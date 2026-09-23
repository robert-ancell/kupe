import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/render/tessellate.dart';
import 'package:kupe/src/style/style.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _latitude = -36.85;

/// A tile seen at its own size, so that a pixel is a pixel.
const _pixelsPerTile = 512.0;

/// A short east to west way with the given tags, and the data to draw it.
OsmSubset _way(Map<String, String> tags, {double latitude = _latitude}) {
  final nodes = [
    OsmNode(id: 1, latitude: latitude, longitude: 174.7600),
    OsmNode(id: 2, latitude: latitude, longitude: 174.7610),
  ];
  final way = OsmWay(id: 10, nodeIds: const [1, 2], tags: tags);
  return OsmSubset(
    matches: [way],
    nodes: {for (final node in nodes) node.id: node},
    ways: {10: way},
    relations: const {},
  );
}

/// How far the triangles of [layer] reach across the line, in pixels.
double _pixelWidth(
  TessellationReport report,
  String layer, {
  double pixelsPerTile = _pixelsPerTile,
}) {
  final wanted = layerIndex(layer);
  var minY = double.maxFinite;
  var maxY = -double.maxFinite;
  for (final tile in report.tiles.values) {
    for (final mesh in [...tile.fills, ...tile.lines]) {
      if (mesh.layer != wanted) continue;
      for (var i = 1; i < mesh.triangles.length; i += 2) {
        minY = mesh.triangles[i] < minY ? mesh.triangles[i] : minY;
        maxY = mesh.triangles[i] > maxY ? mesh.triangles[i] : maxY;
      }
    }
  }
  if (minY > maxY) return 0;
  return (maxY - minY) * pixelsPerTile / tileExtent;
}

TessellationReport _build(
  OsmSubset data, {
  int zoom = 16,
  double pixelsPerTile = _pixelsPerTile,
  bool fills = true,
  bool lines = true,
}) => tessellate(
  data,
  zoom: zoom,
  pixelsPerTile: pixelsPerTile,
  fills: fills,
  lines: lines,
);

void main() {
  test('draws a road the width the style asks for', () {
    final report = _build(_way(const {'highway': 'residential'}));
    expect(
      _pixelWidth(report, 'minor'),
      closeTo(mapStyle[layerIndex('minor')].width, 0.05),
    );
  });

  test('draws the casing wider than the road it outlines', () {
    final report = _build(_way(const {'highway': 'residential'}));
    expect(
      _pixelWidth(report, 'minor-casing'),
      greaterThan(_pixelWidth(report, 'minor')),
    );
  });

  test('draws the same width on screen at any tile zoom', () {
    for (final zoom in [12, 16, 19]) {
      expect(
        _pixelWidth(
          _build(_way(const {'highway': 'residential'}), zoom: zoom),
          'minor',
        ),
        closeTo(mapStyle[layerIndex('minor')].width, 0.05),
        reason: 'at zoom $zoom',
      );
    }
  });

  test('draws the same width on screen at any latitude', () {
    // Mercator stretches distances away from the equator. A width on screen
    // must not notice.
    for (final latitude in [0.0, -36.85, -46.4, 60.0]) {
      expect(
        _pixelWidth(
          _build(_way(const {'highway': 'residential'}, latitude: latitude)),
          'minor',
        ),
        closeTo(mapStyle[layerIndex('minor')].width, 0.05),
        reason: 'at $latitude',
      );
    }
  });

  test('draws the same width however large the tile is on screen', () {
    // Which is the whole point of building it again: the triangles differ,
    // what they come to on screen does not.
    for (final pixels in [256.0, 512.0, 2048.0]) {
      expect(
        _pixelWidth(
          _build(_way(const {'highway': 'residential'}), pixelsPerTile: pixels),
          'minor',
          pixelsPerTile: pixels,
        ),
        closeTo(mapStyle[layerIndex('minor')].width, 0.05),
        reason: 'at $pixels pixels a tile',
      );
    }
  });

  test('says what it was built for, so it can be told when it is stale', () {
    final report = _build(_way(const {'highway': 'residential'}));
    expect(report.tiles.values.single.pixelsPerTile, _pixelsPerTile);
  });

  test('builds only the lines when only the lines are wanted', () {
    final report = _build(_way(const {'highway': 'residential'}), fills: false);
    expect(report.tiles.values.single.lines, isNotEmpty);
    expect(report.tiles.values.single.fills, isEmpty);
  });

  test('stops a way exactly at its last node', () {
    // A butt cap, so that what is drawn says where the way ends.
    final report = _build(_way(const {'highway': 'residential'}));
    final tile = report.tiles.values.single;
    final mesh = tile.lines.firstWhere((m) => m.layer == layerIndex('minor'));
    var maxX = -double.maxFinite;
    for (var i = 0; i < mesh.triangles.length; i += 2) {
      maxX = mesh.triangles[i] > maxX ? mesh.triangles[i] : maxX;
    }
    final end =
        (Mercator.x(174.7610) - tile.id.worldX) * tileExtent / tile.id.size;
    expect(maxX, closeTo(end, 1e-3));
  });

  test('leaves an untagged way undrawn', () {
    expect(_build(_way(const {})).tiles, isEmpty);
  });

  test('puts a closed building in a fill layer and not a line one', () {
    final nodes = [
      const OsmNode(id: 1, latitude: -36.8500, longitude: 174.7600),
      const OsmNode(id: 2, latitude: -36.8500, longitude: 174.7602),
      const OsmNode(id: 3, latitude: -36.8502, longitude: 174.7602),
    ];
    const way = OsmWay(
      id: 10,
      nodeIds: [1, 2, 3, 1],
      tags: {'building': 'yes'},
    );
    final report = _build(
      OsmSubset(
        matches: const [way],
        nodes: {for (final node in nodes) node.id: node},
        ways: const {10: way},
        relations: const {},
      ),
    );
    final tile = report.tiles.values.single;
    expect(tile.fills.map((m) => m.layer), contains(layerIndex('building')));
    expect(tile.lines, isEmpty);
  });
}
