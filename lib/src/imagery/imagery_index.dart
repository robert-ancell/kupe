import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:osm/osm.dart';

/// Where the editor layer index publishes itself.
const imageryIndexUrl =
    'https://osmlab.github.io/editor-layer-index/imagery.geojson';

/// How long a copy of the index is used before it is fetched again.
///
/// Layers are added and withdrawn over weeks, not hours, and an editor that
/// cannot reach the index is better off with last week's list than with none.
const imageryIndexFreshness = Duration(days: 7);

/// What to draw when the index cannot be read at all.
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

/// Reads the editor layer index, keeping a copy between runs.
///
/// A megabyte of JSON describing every layer editors know about. It is read
/// once, kept on disk, and parsed away from the interface thread, because
/// none of that should be in the way of the first frame.
abstract final class ImageryIndex {
  /// The index, from disk if a recent copy is held and from the network
  /// otherwise.
  ///
  /// Never fails: an index that cannot be had at all comes back holding only
  /// [fallbackImagery], so there is always something to draw.
  static Future<OsmImageryIndex> read({
    required File file,
    required OsmFetch fetch,
  }) async {
    final held = await _held(file);
    if (held != null) return held;

    try {
      final body = await fetch(Uri.parse(imageryIndexUrl));
      if (body != null) {
        final json = utf8.decode(body);
        final index = await _parse(json);
        if (index.layers.isNotEmpty) {
          await _keep(file, json);
          return index;
        }
      }
    } on IOException {
      // No network, or the index has moved. Whatever is on disk will do, and
      // failing that the one layer built in.
    } on FormatException {
      // Something that is not the index at all, such as a portal asking to
      // be logged into. Not worth keeping.
    }

    return await _held(file, however: true) ??
        const OsmImageryIndex([fallbackImagery]);
  }

  /// The copy on disk, or null if there is none worth using.
  ///
  /// Set [however] to take one whatever its age, which is what happens when
  /// the network cannot be reached: an old list beats no list.
  static Future<OsmImageryIndex?> _held(
    File file, {
    bool however = false,
  }) async {
    try {
      if (!file.existsSync()) return null;
      if (!however) {
        final age = DateTime.now().difference(await file.lastModified());
        if (age > imageryIndexFreshness) return null;
      }
      final index = await _parse(await file.readAsString());
      return index.layers.isEmpty ? null : index;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _keep(File file, String json) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(json);
    } on IOException {
      // Being unable to keep it costs a fetch next time, nothing more.
    }
  }

  /// Parses away from the interface thread. A megabyte of JSON is not much,
  /// but it is a great deal more than a frame's worth.
  static Future<OsmImageryIndex> _parse(String json) =>
      Isolate.run(() => OsmImageryIndex.parse(json));
}
