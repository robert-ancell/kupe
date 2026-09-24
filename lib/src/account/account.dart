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
/// Empty means no application has been registered for this build — a fork,
/// or a checkout somebody is running themselves — and the editor asks for
/// one rather than pretending to be somebody else's.
const kupeClientId = '';

/// The port OpenStreetMap sends the browser back to.
///
/// Part of the registration: OpenStreetMap matches the redirect URI
/// character for character, so this cannot be whatever the machine had
/// spare.
const kupeRedirectPort = 8642;

/// What Kupe calls itself in a changeset's `created_by`.
const kupeGenerator = 'Kupe';

/// The account the editor holds a token for, and the application it got it
/// as.
class Account {
  /// A client ID put in by hand, for a build with none of its own. Null on
  /// an ordinary install, where [kupeClientId] is the one used.
  final String? clientId;

  /// The bearer token, or null while nobody is signed in.
  final String? token;

  /// Whose token it is, so the editor can say who an edit would be made as.
  final String? user;

  /// Creates an account.
  const Account({this.clientId, this.token, this.user});

  /// Whether there is a token to edit with.
  bool get isSignedIn => token != null;

  /// The application to sign in as: one put in by hand if there is one, and
  /// the editor's own otherwise.
  ///
  /// Null only where there is neither, which is the one case the editor has
  /// to ask about.
  String? get signInAs {
    final own = clientId?.trim();
    if (own != null && own.isNotEmpty) return own;
    return kupeClientId.isEmpty ? null : kupeClientId;
  }

  /// The same account with parts of it replaced, or with the token dropped.
  Account copyWith({
    String? clientId,
    String? token,
    String? user,
    bool signedOut = false,
  }) => Account(
    clientId: clientId ?? this.clientId,
    token: signedOut ? null : token ?? this.token,
    user: signedOut ? null : user ?? this.user,
  );

  /// The account as it is written down.
  Map<String, dynamic> toJson() => {
    if (clientId != null) 'clientId': clientId,
    if (token != null) 'token': token,
    if (user != null) 'user': user,
  };

  /// An account out of what was written down.
  static Account fromJson(Object? json) {
    if (json is! Map) return const Account();
    String? string(String key) =>
        json[key] is String ? json[key] as String : null;
    return Account(
      clientId: string('clientId'),
      token: string('token'),
      user: string('user'),
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
  Future<Account> signIn({
    Future<String> Function(OsmSignIn)? through,
    Future<String> Function(String token)? whoAmI,
  }) async {
    final clientId = signInAs;
    if (clientId == null) {
      throw const OsmSignInException(
        'This build of Kupe has no OpenStreetMap application registered to '
        'sign in as. Register one and put its client ID in here.',
      );
    }
    final signIn = OsmSignIn(
      clientId: clientId,
      redirectPort: kupeRedirectPort,
    );
    final token = await (through?.call(signIn) ?? signIn.tokenFromBrowser());
    final user = await (whoAmI?.call(token) ?? _whoAmI(token));
    return copyWith(token: token, user: user);
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
