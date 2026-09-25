import 'dart:typed_data';

import 'package:kupe/src/render/tessellate.dart';
import 'package:kupe/src/render/tile_mesh.dart';
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

/// Where the triangles of a line layer are when a tile is [pixelsPerTile]
/// across on screen.
Float32List _placed(LineLayerMesh mesh, double pixelsPerTile) =>
    mesh.triangles.at(tileExtent / pixelsPerTile);

/// How far the triangles of [layer] reach across the line, in pixels, when
/// a tile is [pixelsPerTile] across on screen.
double _pixelWidth(
  TessellationReport report,
  String layer, {
  double pixelsPerTile = _pixelsPerTile,
}) {
  final wanted = layerIndex(layer);
  var minY = double.maxFinite;
  var maxY = -double.maxFinite;
  for (final tile in report.tiles.values) {
    for (final mesh in tile.lines) {
      if (mesh.layer != wanted) continue;
      final triangles = _placed(mesh, pixelsPerTile);
      for (var i = 1; i < triangles.length; i += 2) {
        minY = triangles[i] < minY ? triangles[i] : minY;
        maxY = triangles[i] > maxY ? triangles[i] : maxY;
      }
    }
  }
  if (minY > maxY) return 0;
  return (maxY - minY) * pixelsPerTile / tileExtent;
}

TessellationReport _build(
  OsmSubset data, {
  int zoom = 16,
  int Function(int nodeId)? waysThrough,
}) => tessellate(data, zoom: zoom, waysThrough: waysThrough);

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
    // From one build: the same triangles, placed for each size, come to the
    // same width on screen at every one of them.
    final report = _build(_way(const {'highway': 'residential'}));
    for (final pixels in [64.0, 256.0, 512.0, 2048.0, 16384.0]) {
      expect(
        _pixelWidth(report, 'minor', pixelsPerTile: pixels),
        closeTo(mapStyle[layerIndex('minor')].width, 0.05),
        reason: 'at $pixels pixels a tile',
      );
    }
  });

  test('stops a way exactly at its last node', () {
    // A butt cap, so that what is drawn says where the way ends.
    final report = _build(_way(const {'highway': 'residential'}));
    final tile = report.tiles.values.single;
    final mesh = tile.lines.firstWhere((m) => m.layer == layerIndex('minor'));
    final triangles = _placed(mesh, _pixelsPerTile);
    var maxX = -double.maxFinite;
    for (var i = 0; i < triangles.length; i += 2) {
      maxX = triangles[i] > maxX ? triangles[i] : maxX;
    }
    final end =
        (Mercator.x(174.7610) - tile.id.worldX) * tileExtent / tile.id.size;
    expect(maxX, closeTo(end, 1e-3));
  });

  group('draws everything', () {
    /// The layers the one way in [report] was drawn in.
    List<int> layersOf(TessellationReport report) => [
      for (final tile in report.tiles.values) ...[
        for (final mesh in tile.fills) mesh.layer,
        for (final mesh in tile.lines) mesh.layer,
      ],
    ];

    test('draws an untagged way', () {
      // The members of a multipolygon are untagged, and are where its shape
      // is edited.
      expect(layersOf(_build(_way(const {}))), [layerIndex('other')]);
    });

    test('draws a way the style has nothing particular to say about', () {
      expect(layersOf(_build(_way(const {'power': 'line'}))), [
        layerIndex('other'),
      ]);
      expect(layersOf(_build(_way(const {'barrier': 'fence'}))), [
        layerIndex('other'),
      ]);
    });

    test('draws the edge of an area with no colour of its own', () {
      final nodes = {
        1: const OsmNode(id: 1, latitude: -36.85, longitude: 174.7600),
        2: const OsmNode(id: 2, latitude: -36.85, longitude: 174.7602),
        3: const OsmNode(id: 3, latitude: -36.8502, longitude: 174.7602),
      };
      const way = OsmWay(
        id: 10,
        nodeIds: [1, 2, 3, 1],
        tags: {'landuse': 'residential'},
      );
      final report = _build(
        OsmSubset(
          matches: const [way],
          nodes: nodes,
          ways: const {10: way},
          relations: const {},
        ),
      );
      expect(layersOf(report), [layerIndex('other')]);
    });
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

    /// How many points were marked.
    int marksIn(TessellationReport report) =>
        report.tiles.values.fold(0, (total, tile) => total + tile.pointCount);

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

    test('marks no end on a line that comes back to where it started', () {
      final nodes = {
        1: const OsmNode(id: 1, latitude: -36.85, longitude: 174.7600),
        2: const OsmNode(id: 2, latitude: -36.85, longitude: 174.7602),
        3: const OsmNode(id: 3, latitude: -36.8502, longitude: 174.7602),
      };
      const ring = OsmWay(
        id: 10,
        nodeIds: [1, 2, 3, 1],
        tags: {'highway': 'residential', 'junction': 'roundabout'},
      );
      final alone = OsmSubset(
        matches: const [ring],
        nodes: nodes,
        ways: const {10: ring},
        relations: const {},
      );
      expect(marksIn(_build(alone)), 0);

      // Where a road joins it is still marked, and only there.
      const joining = OsmWay(
        id: 11,
        nodeIds: [2, 4],
        tags: {'highway': 'residential'},
      );
      final joined = OsmSubset(
        matches: const [ring, joining],
        nodes: {
          ...nodes,
          4: const OsmNode(id: 4, latitude: -36.8498, longitude: 174.7604),
        },
        ways: const {10: ring, 11: joining},
        relations: const {},
      );
      // The junction, and the far end of the road joining.
      expect(marksIn(_build(joined)), 2);
    });

    group('a node in its own right', () {
      /// A power line of three nodes, the middle one a pylon, and a shop off
      /// on its own.
      OsmSubset powerLine() {
        final nodes = {
          1: const OsmNode(id: 1, latitude: _latitude, longitude: 174.7600),
          2: const OsmNode(
            id: 2,
            latitude: _latitude,
            longitude: 174.7602,
            tags: {'power': 'tower'},
          ),
          3: const OsmNode(id: 3, latitude: _latitude, longitude: 174.7604),
          4: const OsmNode(
            id: 4,
            latitude: _latitude - 0.0003,
            longitude: 174.7602,
            tags: {'shop': 'bakery'},
          ),
        };
        const line = OsmWay(
          id: 10,
          nodeIds: [1, 2, 3],
          tags: {'power': 'line'},
        );
        return OsmSubset(
          matches: [line, ...nodes.values],
          nodes: nodes,
          ways: const {10: line},
          relations: const {},
        );
      }

      test('is marked when it says something itself', () {
        // Both ends of the line, the pylon along it, and the shop.
        expect(marksIn(_build(powerLine())), 4);
      });

      test('is marked when it is in no way at all', () {
        const node = OsmNode(id: 1, latitude: _latitude, longitude: 174.76);
        final report = _build(
          const OsmSubset(
            matches: [node],
            nodes: {1: node},
            ways: {},
            relations: {},
          ),
        );
        expect(marksIn(report), 1);
      });
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

  test('builds a way across the antimeridian short, not round the world', () {
    const nodes = [
      OsmNode(id: 1, latitude: _latitude, longitude: 179.9995),
      OsmNode(id: 2, latitude: _latitude, longitude: -179.9995),
    ];
    const way = OsmWay(
      id: 10,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
    );
    final report = _build(
      OsmSubset(
        matches: const [way],
        nodes: {for (final node in nodes) node.id: node},
        ways: const {10: way},
        relations: const {},
      ),
    );
    expect(report.tiles, isNotEmpty);
    for (final tile in report.tiles.values) {
      expect(tile.bounds.width, lessThan(tileExtent));
    }
  });
}
