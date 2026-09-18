import 'dart:ui';

import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:test/test.dart';

const _size = Size(800, 600);

void main() {
  test('puts its centre in the middle of the view', () {
    const camera = Camera(x: 0.25, y: 0.75, zoom: 12);
    final screen = camera.toScreen(0.25, 0.75, _size);
    expect(screen.dx, closeTo(400, 1e-9));
    expect(screen.dy, closeTo(300, 1e-9));
  });

  test('turns screen positions back into world positions', () {
    const camera = Camera(x: 0.25, y: 0.75, zoom: 12);
    const point = Offset(123, 456);
    final world = camera.toWorld(point, _size);
    final back = camera.toScreen(world.dx, world.dy, _size);
    expect(back.dx, closeTo(point.dx, 1e-6));
    expect(back.dy, closeTo(point.dy, 1e-6));
  });

  test('doubles the scale for each zoom level', () {
    const near = Camera(x: 0.5, y: 0.5, zoom: 11);
    const far = Camera(x: 0.5, y: 0.5, zoom: 10);
    expect(near.scale, closeTo(far.scale * 2, 1e-9));
  });

  test('draws a tile at its own size at its own zoom', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    expect(camera.pixelsPerTile(14), closeTo(tilePixels, 1e-9));
    expect(camera.pixelsPerTile(12), closeTo(tilePixels * 4, 1e-9));
  });

  test('keeps the place under the pointer still while zooming', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    const focus = Offset(700, 100);
    final before = camera.toWorld(focus, _size);
    final after = camera.zoomed(1.5, focus, _size).toWorld(focus, _size);
    expect(after.dx, closeTo(before.dx, 1e-9));
    expect(after.dy, closeTo(before.dy, 1e-9));
  });

  test('pans by exactly the distance dragged', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    final panned = camera.panned(const Offset(64, -32));
    final moved = panned.toScreen(0.5, 0.5, _size);
    expect(moved.dx, closeTo(400 + 64, 1e-6));
    expect(moved.dy, closeTo(300 - 32, 1e-6));
  });

  test('does not zoom past its limits', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    expect(camera.zoomed(100, Offset.zero, _size).zoom, Camera.maxZoom);
    expect(camera.zoomed(-100, Offset.zero, _size).zoom, Camera.minZoom);
  });

  test('asks for the tiles the view covers', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    final tiles = camera.tilesFor(_size, 14);
    // A tile is 256 pixels at zoom 14, so an 800 by 600 view spans four
    // columns and three rows at most.
    expect(tiles.length, lessThanOrEqualTo(4 * 4));
    expect(tiles, contains(TileId.of(14, 0.5, 0.5)));
  });

  test('asks for one tile when the whole world is one tile', () {
    const camera = Camera(x: 0.5, y: 0.5, zoom: 0);
    expect(camera.tilesFor(const Size(256, 256), 0), [const TileId(0, 0, 0)]);
  });

  test('round trips a place on the earth', () {
    final camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 16);
    expect(camera.latitude, closeTo(-36.85, 1e-9));
    expect(camera.longitude, closeTo(174.76, 1e-9));
  });
}
