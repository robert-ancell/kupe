import 'package:kupe/src/render/node_sprite.dart';
import 'package:kupe/src/style/style.dart';
import 'package:test/test.dart';

/// The red, green, blue and alpha of the pixel at ([x], [y]).
List<int> _pixel(List<int> pixels, int size, int x, int y) {
  final at = (y * size + x) * 4;
  return pixels.sublist(at, at + 4);
}

void main() {
  for (final ratio in [1.0, 1.5, 2.0, 3.0]) {
    group('at $ratio pixels to a pixel', () {
      final size = NodeSprite.sizeFor(ratio);
      final pixels = NodeSprite.pixels(ratio);

      test('is the point and a pixel either side', () {
        expect(size, (NodeSprite.diameter * ratio).ceil() + 2);
        expect(pixels.length, size * size * 4);
      });

      test('is light in the middle', () {
        final fill = mapStyle[layerIndex('vertex')].colour;
        final middle = _pixel(pixels, size, size ~/ 2, size ~/ 2);
        expect(middle, [
          (fill >> 16) & 0xff,
          (fill >> 8) & 0xff,
          fill & 0xff,
          255,
        ]);
      });

      test('has a dark edge around it', () {
        final edge = mapStyle[layerIndex('vertex-edge')].colour;
        // Half way between the edge of the light middle and the outside.
        final radius =
            (NodeSprite.diameter + NodeSprite.innerDiameter) / 4 * ratio;
        final x = (size / 2 + radius).floor();
        final ring = _pixel(pixels, size, x, size ~/ 2);
        expect(ring[3], 255);
        expect(ring[0], closeTo((edge >> 16) & 0xff, 2));
      });

      test('is clear at the corners', () {
        expect(_pixel(pixels, size, 0, 0), [0, 0, 0, 0]);
        expect(_pixel(pixels, size, size - 1, size - 1), [0, 0, 0, 0]);
      });

      test('fades out at its edge rather than stopping', () {
        // Around the curve the outside of the disc is neither in nor out,
        // which is what makes it look round rather than stepped. Most of the
        // edge pixels, not an odd one.
        var partial = 0;
        for (var i = 3; i < pixels.length; i += 4) {
          if (pixels[i] > 0 && pixels[i] < 255) partial += 1;
        }
        expect(partial, greaterThanOrEqualTo(8));
      });

      test('is premultiplied, as the upload expects', () {
        for (var i = 0; i < pixels.length; i += 4) {
          final alpha = pixels[i + 3];
          expect(pixels[i], lessThanOrEqualTo(alpha));
          expect(pixels[i + 1], lessThanOrEqualTo(alpha));
          expect(pixels[i + 2], lessThanOrEqualTo(alpha));
        }
      });
    });
  }
}
