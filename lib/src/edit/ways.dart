import 'package:osm/osm.dart';

import '../data/map_store.dart';

/// The ways running through the node with [id], as they now stand.
///
/// Both what was read and what has been made or changed since. The store
/// knows nothing of a node put down a moment ago, or of a way drawn around
/// it, so asking it alone leaves a way running through a node that is about
/// to be taken off the map.
List<OsmWay> waysUsingNode(int id, MapStore store, OsmEditHistory edits) {
  final found = <OsmWay>[];
  final seen = <int>{};
  for (final wayId in store.waysUsing(id)) {
    if (!seen.add(wayId)) continue;
    if (edits.isGone(OsmElementType.way, wayId)) continue;
    final way = edits.changedWay(wayId) ?? store.ways[wayId];
    if (way != null && way.nodeIds.contains(id)) found.add(way);
  }
  for (final way in edits.changedWays.values) {
    if (!seen.add(way.id)) continue;
    if (way.nodeIds.contains(id)) found.add(way);
  }
  return found;
}
