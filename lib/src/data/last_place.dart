import 'dart:convert';
import 'dart:io';

import '../map/camera.dart';

/// Where the map was left, so the editor opens there next time.
///
/// Kept apart from the caches. Those hold what was read, which any tool could
/// use; this is where one person happened to be looking.
abstract final class LastPlace {
  /// Reads the place from [file], or null if there is none to read.
  static Future<Camera?> read(File file) async {
    try {
      if (!file.existsSync()) return null;
      final parsed = jsonDecode(await file.readAsString());
      if (parsed is! Map<String, dynamic>) return null;
      final x = parsed['x'];
      final y = parsed['y'];
      final zoom = parsed['zoom'];
      if (x is! num || y is! num || zoom is! num) return null;
      return Camera(x: x.toDouble(), y: y.toDouble(), zoom: zoom.toDouble());
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Writes [camera] to [file].
  static Future<void> write(File file, Camera camera) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'x': camera.x, 'y': camera.y, 'zoom': camera.zoom}),
      );
    } on IOException {
      // Opening somewhere else next time is no great loss.
    }
  }
}
