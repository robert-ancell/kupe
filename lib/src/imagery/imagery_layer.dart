import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';

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

/// How many rings of tiles beyond the view are fetched.
///
/// Imagery comes from servers built to hand out a great deal of it, and a
/// ring of tiles already in hand is the difference between a map that slides
/// and one that fills itself in behind the drag.
const imageryMargin = 1;

/// How far in a tile is looked for to stand in for one that has not arrived.
///
/// Zooming out leaves the finer tiles held and the coarser one not, so the
/// pieces of it that are held are drawn in its place. Two levels is sixteen
/// pieces, which is as much looking about as is worth doing.
const imageryFinerLevels = 2;

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
  /// Where the tiles come from, and where they are kept.
  final OsmImageryTiles tiles;

  /// Turns a fetched tile into something that can be drawn.
  final Future<T> Function(Uint8List bytes) decode;

  /// Lets go of a decoded tile that is no longer held.
  final void Function(T image) release;

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
    required this.tiles,
    required this.decode,
    required this.release,
    required this.onChanged,
    this.inFlight = 6,
  });

  /// Which layer is being drawn.
  OsmImagery get source => tiles.source;

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
    final wanted = camera.tilesFor(size, zoom, margin: imageryMargin);
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
        if (!_missing.contains(tile) &&
            !tiles.isEmptyAt(tile) &&
            !_reading.containsKey(tile))
          // A tile already decoded needs nothing unless what it was decoded
          // from has aged, in which case it is drawn while a newer one is
          // fetched over the top of it.
          if (!_images.containsKey(tile) || tiles.isStaleAt(tile)) tile,
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
      if (_coarserFor(pieces, tile)) continue;
      // Nothing coarser held either. Zooming out is the other way round: the
      // finer tiles are the ones in hand, so whatever pieces of this tile are
      // held are drawn in its place.
      _finerFor(pieces, tile, imageryFinerLevels);
    }
    return pieces;
  }

  /// Adds the tile itself if it is held, or the closest coarser one that is.
  bool _coarserFor(List<ImageryPiece<T>> pieces, TileId tile) {
    var from = tile;
    for (var level = 0; level <= imageryFallbackLevels; level++) {
      final image = _touch(from);
      if (image != null) {
        pieces.add(ImageryPiece(tile, from, image));
        return true;
      }
      if (from.zoom == 0) return false;
      from = from.parent;
    }
    return false;
  }

  /// Adds whichever pieces of [tile] are held, each drawn in its own place.
  void _finerFor(List<ImageryPiece<T>> pieces, TileId tile, int levels) {
    if (levels == 0) return;
    for (final child in tile.children) {
      final image = _touch(child);
      if (image != null) {
        pieces.add(ImageryPiece(child, child, image));
      } else {
        _finerFor(pieces, child, levels - 1);
      }
    }
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
      final body = await tiles.tile(
        tile,
        abandon: abandon,
        // Held but old: drawn at once, with a newer one fetched behind it.
        onHeld: (held) => unawaited(_store(tile, held)),
        // Given up on, but already on its way. Kept, since the view is
        // likely to come back to it.
        onLate: (late) => unawaited(_store(tile, late)),
      );
      if (body == null) {
        // Ground the source has nothing for. Asking again will not help.
        _missing.add(tile);
      } else {
        await _store(tile, body);
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
