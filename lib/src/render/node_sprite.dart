import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../style/style.dart';

/// The picture every point a line can be taken hold of is drawn with.
///
/// A point is the same size on screen at every zoom, so it does not need
/// triangles of its own: one small picture is uploaded once and drawn at
/// every point in a single call, each copy placed rather than built. That is
/// also what makes it round. Triangles fine enough to pass for a circle at
/// seven pixels across are dozens to a point, and still show their corners
/// without the smoothing the rest of the map is drawn without.
class NodeSprite {
  /// The picture.
  final ui.Image image;

  /// How many of the picture's pixels there are to a pixel on screen.
  ///
  /// Made at the screen's own density, so that it is drawn one to one rather
  /// than stretched.
  final double pixelRatio;

  NodeSprite._(this.image, this.pixelRatio);

  /// How far across the point is on screen, edge included.
  static double get diameter => mapStyle[layerIndex('vertex-edge')].width;

  /// How far across the light middle of it is.
  static double get innerDiameter => mapStyle[layerIndex('vertex')].width;

  /// How many pixels across the picture is at [pixelRatio]: the point, and a
  /// pixel either side for its edge to fade into.
  static int sizeFor(double pixelRatio) => (diameter * pixelRatio).ceil() + 2;

  /// Makes the picture for a screen of [pixelRatio].
  static Future<NodeSprite> create(double pixelRatio) {
    final size = sizeFor(pixelRatio);
    final done = Completer<NodeSprite>();
    ui.decodeImageFromPixels(
      pixels(pixelRatio),
      size,
      size,
      ui.PixelFormat.rgba8888,
      (image) => done.complete(NodeSprite._(image, pixelRatio)),
    );
    return done.future;
  }

  /// The picture's pixels, as premultiplied red, green, blue and alpha.
  ///
  /// Worked out here rather than drawn, so that making it needs nothing
  /// from the graphics card but the upload. Each pixel is sampled sixteen
  /// times and averaged, which is what gives the edge its smoothness.
  static Uint8List pixels(double pixelRatio) {
    final size = sizeFor(pixelRatio);
    final outer = diameter * pixelRatio / 2;
    final inner = innerDiameter * pixelRatio / 2;
    final middle = size / 2;
    final edge = mapStyle[layerIndex('vertex-edge')].colour;
    final fill = mapStyle[layerIndex('vertex')].colour;

    const samples = 4;
    final out = Uint8List(size * size * 4);
    for (var py = 0; py < size; py++) {
      for (var px = 0; px < size; px++) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        for (var sy = 0; sy < samples; sy++) {
          for (var sx = 0; sx < samples; sx++) {
            final x = px + (sx + 0.5) / samples - middle;
            final y = py + (sy + 0.5) / samples - middle;
            final d = math.sqrt(x * x + y * y);
            if (d > outer) continue;
            final colour = d > inner ? edge : fill;
            final alpha = ((colour >> 24) & 0xff) / 255;
            r += ((colour >> 16) & 0xff) * alpha;
            g += ((colour >> 8) & 0xff) * alpha;
            b += (colour & 0xff) * alpha;
            a += alpha * 255;
          }
        }
        const count = samples * samples;
        final at = (py * size + px) * 4;
        out[at] = (r / count).round();
        out[at + 1] = (g / count).round();
        out[at + 2] = (b / count).round();
        out[at + 3] = (a / count).round();
      }
    }
    return out;
  }

  /// Lets go of the picture.
  void dispose() => image.dispose();
}
