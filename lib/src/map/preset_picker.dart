import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

/// A list of the kinds of thing something can be, to choose one from.
///
/// Before anything is typed it offers what the schema suggests for the
/// shape, with its categories opening onto what is in them; once something
/// is typed it offers what that finds. Only kinds every selected element
/// can take are offered at all.
class PresetPicker extends StatefulWidget {
  /// Every kind there is.
  final OsmPresets presets;

  /// The shapes of what is selected. What is offered can take all of them.
  final Set<OsmGeometry> geometries;

  /// What it is now, if everything selected is the same.
  final OsmPreset? current;

  /// The codes of every region what is selected is in. Kinds that only
  /// exist somewhere else are not offered.
  final Set<String> here;

  /// Called with what was chosen.
  final ValueChanged<OsmPreset> onChosen;

  /// Called when nothing is to be chosen after all.
  final VoidCallback onCancelled;

  /// Creates the picker.
  const PresetPicker({
    super.key,
    required this.presets,
    required this.geometries,
    required this.onChosen,
    required this.onCancelled,
    this.current,
    this.here = const {},
  });

  @override
  State<PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<PresetPicker> {
  final _query = TextEditingController();

  /// The category opened to show what is in it, if one is.
  OsmPresetCategory? _open;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _open = null));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Whether [preset] can be offered for what is selected.
  bool _offered(OsmPreset preset) =>
      preset.searchable &&
      preset.replacement == null &&
      preset.appliesAt(widget.here) &&
      preset.geometry.containsAll(widget.geometries);

  /// What to show: presets, and categories to open.
  List<Object> get _entries {
    final presets = widget.presets;
    final query = _query.text.trim();
    if (query.isNotEmpty) {
      return [
        for (final preset in presets.search(
          query,
          widget.geometries.first,
          here: widget.here,
          limit: 100,
        ))
          if (_offered(preset)) preset,
      ];
    }
    final open = _open;
    if (open != null) {
      return [
        for (final id in open.members)
          if (presets.byId[id] case final preset? when _offered(preset)) preset,
      ];
    }
    final suggested = <Object>[];
    for (final id in presets.defaults[widget.geometries.first] ?? const []) {
      final category = presets.categories[id];
      if (category != null) {
        // Only a category with something in it that can be chosen.
        final any = category.members.any((member) {
          final preset = presets.byId[member];
          return preset != null && _offered(preset);
        });
        if (any) suggested.add(category);
        continue;
      }
      final preset = presets.byId[id];
      if (preset != null && _offered(preset)) suggested.add(preset);
    }
    return suggested;
  }

  void _chooseFirst() {
    for (final entry in _entries) {
      if (entry is OsmPreset) {
        widget.onChosen(entry);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_open != null) {
            setState(() => _open = null);
          } else {
            widget.onCancelled();
          }
        },
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('preset-search'),
            controller: _query,
            autofocus: true,
            style: const TextStyle(color: Color(0xffffffff), fontSize: 13),
            cursorColor: const Color(0xff9ec1ff),
            onSubmitted: (_) => _chooseFirst(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search for a type',
              hintStyle: TextStyle(color: Color(0xff7d848c)),
              prefixIcon: Icon(
                Icons.search,
                size: 16,
                color: Color(0xff7d848c),
              ),
              prefixIconConstraints: BoxConstraints(minWidth: 28),
              filled: true,
              fillColor: Color(0xff1f2328),
              contentPadding: EdgeInsets.all(8),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
          if (_open case final open?)
            _Row(
              key: const Key('preset-back'),
              icon: Icons.chevron_left,
              label: open.name,
              bold: true,
              onTap: () => setState(() => _open = null),
            ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: entries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Nothing found',
                      style: TextStyle(color: Color(0xffa0a6ad), fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, i) => switch (entries[i]) {
                      final OsmPresetCategory category => _Row(
                        key: Key(category.id),
                        icon: Icons.folder_outlined,
                        label: category.name,
                        trailing: Icons.chevron_right,
                        onTap: () => setState(() => _open = category),
                      ),
                      final OsmPreset preset => _Row(
                        key: Key(preset.id),
                        label: preset.name,
                        detail: _tagOf(preset),
                        chosen: preset.id == widget.current?.id,
                        onTap: () => widget.onChosen(preset),
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// The tag that says most plainly what [preset] is, to tell apart kinds
  /// with similar names.
  static String _tagOf(OsmPreset preset) {
    final entry = preset.tags.entries.firstOrNull;
    return entry == null ? '' : '${entry.key}=${entry.value}';
  }
}

/// One line of the list.
class _Row extends StatelessWidget {
  final String label;
  final String detail;
  final IconData? icon;
  final IconData? trailing;
  final bool chosen;
  final bool bold;
  final VoidCallback onTap;

  const _Row({
    super.key,
    required this.label,
    required this.onTap,
    this.detail = '',
    this.icon,
    this.trailing,
    this.chosen = false,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: chosen ? const Color(0x332f6fed) : null,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            if (icon case final icon?) ...[
              Icon(icon, size: 16, color: const Color(0xffa0a6ad)),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xffffffff),
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : null,
                ),
              ),
            ),
            if (detail.isNotEmpty)
              Flexible(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xff7d848c),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            if (trailing case final trailing?)
              Icon(trailing, size: 16, color: const Color(0xffa0a6ad)),
          ],
        ),
      ),
    );
  }
}
