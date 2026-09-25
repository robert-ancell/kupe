import 'dart:typed_data';

import 'package:osm/osm.dart';

import '../map/pick.dart';
import '../style/style.dart';
import 'stroke.dart';
import 'tile_mesh.dart';
import 'triangulate.dart';

/// What was built, and what it cost, for one pass over a dataset.
class TessellationReport {
  /// The tiles built, by id.
  final Map<OsmTile, TileMesh> tiles;

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

  /// How many bytes were produced.
  int get bytes => tiles.values.fold(0, (total, tile) => total + tile.bytes);

  /// How many draw calls a frame showing every tile would take.
  int get drawCalls => tiles.values.fold(
    0,
    (total, tile) => total + tile.fills.length + tile.lines.length,
  );
}

/// Turns a dataset into the triangles that draw it.
///
/// Geometry is grouped into tiles at [zoom] so that it can be culled and
/// thrown away in pieces.
///
/// What is built serves every zoom. Filled shapes cover the same ground
/// whatever the zoom; lines are anchored to the ground with their width in
/// pixels held apart; the points a line can be taken hold of by are only
/// where they are. So a tile is built once, when it arrives or when
/// something in it is changed, and never because the map was zoomed.
///
/// Elements are put in the tile holding their first node and are not cut at
/// the tile edge, so a tile's geometry can reach beyond it. That costs some
/// precision when culling and saves having to clip every shape.
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
  OsmTile? into,
  int Function(int nodeId)? waysThrough,
  bool Function(OsmElement element)? skip,
}) {
  final through = waysThrough ?? _countWithin(data);
  final builders = <OsmTile, _TileBuilder>{};
  var drawn = 0;
  var skipped = 0;
  var incomplete = 0;

  for (final element in data.matches) {
    // Anything that has been changed is drawn from what it is now, a frame
    // at a time, so it is left out of what is built once and kept.
    if (skip != null && skip(element)) {
      skipped += 1;
      continue;
    }

    final built = switch (element) {
      OsmWay() => _way(element, data, builders, zoom, into, through),
      OsmRelation() => _relation(element, data, builders, zoom, into),
      OsmNode() => _node(element, builders, zoom, into, through),
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
  Map<OsmTile, _TileBuilder> builders,
  int zoom,
  OsmTile? into,
  int Function(int nodeId) waysThrough,
) {
  // Every way is drawn, tagged or not, known to the style or not: whatever
  // is on the map can be edited, so whatever is on the map is shown.
  final layers = wayLayersFor(way);
  final fills = [
    for (final layer in layers)
      if (mapStyle[layer].kind == LayerKind.fill) layer,
  ];

  final nodes = data.nodesOf(way);
  if (nodes == null) return _Outcome.incomplete;

  if (fills.isNotEmpty) {
    final area = data.areaOf(way);
    if (area == null) return _Outcome.incomplete;
    return _fill(area, fills, builders, zoom, into);
  }

  final tile = into ?? _tileOf(nodes.first, zoom);
  final builder = builders.putIfAbsent(tile, () => _TileBuilder(tile));
  final points = _project(nodes, tile);
  for (final layer in layers) {
    builder.stroke(layer, points);
  }

  // The points this line can be taken hold of without being selected first.
  for (var i = 0; i < way.nodeIds.length; i++) {
    if (!isNodePinned(way, i, waysThrough)) continue;
    builder.point(way.nodeIds[i], points[i * 2], points[i * 2 + 1]);
  }
  return _Outcome.drawn;
}

/// Marks a node that is marked in its own right, by [isNodeMarked]: one
/// that is tagged, or one that is in no way at all.
///
/// The rest are marked, or not, by the ways they are in.
_Outcome _node(
  OsmNode node,
  Map<OsmTile, _TileBuilder> builders,
  int zoom,
  OsmTile? into,
  int Function(int nodeId) waysThrough,
) {
  if (!isNodeMarked(node, waysThrough)) return _Outcome.skipped;
  final tile = into ?? _tileOf(node, zoom);
  final at = _project([node], tile);
  builders
      .putIfAbsent(tile, () => _TileBuilder(tile))
      .point(node.id, at[0], at[1]);
  return _Outcome.drawn;
}

_Outcome _relation(
  OsmRelation relation,
  OsmSubset data,
  Map<OsmTile, _TileBuilder> builders,
  int zoom,
  OsmTile? into,
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
  Map<OsmTile, _TileBuilder> builders,
  int zoom,
  OsmTile? into,
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

OsmTile _tileOf(OsmNode node, int zoom) =>
    OsmTile.at(zoom, node.latitude, node.longitude);

/// Projects nodes into the tile's own coordinates, where a whole tile is
/// [tileExtent] across.
///
/// Each at its copy round the world nearest the tile, so that a way across
/// the antimeridian is built as the short way it is rather than one right
/// round the world.
List<double> _project(List<OsmNode> nodes, OsmTile tile) {
  final scale = tileExtent / tile.size;
  final middle = tile.worldX + tile.size / 2;
  final out = List<double>.filled(nodes.length * 2, 0);
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    final x = Mercator.nearest(Mercator.x(node.longitude), middle);
    out[i * 2] = (x - tile.worldX) * scale;
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
  final OsmTile tile;
  final _fills = <int, List<double>>{};
  final _lineAnchors = <int, List<double>>{};
  final _lineOffsets = <int, List<double>>{};
  final _points = <double>[];
  final _marked = <int>{};

  _TileBuilder(this.tile);

  void fill(int layer, List<double> outer, List<List<double>> inners) {
    final triangles = triangulate(outer, holes: inners);
    if (triangles == null) return;
    (_fills[layer] ??= <double>[]).addAll(triangles);
  }

  /// Marks a node as a point that can be taken hold of.
  ///
  /// Once however many lines it ends or joins: the mark is the same picture
  /// in the same place, and a second one is only a second draw.
  void point(int node, double x, double y) {
    if (!_marked.add(node)) return;
    _points
      ..add(x)
      ..add(y);
  }

  void stroke(int layer, List<double> points) {
    final style = mapStyle[layer];
    final triangles = strokeAnchored(
      points,
      style.width,
      cap: style.cap,
      join: style.join,
    );
    if (triangles.isEmpty) return;
    (_lineAnchors[layer] ??= <double>[]).addAll(triangles.anchors);
    (_lineOffsets[layer] ??= <double>[]).addAll(triangles.offsets);
  }

  TileMesh build() => TileMesh(
    id: tile,
    fills: [
      for (final layer in _fills.keys.toList()..sort())
        LayerMesh(layer, Float32List.fromList(_fills[layer]!)),
    ],
    lines: [
      for (final layer in _lineAnchors.keys.toList()..sort())
        LineLayerMesh(
          layer,
          AnchoredTriangles(
            Float32List.fromList(_lineAnchors[layer]!),
            Float32List.fromList(_lineOffsets[layer]!),
          ),
        ),
    ],
    points: Float32List.fromList(_points),
  );
}
