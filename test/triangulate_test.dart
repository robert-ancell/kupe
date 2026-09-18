import 'package:kupe/src/render/triangulate.dart';
import 'package:test/test.dart';

/// The total area of a triangle list, which must match the area of the
/// polygon it came from if every part was covered exactly once.
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

void main() {
  test('cuts a square into two triangles', () {
    final out = triangulate([0, 0, 10, 0, 10, 10, 0, 10])!;
    expect(out.length, 12);
    expect(_areaOf(out), closeTo(100, 1e-6));
  });

  test('closes a ring that repeats its first point', () {
    final out = triangulate([0, 0, 10, 0, 10, 10, 0, 10, 0, 0])!;
    expect(_areaOf(out), closeTo(100, 1e-6));
  });

  test('cuts the same square wound either way', () {
    final clockwise = triangulate([0, 0, 10, 0, 10, 10, 0, 10])!;
    final anticlockwise = triangulate([0, 10, 10, 10, 10, 0, 0, 0])!;
    expect(_areaOf(clockwise), closeTo(_areaOf(anticlockwise), 1e-6));
  });

  test('cuts a concave polygon', () {
    final out = triangulate([0, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10])!;
    expect(_areaOf(out), closeTo(64, 1e-6));
  });

  test('leaves a hole uncovered', () {
    final out = triangulate(
      [0, 0, 10, 0, 10, 10, 0, 10],
      holes: [
        [3, 3, 7, 3, 7, 7, 3, 7],
      ],
    )!;
    expect(_areaOf(out), closeTo(100 - 16, 1e-6));
  });

  test('leaves two holes uncovered', () {
    final out = triangulate(
      [0, 0, 20, 0, 20, 10, 0, 10],
      holes: [
        [2, 2, 4, 2, 4, 4, 2, 4],
        [12, 2, 16, 2, 16, 6, 12, 6],
      ],
    )!;
    expect(_areaOf(out), closeTo(200 - 4 - 16, 1e-6));
  });

  test('drops a polygon with too few points', () {
    expect(triangulate([0, 0, 1, 1]), isNull);
    expect(triangulate([0, 0, 1, 1, 0, 0]), isNull);
  });

  test('drops repeated points rather than emitting slivers', () {
    final out = triangulate([0, 0, 0, 0, 10, 0, 10, 10, 10, 10, 0, 10])!;
    expect(_areaOf(out), closeTo(100, 1e-6));
  });

  test('still finishes on a ring that crosses itself', () {
    final out = triangulate([0, 0, 10, 10, 10, 0, 0, 10]);
    expect(out, isNotNull);
    expect(out!.length, greaterThan(0));
  });

  test('cuts a long thin ring without stalling', () {
    final ring = <double>[];
    for (var i = 0; i < 200; i++) {
      ring.addAll([i.toDouble(), i.isEven ? 0 : 0.5]);
    }
    for (var i = 199; i >= 0; i--) {
      ring.addAll([i.toDouble(), 2]);
    }
    expect(triangulate(ring), isNotNull);
  });
}
