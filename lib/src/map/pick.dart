import 'dart:math' as math;
import 'dart:ui';

import 'package:osm/osm.dart';

import '../data/map_store.dart';
import '../geometry/tile.dart';
import '../style/style.dart';
import 'camera.dart';

/// How near the pointer has to be to a line to pick it out, in pixels.
///
/// A line is picked anywhere it is drawn, and this much beyond, so that a
/// footpath a pixel wide can still be pointed at.
const pickTolerance = 6.0;

/// A line the pointer is over, and the geometry to draw it by.
class PickedWay {
  /// The way itself.
  final OsmWay way;

  /// Its nodes in world coordinates, x and y in turn.
  final List<double> points;

  /// How wide it is drawn on the ground, in metres.
  final double width;

  /// Creates a picked way.
  const PickedWay({
    required this.way,
    required this.points,
    required this.width,
  });
}

/// The line under [point] on a view of [size], or null if there is none.
///
/// Only the tiles the pointer is over are looked through, and only their
/// lines: a filled shape is not a line, and neither is a way the style draws
/// nothing for. Where several lines are under the pointer the nearest wins,
/// so a footpath beside a road can still be picked.
PickedWay? wayAt(
  Offset point,
  Camera camera,
  Size size,
  MapStore store, {
  int zoom = 16,
}) {
  final world = camera.toWorld(point, size);
  final reach = pickTolerance / camera.scale;

  PickedWay? nearest;
  var nearestDistance = double.infinity;

  for (final tile in _tilesAround(world, reach, zoom)) {
    for (final element in store.drawnIn(tile)) {
      if (element is! OsmWay) continue;
      if (element.isClosed && enclosesArea(element.tags)) continue;
      final layers = lineLayersFor(element.tags);
      if (layers.isEmpty) continue;

      final points = _worldPoints(element, store);
      if (points == null) continue;

      // Anywhere the line is drawn counts, so half its width is taken off
      // the distance before anything is compared.
      final width = mapStyle[layers.last].width;
      final metres = Mercator.metresPerUnit(camera.latitude);
      final half = width / 2 / metres;
      final distance = _distanceTo(points, world) - half;
      if (distance > reach || distance >= nearestDistance) continue;

      nearestDistance = distance;
      nearest = PickedWay(way: element, points: points, width: width);
    }
  }
  return nearest;
}

/// The tiles within [reach] of a world position.
List<TileId> _tilesAround(Offset world, double reach, int zoom) {
  final tiles = <TileId>{};
  for (final dx in [-reach, 0.0, reach]) {
    for (final dy in [-reach, 0.0, reach]) {
      tiles.add(TileId.of(zoom, world.dx + dx, world.dy + dy));
    }
  }
  return tiles.toList();
}

/// A way's nodes in world coordinates, or null if any of them is missing.
List<double>? _worldPoints(OsmWay way, MapStore store) {
  final points = List<double>.filled(way.nodeIds.length * 2, 0);
  for (var i = 0; i < way.nodeIds.length; i++) {
    final node = store.nodes[way.nodeIds[i]];
    if (node == null) return null;
    points[i * 2] = Mercator.x(node.longitude);
    points[i * 2 + 1] = Mercator.y(node.latitude);
  }
  return points;
}

/// How far a point is from the nearest part of a line.
double _distanceTo(List<double> points, Offset at) {
  var nearest = double.infinity;
  for (var i = 0; i + 3 < points.length; i += 2) {
    final distance = _toSegment(
      at.dx,
      at.dy,
      points[i],
      points[i + 1],
      points[i + 2],
      points[i + 3],
    );
    if (distance < nearest) nearest = distance;
  }
  return nearest;
}

double _toSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax;
  final dy = by - ay;
  final length = dx * dx + dy * dy;
  // How far along the segment the nearest point is, kept on the segment so
  // that a point past either end measures to that end.
  final along = length == 0
      ? 0.0
      : (((px - ax) * dx + (py - ay) * dy) / length).clamp(0.0, 1.0);
  final nx = ax + dx * along;
  final ny = ay + dy * along;
  return math.sqrt((px - nx) * (px - nx) + (py - ny) * (py - ny));
}
