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

/// The triangles of a line that is the same width on screen at every zoom.
///
/// Each vertex is held as two parts: the point on the ground it belongs to,
/// and how far from that point it sits on screen. A line a fixed number of
/// pixels wide is exactly the same shape in pixels however far in the map is
/// zoomed; all that changes is how many pixels a unit of ground is. So the
/// triangles are built once, and a zoom is [at] — a multiply and an add for
/// each number — rather than building them again.
///
/// That is exact, not an approximation: every vertex the stroker makes is a
/// point on the line plus something proportional to the line's width, and
/// how finely a curve is cut up depends only on its radius in pixels, which
/// does not change.
class AnchoredTriangles {
  /// Where each vertex is tied to the ground, as alternating x and y in the
  /// units of the points it was built from.
  final Float32List anchors;

  /// How far each vertex sits from its anchor, as alternating x and y in
  /// pixels.
  final Float32List offsets;

  /// Creates a set of triangles.
  const AnchoredTriangles(this.anchors, this.offsets);

  /// Nothing at all.
  static final empty = AnchoredTriangles(Float32List(0), Float32List(0));

  /// How many vertices there are, three to a triangle.
  int get vertices => anchors.length ~/ 2;

  /// Whether there are none.
  bool get isEmpty => anchors.isEmpty;

  /// Where every vertex is when a pixel covers [unitsPerPixel] of the
  /// ground, as six numbers per triangle.
  ///
  /// Written into [into] if it is given and large enough, so that the same
  /// scratch space can serve every zoom rather than each one allocating.
  Float32List at(double unitsPerPixel, [Float32List? into]) {
    final out = into != null && into.length >= anchors.length
        ? into
        : Float32List(anchors.length);
    for (var i = 0; i < anchors.length; i++) {
      out[i] = anchors[i] + offsets[i] * unitsPerPixel;
    }
    return out;
  }

  /// These triangles followed by [other]'s.
  AnchoredTriangles followedBy(AnchoredTriangles other) => AnchoredTriangles(
    Float32List(anchors.length + other.anchors.length)
      ..setAll(0, anchors)
      ..setAll(anchors.length, other.anchors),
    Float32List(offsets.length + other.offsets.length)
      ..setAll(0, offsets)
      ..setAll(offsets.length, other.offsets),
  );
}

/// Builds the triangles that draw [points] as a line [width] pixels wide,
/// whatever the zoom.
///
/// The points are a flat list of alternating x and y on the ground.
///
/// Each segment becomes its own quad and each corner its own fan, so the
/// pieces overlap rather than sharing edges. That costs a few more vertices
/// than threading one strip through the line, but it holds up on the doubled
/// back and zero length ways that real data is full of, where a shared strip
/// turns inside out.
AnchoredTriangles strokeAnchored(
  List<double> points,
  double width, {
  LineCap cap = LineCap.butt,
  LineJoin join = LineJoin.miter,
  double miterLimit = 4,
}) {
  final half = width / 2;
  final out = _Triangles();

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
      _fan(out, xs[0], ys[0], half, 0, 2 * math.pi);
    }
    return out.build();
  }

  for (var i = 0; i + 1 < xs.length; i++) {
    final ax = xs[i], ay = ys[i], bx = xs[i + 1], by = ys[i + 1];
    final dx = bx - ax, dy = by - ay;
    final length = math.sqrt(dx * dx + dy * dy);
    // The direction is the same on the ground as on screen, the scale
    // between the two being the same both ways.
    final ux = dx / length, uy = dy / length;

    // A square end carries on half a width past the point it stops at.
    final before = cap == LineCap.square && i == 0 ? half : 0.0;
    final after = cap == LineCap.square && i + 2 == xs.length ? half : 0.0;

    // The normal to the segment, which is the direction to extrude in.
    final nx = -uy * half, ny = ux * half;
    final sx = -ux * before, sy = -uy * before;
    final ex = ux * after, ey = uy * after;
    out
      ..vertex(ax, ay, sx + nx, sy + ny)
      ..vertex(bx, by, ex + nx, ey + ny)
      ..vertex(bx, by, ex - nx, ey - ny)
      ..vertex(ax, ay, sx + nx, sy + ny)
      ..vertex(bx, by, ex - nx, ey - ny)
      ..vertex(ax, ay, sx - nx, sy - ny);
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
    );
  }

  if (cap == LineCap.round) {
    _fan(out, xs.first, ys.first, half, 0, 2 * math.pi);
    _fan(out, xs.last, ys.last, half, 0, 2 * math.pi);
  }

  return out.build();
}

/// Builds the triangles that draw [points] as a line [width] wide, in the
/// units of the points.
///
/// The points are a flat list of alternating x and y, and the result is a
/// flat list of six numbers per triangle.
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
}) => strokeAnchored(
  points,
  width / unitsPerPixel,
  cap: cap,
  join: join,
  miterLimit: miterLimit,
).at(unitsPerPixel);

/// Fills the corner at (bx, by) between the segments coming from a and going
/// to c, which the two quads leave open on the outside of the turn.
void _join(
  _Triangles out,
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double half,
  LineJoin join,
  double miterLimit,
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

  // The two outer corners, as offsets from the point the line turns at.
  final p1x = -iuy * half * side, p1y = iux * half * side;
  final p2x = -ouy * half * side, p2y = oux * half * side;

  switch (join) {
    case LineJoin.bevel:
      out.triangle(bx, by, 0, 0, p1x, p1y, p2x, p2y);
    case LineJoin.round:
      final from = math.atan2(p1y, p1x);
      final to = math.atan2(p2y, p2x);
      var sweep = to - from;
      while (sweep > math.pi) {
        sweep -= 2 * math.pi;
      }
      while (sweep < -math.pi) {
        sweep += 2 * math.pi;
      }
      _fan(out, bx, by, half, from, sweep);
    case LineJoin.miter:
      // The outer edges meet further out the sharper the corner, without
      // limit as it doubles back, so past the limit a bevel is drawn instead.
      final mx = p1x + p2x, my = p1y + p2y;
      final scale = mx * mx + my * my;
      if (scale == 0) {
        out.triangle(bx, by, 0, 0, p1x, p1y, p2x, p2y);
        return;
      }
      final reach = 2 * half * half / scale;
      final tipx = mx * reach, tipy = my * reach;
      final overshoot = math.sqrt(tipx * tipx + tipy * tipy) / half;
      if (overshoot > miterLimit) {
        out.triangle(bx, by, 0, 0, p1x, p1y, p2x, p2y);
      } else {
        out
          ..triangle(bx, by, 0, 0, p1x, p1y, tipx, tipy)
          ..triangle(bx, by, 0, 0, tipx, tipy, p2x, p2y);
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

/// Approximates an arc of [sweep] radians, [radius] pixels about (cx, cy),
/// with the fewest straight edges that keep it within [_arcTolerance] of the
/// curve.
void _fan(
  _Triangles out,
  double cx,
  double cy,
  double radius,
  double from,
  double sweep,
) {
  final steps = _arcSteps(radius, sweep.abs());
  final step = sweep / steps;
  var px = math.cos(from) * radius, py = math.sin(from) * radius;
  for (var i = 1; i <= steps; i++) {
    final angle = from + step * i;
    final qx = math.cos(angle) * radius, qy = math.sin(angle) * radius;
    out.triangle(cx, cy, 0, 0, px, py, qx, qy);
    px = qx;
    py = qy;
  }
}

/// Collects vertices as they are made.
class _Triangles {
  final _anchors = <double>[];
  final _offsets = <double>[];

  /// A vertex tied to (ax, ay) on the ground and (ox, oy) pixels from it.
  void vertex(double ax, double ay, double ox, double oy) {
    _anchors
      ..add(ax)
      ..add(ay);
    _offsets
      ..add(ox)
      ..add(oy);
  }

  /// A triangle whose three corners are all tied to (x, y), each at its own
  /// offset from it.
  void triangle(
    double x,
    double y,
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) {
    vertex(x, y, ax, ay);
    vertex(x, y, bx, by);
    vertex(x, y, cx, cy);
  }

  AnchoredTriangles build() => AnchoredTriangles(
    Float32List.fromList(_anchors),
    Float32List.fromList(_offsets),
  );
}
