import 'dart:typed_data';

import '../geometry/tile.dart';

/// The triangles of one layer of one tile.
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

/// Everything drawn for one tile, ready to hand to the GPU.
///
/// Building this is the expensive part of drawing a map, and it is done once
/// per tile rather than once per frame. A frame then costs one draw call per
/// layer present, whatever the tile holds.
class TileMesh {
  /// Which tile this covers.
  final TileId id;

  /// The filled layers, in style order.
  ///
  /// A filled shape covers the same ground whatever the zoom, so these are
  /// built once and kept across every rebuild.
  final List<LayerMesh> fills;

  /// The stroked layers, in style order.
  ///
  /// A line is a fixed number of pixels wide however far out the map is
  /// zoomed, so the ground it covers changes and its triangles have to be
  /// built again when [pixelsPerTile] moves far enough.
  final List<LayerMesh> lines;

  /// How wide the tile was assumed to be on screen when line widths were
  /// worked out.
  ///
  /// Line widths are baked into the triangles, so drawing the tile at a
  /// different size draws its lines at the wrong width. Past a threshold the
  /// tile has to be built again.
  final double pixelsPerTile;

  /// Creates a tile's mesh.
  const TileMesh({
    required this.id,
    required this.fills,
    required this.lines,
    required this.pixelsPerTile,
  });

  /// The same tile with its lines rebuilt for a new size on screen.
  TileMesh withLines(List<LayerMesh> lines, double pixelsPerTile) => TileMesh(
    id: id,
    fills: fills,
    lines: lines,
    pixelsPerTile: pixelsPerTile,
  );

  /// Every layer to draw, in the order the style puts them in.
  List<LayerMesh> get layers {
    final all = [...fills, ...lines];
    all.sort((a, b) => a.layer.compareTo(b.layer));
    return all;
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

  /// How many bytes of vertex data the tile holds.
  int get bytes => vertices * 8;

  @override
  String toString() =>
      'TileMesh($id, ${layers.length} layers, $vertices '
      'vertices)';
}
