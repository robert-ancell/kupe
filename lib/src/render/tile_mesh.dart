import 'dart:typed_data';
import 'dart:ui';

import 'package:osm/osm.dart';

import 'stroke.dart';

/// The side of a tile in the local coordinates geometry is stored in.
///
/// Positions are held relative to their tile and as 32 bit floats, which only
/// carry about seven digits. Spread over the whole world that would land
/// vertices metres from where they belong; spread over one tile it is well
/// under a millimetre. The value matches the extent vector tiles use.
const tileExtent = 4096.0;

/// The triangles of one filled layer of one tile.
class LayerMesh {
  /// The index of the layer in the style.
  final int layer;

  /// The triangles, as a flat list of six numbers each, in tile coordinates.
  final Float32List triangles;

  /// Creates a layer's triangles.
  const LayerMesh(this.layer, this.triangles);

  /// How many vertices the layer holds.
  int get vertices => triangles.length ~/ 2;
}

/// The triangles of one stroked layer of one tile.
///
/// Held as ground and pixels apart, so the same triangles serve every zoom:
/// see [AnchoredTriangles].
class LineLayerMesh {
  /// The index of the layer in the style.
  final int layer;

  /// The triangles, anchored in tile coordinates.
  final AnchoredTriangles triangles;

  /// Creates a layer's triangles.
  const LineLayerMesh(this.layer, this.triangles);

  /// How many vertices the layer holds.
  int get vertices => triangles.vertices;
}

/// Everything drawn for one tile, ready to hand to the GPU.
///
/// Building this is the expensive part of drawing a map, and it is done once
/// per tile rather than once per frame or once per zoom. A frame then costs
/// one draw call per layer present, whatever the tile holds.
class TileMesh {
  /// Which tile this covers.
  final OsmTile id;

  /// The filled layers, in style order.
  ///
  /// A filled shape covers the same ground whatever the zoom, so these go to
  /// the GPU once and stay there.
  final List<LayerMesh> fills;

  /// The stroked layers, in style order.
  ///
  /// A line is a fixed number of pixels wide however far out the map is
  /// zoomed, so the ground it covers changes with the zoom. These are
  /// anchored to the ground with the width held apart, so following a zoom
  /// is arithmetic rather than building them again.
  final List<LineLayerMesh> lines;

  /// The points a line can be taken hold of by, as alternating x and y in
  /// tile coordinates.
  ///
  /// Only where they are. What they look like is one picture drawn at each,
  /// the same size at every zoom, so there is nothing about them to build.
  final Float32List points;

  /// The ground everything in the tile is drawn over, in tile coordinates.
  ///
  /// Not the tile itself: a way is put in the tile its first node is in and
  /// is not cut at the edge, so what a tile draws can reach well past it.
  /// Deciding what is on screen by the tile alone would drop the far end of
  /// a road that starts off it. Lines and points reach a few pixels further
  /// than this, which whoever culls by it has to allow for.
  final Rect bounds;

  /// Creates a tile's mesh.
  TileMesh({
    required this.id,
    required this.fills,
    required this.lines,
    Float32List? points,
  }) : points = points ?? Float32List(0),
       bounds = _boundsOf(fills, lines, points);

  /// A tile with nothing drawn in it.
  TileMesh.empty(this.id)
    : fills = const [],
      lines = const [],
      points = Float32List(0),
      bounds = Rect.zero;

  static Rect _boundsOf(
    List<LayerMesh> fills,
    List<LineLayerMesh> lines,
    Float32List? points,
  ) {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    void cover(Float32List xys) {
      for (var i = 0; i + 1 < xys.length; i += 2) {
        final x = xys[i], y = xys[i + 1];
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }

    for (final layer in fills) {
      cover(layer.triangles);
    }
    for (final layer in lines) {
      cover(layer.triangles.anchors);
    }
    if (points != null) cover(points);
    return left > right ? Rect.zero : Rect.fromLTRB(left, top, right, bottom);
  }

  /// How many vertices the whole tile holds.
  int get vertices {
    var total = 0;
    for (final layer in fills) {
      total += layer.vertices;
    }
    for (final layer in lines) {
      total += layer.vertices;
    }
    return total;
  }

  /// How many points the tile marks.
  int get pointCount => points.length ~/ 2;

  /// How many bytes the tile holds, which is four for every number.
  int get bytes {
    var total = points.lengthInBytes;
    for (final layer in fills) {
      total += layer.triangles.lengthInBytes;
    }
    for (final layer in lines) {
      total +=
          layer.triangles.anchors.lengthInBytes +
          layer.triangles.offsets.lengthInBytes;
    }
    return total;
  }

  @override
  String toString() =>
      'TileMesh($id, ${fills.length} fills, ${lines.length} lines, '
      '$vertices vertices, $pointCount points)';
}
