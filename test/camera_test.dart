import 'dart:ui';

import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(800, 600);

void main() {
  test('puts its centre in the middle of the view', () {
    final camera = Camera(x: 0.25, y: 0.75, zoom: 12);
    final screen = camera.toScreen(0.25, 0.75, _size);
    expect(screen.dx, closeTo(400, 1e-9));
    expect(screen.dy, closeTo(300, 1e-9));
  });

  test('turns screen positions back into world positions', () {
    final camera = Camera(x: 0.25, y: 0.75, zoom: 12);
    const point = Offset(123, 456);
    final world = camera.toWorld(point, _size);
    final back = camera.toScreen(world.dx, world.dy, _size);
    expect(back.dx, closeTo(point.dx, 1e-6));
    expect(back.dy, closeTo(point.dy, 1e-6));
  });

  test('doubles the scale for each zoom level', () {
    final near = Camera(x: 0.5, y: 0.5, zoom: 11);
    final far = Camera(x: 0.5, y: 0.5, zoom: 10);
    expect(near.scale, closeTo(far.scale * 2, 1e-9));
  });

  test('draws a tile at its own size at its own zoom', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    expect(camera.pixelsPerTile(14), closeTo(tilePixels, 1e-9));
    expect(camera.pixelsPerTile(12), closeTo(tilePixels * 4, 1e-9));
  });

  test('keeps the place under the pointer still while zooming', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    const focus = Offset(700, 100);
    final before = camera.toWorld(focus, _size);
    final after = camera.zoomed(1.5, focus, _size).toWorld(focus, _size);
    expect(after.dx, closeTo(before.dx, 1e-9));
    expect(after.dy, closeTo(before.dy, 1e-9));
  });

  test('pans by exactly the distance dragged', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    final panned = camera.panned(const Offset(64, -32));
    final moved = panned.toScreen(0.5, 0.5, _size);
    expect(moved.dx, closeTo(400 + 64, 1e-6));
    expect(moved.dy, closeTo(300 - 32, 1e-6));
  });

  test('does not zoom past its limits', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    expect(camera.zoomed(100, Offset.zero, _size).zoom, Camera.maxZoom);
    expect(camera.zoomed(-100, Offset.zero, _size).zoom, Camera.minZoom);
  });

  test('asks for the tiles the view covers', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 14);
    final tiles = camera.tilesFor(_size, 14);
    // A tile is 256 pixels at zoom 14, so an 800 by 600 view spans four
    // columns and three rows at most.
    expect(tiles.length, lessThanOrEqualTo(4 * 4));
    expect(tiles, contains(OsmTile.of(14, 0.5, 0.5)));
  });

  test('asks for one tile when the whole world is one tile', () {
    final camera = Camera(x: 0.5, y: 0.5, zoom: 0);
    expect(camera.tilesFor(const Size(256, 256), 0), [const OsmTile(0, 0, 0)]);
  });

  test('round trips a place on the earth', () {
    final camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 16);
    expect(camera.latitude, closeTo(-36.85, 1e-9));
    expect(camera.longitude, closeTo(174.76, 1e-9));
  });

  group('at the edges of the world', () {
    test('comes round the world panning east past the antimeridian', () {
      final camera = Camera.at(latitude: 0, longitude: 179.99, zoom: 12);
      final panned = camera.panned(const Offset(-1000, 0));
      expect(panned.x, inInclusiveRange(0, 1));
      expect(panned.longitude, inInclusiveRange(-180, 180));
      expect(panned.longitude, lessThan(0));
    });

    test('stops at the top and the bottom', () {
      final camera = Camera.at(latitude: 85, longitude: 0, zoom: 3);
      expect(camera.panned(const Offset(0, 100000)).y, 0);
      expect(camera.panned(const Offset(0, -100000)).y, 1);
      expect(
        camera.panned(const Offset(0, 100000)).tilesFor(_size, 3),
        isNotEmpty,
      );
    });

    test(
      'covers a view across the antimeridian with tiles from both sides',
      () {
        final camera = Camera(x: 0, y: 0.5, zoom: 3);
        final tiles = camera.tilesFor(_size, 3);
        expect(tiles.map((t) => t.x), containsAll([0, 7]));
        expect(tiles.every((t) => t.x >= 0 && t.x < 8), isTrue);
        expect(tiles.toSet().length, tiles.length);
      },
    );

    test(
      'asks for each tile once when the world is narrower than the view',
      () {
        final camera = Camera(x: 0.3, y: 0.5, zoom: 1);
        final tiles = camera.tilesFor(const Size(2000, 400), 1);
        expect(tiles.toSet().length, tiles.length);
      },
    );

    test('draws what is over the antimeridian beside the middle', () {
      final camera = Camera(x: 0.001, y: 0.5, zoom: 10);
      final screen = camera.toScreen(0.999, 0.5, _size);
      expect(screen.dx, closeTo(400 - 0.002 * camera.scale, 1e-6));
      final tile = OsmTile.of(10, 0.9995, 0.5);
      final origin = camera.tileToScreen(tile, _size);
      expect(
        origin.dx,
        closeTo(400 + (tile.worldX - 1 - 0.001) * camera.scale, 1e-6),
      );
    });

    test('asks about the ground either side of the antimeridian', () {
      final camera = Camera(x: 0, y: 0.5, zoom: 10);
      final boxes = camera.groundBounds(_size);
      expect(boxes, hasLength(2));
      for (final box in boxes) {
        expect(box.minLongitude, lessThanOrEqualTo(box.maxLongitude));
        expect(box.minLongitude, greaterThanOrEqualTo(-180));
        expect(box.maxLongitude, lessThanOrEqualTo(180));
      }
      expect(
        Camera(x: 0.5, y: 0.5, zoom: 10).groundBounds(_size),
        hasLength(1),
      );
    });
  });
}
