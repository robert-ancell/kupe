import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/account/account.dart';
import 'package:kupe/src/map/camera.dart';
import 'package:kupe/src/map/map_view.dart';
import 'package:kupe/src/map/pick.dart';
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

/// Two roads running east to west, one a little south of the other, so that
/// there is something to add to a selection and something to take out.
Future<Uint8List?> _twoRoads(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async {
  final box = uri.queryParameters['bbox']!
      .split(',')
      .map(double.parse)
      .toList();
  final [west, south, east, north] = box;
  final roads = StringBuffer('<osm version="0.6">');
  for (final (index, road) in [
    (0, (latitude: _roadLatitude, name: 'First Road')),
    (1, (latitude: _roadLatitude - 0.0004, name: 'Second Road')),
  ]) {
    if (road.latitude < south || road.latitude > north) continue;
    final id = (_served += 10) + index;
    roads.write(
      '<node id="$id" lat="${road.latitude}" lon="$west" version="1"/>'
      '<node id="${id + 1}" lat="${road.latitude}" lon="$east" version="1"/>'
      '<way id="${id + 2}" version="1">'
      '<nd ref="$id"/><nd ref="${id + 1}"/>'
      '<tag k="highway" v="residential"/>'
      '<tag k="name" v="${road.name}"/></way>',
    );
  }
  roads.write('</osm>');
  return Uint8List.fromList(utf8.encode(roads.toString()));
}

/// A short road of three nodes, all of them on screen at zoom 18, so that
/// its ends and its middle can each be pointed at.
Future<Uint8List?> _shortRoad(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
}) async {
  final box = uri.queryParameters['bbox']!
      .split(',')
      .map(double.parse)
      .toList();
  final south = box[1];
  final north = box[3];
  if (_roadLatitude < south || _roadLatitude > north) {
    return Uint8List.fromList(utf8.encode('<osm version="0.6"/>'));
  }
  final id = (_served += 10);
  final nodes = StringBuffer();
  for (var i = 0; i < 3; i++) {
    nodes.write(
      '<node id="${id + i}" lat="$_roadLatitude" '
      'lon="${174.76 - 0.0005 + i * 0.0005}" version="1"/>',
    );
  }
  return Uint8List.fromList(
    utf8.encode(
      '<osm version="0.6">$nodes'
      '<way id="${id + 5}" version="1">'
      '<nd ref="$id"/><nd ref="${id + 1}"/><nd ref="${id + 2}"/>'
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

/// A click, with real time afterwards so that the next one is a click of its
/// own rather than the second half of a double click.
Future<void> _click(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.runAsync(
    () => Future<void>.delayed(
      doubleClickWait + const Duration(milliseconds: 20),
    ),
  );
  await tester.pump();
}

/// Undoes the last change.
Future<void> _undo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Two clicks in the same place, quickly.
Future<void> _doubleClick(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump();
  await tester.tapAt(at);
  await tester.pump();
}

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
  // A click is not known to be a single click until the wait for a second
  // one has passed, and a test that ends inside that wait is a test with a
  // timer still running.
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
      expect(_painterIn(tester).highlight!.tags['highway'], 'residential');
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

  group('selecting', () {
    Future<void> openOver(WidgetTester tester, {double zoom = 18}) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              api: OsmApi(fetch: _twoRoads),
              initialCamera: Camera.at(
                latitude: _roadLatitude,
                longitude: 174.76,
                zoom: zoom,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    /// Where the second road runs, a little south of the first.
    const other = Offset(500, 490);

    Future<void> shift(WidgetTester tester, Future<void> Function() act) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await act();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    testWidgets('selects the line that is clicked', (tester) async {
      await openOver(tester);
      expect(_painterIn(tester).selection, isEmpty);

      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.length, 1);
      expect(find.textContaining('Way '), findsOneWidget);
    });

    testWidgets('shows what the line is tagged with', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      expect(find.text('highway = residential'), findsOneWidget);
      expect(find.text('name = First Road'), findsOneWidget);
    });

    testWidgets('selects one line at a time without shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await _click(tester, other);
      expect(_painterIn(tester).selection.length, 1);
      expect(find.text('name = Second Road'), findsOneWidget);
    });

    testWidgets('adds to the selection with shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 2);
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('shows only what the selection shares', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      // Both are residential roads; only one of them is First Road.
      expect(find.text('highway = residential'), findsOneWidget);
      expect(find.text('name = First Road'), findsNothing);
    });

    testWidgets('takes out of the selection with shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 2);

      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 1);
      expect(find.text('name = First Road'), findsOneWidget);
    });

    testWidgets('clears the selection on clicking nothing', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection, isNotEmpty);

      await _click(tester, const Offset(500, 700));
      expect(_painterIn(tester).selection, isEmpty);
      expect(find.textContaining('Way '), findsNothing);
    });

    testWidgets('keeps the selection on a shift click at nothing', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(const Offset(500, 700)));
      expect(_painterIn(tester).selection.length, 1);
    });

    testWidgets('lets go of the selection when zoomed out', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection, isNotEmpty);

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 400),
          scrollDelta: Offset(0, 800),
        ),
      );
      await tester.pump();
      expect(_painterIn(tester).selection, isEmpty);
    });
  });

  group('selecting nodes', () {
    /// A road of three nodes: its ends 93 pixels either side of the middle
    /// of the view, and a node in the middle of the line at the centre.
    Future<void> openOver(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              api: OsmApi(fetch: _shortRoad),
              initialCamera: Camera.at(
                latitude: _roadLatitude,
                longitude: 174.76,
                zoom: 18,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    Offset endOfRoad(WidgetTester tester) {
      final way =
          _painterIn(tester).selection.whereType<PickedWay>().firstOrNull ??
          _painterIn(tester).highlight as PickedWay;
      return _painterIn(tester).camera.toScreen(
        way.points[0],
        way.points[1],
        tester.getSize(find.byType(MapView)),
      );
    }

    testWidgets('takes the line, not a node along the middle of it', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedWay>());
      expect(find.textContaining('Way '), findsOneWidget);
    });

    testWidgets('takes the node a line ends at', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      final end = endOfRoad(tester);

      await _click(tester, end);
      final picked = _painterIn(tester).selection.single;
      expect(picked, isA<PickedNode>());
      expect(find.text('Node ${picked.id}'), findsOneWidget);
    });

    testWidgets('takes a node along the middle once the line is taken', (
      tester,
    ) async {
      await openOver(tester);
      // Nothing selected: the middle of the line gives the line.
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedWay>());

      // Selected: the same place now gives the node on it.
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
    });

    testWidgets('takes the line again once the node is let go of', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());

      // With only the node selected, its line is not, so the nodes along
      // the middle of it are out of reach again and the same place gives
      // the line back.
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedWay>());
    });
  });

  group('dragging a node', () {
    Future<void> openOver(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              api: OsmApi(fetch: _shortRoad),
              initialCamera: Camera.at(
                latitude: _roadLatitude,
                longitude: 174.76,
                zoom: 18,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    /// Where the road ends, which is always there to take hold of.
    Offset endOfRoad(WidgetTester tester) {
      final way =
          _painterIn(tester).selection.whereType<PickedWay>().firstOrNull ??
          _painterIn(tester).highlight as PickedWay;
      return _painterIn(tester).camera.toScreen(
        way.points[0],
        way.points[1],
        tester.getSize(find.byType(MapView)),
      );
    }

    testWidgets('moves the node the drag started on', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      final end = endOfRoad(tester);
      expect(_painterIn(tester).edited.isEmpty, isTrue);

      await tester.dragFrom(end, const Offset(40, 30));
      await tester.pump();

      final edited = _painterIn(tester).edited;
      expect(edited.nodes.length, 1);
      expect(edited.ways, isNotEmpty, reason: 'the road moves with it');
    });

    testWidgets('moves the map when the drag starts on nothing', (
      tester,
    ) async {
      await openOver(tester);
      final before = _painterIn(tester).camera;

      await tester.dragFrom(const Offset(500, 700), const Offset(40, 30));
      await tester.pump();

      expect(_painterIn(tester).camera, isNot(before));
      expect(_painterIn(tester).edited.isEmpty, isTrue);
    });

    testWidgets('counts a drag as one change', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      final end = endOfRoad(tester);

      await tester.dragFrom(end, const Offset(40, 30));
      await tester.pump();
      expect(find.text('1 change, ctrl+z to undo'), findsOneWidget);
    });

    testWidgets('puts the node back when the change is undone', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await tester.dragFrom(endOfRoad(tester), const Offset(40, 30));
      await tester.pump();
      expect(_painterIn(tester).edited.isEmpty, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(_painterIn(tester).edited.isEmpty, isTrue);
      expect(find.textContaining('ctrl+z'), findsNothing);
    });

    testWidgets('leaves nothing behind where the node started', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      final end = endOfRoad(tester);

      // Take hold of the node, so that it is both selected and pointed at,
      // and move it without letting go.
      final drag = await tester.startGesture(end);
      await drag.moveBy(const Offset(60, 40));
      await tester.pump();

      final painter = _painterIn(tester);
      final size = tester.getSize(find.byType(MapView));
      final moved = painter.edited.nodes.single;
      final where = painter.camera.toScreen(moved.$1, moved.$2, size);

      // Whatever is drawn picked out is drawn where the node is now, not
      // where it was when it was picked.
      for (final picked in [...painter.selection, painter.highlight]) {
        if (picked is PickedNode) {
          final at = painter.camera.toScreen(
            picked.worldX,
            picked.worldY,
            size,
          );
          expect((at - where).distance, lessThan(1));
        }
        if (picked is PickedWay) {
          final near = [
            for (var i = 0; i + 1 < picked.points.length; i += 2)
              (painter.camera.toScreen(
                        picked.points[i],
                        picked.points[i + 1],
                        size,
                      ) -
                      where)
                  .distance,
          ].reduce((a, b) => a < b ? a : b);
          expect(near, lessThan(1), reason: 'the line follows its node');
        }
      }

      await drag.up();
      await tester.pump();
    });

    testWidgets('changes nothing while too far out to edit', (tester) async {
      await openOver(tester);
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 400),
          scrollDelta: Offset(0, 800),
        ),
      );
      await tester.pump();

      await tester.dragFrom(const Offset(500, 400), const Offset(40, 30));
      await tester.pump();
      expect(_painterIn(tester).edited.isEmpty, isTrue);
    });
  });

  group('editing', () {
    Future<void> openOver(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              api: OsmApi(fetch: _shortRoad),
              initialCamera: Camera.at(
                latitude: _roadLatitude,
                longitude: 174.76,
                zoom: 18,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('puts a node into the line on a double click', (tester) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(560, 400));

      // The node is made and taken hold of, and the line it went into is
      // drawn from what it is now.
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
      expect(find.textContaining('Node -'), findsOneWidget);
      expect(_painterIn(tester).edited.ways, isNotEmpty);
    });

    testWidgets('leaves the map alone on a double click at nothing', (
      tester,
    ) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(500, 700));
      expect(_painterIn(tester).edited.isEmpty, isTrue);
      expect(find.textContaining('change'), findsNothing);
    });

    testWidgets('takes a selected node off the map with delete', (
      tester,
    ) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(560, 400));
      final made = _painterIn(tester).selection.single;

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(_painterIn(tester).selection, isEmpty);
      expect(
        _painterIn(tester).edited.nodes.length,
        0,
        reason: 'node ${made.id} is gone',
      );
    });

    testWidgets('takes hold of a line after deleting a node in it', (
      tester,
    ) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(560, 400));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(_painterIn(tester).selection, isEmpty);

      // The line is still there and can still be taken hold of.
      await _click(tester, const Offset(450, 400));
      expect(_painterIn(tester).selection.single, isA<PickedWay>());
    });

    testWidgets('offers a node and a line to add', (tester) async {
      await openOver(tester);
      expect(find.text('Node 1'), findsOneWidget);
      expect(find.text('Line 2'), findsOneWidget);
    });

    testWidgets('puts a node down and takes hold of it', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Node 1'));
      await tester.pump();

      await _click(tester, const Offset(600, 500));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
      expect(find.textContaining('Node -'), findsOneWidget);
      // And the tool is put down again after one use.
      expect(find.text('1 change, ctrl+z to undo'), findsOneWidget);
    });

    testWidgets('draws a line a click at a time', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Line 2'));
      await tester.pump();

      await _click(tester, const Offset(300, 300));
      expect(_painterIn(tester).edited.ways, isEmpty, reason: 'one point');

      await _click(tester, const Offset(400, 350));
      expect(_painterIn(tester).edited.ways, isNotEmpty);

      await _click(tester, const Offset(500, 300));
      expect(_painterIn(tester).edited.ways.single.points.length, 6);
    });

    testWidgets('finishes a line with enter', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Line 2'));
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(_painterIn(tester).selection.single, isA<PickedWay>());
      expect(find.textContaining('Way -'), findsOneWidget);
    });

    testWidgets('gives up on a line with escape', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Line 2'));
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_painterIn(tester).selection, isEmpty);
      expect(
        _painterIn(tester).edited.ways.where((w) => w.way.id < 0),
        isEmpty,
      );
    });

    testWidgets('finishes a line by clicking its last point', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Line 2'));
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));
      await _click(tester, const Offset(400, 350));

      expect(_painterIn(tester).selection.single, isA<PickedWay>());
    });

    testWidgets('takes hold of a node just put down', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Node 1'));
      await tester.pump();
      await _click(tester, const Offset(600, 500));
      await _click(tester, const Offset(300, 200));
      expect(_painterIn(tester).selection, isEmpty, reason: 'clicked away');

      // And it can be taken hold of again, though it is in no box.
      await _click(tester, const Offset(600, 500));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
    });

    testWidgets('takes hold of a line just drawn', (tester) async {
      await openOver(tester);
      await tester.tap(find.text('Line 2'));
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(600, 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await _click(tester, const Offset(200, 600));
      expect(_painterIn(tester).selection, isEmpty, reason: 'clicked away');

      await _click(tester, const Offset(450, 300));
      expect(_painterIn(tester).selection.single, isA<PickedWay>());
      expect(find.textContaining('Way -'), findsOneWidget);
    });

    testWidgets('takes a tool up and puts it down with a number', (
      tester,
    ) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      await _click(tester, const Offset(600, 500));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));
      expect(_painterIn(tester).edited.ways, isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('draws a closed line with the third tool', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(500, 300));
      await _click(tester, const Offset(400, 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final picked = _painterIn(tester).selection.single as PickedWay;
      expect(picked.way.isClosed, isTrue);
      expect(picked.way.nodeIds.length, 4, reason: 'three points and back');
      expect(picked.way.nodeIds.first, picked.way.nodeIds.last);
    });

    testWidgets('closes a line by clicking where it started', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(500, 300));
      await _click(tester, const Offset(400, 500));
      await _click(tester, const Offset(300, 300));

      final picked = _painterIn(tester).selection.single as PickedWay;
      expect(picked.way.isClosed, isTrue);
    });

    testWidgets('undoes a finished line as a line', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));
      await _click(tester, const Offset(500, 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_painterIn(tester).selection.single, isA<PickedWay>());

      await _undo(tester);
      // All of it, not its last point.
      expect(_painterIn(tester).edited.ways, isEmpty);
      expect(_painterIn(tester).edited.nodes, isEmpty);
      expect(find.textContaining('change'), findsNothing);
    });

    testWidgets('undoes the last point while still drawing', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));
      await _click(tester, const Offset(500, 300));
      expect(_painterIn(tester).edited.ways.single.points.length, 6);

      await _undo(tester);
      expect(_painterIn(tester).edited.ways.single.points.length, 4);

      // And the line can go on from there.
      await _click(tester, const Offset(600, 400));
      expect(_painterIn(tester).edited.ways.single.points.length, 6);
    });

    testWidgets('leaves nothing behind when a line is given up on', (
      tester,
    ) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(400, 350));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_painterIn(tester).edited.isEmpty, isTrue);
      expect(find.textContaining('change'), findsNothing);
    });

    testWidgets('follows the pointer from the second point onwards', (
      tester,
    ) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(350, 320));
      await tester.pump();
      expect(_painterIn(tester).ghost, isEmpty, reason: 'nothing put down');

      await _click(tester, const Offset(300, 300));
      await mouse.moveTo(const Offset(420, 360));
      await tester.pump();

      final ghost = _painterIn(tester).ghost;
      expect(ghost.length, 4);
      final size = tester.getSize(find.byType(MapView));
      final from = _painterIn(tester).camera.toScreen(ghost[0], ghost[1], size);
      final to = _painterIn(tester).camera.toScreen(ghost[2], ghost[3], size);
      expect((from - const Offset(300, 300)).distance, lessThan(1));
      expect((to - const Offset(420, 360)).distance, lessThan(1));
    });

    testWidgets('stops following once the line is finished', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      await _click(tester, const Offset(300, 300));
      await mouse.moveTo(const Offset(420, 360));
      await tester.pump();
      expect(_painterIn(tester).ghost, isNotEmpty);

      await _click(tester, const Offset(500, 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_painterIn(tester).ghost, isEmpty);
    });

    testWidgets('ghosts the closing line of a shape', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      await _click(tester, const Offset(300, 300));
      await mouse.moveTo(const Offset(500, 320));
      await tester.pump();
      // One line: there is nothing to close back to yet.
      expect(_painterIn(tester).ghost.length, 4);

      await _click(tester, const Offset(500, 300));
      await mouse.moveTo(const Offset(420, 500));
      await tester.pump();

      // Two: out to the pointer, and back to where the shape started.
      final ghost = _painterIn(tester).ghost;
      expect(ghost.length, 8);
      final size = tester.getSize(find.byType(MapView));
      final back = _painterIn(tester).camera.toScreen(ghost[6], ghost[7], size);
      expect((back - const Offset(300, 300)).distance, lessThan(1));
    });

    testWidgets('leaves a line unclosed while it is drawn', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(500, 300));
      await mouse.moveTo(const Offset(420, 500));
      await tester.pump();
      expect(_painterIn(tester).ghost.length, 4, reason: 'no closing line');
    });

    testWidgets('shows where a node would go before one is put down', (
      tester,
    ) async {
      await openOver(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(420, 360));
      await tester.pump();
      expect(_painterIn(tester).ghostNode, isNull, reason: 'no tool in hand');

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      await mouse.moveTo(const Offset(430, 370));
      await tester.pump();

      final ghost = _painterIn(tester).ghostNode;
      expect(ghost, isNotNull);
      final size = tester.getSize(find.byType(MapView));
      final at = _painterIn(tester).camera.toScreen(ghost!.$1, ghost.$2, size);
      expect((at - const Offset(430, 370)).distance, lessThan(1));
    });

    testWidgets('shows where the first point of a line would go', (
      tester,
    ) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(430, 370));
      await tester.pump();

      expect(_painterIn(tester).ghostNode, isNotNull);
      expect(_painterIn(tester).ghost, isEmpty, reason: 'nothing to join to');
    });

    testWidgets('stops showing one when the tool is put down', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(430, 370));
      await tester.pump();
      expect(_painterIn(tester).ghostNode, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(_painterIn(tester).ghostNode, isNull);
    });

    testWidgets('leaves a shape open while it is being drawn', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(500, 300));
      await _click(tester, const Offset(400, 500));

      // Three points, drawn as three: the line back to the first is the one
      // that would be drawn, and it is shown as such.
      final drawn = _painterIn(tester).edited.ways.single;
      expect(drawn.points.length, 6);
      expect(drawn.way.isClosed, isFalse);
    });

    testWidgets('closes the shape once it is finished', (tester) async {
      await openOver(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      await _click(tester, const Offset(300, 300));
      await _click(tester, const Offset(500, 300));
      await _click(tester, const Offset(400, 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final drawn = _painterIn(tester).edited.ways.single;
      expect(drawn.way.isClosed, isTrue);
      expect(drawn.points.length, 8, reason: 'back to where it started');
    });

    testWidgets('lets go of a node the moment it is deleted', (tester) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(560, 400));
      final made = _painterIn(tester).selection.single;

      // Point at it, so that it is both selected and highlighted.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      final size = tester.getSize(find.byType(MapView));
      final at = _painterIn(tester).camera
          .toScreen((made as PickedNode).worldX, made.worldY, size);
      await mouse.moveTo(at);
      await tester.pump();
      expect(_painterIn(tester).highlight, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      // Without moving the pointer, the node that has gone is no longer
      // what is pointed at. Whatever was under it may well be.
      final now = _painterIn(tester).highlight;
      expect(now is PickedNode && now.id == made.id, isFalse);
      expect(_painterIn(tester).selection, isEmpty);
    });

    testWidgets('shortens the line it was pointing at', (tester) async {
      await openOver(tester);
      await _doubleClick(tester, const Offset(560, 400));
      final made = _painterIn(tester).selection.single as PickedNode;

      // Point at the line rather than the node, and take the node out.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(480, 400));
      await tester.pump();
      final before =
          (_painterIn(tester).highlight as PickedWay?)?.points.length;
      expect(before, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      final after = (_painterIn(tester).highlight as PickedWay?)?.points.length;
      expect(after, isNot(before), reason: 'node ${made.id} is out of it');
    });
  });

  group('signing in', () {
    /// The map, signing in however [signIn] says to.
    Future<void> open(
      WidgetTester tester,
      Future<Account> Function(Account account, Future<void> cancel) signIn,
    ) async {
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
              signIn: signIn,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    const signedIn = Account(
      token: 'a-token',
      user: 'Somebody',
      scopes: {'write_api', 'read_prefs'},
    );

    testWidgets('goes straight to the browser and says it is waiting', (
      tester,
    ) async {
      final browser = Completer<Account>();
      var asked = 0;
      await open(tester, (_, _) {
        asked++;
        return browser.future;
      });
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      expect(asked, 1);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Waiting for the browser…'), findsOneWidget);

      browser.complete(signedIn);
      await tester.pump();
      await tester.pump();
      expect(find.text('Somebody'), findsOneWidget);
      expect(find.text('Waiting for the browser…'), findsNothing);
    });

    testWidgets('gives up when cancelled, and says nothing about it', (
      tester,
    ) async {
      var cancelled = false;
      await open(tester, (_, cancel) async {
        await cancel;
        cancelled = true;
        throw const OsmSignInCancelledException();
      });
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cancel-sign-in')));
      await tester.pump();
      await tester.pump();
      expect(cancelled, isTrue);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
      // Whoever cancelled knows they did; a line saying so is noise.
      expect(find.textContaining('cancelled'), findsNothing);
    });

    testWidgets('says why when it does not work', (tester) async {
      await open(
        tester,
        (_, _) async =>
            throw const OsmSignInException('The browser never came back.'),
      );
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('never came back'), findsOneWidget);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
    });

    testWidgets('carries on to the upload once signed in', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(tester, (_, _) async => signedIn);
      // Something to upload: a node put down with the node tool.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      await _click(tester, const Offset(420, 360));

      await tester.tap(find.text('Upload 1'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      // Straight on to what was asked for, rather than back to the map to
      // press the button a second time.
      expect(find.byKey(const Key('comment')), findsOneWidget);
    });

    testWidgets('signs out from the account button', (tester) async {
      await open(tester, (_, _) async => signedIn);
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      expect(find.text('Somebody'), findsNothing);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
    });
  });
}
