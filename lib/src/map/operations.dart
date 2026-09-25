import 'package:flutter/material.dart';
import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

/// The things that can be done to what is selected, in the order iD offers
/// them.
enum OperationKind {
  /// Carrying on drawing a line from its end.
  continueLine,

  /// Giving what is selected nodes of its own where it touches anything.
  disconnect,

  /// Pulling a point out of what is selected.
  extract,

  /// Making what is selected one.
  merge,

  /// Moving what is selected to follow the pointer.
  move,

  /// Adding a copy of what was copied where the pointer is.
  paste,

  /// Turning what is selected round.
  reverse,

  /// Dividing lines where the selected nodes are.
  split,

  /// Keeping what is selected to paste later.
  copy,

  /// Taking what is selected off the map.
  delete,
}

/// One thing that can be done to what is selected, as it is offered: what
/// it is called, the key for it, what it would do, and why it cannot be
/// done if it cannot.
class OfferedOperation {
  /// Which it is.
  final OperationKind kind;

  /// What it is called.
  final String title;

  /// What it is drawn as.
  final IconData icon;

  /// The key it is done with, as it is written on the key.
  final String key;

  /// What it would do to what is selected.
  final String description;

  /// Why it cannot be done, or null if it can.
  final String? disabled;

  /// Creates an offer.
  const OfferedOperation({
    required this.kind,
    required this.title,
    required this.icon,
    required this.key,
    required this.description,
    this.disabled,
  });

  /// Whether it can be done.
  bool get enabled => disabled == null;
}

/// What can be done to [selected], in iD's order, with iD's words for it.
///
/// Only what applies to the selection is offered at all: nothing is said
/// about reversing an area. What applies but cannot be done now is offered
/// with the reason, as iD offers it, so that whoever reaches for it learns
/// why. [tooLarge] says too little of the selection is on screen to be sure
/// of what is being done to it.
///
/// With nothing selected, the one thing there is to do is paste what was
/// [copied], which is offered greyed while nothing has been.
List<OfferedOperation> offeredOperations(
  OsmEditor view,
  List<OsmElement> selected, {
  bool tooLarge = false,
  OsmCopied? copied,
}) {
  if (selected.isEmpty) {
    return [
      OfferedOperation(
        kind: OperationKind.paste,
        title: 'Paste',
        icon: Icons.content_paste,
        key: 'Ctrl+V',
        description: switch (copied) {
          null => '',
          final copied when copied.length == 1 =>
            'Add a duplicate ${_labelOf(copied.elements.single, view)} '
                'here.',
          final copied => 'Add ${copied.length} duplicate features here.',
        },
        disabled: copied == null ? 'No features have been copied.' : null,
      ),
    ];
  }
  final single = selected.length == 1;
  String one(String ifOne, String ifMany) => single ? ifOne : ifMany;

  final offered = <OfferedOperation>[];

  final continuable = view.continuable(selected);
  if (continuable != null) {
    offered.add(
      OfferedOperation(
        kind: OperationKind.continueLine,
        title: 'Continue',
        icon: Icons.linear_scale,
        key: 'A',
        description: 'Continue this line.',
        disabled: switch (continuable.length) {
          0 => 'No line can be continued here.',
          1 => null,
          _ =>
            'Several lines can be continued here. Add one to the selection '
                'to continue.',
        },
      ),
    );
  }

  final disconnect = OsmDisconnectOperation(view, selected);
  if (disconnect.available) {
    final points = selected.whereType<OsmNode>().isNotEmpty
        ? selected.whereType<OsmNode>().length
        : selected.whereType<OsmWay>().length;
    offered.add(
      OfferedOperation(
        kind: OperationKind.disconnect,
        title: 'Disconnect',
        icon: Icons.link_off,
        key: 'D',
        description:
            _disconnectDescriptions[disconnect.kind] ??
            'Disconnect these features from each other.',
        disabled: tooLarge
            ? points == 1
                  ? "This can't be disconnected because not enough of it is "
                        'currently visible.'
                  : "These can't be disconnected because not enough of them "
                        'are currently visible.'
            : switch (disconnect.disabled) {
                OsmDisabledReason.notConnected =>
                  "There aren't enough lines/areas here to disconnect.",
                OsmDisabledReason.relation =>
                  "This can't be disconnected because it connects members of "
                      'a relation.',
                _ => null,
              },
      ),
    );
  }

  final extract = view.extract(selected);
  if (extract.available) {
    final shapes = {for (final e in selected) view.geometryOf(e)};
    final shape = shapes.length == 1 ? shapes.single : null;
    offered.add(
      OfferedOperation(
        kind: OperationKind.extract,
        title: 'Extract',
        icon: Icons.place_outlined,
        key: 'E',
        description: switch (shape) {
          OsmGeometry.vertex => one(
            'Extract this point from its parent lines/areas.',
            'Extract these points from their parent features.',
          ),
          OsmGeometry.line => one(
            'Extract a point from this line.',
            'Extract points from these lines.',
          ),
          OsmGeometry.area => one(
            'Extract a point from this area.',
            'Extract points from these areas.',
          ),
          _ => 'Extract points from these features.',
        },
        disabled: tooLarge
            ? one(
                "A point can't be extracted because not enough of this "
                    'feature is visible.',
                "Points can't be extracted because not enough of these "
                    'features are visible.',
              )
            : null,
      ),
    );
  }

  final merge = OsmMergeOperation(view, selected);
  if (merge.available) {
    offered.add(
      OfferedOperation(
        kind: OperationKind.merge,
        title: 'Merge',
        icon: Icons.merge_type,
        key: 'C',
        description: 'Merge these features.',
        disabled: switch (merge.disabled) {
          null => null,
          OsmDisabledReason.restriction =>
            "These features can't be merged because it would damage a "
                '"Restriction" relation.',
          OsmDisabledReason.connectivity =>
            "These features can't be merged because it would damage a "
                '"Lane Connectivity" relation.',
          final reason =>
            _mergeReasons[reason] ?? "These features can't be merged.",
        },
      ),
    );
  }

  offered.add(
    OfferedOperation(
      kind: OperationKind.move,
      title: 'Move',
      icon: Icons.open_with,
      key: 'M',
      description: one(
        'Move this feature to a different location.',
        'Move these features to a different location.',
      ),
      disabled: tooLarge
          ? one(
              "This feature can't be moved because not enough of it is "
                  'currently visible.',
              "These features can't be moved because not enough of them are "
                  'currently visible.',
            )
          : null,
    ),
  );

  final reverse = OsmReverseOperation(view, selected);
  if (reverse.available) {
    offered.add(
      OfferedOperation(
        kind: OperationKind.reverse,
        title: 'Reverse',
        icon: Icons.swap_horiz,
        key: 'V',
        description: switch (reverse.kind) {
          'point' => 'Flip the direction of this point.',
          'points' => 'Flip the direction of these points.',
          'line' => 'Make this line go in the opposite direction.',
          'lines' => 'Make these lines go in the opposite direction.',
          _ => 'Flip the directions of these features.',
        },
      ),
    );
  }

  final split = OsmSplitOperation(view, selected);
  if (split.available) {
    final ways = split.ways.length <= 1 ? 'single' : 'multiple';
    final nodes = selected.whereType<OsmNode>().length == 1
        ? 'single_node'
        : 'multiple_node';
    offered.add(
      OfferedOperation(
        kind: OperationKind.split,
        title: 'Split',
        icon: Icons.content_cut,
        key: 'X',
        description:
            _splitDescriptions['${split.kind}.$ways.$nodes'] ??
            _splitDescriptions['feature.multiple.$nodes']!,
        disabled: switch (split.disabled) {
          OsmDisabledReason.notEligible =>
            "Lines can't be split at their beginning or end.",
          OsmDisabledReason.parentIncomplete =>
            'This line cannot be split because a parent relation isn’t '
                'fully downloaded. Download the full relation.',
          OsmDisabledReason.simpleRoundabout =>
            'This line cannot be split because this roundabout is part of a '
                'larger relation. You must remove it from the relation first.',
          _ => null,
        },
      ),
    );
  }

  if (view.copy(selected) != null) {
    offered.add(
      OfferedOperation(
        kind: OperationKind.copy,
        title: 'Copy',
        icon: Icons.content_copy,
        key: 'Ctrl+C',
        description: one(
          'Copy this feature to paste it later.',
          'Copy these features to paste them later.',
        ),
        disabled: tooLarge
            ? one(
                "This can't be copied because not enough of it is currently "
                    'visible.',
                "These can't be copied because not enough of them are "
                    'currently visible.',
              )
            : null,
      ),
    );
  }

  final delete = OsmDeleteOperation(view, selected);
  offered.add(
    OfferedOperation(
      kind: OperationKind.delete,
      title: 'Delete',
      icon: Icons.delete_outline,
      key: 'Del',
      description: one(
        'Delete this feature permanently.',
        'Delete these features permanently.',
      ),
      disabled: tooLarge
          ? one(
              "This feature can't be deleted because not enough of it is "
                  'currently visible.',
              "These features can't be deleted because not enough of them "
                  'are currently visible.',
            )
          : switch (delete.disabled) {
              OsmDisabledReason.partOfRelation => one(
                "This feature can't be deleted because it is part of a "
                    'larger relation. You must remove it from the relation '
                    'first.',
                "These features can't be deleted because they are part of "
                    'larger relations. You must remove them from the '
                    'relations first.',
              ),
              OsmDisabledReason.hasWikidataTag => one(
                "This feature can't be deleted because it has a Wikidata "
                    'tag.',
                "These features can't be deleted because some have "
                    'Wikidata tags.',
              ),
              _ => null,
            },
    ),
  );

  return offered;
}

/// What to call [element] in a sentence: its name, or failing that what
/// kind of thing it is, in lower case, as iD words it.
String _labelOf(OsmElement element, OsmEditor view) {
  final name = element.tags['name'];
  if (name != null && name.isNotEmpty) return name;
  final presets = view.presets;
  if (presets == null) return 'feature';
  return presets
      .match(
        element.tags,
        view.geometryOf(element),
        here: view.regionsOf(element),
      )
      .name
      .toLowerCase();
}

/// What disconnecting does, in iD's words, by what is disconnected.
const _disconnectDescriptions = {
  'no_points.single_way.line': 'Disconnect this line from other features.',
  'no_points.single_way.area': 'Disconnect this area from other features.',
  'no_points.multiple_ways.conjoined':
      'Disconnect these features from each other.',
  'no_points.multiple_ways.separate':
      'Disconnect these features from everything.',
  'single_point.no_ways': 'Disconnect the features at this point.',
  'single_point.single_way.line': 'Disconnect the selected line at this point.',
  'single_point.single_way.area': 'Disconnect the selected area at this point.',
  'single_point.multiple_ways':
      'Disconnect the selected features at this point.',
  'multiple_points.no_ways': 'Disconnect the features at these points.',
  'multiple_points.single_way.line':
      'Disconnect the selected line at these points.',
  'multiple_points.single_way.area':
      'Disconnect the selected area at these points.',
  'multiple_points.multiple_ways':
      'Disconnect the selected features at these points.',
};

/// Why merging cannot be done, in iD's words.
const _mergeReasons = {
  OsmDisabledReason.notEligible: "These features can't be merged.",
  OsmDisabledReason.notAdjacent:
      "These features can't be merged because their endpoints aren't "
      'connected.',
  OsmDisabledReason.relation:
      "These features can't be merged because they have conflicting "
      'relation roles.',
  OsmDisabledReason.incompleteRelation:
      "These features can't be merged because at least one hasn't been "
      'fully downloaded.',
  OsmDisabledReason.conflictingTags:
      "These features can't be merged because some of their tags have "
      'conflicting values.',
  OsmDisabledReason.conflictingRelations:
      "These features can't be merged because they belong to conflicting "
      'relations.',
  OsmDisabledReason.pathsIntersect:
      "These features can't be merged because the resulting path would "
      'intersect itself.',
  OsmDisabledReason.tooManyVertices:
      "These features can't be merged because the resulting path would "
      'have too many points.',
};

/// What splitting does, in iD's words, by what is split, how many, and at
/// how many nodes.
const _splitDescriptions = {
  'line.single.single_node': 'Divide this line into two at this point.',
  'line.single.multiple_node': 'Divide this line at these points.',
  'line.multiple.single_node':
      'Divide all lines at this point. Tip: To limit this operation to a '
      'specific line, select both the line and point before performing the '
      'split.',
  'line.multiple.multiple_node':
      'Divide all lines at these points. Tip: To limit this operation to a '
      'specific line, select the line as well as the points before '
      'performing the split.',
  'area.single.single_node':
      'Divide the edge of this area into two at this point.',
  'area.single.multiple_node': 'Divide the edge of this area at these points.',
  'area.multiple.single_node': 'Divide the edges of these areas at this point.',
  'area.multiple.multiple_node':
      'Divide the edges of these areas at these points.',
  'feature.multiple.single_node': 'Divide these features at this point.',
  'feature.multiple.multiple_node': 'Divide these features at these points.',
};

/// Whether too little of what lies within [selection] is inside [view] to
/// be sure of what is being done to it: less than four fifths of it, as iD
/// judges it. A selection with no extent of its own is judged by whether it
/// is on screen at all.
bool isTooLarge(Rect selection, Rect view) {
  final area = selection.width * selection.height;
  if (area <= 0) {
    return !view.contains(selection.topLeft) ||
        !view.contains(selection.bottomRight);
  }
  final overlap = selection.intersect(view);
  if (overlap.width <= 0 || overlap.height <= 0) return true;
  return overlap.width * overlap.height / area < 0.8;
}
