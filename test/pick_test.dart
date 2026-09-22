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

  test('picks nothing for a shape rather than a line', () {
    final nodes = [
      const OsmNode(id: 1, latitude: _latitude, longitude: _longitude - 0.001),
      const OsmNode(id: 2, latitude: _latitude, longitude: _longitude + 0.001),
      OsmNode(
        id: 3,
        latitude: _latitude - 0.001,
        longitude: _longitude + 0.001,
      ),
    ];
    const way = OsmWay(id: 4, nodeIds: [1, 2, 3, 1], tags: {'building': 'yes'});
    final store = MapStore()
      ..add(TileId.at(16, _latitude, _longitude), [...nodes, way]);
    expect(_pick(_middle, store), isNull);
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
