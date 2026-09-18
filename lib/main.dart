import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

import 'src/map/camera.dart';
import 'src/map/map_view.dart';

/// How Kupe introduces itself to OpenStreetMap's servers.
///
/// They ask to be told what is calling and where to complain about it. This
/// is the application, not the person using it; nothing about them is sent.
const contact = 'kupe +https://github.com/robert-ancell/kupe';

/// Opens the editor over a place on the map.
///
/// Usage: `kupe [latitude longitude [zoom]]`
void main(List<String> arguments) {
  final camera = arguments.length >= 2
      ? Camera.at(
          latitude: double.parse(arguments[0]),
          longitude: double.parse(arguments[1]),
          zoom: arguments.length >= 3 ? double.parse(arguments[2]) : 17,
        )
      // Central Auckland, until there is somewhere to remember a place.
      : Camera.at(latitude: -36.8485, longitude: 174.7633, zoom: 17);

  runApp(KupeApp(camera: camera));
}

/// The editor.
class KupeApp extends StatelessWidget {
  /// Where to open the map.
  final Camera camera;

  /// Creates the app.
  const KupeApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kupe',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: MapView(
          api: OsmApi(fetch: httpFetch(contact: contact)),
          initialCamera: camera,
        ),
      ),
    );
  }
}
