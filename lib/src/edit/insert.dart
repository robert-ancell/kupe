import 'dart:math' as math;

import 'package:osm/osm.dart';

import '../data/map_store.dart';

/// Where a point falls along a line, and how far off it is.
class _Along {
  /// The segment it falls on, by the index of the node before it.
  final int segment;

  /// How far along that segment, from nothing to one.
  final double fraction;

  /// How far the point is from the line, in world units.
  final double distance;

  const _Along(this.segment, this.fraction, this.distance);
}

/// Puts a node into [way] where ([worldX], [worldY]) falls along it, and into
/// every other way that runs along the same stretch.
///
/// Two ways that both run between the same pair of nodes are drawn one over
/// the other, so adding a node to one and not the other would tear them
/// apart at exactly the place someone was working on. A footway drawn along a
/// bridge, or a boundary following a river, are the usual cases.
///
/// Returns the node made, or null if the point is nowhere along the way.
OsmNode? insertNodeInto(
  OsmWay way,
  MapStore store,
  OsmEdits edits, {
  required double worldX,
  required double worldY,
}) {
  final running = edits.changedWay(way.id) ?? way;
  final where = _alongWay(running, store, edits, worldX, worldY);
  if (where == null) return null;

  final before = running.nodeIds[where.segment];
  final after = running.nodeIds[where.segment + 1];

  final start = _nodeOf(before, store, edits)!;
  final end = _nodeOf(after, store, edits)!;
  final node = edits.createNode(
    latitude: start.latitude + (end.latitude - start.latitude) * where.fraction,
    longitude:
        start.longitude + (end.longitude - start.longitude) * where.fraction,
  );

  // Every way running between the same two nodes, this one included.
  for (final id in {...store.waysUsing(before), ...edits.changedWays.keys}) {
    final other = edits.changedWay(id) ?? store.ways[id];
    if (other == null) continue;
    final at = _segmentBetween(other, before, after);
    if (at == null) continue;
    edits.setWayNodes(other, [
      ...other.nodeIds.sublist(0, at + 1),
      node.id,
      ...other.nodeIds.sublist(at + 1),
    ]);
  }
  return node;
}

/// Where along a way a point falls, or null if the way has no length.
_Along? _alongWay(
  OsmWay way,
  MapStore store,
  OsmEdits edits,
  double worldX,
  double worldY,
) {
  _Along? nearest;
  for (var i = 0; i + 1 < way.nodeIds.length; i++) {
    final start = _nodeOf(way.nodeIds[i], store, edits);
    final end = _nodeOf(way.nodeIds[i + 1], store, edits);
    if (start == null || end == null) continue;

    final ax = Mercator.x(start.longitude);
    final ay = Mercator.y(start.latitude);
    final bx = Mercator.x(end.longitude);
    final by = Mercator.y(end.latitude);
    final dx = bx - ax;
    final dy = by - ay;
    final length = dx * dx + dy * dy;
    final along = length == 0
        ? 0.0
        : (((worldX - ax) * dx + (worldY - ay) * dy) / length).clamp(0.0, 1.0);
    final nx = ax + dx * along;
    final ny = ay + dy * along;
    final distance = math.sqrt(
      (worldX - nx) * (worldX - nx) + (worldY - ny) * (worldY - ny),
    );
    if (nearest == null || distance < nearest.distance) {
      nearest = _Along(i, along, distance);
    }
  }
  return nearest;
}

/// Where [way] runs from [before] to [after], either way round, by the index
/// of the first of them, or null if it does not.
int? _segmentBetween(OsmWay way, int before, int after) {
  for (var i = 0; i + 1 < way.nodeIds.length; i++) {
    final a = way.nodeIds[i];
    final b = way.nodeIds[i + 1];
    if ((a == before && b == after) || (a == after && b == before)) return i;
  }
  return null;
}

OsmNode? _nodeOf(int id, MapStore store, OsmEdits edits) =>
    edits.movedNode(id) ?? store.nodes[id];
