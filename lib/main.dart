import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

import 'src/map/camera.dart';
import 'src/map/map_view.dart';
import 'src/render/tessellate.dart';
import 'src/render/tile_mesh.dart';

/// The zoom the tiles of the map are cut at.
///
/// Editing happens several zooms further in than this, so one tile covers a
/// good part of the screen and the count stays small.
const tileZoom = 14;

/// Opens an OpenStreetMap extract and draws it.
///
/// Usage: `kupe <file.osm.pbf> [south west north east]`
void main(List<String> arguments) {
  final path = arguments.isNotEmpty ? arguments.first : null;
  final box = arguments.length >= 5
      ? OsmBounds(
          minLatitude: double.parse(arguments[1]),
          minLongitude: double.parse(arguments[2]),
          maxLatitude: double.parse(arguments[3]),
          maxLongitude: double.parse(arguments[4]),
        )
      : const OsmBounds(
          minLatitude: -36.862,
          minLongitude: 174.752,
          maxLatitude: -36.842,
          maxLongitude: 174.778,
        );

  runApp(KupeApp(path: path, box: box));
}

/// The editor.
class KupeApp extends StatelessWidget {
  /// The extract to open, or null to show how to pass one.
  final String? path;

  /// The part of it to draw.
  final OsmBounds box;

  /// Creates the app.
  const KupeApp({super.key, required this.path, required this.box});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kupe',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: path == null
            ? const Center(child: Text('kupe <file.osm.pbf> [s w n e]'))
            : _Loader(path: path!, box: box),
      ),
    );
  }
}

/// What was read and built, ready to draw.
class _Map {
  final List<TileMesh> tiles;
  final Camera camera;
  final int vertices;

  const _Map(this.tiles, this.camera, this.vertices);
}

/// Reads and builds the map off the interface thread.
///
/// This takes seconds on a whole country, which is exactly why it cannot
/// share a thread with the part that has to hold sixty frames a second.
Future<_Map> _build(String path, OsmBounds box) => Isolate.run(() async {
  final file = await OsmPbfFile.open(path);
  final data = await file.within([box]);
  final camera = Camera.at(
    latitude: (box.minLatitude + box.maxLatitude) / 2,
    longitude: (box.minLongitude + box.maxLongitude) / 2,
    zoom: 16,
  );
  final report = tessellate(
    data,
    zoom: tileZoom,
    pixelsPerTile: camera.pixelsPerTile(tileZoom),
  );
  return _Map(report.tiles.values.toList(), camera, report.vertices);
});

class _Loader extends StatefulWidget {
  final String path;
  final OsmBounds box;

  const _Loader({required this.path, required this.box});

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  late final Future<_Map> _map = _build(widget.path, widget.box);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Map>(
      future: _map,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        final map = snapshot.data;
        if (map == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return MapView(tiles: map.tiles, initialCamera: map.camera);
      },
    );
  }
}
