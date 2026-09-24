import 'dart:ui';

import 'package:kupe/src/data/map_store.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/map/pick.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(800, 600);
const _latitude = -36.85;
const _longitude = 174.76;

final _camera = Camera.at(latitude: _latitude, longitude: _longitude, zoom: 18);

/// Where the middle of the view is on screen.
const _middle = Offset(400, 300);

/// A store holding one way of the given tags, running east to west through
/// the middle of the view.
MapStore _storeWith(
  Map<String, String> tags, {
  double latitude = _latitude,
  int id = 10,
}) {
  final nodes = [
    OsmNode(id: id, latitude: latitude, longitude: _longitude - 0.002),
    OsmNode(id: id + 1, latitude: latitude, longitude: _longitude + 0.002),
  ];
  final way = OsmWay(id: id + 2, nodeIds: [id, id + 1], tags: tags);
  final store = MapStore();
  store.add(TileId.at(16, latitude, _longitude), [...nodes, way]);
  return store;
}

PickedWay? _pick(Offset at, MapStore store) => wayAt(at, _camera, _size, store);

void main() {
  test('picks the line under the pointer', () {
    final picked = _pick(_middle, _storeWith(const {'highway': 'residential'}));
    expect(picked, isNotNull);
    expect(picked!.way.id, 12);
    expect(picked.points.length, 4);
    expect(picked.width, greaterThan(0));
  });

  test('picks a line the pointer is beside but not on', () {
    // A residential road is five and a half metres wide, so a few pixels off
    // the middle of it is still on it.
    final store = _storeWith(const {'highway': 'residential'});
    expect(_pick(_middle + const Offset(0, 4), store), isNotNull);
  });

  test('picks nothing where there is no line', () {
    final store = _storeWith(const {'highway': 'residential'});
    expect(_pick(_middle + const Offset(0, 120), store), isNull);
  });

  test('picks nothing past the end of a line', () {
    final store = _storeWith(const {'highway': 'residential'});
    final end = _onScreen(_latitude, _longitude + 0.002);
    expect(_pick(end - const Offset(2, 0), store), isNotNull);
    expect(_pick(end + const Offset(20, 0), store), isNull);
  });

  test('picks nothing for a way the style does not draw', () {
    final store = _storeWith(const {'note': 'nothing to draw'});
    expect(_pick(_middle, store), isNull);
  });

  group('a building', () {
    /// A triangular building whose northern edge runs through the middle of
    /// the view.
    MapStore building() {
      final nodes = [
        const OsmNode(
          id: 1,
          latitude: _latitude,
          longitude: _longitude - 0.001,
        ),
        const OsmNode(
          id: 2,
          latitude: _latitude,
          longitude: _longitude + 0.001,
        ),
        const OsmNode(
          id: 3,
          latitude: _latitude - 0.001,
          longitude: _longitude + 0.001,
        ),
      ];
      const way = OsmWay(
        id: 4,
        nodeIds: [1, 2, 3, 1],
        tags: {'building': 'yes'},
      );
      return MapStore()
        ..add(TileId.at(16, _latitude, _longitude), [...nodes, way]);
    }

    test('is picked by its edge', () {
      expect(_pick(_middle, building())?.way.id, 4);
    });

    test('is not picked from inside', () {
      // Well inside, away from every edge: whatever else is in there, a
      // path across a courtyard say, is what a click there is for.
      final inside = _onScreen(_latitude - 0.0003, _longitude + 0.0006);
      expect(_pick(inside, building()), isNull);
    });
  });

  test('picks the nearer of two lines', () {
    final store = _storeWith(const {'highway': 'residential'});
    // A footpath a little to the south.
    store.add(TileId.at(16, _latitude, _longitude), [
      const OsmNode(
        id: 20,
        latitude: _latitude - 0.0004,
        longitude: _longitude - 0.002,
      ),
      const OsmNode(
        id: 21,
        latitude: _latitude - 0.0004,
        longitude: _longitude + 0.002,
      ),
      const OsmWay(id: 22, nodeIds: [20, 21], tags: {'highway': 'footway'}),
    ]);
    expect(_pick(_middle, store)!.way.id, 12);
    expect(_pick(_onScreen(_latitude - 0.0004, _longitude), store)!.way.id, 22);
  });

  test('picks nothing when a way is missing a node', () {
    final store = MapStore()
      ..add(TileId.at(16, _latitude, _longitude), [
        const OsmWay(id: 4, nodeIds: [1, 2], tags: {'highway': 'residential'}),
      ]);
    expect(_pick(_middle, store), isNull);
  });

  _nodes();
  _refreshing();
  _afterDeleting();

  test('picks across the seam between tiles', () {
    // A way drawn into the tile next door is still under the pointer.
    final store = _storeWith(const {'highway': 'residential'});
    final elsewhere = MapStore();
    for (final element in store.drawnIn(TileId.at(16, _latitude, _longitude))) {
      elsewhere.add(const TileId(16, 0, 0), [element]);
    }
    expect(_pick(_middle, elsewhere), isNull);
  });
}

/// Where a place on the ground falls on the view.
Offset _onScreen(double latitude, double longitude) =>
    _camera.toScreen(Mercator.x(longitude), Mercator.y(latitude), _size);

/// A store holding a road of [count] nodes running east, and optionally a
/// second road crossing it at the given node along the way.
MapStore _road({int count = 5, int? crossingAt}) {
  final store = MapStore();
  final tile = TileId.at(16, _latitude, _longitude);
  final nodes = <OsmElement>[];
  for (var i = 0; i < count; i++) {
    nodes.add(
      OsmNode(
        id: 100 + i,
        latitude: _latitude,
        longitude: _longitude - 0.002 + i * 0.001,
      ),
    );
  }
  store.add(tile, [
    ...nodes,
    OsmWay(
      id: 1,
      nodeIds: [for (var i = 0; i < count; i++) 100 + i],
      tags: const {'highway': 'residential'},
    ),
  ]);

  if (crossingAt != null) {
    store.add(tile, [
      OsmNode(
        id: 200,
        latitude: _latitude - 0.001,
        longitude: _longitude - 0.002 + crossingAt * 0.001,
      ),
      OsmWay(
        id: 2,
        nodeIds: [100 + crossingAt, 200],
        tags: const {'highway': 'footway'},
      ),
    ]);
  }
  return store;
}

/// Where the node [index] along the road falls on the view.
Offset _nodeOn(int index) =>
    _onScreen(_latitude, _longitude - 0.002 + index * 0.001);

void _nodes() {
  group('nodes', () {
    test('takes the node where a way starts', () {
      final picked = pickAt(_nodeOn(0), _camera, _size, _road());
      expect(picked, isA<PickedNode>());
      expect(picked!.id, 100);
    });

    test('takes the node where a way stops', () {
      final picked = pickAt(_nodeOn(4), _camera, _size, _road());
      expect(picked, isA<PickedNode>());
      expect(picked!.id, 104);
    });

    test('takes the line rather than a node along the middle of it', () {
      final picked = pickAt(_nodeOn(2), _camera, _size, _road());
      expect(picked, isA<PickedWay>());
      expect(picked!.id, 1);
    });

    test('takes a node along the middle once its line is selected', () {
      final picked = pickAt(
        _nodeOn(2),
        _camera,
        _size,
        _road(),
        selectedWays: const {1},
      );
      expect(picked, isA<PickedNode>());
      expect(picked!.id, 102);
    });

    test('takes a node where two ways meet, selected or not', () {
      final store = _road(crossingAt: 2);
      final picked = pickAt(_nodeOn(2), _camera, _size, store);
      expect(picked, isA<PickedNode>());
      expect(picked!.id, 102);
    });

    test('takes the node rather than the line it sits on', () {
      // Both are under the pointer; the node is the smaller thing and the
      // line can be taken anywhere else along it.
      final picked = pickAt(_nodeOn(0), _camera, _size, _road());
      expect(picked, isA<PickedNode>());
    });

    test('takes nothing from a node it cannot reach', () {
      final away = _nodeOn(0) + const Offset(0, 60);
      expect(nodeAt(away, _camera, _size, _road()), isNull);
    });

    test('stops offering a middle node when the line is let go of', () {
      final store = _road();
      expect(
        pickAt(_nodeOn(2), _camera, _size, store, selectedWays: const {1}),
        isA<PickedNode>(),
      );
      expect(pickAt(_nodeOn(2), _camera, _size, store), isA<PickedWay>());
    });

    test('says which nodes can be taken hold of', () {
      final store = _road(crossingAt: 3);
      final way = store.ways[1]!;
      expect(isNodeSelectable(store, way, 0), isTrue, reason: 'the start');
      expect(isNodeSelectable(store, way, 4), isTrue, reason: 'the end');
      expect(isNodeSelectable(store, way, 3), isTrue, reason: 'a crossing');
      expect(isNodeSelectable(store, way, 1), isFalse, reason: 'the middle');
      expect(
        isNodeSelectable(store, way, 1, selectedWays: const {1}),
        isTrue,
        reason: 'the middle of a selected line',
      );
    });
  });
}

void _refreshing() {
  group('following a change', () {
    test('gives a node back from where it now is', () {
      final store = _road();
      final edits = OsmEdits();
      final picked = pickAt(_nodeOn(0), _camera, _size, store)! as PickedNode;

      edits.moveNode(
        picked.node,
        latitude: _latitude + 0.001,
        longitude: _longitude + 0.001,
      );
      final now = refreshed(picked, store, edits)! as PickedNode;

      expect(now.id, picked.id);
      expect(now.worldY, isNot(picked.worldY));
      expect(now.worldY, closeTo(Mercator.y(_latitude + 0.001), 1e-12));
      expect(now.worldX, closeTo(Mercator.x(_longitude + 0.001), 1e-12));
    });

    test('gives a line back with its moved node moved', () {
      final store = _road();
      final edits = OsmEdits();
      final picked =
          pickAt(_nodeOn(2), _camera, _size, store, selectedWays: const {1})!
              as PickedNode;
      final line = PickedWay(
        way: store.ways[1]!,
        points: worldPointsOf(store.ways[1]!, store)!,
        width: 5,
      );

      edits.moveNode(
        picked.node,
        latitude: _latitude + 0.001,
        longitude: _longitude,
      );
      final now = refreshed(line, store, edits)! as PickedWay;

      expect(now.points[5], closeTo(Mercator.y(_latitude + 0.001), 1e-12));
      expect(now.points[1], line.points[1], reason: 'the others stay put');
    });

    test('gives back what it was given when nothing has changed', () {
      final store = _road();
      final picked = pickAt(_nodeOn(0), _camera, _size, store)! as PickedNode;
      final now = refreshed(picked, store, OsmEdits())! as PickedNode;
      expect(now.worldX, picked.worldX);
      expect(now.worldY, picked.worldY);
    });

    test('gives back nothing for something no longer held', () {
      final picked = pickAt(_nodeOn(0), _camera, _size, _road())!;
      expect(refreshed(picked, MapStore(), OsmEdits()), isNull);
    });
  });
}

void _afterDeleting() {
  test('takes hold of a line after a node is taken out of it', () {
    final store = _road(count: 5);
    final edits = OsmEdits();
    final way = store.ways[1]!;

    // Take out a node in the middle of it.
    final node = store.nodes[102]!;
    edits.deleteNode(node, from: [way]);
    expect(edits.changedWay(1)!.nodeIds, [100, 101, 103, 104]);

    // The line is still there to take hold of.
    final picked = pickAt(
      _nodeOn(1) + const Offset(20, 0),
      _camera,
      _size,
      store,
      edits: edits,
    );
    expect(picked, isNotNull);
  });
}
