import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

/// The things that can be done to what is selected, in the order iD offers
/// them.
enum OperationKind {
  /// Carrying on drawing a line from its end.
  continueLine,

  /// Pulling a point out of what is selected.
  extract,

  /// Turning what is selected round.
  reverse,

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
List<OfferedOperation> offeredOperations(
  OsmEditView view,
  List<OsmElement> selected, {
  OsmPresets? presets,
  Set<String> here = const {},
  bool tooLarge = false,
}) {
  if (selected.isEmpty) return const [];
  final single = selected.length == 1;
  String one(String ifOne, String ifMany) => single ? ifOne : ifMany;

  final offered = <OfferedOperation>[];

  final continuable = osmContinuable(view, selected);
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

  final extract = OsmExtract(view, selected, presets: presets, here: here);
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

  final reverse = OsmReverse(view, selected);
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

  final delete = OsmDelete(view, selected);
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
              'part_of_relation' => one(
                "This feature can't be deleted because it is part of a "
                    'larger relation. You must remove it from the relation '
                    'first.',
                "These features can't be deleted because they are part of "
                    'larger relations. You must remove them from the '
                    'relations first.',
              ),
              'has_wikidata_tag' => one(
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
