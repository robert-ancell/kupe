import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:osm/osm.dart';

import 'preset_picker.dart';

/// The tags of what is selected, as text that can be edited.
///
/// One `key=value` to a line, the way iD's text view shows them. With
/// several elements selected there is one text for all of them: a tag they
/// share is shown as it is, and one they do not is shown as `key=*`. What is
/// changed in the text is changed on every one of them — see
/// [OsmTagText.apply] — and what is left alone is left alone on each.
///
/// Changes are applied when the text is left, as iD does: a tag half typed
/// is not a tag, and applying on every key would put `h`, `hi`, `hig` and
/// so on into the list of things to undo.
class TagEditor extends StatefulWidget {
  /// What is selected, as it now stands.
  final List<OsmElement> elements;

  /// Called with every element whose tags the text changed, and the tags it
  /// is to have.
  final void Function(List<(OsmElement, Map<String, String>)> changes)
  onChanged;

  /// Where the keyboard goes when the text is left with escape: back to
  /// whatever it would be doing if the text had never been clicked.
  final FocusNode? returnFocus;

  /// What kinds of thing there are, once they are known. With them the
  /// editor says what is selected rather than only which element it is, and
  /// offers to make it something else.
  final OsmPresets? presets;

  /// The shape of an element, which is what decides what it can be.
  final OsmGeometry Function(OsmElement element, OsmPresets presets)?
  geometryOf;

  /// The codes of every region an element is in, which is what decides
  /// which of the kinds that only exist in some places it can be.
  final Set<String> Function(OsmElement element)? regionsOf;

  /// Creates the editor.
  const TagEditor({
    super.key,
    required this.elements,
    required this.onChanged,
    this.returnFocus,
    this.presets,
    this.geometryOf,
    this.regionsOf,
  });

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  final _focus = FocusNode(debugLabel: 'tags');
  late final TextEditingController _text;

  /// The text as it was shown, which is what the edited text is compared with
  /// to say what changed.
  ///
  /// Set as soon as the editor is made, not the first time it is needed: by
  /// then it may have been typed over, and an edit compared with itself is
  /// no edit at all.
  late String _shown;

  static String _shownFor(List<OsmElement> elements) =>
      OsmTagText([for (final element in elements) element.tags]).text;

  @override
  void initState() {
    super.initState();
    _shown = _shownFor(widget.elements);
    _text = TextEditingController(text: _shown);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(TagEditor old) {
    super.didUpdateWidget(old);
    final sameSelection = _keysOf(old.elements) == _keysOf(widget.elements);
    // Moving on to something else mid edit applies the edit to what it was
    // made to, not to what is selected now. Worked out now, while the text
    // is still the text for those, and handed on once this frame is built,
    // since what is handed on changes the map.
    if (!sameSelection) {
      final changes = _changesTo(old.elements);
      if (changes.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onChanged(changes),
        );
      }
    }
    // And whatever has changed the tags since — this editor, an undo — is
    // shown, unless it is being typed into.
    final shown = _shownFor(widget.elements);
    if (shown != _shown && (!sameSelection || !_focus.hasFocus)) {
      _shown = shown;
      _text.text = shown;
    }
  }

  static String _keysOf(List<OsmElement> elements) =>
      [for (final e in elements) '${e.type.name}/${e.id}'].join(',');

  void _focusChanged() {
    if (_focus.hasFocus) return;
    final changes = _changesTo(widget.elements);
    if (changes.isNotEmpty) widget.onChanged(changes);
  }

  /// What the edit does to each of [elements]: the ones it changes, and the
  /// tags each is to have. The edit counts as applied from here on.
  List<(OsmElement, Map<String, String>)> _changesTo(
    List<OsmElement> elements,
  ) {
    final edited = _text.text;
    if (edited == _shown) return const [];
    final before = [for (final element in elements) element.tags];
    final after = OsmTagText(before, text: _shown).apply(edited);
    _shown = edited;
    return [
      for (var i = 0; i < elements.length; i++)
        if (!identical(after[i], before[i])) (elements[i], after[i]),
    ];
  }

  void _leave() {
    final back = widget.returnFocus;
    if (back != null) {
      back.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  /// Applies what has been typed and not yet applied when the editor is
  /// taken away, however that happens.
  ///
  /// Leaving the text is what normally applies it, but the editor can go
  /// without the text ever being left: zooming out past where editing stops
  /// with the wheel, while the text still has the keyboard, lets go of the
  /// selection and the editor with it.
  @override
  void deactivate() {
    final changes = _changesTo(widget.elements);
    if (changes.isNotEmpty) {
      final onChanged = widget.onChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChanged(changes));
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  /// Whether the list of kinds is showing in place of the text.
  bool _picking = false;

  /// What each element is, and the shape it takes, if the kinds are known.
  List<(OsmPreset, OsmGeometry)>? get _kinds {
    final presets = widget.presets;
    final geometryOf = widget.geometryOf;
    if (presets == null || geometryOf == null) return null;
    final kinds = <(OsmPreset, OsmGeometry)>[];
    for (final element in widget.elements) {
      final geometry = geometryOf(element, presets);
      final here = widget.regionsOf?.call(element) ?? const {};
      kinds.add((presets.match(element.tags, geometry, here: here), geometry));
    }
    return kinds;
  }

  /// What everything selected is, if it is all the same kind.
  static OsmPreset? _shared(List<(OsmPreset, OsmGeometry)>? kinds) {
    if (kinds == null || kinds.isEmpty) return null;
    final first = kinds.first.$1;
    return kinds.every((kind) => kind.$1.id == first.id) ? first : null;
  }

  String _title(List<(OsmPreset, OsmGeometry)>? kinds) {
    final elements = widget.elements;
    if (elements.length > 1) return '${elements.length} selected';
    return kinds?.single.$1.name ?? _idOf(elements.single);
  }

  /// What goes under the title: which element it is, or for several, what
  /// they all are.
  String? _subtitle(List<(OsmPreset, OsmGeometry)>? kinds) {
    final elements = widget.elements;
    if (elements.length > 1) return _shared(kinds)?.name;
    return kinds == null ? null : _idOf(elements.single);
  }

  static String _idOf(OsmElement element) => switch (element.type) {
    OsmElementType.node => 'Node ${element.id}',
    OsmElementType.way => 'Way ${element.id}',
    OsmElementType.relation => 'Relation ${element.id}',
  };

  /// Makes everything selected [chosen], as one change.
  ///
  /// Each element stops being what it was — the tags that said so come off
  /// — and becomes [chosen], keeping everything else it is tagged with: a
  /// house made a cafe keeps its name and its address.
  void _choose(OsmPreset chosen) {
    final presets = widget.presets!;
    final kinds = _kinds!;
    final changes = <(OsmElement, Map<String, String>)>[];
    for (var i = 0; i < widget.elements.length; i++) {
      final element = widget.elements[i];
      final (was, geometry) = kinds[i];
      final tags = chosen.applyTo(
        was.removeFrom(element.tags),
        geometry,
        presets,
      );
      if (!_sameTags(tags, element.tags)) changes.add((element, tags));
    }
    setState(() => _picking = false);
    if (changes.isNotEmpty) widget.onChanged(changes);
  }

  static bool _sameTags(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  Widget build(BuildContext context) {
    final kinds = _kinds;
    final presets = widget.presets;
    final subtitle = _subtitle(kinds);
    const text = TextStyle(
      color: Color(0xffffffff),
      fontSize: 12,
      fontFamily: 'monospace',
      height: 1.4,
    );
    return Material(
      color: const Color(0xee2b3036),
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(kinds),
                          key: const Key('kind'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xff9ec1ff),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xffa0a6ad),
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (kinds != null)
                    TextButton(
                      key: const Key('change-kind'),
                      onPressed: () => setState(() => _picking = !_picking),
                      child: Text(_picking ? 'Cancel' : 'Change'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_picking && presets != null && kinds != null)
                PresetPicker(
                  presets: presets,
                  geometries: {for (final (_, geometry) in kinds) geometry},
                  current: _shared(kinds),
                  // Where the first of them is: a selection is seldom
                  // spread over more than one country.
                  here:
                      widget.regionsOf?.call(widget.elements.first) ?? const {},
                  onChosen: _choose,
                  onCancelled: () => setState(() => _picking = false),
                )
              else
                // Escape leaves the text, which applies it, rather than
                // reaching the map and giving up on whatever is being drawn.
                // The keyboard goes back to the map, so that its own keys —
                // undo among them — work again straight away.
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): _leave,
                  },
                  child: TextField(
                    key: const Key('tags'),
                    controller: _text,
                    focusNode: _focus,
                    style: text,
                    minLines: 3,
                    maxLines: 14,
                    keyboardType: TextInputType.multiline,
                    cursorColor: const Color(0xff9ec1ff),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'key=value',
                      hintStyle: TextStyle(color: Color(0xff7d848c)),
                      filled: true,
                      fillColor: Color(0xff1f2328),
                      contentPadding: EdgeInsets.all(8),
                      border: OutlineInputBorder(borderSide: BorderSide.none),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
