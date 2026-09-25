import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:osm/osm.dart';

import '../edit/edited_geometry.dart';
import '../imagery/imagery_layer.dart';
import '../map/pick.dart';
import '../map/camera.dart';
import '../style/style.dart';
import 'node_sprite.dart';
import 'tile_mesh.dart';

/// A tile's triangles as the engine holds them.
///
/// Handing a list of numbers to the GPU means uploading it. Filled shapes go
/// up once, the first time the tile is drawn, and stay there. Lines go up
/// again whenever the zoom has changed since they last did, which costs a
/// multiply and an add per number and a copy — no building — and happens
/// only for tiles on screen. The points a line can be taken hold of by are
/// one picture drawn many times, and only where each copy goes is kept.
class GpuTileMesh {
  /// What this was uploaded from.
  final TileMesh source;

  /// The uploaded filled layers, paired with their index in the style.
  final List<(int, ui.Vertices)> fills;

  List<(int, ui.Vertices)> _lines = const [];
  double? _linesAt;

  Float32List? _pointTransforms;
  Float32List? _pointRects;
  double? _pointsAt;

  GpuTileMesh._(this.source, this.fills);

  /// Uploads the filled shapes of [mesh], skipping any layer with nothing in
  /// it. Its lines wait until they are drawn and it is known at what zoom.
  factory GpuTileMesh.of(TileMesh mesh) => GpuTileMesh._(mesh, [
    for (final layer in mesh.fills)
      if (layer.triangles.isNotEmpty)
        (
          layer.layer,
          ui.Vertices.raw(ui.VertexMode.triangles, layer.triangles),
        ),
  ]);

  /// Which tile this covers.
  OsmTile get id => source.id;

  /// Room to work out line positions in, shared by every tile since only one
  /// is ever being uploaded at a time. The engine copies what it is given.
  static var _scratch = Float32List(0);

  /// The stroked layers, paired with their index in the style, for when a
  /// pixel covers [unitsPerPixel] of the tile.
  ///
  /// The same ones as last time if the zoom has not changed, which is every
  /// frame of a pan.
  List<(int, ui.Vertices)> linesAt(double unitsPerPixel) {
    if (_linesAt == unitsPerPixel) return _lines;
    _disposeLines();
    _lines = [
      for (final layer in source.lines)
        if (!layer.triangles.isEmpty)
          (layer.layer, _upload(layer, unitsPerPixel)),
    ];
    _linesAt = unitsPerPixel;
    return _lines;
  }

  static ui.Vertices _upload(LineLayerMesh layer, double unitsPerPixel) {
    final length = layer.triangles.anchors.length;
    if (_scratch.length < length) _scratch = Float32List(length);
    layer.triangles.at(unitsPerPixel, _scratch);
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_scratch, 0, length),
    );
  }

  /// Where each copy of [sprite] goes, and which part of it to draw, for
  /// when a pixel covers [unitsPerPixel] of the tile. Null if the tile marks
  /// no points.
  ///
  /// In tile coordinates, under the same transform the triangles are drawn
  /// with, so a pan moves them with everything else and only a zoom has to
  /// work them out again: each copy is scaled down by as much as the tile is
  /// scaled up, which leaves it the same size on screen at every zoom.
  (Float32List, Float32List)? pointsAt(
    double unitsPerPixel,
    NodeSprite sprite,
  ) {
    final points = source.points;
    if (points.isEmpty) return null;
    final count = points.length ~/ 2;
    final size = sprite.image.width.toDouble();
    if (_pointRects == null || _pointRects![2] != size) {
      _pointRects = Float32List(count * 4);
      for (var i = 0; i < count; i++) {
        _pointRects![i * 4 + 2] = size;
        _pointRects![i * 4 + 3] = size;
      }
      _pointsAt = null;
    }
    if (_pointsAt != unitsPerPixel) {
      final transforms = _pointTransforms ??= Float32List(count * 4);
      // The picture's pixels to the tile's units.
      final scale = unitsPerPixel / sprite.pixelRatio;
      final half = size / 2 * scale;
      for (var i = 0; i < count; i++) {
        transforms[i * 4] = scale;
        transforms[i * 4 + 1] = 0;
        transforms[i * 4 + 2] = points[i * 2] - half;
        transforms[i * 4 + 3] = points[i * 2 + 1] - half;
      }
      _pointsAt = unitsPerPixel;
    }
    return (_pointTransforms!, _pointRects!);
  }

  void _disposeLines() {
    for (final (_, vertices) in _lines) {
      vertices.dispose();
    }
    _lines = const [];
    _linesAt = null;
  }

  /// Releases the uploaded triangles.
  void dispose() {
    for (final (_, vertices) in fills) {
      vertices.dispose();
    }
    _disposeLines();
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

  /// What has been changed, drawn a frame at a time.
  ///
  /// Everything else was built into a tile once and is still on the graphics
  /// card. Only what is moving is built again, and only while it moves.
  final EditedGeometry edited;

  /// The lines that would be drawn by the next click, as pairs of world
  /// positions, four numbers to a line.
  ///
  /// The line from the last point put down to the pointer, and for a shape
  /// the line back from the pointer to where it started.
  final List<double> ghost;

  /// Where a node would be put down, if one would.
  final (double, double)? ghostNode;

  /// What is selected, drawn over the map.
  final List<Picked> selection;

  /// What the pointer is over, drawn over everything else.
  final Picked? highlight;

  /// What the points a line can be taken hold of by are drawn with, once it
  /// has been made. Until then they are not drawn.
  final NodeSprite? nodeSprite;

  /// Called with how many draw calls the frame took.
  final void Function(int calls)? onDrawn;

  /// Creates a painter.
  const MapPainter({
    required this.camera,
    required this.tiles,
    this.imagery = const [],
    this.edited = const EditedGeometry(ways: [], nodes: []),
    this.ghost = const [],
    this.ghostNode,
    this.selection = const [],
    this.highlight,
    this.nodeSprite,
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

  /// Smoothed, since a copy of the picture seldom lands on a whole pixel.
  static final _spritePaint = Paint()..filterQuality = FilterQuality.low;

  /// The line that has not been drawn yet, in the colour of the line being
  /// drawn but faint, so that it reads as what would happen rather than as
  /// what has.
  static final _ghostFill = Paint()..color = const Color(0x99ffffff);

  static final _ghostPaint = Paint()
    ..color = const Color(0x99ffffff)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = mapStyle[layerIndex('minor')].width;

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

  static final _vertexEdgePaint = Paint()
    ..color = Color(mapStyle[layerIndex('vertex-edge')].colour);

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

    // A line that is picked out goes under the map, so that it reads as an
    // outline around the line rather than as a line that has changed
    // colour: the road, its casing and its points all stay visible inside.
    for (final picked in selection) {
      if (picked is! PickedWay) continue;
      _drawWay(
        canvas,
        size,
        picked,
        _selectionPaint,
        outlineWidth(picked.width, selectionSpread),
      );
      calls += 1;
    }
    if (highlight case final PickedWay picked) {
      _drawWay(
        canvas,
        size,
        picked,
        _highlightPaint,
        outlineWidth(picked.width, highlightSpread),
      );
      calls += 1;
    }

    final paints = imagery.isEmpty ? _paints : _overImagery;
    final visible = [
      for (final tile in tiles)
        if (_isOnScreen(tile, size)) tile,
    ];
    for (var layer = 0; layer < mapStyle.length; layer++) {
      final paint = paints[layer];
      final kind = mapStyle[layer].kind;
      for (final tile in visible) {
        final unitsPerPixel = tileExtent / camera.pixelsPerTile(tile.id.zoom);
        switch (kind) {
          case LayerKind.fill:
            calls += _draw(canvas, size, tile, tile.fills, layer, paint);
          case LayerKind.line:
            final lines = tile.linesAt(unitsPerPixel);
            calls += _draw(canvas, size, tile, lines, layer, paint);
          case LayerKind.point:
            // One picture holds every part of a point, so it is drawn once,
            // in the turn of the first layer a point is made of.
            if (layer != pointLayers.first) continue;
            calls += _drawPoints(canvas, size, tile, unitsPerPixel);
        }
      }
      // What has been changed was left out of the tiles, so it goes in here,
      // in its own layer's turn, and looks like the rest of the map.
      for (final way in edited.ways) {
        if (!way.layers.contains(layer)) continue;
        if (mapStyle[layer].kind == LayerKind.fill) {
          _drawArea(canvas, size, way.points, paint);
        } else {
          _drawLine(canvas, size, way.points, paint, mapStyle[layer].width);
        }
        calls += 1;
      }
    }

    for (var i = 0; i + 3 < ghost.length; i += 4) {
      canvas.drawLine(
        camera.toScreen(ghost[i], ghost[i + 1], size),
        camera.toScreen(ghost[i + 2], ghost[i + 3], size),
        _ghostPaint,
      );
      calls += 1;
    }

    // Where the next click would put a node, which is what says that a click
    // would put one down at all.
    if (ghostNode case (final x, final y)) {
      final at = camera.toScreen(x, y, size);
      canvas.drawCircle(
        at,
        mapStyle[layerIndex('vertex-edge')].width / 2,
        _ghostFill,
      );
      calls += 1;
    }

    // And the points of what has been changed, which are always there to be
    // taken hold of because they have just been taken hold of.
    for (final (x, y) in edited.nodes) {
      final at = camera.toScreen(x, y, size);
      canvas.drawCircle(
        at,
        mapStyle[layerIndex('vertex-edge')].width / 2,
        _vertexEdgePaint,
      );
      canvas.drawCircle(
        at,
        mapStyle[layerIndex('vertex')].width / 2,
        _nodeFill,
      );
      calls += 1;
    }

    // The nodes of a selected line go over everything: they are what is
    // taken hold of, and they are only there while it is selected.
    for (final picked in selection) {
      if (picked is PickedWay) _drawNodes(canvas, size, picked);
    }

    // A node that is picked out goes over everything as well. A node is a
    // point rather than something to run along, so an outline under the map
    // would be hidden by every line that runs through it, which is exactly
    // the lines that make it worth taking hold of.
    for (final picked in selection) {
      if (picked is! PickedNode) continue;
      _drawNode(canvas, size, picked, _selectionPaint, selectionSpread);
      calls += 1;
    }
    if (highlight case final PickedNode picked) {
      _drawNode(canvas, size, picked, _highlightPaint, highlightSpread);
      calls += 1;
    }

    onDrawn?.call(calls);
  }

  /// Draws whichever of [uploaded] belongs to [layer], and says how many
  /// calls that took.
  /// How far past its anchors anything in a tile can be drawn, in pixels:
  /// half the widest line, stretched as far as a sharp corner's point is
  /// allowed to go, with room to spare.
  static const _reach = 32.0;

  /// Whether anything [tile] draws can be on screen.
  ///
  /// By what the tile draws rather than by the tile, since a way that starts
  /// in one tile is not cut off at its edge.
  bool _isOnScreen(GpuTileMesh tile, Size size) {
    final source = tile.source;
    if (source.vertices == 0 && source.points.isEmpty) return false;
    final bounds = source.bounds;
    final origin = camera.tileToScreen(tile.id, size);
    final scale = camera.pixelsPerTile(tile.id.zoom) / tileExtent;
    final drawn = Rect.fromLTRB(
      origin.dx + bounds.left * scale,
      origin.dy + bounds.top * scale,
      origin.dx + bounds.right * scale,
      origin.dy + bounds.bottom * scale,
    ).inflate(_reach);
    return drawn.overlaps(Offset.zero & size);
  }

  /// Draws the points [tile] marks, all of them in one call.
  int _drawPoints(
    Canvas canvas,
    Size size,
    GpuTileMesh tile,
    double unitsPerPixel,
  ) {
    final sprite = nodeSprite;
    if (sprite == null) return 0;
    final placed = tile.pointsAt(unitsPerPixel, sprite);
    if (placed == null) return 0;
    final (transforms, rects) = placed;
    final origin = camera.tileToScreen(tile.id, size);
    final scale = camera.pixelsPerTile(tile.id.zoom) / tileExtent;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale, scale);
    canvas.drawRawAtlas(
      sprite.image,
      transforms,
      rects,
      null,
      null,
      null,
      _spritePaint,
    );
    canvas.restore();
    return 1;
  }

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
      final origin = camera.tileToScreen(tile.id, size);
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

  /// Draws a node that has been picked out: the mark it is picked out with,
  /// and the node itself over the top of it.
  void _drawNode(
    Canvas canvas,
    Size size,
    PickedNode picked,
    Paint paint,
    double spread,
  ) {
    final at = camera.toScreen(picked.worldX, picked.worldY, size);
    final marked = mapStyle[layerIndex('vertex-edge')].width;
    canvas.drawCircle(
      at,
      outlineWidth(marked, spread) / 2,
      paint..style = PaintingStyle.fill,
    );
    // And the node again on top, because the one in the tile is under the
    // mark that has just been drawn.
    canvas.drawCircle(at, marked / 2, _vertexEdgePaint);
    canvas.drawCircle(at, mapStyle[layerIndex('vertex')].width / 2, _nodeFill);
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
  ) => _drawLine(canvas, size, picked.points, paint, width);

  /// Draws a line from world coordinates, a path a frame.
  ///
  /// For the few lines that cannot be built once and kept: what is being
  /// pointed at, what is selected, and what is being moved.
  /// Fills the shape [points] runs around.
  ///
  /// A path filled by the canvas rather than triangles built here: this is
  /// only ever the few areas being changed, and it is drawn a frame at a time
  /// while a corner is dragged, which is no time to be triangulating.
  void _drawArea(Canvas canvas, Size size, List<double> points, Paint paint) {
    if (points.length < 6) return;
    canvas.drawPath(
      _pathThrough(points, size)..close(),
      Paint()
        ..color = paint.color
        ..isAntiAlias = paint.isAntiAlias,
    );
  }

  Path _pathThrough(List<double> points, Size size) {
    final path = Path();
    for (var i = 0; i + 1 < points.length; i += 2) {
      final at = camera.toScreen(points[i], points[i + 1], size);
      if (i == 0) {
        path.moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
    }
    return path;
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    List<double> points,
    Paint paint,
    double width,
  ) {
    if (points.length < 4) return;

    canvas.drawPath(
      _pathThrough(points, size),
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  /// Draws one tile of imagery, or the matching part of a coarser one that is
  /// standing in for it.
  void _drawImagery(Canvas canvas, Size size, ImageryPiece<ui.Image> piece) {
    final tile = piece.tile;
    final origin = camera.tileToScreen(tile, size);
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
      !identical(old.edited, edited) ||
      !identical(old.ghost, ghost) ||
      old.ghostNode != ghostNode ||
      old.highlight?.id != highlight?.id ||
      old.highlight?.type != highlight?.type ||
      !identical(old.selection, selection) ||
      !identical(old.imagery, imagery) ||
      old.camera != camera ||
      !identical(old.nodeSprite, nodeSprite) ||
      !identical(old.tiles, tiles);
}
