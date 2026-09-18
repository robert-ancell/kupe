# Kupe

An OpenStreetMap editor for the desktop, the tablet and the phone.

Kupe aims to be as approachable as iD and as capable as JOSM, adapting what it
offers to the machine it is running on: a full editor on a desktop, a survey
tool on a tablet in the field, and quick fixes on a phone.

Everything that is not about the interface — reading and writing OpenStreetMap
data, assembling shapes, and applying changes — lives in
[osm.dart](https://github.com/robert-ancell/osm.dart) so that other tools can
use it too.

## Running

```
flutter run -d linux --release -a path/to/extract.osm.pbf
```

An area can be given as well, as south, west, north and east in degrees:

```
flutter run -d linux --release -a extract.osm.pbf -a -36.862 -a 174.752 -a -36.842 -a 174.778
```

Drag to pan, scroll or pinch to zoom. The readout in the corner shows how long
frames are taking.

## Building

```
flutter test
dart benchmark/tessellate.dart path/to/extract.osm.pbf
```

The benchmark reports what an area costs to turn into triangles, which is the
budget the map is drawn within.
