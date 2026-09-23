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
  int Function(int nodeId)? waysThrough,
}) => tessellate(
  data,
  zoom: zoom,
  pixelsPerTile: pixelsPerTile,
  fills: fills,
  lines: lines,
  waysThrough: waysThrough,
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
    // Its edge, and nothing from the layers a road would be drawn in.
    expect(tile.lines.map((m) => m.layer), [layerIndex('building-edge')]);

    // The edge is a fixed width on screen, so a rebuild for a new zoom has
    // to produce it again even though the fill it goes around is kept.
    final restroked = _build(
      OsmSubset(
        matches: const [way],
        nodes: {for (final node in nodes) node.id: node},
        ways: const {10: way},
        relations: const {},
      ),
      fills: false,
    );
    expect(restroked.tiles.values.single.lines.map((m) => m.layer), [
      layerIndex('building-edge'),
    ]);
  });

  group('points that can be taken hold of', () {
    /// A road of [count] nodes, and optionally a second road meeting it at
    /// the node [crossingAt] along the way.
    OsmSubset road({int count = 4, int? crossingAt}) {
      final nodes = <int, OsmNode>{};
      for (var i = 0; i < count; i++) {
        nodes[100 + i] = OsmNode(
          id: 100 + i,
          latitude: _latitude,
          longitude: 174.76 + i * 0.0002,
        );
      }
      final ways = <int, OsmWay>{
        1: OsmWay(
          id: 1,
          nodeIds: [for (var i = 0; i < count; i++) 100 + i],
          tags: const {'highway': 'residential'},
        ),
      };
      if (crossingAt != null) {
        nodes[200] = OsmNode(
          id: 200,
          latitude: _latitude - 0.0002,
          longitude: 174.76 + crossingAt * 0.0002,
        );
        ways[2] = OsmWay(
          id: 2,
          nodeIds: [100 + crossingAt, 200],
          tags: const {'highway': 'footway'},
        );
      }
      return OsmSubset(
        matches: ways.values.toList(),
        nodes: nodes,
        ways: ways,
        relations: const {},
      );
    }

    /// How many discs were drawn, from the area of the marks divided by the
    /// area of one.
    int marksIn(TessellationReport report) {
      var area = 0.0;
      for (final tile in report.tiles.values) {
        for (final mesh in tile.lines) {
          if (mesh.layer != layerIndex('vertex')) continue;
          final t = mesh.triangles;
          for (var i = 0; i < t.length; i += 6) {
            area +=
                ((t[i + 2] - t[i]) * (t[i + 5] - t[i + 1]) -
                        (t[i + 4] - t[i]) * (t[i + 3] - t[i + 1]))
                    .abs() /
                2;
          }
        }
      }
      final units =
          mapStyle[layerIndex('vertex')].width /
          2 *
          tileExtent /
          _pixelsPerTile;
      // A little under a circle, being made of straight pieces.
      return (area / (3.0 * units * units)).round();
    }

    test('marks where a line starts and stops', () {
      expect(marksIn(_build(road())), 2);
    });

    test('marks where lines meet as well', () {
      // Two ends of the road, two ends of the footpath, and the node they
      // share counts once for each of them.
      expect(marksIn(_build(road(crossingAt: 1))), greaterThan(2));
    });

    test('leaves the middle of a line unmarked', () {
      // Four nodes, two of them ends: the two in between are not marked
      // until the line is selected, which the map draws for itself.
      expect(marksIn(_build(road(count: 4))), 2);
      expect(marksIn(_build(road(count: 8))), 2);
    });

    test('marks nothing on a filled shape', () {
      final nodes = {
        1: const OsmNode(id: 1, latitude: -36.85, longitude: 174.7600),
        2: const OsmNode(id: 2, latitude: -36.85, longitude: 174.7602),
        3: const OsmNode(id: 3, latitude: -36.8502, longitude: 174.7602),
      };
      const way = OsmWay(
        id: 10,
        nodeIds: [1, 2, 3, 1],
        tags: {'building': 'yes'},
      );
      final report = _build(
        OsmSubset(
          matches: const [way],
          nodes: nodes,
          ways: const {10: way},
          relations: const {},
        ),
      );
      expect(marksIn(report), 0);
    });

    test('takes what runs through a node from the caller', () {
      // The caller knows about ways in other boxes; the subset does not.
      final report = _build(road(), waysThrough: (id) => id == 101 ? 2 : 1);
      expect(marksIn(report), 3);
    });

    test('marks the same size on screen at any zoom', () {
      final near = marksIn(_build(road(), zoom: 19));
      expect(marksIn(_build(road(), zoom: 14)), near);
    });
  });
}
