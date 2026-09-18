import 'package:kupe/src/data/map_store.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

OsmNode _node(int id, {int? version}) => OsmNode(
  id: id,
  latitude: -36.85,
  longitude: 174.76,
  info: version == null ? null : OsmInfo(version: version),
);

OsmWay _way(int id, List<int> nodes, {int? version}) => OsmWay(
  id: id,
  nodeIds: nodes,
  tags: const {'highway': 'residential'},
  info: version == null ? null : OsmInfo(version: version),
);

void main() {
  test('holds what it is given', () {
    final store = MapStore();
    store.add([
      _node(1),
      _way(10, [1]),
    ]);
    expect(store.nodes.keys, [1]);
    expect(store.ways.keys, [10]);
    expect(store.length, 2);
  });

  test('gives back only what no earlier box took', () {
    final store = MapStore();
    expect(store.add([_node(1), _node(2)]).length, 2);
    // The next box along shares the way on the boundary and its nodes.
    expect(store.add([_node(2), _node(3)]).map((e) => e.id), [3]);
  });

  test('draws a way on a boundary once', () {
    final store = MapStore();
    store.add([
      _node(1),
      _node(2),
      _way(10, [1, 2]),
    ]);
    final second = store.add([
      _node(2),
      _node(3),
      _way(10, [1, 2]),
    ]);
    expect(second.whereType<OsmWay>(), isEmpty);
  });

  test('resolves a way reaching into a box not yet read', () {
    final store = MapStore();
    // The API answers with every node of a way, even the ones outside the
    // box, which is what lets the way be drawn straight away.
    store.add([
      _node(1),
      _node(2),
      _node(3),
      _way(10, [1, 2, 3]),
    ]);
    final subset = store.subsetOf([store.ways[10]!]);
    expect(subset.nodesOf(store.ways[10]!), isNotNull);
    expect(subset.nodesOf(store.ways[10]!)!.length, 3);
  });

  test('keeps the newer of two versions of an element', () {
    final store = MapStore();
    store.add([_node(1, version: 3)]);
    store.add([_node(1, version: 5)]);
    expect(store.nodes[1]!.info!.version, 5);
  });

  test('does not go back to an older version', () {
    final store = MapStore();
    store.add([_node(1, version: 5)]);
    store.add([_node(1, version: 3)]);
    expect(store.nodes[1]!.info!.version, 5);
  });

  test('takes the later answer when neither says its version', () {
    final store = MapStore();
    store.add([_node(1)]);
    final second = _node(1);
    store.add([second]);
    expect(identical(store.nodes[1], second), isTrue);
  });

  test('counts each element once however often it arrives', () {
    final store = MapStore();
    for (var i = 0; i < 5; i++) {
      store.add([
        _node(1),
        _way(10, [1]),
      ]);
    }
    expect(store.length, 2);
  });
}
