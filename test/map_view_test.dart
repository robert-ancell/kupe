import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

/// Where the road the tests point at runs.
const _roadLatitude = -36.85;

var _served = 0;

/// A box of map data holding one road along [_roadLatitude], so that it runs
/// through the middle of a view looking there.
Future<Uint8List?> _oneRoad(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async {
  final box = uri.queryParameters['bbox']!
      .split(',')
      .map(double.parse)
      .toList();
  final [west, south, east, north] = box;
  if (_roadLatitude < south || _roadLatitude > north) {
    return Uint8List.fromList(utf8.encode('<osm version="0.6"/>'));
  }
  final id = (_served += 10);
  return Uint8List.fromList(
    utf8.encode(
      '<osm version="0.6">'
      '<node id="$id" lat="$_roadLatitude" lon="$west" version="1"/>'
      '<node id="${id + 1}" lat="$_roadLatitude" lon="$east" version="1"/>'
      '<way id="${id + 2}" version="1">'
      '<nd ref="$id"/><nd ref="${id + 1}"/>'
      '<tag k="highway" v="residential"/></way>'
      '</osm>',
    ),
  );
}

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
    // Real time, so that fetching and decoding get a chance.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    // And the clock the widget's own timers run on, which only moves when
    // the test says so.
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, {double zoom = 17}) async {
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
            zoom: zoom,
          ),
          imageryIndex: ValueNotifier(const OsmImageryIndex([_linz])),
          imageryFetch: _imagery,
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// What the map says it is showing, from the readout.
String _cameraLine(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? '')
    .firstWhere((line) => line.startsWith('Camera('));

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

  group('too far out to edit', () {
    testWidgets('says so when the map is zoomed out', (tester) async {
      await _open(tester, zoom: minimumEditZoom - 1);
      expect(find.text('Zoom in to edit'), findsOneWidget);
    });

    testWidgets('says nothing when the map is zoomed in', (tester) async {
      await _open(tester, zoom: minimumEditZoom);
      expect(find.text('Zoom in to edit'), findsNothing);
    });

    testWidgets('zooms in far enough to edit when pressed', (tester) async {
      await _open(tester, zoom: minimumEditZoom - 3);
      expect(_cameraLine(tester), contains('z13.00'));

      await tester.tap(find.text('Zoom in to edit'));
      await tester.pumpAndSettle();

      expect(_cameraLine(tester), contains('z16.00'));
      expect(find.text('Zoom in to edit'), findsNothing);
    });

    testWidgets('stays where it was looking while it zooms', (tester) async {
      await _open(tester, zoom: minimumEditZoom - 2);
      final before = _cameraLine(tester).split(',').take(2).join(',');

      await tester.tap(find.text('Zoom in to edit'));
      await tester.pumpAndSettle();

      // The same place on the ground, seen closer.
      expect(_cameraLine(tester), startsWith(before));
    });

    testWidgets('comes back when the map is zoomed out again', (tester) async {
      await _open(tester, zoom: minimumEditZoom + 1);
      expect(find.text('Zoom in to edit'), findsNothing);

      // Scrolling the wheel away zooms out, as it does on a desktop.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 400),
          scrollDelta: Offset(0, 600),
        ),
      );
      await tester.pump();
      expect(find.text('Zoom in to edit'), findsOneWidget);
    });
  });

  group('pointing at a line', () {
    Future<void> openOver(WidgetTester tester, {double zoom = 18}) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              api: OsmApi(fetch: _oneRoad),
              initialCamera: Camera.at(
                latitude: -36.85,
                longitude: 174.76,
                zoom: zoom,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    Future<void> point(WidgetTester tester, Offset at) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(at);
      await tester.pump();
    }

    testWidgets('highlights the line under the pointer', (tester) async {
      await openOver(tester);
      expect(_painterIn(tester).highlight, isNull);

      await point(tester, const Offset(500, 400));
      expect(_painterIn(tester).highlight, isNotNull);
      expect(_painterIn(tester).highlight!.way.tags['highway'], 'residential');
    });

    testWidgets('highlights nothing away from the line', (tester) async {
      await openOver(tester);
      await point(tester, const Offset(500, 700));
      expect(_painterIn(tester).highlight, isNull);
    });

    testWidgets('highlights nothing when too far out to edit', (tester) async {
      // The data is there, read at a closer zoom, but pointing at it does
      // nothing while the map says there is no editing to be done.
      await openOver(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(500, 400));
      await tester.pump();
      expect(_painterIn(tester).highlight, isNotNull);

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 400),
          scrollDelta: Offset(0, 800),
        ),
      );
      await tester.pump();
      await mouse.moveTo(const Offset(500, 401));
      await tester.pump();

      expect(find.text('Zoom in to edit'), findsOneWidget);
      expect(_painterIn(tester).highlight, isNull);
    });

    testWidgets('lets go of the line when the pointer leaves', (tester) async {
      await openOver(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(500, 400));
      await tester.pump();
      expect(_painterIn(tester).highlight, isNotNull);

      await mouse.moveTo(const Offset(-50, -50));
      await tester.pump();
      expect(_painterIn(tester).highlight, isNull);
    });
  });
}
