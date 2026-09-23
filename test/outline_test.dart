import 'package:kupe/src/render/map_painter.dart';
import 'package:kupe/src/style/style.dart';
import 'package:test/test.dart';

void main() {
  test('outlines wider than the line it goes round', () {
    expect(outlineWidth(10, selectionSpread), greaterThan(10));
    expect(outlineWidth(3, selectionSpread), greaterThan(3));
  });

  test('outlines in proportion to the line', () {
    // Twice the line, twice the outline, once the floor is left behind.
    final narrow = outlineWidth(10, selectionSpread);
    final wide = outlineWidth(20, selectionSpread);
    expect(wide, closeTo(narrow * 2, 0.001));
  });

  test('outlines a hairline widely enough to see', () {
    // A footpath is one and a half pixels; half of that either side would be
    // nothing at all.
    final path = mapStyle[layerIndex('path')].width;
    expect(outlineWidth(path, selectionSpread) - path, leastOutline);
  });

  test('outlines what is pointed at inside what is selected', () {
    // So that pointing at a selected line shows both, one inside the other.
    for (final width in [1.5, 3.0, 5.0, 20.0]) {
      expect(
        outlineWidth(width, highlightSpread),
        lessThanOrEqualTo(outlineWidth(width, selectionSpread)),
        reason: 'at $width',
      );
    }
    expect(
      outlineWidth(20, highlightSpread),
      lessThan(outlineWidth(20, selectionSpread)),
    );
  });

  test('leaves room either side of a road and its casing', () {
    // The width picked is the widest layer the road is drawn in, so the
    // outline goes round the casing rather than through it.
    final casing = mapStyle[layerIndex('minor-casing')].width;
    final outline = outlineWidth(casing, selectionSpread);
    expect((outline - casing) / 2, greaterThanOrEqualTo(2));
  });
}
