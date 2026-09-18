import 'dart:io';

import 'package:kupe/src/render/tessellate.dart';
import 'package:kupe/src/style/style.dart';
import 'package:osm/osm.dart';

/// Measures what it costs to turn a piece of OpenStreetMap into triangles.
///
/// The work a frame does is fixed by this: how many vertices a dense area
/// comes to, how many batches they fall into, and how long it takes to build
/// them when the map is zoomed and lines have to be rebuilt at a new width.
///
/// Usage: `dart benchmark/tessellate.dart file.osm.pbf [south west north east]`
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(
      'usage: tessellate.dart <file.osm.pbf> '
      '[south west north east]',
    );
    exitCode = 2;
    return;
  }

  final path = arguments.first;
  final box = arguments.length >= 5
      ? OsmBounds(
          minLatitude: double.parse(arguments[1]),
          minLongitude: double.parse(arguments[2]),
          maxLatitude: double.parse(arguments[3]),
          maxLongitude: double.parse(arguments[4]),
        )
      // Central Auckland, about as dense as New Zealand gets.
      : const OsmBounds(
          minLatitude: -36.862,
          minLongitude: 174.752,
          maxLatitude: -36.842,
          maxLongitude: 174.778,
        );

  const zoom = 14;
  const pixelsPerTile = 2048.0;

  final file = await OsmPbfFile.open(path);
  final readAt = Stopwatch()..start();
  final data = await file.within([box]);
  readAt.stop();

  print(
    'read     ${_ms(readAt)}  ${data.matches.length} elements in the box, '
    '${data.nodes.length} nodes held',
  );
  print('resident ${_mb(ProcessInfo.currentRss)} after reading');

  final buildAt = Stopwatch()..start();
  final report = tessellate(data, zoom: zoom, pixelsPerTile: pixelsPerTile);
  buildAt.stop();

  print('');
  print(
    'build    ${_ms(buildAt)}  ${report.drawn} drawn, '
    '${report.skipped} unstyled, ${report.incomplete} incomplete',
  );
  print('tiles    ${report.tiles.length} at zoom $zoom');
  print('vertices ${report.vertices}  (${_mb(report.bytes)} of vertex data)');
  print('calls    ${report.drawCalls} to draw every tile');
  print('resident ${_mb(ProcessInfo.currentRss)} holding data and triangles');

  print('');
  print('per layer');
  final perLayer = <int, int>{};
  for (final tile in report.tiles.values) {
    for (final layer in [...tile.fills, ...tile.lines]) {
      perLayer[layer.layer] = (perLayer[layer.layer] ?? 0) + layer.vertices;
    }
  }
  final order = perLayer.keys.toList()
    ..sort((a, b) => perLayer[b]!.compareTo(perLayer[a]!));
  for (final layer in order) {
    print('  ${_pad(mapStyle[layer].id, 14)}${perLayer[layer]} vertices');
  }

  // Line widths are baked in, so zooming past the threshold means building
  // them again. Filled shapes cover the same ground at any zoom and are kept,
  // so only the lines are rebuilt. This is the cost that decides whether
  // zooming can stay smooth.
  print('');
  print('rebuild lines on zoom');
  for (final at in [0.5, 1.5, 4.0]) {
    final runs = <int>[];
    late TessellationReport rebuilt;
    for (var i = 0; i < 5; i++) {
      final clock = Stopwatch()..start();
      rebuilt = tessellate(
        data,
        zoom: zoom,
        pixelsPerTile: pixelsPerTile * at,
        fills: false,
      );
      clock.stop();
      runs.add(clock.elapsedMicroseconds);
    }
    runs.sort();
    print(
      '  ${_pad('x$at', 8)}${_ms(runs[runs.length ~/ 2])}'
      '${rebuilt.vertices} line vertices',
    );
  }
}

String _ms(Object value) {
  final micros = value is Stopwatch ? value.elapsedMicroseconds : value as int;
  return _pad('${(micros / 1000).toStringAsFixed(1)} ms', 10);
}

String _mb(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

String _pad(String value, int width) => value.padRight(width);
