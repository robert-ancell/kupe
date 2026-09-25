import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/data/last_place.dart';
import 'package:kupe/src/data/map_loader.dart';
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

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
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

MapLoader _loaderOn(_Api server, {OsmTileCache? cache}) => MapLoader(
  api: OsmApiClient(fetch: server.fetch),
  cache: cache,
  onChanged: () {},
);

Camera _at(double zoom) =>
    Camera.at(latitude: -36.85, longitude: 174.76, zoom: zoom);

/// Lets every queued request run to completion, including work that takes
/// real time such as reading files, which takes longer again when the whole
/// suite is running at once.
Future<void> _drain() async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
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
    final whole = const OsmTile(loadZoom, 0, 0).bounds;
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
      api: OsmApiClient(fetch: server.fetch),
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

  test('keeps what it read when the map zooms past where it reads', () async {
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
      Camera.at(latitude: -36.85, longitude: 174.76, zoom: minimumLoadZoom - 1),
      _size,
    );
    await _drain();
    expect(loader.store.length, held);
  });
  group('how much is asked for', () {
    test('asks for the same size of box at every zoom', () async {
      // As iD does: zooming in never asks for anything but zoom 16 boxes.
      for (final zoom in [16.0, 17.0, 19.0]) {
        final server = _Api();
        _loaderOn(server).look(_at(zoom), _size);
        await _drain();
        for (final box in server.asked) {
          final width = box.maxLongitude - box.minLongitude;
          expect(width, closeTo(360 / (1 << loadZoom), 1e-9), reason: 'z$zoom');
        }
      }
    });

    test('does not fan out without limit over a crowded area', () async {
      // An API that says every box holds too much, however small.
      final server = _Api(refuseWiderThan: 0);
      final loader = _loaderOn(server);
      loader.look(_at(16), _size);
      await _drain();
      expect(server.asked.length, lessThanOrEqualTo(maximumRequestsPerView));
      expect(loader.crowded, isTrue);
    });

    test('says nothing is crowded when everything was read', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(
        Camera.at(latitude: -36.85, longitude: 174.76, zoom: 17),
        _size,
      );
      await _drain();
      expect(loader.crowded, isFalse);
    });
  });
  group('what is held on disk', () {
    late Directory work;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('kupe_loader_test');
    });

    tearDown(() async {
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('keeps what it read for next time', () async {
      final cache = await OsmTileCache.open(directory: work);
      final server = _Api();
      _loaderOn(server, cache: cache).look(_at(17), _size);
      await _drain();
      expect(cache.tiles.length, server.asked.length);
    });

    test('opens from disk without asking the API', () async {
      final cache = await OsmTileCache.open(directory: work);
      final first = _Api();
      _loaderOn(first, cache: cache).look(_at(17), _size);
      await _drain();
      expect(first.asked, isNotEmpty);

      // A second run over the same place, with the cache still there.
      final again = await OsmTileCache.open(directory: work);
      final second = _Api();
      final loader = _loaderOn(second, cache: again);
      loader.look(_at(17), _size);
      await _drain();
      expect(second.asked, isEmpty);
      expect(loader.tiles, isNotEmpty);
    });

    test('remembers where the map was left', () async {
      final place = File('${work.path}/place.json');
      MapLoader(
        api: OsmApiClient(fetch: _Api().fetch),
        place: place,
        onChanged: () {},
      ).look(_at(17), _size);
      await _drain();
      final left = await LastPlace.read(place);
      expect(left, isNotNull);
      expect(left!.zoom, 17);
    });

    test('reads a box again when its file will not open', () async {
      final cache = await OsmTileCache.open(directory: work);
      final first = _Api();
      _loaderOn(first, cache: cache).look(_at(17), _size);
      await _drain();

      // Something truncated the files.
      for (final file in work.listSync(recursive: true)) {
        if (file is File && file.path.endsWith('.osm.pbf')) {
          file.writeAsBytesSync([0, 1, 2]);
        }
      }

      final again = await OsmTileCache.open(directory: work);
      final second = _Api();
      final loader = _loaderOn(second, cache: again);
      loader.look(_at(17), _size);
      await _drain();
      expect(second.asked, isNotEmpty);
      expect(loader.tiles, isNotEmpty);
    });

    test('works with no cache at all', () async {
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(_at(17), _size);
      await _drain();
      expect(loader.tiles, isNotEmpty);
    });
  });
  group('being turned away', () {
    test('picks itself up again rather than stopping for good', () async {
      final server = _Unwell();
      final loader = MapLoader(
        api: OsmApiClient(fetch: server.fetch),
        onChanged: () {},
      );
      loader.look(_at(17), _size);
      await _drain();
      expect(loader.stopped, isNotNull, reason: 'paused while it is unwell');

      // The server comes right, and the wait passes.
      server.unwell = false;
      await Future<void>.delayed(retryDelay + const Duration(seconds: 1));
      await _drain();

      expect(loader.stopped, isNull);
      expect(loader.tiles, isNotEmpty);
      loader.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('asks again for the box it was turned away on', () async {
      final server = _Unwell();
      final loader = MapLoader(
        api: OsmApiClient(fetch: server.fetch),
        onChanged: () {},
      );
      loader.look(_at(17), _size);
      await _drain();
      final turnedAway = server.refused;
      expect(turnedAway, isNotEmpty);

      server.unwell = false;
      await Future<void>.delayed(retryDelay + const Duration(seconds: 1));
      await _drain();

      // A box asked for and never answered has not been read, so it must not
      // be left as a hole in the map.
      for (final box in turnedAway) {
        expect(server.asked.map((b) => b.toString()), contains(box.toString()));
      }
      loader.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('survives the network being away', () async {
      final server = _Offline();
      final loader = MapLoader(
        api: OsmApiClient(fetch: server.fetch),
        onChanged: () {},
      );
      loader.look(_at(17), _size);
      await _drain();
      // A dropped socket is not an HTTP answer and must not escape as an
      // unhandled error.
      expect(loader.stopped, isNotNull);
      loader.dispose();
    });
  });
  group('zooming', () {
    test('builds nothing again and asks for nothing', () async {
      // A line is anchored to the ground with its width held apart, so a new
      // zoom is arithmetic in the painter rather than a new tile here.
      final server = _Api();
      final loader = _loaderOn(server);
      loader.look(_at(17), _size);
      await _drain();
      expect(loader.tiles, isNotEmpty);
      final before = {for (final tile in loader.tiles) tile.id: tile};
      final asked = server.asked.length;

      loader.look(_at(19), _size);
      loader.look(_at(17.3), _size);
      for (final tile in loader.tiles) {
        if (before[tile.id] case final was?) {
          expect(identical(tile, was), isTrue, reason: '${tile.id}');
        }
      }
      expect(server.asked.length, asked);
    });
  });
}

/// An API that has had enough and says so at once.
class _TooManyRequests {
  int asked = 0;

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    asked++;
    throw OsmHttpException(uri, HttpStatus.tooManyRequests);
  }
}

/// An API that is too busy until it is not.
class _Unwell {
  bool unwell = true;

  /// The boxes it refused while it was unwell.
  final List<OsmBounds> refused = [];

  /// The boxes it answered.
  final List<OsmBounds> asked = [];

  final _well = _Api();

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    final parts = uri.queryParameters['bbox']!.split(',').map(double.parse);
    final [west, south, east, north] = parts.toList();
    final bounds = OsmBounds(
      minLatitude: south,
      minLongitude: west,
      maxLatitude: north,
      maxLongitude: east,
    );
    if (unwell) {
      refused.add(bounds);
      throw OsmHttpException(uri, HttpStatus.serviceUnavailable);
    }
    asked.add(bounds);
    return _well.fetch(uri);
  }
}

/// A network that is not there.
class _Offline {
  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async => throw const SocketException('nothing is listening');
}
