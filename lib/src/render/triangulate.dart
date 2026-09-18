import 'dart:typed_data';

/// Cuts a polygon into the triangles the GPU draws it as.
///
/// The polygon is given as an outer ring and any number of holes, each a flat
/// list of alternating x and y. Rings may be given in either direction and
/// need not repeat their first point at the end.
///
/// Returns the triangles as a flat list of six numbers each, or null if the
/// polygon is degenerate. Rings that cross themselves, which OpenStreetMap
/// does contain, are cut as well as they can be rather than rejected, so that
/// a mistagged building still draws.
Float32List? triangulate(
  List<double> outer, {
  List<List<double>> holes = const [],
}) {
  var start = _ring(outer, clockwise: true);
  if (start == null) return null;
  if (holes.isNotEmpty) start = _eliminateHoles(start, holes);

  final triangles = <double>[];
  _clipEars(start, triangles);
  if (triangles.isEmpty) return null;
  return Float32List.fromList(triangles);
}

/// The signed area of a ring, positive when it runs clockwise on a screen
/// whose y axis points down.
double signedArea(List<double> ring) {
  var sum = 0.0;
  final n = ring.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    sum += (ring[j * 2] - ring[i * 2]) * (ring[i * 2 + 1] + ring[j * 2 + 1]);
  }
  return sum / 2;
}

/// A vertex of the polygon being cut, in a circular doubly linked list.
class _Vertex {
  final double x;
  final double y;
  late _Vertex prev;
  late _Vertex next;

  _Vertex(this.x, this.y);
}

/// Builds a linked ring wound in the requested direction, dropping the
/// repeated closing point and any point equal to the one before it.
///
/// Ear clipping needs one consistent direction to tell a corner from a notch.
/// The outer ring is made clockwise and holes anticlockwise, so that once a
/// hole is bridged in, its corners read as notches of the ring it joined.
_Vertex? _ring(List<double> points, {required bool clockwise}) {
  var n = points.length ~/ 2;
  if (n > 1 &&
      points[0] == points[(n - 1) * 2] &&
      points[1] == points[(n - 1) * 2 + 1]) {
    n -= 1;
  }
  if (n < 3) return null;

  final forwards = (signedArea(points) > 0) == clockwise;
  _Vertex? last;
  for (var k = 0; k < n; k++) {
    final i = forwards ? k : n - 1 - k;
    final vertex = _Vertex(points[i * 2], points[i * 2 + 1]);
    if (last != null && last.x == vertex.x && last.y == vertex.y) continue;
    last = _insertAfter(last, vertex);
  }
  if (last == null || last.next == last || last.next.next == last) return null;
  return last.next;
}

_Vertex _insertAfter(_Vertex? at, _Vertex vertex) {
  if (at == null) {
    vertex.prev = vertex;
    vertex.next = vertex;
  } else {
    vertex.next = at.next;
    vertex.prev = at;
    at.next.prev = vertex;
    at.next = vertex;
  }
  return vertex;
}

void _remove(_Vertex vertex) {
  vertex.prev.next = vertex.next;
  vertex.next.prev = vertex.prev;
}

/// Joins every hole into the outer ring, leaving one ring that encloses the
/// same area and can be cut in one pass.
///
/// Holes are taken left to right, because bridging one may pass through the
/// space another would have used.
_Vertex _eliminateHoles(_Vertex outer, List<List<double>> holes) {
  final leftmost = <_Vertex>[];
  for (final hole in holes) {
    final ring = _ring(hole, clockwise: false);
    if (ring != null) leftmost.add(_leftmost(ring));
  }
  leftmost.sort((a, b) => a.x.compareTo(b.x));

  for (final hole in leftmost) {
    final bridge = _bridgeTo(outer, hole);
    if (bridge != null) _split(bridge, hole);
  }
  return outer;
}

_Vertex _leftmost(_Vertex ring) {
  var found = ring;
  var at = ring.next;
  while (!identical(at, ring)) {
    if (at.x < found.x || (at.x == found.x && at.y < found.y)) found = at;
    at = at.next;
  }
  return found;
}

/// Cuts one ring into two, or joins two rings into one, along the line
/// between [a] and [b]. Bridging a hole is the second of those.
void _split(_Vertex a, _Vertex b) {
  final a2 = _Vertex(a.x, a.y);
  final b2 = _Vertex(b.x, b.y);
  final an = a.next;
  final bp = b.prev;

  a.next = b;
  b.prev = a;
  a2.next = an;
  an.prev = a2;
  b2.next = a2;
  a2.prev = b2;
  bp.next = b2;
  b2.prev = bp;
}

/// The vertex of the outer ring that [hole] can be joined to without the
/// bridge crossing an edge.
///
/// Cast a ray west from the leftmost point of the hole and take the edge it
/// first meets; that edge's left corner is visible, unless another corner of
/// the polygon is tucked into the triangle between the two, so those are
/// checked as well and the one at the shallowest angle wins.
_Vertex? _bridgeTo(_Vertex outer, _Vertex hole) {
  final hx = hole.x;
  final hy = hole.y;
  var reach = -double.maxFinite;
  _Vertex? found;

  var at = outer;
  do {
    final next = at.next;
    if (hy <= at.y && hy >= next.y && next.y != at.y) {
      final x = at.x + (hy - at.y) * (next.x - at.x) / (next.y - at.y);
      if (x <= hx && x > reach) {
        reach = x;
        found = at.x < next.x ? at : next;
      }
    }
    at = next;
  } while (!identical(at, outer));
  if (found == null) return null;

  final stop = found;
  final mx = found.x;
  final my = found.y;
  var shallowest = double.maxFinite;

  at = found;
  do {
    if (hx >= at.x &&
        at.x >= mx &&
        hx != at.x &&
        _inTriangle(
          hy < my ? hx : reach,
          hy,
          mx,
          my,
          hy < my ? reach : hx,
          hy,
          at.x,
          at.y,
        )) {
      final tangent = (hy - at.y).abs() / (hx - at.x);
      if (_locallyInside(at, hole) &&
          (tangent < shallowest ||
              (tangent == shallowest && at.x > found!.x))) {
        found = at;
        shallowest = tangent;
      }
    }
    at = at.next;
  } while (!identical(at, stop));

  return found;
}

/// Whether the line from [a] to [b] leaves [a] on the inside of the ring,
/// which it does when it falls within the wedge [a] turns through.
bool _locallyInside(_Vertex a, _Vertex b) => _cross(a.prev, a, a.next) < 0
    ? _cross(a, b, a.next) >= 0 && _cross(a, a.prev, b) >= 0
    : _cross(a, b, a.prev) < 0 || _cross(a, a.next, b) < 0;

/// Whether the ring turns inwards at [v], leaving a notch rather than a
/// corner that could be cut off.
bool _isReflex(_Vertex v) => _cross(v.prev, v, v.next) >= 0;

double _cross(_Vertex a, _Vertex b, _Vertex c) =>
    (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y);

/// Repeatedly snips off a corner that holds no other vertex, which is the
/// whole of ear clipping.
///
/// A ring that crosses itself can reach a state with no such corner. Rather
/// than give up and drop the shape, a corner is taken anyway once every
/// vertex has been tried, which keeps the pass finite and draws something
/// close to the intended outline.
void _clipEars(_Vertex start, List<double> out) {
  var ear = start;
  var remaining = _count(start);
  var tried = 0;

  while (remaining > 3) {
    if (_isEar(ear) || tried > remaining) {
      out.addAll([
        ear.prev.x,
        ear.prev.y,
        ear.x,
        ear.y,
        ear.next.x,
        ear.next.y,
      ]);
      final next = ear.next;
      _remove(ear);
      ear = next.next;
      remaining -= 1;
      tried = 0;
    } else {
      ear = ear.next;
      tried += 1;
    }
  }

  out.addAll([ear.prev.x, ear.prev.y, ear.x, ear.y, ear.next.x, ear.next.y]);
}

int _count(_Vertex start) {
  var n = 1;
  var at = start.next;
  while (!identical(at, start)) {
    n += 1;
    at = at.next;
  }
  return n;
}

bool _isEar(_Vertex ear) {
  final a = ear.prev;
  final b = ear;
  final c = ear.next;
  if (_cross(a, b, c) >= 0) return false;

  var at = c.next;
  while (!identical(at, a)) {
    if (_inTriangle(a.x, a.y, b.x, b.y, c.x, c.y, at.x, at.y) &&
        _isReflex(at)) {
      return false;
    }
    at = at.next;
  }
  return true;
}

bool _inTriangle(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double px,
  double py,
) {
  return (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0 &&
      (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0 &&
      (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0;
}
