/// Who the editor is signed in as, kept between runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:osm/osm.dart';

/// The OAuth application Kupe asks OpenStreetMap for a token as.
///
/// Public on purpose: a client ID names an application and authorises
/// nothing, which is why iD ships its own in the page source. See the notes
/// in osm.dart's `auth.dart` for what it is and is not.
///
/// A fork signing in as itself rather than as Kupe registers its own and
/// changes this, which also means changing [kupeRedirectPort] to whatever
/// that registration was given.
const kupeClientId = 'ZGVvl3NuHXWJaWDNro-48My6lkMAWQw9g6oX4oH5Y7c';

/// The port OpenStreetMap sends the browser back to.
///
/// Part of the registration: OpenStreetMap matches the redirect URI
/// character for character, so this cannot be whatever the machine had
/// spare.
const kupeRedirectPort = 8642;

/// What Kupe asks to be allowed to do when somebody signs in.
///
/// More than it uses today. A token only ever holds what was asked for when
/// it was issued, and OpenStreetMap's tokens do not expire, so a permission
/// asked for later reaches nobody already signed in until they sign in
/// again. Notes and changeset comments are what an editor grows into, and
/// asking now is what saves that.
///
/// Every one has to be ticked on the application's registration too, or
/// OpenStreetMap refuses the sign-in outright.
const kupeScopes = 'read_prefs write_api write_changeset_comments write_notes';

/// What Kupe calls itself in a changeset's `created_by`.
const kupeGenerator = 'Kupe';

/// The account the editor holds a token for, and the application it got it
/// as.
class Account {
  /// The bearer token, or null while nobody is signed in.
  final String? token;

  /// Whose token it is, so the editor can say who an edit would be made as.
  final String? user;

  /// What the token was granted when it was issued.
  ///
  /// Kept because it is not the same as what Kupe asks for. A token carries
  /// what somebody agreed to at the moment they signed in, and a permission
  /// added to the registration afterwards does not reach one already
  /// issued — OpenStreetMap's tokens do not expire, so one short of what is
  /// needed stays short of it until somebody signs in again. Knowing which
  /// is what lets the editor say so before an upload rather than during one.
  final Set<String> scopes;

  /// Creates an account.
  const Account({this.token, this.user, this.scopes = const {}});

  /// Whether there is a token at all.
  bool get isSignedIn => token != null;

  /// Whether the token held is allowed to change the map.
  ///
  /// False while nobody is signed in, and false for a token granted before
  /// Kupe asked to be allowed to upload.
  bool get canUpload => isSignedIn && scopes.contains(osmWriteApiScope);

  /// The same account with parts of it replaced, or with the token dropped.
  Account copyWith({
    String? token,
    String? user,
    Set<String>? scopes,
    bool signedOut = false,
  }) => Account(
    token: signedOut ? null : token ?? this.token,
    user: signedOut ? null : user ?? this.user,
    scopes: signedOut ? const {} : scopes ?? this.scopes,
  );

  /// The account as it is written down.
  Map<String, dynamic> toJson() => {
    if (token != null) 'token': token,
    if (user != null) 'user': user,
    if (scopes.isNotEmpty) 'scopes': scopes.toList()..sort(),
  };

  /// An account out of what was written down.
  static Account fromJson(Object? json) {
    if (json is! Map) return const Account();
    String? string(String key) =>
        json[key] is String ? json[key] as String : null;
    final scopes = json['scopes'];
    return Account(
      token: string('token'),
      user: string('user'),
      scopes: {
        if (scopes is List)
          for (final scope in scopes)
            if (scope is String) scope,
      },
    );
  }

  /// Reads the account from [file], or an empty one if there is none.
  static Future<Account> read(File? file) async {
    if (file == null || !file.existsSync()) return const Account();
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } on Exception {
      // A file somebody has been editing by hand is not worth a crash on
      // startup: sign in again.
      return const Account();
    }
  }

  /// Writes the account to [file].
  Future<void> write(File? file) async {
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(this));
    // Owner only. It is a key to somebody's OpenStreetMap account.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  /// Signs in through the browser and comes back with the account.
  ///
  /// Asks OpenStreetMap whose token it handed over as well, so the editor
  /// can say who an edit would be made as rather than only that it could be
  /// made.
  ///
  /// Completing [cancel] gives up, with [OsmSignInCancelledException].
  Future<Account> signIn({
    Future<void>? cancel,
    Future<OsmToken> Function(OsmSignIn)? through,
    Future<String> Function(String token)? whoAmI,
  }) async {
    final signIn = OsmSignIn(
      clientId: kupeClientId,
      scopes: kupeScopes,
      redirectPort: kupeRedirectPort,
    );
    final token =
        await (through?.call(signIn) ??
            signIn.tokenFromBrowser(cancel: cancel));
    // Asked of OpenStreetMap only where the token is allowed to ask. A token
    // without it is still worth keeping: the editor can say what it is short
    // of, which is more use than refusing to hold it at all.
    final user = token.covers('read_prefs')
        ? await (whoAmI?.call(token.token) ?? _whoAmI(token.token))
        : null;
    return copyWith(token: token.token, user: user, scopes: token.scopes);
  }

  static Future<String> _whoAmI(String token) async {
    final uploader = OsmUploader(token: token, generator: kupeGenerator);
    try {
      return await uploader.whoAmI();
    } finally {
      uploader.close();
    }
  }
}
