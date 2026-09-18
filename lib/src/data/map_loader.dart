import 'dart:async';
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';
import '../render/tessellate.dart';
import '../render/tile_mesh.dart';
import 'map_store.dart';

/// How far in the map has to be before anything is asked for.
///
/// Further out than this a view covers more ground than the API will answer
/// for, and more detail than anyone could read. The same threshold every
/// other editor draws: below it the map shows what has already been read and
/// asks for nothing.
const minimumLoadZoom = 16.0;

/// The zoom the map is asked for at.
///
/// A tile this size is a few hundred metres across, which is small enough to
/// come back quickly and to stay well inside what the API will answer with at
/// once, and large enough that a screenful is tens of requests rather than
/// hundreds.
const loadZoom = 16;

/// The most tiles that will be asked for to fill one view.
///
/// A guard rather than a target. Reaching it means something is wrong with
/// the view being asked about, and asking for less is the safe way to be
/// wrong.
const maximumTilesPerView = 48;

/// How many requests this map has outstanding at once.
///
/// The fetch keeps its own count as well; this one is what keeps the queue
/// short enough to throw away when the view moves.
const maximumInFlight = 2;

/// How far a tile will be split when the API says it holds too much.
const maximumSplits = 2;

/// How far a line's width may drift from what the style asks for before it is
/// built again.
///
/// A line is a fixed number of pixels wide whatever the zoom, but its width
/// is baked into its triangles, so zooming stretches it. A tenth is under a
/// pixel on any line the style draws, which is not something anyone can pick
/// out mid-gesture, and it keeps a pinch from rebuilding the screen twice.
const maximumWidthError = 0.1;

/// How long is spent rebuilding line widths in one go.
///
/// Rebuilding happens on the interface thread, between frames, so it is
/// bounded rather than run to completion: a tile or two catch up each frame
/// and the rest follow. A tile costs a few milliseconds, so this is a quarter
/// of a frame's work at sixty a second, leaving the rest of the frame alone
/// on a machine slower than the one it was measured on.
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

  /// Everything read so far.
  final MapStore store = MapStore();

  /// Called whenever there is something new to draw.
  final void Function() onChanged;

  final _built = <TileId, TileMesh>{};
  final _claimed = <TileId, List<OsmElement>>{};
  final _asked = <TileId>{};
  var _queue = <TileId>[];
  var _running = 0;
  Camera? _camera;
  Size _size = Size.zero;

  /// Why loading stopped, or null while it has not.
  String? stopped;

  /// Creates a loader.
  MapLoader({required this.api, required this.onChanged});

  /// The tiles that have been built.
  List<TileMesh> get tiles => _built.values.toList();

  /// How many tiles are waiting to be asked for.
  int get waiting => _queue.length + _running;

  /// How many requests have been made to the API.
  int get requests => api.requests;

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

  bool _isVisible(TileId tile, Camera camera) {
    if (_size.isEmpty) return false;
    final view = camera.worldBounds(_size);
    return tile.worldX < view.right &&
        tile.worldX + tile.size > view.left &&
        tile.worldY < view.bottom &&
        tile.worldY + tile.size > view.top;
  }

  /// Rebuilds the lines of tiles whose widths no longer match the zoom, for
  /// as long as [restrokeBudget] allows, and says whether any are left.
  ///
  /// Nearest the middle of the view first, so that what is being looked at
  /// comes right before what is at the edge. Filled shapes are left alone;
  /// only the lines carry a width.
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
      final claimed = _claimed[mesh.id];
      if (claimed == null) continue;
      final wanted = camera.pixelsPerTile(mesh.id.zoom);
      final report = tessellate(
        store.subsetOf(claimed),
        zoom: mesh.id.zoom,
        pixelsPerTile: wanted,
        fills: false,
        into: mesh.id,
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
            if (!_asked.contains(tile)) tile,
        ]..sort(
          (a, b) => _distance(
            a,
            camera,
            size,
            centre,
          ).compareTo(_distance(b, camera, size, centre)),
        );

    _queue = wanted.take(maximumTilesPerView).toList();
    _pump();
  }

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
      final tile = _queue.removeAt(0);
      if (!_asked.add(tile)) continue;
      _running += 1;
      _load(tile).whenComplete(() {
        _running -= 1;
        _pump();
      });
    }
  }

  Future<void> _load(TileId tile, {int split = 0}) async {
    try {
      final elements = await api.map(tile.bounds);
      _draw(tile, elements);
    } on OsmTooMuchDataException {
      // The box holds more than the API will hand over at once. Its quarters
      // each hold a quarter as much, so ask for those instead.
      if (split >= maximumSplits) return;
      for (final child in tile.children) {
        if (_asked.add(child)) {
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
      // The server has had enough, or is not there. Asking again is the wrong
      // thing to do, so nothing more is asked for at all.
      stopped = 'the API answered ${e.status}';
      _queue = [];
      onChanged();
    }
  }

  void _draw(TileId tile, List<OsmElement> elements) {
    // Everything is held together, so a way along the edge of this tile that
    // reaches into the next one still has its nodes. Only what no earlier
    // tile already drew is built, which is what keeps the seams from being
    // drawn twice.
    final fresh = store.add(elements);
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
    );
    final mesh = report.tiles[tile];
    if (mesh != null) {
      _built[tile] = mesh;
      // Kept so the lines can be built again at another zoom without asking
      // the API a second time. These are references into the store, not
      // copies of it.
      _claimed[tile] = fresh;
    }
    onChanged();
  }
}
