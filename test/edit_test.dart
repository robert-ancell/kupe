import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/data/map_loader.dart';
import 'package:kupe/src/data/map_store.dart';
import 'package:kupe/src/edit/edited_geometry.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/style/style.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(800, 600);
const _latitude = -36.85;
const _longitude = 174.76;

Camera _at(double zoom) =>
    Camera.at(latitude: _latitude, longitude: _longitude, zoom: zoom);

Future<void> _drain() async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A box holding one road across the middle of it.
Future<Uint8List?> _road(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async {
  final box = uri.queryParameters['bbox']!
      .split(',')
      .map(double.parse)
      .toList();
  final west = box[0];
  final south = box[1];
  final east = box[2];
  final north = box[3];
  if (_latitude < south || _latitude > north) {
    return Uint8List.fromList(utf8.encode('<osm version="0.6"/>'));
  }
  final id = ((west + 180) * 100000).round();
  return Uint8List.fromList(
    utf8.encode(
      '<osm version="0.6">'
      '<node id="$id" lat="$_latitude" lon="$west" version="1"/>'
      '<node id="${id + 1}" lat="$_latitude" lon="$east" version="1"/>'
      '<way id="${id + 2}" version="1">'
      '<nd ref="$id"/><nd ref="${id + 1}"/>'
      '<tag k="highway" v="residential"/></way>'
      '</osm>',
    ),
  );
}

Future<MapLoader> _loaded(OsmEditHistory edits, {OsmTileCache? cache}) async {
  final loader = MapLoader(
    client: OsmApiClient(fetch: _road),
    edits: edits,
    cache: cache,
    onChanged: () {},
  );
  loader.look(_at(17), _size);
  await _drain();
  return loader;
}

/// Some node of a way that was read.
OsmNode _someNode(MapLoader loader) => loader.store.nodes.values.first;

void main() {
  test('draws nothing for changes while there are none', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    expect(editedGeometry(loader.store, edits).isEmpty, isTrue);
    expect(loader.hidden, isEmpty);
  });

  test('takes what has been changed out of the tiles', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final node = _someNode(loader);

    edits.moveNode(node, latitude: _latitude + 0.0002, longitude: _longitude);
    loader.editsChanged();

    // The node and every way running through it.
    expect(loader.hidden, contains((OsmElementType.node, node.id)));
    expect(loader.hidden.where((e) => e.$1 == OsmElementType.way), isNotEmpty);
  });

  test('draws what has been changed instead', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final node = _someNode(loader);

    edits.moveNode(node, latitude: _latitude + 0.0002, longitude: _longitude);
    final drawn = editedGeometry(loader.store, edits);
    expect(drawn.ways, isNotEmpty);
    expect(drawn.nodes.length, 1);
    // From where the node is now.
    expect(
      drawn.nodes.single.$2,
      closeTo(Mercator.y(_latitude + 0.0002), 1e-12),
    );
  });

  test('leaves what was read exactly as it was read', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final node = _someNode(loader);

    edits.moveNode(node, latitude: -36.9, longitude: 174.9);
    loader.editsChanged();

    // The store still holds what OpenStreetMap sent.
    expect(loader.store.nodes[node.id]!.latitude, _latitude);
    expect(loader.store.nodes[node.id]!.longitude, node.longitude);
  });

  test('leaves what is on disk exactly as it was read', () async {
    final work = await Directory.systemTemp.createTemp('kupe_edit_test');
    addTearDown(() async => work.delete(recursive: true));

    final edits = OsmEditHistory();
    final cache = await OsmTileCache.open(directory: work);
    final loader = await _loaded(edits, cache: cache);
    final node = _someNode(loader);
    final before = cache.tiles.map((t) => '${t.id}:${t.bytes}').toList();

    edits.moveNode(node, latitude: -36.9, longitude: 174.9);
    loader.editsChanged();
    await _drain();

    expect(cache.tiles.map((t) => '${t.id}:${t.bytes}').toList(), before);
    // And reading it back gives the node where it was.
    final held = await cache.read(cache.tiles.first.id);
    final read = held!.whereType<OsmNode>().where((n) => n.id == node.id);
    if (read.isNotEmpty) {
      expect(read.single.latitude, _latitude);
    }
  });

  test('puts everything back when the change is undone', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final node = _someNode(loader);

    edits.moveNode(node, latitude: _latitude + 0.0002, longitude: _longitude);
    loader.editsChanged();
    expect(loader.hidden, isNotEmpty);

    edits.undo();
    loader.editsChanged();
    expect(loader.hidden, isEmpty);
    expect(editedGeometry(loader.store, edits).isEmpty, isTrue);
  });

  test('builds the tile again with what was hidden back in it', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final node = _someNode(loader);
    final before = loader.tiles.fold(0, (sum, tile) => sum + tile.vertices);

    edits.moveNode(node, latitude: _latitude + 0.0002, longitude: _longitude);
    loader.editsChanged();
    final hidden = loader.tiles.fold(0, (sum, tile) => sum + tile.vertices);
    expect(hidden, lessThan(before), reason: 'the way is out of the tile');

    edits.undo();
    loader.editsChanged();
    expect(loader.tiles.fold(0, (sum, tile) => sum + tile.vertices), before);
  });

  test('asks the API for nothing when something is changed', () async {
    final edits = OsmEditHistory();
    final loader = await _loaded(edits);
    final asked = loader.requests;

    edits.moveNode(_someNode(loader), latitude: -36.9, longitude: 174.9);
    loader.editsChanged();
    await _drain();
    expect(loader.requests, asked);
  });

  test('draws a changed building as a building', () {
    const corners = [
      OsmNode(id: 1, latitude: _latitude, longitude: _longitude),
      OsmNode(id: 2, latitude: _latitude, longitude: _longitude + 0.0002),
      OsmNode(id: 3, latitude: _latitude - 0.0002, longitude: _longitude),
    ];
    const way = OsmWay(id: 4, nodeIds: [1, 2, 3, 1], tags: {'building': 'yes'});
    final store = MapStore()
      ..add(OsmTile.at(16, _latitude, _longitude), [...corners, way]);
    final edits = OsmEditHistory()
      ..moveNode(
        corners[1],
        latitude: _latitude + 0.0001,
        longitude: _longitude + 0.0002,
      );

    // Its fill and the edge around it, as the tile drew it before it was
    // touched: not a road, which is what a way with nothing to go on is
    // drawn as.
    expect(editedGeometry(store, edits).ways.single.layers, [
      layerIndex('building'),
      layerIndex('building-edge'),
    ]);
  });
}
