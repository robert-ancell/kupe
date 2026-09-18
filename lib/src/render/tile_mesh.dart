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
/// per tile: once built, a tile is correct at every zoom it is drawn at,
/// because everything in it is measured in ground units. A frame then costs
/// one draw call per layer present, whatever the tile holds.
class TileMesh {
  /// Which tile this covers.
  final TileId id;

  /// The layers to draw, in style order.
  final List<LayerMesh> layers;

  /// Creates a tile's mesh.
  const TileMesh({required this.id, required this.layers});

  /// How many vertices the whole tile holds.
  int get vertices {
    var total = 0;
    for (final layer in layers) {
      total += layer.vertices;
    }
    return total;
  }

  /// How many bytes of vertex data the tile holds.
  int get bytes => vertices * 8;

  @override
  String toString() =>
      'TileMesh($id, ${layers.length} layers, $vertices vertices)';
}
