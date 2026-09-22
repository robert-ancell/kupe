import 'dart:io';

import 'package:flutter/material.dart';
import 'package:osm/osm.dart';
import 'package:path_provider/path_provider.dart';

import 'src/data/map_loader.dart';
import 'src/data/last_place.dart';
import 'src/map/camera.dart';
import 'src/map/map_view.dart';

/// How Kupe introduces itself to OpenStreetMap's servers.
///
/// They ask to be told what is calling and where to complain about it. This
/// is the application, not the person using it; nothing about them is sent.
const contact = 'kupe +https://github.com/robert-ancell/kupe';

/// What to draw when the editor layer index cannot be read at all.
///
/// The entry for LINZ's aerial imagery of New Zealand, copied from the index,
/// key and all: LINZ issued that key for OpenStreetMap editors to share, and
/// has given OpenStreetMap written permission to trace the imagery.
const fallbackImagery = OsmImagery(
  id: 'LINZ_NZ_Aerial_Imagery',
  name: 'LINZ NZ Aerial Imagery',
  url:
      'https://basemaps.linz.govt.nz/v1/tiles/aerial/WebMercatorQuad/'
      '{zoom}/{x}/{y}.webp?api=d01egend5f8dv4zcbfj6z2t7rs3',
  category: OsmImageryCategory.photo,
  maximumZoom: 21,
  attribution: 'Sourced from LINZ CC-BY 4.0',
  best: true,
);

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
  final imageryFetch = httpFetch(contact: contact, concurrency: 6);

  OsmTileCache? cache;
  OsmImageryCache? imagery;
  File? place;
  var index = const OsmImageryIndex([fallbackImagery]);
  try {
    final directory = await getApplicationCacheDirectory();
    cache = await OsmTileCache.open(Directory('${directory.path}/tiles'));
    imagery = await OsmImageryCache.open(
      Directory('${directory.path}/imagery'),
    );
    place = File('${directory.path}/last-place.json');
    index = await OsmImageryIndexFile.read(
      file: File('${directory.path}/editor-layer-index.geojson'),
      fetch: imageryFetch,
      fallback: const [fallbackImagery],
    );
  } on Exception {
    cache = null;
    imagery = null;
    place = null;
  }

  final left = place == null ? null : await LastPlace.read(place);

  runApp(
    KupeApp(
      camera:
          asked ??
          left ??
          Camera.at(
            latitude: _somewhere.latitude,
            longitude: _somewhere.longitude,
            zoom: _somewhere.zoom,
          ),
      cache: cache,
      place: place,
      imageryCache: imagery,
      imageryIndex: index,
      imageryFetch: imageryFetch,
    ),
  );
}

/// The editor.
class KupeApp extends StatelessWidget {
  /// Where to open the map.
  final Camera camera;

  /// Where boxes already read are kept between runs.
  final OsmTileCache? cache;

  /// Where the place the map was left is remembered.
  final File? place;

  /// Where imagery tiles are kept between runs.
  final OsmImageryCache? imageryCache;

  /// The layers of imagery to choose from.
  final OsmImageryIndex? imageryIndex;

  /// How imagery tiles are fetched.
  final OsmFetch? imageryFetch;

  /// Creates the app.
  const KupeApp({
    super.key,
    required this.camera,
    this.cache,
    this.place,
    this.imageryCache,
    this.imageryIndex,
    this.imageryFetch,
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
          place: place,
          imageryCache: imageryCache,
          imageryIndex: imageryIndex,
          imageryFetch: imageryFetch,
        ),
      ),
    );
  }
}
