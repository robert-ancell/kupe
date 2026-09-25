import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

/// The elements [edits] has changed, along with everything that has to be
/// drawn again because of them.
///
/// A moved node takes every way running through it with it, which is what
/// [waysUsing] is asked for; so does a node taken off the map.
Set<(OsmElementType, int)> touchedBy(
  OsmEditHistory edits,
  List<int> Function(int nodeId) waysUsing,
) {
  final touched = <(OsmElementType, int)>{...edits.gone};
  for (final id in edits.changedNodes.keys) {
    touched.add((OsmElementType.node, id));
    for (final way in waysUsing(id)) {
      touched.add((OsmElementType.way, way));
    }
  }
  for (final id in edits.changedWays.keys) {
    touched.add((OsmElementType.way, id));
  }
  for (final id in edits.changedRelations.keys) {
    touched.add((OsmElementType.relation, id));
  }
  for (final (type, id) in edits.gone) {
    if (type != OsmElementType.node) continue;
    for (final way in waysUsing(id)) {
      touched.add((OsmElementType.way, way));
    }
  }
  return touched;
}
