import 'package:osm/osm.dart';

import '../data/map_store.dart';
import '../style/style.dart';
import 'ways.dart';

/// What has been read, with what has been changed laid over it: the map as
/// it now stands, for anything done to it to work from.
class StoreEditView implements OsmEditView {
  /// What has been read.
  final MapStore store;

  @override
  final OsmEdits edits;

  /// The kinds of thing there are, if they are known, which decide whether
  /// a closed way is an area.
  final OsmPresets? presets;

  /// Creates a view.
  StoreEditView(this.store, this.edits, {this.presets});

  @override
  OsmNode? node(int id) => edits.isGone(OsmElementType.node, id)
      ? null
      : edits.changedNode(id) ?? store.nodes[id];

  @override
  OsmWay? way(int id) => edits.isGone(OsmElementType.way, id)
      ? null
      : edits.changedWay(id) ?? store.ways[id];

  @override
  OsmRelation? relation(int id) => edits.isGone(OsmElementType.relation, id)
      ? null
      : edits.changedRelation(id) ?? store.relations[id];

  @override
  List<OsmWay> waysUsing(int nodeId) => waysUsingNode(nodeId, store, edits);

  @override
  List<OsmRelation> relationsUsing(OsmElementType type, int id) => [
    for (final relationId in {
      ...store.relationsListing(type, id),
      ...edits.changedRelations.keys,
    })
      if (relation(relationId) case final relation?
          when relation.members.any((m) => m.type == type && m.ref == id))
        relation,
  ];

  /// The shape [element] takes, as far as what it can be is concerned.
  ///
  /// A node is a vertex when it is in a way, drawn since or read, and a point
  /// when it stands alone. A way is an area when it is closed and its tags
  /// say so — by the rule the kinds of thing are chosen by, once they are
  /// known, and by the rule the map is drawn by until then — and a line
  /// otherwise. A multipolygon is an area and any other relation is a
  /// relation.
  @override
  OsmGeometry geometryOf(OsmElement element) => switch (element) {
    OsmNode() =>
      waysUsing(element.id).isEmpty ? OsmGeometry.point : OsmGeometry.vertex,
    OsmWay() =>
      element.isClosed &&
              (presets?.isArea(element.tags) ?? enclosesArea(element.tags))
          ? OsmGeometry.area
          : OsmGeometry.line,
    OsmRelation() =>
      element.tags['type'] == 'multipolygon'
          ? OsmGeometry.area
          : OsmGeometry.relation,
  };
}
