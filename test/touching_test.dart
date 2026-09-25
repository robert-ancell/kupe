import 'package:kupe/src/edit/touching.dart';
import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'editing.dart';

const _node = OsmNode(
  id: 1,
  latitude: -36.85,
  longitude: 174.76,
  info: OsmInfo(version: 3),
);

const _way = OsmWay(id: 10, nodeIds: [1, 2], info: OsmInfo(version: 1));

void main() {
  test('says what has to be drawn again after a move', () {
    final edits = OsmEditHistory();
    editing(edits).moveNode(_node, latitude: -36.86, longitude: 174.77);
    final touched = touchedBy(edits, (id) => id == 1 ? [10, 11] : const []);
    expect(touched, {
      (OsmElementType.node, 1),
      (OsmElementType.way, 10),
      (OsmElementType.way, 11),
    });
  });

  test('says nothing has to be drawn again when nothing has changed', () {
    expect(touchedBy(OsmEditHistory(), (_) => [1, 2]), isEmpty);
  });

  test('says a deleted node and the ways through it are drawn again', () {
    final edits = OsmEditHistory();
    editing(edits, OsmEditorData.of([_node, _way])).deleteNode(_node);
    final touched = touchedBy(edits, (id) => id == 1 ? [10] : const []);
    expect(touched, contains((OsmElementType.node, 1)));
    expect(touched, contains((OsmElementType.way, 10)));
  });
}
