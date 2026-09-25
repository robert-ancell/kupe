import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/data/map_loader.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(400, 400);

Camera _at(double zoom) =>
    Camera.at(latitude: -36.85, longitude: 174.76, zoom: zoom);

/// Lets everything queued run, including work that takes real time such as
/// reading files, which takes longer again when the whole suite is running
/// at once. Turning microtasks over alone is not enough.
Future<void> _drain() async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// An API that answers boxes and says what has been edited over them.
class _Api {
  /// The boxes asked for, in order.
  final List<OsmBounds> boxes = [];

  /// How many times it was asked what had been edited.
  int checks = 0;

  /// The changesets to report, as `(bbox or null)` in degrees.
  List<OsmBounds?> edits = const [];

  /// Whether to report more edits than the caller will take.
  bool tooManyEdits = false;

  /// Ids the boxes no longer hold, standing in for elements deleted since.
  Set<int> deleted = const {};

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    if (uri.path.endsWith('changesets')) {
      checks++;
      if (tooManyEdits) return _changesetPage();
      return _bytes(
        '<osm version="0.6">'
        '${edits.map(_changeset).join()}'
        '</osm>',
      );
    }

    final [west, south, east, north] = uri.queryParameters['bbox']!
        .split(',')
        .map(double.parse)
        .toList();
    boxes.add(
      OsmBounds(
        minLatitude: south,
        minLongitude: west,
        maxLatitude: north,
        maxLongitude: east,
      ),
    );

    // Two nodes and a way joining them, with ids fixed by where the box is
    // so that reading the same box twice gives the same elements back.
    final id = boxes.length * 10;
    final lat = (south + north) / 2;
    return _bytes(
      '<osm version="0.6">'
      '${deleted.contains(id) ? '' : '<node id="$id" lat="$lat" '
                'lon="${west + (east - west) * 0.25}" version="1"/>'}'
      '<node id="${id + 1}" lat="$lat" '
      'lon="${west + (east - west) * 0.75}" version="1"/>'
      '<way id="${id + 2}" version="1">'
      '<nd ref="${id + 1}"/><nd ref="${id + 1}"/>'
      '<tag k="highway" v="residential"/>'
      '</way>'
      '</osm>',
    );
  }

  static String _changeset(OsmBounds? at) =>
      '<changeset id="1" '
      'created_at="2026-09-18T06:00:00Z" open="false" '
      'closed_at="2026-09-18T07:00:00Z" changes_count="1"'
      '${at == null ? '' : ' min_lat="${at.minLatitude}" '
                'min_lon="${at.minLongitude}" max_lat="${at.maxLatitude}" '
                'max_lon="${at.maxLongitude}"'}/>';

  /// A page that stays full however often it is asked for, which is what more
  /// edits than the caller will take looks like.
  Uint8List _changesetPage() {
    final buffer = StringBuffer('<osm version="0.6">');
    for (var i = 0; i < 100; i++) {
      final id = checks * 1000 + i;
      final at = DateTime.utc(2026, 9, 18).subtract(Duration(seconds: id));
      buffer.write(
        '<changeset id="$id" created_at="${at.toIso8601String()}" '
        'open="false" closed_at="${at.toIso8601String()}" '
        'changes_count="1"/>',
      );
    }
    buffer.write('</osm>');
    return _bytes(buffer.toString());
  }

  static Uint8List _bytes(String xml) => Uint8List.fromList(utf8.encode(xml));
}

/// Ages everything the cache holds so that it is worth checking, the way it
/// would be on opening the editor the next day.
Future<OsmDataCache> _aged(Directory work) async {
  final index = File('${work.path}/index.json');
  final parsed = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
  final long = DateTime.now()
      .subtract(OsmDataCache.freshness * 2)
      .millisecondsSinceEpoch;
  for (final tile in parsed['tiles'] as List) {
    (tile as Map<String, dynamic>)['at'] = long;
  }
  await index.writeAsString(jsonEncode(parsed));
  return OsmDataCache.open(directory: work);
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('kupe_refresh_test');
  });

  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// Reads a view into a cache and hands back the cache, aged.
  Future<OsmDataCache> fill(_Api server) async {
    final cache = await OsmDataCache.open(directory: work);
    MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    ).look(_at(17), _size);
    await _drain();
    return _aged(work);
  }

  test('does not check anything while what it holds is new', () async {
    final server = _Api();
    final cache = await OsmDataCache.open(directory: work);
    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    await loader.refresh();
    expect(server.checks, 0);
  });

  test('asks once what has been edited, however many boxes it holds', () async {
    final server = _Api();
    final cache = await fill(server);
    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    expect(cache.tiles.length, greaterThan(1));

    await loader.refresh();
    await _drain();
    expect(server.checks, 1);
  });

  test('reads nothing again when nothing near it was edited', () async {
    final server = _Api()..edits = const [];
    final cache = await fill(server);
    final read = server.boxes.length;

    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    await loader.refresh();
    await _drain();
    expect(server.boxes.length, read);
    // And having been checked, they are not asked about a second time.
    await loader.refresh();
    expect(server.checks, 1);
  });

  test('reads a box again when something in it was edited', () async {
    final server = _Api();
    final cache = await fill(server);
    final read = server.boxes.length;
    // An edit right where the map is looking.
    server.edits = const [
      OsmBounds(
        minLatitude: -36.851,
        minLongitude: 174.759,
        maxLatitude: -36.849,
        maxLongitude: 174.761,
      ),
    ];

    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    await loader.refresh();
    await _drain();
    expect(server.boxes.length, greaterThan(read));
  });

  test('leaves a box alone when the edit was somewhere else', () async {
    final server = _Api();
    final cache = await fill(server);
    final read = server.boxes.length;
    // An edit on the other side of the world.
    server.edits = const [
      OsmBounds(
        minLatitude: 51.5,
        minLongitude: -0.13,
        maxLatitude: 51.51,
        maxLongitude: -0.12,
      ),
    ];

    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    await loader.refresh();
    await _drain();
    expect(server.boxes.length, read);
  });

  test(
    'reads everything again when a changeset says where it reached',
    () async {
      final server = _Api();
      final cache = await fill(server);
      final read = server.boxes.length;
      // A changeset with no bounds at all says nothing about where it was, so
      // it has to be taken as reaching everywhere.
      server.edits = const [null];

      final loader = MapLoader(
        client: OsmApiClient(fetch: server.fetch),
        cache: cache,
        onChanged: () {},
      );
      loader.look(_at(17), _size);
      await _drain();
      await loader.refresh();
      await _drain();
      expect(server.boxes.length, greaterThan(read));
    },
  );

  test(
    'reads everything again when there is more edited than it will follow',
    () async {
      final server = _Api();
      final cache = await fill(server);
      final read = server.boxes.length;
      server.tooManyEdits = true;

      final loader = MapLoader(
        client: OsmApiClient(fetch: server.fetch),
        cache: cache,
        onChanged: () {},
      );
      loader.look(_at(17), _size);
      await _drain();
      await loader.refresh();
      await _drain();
      expect(server.boxes.length, greaterThan(read));
    },
  );

  test('loses an element that has been deleted since', () async {
    final server = _Api();
    final cache = await fill(server);
    server.edits = const [
      OsmBounds(
        minLatitude: -90,
        minLongitude: -180,
        maxLatitude: 90,
        maxLongitude: 180,
      ),
    ];

    final loader = MapLoader(
      client: OsmApiClient(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(17), _size);
    await _drain();
    expect(loader.store.nodes.containsKey(10), isTrue);

    // The first box no longer holds its first node.
    server.deleted = const {10};
    await loader.refresh();
    await _drain();
    expect(loader.store.nodes.containsKey(10), isFalse);
  });
}
