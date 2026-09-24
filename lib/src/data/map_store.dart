import 'package:osm/osm.dart';

/// Everything read from OpenStreetMap so far, stitched into one dataset.
///
/// The API is asked for one box at a time and its answers overlap: a way
/// arrives whole with every one of its nodes, so a way along a boundary comes
/// back with each box it touches, and the nodes past the edge come with it.
/// Holding elements by id rather than by the box they arrived in makes those
/// copies collapse into one, and leaves each box able to resolve geometry
/// that reaches into a box that has not been asked for yet.
class MapStore {
  final _nodes = <int, OsmNode>{};
  final _ways = <int, OsmWay>{};
  final _relations = <int, OsmRelation>{};
  final _drawn = <(OsmElementType, int), OsmTile>{};
  final _byTile = <OsmTile, List<OsmElement>>{};
  final _nodeWays = <int, List<int>>{};
  final _nodeUses = <int, int>{};
  final _nodeEnds = <int, int>{};

  /// Every node held, by id.
  Map<int, OsmNode> get nodes => _nodes;

  /// Every way held, by id.
  Map<int, OsmWay> get ways => _ways;

  /// Every relation held, by id.
  Map<int, OsmRelation> get relations => _relations;

  /// How many elements are held.
  int get length => _nodes.length + _ways.length + _relations.length;

  /// Takes in what a box answered with, and returns the elements that no
  /// earlier box had already taken.
  ///
  /// The ones returned are what [tile] is left to draw. An element that
  /// arrived with an earlier box is already on the map, and drawing it again
  /// would lay it over itself and count twice against the frame.
  ///
  /// Which box drew what is remembered, so that reading a box again can take
  /// back what it drew before. Without that a deleted element would stay on
  /// the map for ever: an answer says what is there, never what has gone.
  List<OsmElement> add(OsmTile tile, Iterable<OsmElement> elements) {
    for (final element in elements) {
      switch (element) {
        case OsmNode():
          _keep(_nodes, element.id, element);
        case OsmWay():
          _keep(_ways, element.id, element);
        case OsmRelation():
          _keep(_relations, element.id, element);
      }
    }

    final fresh = <OsmElement>[];
    for (final element in elements) {
      final key = (element.type, element.id);
      if (_drawn.containsKey(key)) continue;
      _drawn[key] = tile;
      (_byTile[tile] ??= <OsmElement>[]).add(element);
      if (element is OsmWay) _count(element, 1);
      fresh.add(element);
    }
    return fresh;
  }

  /// What [tile] drew, which is what to look through to say what is under a
  /// point on it.
  List<OsmElement> drawnIn(OsmTile tile) => _byTile[tile] ?? const [];

  /// The ways held that run through the node with [id].
  ///
  /// What has to be drawn again when that node moves.
  List<int> waysUsing(int id) => _nodeWays[id] ?? const [];

  /// How many of the ways held run through the node with [id].
  ///
  /// More than one means the ways meet there, which is a place worth being
  /// able to take hold of whether or not anything is selected.
  int waysThrough(int id) => _nodeUses[id] ?? 0;

  /// Whether the node with [id] is where some way starts or stops.
  bool isEndOfWay(int id) => (_nodeEnds[id] ?? 0) > 0;

  /// Keeps the count of what runs through each node as ways come and go.
  void _count(OsmWay way, int by) {
    if (way.nodeIds.isEmpty) return;
    for (final id in way.nodeIds.toSet()) {
      final uses = (_nodeUses[id] ?? 0) + by;
      if (uses > 0) {
        _nodeUses[id] = uses;
      } else {
        _nodeUses.remove(id);
      }
      if (by > 0) {
        (_nodeWays[id] ??= <int>[]).add(way.id);
      } else {
        _nodeWays[id]?.remove(way.id);
        if (_nodeWays[id]?.isEmpty ?? false) _nodeWays.remove(id);
      }
    }
    for (final id in {way.nodeIds.first, way.nodeIds.last}) {
      final ends = (_nodeEnds[id] ?? 0) + by;
      if (ends > 0) {
        _nodeEnds[id] = ends;
      } else {
        _nodeEnds.remove(id);
      }
    }
  }

  /// Forgets everything [tile] drew, so that reading it again starts clean.
  ///
  /// An answer says what is there and never what has gone, so an element
  /// deleted since would otherwise stay on the map for ever. Elements another
  /// box drew are left alone, even where this one also held them: they are
  /// that box's to take back.
  void release(OsmTile tile) {
    _byTile.remove(tile);
    final letting = <(OsmElementType, int)>[];
    for (final entry in _drawn.entries) {
      if (entry.value == tile) letting.add(entry.key);
    }
    for (final key in letting) {
      _drawn.remove(key);
      if (key.$1 == OsmElementType.way) {
        final way = _ways[key.$2];
        if (way != null && way.nodeIds.isNotEmpty) _count(way, -1);
      }
      switch (key.$1) {
        case OsmElementType.node:
          _nodes.remove(key.$2);
        case OsmElementType.way:
          _ways.remove(key.$2);
        case OsmElementType.relation:
          _relations.remove(key.$2);
      }
    }
  }

  /// Keeps the newer of what is held and what has arrived.
  ///
  /// Two boxes read seconds apart can straddle an edit, so the same element
  /// can arrive at two versions. Without a version to go on the later answer
  /// is taken, since it cannot be older than the one before it.
  static void _keep<T extends OsmElement>(Map<int, T> into, int id, T element) {
    final held = into[id];
    if (held == null) {
      into[id] = element;
      return;
    }
    final was = held.info?.version;
    final now = element.info?.version;
    if (was == null || now == null || now >= was) into[id] = element;
  }

  /// The elements in [matches] along with everything they refer to, ready to
  /// have geometry built from.
  OsmSubset subsetOf(List<OsmElement> matches) => OsmSubset(
    matches: matches,
    nodes: _nodes,
    ways: _ways,
    relations: _relations,
  );

  @override
  String toString() =>
      'MapStore(${_nodes.length} nodes, ${_ways.length} ways, '
      '${_relations.length} relations)';
}
