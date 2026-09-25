import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  OsmCache? cache;
  File? place;
  File? accountFile;
  try {
    // Kupe's own, rather than the directory shared by everything using
    // osm.dart: two programs at once would each write a tile cache's index
    // over the other's.
    final directory = await getApplicationCacheDirectory();
    cache = await OsmCache.open(
      directory: Directory('${directory.path}/osm'),
      fetch: httpFetch(contact: contact),
    );
    place = File('${directory.path}/last-place.json');
    // Not in the cache: a token is a key to somebody's OpenStreetMap
    // account, and a cache is a thing anything is entitled to empty.
    accountFile = File(
      '${(await getApplicationSupportDirectory()).path}'
      '/account.json',
    );
  } on Exception {
    cache = null;
    place = null;
    accountFile = null;
  }

  // The map opens on the one layer built in and takes the full list when it
  // arrives. Reading the index is a megabyte off the network, which is no
  // reason for the editor to show nothing at all until it is done.
  final index = ValueNotifier(const OsmImageryIndex([fallbackImagery]));
  if (cache != null) {
    unawaited(
      cache.imageryIndex.then((read) {
        if (read.layers.isNotEmpty) index.value = read;
      }),
    );
  }

  // What kinds of thing there are, which is what says a node is a cafe
  // rather than a node. Half a megabyte off the network the first time and
  // off the disk after that; until it is in, things go by their ids.
  final presets = ValueNotifier<OsmPresets?>(null);
  if (cache != null) {
    // None at all stays unknown: until there are presets, what is an area
    // goes by the map's own style rather than by nothing being one.
    unawaited(
      cache.presets().then((read) {
        if (read.byId.isNotEmpty) presets.value = read;
      }),
    );
  }

  // Which country a place is in, which is what says which of the kinds of
  // thing that only exist in some countries apply here. Until it is in, only
  // the ones meant for everywhere do.
  final countries = ValueNotifier<OsmCountryCoder?>(null);
  if (cache != null) {
    unawaited(cache.countryCoder.then((read) => countries.value = read));
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
      cache: cache?.tileCache,
      place: place,
      account: accountFile,
      imageryCache: cache?.imageryCache,
      imageryIndex: index,
      imageryFetch: imageryFetch,
      presets: presets,
      countries: countries,
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

  /// Where the token an edit is uploaded with is kept.
  final File? account;

  /// Where imagery tiles are kept between runs.
  final OsmImageryCache? imageryCache;

  /// The layers of imagery to choose from, once they are known.
  final ValueListenable<OsmImageryIndex>? imageryIndex;

  /// How imagery tiles are fetched.
  final OsmFetch? imageryFetch;

  /// What kinds of thing there are on the map, once they are known.
  final ValueListenable<OsmPresets?>? presets;

  /// Which country a place is in, once the borders are known.
  final ValueListenable<OsmCountryCoder?>? countries;

  /// Creates the app.
  const KupeApp({
    super.key,
    required this.camera,
    this.cache,
    this.place,
    this.account,
    this.imageryCache,
    this.imageryIndex,
    this.imageryFetch,
    this.presets,
    this.countries,
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
          account: account,
          imageryCache: imageryCache,
          imageryIndex: imageryIndex,
          imageryFetch: imageryFetch,
          presets: presets,
          countries: countries,
        ),
      ),
    );
  }
}
