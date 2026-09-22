import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/imagery/imagery_cache.dart';
import 'package:kupe/src/imagery/imagery_layer.dart';
import 'package:kupe/src/imagery/imagery_source.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(512, 512);

const _source = ImagerySource(
  id: 'test',
  name: 'Test',
  url: 'https://example.test/{zoom}/{x}/{y}.webp',
  maximumZoom: 18,
  attribution: 'Test',
);

/// Stands in for a decoded picture, so nothing is drawn or decoded.
class _Picture {
  final String from;
  bool released = false;

  _Picture(this.from);
}

Future<void> _drain() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A tile server that answers at once unless told to hold on.
class _Server {
  final List<String> asked = [];

  /// Paths it has nothing for.
  final Set<String> empty = {};

  /// Whether to hold answers until [answerAll].
  bool hold = false;

  /// Whether a held answer had begun arriving before it was given up on.
  bool replyBegun = false;

  final _held = <(Uri, Completer<Uint8List?>, void Function(Uint8List)?)>[];

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) {
    asked.add(uri.path);
    if (empty.contains(uri.path)) return Future.value();
    final answer = Completer<Uint8List?>();
    abandon?.then((_) {
      if (!answer.isCompleted) {
        answer.completeError(const OsmAbandonedException());
      }
    });
    if (hold) {
      _held.add((uri, answer, onLate));
    } else {
      answer.complete(Uint8List.fromList(uri.path.codeUnits));
    }
    return answer.future;
  }

  void answerAll() {
    for (final (uri, answer, onLate) in _held) {
      final body = Uint8List.fromList(uri.path.codeUnits);
      if (!answer.isCompleted) {
        answer.complete(body);
      } else if (replyBegun) {
        onLate?.call(body);
      }
    }
    _held.clear();
  }
}

ImageryLayer<_Picture> _layer(
  _Server server, {
  int inFlight = 6,
  ImageryCache? cache,
}) => ImageryLayer<_Picture>(
  source: _source,
  fetch: server.fetch,
  decode: (bytes) async => _Picture(String.fromCharCodes(bytes)),
  release: (picture) => picture.released = true,
  onChanged: () {},
  cache: cache,
  inFlight: inFlight,
);

Camera _at(double zoom) =>
    Camera.at(latitude: -36.85, longitude: 174.76, zoom: zoom);

void main() {
  test('fills a tile into the address', () {
    expect(
      _source.tileUri(const TileId(17, 1, 2)).toString(),
      'https://example.test/17/1/2.webp',
    );
  });

  test('carries the LINZ entry iD uses', () {
    final uri = linzAerial.tileUri(const TileId(17, 129167, 79983));
    expect(uri.host, 'basemaps.linz.govt.nz');
    expect(uri.path, '/v1/tiles/aerial/WebMercatorQuad/17/129167/79983.webp');
    expect(uri.queryParameters['api'], isNotEmpty);
    expect(linzAerial.maximumZoom, 21);
    expect(linzAerial.attribution, contains('LINZ'));
  });

  test('draws tiles of the nearest zoom', () {
    final layer = _layer(_Server());
    expect(layer.zoomFor(_at(16.4)), 16);
    expect(layer.zoomFor(_at(16.6)), 17);
  });

  test('stretches the closest tiles past where the source ends', () {
    expect(_layer(_Server()).zoomFor(_at(21)), _source.maximumZoom);
  });

  test('asks only for the tiles on screen', () async {
    final server = _Server();
    final layer = _layer(server);
    final camera = _at(17);
    layer.look(camera, _size);
    await _drain();
    final wanted = camera.tilesFor(_size, 17);
    expect(server.asked.length, wanted.length);
    for (final tile in wanted) {
      expect(server.asked, contains('/17/${tile.x}/${tile.y}.webp'));
    }
  });

  test('asks for the middle of the view first', () async {
    final server = _Server()..hold = true;
    final layer = _layer(server, inFlight: 1);
    final camera = _at(17);
    layer.look(camera, _size);
    await _drain();
    final middle = TileId.of(17, camera.x, camera.y);
    expect(server.asked.single, '/17/${middle.x}/${middle.y}.webp');
  });

  test('does not ask twice for a tile it holds', () async {
    final server = _Server();
    final layer = _layer(server);
    layer.look(_at(17), _size);
    await _drain();
    final asked = server.asked.length;
    layer.look(_at(17), _size);
    await _drain();
    expect(server.asked.length, asked);
  });

  test('does not ask again where the source has nothing', () async {
    final server = _Server();
    final camera = _at(17);
    for (final tile in camera.tilesFor(_size, 17)) {
      server.empty.add('/17/${tile.x}/${tile.y}.webp');
    }
    final layer = _layer(server);
    layer.look(camera, _size);
    await _drain();
    final asked = server.asked.length;
    layer.look(camera, _size);
    await _drain();
    expect(server.asked.length, asked);
    expect(layer.piecesFor(camera, _size), isEmpty);
  });

  test('draws every tile on screen once they have arrived', () async {
    final layer = _layer(_Server());
    final camera = _at(17);
    layer.look(camera, _size);
    await _drain();
    final pieces = layer.piecesFor(camera, _size);
    expect(pieces.length, camera.tilesFor(_size, 17).length);
    for (final piece in pieces) {
      expect(piece.from, piece.tile);
    }
  });

  test('stands in a coarser tile until the right one comes', () async {
    final server = _Server();
    final layer = _layer(server);
    layer.look(_at(16), _size);
    await _drain();

    // Zoomed in, with nothing at the new zoom arrived yet.
    server.hold = true;
    final closer = _at(17);
    layer.look(closer, _size);
    final pieces = layer.piecesFor(closer, _size);
    expect(pieces, isNotEmpty);
    for (final piece in pieces) {
      expect(piece.from.zoom, 16);
      expect(piece.tile.parent, piece.from);
    }
  });

  test('gives up on tiles the map has moved off', () async {
    final server = _Server()..hold = true;
    final layer = _layer(server);
    layer.look(_at(17), _size);
    await _drain();
    expect(layer.reading, greaterThan(0));

    layer.look(Camera.at(latitude: 51.5, longitude: -0.12, zoom: 17), _size);
    await _drain();
    // Everything being read now is for the new view.
    final london = Camera.at(
      latitude: 51.5,
      longitude: -0.12,
      zoom: 17,
    ).tilesFor(_size, 17).length;
    expect(layer.reading, lessThanOrEqualTo(london));
    server.answerAll();
    await _drain();
    expect(layer.piecesFor(_at(17), _size), isEmpty);
  });

  test('keeps a tile that arrives after it was given up on', () async {
    final server = _Server()
      ..hold = true
      ..replyBegun = true;
    final layer = _layer(server);
    final auckland = _at(17);
    layer.look(auckland, _size);
    await _drain();
    layer.look(Camera.at(latitude: 51.5, longitude: -0.12, zoom: 17), _size);
    server.answerAll();
    await _drain();
    expect(layer.piecesFor(auckland, _size), isNotEmpty);
  });

  test('lets go of the tiles looked at longest ago', () async {
    final server = _Server();
    final pictures = <_Picture>[];
    final tracking = ImageryLayer<_Picture>(
      source: _source,
      fetch: server.fetch,
      decode: (bytes) async {
        final picture = _Picture(String.fromCharCodes(bytes));
        pictures.add(picture);
        return picture;
      },
      release: (picture) => picture.released = true,
      onChanged: () {},
    );
    // Walk east far enough to fetch more than can be held.
    for (var step = 0; step < 40; step++) {
      tracking.look(
        Camera.at(latitude: -36.85, longitude: 174.0 + step * 0.02, zoom: 17),
        _size,
      );
      await _drain();
    }
    expect(tracking.held, maximumImageryTiles);
    expect(
      pictures.where((p) => p.released).length,
      pictures.length - maximumImageryTiles,
    );
    tracking.dispose();
  });

  test('lets go of everything when thrown away', () async {
    final pictures = <_Picture>[];
    final layer = ImageryLayer<_Picture>(
      source: _source,
      fetch: _Server().fetch,
      decode: (bytes) async {
        final picture = _Picture(String.fromCharCodes(bytes));
        pictures.add(picture);
        return picture;
      },
      release: (picture) => picture.released = true,
      onChanged: () {},
    );
    layer.look(_at(17), _size);
    await _drain();
    expect(pictures, isNotEmpty);
    layer.dispose();
    expect(pictures.every((p) => p.released), isTrue);
    expect(layer.held, 0);
  });

  group('kept on disk', () {
    late Directory work;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('kupe_imagery_layer');
    });

    tearDown(() async {
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('keeps what it fetched for next time', () async {
      final cache = await ImageryCache.open(work);
      final server = _Server();
      _layer(server, cache: cache).look(_at(17), _size);
      await _drain();
      expect(cache.tiles.length, server.asked.length);
    });

    test('draws from disk without asking for anything', () async {
      final cache = await ImageryCache.open(work);
      final first = _Server();
      _layer(first, cache: cache).look(_at(17), _size);
      await _drain();
      expect(first.asked, isNotEmpty);

      final again = await ImageryCache.open(work);
      final second = _Server();
      final layer = _layer(second, cache: again);
      final camera = _at(17);
      layer.look(camera, _size);
      await _drain();
      expect(second.asked, isEmpty);
      expect(
        layer.piecesFor(camera, _size).length,
        camera.tilesFor(_size, 17).length,
      );
    });

    test('remembers empty ground between runs', () async {
      final cache = await ImageryCache.open(work);
      final camera = _at(17);
      final first = _Server();
      for (final tile in camera.tilesFor(_size, 17)) {
        first.empty.add('/17/${tile.x}/${tile.y}.webp');
      }
      _layer(first, cache: cache).look(camera, _size);
      await _drain();

      final again = await ImageryCache.open(work);
      final second = _Server();
      _layer(second, cache: again).look(camera, _size);
      await _drain();
      expect(second.asked, isEmpty);
    });

    test('draws an old tile while fetching a newer one', () async {
      final cache = await ImageryCache.open(work);
      final first = _Server();
      _layer(first, cache: cache).look(_at(17), _size);
      await _drain();

      // A week on, with the server holding its answers.
      final index = File('${work.path}/index.json');
      final long = DateTime.now()
          .subtract(imageryFreshness * 2)
          .millisecondsSinceEpoch;
      await index.writeAsString(
        (await index.readAsString()).replaceAll(
          RegExp(r'"at":\d+'),
          '"at":$long',
        ),
      );
      final aged = await ImageryCache.open(work);
      final second = _Server()..hold = true;
      final layer = _layer(second, cache: aged);
      final camera = _at(17);
      layer.look(camera, _size);
      await _drain();

      // What is held is drawn at once, and a newer one is on its way.
      expect(layer.piecesFor(camera, _size), isNotEmpty);
      expect(second.asked, isNotEmpty);
    });
  });
}
