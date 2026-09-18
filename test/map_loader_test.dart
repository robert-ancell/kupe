import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/data/map_loader.dart';
import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(800, 600);

/// An API held in memory that records every box it was asked for.
class _Api {
  final List<OsmBounds> asked = [];

  /// Boxes wider than this are refused as holding too much, standing in for
  /// the real limit on how much one answer may contain.
  final double? refuseWiderThan;

  _Api({this.refuseWiderThan});

  Future<Uint8List?> fetch(Uri uri) async {
    final parts = uri.queryParameters['bbox']!.split(',').map(double.parse);
    final [west, south, east, north] = parts.toList();
    asked.add(
      OsmBounds(
        minLatitude: south,
        minLongitude: west,
        maxLatitude: north,
        maxLongitude: east,
      ),
    );
    if (refuseWiderThan != null && east - west > refuseWiderThan!) {
      throw OsmHttpException(uri, HttpStatus.badRequest);
    }
    // A short road across the middle of the box, with ids of its own, so
    // that every tile has a line in it to draw and to build again.
    final id = asked.length * 10;
    final lat = (south + north) / 2;
    return Uint8List.fromList(
      utf8.encode(
        '<osm version="0.6">'
        '<node id="$id" lat="$lat" lon="${west + (east - west) * 0.25}" '
        'version="1"/>'
        '<node id="${id + 1}" lat="$lat" '
        'lon="${west + (east - west) * 0.75}" version="1"/>'
        '<way id="${id + 2}" version="1">'
        '<nd ref="$id"/><nd ref="${id + 1}"/>'
        '<tag k="highway" v="residential"/>'
        '</way>'
        '</osm>',
      ),
    );
  }
}

MapLoader _loaderOn(_Api server, {void Function()? onChanged}) => MapLoader(
  api: OsmApi(fetch: server.fetch),
  onChanged: onChanged ?? () {},
);

/// Lets every queued request run to completion.
Future<void> _drain() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('asks for nothing while zoomed too far out', () async {
    final server = _Api();
    _loaderOn(server).look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: minimumLoadZoom - 1),
      _size,
    );
    await _drain();
    expect(server.asked, isEmpty);
  });

  test('asks once it is zoomed in far enough', () async {
    final server = _Api();
    _loaderOn(server).look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: minimumLoadZoom),
      _size,
    );
    await _drain();
    expect(server.asked, isNotEmpty);
  });

  test('asks only for what is on screen', () async {
    final server = _Api();
    final camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17);
    _loaderOn(server).look(camera, _size);
    await _drain();

    final view = camera.worldBounds(_size);
    for (final box in server.asked) {
      final west = (box.minLongitude + 180) / 360;
      final east = (box.maxLongitude + 180) / 360;
      expect(east, greaterThan(view.left - 1e-9));
      expect(west, lessThan(view.right + 1e-9));
    }
  });

  test('never asks for the same tile twice', () async {
    final server = _Api();
    final loader = _loaderOn(server);
    final camera = Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17);
    for (var i = 0; i < 5; i++) {
      loader.look(camera, _size);
      await _drain();
    }
    final boxes = server.asked.map((b) => '${b.minLatitude},${b.minLongitude}');
    expect(boxes.toSet().length, boxes.length);
  });

  test('does not ask for more than one view holds', () async {
    final server = _Api();
    final loader = _loaderOn(server);
    // A view far larger than any screen, at the lowest zoom that loads.
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: minimumLoadZoom),
      const Size(8000, 8000),
    );
    await _drain();
    expect(server.asked.length, lessThanOrEqualTo(maximumTilesPerView));
  });

  test('drops what the view has moved away from', () async {
    final server = _Api();
    final loader = _loaderOn(server);
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
      const Size(4000, 4000),
    );
    // Moved to the other side of the world before the queue could drain.
    loader.look(
      Camera.at(latitude: 51.5, longitude: -0.12, zoom: 17),
      const Size(4000, 4000),
    );
    await _drain();
    final auckland = server.asked.where((b) => b.minLongitude > 0).length;
    final london = server.asked.where((b) => b.minLongitude < 0).length;
    expect(london, greaterThan(0));
    expect(auckland, lessThanOrEqualTo(maximumInFlight));
  });

  test('splits a box the API says holds too much', () async {
    final whole = const TileId(loadZoom, 0, 0).bounds;
    final server = _Api(
      refuseWiderThan: (whole.maxLongitude - whole.minLongitude) * 0.75,
    );
    final loader = _loaderOn(server);
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
      const Size(300, 300),
    );
    await _drain();
    // The refused box, then its four quarters.
    expect(server.asked.length, greaterThanOrEqualTo(5));
    expect(loader.store.nodes, isNotEmpty);
  });

  test('stops asking when the server says it has had enough', () async {
    final server = _TooManyRequests();
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      onChanged: () {},
    );
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
      const Size(2000, 2000),
    );
    await _drain();
    expect(loader.stopped, isNotNull);
    expect(server.asked, lessThanOrEqualTo(maximumInFlight));
  });

  test('keeps what it read as the view moves on', () async {
    final server = _Api();
    final loader = _loaderOn(server);
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
      _size,
    );
    await _drain();
    final held = loader.store.length;
    expect(held, greaterThan(0));
    loader.look(
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: 15),
      _size,
    );
    await _drain();
    expect(loader.store.length, held);
  });
  group('line widths', () {
    test('a fresh tile is built for the zoom it was read at', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      expect(loader.tiles, isNotEmpty);
      expect(loader.stale, 0);
    });

    test('zooming leaves the widths behind', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 18),
        _size,
      );
      expect(loader.stale, greaterThan(0));
    });

    test('a small zoom is inside the tolerance and rebuilds nothing', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      // A twentieth of a zoom level is a three and a half per cent error.
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17.05),
        _size,
      );
      expect(loader.stale, 0);
      expect(loader.restroke(), isFalse);
    });

    test('rebuilding catches the widths up with the zoom', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 19),
        _size,
      );
      var passes = 0;
      while (loader.restroke() && passes < 100) {
        passes += 1;
      }
      expect(loader.stale, 0);
    });

    test('rebuilding asks the API for nothing', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      final asked = server.asked.length;
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 19),
        _size,
      );
      while (loader.restroke()) {}
      expect(server.asked.length, asked);
    });

    test('rebuilding keeps the filled shapes as they were', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      final before = {for (final t in loader.tiles) t.id: t.fills};
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 19),
        _size,
      );
      while (loader.restroke()) {}
      for (final tile in loader.tiles) {
        expect(identical(tile.fills, before[tile.id]), isTrue);
      }
    });
    test('leaves a tile that has been scrolled away from alone', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      expect(loader.tiles, isNotEmpty);
      // Zoomed in, which would leave every width behind, and moved to the
      // other side of the world, where none of them can be seen.
      loader.look(Camera.at(latitude: 51.5, longitude: -0.12, zoom: 19), _size);
      expect(loader.stale, 0);
      expect(loader.restroke(), isFalse);
    });
  });
}

/// An API that has had enough and says so at once.
class _TooManyRequests {
  int asked = 0;

  Future<Uint8List?> fetch(Uri uri) async {
    asked++;
    throw OsmHttpException(uri, HttpStatus.tooManyRequests);
  }
}
