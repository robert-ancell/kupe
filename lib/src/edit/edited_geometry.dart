import 'package:osm/osm.dart';

import '../data/map_store.dart';
import '../style/style.dart';

/// A line drawn from what it is now rather than from what was built.
class EditedWay {
  /// Which way it is.
  final OsmWay way;

  /// Its nodes in world coordinates, as they now stand.
  final List<double> points;

  /// The layers it is drawn in, casing first.
  final List<int> layers;

  /// Creates a line to draw.
  const EditedWay({
    required this.way,
    required this.points,
    required this.layers,
  });
}

/// Everything that has been changed, ready to draw.
class EditedGeometry {
  /// The lines to draw.
  final List<EditedWay> ways;

  /// The nodes to draw, in world coordinates.
  final List<(double, double)> nodes;

  /// Creates a set of geometry.
  const EditedGeometry({required this.ways, required this.nodes});

  /// Whether there is nothing to draw.
  bool get isEmpty => ways.isEmpty && nodes.isEmpty;
}

/// Works out what has to be drawn for the changes made.
///
/// Only what has been changed: everything else was built into a tile once and
/// is still on the graphics card. A handful of lines a frame is the price of
/// a node following the pointer.
EditedGeometry editedGeometry(
  MapStore store,
  OsmEdits edits, {
  List<int> drawing = const [],
}) {
  if (edits.isEmpty && drawing.isEmpty) {
    return const EditedGeometry(ways: [], nodes: []);
  }

  final ways = <EditedWay>[];
  final wanted = <int>{
    // Every way that has been made or put through other nodes, and every way
    // running through a node that has moved.
    ...edits.changedWays.keys,
    for (final id in edits.movedNodes.keys) ...store.waysUsing(id),
  };

  for (final id in wanted) {
    final way = edits.changedWay(id) ?? store.ways[id];
    if (way == null) continue;
    if (edits.isGone(OsmElementType.way, id)) continue;
    final layers = way.isClosed && enclosesArea(way.tags)
        ? const <int>[]
        : lineLayersFor(way.tags);
    final points = _pointsOf(way.nodeIds, store, edits);
    if (points.length < 4) continue;
    ways.add(
      EditedWay(
        way: way,
        points: points,
        // A way with nothing said about it yet, which is what a line being
        // drawn is, is still drawn: otherwise there is nothing to see while
        // it is being drawn.
        layers: layers.isEmpty ? [layerIndex('minor')] : layers,
      ),
    );
  }

  // The line being drawn, which is not a way yet. Left open however it will
  // end: the line back to where it started has not been drawn, and is shown
  // as the line that would be drawn rather than as one that has been.
  if (drawing.length > 1) {
    final points = _pointsOf(drawing, store, edits);
    if (points.length >= 4) {
      ways.add(
        EditedWay(
          way: OsmWay(id: 0, nodeIds: drawing),
          points: points,
          layers: [layerIndex('minor')],
        ),
      );
    }
  }

  return EditedGeometry(
    ways: ways,
    nodes: [
      for (final node in edits.movedNodes.values)
        if (!edits.isGone(OsmElementType.node, node.id))
          (Mercator.x(node.longitude), Mercator.y(node.latitude)),
    ],
  );
}

/// Where a run of nodes is, from wherever they now are, leaving out any that
/// are not held.
List<double> _pointsOf(List<int> ids, MapStore store, OsmEdits edits) {
  final points = <double>[];
  for (final id in ids) {
    if (edits.isGone(OsmElementType.node, id)) continue;
    final node = edits.movedNode(id) ?? store.nodes[id];
    if (node == null) continue;
    points.add(Mercator.x(node.longitude));
    points.add(Mercator.y(node.latitude));
  }
  return points;
}
