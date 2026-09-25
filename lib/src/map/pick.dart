import 'dart:math' as math;
import 'dart:ui';

import 'package:osm/osm.dart';

import '../data/map_store.dart';
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

  /// The element itself, as it stood when it was picked.
  OsmElement get element;
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

  @override
  OsmElement get element => node;
}

/// A line the pointer is over, and the geometry to draw it by.
class PickedWay extends Picked {
  /// The way itself.
  final OsmWay way;

  /// Its nodes in world coordinates, x and y in turn.
  final List<double> points;

  /// How wide it is drawn on screen, in pixels.
  ///
  /// The widest of the layers it is drawn in, so that an outline around it
  /// goes round the casing rather than through it.
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

  @override
  OsmElement get element => way;
}

/// The same thing picked out, from where it now is.
///
/// What is picked holds the geometry to draw it by, which stops being true
/// the moment it is moved. Anything holding onto something picked has to ask
/// for it again as it changes, or it draws where the thing used to be.
Picked? refreshed(Picked picked, MapStore store, OsmEdits edits) {
  if (edits.isGone(picked.type, picked.id)) return null;
  switch (picked) {
    case PickedNode():
      final node = edits.changedNode(picked.id) ?? store.nodes[picked.id];
      if (node == null) return null;
      return PickedNode(
        node: node,
        worldX: Mercator.x(node.longitude),
        worldY: Mercator.y(node.latitude),
      );
    case PickedWay():
      final way = edits.changedWay(picked.id) ?? store.ways[picked.id];
      if (way == null) return null;
      final points = worldPointsOf(way, store, edits);
      if (points == null || points.length < 4) return null;
      // Measured again: other tags can mean other lines.
      return PickedWay(way: way, points: points, width: pickWidthOf(way));
  }
}

/// Whether a node of a way is always there to be taken hold of, selected or
/// not: where the way starts or stops, and where it meets another.
///
/// Those are what a line is pinned by. A way that comes back to where it
/// started — a building, a roundabout — has no start or stop: the node the
/// ring happens to have been drawn from is no different from the others, so
/// only where something else meets it counts.
///
/// The one rule for both what is marked on the map and what can be taken
/// hold of, so the two cannot disagree.
bool isNodePinned(OsmWay way, int index, int Function(int nodeId) waysThrough) {
  if (waysThrough(way.nodeIds[index]) > 1) return true;
  if (way.isClosed) return false;
  return index == 0 || index == way.nodeIds.length - 1;
}

/// Whether a node is marked in its own right, whatever ways it is in: when
/// it says something itself — a pylon, a crossing, a shop — or when it is in
/// no way at all, and would otherwise not be on the map.
bool isNodeMarked(OsmNode node, int Function(int nodeId) waysThrough) =>
    node.tags.isNotEmpty || waysThrough(node.id) == 0;

/// Whether a node of a way can be taken hold of.
///
/// Where it is pinned, by [isNodePinned], and anywhere along a way that is
/// selected. The nodes along the middle of a line are only there once that
/// line is selected, or every road would be a row of targets between the map
/// and whatever is under it.
bool isNodeSelectable(
  MapStore store,
  OsmWay way,
  int index, {
  Set<int> selectedWays = const {},
  int Function(int nodeId)? waysThrough,
}) =>
    selectedWays.contains(way.id) ||
    isNodePinned(way, index, waysThrough ?? store.waysThrough);

/// The ways worth looking through for something under a point.
///
/// What the boxes around it drew, as it now stands, along with everything
/// that has been made since. Something just made is in no box: it exists
/// only among the changes, and not being able to take hold of what has just
/// been put down is no use at all.
List<OsmWay> waysNear(MapStore store, OsmEdits? edits, List<OsmTile> tiles) {
  final found = <OsmWay>[];
  final seen = <int>{};
  for (final tile in tiles) {
    for (final element in store.drawnIn(tile)) {
      if (element is! OsmWay || !seen.add(element.id)) continue;
      if (edits?.isGone(OsmElementType.way, element.id) ?? false) continue;
      found.add(edits?.changedWay(element.id) ?? element);
    }
  }
  for (final way in edits?.changedWays.values ?? const <OsmWay>[]) {
    if (seen.add(way.id)) found.add(way);
  }
  return found;
}

/// How many of [ways] run through each node, for saying where they meet.
int Function(int) _through(List<OsmWay> ways, MapStore store) {
  final counts = <int, int>{};
  for (final way in ways) {
    for (final id in way.nodeIds.toSet()) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
  }
  return (id) {
    final here = counts[id] ?? 0;
    final held = store.waysThrough(id);
    return here > held ? here : held;
  };
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
  OsmEdits? edits,
  int zoom = 16,
}) =>
    nodeAt(
      point,
      camera,
      size,
      store,
      selectedWays: selectedWays,
      edits: edits,
      zoom: zoom,
    ) ??
    wayAt(point, camera, size, store, edits: edits, zoom: zoom);

/// The node under [point], or null if there is none to be had there.
PickedNode? nodeAt(
  Offset point,
  Camera camera,
  Size size,
  MapStore store, {
  Set<int> selectedWays = const {},
  OsmEdits? edits,
  int zoom = 16,
}) {
  final world = camera.toWorld(point, size);
  final reach = nodePickTolerance / camera.scale;
  final ways = waysNear(store, edits, _tilesAround(world, reach, zoom));
  final through = _through(ways, store);

  PickedNode? nearest;
  var nearestDistance = double.infinity;

  void consider(OsmNode node) {
    // The copy round the world nearest the pointer.
    final x = Mercator.nearest(Mercator.x(node.longitude), world.dx);
    final y = Mercator.y(node.latitude);
    final distance = math.sqrt(
      (x - world.dx) * (x - world.dx) + (y - world.dy) * (y - world.dy),
    );
    if (distance > reach || distance >= nearestDistance) return;
    nearestDistance = distance;
    nearest = PickedNode(node: node, worldX: x, worldY: y);
  }

  for (final way in ways) {
    for (var i = 0; i < way.nodeIds.length; i++) {
      // A node shared between ways comes round more than once, which costs a
      // comparison and changes nothing. What it must not do is be judged by
      // one way alone, since it can be the middle of one line and the end of
      // another.
      final id = way.nodeIds[i];
      if (edits?.isGone(OsmElementType.node, id) ?? false) continue;
      if (!isNodeSelectable(
        store,
        way,
        i,
        selectedWays: selectedWays,
        waysThrough: through,
      )) {
        continue;
      }
      final node = edits?.changedNode(id) ?? store.nodes[id];
      if (node == null) continue;
      consider(node);
    }
  }

  // Nodes marked in their own right, by [isNodeMarked], wherever they are.
  for (final tile in _tilesAround(world, reach, zoom)) {
    for (final element in store.drawnIn(tile)) {
      if (element is! OsmNode) continue;
      if (edits?.isGone(OsmElementType.node, element.id) ?? false) continue;
      final node = edits?.changedNode(element.id) ?? element;
      if (isNodeMarked(node, through)) consider(node);
    }
  }

  // A node just put down belongs to no way at all, and is always there to be
  // taken hold of.
  for (final node in edits?.changedNodes.values ?? const <OsmNode>[]) {
    if (edits!.isGone(OsmElementType.node, node.id)) continue;
    if (through(node.id) > 0) continue;
    consider(node);
  }
  return nearest;
}

/// The line under [point], or null if there is none.
///
/// Only the tiles the pointer is over are looked through, along with
/// anything made since. Where several lines are under the pointer the
/// nearest wins, so a footpath beside a road can still be picked.
PickedWay? wayAt(
  Offset point,
  Camera camera,
  Size size,
  MapStore store, {
  OsmEdits? edits,
  int zoom = 16,
}) {
  final world = camera.toWorld(point, size);
  final reach = pickTolerance / camera.scale;

  PickedWay? nearest;
  var nearestDistance = double.infinity;

  for (final way in waysNear(store, edits, _tilesAround(world, reach, zoom))) {
    final points = worldPointsOf(way, store, edits);
    if (points == null || points.length < 4) continue;

    // Anywhere the line is drawn counts, so half its width is taken off the
    // distance before anything is compared.
    final width = pickWidthOf(way);
    final half = width / 2 / camera.scale;
    // The pointer brought round to the same side of the world as the line.
    final at = Offset(Mercator.nearest(world.dx, points[0]), world.dy);
    final distance = _distanceTo(points, at) - half;
    if (distance > reach || distance >= nearestDistance) continue;

    nearestDistance = distance;
    nearest = PickedWay(way: way, points: points, width: width);
  }
  return nearest;
}

/// How wide [way] is to take hold of, in pixels: the widest of the lines it
/// is drawn with, and never less than a road.
///
/// By its lines: a road by the road, an area by the edge around it. Not by
/// the inside of an area, which is mostly other things — the paths across a
/// park, the building in the middle of a car park — and would take every
/// click meant for them. Never less than a road, since a hairline is too
/// thin to aim at.
double pickWidthOf(OsmWay way) {
  var width = mapStyle[layerIndex('minor')].width;
  for (final layer in wayLayersFor(way)) {
    final style = mapStyle[layer];
    if (style.kind == LayerKind.line && style.width > width) {
      width = style.width;
    }
  }
  return width;
}

/// The tiles to look through for something under a world position.
///
/// The tile the pointer is on and the ring around it. An element goes in the
/// tile holding its first node and is not cut at the edge, so a way running
/// out of its tile is still found from the one the pointer is over.
List<OsmTile> _tilesAround(Offset world, double reach, int zoom) {
  final middle = OsmTile.of(zoom, world.dx, world.dy);
  final across = 1 << zoom;
  // Round the world east to west, but not over the top or the bottom.
  return {
    for (var dy = -1; dy <= 1; dy++)
      for (var dx = -1; dx <= 1; dx++)
        if (middle.y + dy >= 0 && middle.y + dy < across)
          OsmTile(zoom, (middle.x + dx) % across, middle.y + dy),
  }.toList();
}

/// A way's nodes in world coordinates, or null if any of them is missing.
///
/// From where the nodes are now, which is where they have been moved to if
/// they have been moved at all.
List<double>? worldPointsOf(OsmWay way, MapStore store, [OsmEdits? edits]) {
  final points = <double>[];
  for (final id in way.nodeIds) {
    // A node taken off the map is left out rather than taken as a hole in
    // the line: a way that still names one has not caught up yet, and it is
    // better drawn short than not at all.
    if (edits?.isGone(OsmElementType.node, id) ?? false) continue;
    final node = edits?.changedNode(id) ?? store.nodes[id];
    if (node == null) return null;
    // Each beside the one before, so a way across the antimeridian is the
    // short way it is rather than one right round the world.
    final x = Mercator.x(node.longitude);
    points.add(
      points.isEmpty ? x : Mercator.nearest(x, points[points.length - 2]),
    );
    points.add(Mercator.y(node.latitude));
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
