import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/map/map_view.dart';
import 'package:kupe/src/render/map_painter.dart';
import 'package:osm/osm.dart';

const _linz = OsmImagery(
  id: 'LINZ',
  name: 'LINZ',
  url: 'https://linz.test/{zoom}/{x}/{y}.png',
  category: OsmImageryCategory.photo,
  maximumZoom: 21,
  best: true,
);

/// A picture, so that tiles really are decoded.
final _tileBody = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNoaGj4D8IM'
    'MAYAVvQJ/UtL6SwAAAAASUVORK5CYII=',
  ),
);

Future<Uint8List?> _imagery(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async => _tileBody;

Future<Uint8List?> _nothing(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async => null;

MapPainter _painterIn(WidgetTester tester) =>
    tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .firstWhere((paint) => paint.painter is MapPainter)
            .painter!
        as MapPainter;

/// Lets fetching and decoding actually happen, which the fake clock a widget
/// test runs on otherwise leaves hanging.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapView(
          api: OsmApi(fetch: _nothing),
          initialCamera: Camera.at(
            latitude: -36.85,
            longitude: 174.76,
            zoom: 17,
          ),
          imageryIndex: ValueNotifier(const OsmImageryIndex([_linz])),
          imageryFetch: _imagery,
        ),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('draws the imagery it has fetched', (tester) async {
    await _open(tester);
    expect(_painterIn(tester).imagery, isNotEmpty);
  });

  testWidgets('keeps the imagery on screen while panning', (tester) async {
    await _open(tester);
    final before = _painterIn(tester).imagery.length;
    expect(before, greaterThan(0));

    await tester.drag(find.byType(MapView), const Offset(-40, 0));
    await tester.pump();

    // Moving the map must not throw away what is already drawn. It once did,
    // and a slight pan emptied the background.
    expect(_painterIn(tester).imagery.length, before);
  });

  testWidgets('keeps the imagery through a long drag', (tester) async {
    await _open(tester);
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(MapView), const Offset(-60, -30));
      await tester.pump();
      expect(_painterIn(tester).imagery, isNotEmpty, reason: 'at drag $i');
    }
    await _settle(tester);
    expect(_painterIn(tester).imagery, isNotEmpty);
  });

  testWidgets('draws no imagery when there is no index', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapView(
            api: OsmApi(fetch: _nothing),
            initialCamera: Camera.at(
              latitude: -36.85,
              longitude: 174.76,
              zoom: 17,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(_painterIn(tester).imagery, isEmpty);
  });
}
