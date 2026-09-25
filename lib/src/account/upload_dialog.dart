/// What is about to be sent to OpenStreetMap, and the button that sends it.
///
/// A window of its own rather than a panel down the side, because it is the
/// one moment in the editor that cannot be taken back. Everything up to here
/// is drawing on a screen; this writes to the map under somebody's name. So
/// it stops the work, lists every element that would change, takes a
/// comment, and waits.
///
/// Nothing else in the editor can write to the API. The upload is a callback
/// handed in, so this window is the only way to one.
library;

import 'package:flutter/material.dart';
import 'package:osm/osm.dart';

/// Shows what would be sent and, if the button is pressed and the upload
/// works, returns the changeset number. Null if it was closed instead.
Future<int?> showUploadDialog(
  BuildContext context, {
  required OsmUpload upload,
  required TextEditingController comment,
  required Future<int> Function(String comment) send,
}) => showDialog<int>(
  context: context,
  // Not dismissed by a stray click on the way to the button.
  barrierDismissible: false,
  builder: (context) =>
      UploadDialog(upload: upload, comment: comment, send: send),
);

/// The window that shows what would be sent.
class UploadDialog extends StatefulWidget {
  /// What would go.
  final OsmUpload upload;

  /// What it would be called, kept outside the window so that a comment
  /// typed and then thought better of is still there next time.
  final TextEditingController comment;

  /// Sends it, and gives back the changeset number.
  final Future<int> Function(String comment) send;

  /// Creates the window.
  const UploadDialog({
    super.key,
    required this.upload,
    required this.comment,
    required this.send,
  });

  @override
  State<UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<UploadDialog> {
  bool _busy = false;

  /// What went wrong. A refusal belongs here rather than behind a window
  /// that has already closed: the changes are still in front of you and the
  /// button is there to try again.
  String? _said;

  @override
  void initState() {
    super.initState();
    widget.comment.addListener(_commentChanged);
  }

  @override
  void dispose() {
    widget.comment.removeListener(_commentChanged);
    super.dispose();
  }

  /// The button turns on with the first character of a comment, so it has to
  /// be rebuilt as one is typed.
  void _commentChanged() => setState(() {});

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _said = null;
    });
    try {
      final changeset = await widget.send(widget.comment.text.trim());
      if (!mounted) return;
      // Straight out: what happened is one line, and one line does not want
      // a window with a button under it. The map says it along the bottom
      // with the changeset as a link.
      Navigator.pop(context, changeset);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _said = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changes = describeUpload(widget.upload);
    final ready = changes.isNotEmpty && widget.comment.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('Upload ${changes.length} change(s)'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The list first and the comment under it: the comment
            // describes the list, and it is easier to write one having just
            // read the other.
            Flexible(
              child: changes.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Nothing has been changed.'),
                    )
                  : ListView.builder(
                      key: const Key('changes'),
                      shrinkWrap: true,
                      itemCount: changes.length,
                      itemBuilder: (context, i) => Text(
                        changes[i],
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('comment'),
              controller: widget.comment,
              enabled: !_busy,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What did you change?',
                helperText:
                    'Everybody who looks at this changeset later '
                    'will read this.',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_said case final said?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(
                  said,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('upload'),
          onPressed: _busy || !ready ? null : _send,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload),
          label: const Text('Upload'),
        ),
      ],
    );
  }
}

/// A line for each element of [upload], in the order they would be sent.
///
/// What the dialog lists. Short on purpose: what matters to whoever is
/// reading is how many of what, and which ones, not the XML.
List<String> describeUpload(OsmUpload upload) => [
  for (final node in upload.createdNodes) 'Create node ${_name(node.id)}',
  for (final way in upload.createdWays)
    'Create way ${_name(way.id)} through ${way.nodeIds.length} node(s)',
  for (final relation in upload.createdRelations)
    'Create relation ${_name(relation.id)} of '
        '${relation.members.length} member(s)',
  // Changed rather than moved or retagged: what is sent is the element
  // as it now stands, which says nothing of what it was.
  for (final node in upload.changedNodes) 'Change node/${node.id}',
  for (final way in upload.changedWays) 'Change way/${way.id}',
  for (final relation in upload.changedRelations)
    'Change relation/${relation.id}',
  for (final relation in upload.deletedRelations)
    'Delete relation/${relation.id}',
  for (final way in upload.deletedWays) 'Delete way/${way.id}',
  for (final node in upload.deletedNodes) 'Delete node/${node.id}',
];

/// What to call an element that has no id of its own yet.
String _name(int id) => id < 0 ? 'new ($id)' : '$id';
