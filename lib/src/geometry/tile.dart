import 'mercator.dart';

/// A square of the world at one zoom level, in the standard tile numbering.
///
/// Tiles are the unit the map is built and thrown away in. Geometry is
/// tessellated per tile, cached per tile, and evicted per tile, so the work
/// and the memory both stay proportional to what is on screen rather than to
/// how much of the world has been visited.
class TileId {
  /// The zoom level, where the world is `1 << zoom` tiles across.
  final int zoom;

  /// The column, counting east from the antimeridian.
  final int x;

  /// The row, counting south from the northern limit.
  final int y;

  /// Creates a tile reference.
  const TileId(this.zoom, this.x, this.y);

  /// The tile at [zoom] holding the world position ([worldX], [worldY]).
  factory TileId.of(int zoom, double worldX, double worldY) {
    final across = 1 << zoom;
    return TileId(
      zoom,
      (worldX * across).floor().clamp(0, across - 1),
      (worldY * across).floor().clamp(0, across - 1),
    );
  }

  /// The tile holding ([latitude], [longitude]) at [zoom].
  factory TileId.at(int zoom, double latitude, double longitude) =>
      TileId.of(zoom, Mercator.x(longitude), Mercator.y(latitude));

  /// The side of the tile in world units.
  double get size => 1 / (1 << zoom);

  /// The world x of the tile's western edge.
  double get worldX => x * size;

  /// The world y of the tile's northern edge.
  double get worldY => y * size;

  @override
  bool operator ==(Object other) =>
      other is TileId && other.zoom == zoom && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(zoom, x, y);

  @override
  String toString() => '$zoom/$x/$y';
}

/// The side of a tile in the local coordinates geometry is stored in.
///
/// Positions are held relative to their tile and as 32 bit floats, which only
/// carry about seven digits. Spread over the whole world that would land
/// vertices metres from where they belong; spread over one tile it is well
/// under a millimetre. The value matches the extent vector tiles use.
const tileExtent = 4096.0;
