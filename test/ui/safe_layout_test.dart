// SPDX-License-Identifier: GPL-3.0-or-later
//
// safe_layout_test.dart — the app-wide safe-inset + narrow-viewport policy
// (lib/ui/safe_layout.dart).
//
// Why this file exists: the app targets Android API 36, and Android 15+ made
// edge-to-edge mandatory — there is no opt-out. The Flutter view is therefore
// laid out BEHIND the system navigation bar, and `MediaQuery.padding.bottom`
// is nonzero on every real device. `Scaffold` does not close that gap on its
// own: it strips the TOP padding off `body` when an `AppBar` is present, but
// it strips the BOTTOM padding only when a `bottomNavigationBar` /
// `persistentFooterButtons` is present. With neither, the body gets the whole
// screen height and whatever sits at its bottom edge is drawn under the nav
// bar. That is the bug playtesters reported as "Android's bottom bar covers
// the controls" — reproduced on a Galaxy S25, which only makes it more
// visible because Samsung defaults to the taller 3-button nav bar rather than
// the gesture pill this was developed against.
//
// So these are geometry tests, not golden tests. Each one injects a bottom
// inset the way a real device reports one and asserts that the bottom-most
// INTERACTIVE control still ends above it. They are written to fail against
// the pre-fix tree: every screen exercised here (except the battle screen,
// which got the isolated 2026-08-10 SafeArea) had an unprotected
// `Scaffold.body`.
//
// The narrow-viewport half is the other reported symptom ("wider than
// appropriate for the screen"). The whole existing widget suite runs at
// flutter_test's default 800x600 surface, which is wider than any phone in
// logical pixels, so nothing here had ever been laid out at phone width.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/dev_flags.dart' show kShowDevSurfaces;
import 'package:rune_duel/battle/models/solo_battle_setup.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/main.dart' show GameScreen;
import 'package:rune_duel/spells/basic_spell_seed.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/about_screen.dart';
import 'package:rune_duel/ui/apprenticeship_screen.dart';
import 'package:rune_duel/ui/avatars/avatar_picker_screen.dart';
import 'package:rune_duel/ui/battle_lobby_screen.dart';
import 'package:rune_duel/ui/commune_screen.dart';
import 'package:rune_duel/ui/credits_screen.dart';
import 'package:rune_duel/ui/duel_host_settings_screen.dart';
import 'package:rune_duel/ui/battle_screen.dart';
import 'package:rune_duel/ui/library_screen.dart';
import 'package:rune_duel/ui/menu_screen.dart';
import 'package:rune_duel/ui/onboarding/onboarding_landing_screen.dart';
import 'package:rune_duel/ui/safe_layout.dart';
import 'package:rune_duel/ui/recipes_screen.dart';
import 'package:rune_duel/ui/settings_screen.dart';
import 'package:rune_duel/ui/solo_practice_settings_screen.dart';
import 'package:rune_duel/ui/spell_art_pack_screen.dart';
import 'package:rune_duel/ui/spell_sound_pack_screen.dart';
import 'package:rune_duel/ui/sync_art_screen.dart';
import 'package:rune_duel/ui/trade_screen.dart';
import 'package:rune_duel/ui/vocabulary_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

/// A deliberately narrow Android phone in LOGICAL pixels.
///
/// 360x740 is the long-standing Android baseline (`sw360dp`) and is what a
/// 1080p phone reports once display scaling is raised a notch or two — which
/// is exactly the configuration the "too wide" report came from. It is well
/// under the 800x600 default surface every other widget test runs at.
const Size kNarrowPhone = Size(360, 740);

/// A Samsung-style 3-button navigation bar, in logical pixels.
///
/// The value is only a stand-in for "some nonzero bottom inset" — no
/// production code may ever hardcode it. 48 is the Android standard nav-bar
/// height and roughly twice the gesture pill, so it is the harder of the two
/// cases to satisfy.
const double kBottomNavInset = 48;

/// Pumps [screen] at a phone-shaped viewport with a system bottom inset and
/// text scaling injected the way a real device reports them.
///
/// Both halves matter: `setSurfaceSize` changes the actual render viewport
/// (so RenderFlex really does overflow), while the `MediaQuery` override is
/// what `SafeArea` reads. Injecting only one of the two would test nothing.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  Size size = kNarrowPhone,
  double bottomInset = 0,
  double textScale = 1.0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: screen,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          padding: EdgeInsets.only(bottom: bottomInset),
          viewPadding: EdgeInsets.only(bottom: bottomInset),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
    ),
  );
}

/// Pumps frames, letting real async work (disk reads, the FFI bridge) run
/// between them.
///
/// Screens here are `FutureBuilder`-heavy and `pumpAndSettle` never returns on
/// several of them (see the repo's other UI tests for the same idiom); a
/// bounded interleave of `runAsync` + `pump` is what actually advances them.
Future<void> settleAsync(WidgetTester tester, {int cycles = 12}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
}

/// Asserts the widget [finder] resolves to ends above the system bottom inset.
///
/// This is the whole point of the file: a control whose painted bottom edge
/// runs past `height - inset` is a control the navigation bar is sitting on.
void expectClearsBottomInset(
  WidgetTester tester,
  Finder finder, {
  Size size = kNarrowPhone,
  double inset = kBottomNavInset,
  required String what,
}) {
  expect(finder, findsWidgets, reason: '$what should be on screen at all');
  final bottom = tester.getRect(finder.first).bottom;
  expect(
    bottom,
    lessThanOrEqualTo(size.height - inset + 0.01),
    reason: '$what ends at y=$bottom, which is inside the bottom '
        '${inset}px system inset on a ${size.width}x${size.height} viewport — '
        'the navigation bar covers it',
  );
}

/// Asserts a [Text] is not being horizontally clipped by its own constraints.
///
/// A single unbreakable word (`RUNEWRIGHT`) does not throw a RenderFlex
/// overflow and does not paint an overflow stripe — the paragraph is simply
/// constrained to the viewport and the glyphs past the edge are clipped
/// silently. The only way to catch it is to compare the laid-out width
/// against the width the same text wants naturally.
void expectTextNotClipped(
  WidgetTester tester,
  Finder textFinder, {
  Size size = kNarrowPhone,
  required String what,
}) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: textFinder, matching: find.byType(RichText)).first,
  );
  final natural = (TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
  )..layout())
      .width;

  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(natural - 0.5),
    reason: '$what is laid out ${paragraph.size.width}px wide but wants '
        '${natural}px — the difference is clipped off the side of the screen',
  );
  final painted = tester.getRect(textFinder.first);
  expect(
    painted.width,
    lessThanOrEqualTo(size.width + 0.5),
    reason: '$what paints ${painted.width}px wide on a ${size.width}px '
        'viewport — it runs off the screen',
  );
}

/// A stand-in for the device's canonical gameplay key. These are layout tests
/// — nothing here derives Wild Magic — but `buildSoloBattleState` requires a
/// real caster identity rather than defaulting to a stub, so one is named here
/// explicitly.
const String _testLocalPubkeyHex =
    '0x00000000000000000000000000000000000000000000000000000000000000a1';

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

  // ── Bottom system inset ────────────────────────────────────────────────

  group('bottom system inset', () {
    testWidgets('MenuScreen keeps its last button reachable above the nav bar',
        (tester) async {
      await pumpScreen(tester, const MenuScreen(), bottomInset: kBottomNavInset);
      await settleAsync(tester);

      // The menu is taller than a phone screen, so the policy that matters is
      // that its scroll viewport stops above the navigation bar...
      expectClearsBottomInset(
        tester,
        find.byType(SingleChildScrollView),
        what: "the main menu's scroll viewport",
      );

      // ...and that scrolling to the end therefore brings the last button
      // fully into reach rather than parking it under the bar.
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -600),
      );
      await tester.pump();
      expectClearsBottomInset(
        tester,
        find.text('Settings'),
        what: 'the last main-menu button, scrolled to the end',
      );
    });

    testWidgets('Rune Craft keeps the Inscribe control clear of the nav bar',
        (tester) async {
      // The headline case. GameScreen's body is a bare Column whose last child
      // is the Step/Run/Inscribe action bar — the three controls the whole
      // inscription flow runs through, pinned to the very bottom of the body.
      await pumpScreen(tester, const GameScreen(), bottomInset: kBottomNavInset);
      await settleAsync(tester);

      expectClearsBottomInset(
        tester,
        find.widgetWithText(ElevatedButton, 'Inscribe'),
        what: "Rune Craft's Inscribe button",
      );
    });

    testWidgets('SettingsScreen keeps its scrollable body clear of the nav bar',
        (tester) async {
      // A screen that never had a SafeArea of its own: a plain ListView body
      // under an AppBar. The list stays scrollable; it just must not extend
      // its viewport under the navigation bar.
      await pumpScreen(tester, const SettingsScreen(), bottomInset: kBottomNavInset);
      await settleAsync(tester);

      expectClearsBottomInset(
        tester,
        find.byType(ListView),
        what: "Settings' scrollable body",
      );
    });

    testWidgets('LibraryScreen keeps its tab body clear of the nav bar',
        (tester) async {
      // The other previously-unprotected shape: a TabBarView body.
      await pumpScreen(tester, const LibraryScreen(), bottomInset: kBottomNavInset);
      await settleAsync(tester);

      expectClearsBottomInset(
        tester,
        find.byType(TabBarView),
        what: "the Library's tab body",
      );
    });

    testWidgets('BattleScreen keeps the spell hand clear of the nav bar',
        (tester) async {
      // Included specifically because this screen received the 2026-08-10
      // Samsung-worded SafeArea. It must keep passing after that comment is
      // replaced by the shared policy — the repair was right, its scoping was
      // what needed to change.
      final chapter = await _seededChapter(tester);
      const config = MatchConfig();
      final setup = buildSoloBattleState(
        chapter,
        config,
        localOwnerPubkeyHex: _testLocalPubkeyHex,
        localId: 'local',
      );

      await pumpScreen(
        tester,
        BattleScreen(
          state: setup.state,
          localPlayerId: 'local',
          chapter: chapter,
          session: SoloBattleSession(state: setup.state),
        ),
        bottomInset: kBottomNavInset,
      );
      await settleAsync(tester, cycles: 40);

      // The battle body is one Column; its last child is the spell hand, so
      // the Column's own bottom edge is the tightest thing to assert on and
      // does not depend on which cards happen to be dealt.
      final body = find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(Column),
      );
      expectClearsBottomInset(
        tester,
        body,
        what: "the battle screen's body column",
      );
    });
  });

  // ── Narrow phone viewport ──────────────────────────────────────────────

  group('narrow phone viewport', () {
    testWidgets('the RUNEWRIGHT title fits a 360dp-wide screen',
        (tester) async {
      // fontSize 48 + letterSpacing 8 over ten unbreakable characters measures
      // ~390dp. It fits the 800px test surface and every wide dev viewport,
      // and is clipped on an actual phone.
      await pumpScreen(tester, const MenuScreen());
      await settleAsync(tester);

      expectTextNotClipped(
        tester,
        find.text('RUNEWRIGHT'),
        what: 'the RUNEWRIGHT title',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('MenuScreen lays out with no overflow', (tester) async {
      await pumpScreen(tester, const MenuScreen());
      await settleAsync(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Rune Craft lays out with no overflow', (tester) async {
      await pumpScreen(tester, const GameScreen());
      await settleAsync(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('BattleScreen lays out with no overflow', (tester) async {
      // The battle body is a Column of fixed-height HUD strips around one
      // Expanded battlefield. Anything in it that grows when the screen gets
      // narrower eats the battlefield's share first and then overflows the
      // Column, which is what pushes the spell hand off the bottom of the
      // screen — the same visible symptom as a missing inset, from the
      // opposite direction.
      final chapter = await _seededChapter(tester);
      final setup = buildSoloBattleState(
        chapter,
        const MatchConfig(),
        localOwnerPubkeyHex: _testLocalPubkeyHex,
        localId: 'local',
      );

      await pumpScreen(
        tester,
        BattleScreen(
          state: setup.state,
          localPlayerId: 'local',
          chapter: chapter,
          session: SoloBattleSession(state: setup.state),
        ),
      );
      await settleAsync(tester, cycles: 40);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onboarding lays out with no overflow', (tester) async {
      await pumpScreen(tester, const OnboardingLandingScreen());
      await settleAsync(tester);
      expect(tester.takeException(), isNull);
    });
  });

  // ── Elevated text scaling ──────────────────────────────────────────────

  group('elevated text scaling', () {
    testWidgets('the RUNEWRIGHT title still fits at 1.3x text scale',
        (tester) async {
      await pumpScreen(tester, const MenuScreen(), textScale: 1.3);
      await settleAsync(tester);

      expectTextNotClipped(
        tester,
        find.text('RUNEWRIGHT'),
        what: 'the RUNEWRIGHT title at 1.3x',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets("Rune Craft's action bar survives 1.3x text scale",
        (tester) async {
      // Three ElevatedButton.icons sharing a Row through Expanded. Enlarged
      // labels are the classic way that shape starts throwing RenderFlex.
      await pumpScreen(tester, const GameScreen(), textScale: 1.3);
      await settleAsync(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MenuScreen survives 1.3x text scale with a nav bar present',
        (tester) async {
      await pumpScreen(
        tester,
        const MenuScreen(),
        bottomInset: kBottomNavInset,
        textScale: 1.3,
      );
      await settleAsync(tester);
      expect(tester.takeException(), isNull);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pump();
      expectClearsBottomInset(
        tester,
        find.text('Settings'),
        what: 'the last main-menu button at 1.3x, scrolled to the end',
      );
    });
  });

  // ── Every simply-constructible screen, swept ───────────────────────────

  // A broad, cheap sweep rather than a bespoke test per screen: pump each
  // screen that needs no constructor arguments at phone width, with a nav bar
  // and at raised text scale, and require that it lays out without throwing.
  // This is what caught the three screens whose bottom action button was
  // pushed off the end of an overflowing Column — a defect that looks
  // identical to a missing inset from the player's side (the button is under
  // or past the bottom edge) but comes from the opposite direction.
  group('narrow-phone sweep', () {
    final screens = <String, Widget Function()>{
      'AvatarPicker': () => const AvatarPickerScreen(),
      'BattleLobby': () => const BattleLobbyScreen(),
      'Commune': () => const CommuneScreen(),
      'Credits': () => const CreditsScreen(),
      'DuelHostSettings': () => const DuelHostSettingsScreen(),
      'Library': () => const LibraryScreen(),
      'Recipes': () => const RecipesScreen(),
      'Settings': () => const SettingsScreen(),
      'SoloPracticeSettings': () => const SoloPracticeSettingsScreen(),
      'SpellArtPack': () => const SpellArtPackScreen(),
      'SpellSoundPack': () => const SpellSoundPackScreen(),
      'SyncArt': () => const SyncArtScreen(),
      'Trade': () => const TradeScreen(),
      'Vocabulary': () => const VocabularyScreen(),
      'About': () => const AboutScreen(),
      'Apprenticeship': () => const ApprenticeshipScreen(),
    };

    for (final entry in screens.entries) {
      for (final scale in <double>[1.0, 1.3]) {
        testWidgets('${entry.key} lays out at 360dp @${scale}x', (tester) async {
          await pumpScreen(
            tester,
            entry.value(),
            bottomInset: kBottomNavInset,
            textScale: scale,
          );
          await settleAsync(tester);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  // ── Primary actions on the screens converted to scrolling ─────────────

  // The sweep above only asserts "nothing threw". That is not enough for the
  // three screens whose overflowing Column was converted to a scroll view: once
  // content scrolls it can no longer overflow, so a sweep entry would go green
  // even if the button the screen exists for had scrolled out of reach. These
  // assert the property that actually matters — the primary action is on
  // screen, above the navigation bar.
  group('converted screens keep their primary action reachable', () {
    testWidgets('Host Settings pins HOST above the nav bar', (tester) async {
      await pumpScreen(
        tester,
        const DuelHostSettingsScreen(),
        bottomInset: kBottomNavInset,
      );
      await settleAsync(tester);

      // Pinned below the scroll view, so it must be visible without scrolling.
      expectClearsBottomInset(
        tester,
        find.text('HOST'),
        what: 'the HOST button',
      );
    });

    testWidgets('Solo Practice pins READY above the nav bar', (tester) async {
      await pumpScreen(
        tester,
        const SoloPracticeSettingsScreen(),
        bottomInset: kBottomNavInset,
      );
      await settleAsync(tester);

      expectClearsBottomInset(
        tester,
        find.text('READY'),
        what: 'the READY button',
      );
    });

    testWidgets('the lobby can reach SOLO PRACTICE by scrolling',
        (tester) async {
      // This one IS inside the scroll view (the idle section scrolls as a
      // whole), so reachability is the honest assertion: scroll to the end,
      // then require it to sit clear of the bar.
      await pumpScreen(
        tester,
        const BattleLobbyScreen(),
        bottomInset: kBottomNavInset,
      );
      await settleAsync(tester);

      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -400),
      );
      await tester.pump();

      expectClearsBottomInset(
        tester,
        find.text('SOLO PRACTICE'),
        what: 'the lobby SOLO PRACTICE button, scrolled to the end',
      );
    });
  });

  // ── Keyboard ───────────────────────────────────────────────────────────

  group('onscreen keyboard', () {
    // System-bar safety must not turn into the keyboard covering a form field.
    // These two compose only because SafeArea defaults to
    // maintainBottomViewPadding: false: when the IME opens, Android collapses
    // padding.bottom to zero (the bar is behind the keyboard) and reports the
    // keyboard in viewInsets, which Scaffold.resizeToAvoidBottomInset consumes.
    // Had this wrapper pinned the bar's height instead, the field would float a
    // nav-bar height above the keyboard; had it added fixed padding, the field
    // would be pushed under it.
    Widget formScreen() => Scaffold(
          appBar: AppBar(title: const Text('Form')),
          body: SafeScreenBody(
            child: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                TextField(
                  key: const Key('field'),
                  decoration: const InputDecoration(hintText: 'x'),
                ),
              ],
            ),
          ),
        );

    testWidgets('a bottom field sits above the nav bar with the IME closed',
        (tester) async {
      await pumpScreen(
        tester,
        formScreen(),
        bottomInset: kBottomNavInset,
      );
      expectClearsBottomInset(
        tester,
        find.byKey(const Key('field')),
        what: 'a bottom-anchored text field',
      );
    });

    testWidgets('the IME does not cover that field, and no gap is left',
        (tester) async {
      const keyboard = 300.0;
      await tester.binding.setSurfaceSize(kNarrowPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: formScreen(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: kNarrowPhone,
              // What Android reports with the IME up: the system bar is behind
              // the keyboard, so padding.bottom goes to zero.
              padding: EdgeInsets.zero,
              viewPadding: const EdgeInsets.only(bottom: kBottomNavInset),
              viewInsets: const EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getRect(find.byKey(const Key('field'))).bottom,
        closeTo(kNarrowPhone.height - keyboard, 0.5),
        reason: 'the field should sit exactly on top of the keyboard — lower '
            'means the IME covers it, higher means a nav-bar-sized gap is '
            'being held open behind the keyboard',
      );
    });
  });

  // ── The debug read-out follows the dev flag ────────────────────────────

  testWidgets('the window-metrics card is hidden while kShowDevSurfaces is off',
      (tester) async {
    // The diagnostic added alongside this repair is gated the same way as every
    // other dev surface in the app. Asserted rather than assumed, because it is
    // the one piece of this patch that would be embarrassing to ship visible.
    await pumpScreen(tester, const SettingsScreen(), bottomInset: kBottomNavInset);
    await settleAsync(tester);

    expect(
      find.text('DEBUG: Window metrics'),
      kShowDevSurfaces ? findsOneWidget : findsNothing,
    );
  });

  // ── The policy itself ──────────────────────────────────────────────────

  group('SafeScreenBody', () {
    testWidgets('always insets the bottom, whatever the screen', (tester) async {
      // The one rule nothing may opt out of. Asserted directly so it survives
      // even if every screen below is rewritten.
      await pumpScreen(
        tester,
        const Scaffold(
          body: SafeScreenBody(
            child: SizedBox.expand(child: Placeholder()),
          ),
        ),
        bottomInset: kBottomNavInset,
      );

      expectClearsBottomInset(
        tester,
        find.byType(Placeholder),
        what: 'a SafeScreenBody child',
      );
    });

    testWidgets('applies each system inset exactly once', (tester) async {
      // The duplication guard. Counting the Padding widgets SafeArea inserts is
      // stricter than "the body clears the bar": a screen whose inset was
      // applied twice would still clear the bar, just with a doubled gap.
      const topInset = 40.0;
      await tester.binding.setSurfaceSize(kNarrowPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('T')),
            body: const SafeScreenBody(
              child: SizedBox.expand(child: Placeholder()),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: kNarrowPhone,
              padding: const EdgeInsets.only(
                top: topInset,
                bottom: kBottomNavInset,
              ),
              viewPadding: const EdgeInsets.only(
                top: topInset,
                bottom: kBottomNavInset,
              ),
            ),
            child: child!,
          ),
        ),
      );
      await tester.pump();

      final applied = <EdgeInsets>[
        for (final el in find
            .descendant(
              of: find.byType(SafeScreenBody),
              matching: find.byType(Padding),
            )
            .evaluate())
          if (((el.widget as Padding).padding.resolve(TextDirection.ltr))
                  .bottom ==
              kBottomNavInset)
            (el.widget as Padding).padding.resolve(TextDirection.ltr),
      ];
      expect(
        applied,
        hasLength(1),
        reason: 'the bottom inset should be applied by exactly one Padding, '
            'not stacked by Scaffold + SafeArea + SafeScreenBody together',
      );
      expect(
        applied.single.top,
        0,
        reason: 'the AppBar already consumed the top inset, so SafeScreenBody '
            'must contribute nothing there',
      );
    });

    testWidgets('does not double-apply the top inset under an AppBar',
        (tester) async {
      // Scaffold passes removeTopPadding: appBar != null to its body, so under
      // an AppBar MediaQuery.padding.top is already zero and SafeArea's top
      // edge is a no-op. This pins that: the body starts at the app bar's
      // bottom, not a status-bar height below it. It is the measurement the
      // decision to drop SafeScreenBody's hasAppBar flag rests on, so it must
      // keep holding.
      const topInset = 40.0;
      await tester.binding.setSurfaceSize(kNarrowPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('T')),
            body: const SafeScreenBody(
              child: SizedBox.expand(child: Placeholder()),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: kNarrowPhone,
              padding: const EdgeInsets.only(top: topInset),
              viewPadding: const EdgeInsets.only(top: topInset),
            ),
            child: child!,
          ),
        ),
      );
      await tester.pump();

      final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
      expect(
        tester.getRect(find.byType(Placeholder)).top,
        closeTo(appBarBottom, 0.5),
        reason: 'the body should start where the app bar ends, not a '
            'status-bar height below it',
      );
    });
  });
}

/// A chapter of real, on-disk spells — the minimum a [BattleScreen] needs
/// before `TurnLoop.startBattle` will deal a hand (an empty chapter trips
/// spell_draw.dart's `chapter.isNotEmpty` assertion and the screen renders its
/// blocking-error page instead of the battle UI).
Future<ChapterAsset> _seededChapter(WidgetTester tester) async {
  late List<SpellAsset> spells;
  await tester.runAsync(() async {
    await seedBasicSpells();
    spells = await SpellAsset.loadAll();
  });
  return ChapterAsset(
    id: 'safe-layout-test',
    name: 'Test Chapter',
    createdAt: DateTime.utc(2026, 8, 30),
    entries: [
      for (final s in spells.take(3)) ChapterEntry(spellId: s.id),
    ],
  );
}
