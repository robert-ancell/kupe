import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/data/map_loader.dart';
import 'package:kupe/src/data/tile_cache.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(400, 400);

Camera _at(double latitude, double longitude) =>
    Camera.at(latitude: latitude, longitude: longitude, zoom: 17);

Future<void> _drain() async {
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// An API that answers only when told to, and that honours being given up on
/// the way the real fetch does.
class _Held {
  /// The boxes asked for, in order.
  final List<OsmBounds> asked = [];

  /// The boxes given up on before they were answered.
  final List<OsmBounds> abandoned = [];

  /// Whether the server had begun replying by the time it was given up on,
  /// in which case the answer is kept rather than lost.
  bool replyBegun = false;

  final _waiting =
      <(OsmBounds, Completer<Uint8List?>, void Function(Uint8List)?)>[];

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) {
    final parts = uri.queryParameters['bbox']!.split(',').map(double.parse);
    final [west, south, east, north] = parts.toList();
    final bounds = OsmBounds(
      minLatitude: south,
      minLongitude: west,
      maxLatitude: north,
      maxLongitude: east,
    );
    asked.add(bounds);

    final answer = Completer<Uint8List?>();
    _waiting.add((bounds, answer, onLate));
    abandon?.then((_) {
      if (answer.isCompleted) return;
      abandoned.add(bounds);
      answer.completeError(const OsmAbandonedException());
    });
    return answer.future;
  }

  /// Answers everything held, late where it was already given up on.
  void answerAll() {
    for (final (bounds, answer, onLate) in [..._waiting]) {
      final body = _body(bounds);
      if (answer.isCompleted) {
        if (replyBegun) onLate?.call(body);
      } else {
        answer.complete(body);
      }
    }
    _waiting.clear();
  }

  static Uint8List _body(OsmBounds at) {
    final id = ((at.minLongitude + 180) * 100000).round();
    return Uint8List.fromList(
      utf8.encode(
        '<osm version="0.6">'
        '<node id="$id" lat="${at.minLatitude}" lon="${at.minLongitude}" '
        'version="1"/>'
        '<node id="${id + 1}" lat="${at.maxLatitude}" '
        'lon="${at.maxLongitude}" version="1"/>'
        '<way id="${id + 2}" version="1">'
        '<nd ref="$id"/><nd ref="${id + 1}"/>'
        '<tag k="highway" v="residential"/>'
        '</way>'
        '</osm>',
      ),
    );
  }
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('kupe_abandon_test');
  });

  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('gives up on boxes the map has moved off', () async {
    final server = _Held();
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      onChanged: () {},
    );
    loader.look(_at(-36.85, 174.76), _size);
    await _drain();
    expect(loader.reading, greaterThan(0));

    loader.look(_at(51.5, -0.12), _size);
    await _drain();
    expect(server.abandoned, isNotEmpty);
    loader.dispose();
  });

  test('keeps reading the boxes still on screen', () async {
    final server = _Held();
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      onChanged: () {},
    );
    final where = _at(-36.85, 174.76);
    loader.look(where, _size);
    await _drain();
    final reading = loader.reading;
    expect(reading, greaterThan(0));

    // Looking at the same place again gives up on nothing.
    loader.look(where, _size);
    await _drain();
    expect(server.abandoned, isEmpty);
    expect(loader.reading, reading);
    loader.dispose();
  });

  test('keeps an answer that arrives after it was given up on', () async {
    final cache = await TileCache.open(work);
    final server = _Held()..replyBegun = true;
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    loader.look(_at(-36.85, 174.76), _size);
    await _drain();

    loader.look(_at(51.5, -0.12), _size);
    await _drain();
    expect(server.abandoned, isNotEmpty);
    expect(cache.tiles, isEmpty, reason: 'nothing answered yet');

    // The server had already begun, so the answers still arrive.
    server.answerAll();
    await _drain();
    expect(cache.tiles, isNotEmpty);
    loader.dispose();
  });

  test('reads a kept box from disk rather than asking again', () async {
    final cache = await TileCache.open(work);
    final server = _Held()..replyBegun = true;
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      cache: cache,
      onChanged: () {},
    );
    final where = _at(-36.85, 174.76);
    loader.look(where, _size);
    await _drain();

    loader.look(_at(51.5, -0.12), _size);
    await _drain();
    server.answerAll();
    await _drain();

    final askedSoFar = server.asked.length;
    loader.look(where, _size);
    await _drain();

    // Everything kept comes off the disk; only what was never answered is
    // asked for again.
    expect(loader.tiles, isNotEmpty);
    expect(server.asked.length, lessThan(askedSoFar * 2));
    loader.dispose();
  });

  test('loses nothing when there is no cache to keep it in', () async {
    final server = _Held()..replyBegun = true;
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      onChanged: () {},
    );
    loader.look(_at(-36.85, 174.76), _size);
    await _drain();
    loader.look(_at(51.5, -0.12), _size);
    await _drain();
    server.answerAll();
    await _drain();
    // Nothing to keep it in, and nothing broken by that.
    expect(loader.stopped, isNull);
    loader.dispose();
  });

  test('gives up on everything when it is thrown away', () async {
    final server = _Held();
    final loader = MapLoader(
      api: OsmApi(fetch: server.fetch),
      onChanged: () {},
    );
    loader.look(_at(-36.85, 174.76), _size);
    await _drain();
    expect(loader.reading, greaterThan(0));

    loader.dispose();
    await _drain();
    expect(server.abandoned, isNotEmpty);
  });
}
