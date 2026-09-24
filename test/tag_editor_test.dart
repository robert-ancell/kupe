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
}
