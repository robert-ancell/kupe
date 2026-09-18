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
flutter run -d linux --release
```

A place to open at can be given as latitude, longitude and zoom:

```
flutter run -d linux --release -a -36.8485 -a 174.7633 -a 17
```

Drag to pan, scroll or pinch to zoom. The map is read from OpenStreetMap as it
is looked at, in boxes sized so that a screenful costs about the same number of
requests however far out it is. Somewhere crowded enough that a screen cannot
be read within that budget says so and asks to be zoomed in. The readout in the
corner shows how long frames are taking and how much has been asked of the API.

## Building

```
flutter test
dart benchmark/tessellate.dart path/to/extract.osm.pbf
```

The benchmark reports what an area costs to turn into triangles, which is the
budget the map is drawn within.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
