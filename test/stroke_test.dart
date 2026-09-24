import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kupe/src/render/stroke.dart';
import 'package:test/test.dart';

/// The area the triangles cover, counting overlap once per triangle. Joins
/// are drawn over the segments they bridge, so this is an upper bound on the
/// area of the stroke rather than its exact area.
double _areaOf(List<double> triangles) {
  var sum = 0.0;
  for (var i = 0; i < triangles.length; i += 6) {
    final ax = triangles[i], ay = triangles[i + 1];
    final bx = triangles[i + 2], by = triangles[i + 3];
    final cx = triangles[i + 4], cy = triangles[i + 5];
    sum += ((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)).abs() / 2;
  }
  return sum;
}

({double minX, double minY, double maxX, double maxY}) _boundsOf(
  List<double> triangles,
) {
  var minX = double.maxFinite, minY = double.maxFinite;
  var maxX = -double.maxFinite, maxY = -double.maxFinite;
  for (var i = 0; i < triangles.length; i += 2) {
    minX = triangles[i] < minX ? triangles[i] : minX;
    maxX = triangles[i] > maxX ? triangles[i] : maxX;
    minY = triangles[i + 1] < minY ? triangles[i + 1] : minY;
    maxY = triangles[i + 1] > maxY ? triangles[i + 1] : maxY;
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

void main() {
  test('strokes a straight line as one quad', () {
    final out = strokePolyline([0, 0, 100, 0], 4);
    expect(out.length, 12);
    expect(_areaOf(out), closeTo(400, 1e-3));
  });

  test('extrudes to half the width either side', () {
    final out = strokePolyline([0, 0, 100, 0], 10);
    final bounds = _boundsOf(out);
    expect(bounds.minY, closeTo(-5, 1e-6));
    expect(bounds.maxY, closeTo(5, 1e-6));
    expect(bounds.minX, closeTo(0, 1e-6));
    expect(bounds.maxX, closeTo(100, 1e-6));
  });

  test('a square cap reaches half a width past each end', () {
    final out = strokePolyline([0, 0, 100, 0], 10, cap: LineCap.square);
    final bounds = _boundsOf(out);
    expect(bounds.minX, closeTo(-5, 1e-6));
    expect(bounds.maxX, closeTo(105, 1e-6));
  });

  test('a round cap stays within a third of a pixel of a half circle', () {
    final out = strokePolyline([0, 0, 100, 0], 10, cap: LineCap.round);
    final bounds = _boundsOf(out);
    // Flat edges stand in for the curve, so the cap may fall short of the
    // half width but must never overshoot it.
    expect(bounds.minX, lessThanOrEqualTo(0));
    expect(bounds.minX, greaterThanOrEqualTo(-5));
    expect(bounds.maxX, greaterThanOrEqualTo(100));
    expect(bounds.maxX, lessThanOrEqualTo(105));
    expect(bounds.minX, closeTo(-5, 0.34));
    expect(bounds.maxX, closeTo(105, 0.34));
  });

  test('a round cap is cut more finely on a wider line', () {
    final thin = strokePolyline([5, 5], 4, cap: LineCap.round);
    final thick = strokePolyline([5, 5], 80, cap: LineCap.round);
    expect(thick.length, greaterThan(thin.length));
  });

  test('a round cap is cut more coarsely when drawn smaller', () {
    final near = strokePolyline([5, 5], 40, cap: LineCap.round);
    final far = strokePolyline(
      [5, 5],
      40,
      cap: LineCap.round,
      unitsPerPixel: 20,
    );
    expect(far.length, lessThan(near.length));
  });

  test('fills the corner of a right angle turn', () {
    for (final join in LineJoin.values) {
      final out = strokePolyline([0, 0, 100, 0, 100, 100], 10, join: join);
      // Two segments of 1000 plus whatever fills the corner, which cannot be
      // more than the square the corner sits in.
      expect(_areaOf(out), greaterThan(2000), reason: '$join');
      expect(_areaOf(out), lessThan(2000 + 100), reason: '$join');
    }
  });

  test('fills a corner turning either way the same', () {
    final left = _areaOf(strokePolyline([0, 0, 100, 0, 100, 100], 10));
    final right = _areaOf(strokePolyline([0, 0, 100, 0, 100, -100], 10));
    expect(left, closeTo(right, 1e-6));
  });

  test('a miter on a sharp corner falls back to a bevel', () {
    final sharp = strokePolyline(
      [0, 0, 100, 0, 0, 1],
      10,
      join: LineJoin.miter,
      miterLimit: 4,
    );
    final bounds = _boundsOf(sharp);
    expect(bounds.maxX, lessThan(100 + 10 * 4));
  });

  test('drops repeated points rather than dividing by zero', () {
    final out = strokePolyline([0, 0, 0, 0, 100, 0, 100, 0], 4);
    expect(out.length, 12);
    expect(out.every((v) => v.isFinite), isTrue);
  });

  test('draws nothing for a line with no length', () {
    expect(strokePolyline([5, 5], 4), isEmpty);
    expect(strokePolyline([5, 5, 5, 5], 4), isEmpty);
    expect(strokePolyline([], 4), isEmpty);
  });

  test('draws a dot for a single point with a round cap', () {
    final out = strokePolyline([5, 5], 10, cap: LineCap.round);
    // A polygon inscribed in the circle: no larger than the disc, and no
    // smaller than the disc a third of a pixel inside it.
    expect(_areaOf(out), lessThanOrEqualTo(math.pi * 5 * 5));
    expect(_areaOf(out), greaterThanOrEqualTo(math.pi * 4.67 * 4.67));
  });

  test('a way doubling back on itself stays finite', () {
    final out = strokePolyline([0, 0, 100, 0, 0, 0], 10);
    expect(out.every((v) => v.isFinite), isTrue);
  });

  group('one build for every zoom', () {
    // A zig-zag with a gentle corner, a right angle and one sharp enough to
    // be past the miter limit, so every kind of join is made.
    const ground = <double>[0, 0, 40, 3, 40, 40, 44, -30, 90, -28];

    for (final join in LineJoin.values) {
      for (final cap in LineCap.values) {
        test('comes out as if stroked on screen, $join, $cap', () {
          const width = 5.0;
          final built = strokeAnchored(ground, width, cap: cap, join: join);
          for (final unitsPerPixel in [0.01, 0.37, 1.0, 8.0, 250.0]) {
            // The same line stroked where it is on screen, a pixel a unit.
            final onScreen = strokeAnchored(
              [for (final value in ground) value / unitsPerPixel],
              width,
              cap: cap,
              join: join,
            ).at(1);
            final placed = built.at(unitsPerPixel);
            expect(placed.length, onScreen.length, reason: '$unitsPerPixel');
            for (var i = 0; i < placed.length; i++) {
              expect(
                placed[i] / unitsPerPixel,
                closeTo(onScreen[i], 1e-3),
                reason: 'number $i at $unitsPerPixel units a pixel',
              );
            }
          }
        });
      }
    }

    test('places into the room it is given rather than making more', () {
      final built = strokeAnchored([0, 0, 10, 0, 10, 10], 4);
      final room = Float32List(built.anchors.length + 10);
      expect(identical(built.at(2, room), room), isTrue);
      final small = Float32List(1);
      expect(identical(built.at(2, small), small), isFalse);
    });
  });
}
