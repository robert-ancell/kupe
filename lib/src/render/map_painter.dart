import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../geometry/tile.dart';
import '../imagery/imagery_layer.dart';
import '../map/pick.dart';
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

  /// The uploaded filled layers, paired with their index in the style.
  final List<(int, ui.Vertices)> fills;

  /// The uploaded stroked layers, paired with their index in the style.
  ///
  /// Replaced when the map has been zoomed far enough that the widths they
  /// were built at are no longer right. The fills beside them are not: they
  /// cover the same ground at any zoom.
  List<(int, ui.Vertices)> lines;

  GpuTileMesh._(this.id, this.fills, this.lines);

  /// Uploads [mesh], skipping any layer with nothing in it.
  factory GpuTileMesh.of(TileMesh mesh) =>
      GpuTileMesh._(mesh.id, _upload(mesh.fills), _upload(mesh.lines));

  /// Replaces the stroked layers with the ones in [mesh], leaving the fills
  /// where they are.
  void restroke(TileMesh mesh) {
    for (final (_, vertices) in lines) {
      vertices.dispose();
    }
    lines = _upload(mesh.lines);
  }

  static List<(int, ui.Vertices)> _upload(List<LayerMesh> layers) {
    return <(int, ui.Vertices)>[
      for (final layer in layers)
        if (layer.triangles.isNotEmpty)
          (
            layer.layer,
            ui.Vertices.raw(ui.VertexMode.triangles, layer.triangles),
          ),
    ];
  }

  /// Releases the uploaded triangles.
  void dispose() {
    for (final (_, vertices) in [...fills, ...lines]) {
      vertices.dispose();
    }
  }
}

/// How wide something [width] across is outlined, in pixels.
///
/// The outline is proportional to what it goes round, so that one about a
/// motorway reads the same as one about a footpath rather than swamping it,
/// with a floor so that a hairline still has something to see.
double outlineWidth(double width, double spread) =>
    width + math.max(width * spread, leastOutline);

/// How much wider than the line itself a selected line is outlined, as a
/// share of the line's own width.
const selectionSpread = 1.0;

/// And how much wider for one that is merely pointed at, which is less, so
/// that pointing at something selected shows both at once.
const highlightSpread = 0.5;

/// The narrowest an outline is ever drawn.
const leastOutline = 4.0;

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

  /// The background imagery to draw under the map, if any.
  final List<ImageryPiece<ui.Image>> imagery;

  /// What is selected, drawn over the map.
  final List<Picked> selection;

  /// What the pointer is over, drawn over everything else.
  final Picked? highlight;

  /// Called with how many draw calls the frame took.
  final void Function(int calls)? onDrawn;

  /// Creates a painter.
  const MapPainter({
    required this.camera,
    required this.tiles,
    this.imagery = const [],
    this.selection = const [],
    this.highlight,
    this.onDrawn,
  });

  static final _paints = [
    for (final layer in mapStyle)
      Paint()
        ..color = Color(layer.colour)
        ..isAntiAlias = false,
  ];

  /// The same colours, with filled areas let through so that the imagery
  /// under them can still be traced. Lines stay solid; they are what is
  /// being lined up against the picture.
  static final _overImagery = [
    for (final layer in mapStyle)
      Paint()
        ..color = Color(layer.colour)
            .withValues(alpha: layer.kind == LayerKind.fill ? 0.3 : 1)
        ..isAntiAlias = false,
  ];

  static final _imageryPaint = Paint()..filterQuality = FilterQuality.low;

  /// What the pointer is over is drawn in red over the top, wider than the
  /// thing itself so that it reads as an outline around it rather than as a
  /// road that has changed colour.
  static final _highlightPaint = Paint()
    ..color = const Color(0xffe03030)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  /// What has been selected, in a colour of its own so that pointing at a
  /// selected line still says which one the pointer is on.
  /// How large a node is drawn, in pixels.
  static const _nodeRadius = 5.0;

  static final _nodeFill = Paint()..color = const Color(0xffffffff);

  static final _nodeEdge = Paint()
    ..color = const Color(0xff2f6fed)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;

  static final _selectionPaint = Paint()
    ..color = const Color(0xff2f6fed)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _paints[layerIndex('earth')]);

    var calls = 0;
    for (final piece in imagery) {
      _drawImagery(canvas, size, piece);
      calls += 1;
    }

    // Under the map rather than over it. What is picked out reads as an
    // outline around the line, which means the line itself has to be drawn
    // on top of it.
    for (final picked in selection) {
      _drawPicked(canvas, size, picked, _selectionPaint, selectionSpread);
      calls += 1;
    }
    if (highlight != null) {
      _drawPicked(canvas, size, highlight!, _highlightPaint, highlightSpread);
      calls += 1;
    }

    final paints = imagery.isEmpty ? _paints : _overImagery;
    for (var layer = 0; layer < mapStyle.length; layer++) {
      final paint = paints[layer];
      for (final tile in tiles) {
        calls += _draw(canvas, size, tile, tile.fills, layer, paint);
        calls += _draw(canvas, size, tile, tile.lines, layer, paint);
      }
    }
    // The nodes of a selected line go over everything: they are what is
    // taken hold of, and they are only there while it is selected.
    for (final picked in selection) {
      if (picked is PickedWay) _drawNodes(canvas, size, picked);
    }
    onDrawn?.call(calls);
  }

  /// Draws whichever of [uploaded] belongs to [layer], and says how many
  /// calls that took.
  int _draw(
    Canvas canvas,
    Size size,
    GpuTileMesh tile,
    List<(int, ui.Vertices)> uploaded,
    int layer,
    Paint paint,
  ) {
    var calls = 0;
    for (final (index, vertices) in uploaded) {
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
    return calls;
  }

  /// Draws what has been picked out, whether pointed at or selected.
  void _drawPicked(
    Canvas canvas,
    Size size,
    Picked picked,
    Paint paint,
    double spread,
  ) {
    switch (picked) {
      case PickedWay():
        _drawWay(
          canvas,
          size,
          picked,
          paint,
          outlineWidth(picked.width, spread),
        );
      case PickedNode():
        final at = camera.toScreen(picked.worldX, picked.worldY, size);
        final marked = mapStyle[layerIndex('vertex-edge')].width;
        canvas.drawCircle(
          at,
          outlineWidth(marked, spread) / 2,
          paint..style = PaintingStyle.fill,
        );
    }
  }

  /// Draws the nodes of a way that can be taken hold of while it is
  /// selected, which is all of them.
  void _drawNodes(Canvas canvas, Size size, PickedWay picked) {
    final points = picked.points;
    for (var i = 0; i + 1 < points.length; i += 2) {
      final at = camera.toScreen(points[i], points[i + 1], size);
      canvas.drawCircle(at, _nodeRadius, _nodeFill);
      canvas.drawCircle(at, _nodeRadius, _nodeEdge);
    }
  }

  /// Draws a line that has been picked out, whether pointed at or selected.
  ///
  /// One path a frame, in screen coordinates. There are only ever a few, and
  /// they move with the camera, so building them is cheaper than holding
  /// geometry that is out of date as soon as the map moves.
  void _drawWay(
    Canvas canvas,
    Size size,
    PickedWay picked,
    Paint paint,
    double width,
  ) {
    final points = picked.points;
    if (points.length < 4) return;

    final path = Path();
    for (var i = 0; i + 1 < points.length; i += 2) {
      final at = camera.toScreen(points[i], points[i + 1], size);
      if (i == 0) {
        path.moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
    }

    canvas.drawPath(
      path,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  /// Draws one tile of imagery, or the matching part of a coarser one that is
  /// standing in for it.
  void _drawImagery(Canvas canvas, Size size, ImageryPiece<ui.Image> piece) {
    final tile = piece.tile;
    final origin = camera.toScreen(tile.worldX, tile.worldY, size);
    final side = camera.pixelsPerTile(tile.zoom);
    // Half a pixel over each edge, so that tiles landing on fractional pixels
    // do not leave a hairline of background between them.
    final target = Rect.fromLTWH(origin.dx, origin.dy, side, side).inflate(0.5);

    final image = piece.image;
    final across = 1 << (tile.zoom - piece.from.zoom);
    final part = image.width / across;
    final source = Rect.fromLTWH(
      (tile.x - piece.from.x * across) * part,
      (tile.y - piece.from.y * across) * part,
      part,
      part,
    );
    canvas.drawImageRect(image, source, target, _imageryPaint);
  }

  @override
  bool shouldRepaint(MapPainter old) =>
      old.highlight?.id != highlight?.id ||
      old.highlight?.type != highlight?.type ||
      !identical(old.selection, selection) ||
      !identical(old.imagery, imagery) ||
      old.camera != camera ||
      !identical(old.tiles, tiles);
}
