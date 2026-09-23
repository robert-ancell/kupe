import '../render/stroke.dart';

/// Whether a layer covers ground or draws a line along it.
enum LayerKind {
  /// A filled area, such as a lake or a building.
  fill,

  /// A stroked line, such as a road or a stream.
  line,

  /// A disc at a point, such as the end of a line.
  point,
}

/// One drawn layer of the map.
///
/// Every layer is a separate batch of triangles with a single colour, which
/// is what lets a whole tile go to the GPU in a handful of calls. Anything
/// that would vary the colour within a layer has to become its own layer.
class StyleLayer {
  /// The name of the layer, used to identify its batch.
  final String id;

  /// Whether the layer is filled or stroked.
  final LayerKind kind;

  /// The colour to draw it in, as 0xAARRGGBB.
  final int colour;

  /// For a line, how wide to draw it in pixels.
  ///
  /// On screen rather than on the ground. These lines are not there to show
  /// what a road looks like, which is what the imagery under them is for.
  /// They are what is taken hold of and moved, so they have to stay the same
  /// size to point at however far the map is zoomed.
  final double width;

  /// For a line, how to finish its ends.
  ///
  /// Square by default, which stops exactly at the last node. A round or
  /// extended end would reach past it and hide where the way really stops,
  /// which matters when the way is the thing being edited.
  final LineCap cap;

  /// For a line, how to fill its corners.
  final LineJoin join;

  /// The lowest zoom the layer is drawn at.
  final int minZoom;

  /// Creates a layer.
  const StyleLayer({
    required this.id,
    required this.kind,
    required this.colour,
    this.width = 0,
    this.cap = LineCap.butt,
    this.join = LineJoin.miter,
    this.minZoom = 0,
  });
}

/// The layers of the map, in the order they are drawn.
///
/// Casings come before the lines they sit under, so a road is drawn as a wide
/// dark line with a narrower light one over it, and junctions read correctly
/// because every casing in the map is already down before any fill goes on.
///
/// Line widths are pixels, and thin ones: over imagery a line is a handle on
/// what is underneath rather than a drawing of it, and a wide one hides the
/// road in the photograph, which is the thing being traced.
const mapStyle = <StyleLayer>[
  StyleLayer(id: 'earth', kind: LayerKind.fill, colour: 0xfff2efe9),
  StyleLayer(id: 'green', kind: LayerKind.fill, colour: 0xffc8e6a0),
  StyleLayer(id: 'sand', kind: LayerKind.fill, colour: 0xfff0e5c8),
  StyleLayer(id: 'water', kind: LayerKind.fill, colour: 0xffa5c9e8),
  StyleLayer(id: 'building', kind: LayerKind.fill, colour: 0xffd6cec4),
  StyleLayer(id: 'stream', kind: LayerKind.line, colour: 0xffa5c9e8, width: 2),
  StyleLayer(id: 'path', kind: LayerKind.line, colour: 0xffb08050, width: 1.5),
  StyleLayer(id: 'rail', kind: LayerKind.line, colour: 0xff9a9a9a, width: 2),
  StyleLayer(
    id: 'minor-casing',
    kind: LayerKind.line,
    colour: 0xffcfcabb,
    width: 5,
  ),
  StyleLayer(
    id: 'major-casing',
    kind: LayerKind.line,
    colour: 0xffc0a878,
    width: 7,
  ),
  StyleLayer(id: 'minor', kind: LayerKind.line, colour: 0xffffffff, width: 3),
  StyleLayer(id: 'major', kind: LayerKind.line, colour: 0xfff8d98a, width: 5),
  // Last, so that the points a line can be taken hold of by are on top of
  // every line, including the ones they join.
  StyleLayer(
    id: 'vertex-edge',
    kind: LayerKind.point,
    colour: 0xff44505c,
    width: 7,
  ),
  StyleLayer(
    id: 'vertex',
    kind: LayerKind.point,
    colour: 0xffffffff,
    width: 4.4,
  ),
];

/// The layers a point is drawn as, as indices into [mapStyle].
///
/// A disc with an edge around it, so that it shows up over a light road and
/// over a dark photograph alike.
final pointLayers = [layerIndex('vertex-edge'), layerIndex('vertex')];

/// The index of the layer with the given id.
int layerIndex(String id) => mapStyle.indexWhere((layer) => layer.id == id);

const _greenValues = {
  'park',
  'grass',
  'forest',
  'wood',
  'meadow',
  'scrub',
  'garden',
  'golf_course',
  'pitch',
  'recreation_ground',
  'village_green',
  'cemetery',
  'orchard',
  'farmland',
  'heath',
  'allotments',
};

const _sandValues = {'sand', 'beach', 'bare_rock', 'scree', 'quarry'};

const _waterValues = {'water', 'reservoir', 'basin', 'wetland', 'bay'};

const _majorRoads = {
  'motorway',
  'motorway_link',
  'trunk',
  'trunk_link',
  'primary',
  'primary_link',
  'secondary',
  'secondary_link',
};

const _minorRoads = {
  'tertiary',
  'tertiary_link',
  'residential',
  'unclassified',
  'living_street',
  'service',
  'road',
  'pedestrian',
  'busway',
};

const _paths = {
  'footway',
  'path',
  'cycleway',
  'bridleway',
  'steps',
  'track',
  'corridor',
};

/// The layers a filled element belongs in, as indices into [mapStyle].
List<int> fillLayersFor(Map<String, String> tags) {
  final layers = <int>[];
  if (tags.containsKey('building') || tags.containsKey('building:part')) {
    layers.add(layerIndex('building'));
  }
  final natural = tags['natural'];
  final landuse = tags['landuse'];
  final leisure = tags['leisure'];
  if (natural == 'water' ||
      tags.containsKey('water') ||
      _waterValues.contains(landuse) ||
      _waterValues.contains(natural)) {
    layers.add(layerIndex('water'));
  } else if (_greenValues.contains(landuse) ||
      _greenValues.contains(leisure) ||
      _greenValues.contains(natural)) {
    layers.add(layerIndex('green'));
  } else if (_sandValues.contains(natural) || _sandValues.contains(landuse)) {
    layers.add(layerIndex('sand'));
  }
  return layers;
}

/// The layers a linear element belongs in, as indices into [mapStyle].
///
/// A road returns two: the casing under it and the line over it.
List<int> lineLayersFor(Map<String, String> tags) {
  final highway = tags['highway'];
  if (highway != null) {
    if (_majorRoads.contains(highway)) {
      return [layerIndex('major-casing'), layerIndex('major')];
    }
    if (_minorRoads.contains(highway)) {
      return [layerIndex('minor-casing'), layerIndex('minor')];
    }
    if (_paths.contains(highway)) return [layerIndex('path')];
    return const [];
  }
  if (tags.containsKey('railway')) return [layerIndex('rail')];
  final waterway = tags['waterway'];
  if (waterway == 'river' || waterway == 'stream' || waterway == 'canal') {
    return [layerIndex('stream')];
  }
  return const [];
}

/// Whether a closed way with these tags encloses an area or is a loop.
///
/// A closed way is only a shape if its tags say so. A roundabout and a
/// building are both rings of nodes; only one of them is filled in.
bool enclosesArea(Map<String, String> tags) {
  if (tags['area'] == 'yes') return true;
  if (tags.containsKey('highway') ||
      tags.containsKey('barrier') ||
      tags.containsKey('railway')) {
    return false;
  }
  return tags.containsKey('building') ||
      tags.containsKey('building:part') ||
      tags.containsKey('landuse') ||
      tags.containsKey('leisure') ||
      tags.containsKey('natural') ||
      tags.containsKey('amenity') ||
      tags.containsKey('water') ||
      tags.containsKey('place');
}
