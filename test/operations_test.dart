import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/data/map_store.dart';
import 'package:kupe/src/map/operations.dart';
import 'package:kupe/src/style/style.dart';
import 'package:osm/osm.dart';

const _tile = OsmTile(16, 64583, 39992);

OsmNode _node(int id, double lon, [Map<String, String> tags = const {}]) =>
    OsmNode(
      id: id,
      latitude: -36.85,
      longitude: 174.76 + lon,
      tags: tags,
      info: const OsmInfo(version: 1),
    );

/// A road of three nodes, the middle one a crossing, and a path off its end.
OsmEditor _roads({List<OsmRelation> relations = const []}) {
  final store = MapStore()
    ..add(_tile, [
      _node(1, 0),
      _node(2, 0.001, {'highway': 'crossing'}),
      _node(3, 0.002),
      _node(4, 0.003),
      const OsmWay(
        id: 10,
        nodeIds: [1, 2, 3],
        tags: {'highway': 'residential'},
        info: OsmInfo(version: 1),
      ),
      const OsmWay(
        id: 11,
        nodeIds: [3, 4],
        tags: {'highway': 'footway'},
        info: OsmInfo(version: 1),
      ),
      ...relations,
    ]);
  return OsmEditor(store, isArea: enclosesArea);
}

List<OperationKind> _kinds(List<OfferedOperation> offered) => [
  for (final offer in offered) offer.kind,
];

void main() {
  test('offers only to paste with nothing selected', () {
    final view = _roads();
    final nothing = offeredOperations(view, const []);
    expect(_kinds(nothing), [OperationKind.paste]);
    expect(nothing.single.disabled, 'No features have been copied.');

    final copied = view.copy([view.way(11)!, view.way(10)!]);
    final something = offeredOperations(view, const [], copied: copied);
    expect(something.single.enabled, isTrue);
    expect(something.single.description, 'Add 2 duplicate features here.');
  });

  test('names what one pasted thing is', () {
    final store = MapStore()
      ..add(_tile, [
        _node(1, 0, {'amenity': 'bench', 'name': 'Rest'}),
      ]);
    final view = OsmEditor(store, isArea: enclosesArea);
    final copied = view.copy([view.node(1)!]);
    expect(
      offeredOperations(view, const [], copied: copied).single.description,
      'Add a duplicate Rest here.',
    );
  });

  test('offers what applies to a line, in iD\'s order', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.way(10)!]);
    // It touches the footway at its end, so it can be disconnected from it.
    expect(_kinds(offered), [
      OperationKind.disconnect,
      OperationKind.move,
      OperationKind.reverse,
      OperationKind.copy,
      OperationKind.delete,
    ]);
    final reverse = offered[2];
    expect(reverse.title, 'Reverse');
    expect(reverse.key, 'V');
    expect(reverse.description, 'Make this line go in the opposite direction.');
    expect(offered.every((o) => o.enabled), isTrue);
  });

  test('offers to continue from the end of a line', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.node(1)!]);
    expect(offered.first.kind, OperationKind.continueLine);
    expect(offered.first.enabled, isTrue);
  });

  test('says why a line cannot be continued from where two end', () {
    // The road and the path both end at node 3.
    final view = _roads();
    final offered = offeredOperations(view, [view.node(3)!]);
    expect(offered.first.kind, OperationKind.continueLine);
    expect(
      offered.first.disabled,
      startsWith('Several lines can be continued'),
    );
  });

  test('offers to pull a tagged node out of its line', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.node(2)!]);
    final extract = offered.firstWhere((o) => o.kind == OperationKind.extract);
    expect(
      extract.description,
      'Extract this point from its parent lines/areas.',
    );
    // From the middle of a line there is nothing to continue.
    expect(offered.first.disabled, 'No line can be continued here.');
  });

  test('offers to split, disconnect and pull out at a node along a line', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.node(2)!]);
    expect(_kinds(offered), [
      OperationKind.continueLine,
      OperationKind.disconnect,
      OperationKind.extract,
      OperationKind.move,
      OperationKind.split,
      // A node along a way that says something is worth copying on its own.
      OperationKind.copy,
      OperationKind.delete,
    ]);
    final split = offered.firstWhere((o) => o.kind == OperationKind.split);
    expect(split.description, 'Divide this line into two at this point.');
    expect(split.key, 'X');
    // On one line only: nothing to disconnect it from.
    final disconnect = offered.firstWhere(
      (o) => o.kind == OperationKind.disconnect,
    );
    expect(
      disconnect.disabled,
      "There aren't enough lines/areas here to disconnect.",
    );
  });

  test('offers to disconnect where lines meet', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.node(3)!]);
    final disconnect = offered.firstWhere(
      (o) => o.kind == OperationKind.disconnect,
    );
    expect(disconnect.enabled, isTrue);
    expect(disconnect.description, 'Disconnect the features at this point.');
  });

  test('offers to merge two lines, and says why it cannot', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.way(10)!, view.way(11)!]);
    final merge = offered.firstWhere((o) => o.kind == OperationKind.merge);
    expect(merge.key, 'C');
    // A residential road and a footway are not one thing.
    expect(
      merge.disabled,
      "These features can't be merged because some of their tags have "
      'conflicting values.',
    );
  });

  test('says why part of a route cannot be deleted', () {
    final view = _roads(
      relations: const [
        OsmRelation(
          id: 30,
          members: [OsmMember(type: OsmElementType.way, ref: 10, role: '')],
          tags: {'type': 'route'},
          info: OsmInfo(version: 1),
        ),
      ],
    );
    final delete = offeredOperations(view, [view.way(10)!]).last;
    expect(delete.disabled, contains('part of a larger relation'));
  });

  test('says why what is mostly off screen cannot be deleted', () {
    final view = _roads();
    final delete = offeredOperations(view, [
      view.way(10)!,
      view.way(11)!,
    ], tooLarge: true).last;
    expect(
      delete.disabled,
      "These features can't be deleted because not enough of them are "
      'currently visible.',
    );
  });

  test('finds the relations listing an element, as they now stand', () {
    final view = _roads(
      relations: const [
        OsmRelation(
          id: 30,
          members: [
            OsmMember(type: OsmElementType.way, ref: 10, role: ''),
            OsmMember(type: OsmElementType.way, ref: 10, role: ''),
          ],
          info: OsmInfo(version: 1),
        ),
      ],
    );
    expect(view.relationsUsing(OsmElementType.way, 10).map((r) => r.id), [30]);
    view.setRelationMembers(view.relation(30)!, const []);
    expect(view.relationsUsing(OsmElementType.way, 10), isEmpty);
  });

  group('too large', () {
    const screen = Rect.fromLTWH(0, 0, 100, 100);

    test('is not what is all on screen', () {
      expect(isTooLarge(const Rect.fromLTWH(10, 10, 50, 50), screen), isFalse);
    });

    test('is what is less than four fifths on screen', () {
      expect(isTooLarge(const Rect.fromLTWH(30, 0, 100, 100), screen), isTrue);
      expect(
        isTooLarge(const Rect.fromLTWH(-10, 0, 100, 100), screen),
        isFalse,
      );
    });

    test('is a point off screen, and not one on it', () {
      expect(isTooLarge(const Rect.fromLTWH(50, 50, 0, 0), screen), isFalse);
      expect(isTooLarge(const Rect.fromLTWH(150, 50, 0, 0), screen), isTrue);
    });
  });
}
