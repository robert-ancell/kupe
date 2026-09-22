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

/// Something the pointer is over, and what is needed to draw it picked out.
sealed class Picked {
  const Picked();

  /// What kind of element it is.
  OsmElementType get type;

  /// Its id, which with [type] says which element it is.
  int get id;

  /// What it is tagged with.
  Map<String, String> get tags;
}

/// How near the pointer has to be to a node to pick it out, in pixels.
///
/// Larger than the line tolerance, because a node is a point rather than
/// something to run along, and because taking hold of the wrong one is worse
/// than missing.
const nodePickTolerance = 9.0;

/// A node the pointer is over.
class PickedNode extends Picked {
  /// The node itself.
  final OsmNode node;

  /// Where it is in world coordinates.
  final double worldX;

  /// And the other half of that.
  final double worldY;

  /// Creates a picked node.
  const PickedNode({
    required this.node,
    required this.worldX,
    required this.worldY,
  });

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => node.id;

  @override
  Map<String, String> get tags => node.tags;
}

/// A line the pointer is over, and the geometry to draw it by.
class PickedWay extends Picked {
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

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  int get id => way.id;

  @override
  Map<String, String> get tags => way.tags;
}

/// Whether a node of a way can be taken hold of.
///
/// Where a way starts or stops, and where ways meet, are always there to be
/// taken: they are what a line is pinned by. The nodes along the middle of a
/// line are only there once that line is selected, or every road would be a
/// row of targets between the map and whatever is under it.
bool isNodeSelectable(
  MapStore store,
  OsmWay way,
  int index, {
  Set<int> selectedWays = const {},
}) {
  if (selectedWays.contains(way.id)) return true;
  final id = way.nodeIds[index];
  if (store.waysThrough(id) > 1) return true;
  return index == 0 || index == way.nodeIds.length - 1;
}

/// What is under [point] on a view of [size], a node for preference.
///
/// Nodes win over the lines they sit on: they are the smaller thing, they are
/// drawn on top, and a line can be taken hold of anywhere else along it.
Picked? pickAt(
  Offset point,
  Camera camera,
  Size size,
  MapStore store, {
  Set<int> selectedWays = const {},
  int zoom = 16,
}) =>
    nodeAt(
      point,
      camera,
      size,
      store,
      selectedWays: selectedWays,
      zoom: zoom,
    ) ??
    wayAt(point, camera, size, store, zoom: zoom);

/// The node under [point], or null if there is none to be had there.
PickedNode? nodeAt(
  Offset point,
  Camera camera,
  Size size,
  MapStore store, {
  Set<int> selectedWays = const {},
  int zoom = 16,
}) {
  final world = camera.toWorld(point, size);
  final reach = nodePickTolerance / camera.scale;

  PickedNode? nearest;
  var nearestDistance = double.infinity;

  for (final tile in _tilesAround(world, reach, zoom)) {
    for (final element in store.drawnIn(tile)) {
      if (element is! OsmWay) continue;
      for (var i = 0; i < element.nodeIds.length; i++) {
        // A node shared between ways comes round more than once, which
        // costs a comparison and changes nothing: the same node is the same
        // distance away. What it must not do is be judged by one way alone,
        // since it can be the middle of one line and the end of another.
        final id = element.nodeIds[i];
        if (!isNodeSelectable(store, element, i, selectedWays: selectedWays)) {
          continue;
        }
        final node = store.nodes[id];
        if (node == null) continue;

        final x = Mercator.x(node.longitude);
        final y = Mercator.y(node.latitude);
        final distance = math.sqrt(
          (x - world.dx) * (x - world.dx) + (y - world.dy) * (y - world.dy),
        );
        if (distance > reach || distance >= nearestDistance) continue;
        nearestDistance = distance;
        nearest = PickedNode(node: node, worldX: x, worldY: y);
      }
    }
  }
  return nearest;
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

/// The tiles to look through for something under a world position.
///
/// The tile the pointer is on and the ring around it. An element goes in the
/// tile holding its first node and is not cut at the edge, so a way running
/// out of its tile is still found from the one the pointer is over.
List<TileId> _tilesAround(Offset world, double reach, int zoom) {
  final middle = TileId.of(zoom, world.dx, world.dy);
  final across = 1 << zoom;
  return [
    for (var dy = -1; dy <= 1; dy++)
      for (var dx = -1; dx <= 1; dx++)
        if (middle.x + dx >= 0 &&
            middle.x + dx < across &&
            middle.y + dy >= 0 &&
            middle.y + dy < across)
          TileId(zoom, middle.x + dx, middle.y + dy),
  ];
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
