import 'package:osm/osm.dart';

/// A square of the world at one zoom level.
///
/// The numbering itself is [OsmTile], since it is what every OpenStreetMap
/// tile service uses and nothing about it is to do with drawing. Tiles are
/// the unit the map is built and thrown away in: geometry is tessellated per
/// tile, cached per tile, and evicted per tile, so the work and the memory
/// both stay proportional to what is on screen rather than to how much of
/// the world has been visited.
typedef TileId = OsmTile;

/// How large a tile is on screen at its own zoom level.
const tilePixels = 256.0;

/// The closest the map is ever drawn at.
///
/// Geometry is built once and never again, so anything that has to be cut up
/// into straight edges is cut finely enough for the closest look it will ever
/// get rather than for the zoom it happened to be built at.
const maximumZoom = 22.0;

/// The side of a tile in the local coordinates geometry is stored in.
///
/// Positions are held relative to their tile and as 32 bit floats, which only
/// carry about seven digits. Spread over the whole world that would land
/// vertices metres from where they belong; spread over one tile it is well
/// under a millimetre. The value matches the extent vector tiles use.
const tileExtent = 4096.0;
