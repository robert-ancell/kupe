import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:osm/osm.dart';

import '../account/account.dart';
import '../account/sign_in_dialog.dart';
import '../account/upload_dialog.dart';
import '../data/map_loader.dart';
import '../edit/edited_geometry.dart';
import '../edit/insert.dart';
import '../edit/ways.dart';
import '../imagery/imagery_layer.dart';
import '../geometry/tile.dart';
import '../render/map_painter.dart';
import '../render/tile_mesh.dart';
import 'camera.dart';
import 'frame_stats.dart';
import 'pick.dart';

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
  final OsmApi api;

  /// Where to start looking from.
  final Camera initialCamera;

  /// Where boxes already read are kept between runs.
  final OsmTileCache? cache;

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

  /// Creates the map.
  const MapView({
    super.key,
    required this.api,
    required this.initialCamera,
    this.cache,
    this.place,
    this.account,
    this.imageryIndex,
    this.imageryCache,
    this.imageryFetch,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  late Camera _camera = widget.initialCamera;
  late final OsmEdits _edits = OsmEdits(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  late final MapLoader _loader = MapLoader(
    api: widget.api,
    cache: widget.cache,
    place: widget.place,
    edits: _edits,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  OsmImagery? _source;
  ImageryLayer<ui.Image>? _imagery;
  final _uploaded = <TileId, _Uploaded>{};
  var _restroking = false;
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

  /// Who an edit would be made as.
  Account _account = const Account();

  /// What the changeset would be called, kept here so that a comment typed
  /// and then thought better of is still there next time.
  final _comment = TextEditingController();

  /// The changeset last uploaded, for the line saying it went.
  int? _sent;

  /// What a click does next.
  MapTool _tool = MapTool.browse;

  /// The nodes of the line being drawn, if one is.
  final _drawing = <int>[];

  /// How many changes had been made when the line being drawn was started,
  /// so that all of it can be gathered into one when it is finished.
  int? _drawingFrom;

  /// Where the pointer is, for the line to follow while it is being drawn.
  Offset? _pointerAt;

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
    unawaited(
      Account.read(widget.account).then((account) {
        if (mounted) setState(() => _account = account);
      }),
    );
  }

  /// Opens the account window, and keeps whatever it came back with.
  Future<void> _showAccount() async {
    final account = await showSignInDialog(context, account: _account);
    if (account == null || !mounted) return;
    await account.write(widget.account);
    if (!mounted) return;
    setState(() => _account = account);
  }

  /// Shows what would be sent and, if it is agreed to, sends it.
  ///
  /// What is on screen afterwards is a version behind what OpenStreetMap now
  /// holds — the new elements have real ids, and the changed ones a new
  /// version — so everything read is thrown away and asked for again. That
  /// is a few boxes off the network, and the alternative is an editor whose
  /// next change is made against a version that no longer exists.
  Future<void> _upload() async {
    final token = _account.token;
    // Not signed in, or signed in with a token that was never granted
    // permission to change the map. Both are the same thing to whoever is
    // looking at it — go and sign in — and the window says which.
    if (token == null || !_account.canUpload) {
      await _showAccount();
      return;
    }
    final uploader = OsmUploader(token: token, generator: kupeGenerator);
    final changeset = await showUploadDialog(
      context,
      upload: OsmUpload.of(_edits),
      comment: _comment,
      send: (comment) => uploader.send(OsmUpload.of(_edits), comment: comment),
    );
    uploader.close();
    if (changeset == null || !mounted) return;
    setState(() {
      _edits.undoAll();
      _selected.clear();
      _hovered = null;
      _comment.clear();
      _sent = changeset;
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
    _settle?.cancel();
    _check?.cancel();
    _loader.dispose();
    _imagery?.dispose();
    for (final held in _uploaded.values) {
      held.gpu.dispose();
    }
    _stats.dispose();
    _comment.dispose();
    super.dispose();
  }

  /// The tiles as the engine holds them, uploading what is new and replacing
  /// the lines of anything that has been built again.
  List<GpuTileMesh> get _meshes {
    final meshes = <GpuTileMesh>[];
    for (final tile in _loader.tiles) {
      var held = _uploaded[tile.id];
      if (held == null) {
        held = _Uploaded(tile, GpuTileMesh.of(tile));
        _uploaded[tile.id] = held;
      } else if (!identical(held.source, tile)) {
        // Rebuilding widths leaves the filled shapes untouched and hands
        // back the same list, so only the lines go up again.
        if (identical(held.source.fills, tile.fills)) {
          held.gpu.restroke(tile);
          held.source = tile;
        } else {
          held.gpu.dispose();
          held = _Uploaded(tile, GpuTileMesh.of(tile));
          _uploaded[tile.id] = held;
        }
      }
      meshes.add(held.gpu);
    }
    return meshes;
  }

  /// Catches the line widths up with the zoom, a few tiles at a time.
  ///
  /// Zooming stretches lines that were built for another zoom. Rebuilding
  /// every tile on screen at once would drop a frame, so it is done between
  /// frames until there is nothing stale left.
  void _restrokeSoon() {
    if (_restroking) return;
    _restroking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _restroking = false;
      if (!mounted) return;
      final more = _loader.restroke();
      setState(() {});
      if (more) _restrokeSoon();
    });
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
    _restrokeSoon();
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
    if (held != null && held.covers(camera.latitude, camera.longitude)) return;

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
        fetch: widget.imageryFetch ?? httpFetch(),
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
      _edits.moveNode(
        held.node,
        latitude: Mercator.latitude(world.dy.clamp(0.0, 1.0)),
        longitude: Mercator.longitude(world.dx),
        continuing: !first,
      );
      _refreshPicked();
    });
    if (first) _loader.editsChanged();
  }

  /// Puts back the last change made.
  ///
  /// While a line is being drawn that is its last point: the line is not a
  /// line yet, so there is nothing else it could mean.
  void _undo() {
    if (_drawing.isNotEmpty) {
      _removeLastPoint();
      return;
    }
    if (!_edits.undo()) return;
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

  /// Takes the selected nodes off the map.
  void _deleteSelected() {
    final nodes = _selected.values.whereType<PickedNode>().toList();
    if (nodes.isEmpty) return;
    for (final picked in nodes) {
      _edits.deleteNode(
        picked.node,
        from: waysUsingNode(picked.id, _loader.store, _edits),
      );
    }
    setState(() {
      _selected.clear();
      // What was pointed at may have just been taken off the map, or be a
      // line that is a node shorter than it was.
      _refreshPicked();
    });
    _loader.editsChanged();
  }

  /// Puts a node where the map was clicked, and takes hold of it.
  void _placeNode(Offset at) {
    final world = _camera.toWorld(at, _size);
    final made = _edits.createNode(
      latitude: Mercator.latitude(world.dy.clamp(0.0, 1.0)),
      longitude: Mercator.longitude(world.dx),
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
              latitude: Mercator.latitude(world.dy.clamp(0.0, 1.0)),
              longitude: Mercator.longitude(world.dx),
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
    final node = _edits.movedNode(id) ?? _loader.store.nodes[id];
    if (node == null) return null;
    return [Mercator.x(node.longitude), Mercator.y(node.latitude)];
  }

  /// Whether a click landed on the node with [id].
  bool _isOn(int id, Offset at) {
    final node = _edits.movedNode(id) ?? _loader.store.nodes[id];
    if (node == null) return false;
    final where = _camera.toScreen(
      Mercator.x(node.longitude),
      Mercator.y(node.latitude),
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
    if (_drawing.length > (closing ? 2 : 1)) {
      final way = _edits.createWay(
        nodeIds: [..._drawing, if (closing) _drawing.first],
      );
      // Drawn a point at a time, but a line once it is finished, and a line
      // is what should come back if it is undone.
      if (from != null) _edits.combineSince(from);
      _selectOnly(way);
    } else if (from != null) {
      // Not enough of a line to keep, so its points go with it.
      while (_edits.length > from) {
        _edits.undo();
      }
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
      while (_edits.length > from) {
        _edits.undo();
      }
    }
    setState(() {
      _drawing.clear();
      _drawingFrom = null;
      _tool = MapTool.browse;
    });
    _loader.editsChanged();
  }

  /// Takes back the last point put down for the line being drawn.
  void _removeLastPoint() {
    final id = _drawing.removeLast();
    // Only if it was put down for this line. A point that was already on the
    // map was joined to, not made, and stays where it is.
    if (id < 0) _edits.undo();
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
        worldX: Mercator.x(element.longitude),
        worldY: Mercator.y(element.latitude),
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
      if ((_edits.movedNode(id) ?? _loader.store.nodes[id])
          case final node?) ...[
        Mercator.x(node.longitude),
        Mercator.y(node.latitude),
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
            const SingleActivator(LogicalKeyboardKey.delete):
                const _DeleteIntent(),
            const SingleActivator(LogicalKeyboardKey.backspace):
                const _DeleteIntent(),
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
              _UndoIntent: CallbackAction<_UndoIntent>(
                onInvoke: (_) {
                  _undo();
                  return null;
                },
              ),
              _DeleteIntent: CallbackAction<_DeleteIntent>(
                onInvoke: (_) {
                  _deleteSelected();
                  return null;
                },
              ),
              _FinishIntent: CallbackAction<_FinishIntent>(
                onInvoke: (_) {
                  if (_tool != MapTool.browse) _finishLine();
                  return null;
                },
              ),
              _ToolIntent: CallbackAction<_ToolIntent>(
                onInvoke: (intent) {
                  _chooseTool(intent.tool);
                  return null;
                },
              ),
              _AbandonIntent: CallbackAction<_AbandonIntent>(
                onInvoke: (_) {
                  _abandonLine();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Listener(
                onPointerDown: (event) => _pressedAt = event.localPosition,
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
                      var camera = _camera.panned(details.focalPointDelta);
                      if (details.scale != 1) {
                        final target =
                            _zoomFrom! + math.log(details.scale) / math.ln2;
                        camera = camera.zoomed(
                          target - camera.zoom,
                          details.localFocalPoint,
                          size,
                        );
                      }
                      _moveTo(camera);
                    },
                    onScaleEnd: (_) => _dragging = null,
                    child: Stack(
                      children: [
                        Positioned.fill(
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
                                onDrawn: (calls) => _drawCalls = calls,
                              ),
                              size: Size.infinite,
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
                                changes: OsmUpload.of(_edits).length,
                                onAccount: _showAccount,
                                onUpload: _upload,
                              ),
                              if (!_tooFarToEdit) ...[
                                const SizedBox(height: 12),
                                _Tools(
                                  tool: _tool,
                                  onChanged: (tool) => setState(() {
                                    _drawing.clear();
                                    _tool = _tool == tool
                                        ? MapTool.browse
                                        : tool;
                                  }),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_tooFarToEdit)
                          Positioned.fill(
                            child: Center(
                              child: _ZoomToEdit(onPressed: _zoomToEdit),
                            ),
                          ),
                        if (_selected.isNotEmpty)
                          Positioned(
                            left: 12,
                            bottom: 12,
                            child: _Tags(selected: _selected.values.toList()),
                          ),
                        if (_sent case final changeset?)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 40,
                            child: Center(
                              child: _Sent(
                                changeset: changeset,
                                onDismissed: () => setState(() => _sent = null),
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

/// The tags of what is selected.
///
/// One thing selected shows everything it is tagged with. Several show what
/// they have in common, which is what says whether they can be treated as one
/// thing, and the count says how many they are.
class _Tags extends StatelessWidget {
  final List<Picked> selected;

  const _Tags({required this.selected});

  /// The tags every selected way carries with the same value.
  Map<String, String> get _shared {
    final shared = Map<String, String>.from(selected.first.tags);
    for (final picked in selected.skip(1)) {
      shared.removeWhere((key, value) => picked.tags[key] != value);
    }
    return shared;
  }

  /// What to call the selection.
  String get _title {
    if (selected.length > 1) return '${selected.length} selected';
    final only = selected.single;
    return switch (only.type) {
      OsmElementType.node => 'Node ${only.id}',
      OsmElementType.way => 'Way ${only.id}',
      OsmElementType.relation => 'Relation ${only.id}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final tags = _shared;
    final entries = tags.keys.toList()..sort();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xee2b3036),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280, maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                Text(
                  _title,
                  style: const TextStyle(
                    color: Color(0xff9ec1ff),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                if (entries.isEmpty)
                  Text(
                    selected.length == 1
                        ? 'no tags'
                        : 'nothing tagged the same',
                    style: const TextStyle(color: Color(0xffa0a6ad)),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final key in entries)
                            Text('$key = ${tags[key]}'),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's triangles, and the copy of them the engine holds.
class _Uploaded {
  TileMesh source;
  final GpuTileMesh gpu;

  _Uploaded(this.source, this.gpu);
}

/// Asks for the last change to be put back.
class _UndoIntent extends Intent {
  const _UndoIntent();
}

/// Asks for what is selected to be taken off the map.
class _DeleteIntent extends Intent {
  const _DeleteIntent();
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
  final VoidCallback onAccount;
  final VoidCallback onUpload;

  const _AccountBar({
    required this.account,
    required this.changes,
    required this.onAccount,
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
            onPressed: onUpload,
          ),
          const SizedBox(width: 6),
        ],
        _ToolButton(
          // A token that cannot change the map is not the same as being
          // signed in, whatever it says about who it belongs to, so it does
          // not get the settled icon.
          icon: account.canUpload
              ? Icons.person
              : account.isSignedIn
              ? Icons.person_off_outlined
              : Icons.person_outline,
          label: account.canUpload ? (account.user ?? 'Signed in') : 'Sign in',
          chosen: false,
          onPressed: onAccount,
        ),
      ],
    );
  }
}

/// That a changeset went, with a way to go and look at it.
class _Sent extends StatelessWidget {
  final int changeset;
  final VoidCallback onDismissed;

  const _Sent({required this.changeset, required this.onDismissed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xee2b3036),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              'Uploaded as changeset $changeset',
              style: const TextStyle(fontSize: 12, color: Color(0xffffffff)),
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
  final VoidCallback onPressed;

  const _ToolButton({
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
