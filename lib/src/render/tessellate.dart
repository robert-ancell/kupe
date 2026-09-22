import 'dart:math' as math;
import 'dart:typed_data';

import 'package:osm/osm.dart';

import '../geometry/tile.dart';
import '../style/style.dart';
import 'stroke.dart';
import 'tile_mesh.dart';
import 'triangulate.dart';

/// What was built, and what it cost, for one pass over a dataset.
class TessellationReport {
  /// The tiles built, by id.
  final Map<TileId, TileMesh> tiles;

  /// How many elements were turned into geometry.
  final int drawn;

  /// How many elements the style had nothing to say about.
  final int skipped;

  /// How many elements could not be built, almost always a way whose nodes
  /// run off the edge of the data.
  final int incomplete;

  /// Creates a report.
  const TessellationReport({
    required this.tiles,
    required this.drawn,
    required this.skipped,
    required this.incomplete,
  });

  /// How many vertices were produced across every tile.
  int get vertices =>
      tiles.values.fold(0, (total, tile) => total + tile.vertices);

  /// How many bytes of vertex data were produced.
  int get bytes => vertices * 8;

  /// How many draw calls a frame showing every tile would take.
  int get drawCalls =>
      tiles.values.fold(0, (total, tile) => total + tile.layers.length);
}

/// Turns a dataset into the triangles that draw it.
///
/// Geometry is grouped into tiles at [zoom] so that it can be culled and
/// thrown away in pieces.
///
/// Everything is measured in ground units, lines included, so a tile is
/// right at every zoom it is ever drawn at and is never built a second time.
/// The canvas scale does the rest.
///
/// Elements are put in the tile holding their first node and are not cut at
/// the tile edge, so a tile's geometry can reach beyond it. That costs some
/// precision when culling and saves having to clip every shape.
///
/// Pass [into] to put everything in one named tile rather than in whichever
/// tile it falls in. Data read a box at a time arrives already divided, and
/// keeping each box's share whole is what stops two boxes from both claiming
/// a tile on the line between them.
TessellationReport tessellate(
  OsmSubset data, {
  required int zoom,
  TileId? into,
}) {
  final builders = <TileId, _TileBuilder>{};
  var drawn = 0;
  var skipped = 0;
  var incomplete = 0;

  for (final element in data.matches) {
    if (element.tags.isEmpty) {
      skipped += 1;
      continue;
    }

    final built = switch (element) {
      OsmWay() => _way(element, data, builders, zoom, into),
      OsmRelation() => _relation(element, data, builders, zoom, into),
      OsmNode() => _Outcome.skipped,
    };
    switch (built) {
      case _Outcome.drawn:
        drawn += 1;
      case _Outcome.skipped:
        skipped += 1;
      case _Outcome.incomplete:
        incomplete += 1;
    }
  }

  return TessellationReport(
    tiles: {
      for (final entry in builders.entries) entry.key: entry.value.build(),
    },
    drawn: drawn,
    skipped: skipped,
    incomplete: incomplete,
  );
}

enum _Outcome { drawn, skipped, incomplete }

_Outcome _way(
  OsmWay way,
  OsmSubset data,
  Map<TileId, _TileBuilder> builders,
  int zoom,
  TileId? into,
) {
  final asArea = way.isClosed && enclosesArea(way.tags);
  final layers = asArea ? fillLayersFor(way.tags) : lineLayersFor(way.tags);
  if (layers.isEmpty) return _Outcome.skipped;

  final nodes = data.nodesOf(way);
  if (nodes == null) return _Outcome.incomplete;

  if (asArea) {
    final area = data.areaOf(way);
    if (area == null) return _Outcome.incomplete;
    return _fill(area, layers, builders, zoom, into);
  }

  final tile = into ?? _tileOf(nodes.first, zoom);
  final builder = builders.putIfAbsent(tile, () => _TileBuilder(tile));
  final points = _project(nodes, tile);
  for (final layer in layers) {
    builder.stroke(layer, points);
  }
  return _Outcome.drawn;
}

_Outcome _relation(
  OsmRelation relation,
  OsmSubset data,
  Map<TileId, _TileBuilder> builders,
  int zoom,
  TileId? into,
) {
  if (relation.tags['type'] != 'multipolygon') return _Outcome.skipped;
  final layers = fillLayersFor(relation.tags);
  if (layers.isEmpty) return _Outcome.skipped;

  final area = data.areaOf(relation);
  if (area == null) return _Outcome.incomplete;
  return _fill(area, layers, builders, zoom, into);
}

_Outcome _fill(
  OsmArea area,
  List<int> layers,
  Map<TileId, _TileBuilder> builders,
  int zoom,
  TileId? into,
) {
  if (area.polygons.isEmpty) return _Outcome.incomplete;

  for (final polygon in area.polygons) {
    if (polygon.outer.isEmpty) continue;
    final tile = into ?? _tileOf(polygon.outer.first, zoom);
    final builder = builders.putIfAbsent(tile, () => _TileBuilder(tile));
    final outer = _project(polygon.outer, tile);
    final inners = [for (final inner in polygon.inners) _project(inner, tile)];
    for (final layer in layers) {
      builder.fill(layer, outer, inners);
    }
  }
  return _Outcome.drawn;
}

TileId _tileOf(OsmNode node, int zoom) =>
    TileId.at(zoom, node.latitude, node.longitude);

/// Projects nodes into the tile's own coordinates, where a whole tile is
/// [tileExtent] across.
List<double> _project(List<OsmNode> nodes, TileId tile) {
  final scale = tileExtent / tile.size;
  final out = List<double>.filled(nodes.length * 2, 0);
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    out[i * 2] = (Mercator.x(node.longitude) - tile.worldX) * scale;
    out[i * 2 + 1] = (Mercator.y(node.latitude) - tile.worldY) * scale;
  }
  return out;
}

/// Collects the triangles of one tile, keeping each layer's in its own list
/// so that the whole layer can go to the GPU in one call.
class _TileBuilder {
  final TileId tile;
  final _layers = <int, List<double>>{};

  /// How many tile units a metre of ground covers here.
  ///
  /// Mercator stretches distances away from the equator, so a metre is more
  /// tile units in Invercargill than in Auckland. Taken at the middle of the
  /// tile, across which the difference is far under a pixel.
  final double unitsPerMetre;

  /// How many tile units a pixel covers at the closest the map is drawn.
  ///
  /// Only anything that has to approximate a curve needs this, and it is the
  /// finest case rather than the current one because the tile is built once.
  final double unitsPerPixel;

  _TileBuilder(this.tile)
    : unitsPerMetre =
          tileExtent /
          (tile.size *
              Mercator.metresPerUnit(
                Mercator.latitude(tile.worldY + tile.size / 2),
              )),
      unitsPerPixel =
          tileExtent /
          (tilePixels * math.pow(2, maximumZoom - tile.zoom).toDouble());

  void fill(int layer, List<double> outer, List<List<double>> inners) {
    final triangles = triangulate(outer, holes: inners);
    if (triangles == null) return;
    (_layers[layer] ??= <double>[]).addAll(triangles);
  }

  void stroke(int layer, List<double> points) {
    final style = mapStyle[layer];
    final triangles = strokePolyline(
      points,
      style.width * unitsPerMetre,
      cap: style.cap,
      join: style.join,
      unitsPerPixel: unitsPerPixel,
    );
    if (triangles.isEmpty) return;
    (_layers[layer] ??= <double>[]).addAll(triangles);
  }

  TileMesh build() {
    final order = _layers.keys.toList()..sort();
    return TileMesh(
      id: tile,
      layers: [
        for (final layer in order)
          LayerMesh(layer, Float32List.fromList(_layers[layer]!)),
      ],
    );
  }
}
