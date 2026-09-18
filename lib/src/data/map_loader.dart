import 'dart:async';
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';
import '../render/tessellate.dart';
import '../render/tile_mesh.dart';
import 'map_store.dart';

/// How far out the map still reads data.
///
/// Further out than this a view covers so much ground that reading it would
/// be a bulk download whatever it is cut into. Other editors stop sooner:
/// iD reads nothing below zoom 16 and Vespucci below 17. Kupe goes further
/// out because what matters is how much comes back, not how far out the
/// camera is, and how much comes back is guarded directly below.
const minimumLoadZoom = 13.0;

/// The finest zoom a box is asked for at.
///
/// A tile this size is a few hundred metres across, which comes back quickly
/// and stays well inside what the API will answer with at once. The same
/// zoom iD asks at.
const finestRequestZoom = 16;

/// The coarsest zoom a box is asked for at.
///
/// Held above [minimumLoadZoom] would mean thousands of tiny requests to
/// cover a zoomed out view. Asking at the zoom being looked at instead keeps
/// the count of requests roughly the same however far out the map is, and
/// leaves how much ground each one covers to the guard below.
const coarsestRequestZoom = 13;

/// The most tiles that will be asked for to fill one view.
///
/// This is the real limit. A view needs about the same number of tiles at
/// every zoom, because the tiles grow as the map zooms out, so this bounds
/// what one screenful costs wherever it is pointed.
const maximumTilesPerView = 48;

/// The most requests one view may cost in total, splitting included.
///
/// A coarse tile over a city holds far more than the API will answer with, so
/// it is asked for in quarters, and those may be too much in turn. Without a
/// ceiling a single zoomed out look at Tokyo would fan out into hundreds of
/// requests. Reaching this means there is too much here to show at this zoom,
/// which the map says rather than quietly reading half of it.
const maximumRequestsPerView = 96;

/// How many requests this map has outstanding at once.
///
/// The fetch keeps its own count as well; this one is what keeps the queue
/// short enough to throw away when the view moves. iD sets no limit at all
/// and lets the browser decide; this stays well under that.
const maximumInFlight = 4;

/// How far a tile will be split when the API says it holds too much.
///
/// Enough for the coarsest request to reach the finest: a zoom 13 box that is
/// too much can come down to zoom 16 a quarter at a time.
const maximumSplits = finestRequestZoom - coarsestRequestZoom;

/// The zoom boxes are asked for at when looking through [camera].
///
/// Tracking the camera keeps the number of tiles a view needs about the same
/// at every zoom, rather than growing fourfold each time the map zooms out.
int requestZoomFor(Camera camera) =>
    camera.zoom.round().clamp(coarsestRequestZoom, finestRequestZoom);

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
  final _asked = <TileId>{};
  var _queue = <TileId>[];
  var _running = 0;

  /// Why loading stopped, or null while it has not.
  String? stopped;

  /// Whether the view holds more than can be read at this zoom.
  ///
  /// Set when splitting a box runs out of budget, which means there is too
  /// much here to show all of. Cleared by looking somewhere else or by
  /// zooming in, which both make the boxes smaller.
  bool crowded = false;

  var _spent = 0;

  /// Creates a loader.
  MapLoader({required this.api, required this.onChanged});

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
    if (stopped != null) return;
    if (camera.zoom < minimumLoadZoom) {
      _queue = [];
      return;
    }

    final centre = Offset(size.width / 2, size.height / 2);
    final wanted =
        [
          for (final tile in camera.tilesFor(size, requestZoomFor(camera)))
            if (!_covered(tile)) tile,
        ]..sort(
          (a, b) => _distance(
            a,
            camera,
            size,
            centre,
          ).compareTo(_distance(b, camera, size, centre)),
        );

    _queue = wanted.take(maximumTilesPerView).toList();
    _spent = 0;
    crowded = false;
    _pump();
  }

  /// Whether a tile's ground has already been read, by itself or by a coarser
  /// box that swallowed it.
  ///
  /// Zooming in after a coarse look must not read the same ground again in
  /// smaller pieces, so the boxes already asked for are checked all the way
  /// out, not just at the zoom being asked at now.
  bool _covered(TileId tile) {
    var at = tile;
    while (true) {
      if (_asked.contains(at)) return true;
      if (at.zoom <= coarsestRequestZoom) return false;
      at = at.parent;
    }
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
    try {
      final elements = await api.map(tile.bounds);
      _draw(tile, elements);
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
    final report = tessellate(
      store.subsetOf(fresh),
      zoom: tile.zoom,
      into: tile,
    );
    final mesh = report.tiles[tile];
    if (mesh != null) _built[tile] = mesh;
    onChanged();
  }
}
