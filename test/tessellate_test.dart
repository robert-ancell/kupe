import 'package:osm/osm.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/render/tessellate.dart';
import 'package:kupe/src/style/style.dart';
import 'package:test/test.dart';

const _latitude = -36.85;

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

/// How far the triangles of [layer] reach across the line, in metres.
double _groundWidth(TessellationReport report, String layer) {
  final wanted = layerIndex(layer);
  var minY = double.maxFinite;
  var maxY = -double.maxFinite;
  late TileId id;
  for (final tile in report.tiles.values) {
    for (final mesh in tile.layers) {
      if (mesh.layer != wanted) continue;
      id = tile.id;
      for (var i = 1; i < mesh.triangles.length; i += 2) {
        minY = mesh.triangles[i] < minY ? mesh.triangles[i] : minY;
        maxY = mesh.triangles[i] > maxY ? mesh.triangles[i] : maxY;
      }
    }
  }
  if (minY > maxY) return 0;
  final metresPerUnit =
      id.size * Mercator.metresPerUnit(_latitude) / tileExtent;
  return (maxY - minY) * metresPerUnit;
}

void main() {
  test('draws a road as wide as the road is', () {
    final report = tessellate(_way(const {'highway': 'residential'}), zoom: 16);
    final style = mapStyle[layerIndex('minor')].width;
    expect(_groundWidth(report, 'minor'), closeTo(style, 0.05));
  });

  test('draws the casing wider than the road it outlines', () {
    final report = tessellate(_way(const {'highway': 'residential'}), zoom: 16);
    expect(
      _groundWidth(report, 'minor-casing'),
      greaterThan(_groundWidth(report, 'minor')),
    );
  });

  test('draws the same ground width whatever zoom the tile is', () {
    // The whole point of measuring in ground units: a tile built at one zoom
    // is right at every zoom it is ever drawn at.
    final coarse = _groundWidth(
      tessellate(_way(const {'highway': 'residential'}), zoom: 12),
      'minor',
    );
    final fine = _groundWidth(
      tessellate(_way(const {'highway': 'residential'}), zoom: 18),
      'minor',
    );
    expect(coarse, closeTo(fine, 0.05));
  });

  test('draws the same ground width at any latitude', () {
    // Mercator stretches distances away from the equator, so the same road
    // is more tile units further south. The metres must not change.
    for (final latitude in [0.0, -36.85, -46.4, 60.0]) {
      final report = tessellate(
        _way(const {'highway': 'residential'}, latitude: latitude),
        zoom: 16,
      );
      var minY = double.maxFinite;
      var maxY = -double.maxFinite;
      late TileId id;
      for (final tile in report.tiles.values) {
        for (final mesh in tile.layers) {
          if (mesh.layer != layerIndex('minor')) continue;
          id = tile.id;
          for (var i = 1; i < mesh.triangles.length; i += 2) {
            minY = mesh.triangles[i] < minY ? mesh.triangles[i] : minY;
            maxY = mesh.triangles[i] > maxY ? mesh.triangles[i] : maxY;
          }
        }
      }
      final metres =
          (maxY - minY) *
          id.size *
          Mercator.metresPerUnit(latitude) /
          tileExtent;
      expect(
        metres,
        closeTo(mapStyle[layerIndex('minor')].width, 0.05),
        reason: 'at $latitude',
      );
    }
  });

  test('stops a way exactly at its last node', () {
    // A butt cap, so that what is drawn says where the way ends.
    final report = tessellate(_way(const {'highway': 'residential'}), zoom: 16);
    final tile = report.tiles.values.single;
    final mesh = tile.layers.firstWhere((m) => m.layer == layerIndex('minor'));
    var maxX = -double.maxFinite;
    for (var i = 0; i < mesh.triangles.length; i += 2) {
      maxX = mesh.triangles[i] > maxX ? mesh.triangles[i] : maxX;
    }
    final end =
        (Mercator.x(174.7610) - tile.id.worldX) * tileExtent / tile.id.size;
    expect(maxX, closeTo(end, 1e-3));
  });

  test('leaves an untagged way undrawn', () {
    expect(tessellate(_way(const {}), zoom: 16).tiles, isEmpty);
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
    final report = tessellate(
      OsmSubset(
        matches: const [way],
        nodes: {for (final node in nodes) node.id: node},
        ways: const {10: way},
        relations: const {},
      ),
      zoom: 16,
    );
    final layers = report.tiles.values.single.layers.map((m) => m.layer);
    expect(layers, contains(layerIndex('building')));
    expect(layers, isNot(contains(layerIndex('minor'))));
  });
}
