import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:osm/osm.dart';

import '../data/map_loader.dart';
import '../edit/edited_geometry.dart';
import '../imagery/imagery_layer.dart';
import '../geometry/tile.dart';
import '../render/map_painter.dart';
import '../render/tile_mesh.dart';
import 'camera.dart';
import 'frame_stats.dart';
import 'pick.dart';

/// How long the map waits after being moved before asking for what it can
/// now see.
///
/// Long enough that a drag across a city is one request for where it stopped
/// rather than a request for everywhere it passed over.
const settleDelay = Duration(milliseconds: 250);

/// How long the map waits before checking what it drew from disk against what
/// has been edited since.
///
/// After the reading, so that a view arriving from the cache is on screen
/// before anything is asked about it, and long enough that moving on again
/// cancels it.
const checkDelay = Duration(seconds: 2);

/// How far in the map has to be before anything can be edited.
///
/// The same as the zoom it starts reading at, and for the same reason: there
/// is nothing to edit until the data is there. iD draws the line in the same
/// place.
const minimumEditZoom = minimumLoadZoom;

/// How long zooming in to edit takes.
///
/// Long enough to see where the map went, short enough not to wait for it.
const zoomToEditDuration = Duration(milliseconds: 250);

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

  /// Where boxes already read are kept between runs.
  final OsmTileCache? cache;

  /// Where to remember the place the map was left.
  final File? place;

  /// The layers of imagery to choose from.
  ///
  /// A listenable rather than a list, because the index is a megabyte off the
  /// network: the map opens on whatever was already known and takes the full
  /// list when it arrives.
  final ValueListenable<OsmImageryIndex>? imageryIndex;

  /// Where imagery tiles are kept between runs.
  final OsmImageryCache? imageryCache;

  /// How imagery tiles are fetched.
  ///
  /// Kept apart from the fetch the API uses, so that imagery, which comes
  /// from servers built to hand out a great deal of it, never takes a turn
  /// the API could have used.
  final OsmFetch? imageryFetch;

  /// Creates the map.
  const MapView({
    super.key,
    required this.api,
    required this.initialCamera,
    this.cache,
    this.place,
    this.imageryIndex,
    this.imageryCache,
    this.imageryFetch,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  late Camera _camera = widget.initialCamera;
  late final OsmEdits _edits = OsmEdits(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  late final MapLoader _loader = MapLoader(
    api: widget.api,
    cache: widget.cache,
    place: widget.place,
    edits: _edits,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  OsmImagery? _source;
  ImageryLayer<ui.Image>? _imagery;
  final _uploaded = <TileId, _Uploaded>{};
  var _restroking = false;
  final _stats = FrameStats();
  Timer? _settle;
  Timer? _check;
  Size _size = Size.zero;
  var _drawCalls = 0;
  double? _zoomFrom;

  late final AnimationController _zoomer = AnimationController(
    vsync: this,
    duration: zoomToEditDuration,
  )..addListener(_zoomStep);
  double? _easeFrom;
  double? _easeTo;
  Picked? _hovered;
  PickedNode? _dragging;
  Offset? _pressedAt;
  var _dragged = false;
  final _selected = <(OsmElementType, int), Picked>{};

  /// The ways that are selected, which is what says whether the nodes along
  /// them can be taken hold of.
  Set<int> get _selectedWays => {
    for (final picked in _selected.values)
      if (picked is PickedWay) picked.id,
  };

  @override
  void initState() {
    super.initState();
    widget.imageryIndex?.addListener(_indexChanged);
  }

  /// Whether the map is too far out to edit.
  bool get _tooFarToEdit => _camera.zoom < minimumEditZoom;

  /// Zooms in to where editing starts, about the middle of the view.
  void _zoomToEdit() {
    if (!_tooFarToEdit) return;
    _easeFrom = _camera.zoom;
    _easeTo = minimumEditZoom;
    _zoomer.forward(from: 0);
  }

  void _zoomStep() {
    final from = _easeFrom;
    final to = _easeTo;
    if (from == null || to == null) return;
    _moveTo(
      Camera(
        x: _camera.x,
        y: _camera.y,
        zoom: from + (to - from) * Curves.easeOut.transform(_zoomer.value),
      ),
    );
  }

  /// Takes the imagery again once the full index has arrived, in case it
  /// knows of something better here than what the map opened with.
  void _indexChanged() {
    if (!mounted) return;
    _source = null;
    _chooseImagery(_camera);
    _imagery?.look(_camera, _size);
    setState(() {});
  }

  @override
  void dispose() {
    _zoomer.dispose();
    widget.imageryIndex?.removeListener(_indexChanged);
    _settle?.cancel();
    _check?.cancel();
    _loader.dispose();
    _imagery?.dispose();
    for (final held in _uploaded.values) {
      held.gpu.dispose();
    }
    _stats.dispose();
    super.dispose();
  }

  /// The tiles as the engine holds them, uploading what is new and replacing
  /// the lines of anything that has been built again.
  List<GpuTileMesh> get _meshes {
    final meshes = <GpuTileMesh>[];
    for (final tile in _loader.tiles) {
      var held = _uploaded[tile.id];
      if (held == null) {
        held = _Uploaded(tile, GpuTileMesh.of(tile));
        _uploaded[tile.id] = held;
      } else if (!identical(held.source, tile)) {
        // Rebuilding widths leaves the filled shapes untouched and hands
        // back the same list, so only the lines go up again.
        if (identical(held.source.fills, tile.fills)) {
          held.gpu.restroke(tile);
          held.source = tile;
        } else {
          held.gpu.dispose();
          held = _Uploaded(tile, GpuTileMesh.of(tile));
          _uploaded[tile.id] = held;
        }
      }
      meshes.add(held.gpu);
    }
    return meshes;
  }

  /// Catches the line widths up with the zoom, a few tiles at a time.
  ///
  /// Zooming stretches lines that were built for another zoom. Rebuilding
  /// every tile on screen at once would drop a frame, so it is done between
  /// frames until there is nothing stale left.
  void _restrokeSoon() {
    if (_restroking) return;
    _restroking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _restroking = false;
      if (!mounted) return;
      final more = _loader.restroke();
      setState(() {});
      if (more) _restrokeSoon();
    });
  }

  /// Asks for what is on screen once the map has stopped moving.
  ///
  /// Anything already held on disk is drawn at once; the rest is read. A
  /// little later, what was drawn from disk is checked against what has been
  /// edited since, which is a single request whatever is on screen.
  void _lookSoon() {
    _settle?.cancel();
    _check?.cancel();
    _settle = Timer(settleDelay, () {
      if (mounted) _loader.look(_camera, _size);
    });
    _check = Timer(checkDelay, () {
      if (mounted) unawaited(_loader.refresh());
    });
  }

  void _moveTo(Camera camera) {
    setState(() {
      _camera = camera;
      // Out here there is no editing to be done, so there is nothing to have
      // selected either.
      if (_tooFarToEdit) _selected.clear();
    });
    // Imagery is asked for as the map moves rather than once it settles,
    // since its servers are built for it and a blank background mid pan is
    // what makes a map feel slow.
    _chooseImagery(camera);
    _imagery?.look(camera, _size);
    _lookSoon();
    _restrokeSoon();
  }

  /// Picks the imagery to draw where the map is looking.
  ///
  /// The index says which layers have tiles over a place and which of them to
  /// prefer, so the layer changes by itself on crossing into ground a better
  /// one covers. The one already chosen is kept for as long as it covers the
  /// middle of the view, so that panning around inside a country does not
  /// swap the background about.
  void _chooseImagery(Camera camera) {
    final index = widget.imageryIndex?.value;
    if (index == null) return;
    final held = _source;
    if (held != null && held.covers(camera.latitude, camera.longitude)) return;

    final wanted = index
        .at(
          camera.latitude,
          camera.longitude,
          category: OsmImageryCategory.photo,
        )
        .firstOrNull;
    if (wanted == null || wanted.id == held?.id) return;

    _imagery?.dispose();
    _source = wanted;
    _imagery = ImageryLayer<ui.Image>(
      tiles: OsmImageryTiles(
        source: wanted,
        fetch: widget.imageryFetch ?? httpFetch(),
        cache: widget.imageryCache,
      ),
      decode: _decode,
      release: (image) => image.dispose(),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// What the imagery is doing, for the readout.
  String get _imageryState {
    final source = _source;
    if (source == null) {
      return widget.imageryIndex == null
          ? 'no imagery index'
          : 'no imagery covers here';
    }
    return '${source.name}: ${_imagery?.held ?? 0} held, '
        '${_imagery?.reading ?? 0} reading';
  }

  /// Works out what the pointer is over.
  ///
  /// Only while the map is close enough to edit: further out the lines are
  /// too fine to point at, and there is nothing to be done with one anyway.
  void _hover(Offset at) {
    final found = _tooFarToEdit
        ? null
        : pickAt(
            at,
            _camera,
            _size,
            _loader.store,
            selectedWays: _selectedWays,
            edits: _edits,
            zoom: loadZoom,
          );
    if (found?.id == _hovered?.id && found?.type == _hovered?.type) {
      // The same line, but its shape moves with the camera.
      _hovered = found;
      return;
    }
    setState(() => _hovered = found);
  }

  /// Selects what the pointer is on.
  ///
  /// Holding shift adds to the selection, or takes out what was already in
  /// it, which is how every editor does it. Clicking away from everything
  /// clears the selection, unless shift is held, since that is a miss rather
  /// than a change of mind.
  void _tap(Offset at) {
    if (_tooFarToEdit) return;
    final picked = pickAt(
      at,
      _camera,
      _size,
      _loader.store,
      selectedWays: _selectedWays,
      edits: _edits,
      zoom: loadZoom,
    );
    final adding = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (picked == null) {
        if (!adding) _selected.clear();
        return;
      }
      final key = (picked.type, picked.id);
      if (adding) {
        if (_selected.remove(key) == null) _selected[key] = picked;
      } else {
        _selected
          ..clear()
          ..[key] = picked;
      }
    });
  }

  /// Moves a node to follow the pointer.
  ///
  /// The first move of a drag takes the way it belongs to out of the tile it
  /// was built into, so that the old shape stops being drawn; the rest only
  /// move the node, which is a line or two a frame.
  void _dragNode(PickedNode held, Offset to) {
    final world = _camera.toWorld(to, _size);
    final first = !_dragged;
    _dragged = true;
    setState(() {
      _edits.moveNode(
        held.node,
        latitude: Mercator.latitude(world.dy.clamp(0.0, 1.0)),
        longitude: Mercator.longitude(world.dx),
        continuing: !first,
      );
    });
    if (first) _loader.editsChanged();
  }

  /// Puts back the last change made.
  void _undo() {
    if (!_edits.undo()) return;
    _loader.editsChanged();
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
          _chooseImagery(_camera);
          _imagery?.look(_camera, size);
          _lookSoon();
        }
        return Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                const _UndoIntent(),
            SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                const _UndoIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _UndoIntent: CallbackAction<_UndoIntent>(
                onInvoke: (_) {
                  _undo();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Listener(
                onPointerDown: (event) => _pressedAt = event.localPosition,
                onPointerSignal: _scroll,
                child: MouseRegion(
                  onHover: (event) => _hover(event.localPosition),
                  onExit: (_) {
                    if (_hovered != null) setState(() => _hovered = null);
                  },
                  child: GestureDetector(
                    onTapUp: (details) => _tap(details.localPosition),
                    onScaleStart: (details) {
                      _zoomFrom = _camera.zoom;
                      _dragged = false;
                      // A drag that starts on a node moves the node; anywhere else
                      // it moves the map.
                      // From where the pointer went down rather than from
                      // where the gesture was recognised: a drag is only a
                      // drag once it has moved, by which time it has left
                      // anything as small as a node behind.
                      _dragging = _tooFarToEdit
                          ? null
                          : nodeAt(
                              _pressedAt ?? details.localFocalPoint,
                              _camera,
                              _size,
                              _loader.store,
                              selectedWays: _selectedWays,
                              edits: _edits,
                              zoom: loadZoom,
                            );
                    },
                    onScaleUpdate: (details) {
                      final held = _dragging;
                      if (held != null && details.pointerCount < 2) {
                        _dragNode(held, details.localFocalPoint);
                        return;
                      }
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
                      _moveTo(camera);
                    },
                    onScaleEnd: (_) => _dragging = null,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: MapPainter(
                                camera: _camera,
                                tiles: _meshes,
                                imagery:
                                    _imagery?.piecesFor(_camera, size) ??
                                    const [],
                                edited: editedGeometry(_loader.store, _edits),
                                selection: _selected.values.toList(),
                                highlight: _hovered,
                                onDrawn: (calls) => _drawCalls = calls,
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                        if (_tooFarToEdit)
                          Positioned.fill(
                            child: Center(
                              child: _ZoomToEdit(onPressed: _zoomToEdit),
                            ),
                          ),
                        if (_selected.isNotEmpty)
                          Positioned(
                            left: 12,
                            bottom: 12,
                            child: _Tags(selected: _selected.values.toList()),
                          ),
                        if (_source?.attribution case final credit?)
                          Positioned(
                            right: 8,
                            bottom: 6,
                            child: _Attribution(credit),
                          ),
                        Positioned(
                          left: 12,
                          top: 12,
                          child: _Readout(
                            camera: _camera,
                            stats: _stats,
                            loader: _loader,
                            drawCalls: _drawCalls,
                            imagery: _imageryState,
                            edits: _edits.length,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Turns a fetched tile into a picture.
Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// The credit the imagery's licence asks for, which has to be on screen
/// whenever the imagery is.
class _Attribution extends StatelessWidget {
  final String text;

  const _Attribution(this.text);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xb3ffffff),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(fontSize: 11, color: Color(0xff333333)),
        ),
      ),
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
  final String imagery;
  final int edits;

  const _Readout({
    required this.camera,
    required this.stats,
    required this.loader,
    required this.drawCalls,
    required this.imagery,
    required this.edits,
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
              Text(
                '${loader.requests} requests, ${loader.reading} reading, '
                '${loader.waiting - loader.reading} waiting',
              ),
              Text('${loader.store}'),
              Text(widget.imagery),
              if (widget.edits > 0)
                Text(
                  '${widget.edits} '
                  '${widget.edits == 1 ? 'change' : 'changes'}, '
                  'ctrl+z to undo',
                  style: const TextStyle(color: Color(0xffffd080)),
                ),
              if (loader.cache != null)
                Text(
                  '${loader.cache!.tiles.length} boxes held, '
                  '${(loader.cache!.bytes / (1 << 20)).toStringAsFixed(1)} '
                  'MB on disk',
                ),
              if (loader.stopped != null)
                Text(
                  'paused: ${loader.stopped}, trying again shortly',
                  style: const TextStyle(color: Color(0xffff8080)),
                )
              else if (loader.crowded)
                const Text(
                  'too much here to show it all, zoom in',
                  style: TextStyle(color: Color(0xffffd080)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says that the map is too far out to edit, and zooms in when pressed.
///
/// What iD shows, down to the words: below the zoom where data is read there
/// is nothing to edit, and the way out of that is the same gesture every
/// time, so it is worth a button rather than an instruction.
class _ZoomToEdit extends StatelessWidget {
  final VoidCallback onPressed;

  const _ZoomToEdit({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xee3b4147),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 18, color: Color(0xffffffff)),
              SizedBox(width: 8),
              Text(
                'Zoom in to edit',
                style: TextStyle(fontSize: 14, color: Color(0xffffffff)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tags of what is selected.
///
/// One thing selected shows everything it is tagged with. Several show what
/// they have in common, which is what says whether they can be treated as one
/// thing, and the count says how many they are.
class _Tags extends StatelessWidget {
  final List<Picked> selected;

  const _Tags({required this.selected});

  /// The tags every selected way carries with the same value.
  Map<String, String> get _shared {
    final shared = Map<String, String>.from(selected.first.tags);
    for (final picked in selected.skip(1)) {
      shared.removeWhere((key, value) => picked.tags[key] != value);
    }
    return shared;
  }

  /// What to call the selection.
  String get _title {
    if (selected.length > 1) return '${selected.length} selected';
    final only = selected.single;
    return switch (only.type) {
      OsmElementType.node => 'Node ${only.id}',
      OsmElementType.way => 'Way ${only.id}',
      OsmElementType.relation => 'Relation ${only.id}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final tags = _shared;
    final entries = tags.keys.toList()..sort();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xee2b3036),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280, maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                Text(
                  _title,
                  style: const TextStyle(
                    color: Color(0xff9ec1ff),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                if (entries.isEmpty)
                  Text(
                    selected.length == 1
                        ? 'no tags'
                        : 'nothing tagged the same',
                    style: const TextStyle(color: Color(0xffa0a6ad)),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final key in entries)
                            Text('$key = ${tags[key]}'),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's triangles, and the copy of them the engine holds.
class _Uploaded {
  TileMesh source;
  final GpuTileMesh gpu;

  _Uploaded(this.source, this.gpu);
}

/// Asks for the last change to be put back.
class _UndoIntent extends Intent {
  const _UndoIntent();
}
