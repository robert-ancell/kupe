import 'dart:math' as math;
import 'dart:typed_data';

/// How the ends of a stroked line are finished.
enum LineCap {
  /// Stop square at the last point.
  butt,

  /// Carry on half a width past the last point.
  square,

  /// Finish with a half disc.
  round,
}

/// How the corners of a stroked line are filled in.
enum LineJoin {
  /// Bridge the corner with a single triangle.
  bevel,

  /// Fill the corner with a fan, which reads as a curve at road widths.
  round,

  /// Carry the outer edges to where they meet, falling back to a bevel on
  /// corners sharp enough to send that point a long way from the line.
  miter,
}

/// Builds the triangles that draw [points] as a line [width] wide.
///
/// The points are a flat list of alternating x and y, and the result is a
/// flat list of six numbers per triangle.
///
/// Each segment becomes its own quad and each corner its own fan, so the
/// pieces overlap rather than sharing edges. That costs a few more vertices
/// than threading one strip through the line, but it holds up on the doubled
/// back and zero length ways that real data is full of, where a shared strip
/// turns inside out.
///
/// [unitsPerPixel] says how large the coordinates are compared to what will
/// be on screen, which is what decides how finely a curve has to be cut up.
/// Without it a round join is either visibly faceted or made of far more
/// triangles than anyone can see.
Float32List strokePolyline(
  List<double> points,
  double width, {
  LineCap cap = LineCap.butt,
  LineJoin join = LineJoin.miter,
  double miterLimit = 4,
  double unitsPerPixel = 1,
}) {
  final half = width / 2;
  final out = <double>[];

  // Drop points that repeat, which would give a segment no direction.
  final xs = <double>[];
  final ys = <double>[];
  for (var i = 0; i + 1 < points.length; i += 2) {
    final x = points[i];
    final y = points[i + 1];
    if (xs.isNotEmpty && xs.last == x && ys.last == y) continue;
    xs.add(x);
    ys.add(y);
  }
  if (xs.length < 2) {
    if (xs.length == 1 && cap == LineCap.round) {
      _fan(out, xs[0], ys[0], half, 0, 2 * math.pi, unitsPerPixel);
    }
    return Float32List.fromList(out);
  }

  for (var i = 0; i + 1 < xs.length; i++) {
    var ax = xs[i], ay = ys[i], bx = xs[i + 1], by = ys[i + 1];
    final dx = bx - ax, dy = by - ay;
    final length = math.sqrt(dx * dx + dy * dy);
    final ux = dx / length, uy = dy / length;

    if (cap == LineCap.square) {
      if (i == 0) {
        ax -= ux * half;
        ay -= uy * half;
      }
      if (i + 2 == xs.length) {
        bx += ux * half;
        by += uy * half;
      }
    }

    // The normal to the segment, which is the direction to extrude in.
    final nx = -uy * half, ny = ux * half;
    _quad(
      out,
      ax + nx,
      ay + ny,
      bx + nx,
      by + ny,
      bx - nx,
      by - ny,
      ax - nx,
      ay - ny,
    );
  }

  for (var i = 1; i + 1 < xs.length; i++) {
    _join(
      out,
      xs[i - 1],
      ys[i - 1],
      xs[i],
      ys[i],
      xs[i + 1],
      ys[i + 1],
      half,
      join,
      miterLimit,
      unitsPerPixel,
    );
  }

  if (cap == LineCap.round) {
    _fan(out, xs.first, ys.first, half, 0, 2 * math.pi, unitsPerPixel);
    _fan(out, xs.last, ys.last, half, 0, 2 * math.pi, unitsPerPixel);
  }

  return Float32List.fromList(out);
}

/// Fills the corner at (bx, by) between the segments coming from a and going
/// to c, which the two quads leave open on the outside of the turn.
void _join(
  List<double> out,
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double half,
  LineJoin join,
  double miterLimit,
  double unitsPerPixel,
) {
  final inx = bx - ax, iny = by - ay;
  final outx = cx - bx, outy = cy - by;
  final inLength = math.sqrt(inx * inx + iny * iny);
  final outLength = math.sqrt(outx * outx + outy * outy);
  final iux = inx / inLength, iuy = iny / inLength;
  final oux = outx / outLength, ouy = outy / outLength;

  // Which way the line turns decides which side the gap is on.
  final turn = iux * ouy - iuy * oux;
  if (turn == 0) return;
  final side = turn > 0 ? -1.0 : 1.0;

  final p1x = bx + -iuy * half * side, p1y = by + iux * half * side;
  final p2x = bx + -ouy * half * side, p2y = by + oux * half * side;

  switch (join) {
    case LineJoin.bevel:
      _triangle(out, bx, by, p1x, p1y, p2x, p2y);
    case LineJoin.round:
      final from = math.atan2(p1y - by, p1x - bx);
      final to = math.atan2(p2y - by, p2x - bx);
      var sweep = to - from;
      while (sweep > math.pi) {
        sweep -= 2 * math.pi;
      }
      while (sweep < -math.pi) {
        sweep += 2 * math.pi;
      }
      _fan(out, bx, by, half, from, sweep, unitsPerPixel);
    case LineJoin.miter:
      // The outer edges meet further out the sharper the corner, without
      // limit as it doubles back, so past the limit a bevel is drawn instead.
      final mx = p1x + p2x - 2 * bx, my = p1y + p2y - 2 * by;
      final scale = mx * mx + my * my;
      if (scale == 0) {
        _triangle(out, bx, by, p1x, p1y, p2x, p2y);
        return;
      }
      final reach = 2 * half * half / scale;
      final tipx = bx + mx * reach, tipy = by + my * reach;
      final overshoot =
          math.sqrt((tipx - bx) * (tipx - bx) + (tipy - by) * (tipy - by)) /
          half;
      if (overshoot > miterLimit) {
        _triangle(out, bx, by, p1x, p1y, p2x, p2y);
      } else {
        _triangle(out, bx, by, p1x, p1y, tipx, tipy);
        _triangle(out, bx, by, tipx, tipy, p2x, p2y);
      }
  }
}

/// The furthest a straight edge is allowed to fall inside the curve it stands
/// in for, in pixels. A third of a pixel is below what anyone can pick out,
/// and it keeps a road corner down to a few triangles instead of a dozen.
const _arcTolerance = 0.33;

/// How many straight edges an arc of [sweep] radians on a circle of [radius]
/// pixels needs before the gap between edge and curve stops being visible.
/// A wider line needs more, a sharper corner needs more, and a line thinner
/// than the tolerance needs only one.
int _arcSteps(double radius, double sweep) {
  if (radius <= _arcTolerance) return 1;
  final widest = 2 * math.acos(1 - _arcTolerance / radius);
  return math.max(1, (sweep / widest).ceil());
}

/// Approximates an arc of [sweep] radians with the fewest straight edges that
/// keep it within [_arcTolerance] of the curve.
void _fan(
  List<double> out,
  double cx,
  double cy,
  double radius,
  double from,
  double sweep,
  double unitsPerPixel,
) {
  final steps = _arcSteps(radius / unitsPerPixel, sweep.abs());
  final step = sweep / steps;
  var px = cx + math.cos(from) * radius, py = cy + math.sin(from) * radius;
  for (var i = 1; i <= steps; i++) {
    final angle = from + step * i;
    final qx = cx + math.cos(angle) * radius,
        qy = cy + math.sin(angle) * radius;
    _triangle(out, cx, cy, px, py, qx, qy);
    px = qx;
    py = qy;
  }
}

void _triangle(
  List<double> out,
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  out.addAll([ax, ay, bx, by, cx, cy]);
}

void _quad(
  List<double> out,
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  out.addAll([ax, ay, bx, by, cx, cy, ax, ay, cx, cy, dx, dy]);
}
