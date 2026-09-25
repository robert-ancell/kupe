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
          client: OsmApiClient(fetch: _nothing),
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

/// The tags of what is selected, as the text box shows them.
String _tagText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('tags'))).controller!.text;

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
            client: OsmApiClient(fetch: _nothing),
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
              client: OsmApiClient(fetch: _oneRoad),
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
              client: OsmApiClient(fetch: _twoRoads),
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
      expect(_tagText(tester), 'highway=residential\nname=First Road');
    });

    testWidgets('selects one line at a time without shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await _click(tester, other);
      expect(_painterIn(tester).selection.length, 1);
      expect(_tagText(tester), contains('name=Second Road'));
    });

    testWidgets('adds to the selection with shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 2);
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('shows what the selection disagrees on as a star', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      // Both are residential roads; only one of them is First Road.
      expect(_tagText(tester), 'highway=residential\nname=*');
    });

    testWidgets('takes out of the selection with shift', (tester) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 2);

      await shift(tester, () => tester.tapAt(other));
      expect(_painterIn(tester).selection.length, 1);
      expect(_tagText(tester), contains('name=First Road'));
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
              client: OsmApiClient(fetch: _shortRoad),
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
              client: OsmApiClient(fetch: _shortRoad),
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

    testWidgets('moves the node again when the change is redone', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, const Offset(500, 400));
      await tester.dragFrom(endOfRoad(tester), const Offset(40, 30));
      await tester.pump();
      await _undo(tester);
      expect(_painterIn(tester).edited.isEmpty, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_painterIn(tester).edited.isEmpty, isFalse);
      expect(find.text('1 change, ctrl+z to undo'), findsOneWidget);

      // Ctrl+Y as well, once there is something to redo again.
      await _undo(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_painterIn(tester).edited.isEmpty, isFalse);
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
              client: OsmApiClient(fetch: _shortRoad),
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

  group('editing tags', () {
    Future<void> openOver(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              client: OsmApiClient(fetch: _twoRoads),
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

    const first = Offset(500, 400);
    const second = Offset(500, 490);
    const nothing = Offset(500, 150);

    Future<void> selectBoth(WidgetTester tester) async {
      await _click(tester, first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(second);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_painterIn(tester).selection, hasLength(2));
    }

    /// The tags of each road, read back by selecting it on its own.
    Future<List<String>> eachRoad(WidgetTester tester) async {
      final out = <String>[];
      for (final at in [first, second]) {
        await _click(tester, at);
        out.add(_tagText(tester));
      }
      return out;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('tags')), text);
      await tester.pump();
    }

    testWidgets('applies an edit when the map is clicked', (tester) async {
      await openOver(tester);
      await _click(tester, first);
      await type(tester, 'highway=service\nname=First Road');
      // Clicking away clears the selection, and the edit has to have been
      // applied to what it was made to before that.
      await _click(tester, nothing);
      expect(_painterIn(tester).selection, isEmpty);
      expect(
        (await eachRoad(tester)).first,
        'highway=service\nname=First Road',
      );
    });

    testWidgets('applies an edit when zooming out takes the selection', (
      tester,
    ) async {
      // The wheel moves the map without taking the keyboard from the text,
      // so the text is never left; the editor is simply taken away.
      await openOver(tester);
      await _click(tester, first);
      await type(tester, 'highway=service\nname=First Road');
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(nothing));
      for (
        var i = 0;
        i < 20 && find.text('Zoom in to edit').evaluate().isEmpty;
        i++
      ) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 400)));
        await tester.pump();
      }
      expect(find.byKey(const Key('tags')), findsNothing);
      await tester.pump();
      expect(find.textContaining('Upload 1'), findsOneWidget);
    });

    testWidgets('applies an edit when escape leaves it', (tester) async {
      await openOver(tester);
      await _click(tester, first);
      await type(tester, 'highway=residential\nname=First Road\nlit=yes');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_painterIn(tester).selection.single.tags['lit'], 'yes');
      // Still selected: escape left the text, not the selection.
      expect(_painterIn(tester).selection, hasLength(1));
    });

    testWidgets('adds a tag to everything selected and keeps what differs', (
      tester,
    ) async {
      await openOver(tester);
      await selectBoth(tester);
      await type(tester, 'highway=residential\nname=*\nlit=yes');
      await _click(tester, nothing);
      expect(await eachRoad(tester), [
        'highway=residential\nlit=yes\nname=First Road',
        'highway=residential\nlit=yes\nname=Second Road',
      ]);
    });

    testWidgets('renames a key on everything, keeping each value', (
      tester,
    ) async {
      await openOver(tester);
      await selectBoth(tester);
      await type(tester, 'highway=residential\nold_name=*');
      await _click(tester, nothing);
      expect(await eachRoad(tester), [
        'highway=residential\nold_name=First Road',
        'highway=residential\nold_name=Second Road',
      ]);
    });

    testWidgets('takes a tag off everything', (tester) async {
      await openOver(tester);
      await selectBoth(tester);
      await type(tester, 'highway=residential');
      await _click(tester, nothing);
      expect(await eachRoad(tester), [
        'highway=residential',
        'highway=residential',
      ]);
    });

    testWidgets('undoes one edit of several elements at once', (tester) async {
      await openOver(tester);
      await selectBoth(tester);
      await type(tester, 'highway=service\nname=*');
      await _click(tester, nothing);
      await _undo(tester);
      expect(await eachRoad(tester), [
        'highway=residential\nname=First Road',
        'highway=residential\nname=Second Road',
      ]);
    });

    testWidgets('shows the tags as they are after an undo', (tester) async {
      await openOver(tester);
      await _click(tester, first);
      await type(tester, 'highway=service\nname=First Road');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await _undo(tester);
      expect(_tagText(tester), 'highway=residential\nname=First Road');
    });

    testWidgets('keeps the keys of the map out of the text', (tester) async {
      await openOver(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: nothing);

      await _click(tester, first);
      await tester.tap(find.byKey(const Key('tags')));
      await tester.pump();
      // A 1 is text here, not the node tool, and backspace is text too.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_painterIn(tester).selection, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await mouse.moveTo(nothing + const Offset(10, 0));
      await tester.pump();
      expect(_painterIn(tester).ghostNode, isNull, reason: 'no tool taken up');
    });
  });

  group('doing things to what is selected', () {
    /// The short road, from the one box it runs through the middle of.
    ///
    /// Every box across its latitude answers with a copy of it otherwise,
    /// each with ids of its own, which leaves two roads in one place: one
    /// deleted leaves the other there to be found.
    Future<Uint8List?> oneRoad(
      Uri uri, {
      Future<void>? abandon,
      void Function(Uint8List body)? onLate,
    }) async {
      final [west, _, east, _] = uri.queryParameters['bbox']!
          .split(',')
          .map(double.parse)
          .toList();
      if (174.76 < west || 174.76 >= east) {
        return Uint8List.fromList(utf8.encode('<osm version="0.6"/>'));
      }
      return _shortRoad(uri);
    }

    Future<void> openOver(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              client: OsmApiClient(fetch: oneRoad),
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

    /// Along the road, away from its nodes, and one of its ends.
    const road = Offset(450, 400);
    const end = Offset(407, 400);

    Future<void> rightClick(WidgetTester tester, Offset at) async {
      await tester.tapAt(
        at,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    OsmWay selectedWay(WidgetTester tester) =>
        (_painterIn(tester).selection.single as PickedWay).way;

    testWidgets('offers what can be done to what is right clicked', (
      tester,
    ) async {
      await openOver(tester);
      await rightClick(tester, road);
      // Selected first, so that what is offered is for it.
      expect(_painterIn(tester).selection.single, isA<PickedWay>());
      expect(find.text('Reverse'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // Nothing that does not apply to a line.
      expect(find.text('Extract'), findsNothing);
      expect(find.text('Continue'), findsNothing);
    });

    testWidgets('does what is chosen from the menu', (tester) async {
      await openOver(tester);
      await rightClick(tester, road);
      final deleted = selectedWay(tester).id;
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(_painterIn(tester).selection, isEmpty);
      // Nothing left there to point at, and nothing that was it.
      await _click(tester, road);
      expect(
        _painterIn(tester).selection.map((picked) => picked.id),
        isNot(contains(deleted)),
      );
    });

    testWidgets('offers nothing, and lets go, for nothing right clicked', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, road);
      await rightClick(tester, const Offset(500, 700));
      expect(_painterIn(tester).selection, isEmpty);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('does it by its key as well', (tester) async {
      await openOver(tester);
      await _click(tester, road);
      final before = selectedWay(tester).nodeIds;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(selectedWay(tester).nodeIds, before.reversed.toList());
    });

    testWidgets('moves what is selected with the pointer, as one change', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, road);
      final before = selectedWay(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: road);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      await mouse.moveTo(road + const Offset(0, 60));
      await tester.pump();
      // Put down where the pointer is.
      await _click(tester, road + const Offset(0, 60));

      final after = selectedWay(tester);
      final points = _painterIn(tester).selection.single as PickedWay;
      final camera = _painterIn(tester).camera;
      final size = tester.getSize(find.byType(MapView));
      final start = camera.toScreen(points.points[0], points.points[1], size);
      expect(start.dy, closeTo(460, 1));
      expect(after.nodeIds, before.nodeIds);

      await _undo(tester);
      final back = _painterIn(tester).selection.single as PickedWay;
      expect(
        camera.toScreen(back.points[0], back.points[1], size).dy,
        closeTo(400, 1),
      );
    });

    testWidgets('puts back what was being moved on escape', (tester) async {
      await openOver(tester);
      await _click(tester, road);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: road);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      await mouse.moveTo(road + const Offset(0, 60));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('Upload'), findsNothing);
    });

    testWidgets('pastes a copy where the menu is opened', (tester) async {
      await openOver(tester);
      await rightClick(tester, road);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      // Nothing is selected where nothing is, and pasting is what there is.
      await rightClick(tester, const Offset(450, 600));
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();

      final pasted = selectedWay(tester);
      expect(pasted.id, isNegative);
      expect(pasted.nodeIds, hasLength(3));
      expect(pasted.tags, {'highway': 'residential'});
      final picked = _painterIn(tester).selection.single as PickedWay;
      final size = tester.getSize(find.byType(MapView));
      final middle = _painterIn(tester).camera
          .toScreen(picked.points[2], picked.points[3], size);
      // Copied from a point on the road 50 left of its middle, pasted the
      // same way round the point it was pasted at.
      expect(middle.dx, closeTo(500, 1));
      expect(middle.dy, closeTo(600, 1));
    });

    testWidgets('splits a line where a node along it is selected', (
      tester,
    ) async {
      await openOver(tester);
      // Selecting the road is what makes the nodes along it selectable.
      await _click(tester, road);
      await _click(tester, const Offset(500, 400));
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      // The node and both pieces, ready to be disconnected.
      final selection = _painterIn(tester).selection;
      expect(selection.whereType<PickedNode>(), hasLength(1));
      final pieces = selection.whereType<PickedWay>().toList();
      expect(pieces, hasLength(2));
      expect(pieces.map((p) => p.way.nodeIds.length), everyElement(2));
    });

    testWidgets('carries a line on from its end, as one change', (
      tester,
    ) async {
      await openOver(tester);
      await _click(tester, end);
      expect(_painterIn(tester).selection.single, isA<PickedNode>());
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      await _click(tester, const Offset(330, 400));
      await _click(tester, const Offset(300, 460));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final line = selectedWay(tester);
      expect(line.id, isPositive, reason: 'the same line, not a new one');
      expect(line.nodeIds, hasLength(5));
      // Added at the end it was carried on from, which is its start.
      expect(line.nodeIds.take(2).every((id) => id < 0), isTrue);

      await _undo(tester);
      await _click(tester, road);
      expect(selectedWay(tester).nodeIds, hasLength(3));
    });
  });

  group('where it is', () {
    /// A road, and a kind of road only one country has.
    final presets = OsmPresets.parse(
      presets: jsonEncode({
        'line': {
          'tags': <String, String>{},
          'geometry': ['line'],
          'matchScore': 0.1,
        },
        'highway/residential': {
          'tags': {'highway': 'residential'},
          'geometry': ['line'],
          'locationSet': {
            'include': ['001'],
            'exclude': ['xa'],
          },
        },
        'highway/residential-XA': {
          'tags': {'highway': 'residential'},
          'geometry': ['line'],
          'locationSet': {
            'include': ['xa'],
          },
        },
      }),
      translations: jsonEncode({
        'en': {
          'presets': {
            'presets': {
              'line': {'name': 'Line'},
              'highway/residential': {'name': 'Residential Road'},
              'highway/residential-XA': {'name': 'Examplian Street'},
            },
          },
        },
      }),
    );

    /// A country taking in everywhere the map looks.
    final countries = OsmCountryCoder.parse(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'iso1A2': 'XA', 'nameEn': 'Examplia'},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [170, -40],
                  [180, -40],
                  [180, -30],
                  [170, -30],
                  [170, -40],
                ],
              ],
            },
          },
        ],
      }),
    );

    Future<void> openOver(WidgetTester tester, OsmCountryCoder? known) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapView(
              client: OsmApiClient(fetch: _twoRoads),
              initialCamera: Camera.at(
                latitude: _roadLatitude,
                longitude: 174.76,
                zoom: 18,
              ),
              presets: ValueNotifier(presets),
              countries: ValueNotifier(known),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('names things as they are named everywhere until it knows', (
      tester,
    ) async {
      await openOver(tester, null);
      await _click(tester, const Offset(500, 400));
      expect(find.text('Residential Road'), findsOneWidget);
    });

    testWidgets('names things as they are named in the country they are in', (
      tester,
    ) async {
      await openOver(tester, countries);
      await _click(tester, const Offset(500, 400));
      expect(find.text('Examplian Street'), findsOneWidget);
    });
  });

  group('buttons over the map', () {
    testWidgets('keep a drag that starts on them to themselves', (
      tester,
    ) async {
      await _open(tester);
      final before = _cameraLine(tester);
      await tester.dragFrom(
        tester.getCenter(find.text('Node 1')),
        const Offset(-200, 150),
      );
      await tester.pump();
      expect(_cameraLine(tester), before);
    });

    testWidgets('keep the scroll wheel to themselves', (tester) async {
      await _open(tester);
      final before = _cameraLine(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(tester.getCenter(find.text('Line 2'))),
      );
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      await tester.pump();
      expect(_cameraLine(tester), before);
    });

    testWidgets('still let the map be dragged beside them', (tester) async {
      // The other half: taking the pointer away from the map everywhere
      // would pass the test above too.
      await _open(tester);
      final before = _cameraLine(tester);
      await tester.dragFrom(const Offset(400, 400), const Offset(-200, 150));
      await tester.pump();
      expect(_cameraLine(tester), isNot(before));
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
              client: OsmApiClient(fetch: _nothing),
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
        throw const OsmAuthenticationCancelledException();
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
        (_, _) async => throw const OsmAuthenticationException(
          'The browser never came back.',
        ),
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
