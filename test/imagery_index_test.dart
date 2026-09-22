import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kupe/src/imagery/imagery_index.dart';
import 'package:test/test.dart';

late Directory _work;
File get _file => File('${_work.path}/index.geojson');

const _index = '''
{"type": "FeatureCollection", "features": [
  {"type": "Feature", "properties": {"id": "A", "name": "A", "type": "tms",
    "category": "photo", "url": "https://a.test/{zoom}/{x}/{y}.png"},
   "geometry": null}
]}
''';

/// A server that hands out an index, or refuses to.
class _Server {
  int asked = 0;
  bool away = false;
  String body = _index;

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    asked++;
    if (away) throw const SocketException('nothing is listening');
    return Uint8List.fromList(utf8.encode(body));
  }
}

void main() {
  setUp(() async {
    _work = await Directory.systemTemp.createTemp('kupe_index_test');
  });

  tearDown(() async {
    if (_work.existsSync()) await _work.delete(recursive: true);
  });

  test('reads the index from the network the first time', () async {
    final server = _Server();
    final index = await ImageryIndex.read(file: _file, fetch: server.fetch);
    expect(server.asked, 1);
    expect(index.layers.single.id, 'A');
    expect(_file.existsSync(), isTrue);
  });

  test('uses the copy it kept rather than asking again', () async {
    final server = _Server();
    await ImageryIndex.read(file: _file, fetch: server.fetch);
    final again = await ImageryIndex.read(file: _file, fetch: server.fetch);
    expect(server.asked, 1);
    expect(again.layers.single.id, 'A');
  });

  test('asks again once its copy has aged', () async {
    final server = _Server();
    await ImageryIndex.read(file: _file, fetch: server.fetch);
    await _file.setLastModified(
      DateTime.now().subtract(imageryIndexFreshness * 2),
    );
    await ImageryIndex.read(file: _file, fetch: server.fetch);
    expect(server.asked, 2);
  });

  test('keeps an old copy when it cannot be reached', () async {
    final server = _Server();
    await ImageryIndex.read(file: _file, fetch: server.fetch);
    await _file.setLastModified(
      DateTime.now().subtract(imageryIndexFreshness * 2),
    );

    server.away = true;
    final index = await ImageryIndex.read(file: _file, fetch: server.fetch);
    // An old list beats no list.
    expect(index.layers.single.id, 'A');
  });

  test('falls back to the one layer built in with nothing else', () async {
    final index = await ImageryIndex.read(
      file: _file,
      fetch: (_Server()..away = true).fetch,
    );
    expect(index.layers.single.id, fallbackImagery.id);
  });

  test(
    'falls back rather than trusting something that is not an index',
    () async {
      final server = _Server()..body = 'not json';
      final index = await ImageryIndex.read(file: _file, fetch: server.fetch);
      expect(index.layers.single.id, fallbackImagery.id);
    },
  );

  test('falls back on an index holding nothing it can use', () async {
    final server = _Server()
      ..body = '{"type": "FeatureCollection", "features": []}';
    final index = await ImageryIndex.read(file: _file, fetch: server.fetch);
    expect(index.layers.single.id, fallbackImagery.id);
    // Nothing worth keeping was kept.
    expect(_file.existsSync(), isFalse);
  });

  test('ignores a kept copy that will not read', () async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString('half a fi');
    final server = _Server();
    final index = await ImageryIndex.read(file: _file, fetch: server.fetch);
    expect(server.asked, 1);
    expect(index.layers.single.id, 'A');
  });
}
