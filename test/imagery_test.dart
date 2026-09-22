import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:kupe/src/geometry/tile.dart';
import 'package:kupe/src/imagery/imagery_layer.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _size = Size(512, 512);

const _source = OsmImagery(
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

/// Lets everything queued run, including reads from the disk, which take
/// real time and take longer again when the whole suite is running at once.
Future<void> _drain() async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
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
  OsmImageryCache? cache,
}) => ImageryLayer<_Picture>(
  tiles: OsmImageryTiles(source: _source, fetch: server.fetch, cache: cache),
  decode: (bytes) async => _Picture(String.fromCharCodes(bytes)),
  release: (picture) => picture.released = true,
  onChanged: () {},
  inFlight: inFlight,
);

Camera _at(double zoom) =>
    Camera.at(latitude: -36.85, longitude: 174.76, zoom: zoom);

void main() {
  test('draws tiles of the nearest zoom', () {
    final layer = _layer(_Server());
    expect(layer.zoomFor(_at(16.4)), 16);
    expect(layer.zoomFor(_at(16.6)), 17);
  });

  test('stretches the closest tiles past where the source ends', () {
    expect(_layer(_Server()).zoomFor(_at(21)), _source.maximumZoom);
  });

  test('asks for the tiles on screen and the ring around them', () async {
    final server = _Server();
    final layer = _layer(server);
    final camera = _at(17);
    layer.look(camera, _size);
    await _drain();
    final wanted = camera.tilesFor(_size, 17, margin: imageryMargin);
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
      tiles: OsmImageryTiles(source: _source, fetch: server.fetch),
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
    expect(tracking.held, lessThanOrEqualTo(tracking.capacity));
    expect(tracking.held, greaterThan(0));
    expect(
      pictures.where((p) => p.released).length,
      pictures.length - tracking.held,
    );
    tracking.dispose();
  });

  test('lets go of everything when thrown away', () async {
    final pictures = <_Picture>[];
    final layer = ImageryLayer<_Picture>(
      tiles: OsmImageryTiles(source: _source, fetch: _Server().fetch),
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
      final cache = await OsmImageryCache.open(work);
      final server = _Server();
      _layer(server, cache: cache).look(_at(17), _size);
      await _drain();
      expect(cache.tiles.length, server.asked.length);
    });

    test('draws from disk without asking for anything', () async {
      final cache = await OsmImageryCache.open(work);
      final first = _Server();
      _layer(first, cache: cache).look(_at(17), _size);
      await _drain();
      expect(first.asked, isNotEmpty);

      final again = await OsmImageryCache.open(work);
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
      final cache = await OsmImageryCache.open(work);
      final camera = _at(17);
      final first = _Server();
      for (final tile in camera.tilesFor(_size, 17)) {
        first.empty.add('/17/${tile.x}/${tile.y}.webp');
      }
      _layer(first, cache: cache).look(camera, _size);
      await _drain();

      final again = await OsmImageryCache.open(work);
      final second = _Server();
      _layer(second, cache: again).look(camera, _size);
      await _drain();
      expect(second.asked, isEmpty);
    });

    test('draws an old tile while fetching a newer one', () async {
      final cache = await OsmImageryCache.open(work);
      final first = _Server();
      _layer(first, cache: cache).look(_at(17), _size);
      await _drain();

      // A week on, with the server holding its answers.
      final index = File('${work.path}/index.json');
      final long = DateTime.now()
          .subtract(osmImageryFreshness * 2)
          .millisecondsSinceEpoch;
      await index.writeAsString(
        (await index.readAsString()).replaceAll(
          RegExp(r'"at":\d+'),
          '"at":$long',
        ),
      );
      final aged = await OsmImageryCache.open(work);
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

  group('never goes blank', () {
    test('draws the coarser tiles it holds while zooming in', () async {
      final server = _Server();
      final layer = _layer(server);
      layer.look(_at(16), _size);
      await _drain();

      server.hold = true;
      final closer = _at(17);
      layer.look(closer, _size);
      final pieces = layer.piecesFor(closer, _size);
      expect(pieces.length, closer.tilesFor(_size, 17).length);
      for (final piece in pieces) {
        expect(piece.from.zoom, lessThan(piece.tile.zoom));
      }
    });

    test('draws the finer tiles it holds while zooming out', () async {
      // The other way round, and the one that was blank: zooming out leaves
      // what is held finer than what is wanted.
      final server = _Server();
      final layer = _layer(server);
      layer.look(_at(17), _size);
      await _drain();

      server.hold = true;
      final wider = _at(16);
      layer.look(wider, _size);
      final pieces = layer.piecesFor(wider, _size);
      expect(pieces, isNotEmpty);
      for (final piece in pieces) {
        expect(piece.from, piece.tile);
        expect(piece.tile.zoom, greaterThan(16));
      }
    });

    test('draws nothing for ground it has never held', () async {
      final server = _Server()..hold = true;
      final layer = _layer(server);
      final camera = _at(17);
      layer.look(camera, _size);
      expect(layer.piecesFor(camera, _size), isEmpty);
    });

    test('asks for a ring beyond the view', () async {
      final server = _Server();
      final layer = _layer(server);
      final camera = _at(17);
      layer.look(camera, _size);
      await _drain();
      // What is on screen, and a ring around it ready for the next drag.
      expect(
        server.asked.length,
        greaterThan(camera.tilesFor(_size, 17).length),
      );
      expect(
        server.asked.length,
        camera.tilesFor(_size, 17, margin: imageryMargin).length,
      );
    });

    test('keeps what it has drawn as the map is moved about', () async {
      final server = _Server();
      final layer = _layer(server);
      final start = _at(17);
      layer.look(start, _size);
      await _drain();
      final held = layer.held;

      for (final zoom in [17.6, 18.0, 17.0]) {
        layer.look(_at(zoom), _size);
        await _drain();
      }
      // Nothing is let go of on the way, so coming back is instant.
      expect(layer.held, greaterThanOrEqualTo(held));
      expect(
        layer.piecesFor(start, _size).length,
        start.tilesFor(_size, 17).length,
      );
    });

    test('draws every tile itself, however far the map is panned', () async {
      // Panning past what can be held has to throw something away, and what
      // it throws away must never be what is about to be drawn.
      final server = _Server();
      final layer = _layer(server);
      var released = 0;
      final tracking = ImageryLayer<_Picture>(
        tiles: OsmImageryTiles(source: _source, fetch: server.fetch),
        decode: (bytes) async => _Picture(String.fromCharCodes(bytes)),
        release: (picture) {
          picture.released = true;
          released++;
        },
        onChanged: () {},
      );
      for (var step = 0; step < 30; step++) {
        final camera = Camera.at(
          latitude: -36.85,
          longitude: 174.0 + step * 0.004,
          zoom: 17,
        );
        tracking.look(camera, _size);
        await _drain();
        final pieces = tracking.piecesFor(camera, _size);
        expect(
          pieces.where((piece) => piece.from == piece.tile).length,
          camera.tilesFor(_size, 17).length,
          reason: 'every tile drawn as itself at step $step',
        );
      }
      expect(released, greaterThan(0), reason: 'and something was let go of');
      expect(tracking.held, lessThanOrEqualTo(tracking.capacity));
      layer.dispose();
      tracking.dispose();
    });

    test('holds more for a larger view', () async {
      final small = _layer(_Server());
      small.look(_at(17), const Size(320, 480));
      final large = _layer(_Server());
      large.look(_at(17), const Size(2560, 1440));
      expect(large.capacity, greaterThan(small.capacity));
      expect(small.capacity, minimumImageryTiles);
    });
  });
}
