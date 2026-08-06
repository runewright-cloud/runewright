// SPDX-License-Identifier: GPL-3.0-or-later
//
// about_screen_test.dart — AboutScreen (lib/ui/about_screen.dart).
//
// Markdown-lite rendering (`parseMarkdownLite`) is tested against synthetic
// strings built in-memory, never through `rootBundle.loadString` -- a real
// asset load of README.md was confirmed, empirically, to never resolve the
// SECOND time it's triggered anywhere in this file (reproducible with a
// bare FutureBuilder + rootBundle.loadString, no AboutScreen involved;
// looks like the same class of trap as this repo's other "real async I/O
// doesn't reach an awaited Future inside testWidgets' FakeAsync zone"
// gotchas -- see test-environment-widget-gotchas memory -- except
// tester.runAsync did not bridge it here). So: only ONE test below performs
// a real README.md load (the "defaults to..." test); every other test
// either supplies markdown in-memory, starts on the Credits tab (which
// never builds the README page, confirmed not to trigger the load), or
// uses bounded pump()s instead of pumpAndSettle so it doesn't wait on the
// README FutureBuilder at all -- the same idiom this repo already uses for
// ApprenticeshipScreen's never-settling FutureBuilder in
// commune_trade_navigation_test.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/about_screen.dart';
import 'package:rune_duel/ui/credits_screen.dart';
import 'package:rune_duel/ui/menu_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    installFakeSecureStorage();
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('parseMarkdownLite', () {
    const sample = '# Title\n'
        '\n'
        'A paragraph with **bold**, `code`, and a [link](https://example.com).\n'
        '\n'
        '## Section\n'
        '\n'
        '- first item\n'
        '- second item continues\n'
        '  on a wrapped line\n'
        '\n'
        '| Col A | Col B |\n'
        '|---|---|\n'
        '| a1 | b1 |\n'
        '\n'
        '```\n'
        'some code\n'
        '```\n';

    testWidgets('renders headings, inline formatting, lists, tables, and code blocks',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(children: parseMarkdownLite(sample)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Section'), findsOneWidget);
      expect(find.textContaining('bold'), findsOneWidget);
      expect(find.textContaining('code'), findsWidgets); // inline `code` + fenced block
      expect(find.textContaining('link'), findsOneWidget);
      expect(find.textContaining('first item'), findsOneWidget);
      // Wrapped continuation line merges into the same bullet.
      expect(find.textContaining('second item continues on a wrapped line'), findsOneWidget);
      expect(find.text('Col A'), findsOneWidget);
      expect(find.text('a1'), findsOneWidget);
      expect(find.textContaining('some code'), findsOneWidget);
    });
  });

  testWidgets('defaults to the README tab (real README.md) and switches to Credits on tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    await tester.pumpAndSettle();

    expect(find.text('README'), findsOneWidget);
    expect(find.text('Credits'), findsOneWidget);
    // A line straight out of README.md's opening paragraph.
    expect(find.textContaining('peer-to-peer'), findsWidgets);

    await tester.tap(find.text('Credits'));
    await tester.pumpAndSettle();

    expect(find.byType(CreditsScreen), findsOneWidget);
    expect(find.textContaining('J. W. Bjerk'), findsWidgets);
  });

  testWidgets('initialTab: 1 opens directly on Credits', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen(initialTab: 1)));
    await tester.pumpAndSettle();

    expect(find.byType(CreditsScreen), findsOneWidget);
    expect(find.textContaining('J. W. Bjerk'), findsWidgets);
  });

  testWidgets('Menu -> About reaches the About screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MenuScreen()));
    await tester.pumpAndSettle();

    // The menu is a plain SingleChildScrollView, tall enough (title, sigil,
    // apprenticeship nag, six menu buttons, debug button) to push "About"
    // below the fold in the default test viewport -- scroll it into view
    // first, same as credits_screen_test.dart does for the Settings entry.
    await tester.dragUntilVisible(
      find.text('About'),
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('About'));
    // Bounded pumps, not pumpAndSettle -- the pushed AboutScreen defaults to
    // the README tab, which would start a second real README.md load in
    // this file (see file header). The AppBar/TabBar chrome renders on the
    // route-push transition regardless of whether that body load ever
    // settles, so this only asserts on the chrome.
    await tester.pump(); // starts the push transition
    await tester.pump(const Duration(milliseconds: 300)); // transition duration

    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.text('README'), findsOneWidget);
    expect(find.text('Credits'), findsOneWidget);
  });
}
