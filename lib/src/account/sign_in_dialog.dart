/// Signing in, and saying who is signed in.
library;

import 'package:flutter/material.dart';

import 'account.dart';

/// Takes somebody through signing in, and gives back the account it came
/// back with. Null if it was closed instead.
///
/// A window rather than a button that simply opens a browser: a sign-in
/// leaves the editor for a while and can fail in ways that are worth reading
/// — an application registered wrongly says so in a paragraph — and there
/// has to be somewhere for that to appear.
Future<Account?> showSignInDialog(
  BuildContext context, {
  required Account account,
  Future<Account> Function(Account account)? signIn,
}) => showDialog<Account>(
  context: context,
  builder: (context) => SignInDialog(account: account, signIn: signIn),
);

/// The window that takes somebody through signing in.
class SignInDialog extends StatefulWidget {
  /// What is known about the account already.
  final Account account;

  /// How to sign in. Replaced in tests, which have no browser.
  final Future<Account> Function(Account account)? signIn;

  /// Creates the window.
  const SignInDialog({super.key, required this.account, this.signIn});

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  late final Account _account = widget.account;
  bool _busy = false;

  /// What went wrong, where it went wrong. It belongs in front of the
  /// button that caused it rather than behind a window that has closed.
  String? _said;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _said = null;
    });
    try {
      final signedIn =
          await (widget.signIn?.call(_account) ?? _account.signIn());
      if (!mounted) return;
      Navigator.pop(context, signedIn);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _said = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signOut() => Navigator.pop(context, _account.copyWith(signedOut: true));

  /// What the window says above the buttons.
  String get _explanation {
    if (!_account.isSignedIn) {
      return 'Signing in opens OpenStreetMap in your browser. Kupe never '
          'sees your password: it is given a token, and only for as long as '
          'you leave it signed in.';
    }
    final user = _account.user;
    final who = user == null ? '' : ' as $user';
    if (!_account.canUpload) {
      // A token granted before Kupe asked to be allowed to upload goes on
      // being short of it: OpenStreetMap's tokens do not expire, and a
      // permission added to the registration never reaches one already
      // issued. Saying so here is the difference between a sentence and a
      // refusal part way through an upload.
      return 'Signed in$who, but this sign-in did not include permission to '
          'change the map. Sign in again to give it.';
    }
    return 'Signed in$who. Changes you upload will be made under that '
        'account.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('OpenStreetMap account'),
      // Scrolled, because what this has to say varies: a refusal from
      // OpenStreetMap can be a paragraph, and a paragraph is not a reason
      // for the buttons to go off the bottom of the screen.
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_explanation),
              if (_said case final said?)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: SelectableText(
                    said,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('close'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (_account.isSignedIn)
          TextButton(
            key: const Key('sign-out'),
            onPressed: _busy ? null : _signOut,
            child: const Text('Sign out'),
          ),
        if (!_account.isSignedIn || !_account.canUpload)
          FilledButton.icon(
            key: const Key('sign-in'),
            onPressed: _busy ? null : _signIn,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.open_in_browser),
            label: Text(_account.isSignedIn ? 'Sign in again' : 'Sign in'),
          ),
      ],
    );
  }
}
