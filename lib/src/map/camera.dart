import 'dart:math' as math;
import 'dart:ui';

import 'package:osm/osm.dart';

/// How large a tile is on screen at its own zoom level.
const tilePixels = 256.0;

/// Where the map is being looked at from.
///
/// The centre is held in world coordinates rather than degrees so that
/// panning is a plain subtraction, and the zoom is continuous rather than
/// stepped so that pinching is smooth.
///
/// The world goes round east to west, so the centre is always brought back
/// onto it and everything is drawn at whichever of its copies is nearest the
/// centre: panning east past the antimeridian carries on into the far east
/// of Russia rather than off the end of the map. North to south it stops, at
/// the edge of the square the world is drawn on.
class Camera {
  /// The world x at the middle of the view.
  final double x;

  /// The world y at the middle of the view.
  final double y;

  /// How far in the map is zoomed, where the whole world is [tilePixels]
  /// across at zoom 0 and twice that at zoom 1.
  final double zoom;

  /// Creates a camera over world ([x], [y]), which is brought back onto the
  /// world.
  Camera({required double x, required double y, required this.zoom})
    : x = Mercator.wrap(x),
      y = y.clamp(0.0, 1.0);

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

  /// Where world position ([worldX], [worldY]) falls on a view of [size], at
  /// whichever of its copies round the world is nearest the middle.
  Offset toScreen(double worldX, double worldY, Size size) => Offset(
    (Mercator.nearest(worldX, x) - x) * scale + size.width / 2,
    (worldY - y) * scale + size.height / 2,
  );

  /// Where the north west corner of [tile] falls on a view of [size], at
  /// whichever of the tile's copies round the world is nearest the middle.
  ///
  /// By the tile's middle, not its corner: a tile far out is much of the
  /// world across, and the copy of its corner nearest the middle need not
  /// be the corner of the copy of the tile that is.
  Offset tileToScreen(OsmTile tile, Size size) {
    final half = tile.size / 2;
    final middle = toScreen(tile.worldX + half, tile.worldY + half, size);
    return middle - Offset(half * scale, half * scale);
  }

  /// The world position under [point] on a view of [size].
  ///
  /// Not brought back onto the world, so that positions either side of the
  /// antimeridian on the same view are still next to each other. Anything
  /// put there has to be brought back first, by [Mercator.wrappedLongitude].

  Offset toWorld(Offset point, Size size) => Offset(
    (point.dx - size.width / 2) / scale + x,
    (point.dy - size.height / 2) / scale + y,
  );

  /// The part of the world a view of [size] shows, which runs past 0 or 1
  /// when it is across the antimeridian.
  Rect worldBounds(Size size) {
    final topLeft = toWorld(Offset.zero, size);
    final bottomRight = toWorld(Offset(size.width, size.height), size);
    return Rect.fromPoints(topLeft, bottomRight);
  }

  /// The ground a view of [size] shows, which is what the API is asked
  /// about.
  ///
  /// Two boxes when the view is across the antimeridian, one either side of
  /// it, since a box on the ground cannot go round the back of the world.
  List<OsmBounds> groundBounds(Size size) {
    final view = worldBounds(size);
    final minLatitude = Mercator.latitude(view.bottom.clamp(0.0, 1.0));
    final maxLatitude = Mercator.latitude(view.top.clamp(0.0, 1.0));
    OsmBounds box(double left, double right) => OsmBounds(
      minLatitude: minLatitude,
      minLongitude: Mercator.longitude(left),
      maxLatitude: maxLatitude,
      maxLongitude: Mercator.longitude(right),
    );
    if (view.width >= 1) return [box(0, 1)];
    final left = Mercator.wrap(view.left);
    final right = left + view.width;
    if (right <= 1) return [box(left, right)];
    return [box(left, 1), box(0, right - 1)];
  }

  /// The tiles at [zoom] needed to cover a view of [size].
  ///
  /// [margin] adds rings of tiles beyond the edges, for asking for what is
  /// about to be scrolled into view rather than once it already has been.
  List<OsmTile> tilesFor(Size size, int tileZoom, {int margin = 0}) {
    final bounds = worldBounds(size);
    final across = 1 << tileZoom;
    // Columns go round the world, and a view wider than it wants each only
    // once. Rows stop at the top and bottom.
    var left = (bounds.left * across).floor() - margin;
    var right = (bounds.right * across).ceil() + margin;
    if (right - left > across) {
      left = 0;
      right = across;
    }
    final top = ((bounds.top * across).floor() - margin).clamp(0, across - 1);
    final bottom = ((bounds.bottom * across).ceil() + margin).clamp(0, across);
    return [
      for (var ty = top; ty < bottom; ty++)
        for (var tx = left; tx < right; tx++)
          OsmTile(tileZoom, tx % across, ty),
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
      y: moved.y + anchor.dy - after.dy,
      zoom: moved.zoom,
    );
  }

  /// The furthest the map zooms out, where the world is one tile across.
  static const minZoom = 0.0;

  /// The closest the map zooms in, past which there is nothing more to see.
  static const maxZoom = 22.0;

  @override
  String toString() =>
      'Camera(${latitude.toStringAsFixed(5)}, '
      '${longitude.toStringAsFixed(5)}, z${zoom.toStringAsFixed(2)})';
}
