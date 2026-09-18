import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../geometry/tile.dart';
import '../map/camera.dart';
import '../style/style.dart';
import 'tile_mesh.dart';

/// A tile's triangles as the engine holds them.
///
/// Handing a list of numbers to the GPU means uploading it, which is work
/// that must not happen while a frame is being drawn. Each mesh is converted
/// once, the first time it is needed, and kept until the tile is dropped.
/// Nothing about it changes with the zoom, so nothing goes up twice.
class GpuTileMesh {
  /// Which tile this covers.
  final TileId id;

  /// The uploaded layers, paired with their index in the style.
  final List<(int, ui.Vertices)> layers;

  GpuTileMesh._(this.id, this.layers);

  /// Uploads [mesh], skipping any layer with nothing in it.
  factory GpuTileMesh.of(TileMesh mesh) => GpuTileMesh._(mesh.id, [
    for (final layer in mesh.layers)
      if (layer.triangles.isNotEmpty)
        (
          layer.layer,
          ui.Vertices.raw(ui.VertexMode.triangles, layer.triangles),
        ),
  ]);

  /// Releases the uploaded triangles.
  void dispose() {
    for (final (_, vertices) in layers) {
      vertices.dispose();
    }
  }
}

/// Draws the tiles that are on screen.
///
/// A frame is one pass over the layers of the style, drawing every tile's
/// share of each before moving to the next. Going layer by layer rather than
/// tile by tile is what keeps a road from disappearing under the buildings of
/// the tile next door.
class MapPainter extends CustomPainter {
  /// Where the map is being looked at from.
  final Camera camera;

  /// The tiles to draw, in no particular order.
  final List<GpuTileMesh> tiles;

  /// Called with how many draw calls the frame took.
  final void Function(int calls)? onDrawn;

  /// Creates a painter.
  const MapPainter({required this.camera, required this.tiles, this.onDrawn});

  static final _paints = [
    for (final layer in mapStyle)
      Paint()
        ..color = Color(layer.colour)
        ..isAntiAlias = false,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _paints[layerIndex('earth')]);

    var calls = 0;
    for (var layer = 0; layer < mapStyle.length; layer++) {
      final paint = _paints[layer];
      for (final tile in tiles) {
        for (final (index, vertices) in tile.layers) {
          if (index != layer) continue;
          final origin = camera.toScreen(tile.id.worldX, tile.id.worldY, size);
          final scale = camera.pixelsPerTile(tile.id.zoom) / tileExtent;
          canvas.save();
          canvas.translate(origin.dx, origin.dy);
          canvas.scale(scale, scale);
          canvas.drawVertices(vertices, BlendMode.srcOver, paint);
          canvas.restore();
          calls += 1;
        }
      }
    }
    onDrawn?.call(calls);
  }

  @override
  bool shouldRepaint(MapPainter old) =>
      old.camera != camera || !identical(old.tiles, tiles);
}
