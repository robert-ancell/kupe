import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/map/tag_editor.dart';
import 'package:osm/osm.dart';

const _road = OsmWay(
  id: 1,
  nodeIds: [1, 2],
  tags: {'highway': 'residential', 'name': 'Queen Street'},
);

const _other = OsmWay(
  id: 2,
  nodeIds: [3, 4],
  tags: {'highway': 'residential', 'name': 'King Street'},
);

/// What the editor handed on, in the order it did.
final _applied = <List<(OsmElement, Map<String, String>)>>[];

Future<void> _show(WidgetTester tester, List<OsmElement> elements) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagEditor(elements: elements, onChanged: _applied.add),
        ),
      ),
    );

String _text(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _leave(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

void main() {
  setUp(_applied.clear);

  testWidgets('shows the tags as text', (tester) async {
    await _show(tester, const [_road]);
    expect(_text(tester), 'highway=residential\nname=Queen Street');
    expect(find.text('Way 1'), findsOneWidget);
  });

  testWidgets('applies an edit typed straight after it is shown', (
    tester,
  ) async {
    // Nothing is rebuilt between showing and typing, so the text as it was
    // shown has to have been kept from the start rather than the first time
    // it was wanted, which would be after the typing.
    await _show(tester, const [_road]);
    await tester.enterText(find.byType(TextField), 'highway=service');
    await _leave(tester);
    expect(_applied, hasLength(1));
    final (element, tags) = _applied.single.single;
    expect(element.id, 1);
    expect(tags, {'highway': 'service'});
  });

  testWidgets('applies nothing when nothing was changed', (tester) async {
    await _show(tester, const [_road]);
    await tester.showKeyboard(find.byType(TextField));
    await _leave(tester);
    expect(_applied, isEmpty);
  });

  testWidgets('waits for the text to be left before applying it', (
    tester,
  ) async {
    await _show(tester, const [_road]);
    await tester.enterText(find.byType(TextField), 'highway=service');
    await tester.pump();
    expect(_applied, isEmpty);
  });

  testWidgets('applies an edit on escape', (tester) async {
    await _show(tester, const [_road]);
    await tester.enterText(find.byType(TextField), 'highway=service');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_applied, hasLength(1));
  });

  testWidgets('applies an edit to what it was made to when that changes', (
    tester,
  ) async {
    await _show(tester, const [_road]);
    await tester.enterText(find.byType(TextField), 'highway=service');
    // Something else is selected while the text still has the keyboard.
    await _show(tester, const [_other]);
    await tester.pump();
    expect(_applied.single.single.$1.id, 1);
    expect(_text(tester), 'highway=residential\nname=King Street');
  });

  testWidgets('applies an edit when it is taken away', (tester) async {
    await _show(tester, const [_road]);
    await tester.enterText(find.byType(TextField), 'highway=service');
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(_applied.single.single.$2, {'highway': 'service'});
  });

  testWidgets('hands on only the elements an edit changes', (tester) async {
    const lit = OsmWay(
      id: 3,
      nodeIds: [5, 6],
      tags: {'highway': 'residential', 'lit': 'yes'},
    );
    await _show(tester, const [_road, lit]);
    expect(_text(tester), 'highway=residential\nlit=*\nname=*');
    // Lighting both: the one already lit is left as it is.
    await tester.enterText(
      find.byType(TextField),
      'highway=residential\nlit=yes\nname=*',
    );
    await _leave(tester);
    expect([for (final (e, _) in _applied.single) e.id], [1]);
  });

  group('kinds', () {
    final presets = OsmPresets.parse(
      presets: jsonEncode({
        'point': {
          'tags': <String, String>{},
          'geometry': ['point', 'vertex'],
          'matchScore': 0.1,
        },
        'line': {
          'tags': <String, String>{},
          'geometry': ['line'],
          'matchScore': 0.1,
        },
        'area': {
          'tags': {'area': 'yes'},
          'geometry': ['area'],
          'matchScore': 0.1,
        },
        'highway/residential': {
          'tags': {'highway': 'residential'},
          'geometry': ['line'],
        },
        'highway/service': {
          'tags': {'highway': 'service'},
          'geometry': ['line'],
        },
        'amenity/cafe': {
          'tags': {'amenity': 'cafe'},
          'geometry': ['point', 'area'],
        },
        'building/house': {
          'tags': {'building': 'house'},
          'geometry': ['area'],
        },
      }),
      translations: jsonEncode({
        'en': {
          'presets': {
            'categories': {
              'category-road': {'name': 'Roads'},
            },
            'presets': {
              'point': {'name': 'Point'},
              'line': {'name': 'Line'},
              'area': {'name': 'Area'},
              'highway/residential': {'name': 'Residential Road'},
              'highway/service': {'name': 'Service Road'},
              'amenity/cafe': {'name': 'Cafe'},
              'building/house': {'name': 'House'},
            },
          },
        },
      }),
      categories: jsonEncode({
        'category-road': {
          'members': ['highway/residential', 'highway/service'],
        },
      }),
      defaults: jsonEncode({
        'line': ['category-road'],
        'point': ['amenity/cafe'],
        'area': ['amenity/cafe', 'building/house'],
      }),
    );

    /// Everything here is a line, but for the shop and the house.
    OsmGeometry geometryOf(OsmElement element, OsmPresets presets) =>
        switch (element.id) {
          10 => OsmGeometry.point,
          11 => OsmGeometry.area,
          _ => OsmGeometry.line,
        };

    const shop = OsmNode(
      id: 10,
      latitude: 0,
      longitude: 0,
      tags: {'amenity': 'cafe', 'name': 'Beans'},
    );
    const house = OsmWay(
      id: 11,
      nodeIds: [1, 2, 3, 1],
      tags: {'building': 'house', 'name': 'Mine'},
    );

    Future<void> showKinds(WidgetTester tester, List<OsmElement> elements) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TagEditor(
                elements: elements,
                presets: presets,
                geometryOf: geometryOf,
                onChanged: _applied.add,
              ),
            ),
          ),
        );

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('change-kind')));
      await tester.pumpAndSettle();
    }

    testWidgets('says what one element is and which it is', (tester) async {
      await showKinds(tester, const [_road]);
      expect(find.text('Residential Road'), findsOneWidget);
      expect(find.text('Way 1'), findsOneWidget);
    });

    testWidgets('says what several are when they are all the same', (
      tester,
    ) async {
      await showKinds(tester, const [_road, _other]);
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Residential Road'), findsOneWidget);
    });

    testWidgets('says only how many when they differ', (tester) async {
      await showKinds(tester, const [shop, house]);
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Cafe'), findsNothing);
    });

    testWidgets('goes by ids until the kinds are known', (tester) async {
      await _show(tester, const [_road]);
      expect(find.text('Way 1'), findsOneWidget);
      expect(find.byKey(const Key('change-kind')), findsNothing);
    });

    testWidgets('offers what the shape is usually made first', (tester) async {
      await showKinds(tester, const [_road]);
      await openPicker(tester);
      expect(find.text('Roads'), findsOneWidget);
      await tester.tap(find.text('Roads'));
      await tester.pumpAndSettle();
      expect(find.text('Service Road'), findsOneWidget);
    });

    testWidgets('makes several elements something else as one change', (
      tester,
    ) async {
      await showKinds(tester, const [_road, _other]);
      await openPicker(tester);
      await tester.enterText(find.byKey(const Key('preset-search')), 'serv');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Service Road'));
      await tester.pumpAndSettle();
      expect(_applied, hasLength(1));
      expect([for (final (e, _) in _applied.single) e.id], [1, 2]);
      expect(
        [for (final (_, tags) in _applied.single) tags],
        [
          {'name': 'Queen Street', 'highway': 'service'},
          {'name': 'King Street', 'highway': 'service'},
        ],
      );
      // And back to the tags.
      expect(find.byKey(const Key('tags')), findsOneWidget);
    });

    testWidgets('keeps what else an element is tagged with', (tester) async {
      await showKinds(tester, const [house]);
      await openPicker(tester);
      await tester.enterText(find.byKey(const Key('preset-search')), 'cafe');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_applied.single.single.$2, {'name': 'Mine', 'amenity': 'cafe'});
    });

    testWidgets('offers only what every element can be', (tester) async {
      // A cafe can be a point or an area; a house only an area.
      await showKinds(tester, const [shop, house]);
      await openPicker(tester);
      await tester.enterText(find.byKey(const Key('preset-search')), 'e');
      await tester.pumpAndSettle();
      expect(find.text('Cafe'), findsOneWidget);
      expect(find.text('House'), findsNothing);
    });

    testWidgets('goes back to the tags on escape, changing nothing', (
      tester,
    ) async {
      await showKinds(tester, const [_road]);
      await openPicker(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tags')), findsOneWidget);
      expect(_applied, isEmpty);
    });
  });
}
