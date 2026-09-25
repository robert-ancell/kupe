import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

/// An editor making its changes into [edits], over [read] if given and over
/// nothing otherwise: for a test that holds the history a map is drawn from
/// and wants to change it.
OsmEditor editing(OsmEditHistory edits, [OsmElementSource? read]) => OsmEditor(
  read ?? OsmElementSource.of(const []),
  history: edits,
  rules: OsmStandardTagRules(),
);
