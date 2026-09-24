import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kupe/src/account/account.dart';
import 'package:kupe/src/account/sign_in_dialog.dart';
import 'package:kupe/src/account/upload_dialog.dart';
import 'package:osm/osm.dart';

/// Puts [child] on screen on its own, for the windows this file is about.
Future<void> _show(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  group('what is kept between runs', () {
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('kupe-account');
      file = File('${directory.path}/account.json');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test('starts signed out where there is nothing to read', () async {
      expect((await Account.read(file)).isSignedIn, isFalse);
      expect((await Account.read(null)).isSignedIn, isFalse);
    });

    test('remembers who was signed in', () async {
      await const Account(token: 'a-token', user: 'Somebody').write(file);
      final read = await Account.read(file);
      expect(read.token, 'a-token');
      expect(read.user, 'Somebody');
      expect(read.isSignedIn, isTrue);
    });

    test('keeps the token to the one account it belongs to', () async {
      await const Account(token: 'a-token').write(file);
      // It is a key to somebody's OpenStreetMap account, so nobody else on
      // the machine is entitled to read it.
      expect(file.statSync().mode & 0x3f, 0);
    }, skip: Platform.isWindows ? 'no file modes' : null);

    test('signs in again rather than crashing on a file by hand', () async {
      await file.writeAsString('not json');
      expect((await Account.read(file)).isSignedIn, isFalse);
    });

    test('forgets the token when signed out', () {
      const account = Account(token: 'a-token', user: 'Somebody');
      final out = account.copyWith(signedOut: true);
      expect(out.isSignedIn, isFalse);
      expect(out.user, isNull);
    });

    test('prefers a client ID put in by hand', () {
      expect(const Account(clientId: 'mine').signInAs, 'mine');
    });
  });

  group('signing in', () {
    testWidgets('offers to sign in when nobody is', (tester) async {
      await _show(tester, const SignInDialog(account: Account()));
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
      expect(find.byKey(const Key('sign-out')), findsNothing);
    });

    testWidgets('says who is signed in', (tester) async {
      await _show(
        tester,
        const SignInDialog(
          account: Account(token: 'a-token', user: 'Somebody'),
        ),
      );
      expect(find.textContaining('Somebody'), findsOneWidget);
      expect(find.byKey(const Key('sign-out')), findsOneWidget);
    });

    testWidgets('comes back with the account it signed in as', (tester) async {
      Account? came;
      await _show(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => came = await showSignInDialog(
              context,
              account: const Account(),
              signIn: (account) async =>
                  account.copyWith(token: 'a-token', user: 'Somebody'),
            ),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pumpAndSettle();
      expect(came!.user, 'Somebody');
    });

    testWidgets('says what went wrong rather than closing', (tester) async {
      await _show(
        tester,
        SignInDialog(
          account: const Account(),
          signIn: (_) async =>
              throw const OsmSignInException('The browser never came back.'),
        ),
      );
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pumpAndSettle();
      expect(find.textContaining('never came back'), findsOneWidget);
      expect(find.byKey(const Key('sign-in')), findsOneWidget);
    });
  });

  group('uploading', () {
    /// Some changes to show: a node made, and one moved.
    OsmUpload changes() {
      final edits = OsmEdits()..createNode(latitude: 1, longitude: 2);
      edits.moveNode(
        const OsmNode(
          id: 7,
          latitude: 1,
          longitude: 2,
          info: OsmInfo(version: 4),
        ),
        latitude: 3,
        longitude: 4,
      );
      return OsmUpload.of(edits);
    }

    testWidgets('lists every element that would change', (tester) async {
      await _show(
        tester,
        UploadDialog(
          upload: changes(),
          comment: TextEditingController(),
          send: (_) async => 1,
        ),
      );
      expect(find.textContaining('Create node'), findsOneWidget);
      expect(find.textContaining('Move node/7'), findsOneWidget);
    });

    testWidgets('will not send without a comment', (tester) async {
      final comment = TextEditingController();
      await _show(
        tester,
        UploadDialog(upload: changes(), comment: comment, send: (_) async => 1),
      );
      final button = find.byKey(const Key('upload'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);

      await tester.enterText(find.byKey(const Key('comment')), 'Fixed a road');
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });

    testWidgets('comes back with the changeset number', (tester) async {
      int? sent;
      final comment = TextEditingController(text: 'Fixed a road');
      await _show(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => sent = await showUploadDialog(
              context,
              upload: changes(),
              comment: comment,
              send: (_) async => 12345,
            ),
            child: const Text('go'),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('upload')));
      await tester.pumpAndSettle();
      expect(sent, 12345);
    });

    testWidgets('keeps the changes in front of a refusal', (tester) async {
      await _show(
        tester,
        UploadDialog(
          upload: changes(),
          comment: TextEditingController(text: 'Fixed a road'),
          send: (_) async =>
              throw const OsmUploadException('Somebody got there first.'),
        ),
      );
      await tester.tap(find.byKey(const Key('upload')));
      await tester.pumpAndSettle();
      expect(find.textContaining('got there first'), findsOneWidget);
      expect(find.textContaining('Move node/7'), findsOneWidget);
    });
  });
}
