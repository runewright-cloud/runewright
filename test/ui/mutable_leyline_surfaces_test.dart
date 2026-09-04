// SPDX-License-Identifier: GPL-3.0-or-later
//
// mutable_leyline_surfaces_test.dart — Mutable Leylines Slice E: the reachable
// UI (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E).
//
// Where `incantation_display_test.dart` pins the interpretation, this pins the
// SURFACES: that a player can actually select a Mutable leyline, that the
// selection reaches the same lexicon battle resolution builds, that the spell
// card's rules box shows the mutable reading rather than the ordinary one, and
// — most importantly — that none of the above disturbs an ordinary card.
//
// The card here is driven through `activeWildMagicContext`, which is how the
// real app already carries the leyline to a card: the library primes it from
// the device's own setting and `BattleScreen` overrides it with
// `state.config.leyline` for the duration of a duel. Slice E adds no second
// channel; it reads the one that was already there.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/spells/incantation_display.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';
import 'package:rune_duel/ui/widgets/leyline_picker.dart';

import '../support/wild_magic_fixture.dart';

/// A caster key that fires no wild magic for the shared fixture, so these
/// tests observe the rules box rather than a foil animation. (A foil card
/// never settles — see spell_card_wild_magic_test.dart's header.)
const String _quietCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000000';

LeylineConfig _rivendell(int length) =>
    LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: length);

/// Points every card in the test at [leyline], as the app does.
void _viewUnder(LeylineConfig leyline) {
  debugClearWildMagicPreviewCache();
  activeWildMagicContext.value = WildMagicPreviewContext(
    casterPubkeyHex: _quietCaster,
    leyline: leyline,
  );
}

/// A spell whose stored formula is one complete length-4 formula that the
/// Slice B corpus pins as MEANINGFUL under `rivendell 4`, and which is also
/// four ordinary elements (one triplet plus a residual).
///
/// Its ordinary and mutable readings happen to COINCIDE (both "Firey Terrain
/// Sculpting") — the codebook is a permutation of the same sixteen effects, so
/// some keys land back where they started. That makes it the right fixture for
/// "ordinary cards are unchanged" and the WRONG one for "the mutable reading
/// is shown", which uses [_noiseSpell] instead. Do not swap them.
SpellAsset _fourElementSpell() => fixtureSpell(
      name: 'Fixture',
      // affinity fire, then the corpus's meaningful length-4 tail.
      formula: const ['fire', 'earth', 'water', 'fire'],
    );

/// A spell that reads as a real effect ordinarily ("Firey Cloud") and as
/// NOISE under `rivendell 4` — the corpus's pinned length-4 noise tail behind
/// a fire affinity.
///
/// This is the `battle says Noise / UI says Glacier` failure mode in one
/// fixture: before Slice E the card printed "Firey Cloud" for a cast that
/// would do nothing at all.
SpellAsset _noiseSpell() => fixtureSpell(
      name: 'Fixture',
      formula: const ['fire', 'water', 'fire', 'fire'],
    );

/// A three-element spell: a complete formula ordinarily, structurally VOID
/// under every mutable length.
SpellAsset _threeElementSpell() =>
    fixtureSpell(name: 'Fixture', formula: const ['fire', 'fire', 'fire']);

Future<void> _pumpCard(WidgetTester tester, SpellAsset spell) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 520,
            child: SpellCardWidget(spell: spell),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => _viewUnder(LeylineConfig.ordinaryDefault));
  tearDown(() {
    activeWildMagicContext.value = const WildMagicPreviewContext();
    debugClearWildMagicPreviewCache();
  });

  // ── Mutable configuration activation ──────────────────────────────────────

  group('activation', () {
    /// Pumps the picker with live state so a tap's effect is observable as a
    /// config rather than merely reported.
    Future<LeylineConfig Function()> pumpPicker(WidgetTester tester) async {
      var config = LeylineConfig.ordinaryDefault;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: SingleChildScrollView(
                child: LeylinePicker(
                  communitySeed: 'rivendell',
                  value: config,
                  onChanged: (c) => setState(() => config = c),
                ),
              ),
            ),
          ),
        ),
      );
      return () => config;
    }

    testWidgets('starts ordinary and stays ordinary until asked', (t) async {
      final config = await pumpPicker(t);
      expect(config().formulaLength, LeylineConfig.kOrdinaryFormulaLength);
      expect(IncantationLexicon.of(config()).isMutable, isFalse);

      // Tapping the already-selected option must not mint a new config.
      await t.tap(find.byKey(const Key('leyline-ordinary')));
      await t.pump();
      expect(IncantationLexicon.of(config()).isMutable, isFalse);
      expect(find.byKey(const Key('leyline-formula-length')), findsNothing);
    });

    testWidgets('a player can select a Mutable leyline', (t) async {
      final config = await pumpPicker(t);
      await t.tap(find.byKey(const Key('leyline-mutable')));
      await t.pump();

      final chosen = config();
      expect(IncantationLexicon.of(chosen).isMutable, isTrue);
      expect(chosen.formulaLength,
          LeylinePicker.kInitialMutableFormulaLength);
      expect(chosen.normalizedSeed, 'rivendell');
      // The canonical config is what travels, hash included.
      expect(chosen.leylineConfigHash, hasLength(64));
      // And the grammar controls appear with it.
      expect(find.byKey(const Key('leyline-formula-length')), findsOneWidget);
      expect(find.byKey(const Key('leyline-noise-density')), findsOneWidget);
    });

    testWidgets('formula length is selectable across the ratified range',
        (t) async {
      final config = await pumpPicker(t);
      await t.tap(find.byKey(const Key('leyline-mutable')));
      await t.pump();

      // Walk up to the maximum, one tap at a time, and confirm the config
      // tracks — this is the number that decides how a trajectory is cut.
      for (var expected = LeylineConfig.kMinMutableFormulaLength + 1;
          expected <= LeylineConfig.kMaxMutableFormulaLength;
          expected++) {
        await t.tap(find.descendant(
          of: find.byKey(const Key('leyline-formula-length')),
          matching: find.byIcon(Icons.add),
        ));
        await t.pump();
        expect(config().formulaLength, expected);
      }
      // The stepper cannot leave the range the config would refuse.
      await t.tap(find.descendant(
        of: find.byKey(const Key('leyline-formula-length')),
        matching: find.byIcon(Icons.add),
      ));
      await t.pump();
      expect(config().formulaLength, LeylineConfig.kMaxMutableFormulaLength);
    });

    testWidgets('switching back to Ordinary restores the canonical config',
        (t) async {
      final config = await pumpPicker(t);
      await t.tap(find.byKey(const Key('leyline-mutable')));
      await t.pump();
      await t.tap(find.byKey(const Key('leyline-ordinary')));
      await t.pump();

      // Not merely "not mutable" — the ORDINARY canonical spelling, which is
      // the only one whose hash matches ordinary play.
      expect(config().formulaLength, LeylineConfig.kOrdinaryFormulaLength);
      expect(config().noiseDensityPermille, 0);
      expect(config().leylineConfigHash,
          LeylineConfig.ordinary('rivendell').leylineConfigHash);
    });

    testWidgets('the selected config reaches the battle lexicon', (t) async {
      // The whole point of the activation: what the picker emits is what
      // `DeterministicResolution` will build its lexicon from. Asserted
      // through `MatchConfig`, which is the object that actually carries it.
      final config = await pumpPicker(t);
      await t.tap(find.byKey(const Key('leyline-mutable')));
      await t.pump();
      await t.tap(find.descendant(
        of: find.byKey(const Key('leyline-formula-length')),
        matching: find.byIcon(Icons.add),
      ));
      await t.pump();

      final match = MatchConfig(leyline: config());
      final lexicon = IncantationLexicon.of(match.leyline);
      expect(lexicon.isMutable, isTrue);
      expect(lexicon.formulaLength, 5);
      expect(match.leyline.leylineConfigHash,
          _rivendell(5).leylineConfigHash);
      // Round-trips the wire codec unchanged, so host and guest agree.
      expect(
        LeylineConfig.fromMatchConfigJson(match.toJson()),
        match.leyline,
      );
    });

    testWidgets('the selected-option inference agrees with the lexicon',
        (t) async {
      // `LeylinePicker` decides which option is highlighted from
      // `formulaLength`, because reading the config's mutable flag is
      // forbidden to UI (posture test) and building a lexicon per frame is too
      // expensive. That inference is exact only while the ordinary length and
      // the mutable range stay disjoint. Pinned over every canonical config
      // this build can construct, so a future range change fails here rather
      // than shipping a picker that highlights the wrong option.
      final configs = <LeylineConfig>[
        LeylineConfig.ordinaryDefault,
        LeylineConfig.ordinary('rivendell'),
        for (var n = LeylineConfig.kMinMutableFormulaLength;
            n <= LeylineConfig.kMaxMutableFormulaLength;
            n++)
          _rivendell(n),
      ];
      for (final config in configs) {
        final inferred =
            config.formulaLength != LeylineConfig.kOrdinaryFormulaLength;
        expect(inferred, IncantationLexicon.of(config).isMutable,
            reason: '$config');
      }

      // And the picker really does highlight by that inference: a mutable
      // config shows the grammar controls, an ordinary one does not.
      for (final config in configs) {
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LeylinePicker(
                communitySeed: 'rivendell',
                value: config,
                onChanged: (_) {},
              ),
            ),
          ),
        ));
        await t.pump();
        expect(
          find.byKey(const Key('leyline-formula-length')),
          IncantationLexicon.of(config).isMutable
              ? findsOneWidget
              : findsNothing,
          reason: '$config',
        );
      }
    });

    testWidgets('the noise value renders on one line', (t) async {
      // Regression, from the on-screen pass: `IntStepperRow`'s value box is a
      // fixed 48px sized for the one- and two-digit values every other caller
      // has, and noise density is the first three-digit one. At 500 the text
      // wrapped and the control read as "50" over "0".
      //
      // Asserted by HEIGHT rather than by the width constant, so it keeps
      // testing the thing that actually broke: a wrapped value is two lines
      // tall. A future font-size or padding change that reintroduces the wrap
      // fails here even if the width is still nominally "wide enough".
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LeylinePicker(
              communitySeed: 'rivendell',
              value: _rivendell(4),
              onChanged: (_) {},
            ),
          ),
        ),
      ));
      await t.pump();

      final value = find.descendant(
        of: find.byKey(const Key('leyline-noise-density')),
        matching: find.text('500'),
      );
      expect(value, findsOneWidget);
      final oneLine = t.getSize(find.descendant(
        of: find.byKey(const Key('leyline-formula-length')),
        matching: find.text('4'),
      ));
      expect(t.getSize(value).height, oneLine.height,
          reason: 'the three-digit noise value is taller than the '
              'single-digit formula length — it has wrapped');
    });

    testWidgets('the two leyline options are the same height', (t) async {
      // Also from the on-screen pass. The captions wrap to different line
      // counts on a narrow phone, and two ragged boxes stop reading as one
      // either/or choice. 360px is narrower than the narrowest device this
      // ships to, so the wrap is guaranteed.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: LeylinePicker(
                communitySeed: 'rivendell',
                value: LeylineConfig.ordinary('rivendell'),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ));
      await t.pump();

      final ordinary = t.getSize(find.byKey(const Key('leyline-ordinary')));
      final mutable = t.getSize(find.byKey(const Key('leyline-mutable')));
      expect(ordinary.height, mutable.height);
      // And the captions really do wrap differently at this width, so the
      // assertion above is not passing vacuously.
      expect(
        t.getSize(find.text('Three elements to a formula. The standard '
            'grammar.')).height,
        lessThan(t
            .getSize(find.text('A rekeyed grammar. Longer formulas, and some '
                'of them mean nothing at all.'))
            .height),
      );
    });

    testWidgets('the default MatchConfig is still ordinary', (t) async {
      // Ordinary invariance at the config layer: nothing about adding a picker
      // may change what a match is when nobody touches it.
      const match = MatchConfig();
      expect(IncantationLexicon.of(match.leyline).isMutable, isFalse);
      expect(match.leyline.formulaLength,
          LeylineConfig.kOrdinaryFormulaLength);
    });
  });

  // ── The spell card's rules box ────────────────────────────────────────────

  group('spell card rules box', () {
    testWidgets('ordinary cards are unchanged', (t) async {
      // The regression that matters. A four-element spell reads ordinarily as
      // one triplet plus a discarded residual, exactly as it always has.
      await _pumpCard(t, _fourElementSpell());
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();

      final expected = formulaEffects(_fourElementSpell().formula).single;
      expect(find.textContaining(expected.name, findRichText: true),
          findsWidgets);
      expect(find.textContaining(kIncantationNoiseLabel, findRichText: true),
          findsNothing);
      // No leyline caption on an ordinary card — there is only one ordinary
      // grammar, and captioning every card with it would be noise.
      expect(find.textContaining('elements to a formula'), findsNothing);
    });

    testWidgets('a mutable card shows the mutable reading, not the ordinary one',
        (t) async {
      // The headline failure mode. This fixture's two readings genuinely
      // differ — "Firey Cloud" ordinarily, Noise under `rivendell 4` — so the
      // assertions below cannot pass by coincidence. The guard at the top
      // fails loudly if a future codebook change makes them agree, rather than
      // letting this test quietly stop testing anything.
      final spell = _noiseSpell();
      final ordinary = formulaEffects(spell.formula).single;
      final views = incantationViewsFor(
          spell.formula, IncantationLexicon.of(_rivendell(4)));
      expect(views, hasLength(1));
      expect(views.single.name, kIncantationNoiseLabel);
      expect(ordinary.name, isNot(views.single.name),
          reason: 'the fixture must have two DIFFERENT readings or this test '
              'proves nothing — pick another corpus key rather than '
              'weakening the assertions below');

      _viewUnder(_rivendell(4));
      await _pumpCard(t, spell);
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();

      // The mutable reading is shown, as a real word rather than a blank.
      expect(find.textContaining(kIncantationNoiseLabel, findRichText: true),
          findsWidgets);
      // The ordinary reading is nowhere on the card.
      expect(find.textContaining(ordinary.name, findRichText: true),
          findsNothing,
          reason: 'the card is still naming the ordinary effect for a formula '
              'the engine will resolve as noise');
      // The grammar this reading was taken under is named.
      expect(find.textContaining('rivendell 4'), findsWidgets);
    });

    testWidgets('the same card reads ordinarily with no leyline in force',
        (t) async {
      // The other direction: nothing about the noise fixture is intrinsically
      // inert. Out of a mutable match it is a Firey Cloud, and the library
      // must keep saying so.
      final spell = _noiseSpell();
      await _pumpCard(t, spell);
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();
      expect(
        find.textContaining(formulaEffects(spell.formula).single.name,
            findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining(kIncantationNoiseLabel, findRichText: true),
          findsNothing);
    });

    testWidgets('a mounted card re-reads when the leyline changes', (t) async {
      // `activeWildMagicContext` is the app's live leyline channel — the
      // library primes it, BattleScreen overrides it for a duel and restores
      // it after. A card left open across that transition must not keep
      // claiming the old grammar's reading.
      //
      // This also pins the card's lexicon MEMO. Deriving a codebook costs
      // ~1040 SHA-256s, so the card memoizes it — keyed on the whole canonical
      // LeylineConfig. A memo that failed to invalidate would freeze the card
      // on whichever leyline it first painted under, which is exactly the lie
      // this slice exists to prevent, arriving one frame late.
      final spell = _noiseSpell();
      final ordinaryName = formulaEffects(spell.formula).single.name;

      await _pumpCard(t, spell);
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();
      expect(find.textContaining(ordinaryName, findRichText: true),
          findsWidgets);

      // A duel begins under a mutable leyline, with the card still open.
      _viewUnder(_rivendell(4));
      await t.pumpAndSettle();
      expect(find.textContaining(kIncantationNoiseLabel, findRichText: true),
          findsWidgets);
      expect(find.textContaining(ordinaryName, findRichText: true),
          findsNothing);

      // …and ends. The card goes back to the ordinary reading.
      _viewUnder(LeylineConfig.ordinaryDefault);
      await t.pumpAndSettle();
      expect(find.textContaining(ordinaryName, findRichText: true),
          findsWidgets);
      expect(find.textContaining(kIncantationNoiseLabel, findRichText: true),
          findsNothing);
    });

    testWidgets('a structurally void spell says so, and claims nothing',
        (t) async {
      // The high-risk gate. Three elements is a complete ordinary formula and
      // NOTHING under length 4 — the card must not print the ordinary effect
      // it would have had, and must not merely go blank either.
      _viewUnder(_rivendell(4));
      await _pumpCard(t, _threeElementSpell());
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();

      final wouldHaveBeen =
          formulaEffects(_threeElementSpell().formula).single.name;
      expect(find.textContaining(wouldHaveBeen, findRichText: true),
          findsNothing,
          reason: 'the ordinary reading must not survive as a fallback');
      expect(find.textContaining('No complete formula'), findsOneWidget);
      // Named concretely enough that a player can act on it.
      expect(find.textContaining('rivendell 4'), findsOneWidget);
    });

    testWidgets('the same void spell reads normally under an ordinary leyline',
        (t) async {
      // The other half of the void gate: the spell is not broken, the leyline
      // is. Its library identity is untouched.
      await _pumpCard(t, _threeElementSpell());
      await t.tap(find.byType(SpellCardWidget));
      await t.pumpAndSettle();
      expect(
        find.textContaining(
          formulaEffects(_threeElementSpell().formula).single.name,
          findRichText: true,
        ),
        findsWidgets,
      );
      expect(find.textContaining('No complete formula'), findsNothing);
    });
  });

  // ── Heraldic identity stays leyline-independent ───────────────────────────

  group('heraldic identity', () {
    test('frame colours do not move with the leyline', () {
      // The Slice E ruling: a card's picture is IDENTITY and must not re-skin
      // itself per duel. These helpers take no lexicon by design — if one ever
      // grows a leyline parameter, this test is the place that argues.
      final spell = _fourElementSpell();
      final shares = frameColorShares(spell.formula);
      final symbols = elementSymbolsFor(spell.formula, spell.t);

      for (final leyline in [
        LeylineConfig.ordinaryDefault,
        _rivendell(4),
        _rivendell(5),
        _rivendell(6),
      ]) {
        _viewUnder(leyline);
        expect(frameColorShares(spell.formula), shares);
        expect(elementSymbolsFor(spell.formula, spell.t), symbols);
      }
    });

    test('a void spell keeps its heraldry', () {
      // Structurally void says nothing about identity: the trajectory is still
      // the trajectory, and the card must still be recognisable as itself.
      final spell = _threeElementSpell();
      expect(frameColorShares(spell.formula), isNotEmpty);
      expect(elementSymbolsFor(spell.formula, spell.t), hasLength(spell.t));
    });
  });
}
