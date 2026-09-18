import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

import '../data/map_loader.dart';
import '../geometry/tile.dart';
import '../render/map_painter.dart';
import 'camera.dart';
import 'frame_stats.dart';

/// How long the map waits after being moved before asking for what it can
/// now see.
///
/// Long enough that a drag across a city is one request for where it stopped
/// rather than a request for everywhere it passed over.
const settleDelay = Duration(milliseconds: 250);

/// The map, read from OpenStreetMap as it is looked at.
///
/// Panning and zooming only move the camera. Geometry already built is not
/// built again and not uploaded again, so a frame costs the same whether the
/// map is still or moving, and new tiles appear as their answers arrive.
class MapView extends StatefulWidget {
  /// Where to read the map from.
  final OsmApi api;

  /// Where to start looking from.
  final Camera initialCamera;

  /// Creates the map.
  const MapView({super.key, required this.api, required this.initialCamera});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  late Camera _camera = widget.initialCamera;
  late final MapLoader _loader = MapLoader(
    api: widget.api,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  final _uploaded = <TileId, GpuTileMesh>{};
  final _stats = FrameStats();
  Timer? _settle;
  Size _size = Size.zero;
  var _drawCalls = 0;
  double? _zoomFrom;

  @override
  void dispose() {
    _settle?.cancel();
    for (final mesh in _uploaded.values) {
      mesh.dispose();
    }
    _stats.dispose();
    super.dispose();
  }

  /// The tiles as the engine holds them, uploading anything new.
  ///
  /// A tile is uploaded once and left alone. Nothing about it depends on the
  /// zoom, so panning and zooming never send anything back to the GPU.
  List<GpuTileMesh> get _meshes => [
    for (final tile in _loader.tiles)
      _uploaded.putIfAbsent(tile.id, () => GpuTileMesh.of(tile)),
  ];

  /// Asks for what is on screen once the map has stopped moving.
  void _lookSoon() {
    _settle?.cancel();
    _settle = Timer(settleDelay, () {
      if (mounted) _loader.look(_camera, _size);
    });
  }

  void _moveTo(Camera camera) {
    setState(() => _camera = camera);
    _lookSoon();
  }

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _moveTo(
      _camera.zoomed(-event.scrollDelta.dy / 200, event.localPosition, _size),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          _lookSoon();
        }
        return Listener(
          onPointerSignal: _scroll,
          child: GestureDetector(
            onScaleStart: (_) => _zoomFrom = _camera.zoom,
            onScaleUpdate: (details) {
              var camera = _camera.panned(details.focalPointDelta);
              if (details.scale != 1) {
                final target = _zoomFrom! + math.log(details.scale) / math.ln2;
                camera = camera.zoomed(
                  target - camera.zoom,
                  details.localFocalPoint,
                  size,
                );
              }
              _moveTo(camera);
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
                    loader: _loader,
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
/// to know which is to watch the numbers while moving it around. The rest
/// says how much has been asked of OpenStreetMap, which nothing else shows.
class _Readout extends StatefulWidget {
  final Camera camera;
  final FrameStats stats;
  final MapLoader loader;
  final int drawCalls;

  const _Readout({
    required this.camera,
    required this.stats,
    required this.loader,
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
    final loader = widget.loader;
    final tooFar = widget.camera.zoom < minimumLoadZoom;
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
              Text(
                '${loader.tiles.length} tiles, '
                '${widget.drawCalls} draw calls',
              ),
              Text('build  ${stats.build.toStringAsFixed(2)} ms'),
              Text('raster ${stats.raster.toStringAsFixed(2)} ms'),
              Text('worst  ${stats.worst.toStringAsFixed(2)} ms'),
              Text('${loader.requests} requests, ${loader.waiting} waiting'),
              Text('${loader.store}'),
              if (loader.stopped != null)
                Text(
                  'stopped: ${loader.stopped}',
                  style: const TextStyle(color: Color(0xffff8080)),
                )
              else if (tooFar)
                Text(
                  'zoom in to z${minimumLoadZoom.toInt()} to load',
                  style: const TextStyle(color: Color(0xffffd080)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
