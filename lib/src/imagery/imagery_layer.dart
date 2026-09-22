import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';
import 'imagery_cache.dart';

/// How many decoded tiles are held.
///
/// A tile is 256 pixels square, a quarter of a megabyte once decoded, so this
/// is about forty megabytes: enough for a large screen several times over,
/// so panning back and forth does not fetch anything twice.
const maximumImageryTiles = 160;

/// How far out a tile is looked for to stand in for one that has not arrived.
///
/// Four levels is a tile sixteen times too coarse, which is blurry but far
/// better than a blank square while the right one loads.
const imageryFallbackLevels = 4;

/// Part of the view, and the tile that fills it.
///
/// [image] is the tile of [from], which is either [tile] itself or a coarser
/// one holding it, whose matching part stands in until the right one comes.
class ImageryPiece<T extends Object> {
  /// Where on the map this is drawn.
  final TileId tile;

  /// Which tile [image] is of.
  final TileId from;

  /// The picture.
  final T image;

  /// Creates a piece.
  const ImageryPiece(this.tile, this.from, this.image);
}

/// Background imagery for the view, fetched a tile at a time.
///
/// Much like the map data: only what is on screen is asked for, the middle
/// first, and a tile scrolled off is given up on. Unlike the map data the
/// servers are content delivery networks built for this, so more is asked for
/// at once.
class ImageryLayer<T extends Object> {
  /// Where the tiles come from.
  final OsmImagery source;

  /// How they are fetched.
  final OsmFetch fetch;

  /// Turns a fetched tile into something that can be drawn.
  final Future<T> Function(Uint8List bytes) decode;

  /// Lets go of a decoded tile that is no longer held.
  final void Function(T image) release;

  /// Where tiles are kept between runs, if anywhere.
  final ImageryCache? cache;

  /// Called whenever a tile arrives.
  final void Function() onChanged;

  /// How many tiles are fetched at once.
  final int inFlight;

  // Oldest looked at first, which makes the first one the one to drop.
  final _images = <TileId, T>{};
  final _missing = <TileId>{};
  final _reading = <TileId, Completer<void>>{};
  var _queue = <TileId>[];

  /// Creates a layer.
  ImageryLayer({
    required this.source,
    required this.fetch,
    required this.decode,
    required this.release,
    required this.onChanged,
    this.cache,
    this.inFlight = 6,
  });

  /// How many tiles are held.
  int get held => _images.length;

  /// How many tiles are being fetched.
  int get reading => _reading.length;

  /// The zoom whose tiles are drawn when looking through [camera].
  ///
  /// The nearest one, so a tile is never drawn at less than about seven
  /// tenths or more than about one and a half times its own size. Closer in
  /// than the source goes, its closest tiles are stretched.
  int zoomFor(Camera camera) =>
      camera.zoom.round().clamp(source.minimumZoom, source.maximumZoom);

  /// Asks for the tiles [camera] can see, giving up on any it no longer can.
  void look(Camera camera, Size size) {
    final zoom = zoomFor(camera);
    final wanted = camera.tilesFor(size, zoom);
    final centre = Offset(camera.x, camera.y);
    wanted.sort(
      (a, b) => _fromCentre(a, centre).compareTo(_fromCentre(b, centre)),
    );

    final showing = wanted.toSet();
    for (final tile in _reading.keys.toList()) {
      if (!showing.contains(tile)) _abandon(tile);
    }
    _queue = [
      for (final tile in wanted)
        if (!_missing.contains(tile) && !_reading.containsKey(tile))
          // A tile already decoded needs nothing unless what it was decoded
          // from has aged, in which case it is drawn while a newer one is
          // fetched over the top of it.
          if (!_images.containsKey(tile) ||
              (cache?.entry(tile)?.isStale ?? false))
            tile,
    ];
    _pump();
  }

  /// What to draw for each tile [camera] can see.
  ///
  /// A tile that has not arrived is stood in for by the closest coarser one
  /// that has, and a tile with nothing held for it at all is left out.
  List<ImageryPiece<T>> piecesFor(Camera camera, Size size) {
    final pieces = <ImageryPiece<T>>[];
    for (final tile in camera.tilesFor(size, zoomFor(camera))) {
      var from = tile;
      for (var level = 0; level <= imageryFallbackLevels; level++) {
        final image = _touch(from);
        if (image != null) {
          pieces.add(ImageryPiece(tile, from, image));
          break;
        }
        if (from.zoom == 0) break;
        from = from.parent;
      }
    }
    return pieces;
  }

  /// Lets go of every tile and gives up on everything being fetched.
  void dispose() {
    for (final tile in _reading.keys.toList()) {
      _abandon(tile);
    }
    _queue = [];
    for (final image in _images.values) {
      release(image);
    }
    _images.clear();
  }

  /// The image held for [tile], marking it as the one looked at last.
  T? _touch(TileId tile) {
    final image = _images.remove(tile);
    if (image != null) _images[tile] = image;
    return image;
  }

  double _fromCentre(TileId tile, Offset centre) {
    final dx = tile.worldX + tile.size / 2 - centre.dx;
    final dy = tile.worldY + tile.size / 2 - centre.dy;
    return dx * dx + dy * dy;
  }

  void _pump() {
    while (_reading.length < inFlight && _queue.isNotEmpty) {
      final tile = _queue.removeAt(0);
      final giveUp = Completer<void>();
      _reading[tile] = giveUp;
      unawaited(_load(tile, giveUp.future));
    }
  }

  void _abandon(TileId tile) {
    final giveUp = _reading.remove(tile);
    if (giveUp != null && !giveUp.isCompleted) giveUp.complete();
  }

  Future<void> _load(TileId tile, Future<void> abandon) async {
    try {
      // What is on disk is drawn before anything is asked for, so a map that
      // has been looked at before is there the moment it opens.
      final held = cache?.entry(tile);
      if (held != null && !_images.containsKey(tile)) {
        if (held.missing) {
          _missing.add(tile);
          return;
        }
        final kept = await cache!.read(tile);
        if (kept != null) {
          await _store(tile, kept);
          // Aerial imagery is reflown in years, so a tile within its week is
          // taken as current and nothing is asked for at all.
          if (!held.isStale) return;
        }
      }

      final bytes = await fetch(
        Uri.parse(source.tileUrl(tile.zoom, tile.x, tile.y)),
        abandon: abandon,
        // Already on its way when it was given up on. It is a few kilobytes
        // and the view may well come back to it, so it is kept.
        onLate: (late) => unawaited(_keep(tile, late)),
      );
      if (bytes == null) {
        // Outside the ground the source covers. Asking again will not help,
        // now or on the next run.
        _missing.add(tile);
        await cache?.markMissing(tile);
      } else {
        await _store(tile, bytes);
        await cache?.write(tile, bytes);
      }
    } on OsmAbandonedException {
      // Scrolled off; asked for again if it comes back.
    } on IOException {
      // Asked for again next time the view settles.
    } on Exception {
      // Not a picture that would decode. Asked for again next time.
    } finally {
      _reading.remove(tile);
      _pump();
    }
  }

  /// Keeps a tile that arrived after it stopped being waited for.
  Future<void> _keep(TileId tile, Uint8List bytes) async {
    await _store(tile, bytes);
    await cache?.write(tile, bytes);
  }

  Future<void> _store(TileId tile, Uint8List bytes) async {
    final image = await decode(bytes);
    final replaced = _images.remove(tile);
    if (replaced != null) release(replaced);
    _images[tile] = image;
    while (_images.length > maximumImageryTiles) {
      final oldest = _images.keys.first;
      release(_images.remove(oldest)!);
    }
    onChanged();
  }
}
