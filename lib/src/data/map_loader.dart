import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';
import '../render/tessellate.dart';
import '../render/tile_mesh.dart';
import 'last_place.dart';
import 'map_store.dart';

/// How far in the map has to be before anything is asked for.
///
/// The same threshold iD uses. Further out a view covers enough ground that
/// reading it is a bulk download rather than editing, and the API is run for
/// editing.
const minimumLoadZoom = 16.0;

/// The zoom boxes are asked for at.
///
/// A box this size is a few hundred metres across, comes back quickly and
/// stays well inside what the API will answer with at once. The same zoom iD
/// asks at, whatever the camera is doing.
const loadZoom = 16;

/// The most tiles that will be asked for to fill one view.
///
/// Measured against the live API over Auckland and Wellington: the first
/// half dozen boxes come back in two to five seconds and everything after
/// them takes twenty five to fifty. The server allows a burst and then holds
/// the rest back, so asking for a whole large screen at once buys a minute of
/// waiting. Staying near the burst is what makes the middle of the view
/// appear quickly; the edges follow as the map is panned.
const maximumTilesPerView = 16;

/// The most requests one view may cost in total, splitting included.
///
/// A box over somewhere very dense can hold more than the API will answer
/// with, so it is asked for in quarters. Reaching this means there is too
/// much here to show, which the map says rather than quietly reading half.
const maximumRequestsPerView = 32;

/// How many requests this map has outstanding at once.
///
/// The fetch keeps its own count as well; this one is what keeps the queue
/// short enough to throw away when the view moves. iD sets no limit at all
/// and lets the browser decide; this stays well under that.
///
/// Two was measured as slower than four rather than gentler: the server holds
/// a client to about the same throughput either way, so asking one at a time
/// only lengthens the wait.
const maximumInFlight = 4;

/// How long the map waits before trying again after the API turns it away.
///
/// Being turned away is not permanent and must not be treated as such. The
/// same wait iD uses.
const retryDelay = Duration(seconds: 8);

/// How far a tile will be split when the API says it holds too much.
const maximumSplits = 2;

/// How far a line's width may drift from what the style asks for before it is
/// built again.
///
/// A line is a fixed number of pixels wide whatever the zoom, but its width
/// is baked into its triangles, so zooming stretches it. A tenth is under a
/// pixel on any line the style draws, which is not something anyone can pick
/// out mid gesture, and it keeps a pinch from rebuilding the screen twice.
const maximumWidthError = 0.1;

/// How long is spent rebuilding line widths in one go.
///
/// Rebuilding happens on the interface thread, between frames, so it is
/// bounded rather than run to completion: a tile or two catch up each frame
/// and the rest follow.
const restrokeBudget = Duration(milliseconds: 4);

/// Reads the visible map from OpenStreetMap, a tile at a time.
///
/// Only what is on screen is asked for, only once, and only while the map is
/// zoomed in far enough for the answer to be a reasonable size. Panning away
/// from a tile that has not been asked for yet drops it from the queue rather
/// than asking for it anyway.
class MapLoader {
  /// The API to read from.
  final OsmApi api;

  /// Where boxes already read are kept between runs, if anywhere.
  final OsmTileCache? cache;

  /// Where to remember the place the map was left, if anywhere.
  final File? place;

  /// The changes made to the map.
  ///
  /// What has been changed is left out of the tiles that are built and kept,
  /// because those are built once and a change has to show at once. It is
  /// drawn from what it is now instead.
  final OsmEdits edits;

  /// Everything read so far.
  final MapStore store = MapStore();

  /// Called whenever there is something new to draw.
  final void Function() onChanged;

  final _built = <TileId, TileMesh>{};
  final _asked = <TileId>{};
  var _queue = <TileId>[];
  var _running = 0;
  Camera? _camera;
  Size _size = Size.zero;

  /// Why loading is paused, or null while it is not.
  ///
  /// Set when the API turns the map away. Cleared again after [retryDelay],
  /// because a server that is busy now will not be busy for ever.
  String? stopped;

  /// Whether the view holds more than can be read at this zoom.
  ///
  /// Set when splitting a box runs out of budget, which means there is too
  /// much here to show all of. Cleared by looking somewhere else or by
  /// zooming in, which both make the boxes smaller.
  bool crowded = false;

  var _spent = 0;
  Timer? _resume;
  final _reading = <TileId, Completer<void>>{};

  /// Creates a loader.
  MapLoader({
    required this.api,
    required this.onChanged,
    this.cache,
    this.place,
    OsmEdits? edits,
  }) : edits = edits ?? OsmEdits();

  /// The elements left out of the tiles because they have been changed.
  Set<(OsmElementType, int)> get hidden => _hidden;

  var _hidden = <(OsmElementType, int)>{};

  bool _isHidden(OsmElement element) =>
      _hidden.contains((element.type, element.id));

  /// Builds again whatever the latest change affects.
  ///
  /// Only the tiles holding something that has been changed, or that was
  /// changed and has been put back, and only when the changes themselves
  /// change rather than on every frame of a drag.
  void editsChanged() {
    final now = edits.touching(store.waysUsing);
    final affected = {..._hidden, ...now};
    _hidden = now;
    if (affected.isEmpty) {
      onChanged();
      return;
    }

    for (final tile in _built.keys.toList()) {
      final drawn = store.drawnIn(tile);
      if (!drawn.any((e) => affected.contains((e.type, e.id)))) continue;
      final pixels =
          _camera?.pixelsPerTile(tile.zoom) ?? _built[tile]!.pixelsPerTile;
      final report = tessellate(
        store.subsetOf(drawn),
        zoom: tile.zoom,
        pixelsPerTile: pixels,
        into: tile,
        waysThrough: store.waysThrough,
        skip: _isHidden,
      );
      // A tile with everything in it changed builds nothing at all, which is
      // an empty tile rather than a reason to keep the one that is wrong.
      _built[tile] =
          report.tiles[tile] ??
          TileMesh(
            id: tile,
            pixelsPerTile: pixels,
            fills: const [],
            lines: const [],
          );
    }
    onChanged();
  }

  /// Stops the loader waiting to try again, and gives up on anything still
  /// being read.
  void dispose() {
    _resume?.cancel();
    _resume = null;
    for (final tile in _reading.keys.toList()) {
      _abandon(tile);
    }
  }

  /// How many boxes are being read right now.
  int get reading => _reading.length;

  /// Gives up on a box that is still being read.
  void _abandon(TileId tile) {
    final giveUp = _reading.remove(tile);
    if (giveUp != null && !giveUp.isCompleted) giveUp.complete();
  }

  /// The tiles that have been built.
  List<TileMesh> get tiles => _built.values.toList();

  /// How many tiles are waiting to be asked for.
  int get waiting => _queue.length + _running;

  /// How many requests have been made to the API.
  int get requests => api.requests;

  /// Asks for whatever [camera] can see and has not been read yet.
  ///
  /// Safe to call on every frame of a pan: tiles already asked for are not
  /// asked for again, and the queue is replaced rather than added to, so it
  /// always holds what is on screen now rather than everywhere that has been
  /// crossed on the way.
  void look(Camera camera, Size size) {
    _camera = camera;
    _size = size;
    if (stopped != null) return;
    if (camera.zoom < minimumLoadZoom) {
      _queue = [];
      return;
    }

    final centre = Offset(size.width / 2, size.height / 2);
    final wanted =
        [
          for (final tile in camera.tilesFor(size, loadZoom))
            if (!_covered(tile)) tile,
        ]..sort(
          (a, b) => _distance(
            a,
            camera,
            size,
            centre,
          ).compareTo(_distance(b, camera, size, centre)),
        );

    final capped = wanted.take(maximumTilesPerView).toList();
    _spent = 0;
    crowded = false;

    // Boxes being read for somewhere the map has moved off are given up on.
    // The server answers a client at about a fixed rate whatever it is asked,
    // so a box nobody is looking at any more is holding up one that is.
    for (final tile in _reading.keys.toList()) {
      if (!_isVisible(tile, camera)) _abandon(tile);
    }

    // Anything already on disk is drawn straight away and costs the API
    // nothing. Only what is left goes into the queue.
    _queue = [];
    for (final tile in capped) {
      if (cache?.holds(tile) ?? false) {
        if (_asked.add(tile)) unawaited(_fromCache(tile));
      } else {
        _queue.add(tile);
      }
    }
    _pump();
    final remembering = place;
    if (remembering != null) {
      unawaited(LastPlace.write(remembering, camera));
    }
  }

  /// Draws a box from what is held on disk.
  ///
  /// A file that will not read is dropped and the box asked for again, since
  /// the only thing it cost was the reading.
  Future<void> _fromCache(TileId tile) async {
    final elements = await cache!.read(tile);
    if (elements == null) {
      _asked.remove(tile);
      _queue.add(tile);
      _pump();
      return;
    }
    _draw(tile, elements);
  }

  /// Checks what is held against what has been edited, and reads again only
  /// the boxes that have.
  ///
  /// The API carries no entity tag and answers a conditional request with the
  /// whole body, so there is no asking whether a box is still current. What
  /// can be asked is what has been edited over the area since it was read,
  /// which is one request however many boxes are being checked.
  ///
  /// A changeset covers the box around everything in it, so a bot edit
  /// spanning a country marks everything under it as worth reading again.
  /// That costs reads, never correctness.
  Future<void> refresh() async {
    final camera = _camera;
    final held = cache;
    if (camera == null || held == null || stopped != null) return;
    if (camera.zoom < minimumLoadZoom) return;

    final checking = [
      for (final tile in held.tiles)
        if (tile.isStale && _isVisible(tile.id, camera)) tile,
    ];
    if (checking.isEmpty) return;

    final since = checking
        .map((tile) => tile.at)
        .reduce((a, b) => a.isBefore(b) ? a : b);

    final List<OsmChangeset>? changesets;
    try {
      changesets = await api.changesetsIn(
        camera.groundBounds(_size),
        since: since,
      );
    } on OsmHttpException {
      // Not being able to check is not a reason to throw away what is held.
      return;
    }

    for (final tile in checking) {
      // No answer at all means more edits than are worth following, so
      // everything held here is read again rather than patched.
      final touched =
          changesets == null ||
          changesets.any(
            (changeset) => changeset.bounds?.intersects(tile.id.bounds) ?? true,
          );
      if (touched) {
        await _invalidate(tile.id);
      } else {
        await held.markChecked(tile.id);
      }
    }
    look(camera, _size);
  }

  /// Forgets a box so that it is read again from the start.
  ///
  /// What it drew is taken back first. An answer says what is there and never
  /// what has gone, so an element deleted since would otherwise stay on the
  /// map for ever.
  Future<void> _invalidate(TileId tile) async {
    store.release(tile);
    _built.remove(tile);
    _asked.remove(tile);
    await cache?.forget(tile);
  }

  /// How many tiles on screen are drawn at a width that no longer matches
  /// the zoom.
  int get stale => _built.values.where(_isStale).length;

  /// Whether a tile is on screen and drawn at the wrong width.
  ///
  /// A tile that has been scrolled away from is left as it is. Rebuilding it
  /// would be work nobody can see, and it will be rebuilt if it is ever
  /// looked at again.
  bool _isStale(TileMesh mesh) {
    final camera = _camera;
    if (camera == null || !_isVisible(mesh.id, camera)) return false;
    final wanted = camera.pixelsPerTile(mesh.id.zoom);
    return (wanted - mesh.pixelsPerTile).abs() >
        mesh.pixelsPerTile * maximumWidthError;
  }

  /// Rebuilds the lines of tiles whose widths no longer match the zoom, for
  /// as long as [restrokeBudget] allows, and says whether any are left.
  ///
  /// Nearest the middle of the view first, so that what is being looked at
  /// comes right before what is at the edge. Filled shapes are left alone;
  /// only the lines carry a width. Nothing is read again: a tile is built
  /// from the elements it drew, which the store still holds.
  bool restroke() {
    final camera = _camera;
    if (camera == null) return false;

    final stale = _built.values.where(_isStale).toList()
      ..sort(
        (a, b) =>
            _fromCentre(a.id, camera).compareTo(_fromCentre(b.id, camera)),
      );
    if (stale.isEmpty) return false;

    final clock = Stopwatch()..start();
    for (final mesh in stale) {
      final drawn = store.drawnIn(mesh.id);
      if (drawn.isEmpty) continue;
      final wanted = camera.pixelsPerTile(mesh.id.zoom);
      final report = tessellate(
        store.subsetOf(drawn),
        zoom: mesh.id.zoom,
        pixelsPerTile: wanted,
        fills: false,
        into: mesh.id,
        waysThrough: store.waysThrough,
        skip: _isHidden,
      );
      _built[mesh.id] = mesh.withLines(
        report.tiles[mesh.id]?.lines ?? const [],
        wanted,
      );
      if (clock.elapsed > restrokeBudget) break;
    }
    return _built.values.any(_isStale);
  }

  double _fromCentre(TileId tile, Camera camera) {
    final dx = tile.worldX + tile.size / 2 - camera.x;
    final dy = tile.worldY + tile.size / 2 - camera.y;
    return dx * dx + dy * dy;
  }

  bool _isVisible(TileId tile, Camera camera) {
    if (_size.isEmpty) return false;
    final view = camera.worldBounds(_size);
    return tile.worldX < view.right &&
        tile.worldX + tile.size > view.left &&
        tile.worldY < view.bottom &&
        tile.worldY + tile.size > view.top;
  }

  /// Whether a tile's ground has already been asked for.
  bool _covered(TileId tile) => _asked.contains(tile);

  /// How far a tile's middle is from the middle of the view, so that what is
  /// being looked at arrives before what is at the edge.
  double _distance(TileId tile, Camera camera, Size size, Offset centre) {
    final middle = camera.toScreen(
      tile.worldX + tile.size / 2,
      tile.worldY + tile.size / 2,
      size,
    );
    return (middle - centre).distanceSquared;
  }

  void _pump() {
    while (_running < maximumInFlight && _queue.isNotEmpty) {
      if (_spent >= maximumRequestsPerView) {
        // Everything this view was allowed has been spent, most of it on
        // splitting boxes that held too much. What is left goes unread.
        crowded = true;
        _queue = [];
        return;
      }
      final tile = _queue.removeAt(0);
      if (!_asked.add(tile)) continue;
      _spent += 1;
      _running += 1;
      _load(tile).whenComplete(() {
        _running -= 1;
        _pump();
      });
    }
  }

  Future<void> _load(TileId tile, {int split = 0}) async {
    final giveUp = Completer<void>();
    _reading[tile] = giveUp;
    try {
      final elements = await api.map(
        tile.bounds,
        abandon: giveUp.future,
        // Given up on, but the server had already begun answering. The work
        // is done and the box will be wanted again the moment the map comes
        // back to it, so it is kept even though nobody waited for it.
        onLate: (late) => unawaited(_keep(tile, late)),
      );
      _draw(tile, elements);
      await cache?.write(tile, elements);
    } on OsmAbandonedException {
      // The map moved off it. Not a failure, and not a box that has been
      // read, so it is asked for again if it comes back into view.
      _asked.remove(tile);
    } on OsmTooMuchDataException {
      // The box holds more than the API will hand over at once. Its quarters
      // each hold a quarter as much, so ask for those instead, for as long as
      // this view has any budget left to spend on it.
      if (split >= maximumSplits) {
        crowded = true;
        return;
      }
      for (final child in tile.children) {
        if (_spent >= maximumRequestsPerView) {
          crowded = true;
          return;
        }
        if (_asked.add(child)) {
          _spent += 1;
          _running += 1;
          unawaited(
            _load(child, split: split + 1).whenComplete(() {
              _running -= 1;
              _pump();
            }),
          );
        }
      }
    } on OsmHttpException catch (e) {
      _pause('the API answered ${e.status}', tile);
    } on IOException catch (e) {
      // A dropped connection, a name that would not resolve, a refused
      // socket. The fetch has already tried several times over about a
      // minute, so the network is genuinely away rather than blinking.
      _pause('${e.runtimeType}', tile);
    } finally {
      _reading.remove(tile);
    }
  }

  /// Keeps a box that arrived after it stopped being waited for.
  ///
  /// Written to disk but not drawn: the map has moved off it, and it is taken
  /// off the list of boxes already asked for so that coming back to it reads
  /// it from disk rather than from the API.
  Future<void> _keep(TileId tile, List<OsmElement> elements) async {
    await cache?.write(tile, elements);
    _asked.remove(tile);
    onChanged();
  }

  /// Stops asking for a while, and picks up where it left off afterwards.
  ///
  /// Being turned away says the server is busy now, not that it will be busy
  /// for ever, so the queue is dropped rather than the loader. [tile] is put
  /// back so that it is asked for again rather than left as a hole: a box
  /// that was asked for and never answered has not been read.
  void _pause(String why, TileId tile) {
    _asked.remove(tile);
    stopped = why;
    _queue = [];
    onChanged();

    _resume?.cancel();
    _resume = Timer(retryDelay, () {
      stopped = null;
      onChanged();
      final camera = _camera;
      if (camera != null) look(camera, _size);
    });
  }

  void _draw(TileId tile, List<OsmElement> elements) {
    // Everything is held together, so a way along the edge of this tile that
    // reaches into the next one still has its nodes. Only what no earlier
    // tile already drew is built, which is what keeps the seams from being
    // drawn twice.
    final fresh = store.add(tile, elements);
    if (fresh.isEmpty) {
      onChanged();
      return;
    }
    final camera = _camera;
    final report = tessellate(
      store.subsetOf(fresh),
      zoom: tile.zoom,
      pixelsPerTile: camera?.pixelsPerTile(tile.zoom) ?? tilePixels,
      into: tile,
      // From everything held rather than everything in this box, so that two
      // roads meeting just over its edge are still a junction.
      waysThrough: store.waysThrough,
      skip: _isHidden,
    );
    final mesh = report.tiles[tile];
    if (mesh != null) _built[tile] = mesh;
    onChanged();
  }
}
