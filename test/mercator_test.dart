import 'package:kupe/src/geometry/mercator.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:test/test.dart';

void main() {
  test('puts the origin at the north west corner', () {
    expect(Mercator.x(-180), closeTo(0, 1e-12));
    expect(Mercator.y(Mercator.latitudeLimit), closeTo(0, 1e-9));
  });

  test('puts null island in the middle', () {
    expect(Mercator.x(0), closeTo(0.5, 1e-12));
    expect(Mercator.y(0), closeTo(0.5, 1e-12));
  });

  test('round trips a location', () {
    for (final latitude in [-84.0, -36.85, 0.0, 51.5, 84.0]) {
      for (final longitude in [-179.0, -1.0, 0.0, 174.76, 179.0]) {
        expect(
          Mercator.latitude(Mercator.y(latitude)),
          closeTo(latitude, 1e-9),
        );
        expect(
          Mercator.longitude(Mercator.x(longitude)),
          closeTo(longitude, 1e-9),
        );
      }
    }
  });

  test('clamps beyond the limit rather than running to infinity', () {
    expect(Mercator.y(90), closeTo(0, 1e-9));
    expect(Mercator.y(-90), closeTo(1, 1e-9));
  });

  test('stretches distances away from the equator', () {
    expect(Mercator.metresPerUnit(0), greaterThan(Mercator.metresPerUnit(60)));
    expect(
      Mercator.metresPerUnit(60),
      closeTo(Mercator.metresPerUnit(0) / 2, 1),
    );
  });

  test('numbers tiles from the north west', () {
    expect(TileId.at(0, 0, 0), const TileId(0, 0, 0));
    expect(TileId.at(1, 45, -90), const TileId(1, 0, 0));
    expect(TileId.at(1, -45, 90), const TileId(1, 1, 1));
  });

  test('keeps a tile inside the world at the edges', () {
    expect(TileId.at(2, -89, 180).x, 3);
    expect(TileId.at(2, -89, 180).y, 3);
  });

  test('halves a tile for each zoom level', () {
    expect(const TileId(0, 0, 0).size, 1);
    expect(const TileId(10, 0, 0).size, closeTo(1 / 1024, 1e-12));
  });
}
