import 'dart:math' as math;
import 'dart:ui';

import 'package:osm/osm.dart';

import '../geometry/mercator.dart';
import '../geometry/tile.dart';

/// Where the map is being looked at from.
///
/// The centre is held in world coordinates rather than degrees so that
/// panning is a plain subtraction, and the zoom is continuous rather than
/// stepped so that pinching is smooth.
class Camera {
  /// The world x at the middle of the view.
  final double x;

  /// The world y at the middle of the view.
  final double y;

  /// How far in the map is zoomed, where the whole world is [tilePixels]
  /// across at zoom 0 and twice that at zoom 1.
  final double zoom;

  /// Creates a camera.
  const Camera({required this.x, required this.y, required this.zoom});

  /// A camera looking at a place on the earth.
  factory Camera.at({
    required double latitude,
    required double longitude,
    required double zoom,
  }) => Camera(x: Mercator.x(longitude), y: Mercator.y(latitude), zoom: zoom);

  /// How many pixels one world unit covers.
  double get scale => tilePixels * math.pow(2, zoom).toDouble();

  /// The latitude at the middle of the view.
  double get latitude => Mercator.latitude(y);

  /// The longitude at the middle of the view.
  double get longitude => Mercator.longitude(x);

  /// Where world position ([worldX], [worldY]) falls on a view of [size].
  Offset toScreen(double worldX, double worldY, Size size) => Offset(
    (worldX - x) * scale + size.width / 2,
    (worldY - y) * scale + size.height / 2,
  );

  /// The world position under [point] on a view of [size].
  Offset toWorld(Offset point, Size size) => Offset(
    (point.dx - size.width / 2) / scale + x,
    (point.dy - size.height / 2) / scale + y,
  );

  /// The part of the world a view of [size] shows.
  Rect worldBounds(Size size) {
    final topLeft = toWorld(Offset.zero, size);
    final bottomRight = toWorld(Offset(size.width, size.height), size);
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// The ground a view of [size] shows, which is what the API is asked
  /// about.
  OsmBounds groundBounds(Size size) {
    final view = worldBounds(size);
    return OsmBounds(
      minLatitude: Mercator.latitude(view.bottom.clamp(0.0, 1.0)),
      minLongitude: Mercator.longitude(view.left.clamp(0.0, 1.0)),
      maxLatitude: Mercator.latitude(view.top.clamp(0.0, 1.0)),
      maxLongitude: Mercator.longitude(view.right.clamp(0.0, 1.0)),
    );
  }

  /// The tiles at [zoom] needed to cover a view of [size].
  List<TileId> tilesFor(Size size, int tileZoom) {
    final bounds = worldBounds(size);
    final across = 1 << tileZoom;
    final left = (bounds.left * across).floor().clamp(0, across - 1);
    final right = (bounds.right * across).ceil().clamp(0, across);
    final top = (bounds.top * across).floor().clamp(0, across - 1);
    final bottom = (bounds.bottom * across).ceil().clamp(0, across);
    return [
      for (var ty = top; ty < bottom; ty++)
        for (var tx = left; tx < right; tx++) TileId(tileZoom, tx, ty),
    ];
  }

  /// How wide a tile at [tileZoom] is on screen, which is what line widths
  /// have to be built for.
  double pixelsPerTile(int tileZoom) =>
      tilePixels * math.pow(2, zoom - tileZoom).toDouble();

  /// This camera moved by [delta] pixels on screen.
  Camera panned(Offset delta) =>
      Camera(x: x - delta.dx / scale, y: y - delta.dy / scale, zoom: zoom);

  /// This camera zoomed by [by] levels, keeping [focus] on a view of [size]
  /// over the same place on the ground.
  Camera zoomed(double by, Offset focus, Size size) {
    final anchor = toWorld(focus, size);
    final moved = Camera(x: x, y: y, zoom: (zoom + by).clamp(minZoom, maxZoom));
    final after = moved.toWorld(focus, size);
    return Camera(
      x: moved.x + anchor.dx - after.dx,
      y: (moved.y + anchor.dy - after.dy).clamp(0.0, 1.0),
      zoom: moved.zoom,
    );
  }

  /// The furthest the map zooms out, where the world is one tile across.
  static const minZoom = 0.0;

  /// The closest the map zooms in, past which there is nothing more to see.
  static const maxZoom = maximumZoom;

  @override
  String toString() =>
      'Camera(${latitude.toStringAsFixed(5)}, '
      '${longitude.toStringAsFixed(5)}, z${zoom.toStringAsFixed(2)})';
}
