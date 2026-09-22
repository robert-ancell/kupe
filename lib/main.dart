import 'dart:io';

import 'package:flutter/material.dart';
import 'package:osm/osm.dart';
import 'package:path_provider/path_provider.dart';

import 'src/data/map_loader.dart';
import 'src/data/tile_cache.dart';
import 'src/imagery/imagery_cache.dart';
import 'src/imagery/imagery_source.dart';
import 'src/map/camera.dart';
import 'src/map/map_view.dart';

/// How Kupe introduces itself to OpenStreetMap's servers.
///
/// They ask to be told what is calling and where to complain about it. This
/// is the application, not the person using it; nothing about them is sent.
const contact = 'kupe +https://github.com/robert-ancell/kupe';

/// Where the map opens when there is nowhere it was left.
const _somewhere = (latitude: -36.8485, longitude: 174.7633, zoom: 17.0);

/// Opens the editor where it was last left, or over a given place.
///
/// Usage: `kupe [latitude longitude [zoom]]`
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  final asked = arguments.length >= 2
      ? Camera.at(
          latitude: double.parse(arguments[0]),
          longitude: double.parse(arguments[1]),
          zoom: arguments.length >= 3 ? double.parse(arguments[2]) : 17,
        )
      : null;

  // Somewhere to keep what has been read. Without it the editor still works
  // and simply reads everything again each time.
  TileCache? cache;
  ImageryCache? imagery;
  try {
    final directory = await getApplicationCacheDirectory();
    cache = await TileCache.open(Directory('${directory.path}/tiles'));
    imagery = await ImageryCache.open(Directory('${directory.path}/imagery'));
  } on Exception {
    cache = null;
    imagery = null;
  }

  runApp(
    KupeApp(
      camera:
          asked ??
          cache?.camera ??
          Camera.at(
            latitude: _somewhere.latitude,
            longitude: _somewhere.longitude,
            zoom: _somewhere.zoom,
          ),
      cache: cache,
      imageryCache: imagery,
    ),
  );
}

/// The editor.
class KupeApp extends StatelessWidget {
  /// Where to open the map.
  final Camera camera;

  /// Where boxes already read are kept between runs.
  final TileCache? cache;

  /// Where imagery tiles are kept between runs.
  final ImageryCache? imageryCache;

  /// Creates the app.
  const KupeApp({
    super.key,
    required this.camera,
    this.cache,
    this.imageryCache,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kupe',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: MapView(
          api: OsmApi(
            fetch: httpFetch(contact: contact, concurrency: maximumInFlight),
          ),
          initialCamera: camera,
          cache: cache,
          imagery: linzAerial,
          imageryCache: imageryCache,
          imageryFetch: httpFetch(contact: contact, concurrency: 6),
        ),
      ),
    );
  }
}
