import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

import '../contact.dart';
import '../account/account.dart';
import '../account/upload_dialog.dart';
import '../data/map_loader.dart';
import '../edit/edited_geometry.dart';
import '../edit/insert.dart';
import '../imagery/imagery_layer.dart';
import '../render/map_painter.dart';
import '../render/node_sprite.dart';
import '../style/style.dart';
import 'camera.dart';
import 'frame_stats.dart';
import 'operations.dart';
import 'pick.dart';
import 'tag_editor.dart';

/// How long the map waits after being moved before asking for what it can
/// now see.
///
/// Long enough that a drag across a city is one request for where it stopped
/// rather than a request for everywhere it passed over.
const settleDelay = Duration(milliseconds: 250);

/// How long the map waits before checking what it drew from disk against what
/// has been edited since.
///
/// After the reading, so that a view arriving from the cache is on screen
/// before anything is asked about it, and long enough that moving on again
/// cancels it.
const checkDelay = Duration(seconds: 2);

/// How long after a click a second one in the same place is taken as a
/// double click rather than as another click.
const doubleClickWait = Duration(milliseconds: 400);

/// And how far it may be away and still count as the same place.
const doubleClickSlop = 20.0;

/// What a click on the map does.
enum MapTool {
  /// Takes hold of whatever is under it.
  browse,

  /// Puts a node down.
  addNode,

  /// Draws a line, a point at a time.
  addLine,

  /// Draws a line that comes back to where it started.
  addArea,
}

/// How far in the map has to be before anything can be edited.
///
/// The same as the zoom it starts reading at, and for the same reason: there
/// is nothing to edit until the data is there. iD draws the line in the same
/// place.
const minimumEditZoom = minimumLoadZoom;

/// How long zooming in to edit takes.
///
/// Long enough to see where the map went, short enough not to wait for it.
const zoomToEditDuration = Duration(milliseconds: 250);

/// The map, read from OpenStreetMap as it is looked at.
///
/// Panning and zooming only move the camera. Geometry already built is not
/// built again and not uploaded again, so a frame costs the same whether the
/// map is still or moving, and new tiles appear as their answers arrive.
class MapView extends StatefulWidget {
  /// Where to read the map from.
  final OsmApiClient client;

  /// Where to start looking from.
  final Camera initialCamera;

  /// Where boxes already read are kept between runs.
  final OsmDataCache? cache;

  /// Where to remember the place the map was left.
  final File? place;

  /// Where the token an edit is uploaded with is kept between runs.
  ///
  /// Null where there is nowhere to keep one, in which case signing in lasts
  /// only as long as the editor is open.
  final File? account;

  /// The layers of imagery to choose from.
  ///
  /// A listenable rather than a list, because the index is a megabyte off the
  /// network: the map opens on whatever was already known and takes the full
  /// list when it arrives.
  final ValueListenable<OsmImageryIndex>? imageryIndex;

  /// Where imagery tiles are kept between runs.
  final OsmImageryCache? imageryCache;

  /// How imagery tiles are fetched.
  ///
  /// Kept apart from the fetch the API uses, so that imagery, which comes
  /// from servers built to hand out a great deal of it, never takes a turn
  /// the API could have used.
  final OsmFetch? imageryFetch;

  /// What kinds of thing there are on the map, once they are known: what
  /// says a selected node is a cafe, and what it can be made instead.
  final ValueListenable<OsmPresets?>? presets;

  /// Which country a place is in, once the borders are known: what says
  /// which of the kinds that only exist in some countries apply to what is
  /// selected.
  final ValueListenable<OsmCountryCoder?>? countries;

  /// How to sign in, given the account as it stands and a future that
  /// completes if it is given up on. Replaced in tests, which have no
  /// browser.
  final Future<Account> Function(Account account, Future<void> cancel)? signIn;

  /// Creates the map.
  const MapView({
    super.key,
    required this.client,
    required this.initialCamera,
    this.cache,
    this.place,
    this.account,
    this.signIn,
    this.imageryIndex,
    this.imageryCache,
    this.imageryFetch,
    this.presets,
    this.countries,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  late Camera _camera = widget.initialCamera;
  late final OsmEditHistory _edits = OsmEditHistory(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// Everything done to the map, laid over what [_loader] has read.
  late final OsmEditor _editor = OsmEditor(
    _loader.store,
    history: _edits,
    presets: widget.presets?.value,
    isArea: enclosesArea,
  );
  late final MapLoader _loader = MapLoader(
    client: widget.client,
    cache: widget.cache,
    place: widget.place,
    edits: _edits,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  OsmImagery? _source;
  ImageryLayer<ui.Image>? _imagery;
  final _uploaded = <OsmTile, GpuTileMesh>{};

  /// What the points a line can be taken hold of by are drawn with, made for
  /// the screen's density once it is known.
  NodeSprite? _nodeSprite;
  double? _spriteRatio;
  final _stats = FrameStats();
  Timer? _settle;
  Timer? _check;
  Size _size = Size.zero;
  var _drawCalls = 0;
  double? _zoomFrom;

  late final AnimationController _zoomer = AnimationController(
    vsync: this,
    duration: zoomToEditDuration,
  )..addListener(_zoomStep);
  double? _easeFrom;
  double? _easeTo;

  /// The map's own hold on the keyboard, taken back from anything being
  /// typed into whenever the map is pressed.
  final _mapFocus = FocusNode(debugLabel: 'map');

  /// Who an edit would be made as.
  Account _account = const Account();

  /// Takes [account] as whoever is signed in, and gives the API their token.
  void _setAccount(Account account) {
    _account = account;
    widget.client.token = account.token;
  }

  /// What the changeset would be called, kept here so that a comment typed
  /// and then thought better of is still there next time.
  final _comment = TextEditingController();

  /// What to give up signing in with, while a sign-in is waiting on the
  /// browser.
  Completer<void>? _signingIn;

  /// A line to say along the bottom: that a changeset went, or why signing
  /// in did not.
  String? _notice;

  /// What a click does next.
  MapTool _tool = MapTool.browse;

  /// The nodes of the line being drawn, if one is.
  final _drawing = <int>[];

  /// How many changes had been made when the line being drawn was started,
  /// so that all of it can be gathered into one when it is finished.
  int? _drawingFrom;

  /// The line being carried on, if the line being drawn is the rest of one,
  /// and whether it is being carried on from its start rather than its end.
  (int, bool)? _continuing;

  /// Where the pointer is, for the line to follow while it is being drawn.
  Offset? _pointerAt;

  /// Where the pointer was last seen over the map, whatever is in hand: where
  /// a paste goes, and where a move starts from, when they come from a key.
  Offset? _lastPointer;

  /// Where the menu was opened, which is where what it does is done.
  Offset? _menuAt;

  /// What was copied, to paste.
  OsmCopied? _copied;

  /// What is being moved to follow the pointer, if anything is: how many
  /// changes there were before it started, where the pointer started, in
  /// world coordinates, and what is moving.
  (int, Offset, List<OsmElement>)? _moving;

  DateTime? _tappedAt;
  Offset? _tappedOn;

  Picked? _hovered;
  PickedNode? _dragging;
  Offset? _pressedAt;
  var _dragged = false;
  final _selected = <(OsmElementType, int), Picked>{};

  /// The ways that are selected, which is what says whether the nodes along
  /// them can be taken hold of.
  Set<int> get _selectedWays => {
    for (final picked in _selected.values)
      if (picked is PickedWay) picked.id,
  };

  @override
  void initState() {
    super.initState();
    widget.imageryIndex?.addListener(_indexChanged);
    widget.presets?.addListener(_presetsChanged);
    widget.countries?.addListener(_presetsChanged);
    unawaited(
      Account.read(widget.account).then((account) {
        if (mounted) setState(() => _setAccount(account));
      }),
    );
  }

  /// Opens OpenStreetMap in the browser and waits for it to come back,
  /// and says whether it did.
  ///
  /// Straight to the browser, with nothing in between: there is nothing to
  /// decide before signing in, so a window asking whether to would be a
  /// click spent on nothing. While it waits the account button says so and
  /// offers to give up, since the browser may never come back at all.
  Future<bool> _signIn() async {
    if (_signingIn != null) return false;
    final cancel = Completer<void>();
    setState(() {
      _signingIn = cancel;
      _notice = null;
    });
    try {
      final account =
          await (widget.signIn?.call(_account, cancel.future) ??
              _account.signIn(cancel: cancel.future));
      await account.write(widget.account);
      if (!mounted) return false;
      setState(() => _setAccount(account));
      return account.canUpload;
    } on OsmAuthenticationCancelledException {
      return false;
    } on Exception catch (e) {
      if (mounted) setState(() => _notice = '$e');
      return false;
    } finally {
      if (mounted) setState(() => _signingIn = null);
    }
  }

  /// Gives up on the sign-in waiting on the browser.
  void _cancelSignIn() {
    final cancel = _signingIn;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Forgets the token, here and on disk.
  Future<void> _signOut() async {
    final account = _account.copyWith(signedOut: true);
    setState(() => _setAccount(account));
    await account.write(widget.account);
  }

  /// Shows what would be sent and, if it is agreed to, sends it.
  ///
  /// What is on screen afterwards is a version behind what OpenStreetMap now
  /// holds — the new elements have real ids, and the changed ones a new
  /// version — so everything read is thrown away and asked for again. That
  /// is a few boxes off the network, and the alternative is an editor whose
  /// next change is made against a version that no longer exists.
  Future<void> _upload() async {
    // Not signed in, or signed in with a token that was never granted
    // permission to change the map. Either way the answer is to sign in, and
    // once that has worked the upload carries on from where it was asked
    // for rather than making somebody press the button a second time.
    if (!_account.canUpload && !await _signIn()) return;
    if (_account.token == null || !mounted) return;
    final changeset = await showUploadDialog(
      context,
      upload: OsmUpload.of(_edits),
      comment: _comment,
      send: (comment) =>
          widget.client.upload(OsmUpload.of(_edits), comment: comment),
    );
    if (changeset == null || !mounted) return;
    setState(() {
      _editor.undoAll();
      _selected.clear();
      _hovered = null;
      _comment.clear();
      _notice = 'Uploaded as changeset $changeset';
    });
    await _loader.reread();
  }

  /// Whether the map is too far out to edit.
  bool get _tooFarToEdit => _camera.zoom < minimumEditZoom;

  /// Zooms in to where editing starts, about the middle of the view.
  void _zoomToEdit() {
    if (!_tooFarToEdit) return;
    _easeFrom = _camera.zoom;
    _easeTo = minimumEditZoom;
    _zoomer.forward(from: 0);
  }

  void _zoomStep() {
    final from = _easeFrom;
    final to = _easeTo;
    if (from == null || to == null) return;
    _moveTo(
      Camera(
        x: _camera.x,
        y: _camera.y,
        zoom: from + (to - from) * Curves.easeOut.transform(_zoomer.value),
      ),
    );
  }

  /// Takes the imagery again once the full index has arrived, in case it
  /// knows of something better here than what the map opened with.
  void _indexChanged() {
    if (!mounted) return;
    _source = null;
    _chooseImagery(_camera);
    _imagery?.look(_camera, _size);
    setState(() {});
  }

  @override
  void dispose() {
    _zoomer.dispose();
    widget.imageryIndex?.removeListener(_indexChanged);
    widget.presets?.removeListener(_presetsChanged);
    widget.countries?.removeListener(_presetsChanged);
    _settle?.cancel();
    _check?.cancel();
    _loader.dispose();
    _imagery?.dispose();
    for (final held in _uploaded.values) {
      held.dispose();
    }
    _nodeSprite?.dispose();
    _stats.dispose();
    _comment.dispose();
    _mapFocus.dispose();
    super.dispose();
  }

  /// The tiles as the engine holds them, uploading what is new, replacing
  /// what has been built again, and letting go of what the loader no longer
  /// holds.
  List<GpuTileMesh> get _meshes {
    final tiles = _loader.tiles;
    final meshes = <GpuTileMesh>[];
    for (final tile in tiles) {
      var held = _uploaded[tile.id];
      if (held == null || !identical(held.source, tile)) {
        held?.dispose();
        held = GpuTileMesh.of(tile);
        _uploaded[tile.id] = held;
      }
      meshes.add(held);
    }
    if (_uploaded.length > tiles.length) {
      final kept = {for (final tile in tiles) tile.id};
      _uploaded.removeWhere((id, held) {
        if (kept.contains(id)) return false;
        held.dispose();
        return true;
      });
    }
    return meshes;
  }

  /// Makes the picture points are drawn with, for the density of the screen
  /// the map is on, and again if it moves to one of another.
  void _makeSprite(double pixelRatio) {
    if (_spriteRatio == pixelRatio) return;
    _spriteRatio = pixelRatio;
    unawaited(
      NodeSprite.create(pixelRatio).then((sprite) {
        if (!mounted || _spriteRatio != pixelRatio) {
          sprite.dispose();
          return;
        }
        _nodeSprite?.dispose();
        setState(() => _nodeSprite = sprite);
      }),
    );
  }

  /// Asks for what is on screen once the map has stopped moving.
  ///
  /// Anything already held on disk is drawn at once; the rest is read. A
  /// little later, what was drawn from disk is checked against what has been
  /// edited since, which is a single request whatever is on screen.
  void _lookSoon() {
    _settle?.cancel();
    _check?.cancel();
    _settle = Timer(settleDelay, () {
      if (mounted) _loader.look(_camera, _size);
    });
    _check = Timer(checkDelay, () {
      if (mounted) unawaited(_loader.refresh());
    });
  }

  void _moveTo(Camera camera) {
    setState(() {
      _camera = camera;
      // Out here there is no editing to be done, so there is nothing to have
      // selected either.
      if (_tooFarToEdit) _selected.clear();
    });
    // Imagery is asked for as the map moves rather than once it settles,
    // since its servers are built for it and a blank background mid pan is
    // what makes a map feel slow.
    _chooseImagery(camera);
    _imagery?.look(camera, _size);
    _lookSoon();
  }

  /// Picks the imagery to draw where the map is looking.
  ///
  /// The index says which layers have tiles over a place and which of them to
  /// prefer, so the layer changes by itself on crossing into ground a better
  /// one covers. The one already chosen is kept for as long as it covers the
  /// middle of the view, so that panning around inside a country does not
  /// swap the background about.
  void _chooseImagery(Camera camera) {
    final index = widget.imageryIndex?.value;
    if (index == null) return;
    final held = _source;
    if (held != null && held.contains(camera.latitude, camera.longitude)) {
      return;
    }

    final wanted = index
        .at(
          camera.latitude,
          camera.longitude,
          category: OsmImageryCategory.photo,
        )
        .firstOrNull;
    if (wanted == null || wanted.id == held?.id) return;

    _imagery?.dispose();
    _source = wanted;
    _imagery = ImageryLayer<ui.Image>(
      tiles: OsmImageryTiles(
        source: wanted,
        contact: contact,
        fetch: widget.imageryFetch,
        cache: widget.imageryCache,
      ),
      decode: _decode,
      release: (image) => image.dispose(),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// What the imagery is doing, for the readout.
  String get _imageryState {
    final source = _source;
    if (source == null) {
      return widget.imageryIndex == null
          ? 'no imagery index'
          : 'no imagery covers here';
    }
    return '${source.name}: ${_imagery?.held ?? 0} held, '
        '${_imagery?.reading ?? 0} reading';
  }

  /// Works out what the pointer is over.
  ///
  /// Only while the map is close enough to edit: further out the lines are
  /// too fine to point at, and there is nothing to be done with one anyway.
  void _hover(Offset at) {
    _lastPointer = at;
    if (_moving != null) {
      _followPointer(at);
      return;
    }
    // What a click would draw follows the pointer, so where it is has to be
    // known before anything has been drawn at all.
    if (_tool != MapTool.browse) setState(() => _pointerAt = at);
    final found = _tooFarToEdit
        ? null
        : pickAt(
            at,
            _camera,
            _size,
            _loader.store,
            selectedWays: _selectedWays,
            edits: _edits,
            zoom: loadZoom,
          );
    if (found?.id == _hovered?.id && found?.type == _hovered?.type) {
      // The same line, but its shape moves with the camera.
      _hovered = found;
      return;
    }
    setState(() => _hovered = found);
  }

  /// Selects what the pointer is on.
  ///
  /// Holding shift adds to the selection, or takes out what was already in
  /// it, which is how every editor does it. Clicking away from everything
  /// clears the selection, unless shift is held, since that is a miss rather
  /// than a change of mind.
  void _tap(Offset at) {
    // A click puts down what is being moved.
    if (_moving != null) {
      setState(() => _moving = null);
      return;
    }
    if (_tooFarToEdit) return;

    // A second click in the same place, soon enough, puts a node into the
    // line there. Counted here rather than by asking for a double click,
    // because that holds every single click back until it is sure there is
    // no second one, and an editor that waits to say what has been selected
    // feels broken.
    final last = _tappedAt;
    final where = _tappedOn;
    final quick =
        last != null &&
        where != null &&
        !HardwareKeyboard.instance.isShiftPressed &&
        DateTime.now().difference(last) < doubleClickWait &&
        (at - where).distance < doubleClickSlop;
    _tappedAt = DateTime.now();
    _tappedOn = at;
    if (quick && _tool == MapTool.browse) {
      _tappedAt = null;
      _insertNode(at);
      return;
    }

    switch (_tool) {
      case MapTool.addNode:
        _placeNode(at);
        return;
      case MapTool.addLine:
      case MapTool.addArea:
        _extendLine(at);
        return;
      case MapTool.browse:
        break;
    }
    final picked = pickAt(
      at,
      _camera,
      _size,
      _loader.store,
      selectedWays: _selectedWays,
      edits: _edits,
      zoom: loadZoom,
    );
    final adding = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (picked == null) {
        if (!adding) _selected.clear();
        return;
      }
      final key = (picked.type, picked.id);
      if (adding) {
        if (_selected.remove(key) == null) _selected[key] = picked;
      } else {
        _selected
          ..clear()
          ..[key] = picked;
      }
    });
  }

  /// Moves a node to follow the pointer.
  ///
  /// The first move of a drag takes the way it belongs to out of the tile it
  /// was built into, so that the old shape stops being drawn; the rest only
  /// move the node, which is a line or two a frame.
  void _dragNode(PickedNode held, Offset to) {
    final world = _camera.toWorld(to, _size);
    final first = !_dragged;
    _dragged = true;
    setState(() {
      _editor.moveNode(
        held.node,
        latitude: OsmMercator.latitude(world.dy.clamp(0.0, 1.0)),
        longitude: OsmMercator.wrappedLongitude(world.dx),
        continuing: !first,
      );
      _refreshPicked();
    });
    if (first) _loader.editsChanged();
  }

  void _presetsChanged() {
    _editor.presets = widget.presets?.value;
    if (mounted) setState(() {});
  }

  /// The shape [element] takes; see [OsmEditor.geometryOf].
  OsmGeometry _geometryOf(OsmElement element, OsmPresets presets) =>
      _editor.geometryOf(element);

  /// What is selected, as it now stands.
  List<OsmElement> get _selectedElements => [
    for (final picked in _selected.values) picked.element,
  ];

  /// Whether too little of what is selected is on screen to be sure of
  /// what is being done to it.
  bool get _selectionTooLarge {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    void cover(OsmNode? node) {
      if (node == null) return;
      // At the copy round the world nearest the view, as it is drawn.
      final x = OsmMercator.nearest(OsmMercator.x(node.longitude), _camera.x);
      final y = OsmMercator.y(node.latitude);
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }

    final view = _editor;
    for (final element in _selectedElements) {
      switch (element) {
        case OsmNode():
          cover(view.node(element.id));
        case OsmWay():
          for (final id in element.nodeIds) {
            cover(view.node(id));
          }
        case OsmRelation():
          break;
      }
    }
    if (left > right) return false;
    return isTooLarge(
      Rect.fromLTRB(left, top, right, bottom),
      _camera.worldBounds(_size),
    );
  }

  /// What can be done to what is selected, as iD offers it.
  List<OfferedOperation> _offered() {
    final selected = _selectedElements;
    return offeredOperations(
      _editor,
      selected,
      presets: widget.presets?.value,
      here: selected.isEmpty ? const {} : _regionsOf(selected.first),
      tooLarge: selected.isNotEmpty && _selectionTooLarge,
      copied: _copied,
    );
  }

  /// Where on the map what is done by a key or from the menu is done, in
  /// world coordinates: where the menu was opened, or where the pointer is,
  /// or the middle of the view.
  Offset get _actionPoint => _camera.toWorld(
    _menuAt ?? _lastPointer ?? _size.center(Offset.zero),
    _size,
  );

  /// Moves what is being moved to where the pointer has got to from where
  /// it started.
  ///
  /// The move is made afresh from where everything was each time, so that
  /// however long the pointer wanders it comes to one change to undo.
  void _followPointer(Offset at) {
    final (mark, start, elements) = _moving!;
    _edits.undoSince(mark);
    final world = _camera.toWorld(at, _size);
    _editor.move(elements, dx: world.dx - start.dx, dy: world.dy - start.dy);
    _loader.editsChanged();
    setState(_refreshPicked);
  }

  /// Puts back what was being moved where it was.
  void _cancelMove() {
    final (mark, _, _) = _moving!;
    _edits.undoSince(mark);
    _loader.editsChanged();
    setState(() {
      _moving = null;
      _refreshPicked();
    });
  }

  /// Does [kind] to what is selected, or says why it cannot be done.
  ///
  /// By its key as well as from the menu, and by its key the reason it
  /// cannot be done is all there is to show, so it is said along the bottom
  /// of the map, as iD flashes it.
  void _perform(OperationKind kind) {
    if (_tooFarToEdit || _tool != MapTool.browse || _moving != null) return;
    // Pasting by its key works with something selected too, taking the place
    // of the selection with what is pasted.
    if (kind == OperationKind.paste && _copied != null) {
      _paste();
      return;
    }
    final offer = _offered().where((o) => o.kind == kind).firstOrNull;
    if (offer == null) return;
    if (offer.disabled case final why?) {
      setState(() => _notice = why);
      return;
    }
    final view = _editor;
    final selected = _selectedElements;
    switch (kind) {
      case OperationKind.move:
        setState(() => _moving = (_edits.length, _actionPoint, selected));
        return;
      case OperationKind.copy:
        _copied = view.copy(
          selected,
          anchor: (_actionPoint.dx, _actionPoint.dy),
        );
        return;
      case OperationKind.paste:
        _paste();
        return;
      case OperationKind.continueLine:
        final line = view.continuable(selected)!.single;
        final vertex = selected.whereType<OsmNode>().single;
        _startContinuing(line, vertex);
        return;
      case OperationKind.extract:
        final points = view
            .extract(selected, here: _regionsOf(selected.first))
            .apply();
        _loader.editsChanged();
        setState(() {
          _selected.clear();
          for (final point in points) {
            _selected[(OsmElementType.node, point.id)] = PickedNode(
              node: point,
              worldX: OsmMercator.x(point.longitude),
              worldY: OsmMercator.y(point.latitude),
            );
          }
          _refreshPicked();
        });
      case OperationKind.disconnect:
        view.disconnect(selected).apply();
        _loader.editsChanged();
        setState(_refreshPicked);
      case OperationKind.merge:
        _selectAfter(view.merge(selected).apply());
      case OperationKind.split:
        final ways = view.split(selected).apply();
        // The nodes and the pieces, so that they can be disconnected
        // straight away if that is what is wanted next.
        _selectAfter([...selected.whereType<OsmNode>(), ...ways]);
      case OperationKind.reverse:
        view.reverse(selected).apply();
        _loader.editsChanged();
        setState(_refreshPicked);
      case OperationKind.delete:
        view.delete(selected).apply();
        _loader.editsChanged();
        setState(() {
          _selected.clear();
          // What was pointed at may have just been taken off the map, or be
          // a line that is a node shorter than it was.
          _refreshPicked();
        });
    }
  }

  /// Adds a copy of what was copied where the action is, and selects it.
  ///
  /// The point the pointer was at when it was copied lands where the pointer
  /// is now; a single node, or anything copied with the pointer nowhere,
  /// lands by its middle.
  void _paste() {
    final copied = _copied;
    if (copied == null) return;
    final to = _actionPoint;
    final (fromX, fromY) = copied.anchor ?? copied.middle;
    _selectAfter(_editor.paste(copied, dx: to.dx - fromX, dy: to.dy - fromY));
  }

  /// Selects [elements] as they now stand once an operation has changed
  /// them.
  void _selectAfter(List<OsmElement> elements) {
    _loader.editsChanged();
    final view = _editor;
    setState(() {
      _selected.clear();
      for (final element in elements) {
        final picked = switch (element) {
          OsmNode() => switch (view.node(element.id)) {
            final node? => PickedNode(
              node: node,
              worldX: OsmMercator.x(node.longitude),
              worldY: OsmMercator.y(node.latitude),
            ),
            null => null,
          },
          OsmWay() => switch (view.way(element.id)) {
            final way? => PickedWay(
              way: way,
              points: _pointsOfWay(way),
              width: pickWidthOf(way),
            ),
            null => null,
          },
          OsmRelation() => null,
        };
        if (picked != null) _selected[(picked.type, picked.id)] = picked;
      }
      _refreshPicked();
    });
  }

  /// Opens the menu of what can be done, at [at] on the map and [global] on
  /// the screen.
  ///
  /// Whatever is under the pointer is selected first unless it already is,
  /// so that what the menu offers is for what was pointed at. Pointing at
  /// nothing lets go of the selection, and there is nothing to offer.
  Future<void> _openMenu(Offset at, Offset global) async {
    // A right click while something is being moved gives up on the move.
    if (_moving != null) {
      _cancelMove();
      return;
    }
    if (_tooFarToEdit || _tool != MapTool.browse) return;
    final picked = pickAt(
      at,
      _camera,
      _size,
      _loader.store,
      selectedWays: _selectedWays,
      edits: _edits,
      zoom: loadZoom,
    );
    setState(() {
      if (picked == null) {
        _selected.clear();
      } else if (!_selected.containsKey((picked.type, picked.id))) {
        _selected
          ..clear()
          ..[(picked.type, picked.id)] = picked;
      }
    });
    final offered = _offered();
    if (offered.isEmpty) return;
    _menuAt = at;

    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final chosen = await showMenu<OperationKind>(
      context: context,
      position: RelativeRect.fromRect(
        global & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        for (final offer in offered)
          PopupMenuItem(
            key: Key('operation-${offer.kind.name}'),
            value: offer.kind,
            enabled: offer.enabled,
            height: 36,
            child: Tooltip(
              message: offer.disabled ?? offer.description,
              waitDuration: const Duration(milliseconds: 400),
              child: Row(
                children: [
                  Icon(offer.icon, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(offer.title)),
                  const SizedBox(width: 16),
                  Text(
                    offer.key,
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    if (chosen != null && mounted) _perform(chosen);
    _menuAt = null;
  }

  /// Carries on drawing [line] from [vertex], its first node or its last.
  ///
  /// As drawing a new line, a point a click, but the points go onto the end
  /// of [line] when it is finished rather than making a line of their own.
  /// A `fixme=continue` or `noexit=yes` on the end is taken off, since the
  /// line no longer stops there, and that goes with the rest of it as one
  /// change to undo.
  void _startContinuing(OsmWay line, OsmNode vertex) {
    _drawingFrom = _edits.length;
    final tags = Map.of(vertex.tags);
    if (tags['fixme'] == 'continue') tags.remove('fixme');
    if (tags['noexit'] == 'yes') tags.remove('noexit');
    _editor.setTags(vertex, tags);
    setState(() {
      _selected.clear();
      _continuing = (line.id, line.nodeIds.first == vertex.id);
      _drawing
        ..clear()
        ..add(vertex.id);
      _tool = MapTool.addLine;
    });
    _loader.editsChanged();
  }

  /// Every region [element] is in, by where it is: a node where it stands,
  /// and a way where it starts. Nothing while the borders are not known, or
  /// for something with nowhere to stand, which leaves only what is meant
  /// for everywhere.
  Set<String> _regionsOf(OsmElement element) {
    final countries = widget.countries?.value;
    if (countries == null) return const {};
    final node = switch (element) {
      OsmNode() => _edits.changedNode(element.id) ?? element,
      OsmWay() when element.nodeIds.isNotEmpty =>
        _edits.changedNode(element.nodeIds.first) ??
            _loader.store.nodes[element.nodeIds.first],
      _ => null,
    };
    if (node == null) return const {};
    return countries.codesAt(node.latitude, node.longitude);
  }

  /// Gives each element its new tags, all as one change.
  ///
  /// However many elements one edit of the text touches, it was one thing to
  /// whoever made it and is one thing to undo.
  void _setTags(List<(OsmElement, Map<String, String>)> changes) {
    _editor.group(() {
      for (final (element, tags) in changes) {
        _editor.setTags(element, tags);
      }
    });
    _loader.editsChanged();
    _refreshPicked();
  }

  /// Puts back the last change made.
  ///
  /// While a line is being drawn that is its last point: the line is not a
  /// line yet, so there is nothing else it could mean.
  void _undo() {
    // Undoing mid move is giving up on the move.
    if (_moving != null) {
      _cancelMove();
      return;
    }
    // Carrying a line on with nothing added to it yet is only the start of
    // it, and taking that back is giving up on it.
    if (_continuing != null && _drawing.length <= 1) {
      _abandonLine();
      return;
    }
    if (_drawing.isNotEmpty) {
      _removeLastPoint();
      return;
    }
    if (!_editor.undo()) return;
    _loader.editsChanged();
    _refreshPicked();
  }

  /// Makes the last change undone again.
  ///
  /// Not while moving or drawing: what was undone was undone from before
  /// either started.
  void _redo() {
    if (_moving != null || _drawing.isNotEmpty) return;
    if (!_editor.redo()) return;
    _loader.editsChanged();
    _refreshPicked();
  }

  /// Brings what is pointed at and what is selected up to date with what has
  /// been changed.
  ///
  /// Both hold the geometry to draw themselves by, taken when they were
  /// picked. Without this they go on being drawn where they were before the
  /// change, which for a node being dragged is a circle left behind at the
  /// place it started from.
  void _refreshPicked() {
    final store = _loader.store;
    final hovered = _hovered;
    if (hovered != null) _hovered = refreshed(hovered, store, _edits);
    for (final key in _selected.keys.toList()) {
      final picked = refreshed(_selected[key]!, store, _edits);
      if (picked == null) {
        _selected.remove(key);
      } else {
        _selected[key] = picked;
      }
    }
  }

  /// Puts a node into the line under the pointer.
  ///
  /// Where a double click lands rather than where the line's nodes are, so
  /// that a node can be put exactly where it is wanted.
  void _insertNode(Offset at) {
    if (_tooFarToEdit) return;
    final line = wayAt(
      at,
      _camera,
      _size,
      _loader.store,
      edits: _edits,
      zoom: loadZoom,
    );
    if (line == null) return;

    final world = _camera.toWorld(at, _size);
    final made = insertNodeInto(
      line.way,
      _loader.store,
      _edits,
      worldX: world.dx,
      worldY: world.dy,
    );
    if (made == null) return;
    _selectOnly(made);
    setState(_refreshPicked);
    _loader.editsChanged();
  }

  /// Puts a node where the map was clicked, and takes hold of it.
  void _placeNode(Offset at) {
    final world = _camera.toWorld(at, _size);
    final made = _editor.createNode(
      latitude: OsmMercator.latitude(world.dy.clamp(0.0, 1.0)),
      longitude: OsmMercator.wrappedLongitude(world.dx),
    );
    _selectOnly(made);
    setState(() => _tool = MapTool.browse);
    _loader.editsChanged();
  }

  /// Adds a point to the line being drawn, or finishes it.
  void _extendLine(Offset at) {
    _drawingFrom ??= _edits.length;
    final world = _camera.toWorld(at, _size);
    // Clicking the point the line has reached finishes it, which is how
    // every editor ends a line. The points of a line being drawn are new and
    // in no way yet, so they are looked for here rather than on the map.
    if (_drawing.isNotEmpty && _isOn(_drawing.last, at)) {
      _finishLine();
      return;
    }
    // Coming back to where a closed line started closes it there.
    if (_tool == MapTool.addArea &&
        _drawing.length > 2 &&
        _isOn(_drawing.first, at)) {
      _finishLine();
      return;
    }

    final under = nodeAt(
      at,
      _camera,
      _size,
      _loader.store,
      selectedWays: _selectedWays,
      edits: _edits,
      zoom: loadZoom,
    );

    final id =
        under?.id ??
        _edits
            .createNode(
              latitude: OsmMercator.latitude(world.dy.clamp(0.0, 1.0)),
              longitude: OsmMercator.wrappedLongitude(world.dx),
            )
            .id;
    setState(() => _drawing.add(id));
    _loader.editsChanged();
  }

  /// The line from the last point put down to the pointer, so that what the
  /// next click would draw can be seen before it is drawn.
  List<double> _ghost(Size size) {
    final at = _pointerAt;
    if (_drawing.isEmpty || at == null) return const [];
    final world = _camera.toWorld(at, size);
    final last = _pointOf(_drawing.last);
    if (last == null) return const [];
    final first = _pointOf(_drawing.first);

    return [
      ...last,
      world.dx,
      world.dy,
      // A shape closes back to where it started, and that line has not been
      // drawn either, so it is shown the same way.
      if (_tool == MapTool.addArea && _drawing.length > 1 && first != null) ...[
        world.dx,
        world.dy,
        ...first,
      ],
    ];
  }

  /// Where a node would be put down by the next click, if one would.
  (double, double)? _ghostNode(Size size) {
    final at = _pointerAt;
    if (at == null || _tool == MapTool.browse) return null;
    final world = _camera.toWorld(at, size);
    return (world.dx, world.dy);
  }

  /// Where a node is, in world coordinates.
  List<double>? _pointOf(int id) {
    final node = _edits.changedNode(id) ?? _loader.store.nodes[id];
    if (node == null) return null;
    return [OsmMercator.x(node.longitude), OsmMercator.y(node.latitude)];
  }

  /// Whether a click landed on the node with [id].
  bool _isOn(int id, Offset at) {
    final node = _edits.changedNode(id) ?? _loader.store.nodes[id];
    if (node == null) return false;
    final where = _camera.toScreen(
      OsmMercator.x(node.longitude),
      OsmMercator.y(node.latitude),
      _size,
    );
    return (where - at).distance <= nodePickTolerance;
  }

  /// Finishes the line being drawn, keeping it if it has any length.
  ///
  /// A closed line comes back to the point it started from, which is the
  /// same node again rather than another one in the same place.
  void _finishLine() {
    final closing = _tool == MapTool.addArea;
    final from = _drawingFrom;
    final continuing = _continuing;
    if (continuing != null) {
      final (id, fromStart) = continuing;
      final line = _editor.way(id);
      final added = _drawing.skip(1).toList();
      if (line != null && added.isNotEmpty) {
        _editor.setWayNodes(line, [
          if (fromStart) ...added.reversed,
          ...line.nodeIds,
          if (!fromStart) ...added,
        ]);
        if (from != null) _edits.combineSince(from);
        _selectOnly(_editor.way(id)!);
      } else if (from != null) {
        _edits.undoSince(from);
      }
      setState(() {
        _drawing.clear();
        _drawingFrom = null;
        _continuing = null;
        _tool = MapTool.browse;
      });
      _loader.editsChanged();
      return;
    }
    if (_drawing.length > (closing ? 2 : 1)) {
      final way = _editor.createWay(
        nodeIds: [..._drawing, if (closing) _drawing.first],
      );
      // Drawn a point at a time, but a line once it is finished, and a line
      // is what should come back if it is undone.
      if (from != null) _edits.combineSince(from);
      _selectOnly(way);
    } else if (from != null) {
      // Not enough of a line to keep, so its points go with it.
      _edits.undoSince(from);
    }
    setState(() {
      _drawing.clear();
      _drawingFrom = null;
      _tool = MapTool.browse;
    });
    _loader.editsChanged();
  }

  /// Gives up on the line being drawn, and on the points put down for it.
  void _abandonLine() {
    if (_drawing.isEmpty && _tool == MapTool.browse) return;
    final from = _drawingFrom;
    if (from != null) {
      _edits.undoSince(from);
    }
    setState(() {
      _drawing.clear();
      _drawingFrom = null;
      _continuing = null;
      _tool = MapTool.browse;
    });
    _loader.editsChanged();
  }

  /// Takes back the last point put down for the line being drawn.
  void _removeLastPoint() {
    final id = _drawing.removeLast();
    // Only if it was put down for this line. A point that was already on the
    // map was joined to, not made, and stays where it is.
    // Taken back rather than undone, so it cannot be redone: the line
    // being drawn does not know about it any more.
    if (id < 0) _edits.undoSince(_edits.length - 1);
    if (_drawing.isEmpty) _drawingFrom = null;
    setState(() {});
    _loader.editsChanged();
  }

  /// Takes up a tool, or puts it down again if it was already in hand.
  void _chooseTool(MapTool tool) {
    if (_tooFarToEdit) return;
    if (_drawing.isNotEmpty) _abandonLine();
    setState(() {
      _tool = _tool == tool ? MapTool.browse : tool;
      if (_tool == MapTool.browse) _pointerAt = null;
    });
  }

  /// Selects one element and nothing else.
  void _selectOnly(OsmElement element) {
    final picked = switch (element) {
      OsmNode() => PickedNode(
        node: element,
        worldX: OsmMercator.x(element.longitude),
        worldY: OsmMercator.y(element.latitude),
      ),
      OsmWay() => PickedWay(
        way: element,
        points: _pointsOfWay(element),
        width: 5,
      ),
      _ => null,
    };
    if (picked == null) return;
    setState(() {
      _selected
        ..clear()
        ..[(picked.type, picked.id)] = picked;
    });
  }

  List<double> _pointsOfWay(OsmWay way) => [
    for (final id in way.nodeIds)
      if ((_edits.changedNode(id) ?? _loader.store.nodes[id])
          case final node?) ...[
        OsmMercator.x(node.longitude),
        OsmMercator.y(node.latitude),
      ],
  ];

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _moveTo(
      _camera.zoomed(-event.scrollDelta.dy / 200, event.localPosition, _size),
    );
  }

  @override
  Widget build(BuildContext context) {
    _makeSprite(MediaQuery.devicePixelRatioOf(context));
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          _chooseImagery(_camera);
          _imagery?.look(_camera, size);
          _lookSoon();
        }
        return Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                const _UndoIntent(),
            SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                const _UndoIntent(),
            SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: true,
              shift: true,
            ): const _RedoIntent(),
            SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
                const _RedoIntent(),
            SingleActivator(LogicalKeyboardKey.keyY, control: true):
                const _RedoIntent(),
            // iD's keys for what can be done to what is selected.
            const SingleActivator(LogicalKeyboardKey.delete):
                const _OperationIntent(OperationKind.delete),
            const SingleActivator(LogicalKeyboardKey.delete, control: true):
                const _OperationIntent(OperationKind.delete),
            const SingleActivator(LogicalKeyboardKey.delete, meta: true):
                const _OperationIntent(OperationKind.delete),
            const SingleActivator(LogicalKeyboardKey.backspace, control: true):
                const _OperationIntent(OperationKind.delete),
            const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
                const _OperationIntent(OperationKind.delete),
            const SingleActivator(LogicalKeyboardKey.keyA):
                const _OperationIntent(OperationKind.continueLine),
            const SingleActivator(LogicalKeyboardKey.keyD):
                const _OperationIntent(OperationKind.disconnect),
            const SingleActivator(LogicalKeyboardKey.keyE):
                const _OperationIntent(OperationKind.extract),
            const SingleActivator(LogicalKeyboardKey.keyC):
                const _OperationIntent(OperationKind.merge),
            const SingleActivator(LogicalKeyboardKey.keyX):
                const _OperationIntent(OperationKind.split),
            const SingleActivator(LogicalKeyboardKey.keyM):
                const _OperationIntent(OperationKind.move),
            const SingleActivator(LogicalKeyboardKey.keyC, control: true):
                const _OperationIntent(OperationKind.copy),
            const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                const _OperationIntent(OperationKind.copy),
            const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                const _OperationIntent(OperationKind.paste),
            const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                const _OperationIntent(OperationKind.paste),
            const SingleActivator(LogicalKeyboardKey.keyV):
                const _OperationIntent(OperationKind.reverse),
            const SingleActivator(LogicalKeyboardKey.enter):
                const _FinishIntent(),
            const SingleActivator(LogicalKeyboardKey.numpadEnter):
                const _FinishIntent(),
            const SingleActivator(LogicalKeyboardKey.escape):
                const _AbandonIntent(),
            const SingleActivator(LogicalKeyboardKey.digit1): const _ToolIntent(
              MapTool.addNode,
            ),
            const SingleActivator(LogicalKeyboardKey.digit2): const _ToolIntent(
              MapTool.addLine,
            ),
            const SingleActivator(LogicalKeyboardKey.digit3): const _ToolIntent(
              MapTool.addArea,
            ),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _UndoIntent: _MapAction<_UndoIntent>(
                onInvoke: (_) {
                  _undo();
                  return null;
                },
              ),
              _RedoIntent: _MapAction<_RedoIntent>(
                onInvoke: (_) {
                  _redo();
                  return null;
                },
              ),
              _OperationIntent: _MapAction<_OperationIntent>(
                onInvoke: (intent) {
                  _perform(intent.kind);
                  return null;
                },
              ),
              _FinishIntent: _MapAction<_FinishIntent>(
                onInvoke: (_) {
                  if (_tool != MapTool.browse) _finishLine();
                  return null;
                },
              ),
              _ToolIntent: _MapAction<_ToolIntent>(
                onInvoke: (intent) {
                  _chooseTool(intent.tool);
                  return null;
                },
              ),
              _AbandonIntent: _MapAction<_AbandonIntent>(
                onInvoke: (_) {
                  if (_moving != null) {
                    _cancelMove();
                    return null;
                  }
                  _abandonLine();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              focusNode: _mapFocus,
              child: Stack(
                children: [
                  // Only the map takes the pointer. The buttons over it are
                  // its siblings rather than its children, so a press, a
                  // drag, a scroll or a hover on one of them stops at the
                  // button instead of reaching the map underneath.
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: (event) {
                        _pressedAt = event.localPosition;
                        if (event.kind == PointerDeviceKind.mouse &&
                            event.buttons & kSecondaryMouseButton != 0) {
                          _mapFocus.requestFocus();
                          unawaited(
                            _openMenu(event.localPosition, event.position),
                          );
                          return;
                        }
                        // Pressing on the map takes the keys back from
                        // anything being typed into, which is also what
                        // applies tags being edited before the press can
                        // change what is selected.
                        _mapFocus.requestFocus();
                      },
                      onPointerSignal: _scroll,
                      child: MouseRegion(
                        onHover: (event) => _hover(event.localPosition),
                        onExit: (_) {
                          if (_hovered != null) setState(() => _hovered = null);
                        },
                        child: GestureDetector(
                          onTapUp: (details) => _tap(details.localPosition),
                          onScaleStart: (details) {
                            _zoomFrom = _camera.zoom;
                            _dragged = false;
                            // A drag that starts on a node moves the node; anywhere else
                            // it moves the map.
                            // From where the pointer went down rather than from
                            // where the gesture was recognised: a drag is only a
                            // drag once it has moved, by which time it has left
                            // anything as small as a node behind.
                            _dragging = _tooFarToEdit
                                ? null
                                : nodeAt(
                                    _pressedAt ?? details.localFocalPoint,
                                    _camera,
                                    _size,
                                    _loader.store,
                                    selectedWays: _selectedWays,
                                    edits: _edits,
                                    zoom: loadZoom,
                                  );
                          },
                          onScaleUpdate: (details) {
                            final held = _dragging;
                            if (held != null && details.pointerCount < 2) {
                              _dragNode(held, details.localFocalPoint);
                              return;
                            }
                            var camera = _camera.panned(
                              details.focalPointDelta,
                            );
                            if (details.scale != 1) {
                              final target =
                                  _zoomFrom! +
                                  math.log(details.scale) / math.ln2;
                              camera = camera.zoomed(
                                target - camera.zoom,
                                details.localFocalPoint,
                                size,
                              );
                            }
                            _moveTo(camera);
                          },
                          onScaleEnd: (_) => _dragging = null,
                          // Holding a finger down is the right click of a
                          // touch screen.
                          onLongPressStart: (details) => unawaited(
                            _openMenu(
                              details.localPosition,
                              details.globalPosition,
                            ),
                          ),
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: MapPainter(
                                camera: _camera,
                                tiles: _meshes,
                                imagery:
                                    _imagery?.piecesFor(_camera, size) ??
                                    const [],
                                edited: editedGeometry(
                                  _loader.store,
                                  _edits,
                                  drawing: _drawing,
                                ),
                                ghost: _ghost(size),
                                ghostNode: _ghostNode(size),
                                selection: _selected.values.toList(),
                                highlight: _hovered,
                                nodeSprite: _nodeSprite,
                                onDrawn: (calls) => _drawCalls = calls,
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _AccountBar(
                          account: _account,
                          signingIn: _signingIn != null,
                          onSignIn: _signIn,
                          onCancel: _cancelSignIn,
                          onSignOut: _signOut,
                          changes: OsmUpload.of(_edits).length,
                          onUpload: _upload,
                        ),
                        if (!_tooFarToEdit) ...[
                          const SizedBox(height: 12),
                          _Tools(
                            tool: _tool,
                            onChanged: (tool) => setState(() {
                              _drawing.clear();
                              _tool = _tool == tool ? MapTool.browse : tool;
                            }),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_tooFarToEdit)
                    Positioned.fill(
                      child: Center(child: _ZoomToEdit(onPressed: _zoomToEdit)),
                    ),
                  if (_selected.isNotEmpty)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: TagEditor(
                        elements: [
                          for (final picked in _selected.values) picked.element,
                        ],
                        presets: widget.presets?.value,
                        geometryOf: _geometryOf,
                        regionsOf: _regionsOf,
                        onChanged: _setTags,
                        returnFocus: _mapFocus,
                      ),
                    ),
                  if (_notice case final notice?)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 40,
                      child: Center(
                        child: _Notice(
                          text: notice,
                          onDismissed: () => setState(() => _notice = null),
                        ),
                      ),
                    ),
                  if (_source?.attribution case final credit?)
                    Positioned(
                      right: 8,
                      bottom: 6,
                      child: _Attribution(credit),
                    ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _Readout(
                      camera: _camera,
                      stats: _stats,
                      loader: _loader,
                      drawCalls: _drawCalls,
                      imagery: _imageryState,
                      edits: _edits.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Turns a fetched tile into a picture.
Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// The credit the imagery's licence asks for, which has to be on screen
/// whenever the imagery is.
class _Attribution extends StatelessWidget {
  final String text;

  const _Attribution(this.text);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xb3ffffff),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(fontSize: 11, color: Color(0xff333333)),
        ),
      ),
    );
  }
}

/// What the map is doing, drawn over it.
///
/// A map either holds sixty frames a second or it does not, and the only way
/// to know which is to watch the numbers while moving it around. The rest
/// says how much has been asked of OpenStreetMap, which nothing else shows.
class _Readout extends StatefulWidget {
  final Camera camera;
  final FrameStats stats;
  final MapLoader loader;
  final int drawCalls;
  final String imagery;
  final int edits;

  const _Readout({
    required this.camera,
    required this.stats,
    required this.loader,
    required this.drawCalls,
    required this.imagery,
    required this.edits,
  });

  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
  // The numbers keep moving after the map stops, as the last frames age out
  // of the window, so the readout ticks rather than waiting for a gesture.
  late final Timer _tick = Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final loader = widget.loader;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xcc000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xffffffff),
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.camera}'),
              Text(
                '${loader.tiles.length} tiles, '
                '${widget.drawCalls} draw calls',
              ),
              Text('build  ${stats.build.toStringAsFixed(2)} ms'),
              Text('raster ${stats.raster.toStringAsFixed(2)} ms'),
              Text('worst  ${stats.worst.toStringAsFixed(2)} ms'),
              Text(
                '${loader.requests} requests, ${loader.reading} reading, '
                '${loader.waiting - loader.reading} waiting',
              ),
              Text('${loader.store}'),
              Text(widget.imagery),
              if (widget.edits > 0)
                Text(
                  '${widget.edits} '
                  '${widget.edits == 1 ? 'change' : 'changes'}, '
                  'ctrl+z to undo',
                  style: const TextStyle(color: Color(0xffffd080)),
                ),
              if (loader.cache != null)
                Text(
                  '${loader.cache!.tiles.length} boxes held, '
                  '${(loader.cache!.bytes / (1 << 20)).toStringAsFixed(1)} '
                  'MB on disk',
                ),
              if (loader.stopped != null)
                Text(
                  'paused: ${loader.stopped}, trying again shortly',
                  style: const TextStyle(color: Color(0xffff8080)),
                )
              else if (loader.crowded)
                const Text(
                  'too much here to show it all, zoom in',
                  style: TextStyle(color: Color(0xffffd080)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says that the map is too far out to edit, and zooms in when pressed.
///
/// What iD shows, down to the words: below the zoom where data is read there
/// is nothing to edit, and the way out of that is the same gesture every
/// time, so it is worth a button rather than an instruction.
class _ZoomToEdit extends StatelessWidget {
  final VoidCallback onPressed;

  const _ZoomToEdit({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xee3b4147),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 18, color: Color(0xffffffff)),
              SizedBox(width: 8),
              Text(
                'Zoom in to edit',
                style: TextStyle(fontSize: 14, color: Color(0xffffffff)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for the last change to be put back.
class _UndoIntent extends Intent {
  const _UndoIntent();
}

/// Asks for the last change put back to be made again.
class _RedoIntent extends Intent {
  const _RedoIntent();
}

/// Asks for something to be done to what is selected.
class _OperationIntent extends Intent {
  /// What.
  final OperationKind kind;

  const _OperationIntent(this.kind);
}

/// Asks for the line being drawn to be finished.
class _FinishIntent extends Intent {
  const _FinishIntent();
}

/// Asks for the line being drawn to be given up on.
class _AbandonIntent extends Intent {
  const _AbandonIntent();
}

/// Asks for a tool to be taken up.
class _ToolIntent extends Intent {
  /// Which one.
  final MapTool tool;

  const _ToolIntent(this.tool);
}

/// Who an edit would be made as, and the button that sends one.
///
/// Always on screen, even zoomed out past editing: what it says is who the
/// editor is, which is worth knowing before a change is made rather than
/// after one is ready to go.
class _AccountBar extends StatelessWidget {
  final Account account;
  final int changes;
  final bool signingIn;
  final VoidCallback onSignIn;
  final VoidCallback onCancel;
  final VoidCallback onSignOut;
  final VoidCallback onUpload;

  const _AccountBar({
    required this.account,
    required this.changes,
    required this.signingIn,
    required this.onSignIn,
    required this.onCancel,
    required this.onSignOut,
    required this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (changes > 0) ...[
          _ToolButton(
            icon: Icons.cloud_upload,
            label: 'Upload $changes',
            chosen: true,
            onPressed: signingIn ? null : onUpload,
          ),
          const SizedBox(width: 6),
        ],
        if (signingIn)
          // What the editor is waiting on is somewhere else — a browser
          // window, perhaps behind this one — so it says where, and offers
          // a way out for when that window has been closed and is never
          // coming back.
          _ToolButton(
            key: const Key('cancel-sign-in'),
            icon: Icons.close,
            label: 'Waiting for the browser…',
            chosen: false,
            onPressed: onCancel,
          )
        else if (account.canUpload)
          Builder(
            builder: (context) => _ToolButton(
              key: const Key('account'),
              icon: Icons.person,
              label: account.user ?? 'Signed in',
              chosen: false,
              onPressed: () => _offerSignOut(context),
            ),
          )
        else
          _ToolButton(
            key: const Key('sign-in'),
            // A token that cannot change the map is not the same as being
            // signed in, whatever it says about who it belongs to, so it is
            // offered as signing in rather than as an account.
            icon: account.isSignedIn
                ? Icons.person_off_outlined
                : Icons.person_outline,
            label: 'Sign in',
            chosen: false,
            onPressed: onSignIn,
          ),
      ],
    );
  }

  /// A menu under the account button, holding the one thing there is to do
  /// with an account once it is signed in.
  Future<void> _offerSignOut(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(
      box.size.bottomLeft(Offset.zero),
      ancestor: overlay,
    );
    final chosen = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size(box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          key: Key('sign-out'),
          value: true,
          child: Text('Sign out'),
        ),
      ],
    );
    if (chosen == true) onSignOut();
  }
}

/// A line along the bottom of the map: that a changeset went, or why
/// signing in did not.
class _Notice extends StatelessWidget {
  final String text;
  final VoidCallback onDismissed;

  const _Notice({required this.text, required this.onDismissed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xee2b3036),
      borderRadius: BorderRadius.circular(4),
      child: ConstrainedBox(
        // A refusal from OpenStreetMap can be a paragraph, and a paragraph
        // across the whole width of a desktop screen cannot be read.
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SelectableText(
                  text,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffffffff),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: const Color(0xffffffff),
                onPressed: onDismissed,
                tooltip: 'Dismiss',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The buttons that say what a click does next.
class _Tools extends StatelessWidget {
  final MapTool tool;
  final ValueChanged<MapTool> onChanged;

  const _Tools({required this.tool, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ToolButton(
          icon: Icons.fiber_manual_record,
          label: 'Node 1',
          chosen: tool == MapTool.addNode,
          onPressed: () => onChanged(MapTool.addNode),
        ),
        const SizedBox(height: 6),
        _ToolButton(
          icon: Icons.timeline,
          label: 'Line 2',
          chosen: tool == MapTool.addLine,
          onPressed: () => onChanged(MapTool.addLine),
        ),
        const SizedBox(height: 6),
        _ToolButton(
          icon: Icons.pentagon_outlined,
          label: 'Area 3',
          chosen: tool == MapTool.addArea,
          onPressed: () => onChanged(MapTool.addArea),
        ),
      ],
    );
  }
}

/// One of them, which says whether it is the one in hand.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool chosen;
  final VoidCallback? onPressed;

  const _ToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.chosen,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: chosen ? const Color(0xff2f6fed) : const Color(0xee2b3036),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: const Color(0xffffffff)),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Color(0xffffffff)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the map's own keyboard actions, which stands aside while text is
/// being typed.
///
/// The map's keys are nearer to a text field than the ones that edit text,
/// so without this backspace in the tags would delete what is selected and
/// typing a 1 would take up the node tool. Standing aside lets the key
/// carry on to the text field as if the map were not there.
class _MapAction<T extends Intent> extends CallbackAction<T> {
  _MapAction({required super.onInvoke});

  @override
  bool isEnabled(T intent) => !_typing;

  static bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null);
  }
}
