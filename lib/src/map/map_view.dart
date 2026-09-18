import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../render/map_painter.dart';
import '../render/tile_mesh.dart';
import 'camera.dart';
import 'frame_stats.dart';

/// The map, drawn from tiles that have already been built.
///
/// Panning and zooming only change the camera. No geometry is rebuilt and
/// nothing is uploaded again, so the cost of a frame is the same whether the
/// map is still or moving.
class MapView extends StatefulWidget {
  /// The tiles to draw.
  final List<TileMesh> tiles;

  /// Where to start looking from.
  final Camera initialCamera;

  /// Creates the map.
  const MapView({super.key, required this.tiles, required this.initialCamera});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  late Camera _camera = widget.initialCamera;
  final _uploaded = <TileMesh, GpuTileMesh>{};
  final _stats = FrameStats();
  var _drawCalls = 0;
  double? _zoomFrom;

  @override
  void dispose() {
    for (final mesh in _uploaded.values) {
      mesh.dispose();
    }
    _stats.dispose();
    super.dispose();
  }

  List<GpuTileMesh> get _meshes => [
    for (final tile in widget.tiles)
      _uploaded.putIfAbsent(tile, () => GpuTileMesh.of(tile)),
  ];

  void _scroll(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) return;
    setState(() {
      _camera = _camera.zoomed(
        -event.scrollDelta.dy / 200,
        event.localPosition,
        size,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Listener(
          onPointerSignal: (event) => _scroll(event, size),
          child: GestureDetector(
            onScaleStart: (_) => _zoomFrom = _camera.zoom,
            onScaleUpdate: (details) {
              setState(() {
                var camera = _camera.panned(details.focalPointDelta);
                if (details.scale != 1) {
                  final target =
                      _zoomFrom! + math.log(details.scale) / math.ln2;
                  camera = camera.zoomed(
                    target - camera.zoom,
                    details.localFocalPoint,
                    size,
                  );
                }
                _camera = camera;
              });
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: MapPainter(
                        camera: _camera,
                        tiles: _meshes,
                        onDrawn: (calls) => _drawCalls = calls,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  top: 12,
                  child: _Readout(
                    camera: _camera,
                    stats: _stats,
                    tiles: widget.tiles.length,
                    drawCalls: _drawCalls,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What the map is doing, drawn over it.
///
/// A map either holds sixty frames a second or it does not, and the only way
/// to know which is to watch the numbers while moving it around.
class _Readout extends StatefulWidget {
  final Camera camera;
  final FrameStats stats;
  final int tiles;
  final int drawCalls;

  const _Readout({
    required this.camera,
    required this.stats,
    required this.tiles,
    required this.drawCalls,
  });

  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
  // The numbers keep moving after the map stops, as the last frames age out
  // of the window, so the readout ticks rather than waiting for a gesture.
  late final Timer _tick = Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xcc000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xffffffff),
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.camera}'),
              Text('${widget.tiles} tiles, ${widget.drawCalls} draw calls'),
              Text('build  ${stats.build.toStringAsFixed(2)} ms'),
              Text('raster ${stats.raster.toStringAsFixed(2)} ms'),
              Text('worst  ${stats.worst.toStringAsFixed(2)} ms'),
            ],
          ),
        ),
      ),
    );
  }
}
