import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/map/pick.dart';
import 'package:kupe/src/render/map_painter.dart';
import 'package:kupe/src/render/tile_mesh.dart';
import 'package:kupe/src/style/style.dart';
import 'package:osm/osm.dart';

/// A canvas that draws nothing and remembers what it was asked to draw.
///
/// Enough to say what is drawn over what, which is the whole question here,
/// without anything being rasterised.
class _Recorder implements Canvas {
  final calls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(name.indexOf('"') + 1, name.lastIndexOf('"')));
    return null;
  }
}

const _tile = TileId(16, 64583, 39992);

final _camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17);

/// One tile holding a single stroked layer, so that the map has something in
/// it to be drawn over and under.
GpuTileMesh _mesh() => GpuTileMesh.of(
  TileMesh(
    id: _tile,
    pixelsPerTile: 512,
    fills: const [],
    lines: [
      LayerMesh(
        layerIndex('minor'),
        Float32List.fromList([0, 0, 100, 0, 100, 100]),
      ),
    ],
  ),
);

PickedWay _way() => const PickedWay(
  way: OsmWay(id: 1, nodeIds: [1, 2], tags: {'highway': 'residential'}),
  points: [0.5, 0.5, 0.5001, 0.5001],
  width: 5,
);

PickedNode _node() => const PickedNode(
  node: OsmNode(id: 1, latitude: -36.85, longitude: 174.76),
  worldX: 0.5,
  worldY: 0.5,
);

List<String> _drawnBy(MapPainter painter) {
  final recorder = _Recorder();
  painter.paint(recorder, const Size(800, 600));
  return recorder.calls;
}

void main() {
  test('draws a picked line under the map', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], highlight: _way()),
    );
    // The outline goes down first and the line is drawn inside it.
    expect(calls.indexOf('drawPath'), greaterThan(-1));
    expect(calls.indexOf('drawPath'), lessThan(calls.indexOf('drawVertices')));
  });

  test('draws a picked node over the map', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], highlight: _node()),
    );
    // A node is a point, and the lines that make it worth taking hold of are
    // the very ones that would hide it.
    expect(calls.indexOf('drawCircle'), greaterThan(-1));
    expect(
      calls.indexOf('drawCircle'),
      greaterThan(calls.lastIndexOf('drawVertices')),
    );
  });

  test('draws a selected node over the map as well', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], selection: [_node()]),
    );
    expect(
      calls.indexOf('drawCircle'),
      greaterThan(calls.lastIndexOf('drawVertices')),
    );
  });

  test('draws the nodes of a selected line over the map', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], selection: [_way()]),
    );
    expect(
      calls.indexOf('drawCircle'),
      greaterThan(calls.lastIndexOf('drawVertices')),
    );
  });

  test('draws a selected line under the map and its nodes over it', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], selection: [_way()]),
    );
    expect(calls.indexOf('drawPath'), lessThan(calls.indexOf('drawVertices')));
    expect(
      calls.lastIndexOf('drawCircle'),
      greaterThan(calls.indexOf('drawVertices')),
    );
  });

  test('lays the ground down before anything else', () {
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], highlight: _way()),
    );
    expect(calls.first, 'drawRect');
  });
}
