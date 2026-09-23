import 'package:osm/osm.dart';

import '../data/map_store.dart';
import '../map/pick.dart';
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
EditedGeometry editedGeometry(MapStore store, OsmEdits edits) {
  if (edits.isEmpty) return const EditedGeometry(ways: [], nodes: []);

  final ways = <EditedWay>[];
  final drawn = <int>{};
  for (final id in edits.movedNodes.keys) {
    for (final wayId in store.waysUsing(id)) {
      if (!drawn.add(wayId)) continue;
      final way = store.ways[wayId];
      if (way == null) continue;
      final layers = way.isClosed && enclosesArea(way.tags)
          ? const <int>[]
          : lineLayersFor(way.tags);
      if (layers.isEmpty) continue;
      final points = worldPointsOf(way, store, edits);
      if (points == null) continue;
      ways.add(EditedWay(way: way, points: points, layers: layers));
    }
  }

  return EditedGeometry(
    ways: ways,
    nodes: [
      for (final node in edits.movedNodes.values)
        (Mercator.x(node.longitude), Mercator.y(node.latitude)),
    ],
  );
}
