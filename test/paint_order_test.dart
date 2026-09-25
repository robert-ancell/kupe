import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/map/pick.dart';
import 'package:kupe/src/render/map_painter.dart';
import 'package:kupe/src/render/node_sprite.dart';
import 'package:kupe/src/render/stroke.dart';
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

final _camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17);

/// One tile holding a single stroked layer, so that the map has something in
/// it to be drawn over and under.
///
/// Through the middle of the view: a tile is only drawn if what it holds is
/// on screen.
GpuTileMesh _mesh({double latitude = -36.85, double longitude = 174.76}) {
  final tile = OsmTile.at(16, latitude, longitude);
  final x = (OsmMercator.x(longitude) - tile.worldX) * tileExtent / tile.size;
  final y = (OsmMercator.y(latitude) - tile.worldY) * tileExtent / tile.size;
  return GpuTileMesh.of(
    TileMesh(
      id: tile,
      fills: const [],
      lines: [
        LineLayerMesh(
          layerIndex('minor'),
          strokeAnchored([x - 100, y, x + 100, y], 3),
        ),
      ],
      // Its two ends, which are what a line is taken hold of by.
      points: Float32List.fromList([x - 100, y, x + 100, y]),
    ),
  );
}

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

  testWidgets('draws every point of a tile in one call, over its lines', (
    tester,
  ) async {
    final sprite = (await tester.runAsync(() => NodeSprite.create(1)))!;
    addTearDown(sprite.dispose);
    final calls = _drawnBy(
      MapPainter(camera: _camera, tiles: [_mesh()], nodeSprite: sprite),
    );
    expect(calls.where((call) => call == 'drawRawAtlas'), hasLength(1));
    expect(
      calls.indexOf('drawRawAtlas'),
      greaterThan(calls.lastIndexOf('drawVertices')),
    );
  });

  test('draws no points until there is a picture to draw them with', () {
    final calls = _drawnBy(MapPainter(camera: _camera, tiles: [_mesh()]));
    expect(calls, isNot(contains('drawRawAtlas')));
    expect(calls, contains('drawVertices'));
  });

  test('leaves out a tile with nothing on screen', () {
    final calls = _drawnBy(
      MapPainter(
        camera: _camera,
        tiles: [_mesh(latitude: 51.5, longitude: -0.12)],
      ),
    );
    expect(calls, isNot(contains('drawVertices')));
  });

  test('places the lines again for a zoom, and not for a pan', () {
    final mesh = _mesh();
    final placed = mesh.linesAt(1);
    expect(identical(mesh.linesAt(1), placed), isTrue);
    expect(identical(mesh.linesAt(2), placed), isFalse);
  });

  test('draws a tile off screen whose road runs onto it', () {
    // A way goes in the tile its first node is in and is not cut at the
    // edge, so a road starting two tiles west still reaches the middle.
    final here = OsmTile.at(16, -36.85, 174.76);
    final west = OsmTile(16, here.x - 2, here.y);
    final x = (OsmMercator.x(174.76) - west.worldX) * tileExtent / west.size;
    final y = (OsmMercator.y(-36.85) - west.worldY) * tileExtent / west.size;
    final mesh = GpuTileMesh.of(
      TileMesh(
        id: west,
        fills: const [],
        lines: [
          LineLayerMesh(layerIndex('minor'), strokeAnchored([100, y, x, y], 3)),
        ],
      ),
    );
    final calls = _drawnBy(MapPainter(camera: _camera, tiles: [mesh]));
    expect(calls, contains('drawVertices'));
  });
}
