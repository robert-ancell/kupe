import 'package:kupe/src/data/map_store.dart';
import 'package:kupe/src/edit/insert.dart';
import 'package:kupe/src/edit/ways.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _latitude = -36.85;
const _tile = TileId(16, 64583, 39992);

/// Two nodes a little apart, and whatever ways are asked for through them.
MapStore _storeWith(List<OsmWay> ways, {List<OsmNode> extra = const []}) {
  final store = MapStore();
  store.add(_tile, [
    const OsmNode(id: 1, latitude: _latitude, longitude: 174.760),
    const OsmNode(id: 2, latitude: _latitude, longitude: 174.762),
    ...extra,
    ...ways,
  ]);
  return store;
}

/// Halfway along the stretch between the two nodes.
double get _middleX => Mercator.x(174.761);
double get _middleY => Mercator.y(_latitude);

void main() {
  _deleting();

  test('puts a node where the line was pointed at', () {
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    final store = _storeWith([road]);
    final edits = OsmEdits();

    final made = insertNodeInto(
      road,
      store,
      edits,
      worldX: _middleX,
      worldY: _middleY,
    );

    expect(made, isNotNull);
    expect(made!.longitude, closeTo(174.761, 1e-6));
    expect(made.latitude, closeTo(_latitude, 1e-6));
    expect(edits.changedWay(10)!.nodeIds, [1, made.id, 2]);
  });

  test('puts it between the right pair on a longer line', () {
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2, 3],
      tags: {'highway': 'residential'},
    );
    final store = _storeWith(
      [road],
      extra: const [OsmNode(id: 3, latitude: _latitude, longitude: 174.764)],
    );
    final edits = OsmEdits();

    final made = insertNodeInto(
      road,
      store,
      edits,
      worldX: Mercator.x(174.763),
      worldY: _middleY,
    );
    expect(edits.changedWay(10)!.nodeIds, [1, 2, made!.id, 3]);
  });

  test('puts it in every line along the same stretch', () {
    // A footway drawn along the same two nodes as the road: adding to one
    // and not the other would tear them apart.
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    const path = OsmWay(id: 11, nodeIds: [1, 2], tags: {'highway': 'footway'});
    final store = _storeWith([road, path]);
    final edits = OsmEdits();

    final made = insertNodeInto(
      road,
      store,
      edits,
      worldX: _middleX,
      worldY: _middleY,
    );
    expect(edits.changedWay(10)!.nodeIds, [1, made!.id, 2]);
    expect(edits.changedWay(11)!.nodeIds, [1, made.id, 2]);
  });

  test('puts it in a line that runs the other way round', () {
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    const other = OsmWay(id: 11, nodeIds: [2, 1], tags: {'barrier': 'fence'});
    final store = _storeWith([road, other]);
    final edits = OsmEdits();

    final made = insertNodeInto(
      road,
      store,
      edits,
      worldX: _middleX,
      worldY: _middleY,
    );
    expect(edits.changedWay(11)!.nodeIds, [2, made!.id, 1]);
  });

  test('leaves a line that only shares one of the two nodes', () {
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    const side = OsmWay(id: 11, nodeIds: [1, 3], tags: {'highway': 'footway'});
    final store = _storeWith(
      [road, side],
      extra: const [OsmNode(id: 3, latitude: -36.851, longitude: 174.760)],
    );
    final edits = OsmEdits();

    insertNodeInto(road, store, edits, worldX: _middleX, worldY: _middleY);
    expect(edits.changedWay(11), isNull);
  });

  test('undoes the whole insertion at once', () {
    const road = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    const path = OsmWay(id: 11, nodeIds: [1, 2], tags: {'highway': 'footway'});
    final store = _storeWith([road, path]);
    final edits = OsmEdits();

    final made = insertNodeInto(
      road,
      store,
      edits,
      worldX: _middleX,
      worldY: _middleY,
    )!;

    // One change for the node and one for each line it went into.
    while (edits.isNotEmpty) {
      edits.undo();
    }
    expect(edits.changedWay(10), isNull);
    expect(edits.changedWay(11), isNull);
    expect(edits.movedNode(made.id), isNull);
  });

  test('puts nothing anywhere for a line with no length', () {
    const road = OsmWay(id: 10, nodeIds: [1], tags: {'highway': 'residential'});
    final store = _storeWith([road]);
    final edits = OsmEdits();
    expect(
      insertNodeInto(road, store, edits, worldX: _middleX, worldY: _middleY),
      isNull,
    );
    expect(edits.isEmpty, isTrue);
  });
}

void _deleting() {
  group('taking an inserted node back out', () {
    test('takes it out of the line it was put into', () {
      const road = OsmWay(
        id: 10,
        nodeIds: [1, 2],
        tags: {'highway': 'residential'},
      );
      final store = _storeWith([road]);
      final edits = OsmEdits();

      final made = insertNodeInto(
        road,
        store,
        edits,
        worldX: _middleX,
        worldY: _middleY,
      )!;
      expect(edits.changedWay(10)!.nodeIds, [1, made.id, 2]);

      // The store knows nothing of a node made a moment ago, so asking it
      // alone would leave the line running through something that has gone.
      edits.deleteNode(made, from: waysUsingNode(made.id, store, edits));
      expect(edits.changedWay(10)!.nodeIds, [1, 2]);
    });

    test('finds the ways through a node that was read', () {
      const road = OsmWay(
        id: 10,
        nodeIds: [1, 2],
        tags: {'highway': 'residential'},
      );
      final store = _storeWith([road]);
      final edits = OsmEdits();
      expect(waysUsingNode(1, store, edits).single.id, 10);
    });

    test('finds a way drawn around a node since', () {
      final store = _storeWith(const []);
      final edits = OsmEdits();
      final way = edits.createWay(nodeIds: [1, 2]);
      expect(waysUsingNode(1, store, edits).single.id, way.id);
    });

    test('leaves out a way the node is no longer in', () {
      const road = OsmWay(
        id: 10,
        nodeIds: [1, 2],
        tags: {'highway': 'residential'},
      );
      final store = _storeWith([road]);
      final edits = OsmEdits();
      edits.setWayNodes(road, [1]);
      expect(waysUsingNode(2, store, edits), isEmpty);
    });
  });
}
