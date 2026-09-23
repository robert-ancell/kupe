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
  /// run off the edge of the file.
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
  int get drawCalls => tiles.values.fold(
    0,
    (total, tile) => total + tile.fills.length + tile.lines.length,
  );
}

/// Turns a dataset into the triangles that draw it.
///
/// Geometry is grouped into tiles at [zoom] so that it can be culled and
/// thrown away in pieces. [pixelsPerTile] is how wide a tile is expected to
/// be on screen, which sets how wide lines are built.
///
/// Elements are put in the tile holding their first node and are not cut at
/// the tile edge, so a tile's geometry can reach beyond it. That costs some
/// precision when culling and saves having to clip every shape.
///
/// Set [fills] or [lines] to false to build only one of the two. Zooming
/// changes what lines have to look like but leaves filled shapes alone, so a
/// rebuild on zoom only has to redo the lines.
///
/// [skip] leaves elements out, for anything being drawn some other way.
///
/// [waysThrough] says how many ways run through a node, which decides where
/// a line is marked as able to be taken hold of. Without it only what is in
/// [data] is counted, which misses ways meeting across the edge of a box.
///
/// Pass [into] to put everything in one named tile rather than in whichever
/// tile it falls in. Data read a box at a time arrives already divided, and
/// keeping each box's share whole is what stops two boxes from both claiming
/// a tile on the line between them.
TessellationReport tessellate(
  OsmSubset data, {
  required int zoom,
  required double pixelsPerTile,
  bool fills = true,
  bool lines = true,
  TileId? into,
  int Function(int nodeId)? waysThrough,
  bool Function(OsmElement element)? skip,
}) {
  final through = waysThrough ?? _countWithin(data);
  final builders = <TileId, _TileBuilder>{};
  var drawn = 0;
  var skipped = 0;
  var incomplete = 0;

  for (final element in data.matches) {
    if (element.tags.isEmpty) {
      skipped += 1;
      continue;
    }
    // Anything that has been changed is drawn from what it is now, a frame
    // at a time, so it is left out of what is built once and kept.
    if (skip != null && skip(element)) {
      skipped += 1;
      continue;
    }

    final built = switch (element) {
      OsmWay() => _way(
        element,
        data,
        builders,
        zoom,
        pixelsPerTile,
        fills,
        lines,
        into,
        through,
      ),
      OsmRelation() => _relation(
        element,
        data,
        builders,
        zoom,
        pixelsPerTile,
        fills,
        lines,
        into,
      ),
      _ => _Outcome.skipped,
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
  double pixelsPerTile,
  bool fills,
  bool lines,
  TileId? into,
  int Function(int nodeId) waysThrough,
) {
  final asArea = way.isClosed && enclosesArea(way.tags);
  // An area is a fill and an edge around it, so it has something to build in
  // either pass.
  if (asArea ? !fills && !lines : !lines) return _Outcome.skipped;
  final layers = asArea ? fillLayersFor(way.tags) : lineLayersFor(way.tags);
  if (layers.isEmpty) return _Outcome.skipped;

  final nodes = data.nodesOf(way);
  if (nodes == null) return _Outcome.incomplete;

  if (asArea) {
    final area = data.areaOf(way);
    if (area == null) return _Outcome.incomplete;
    return _fill(
      area,
      layers,
      builders,
      zoom,
      pixelsPerTile,
      fills,
      lines,
      into,
    );
  }

  final tile = into ?? _tileOf(nodes.first, zoom);
  final builder = builders.putIfAbsent(
    tile,
    () => _TileBuilder(tile, pixelsPerTile),
  );
  final points = _project(nodes, tile);
  for (final layer in layers) {
    builder.stroke(layer, points);
  }

  // The points this line can be taken hold of without being selected first:
  // where it starts and stops, and where other lines meet it.
  for (var i = 0; i < way.nodeIds.length; i++) {
    final ends = i == 0 || i == way.nodeIds.length - 1;
    if (!ends && waysThrough(way.nodeIds[i]) < 2) continue;
    builder.point(points[i * 2], points[i * 2 + 1]);
  }
  return _Outcome.drawn;
}

_Outcome _relation(
  OsmRelation relation,
  OsmSubset data,
  Map<TileId, _TileBuilder> builders,
  int zoom,
  double pixelsPerTile,
  bool fills,
  bool lines,
  TileId? into,
) {
  if (!fills && !lines) return _Outcome.skipped;
  if (relation.tags['type'] != 'multipolygon') return _Outcome.skipped;
  final layers = fillLayersFor(relation.tags);
  if (layers.isEmpty) return _Outcome.skipped;

  final area = data.areaOf(relation);
  if (area == null) return _Outcome.incomplete;
  return _fill(area, layers, builders, zoom, pixelsPerTile, fills, lines, into);
}

_Outcome _fill(
  OsmArea area,
  List<int> layers,
  Map<TileId, _TileBuilder> builders,
  int zoom,
  double pixelsPerTile,
  bool fills,
  bool lines,
  TileId? into,
) {
  if (area.polygons.isEmpty) return _Outcome.incomplete;

  for (final polygon in area.polygons) {
    if (polygon.outer.isEmpty) continue;
    final tile = into ?? _tileOf(polygon.outer.first, zoom);
    final builder = builders.putIfAbsent(
      tile,
      () => _TileBuilder(tile, pixelsPerTile),
    );
    final outer = _project(polygon.outer, tile);
    final inners = [for (final inner in polygon.inners) _project(inner, tile)];
    for (final layer in layers) {
      if (fills) builder.fill(layer, outer, inners);
      if (!lines) continue;
      final edge = areaEdgeLayer(layer);
      if (edge == null) continue;
      builder.stroke(edge, _ring(outer));
      for (final inner in inners) {
        builder.stroke(edge, _ring(inner));
      }
    }
  }
  return _Outcome.drawn;
}

/// A ring's points as a line that comes back to where it started.
///
/// A ring is held without repeating its first point; a stroked line needs it
/// repeated, or the shape is drawn with one side missing.
List<double> _ring(List<double> points) {
  if (points.length < 4) return points;
  final first = points[0], second = points[1];
  if (points[points.length - 2] == first && points.last == second) {
    return points;
  }
  return [...points, first, second];
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

/// How many ways in a subset run through each node.
///
/// A fallback for callers with nothing better. It only sees what it is given,
/// so two roads meeting just over the edge of a box look like two roads that
/// do not meet.
int Function(int) _countWithin(OsmSubset data) {
  final counts = <int, int>{};
  for (final way in data.ways.values) {
    for (final id in way.nodeIds.toSet()) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
  }
  return (id) => counts[id] ?? 0;
}

/// Collects the triangles of one tile, keeping each layer's in its own list
/// so that the whole layer can go to the GPU in one call.
class _TileBuilder {
  final TileId tile;
  final double pixelsPerTile;
  final _fills = <int, List<double>>{};
  final _lines = <int, List<double>>{};

  _TileBuilder(this.tile, this.pixelsPerTile);

  /// How many tile units a pixel covers, which is how a width on screen
  /// becomes a width in the triangles.
  double get unitsPerPixel => tileExtent / pixelsPerTile;

  void fill(int layer, List<double> outer, List<List<double>> inners) {
    final triangles = triangulate(outer, holes: inners);
    if (triangles == null) return;
    (_fills[layer] ??= <double>[]).addAll(triangles);
  }

  /// Marks a point that can be taken hold of.
  void point(double x, double y) {
    for (final layer in pointLayers) {
      final triangles = disc(
        x,
        y,
        mapStyle[layer].width * unitsPerPixel,
        unitsPerPixel: unitsPerPixel,
      );
      if (triangles.isEmpty) continue;
      (_lines[layer] ??= <double>[]).addAll(triangles);
    }
  }

  void stroke(int layer, List<double> points) {
    final style = mapStyle[layer];
    final triangles = strokePolyline(
      points,
      style.width * unitsPerPixel,
      cap: style.cap,
      join: style.join,
      unitsPerPixel: unitsPerPixel,
    );
    if (triangles.isEmpty) return;
    (_lines[layer] ??= <double>[]).addAll(triangles);
  }

  TileMesh build() => TileMesh(
    id: tile,
    pixelsPerTile: pixelsPerTile,
    fills: _meshes(_fills),
    lines: _meshes(_lines),
  );

  static List<LayerMesh> _meshes(Map<int, List<double>> layers) {
    final order = layers.keys.toList()..sort();
    return [
      for (final layer in order)
        LayerMesh(layer, Float32List.fromList(layers[layer]!)),
    ];
  }
}
