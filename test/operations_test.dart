import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/data/map_store.dart';
import 'package:kupe/src/edit/view.dart';
import 'package:kupe/src/map/operations.dart';
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
StoreEditView _roads({List<OsmRelation> relations = const []}) {
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
  return StoreEditView(store, OsmEdits());
}

List<OperationKind> _kinds(List<OfferedOperation> offered) => [
  for (final offer in offered) offer.kind,
];

void main() {
  test('offers nothing for nothing', () {
    final view = _roads();
    expect(offeredOperations(view, const []), isEmpty);
  });

  test('offers what applies to a line, in iD\'s order', () {
    final view = _roads();
    final offered = offeredOperations(view, [view.way(10)!]);
    expect(_kinds(offered), [OperationKind.reverse, OperationKind.delete]);
    expect(offered.first.title, 'Reverse');
    expect(offered.first.key, 'V');
    expect(
      offered.first.description,
      'Make this line go in the opposite direction.',
    );
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
    expect(_kinds(offered), [
      OperationKind.continueLine,
      OperationKind.extract,
      OperationKind.delete,
    ]);
    expect(
      offered[1].description,
      'Extract this point from its parent lines/areas.',
    );
    // From the middle of a line there is nothing to continue.
    expect(offered.first.disabled, 'No line can be continued here.');
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
    view.edits.setRelationMembers(view.relation(30)!, const []);
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
