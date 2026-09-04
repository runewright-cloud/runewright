// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_screen_conveyor_prompt_test.dart — guards the cast-time push-direction
// prompt gate (spellNeedsConveyorDirection, the pure predicate _onCast wraps).
//
// The prompt exists for Air-flavor tileModification, which resolves to a
// ConveyorTile. Summon-mode spells bypass EffectResolver/EffectApplicator
// entirely (TurnLoop._applySpell's `if (spell.isSummon)` early return), so they
// must never be prompted no matter what their formula's triplets decode to —
// the bundled Basic Windhound is a real spell that trips exactly that case.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/spells/incantation_display.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/battle_screen.dart';

void main() {
  SpellAsset spell({
    required List<String> formula,
    bool isSummon = false,
  }) =>
      SpellAsset(
        id: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        tier: 24,
        t: 3,
        ownerPubkeyHex: '',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: 'Test Spell',
        commitmentHex: '',
        spellHashHex: '',
        formula: formula,
        isSummon: isSummon,
      );

  // The shipped Basic Windhound's formula, verbatim from
  // assets/basic_spells/basic_windhound.json.
  const windhoundFormula = [
    'air', 'water', 'earth', //
    'air', 'water', 'fire', //
    'air', 'earth', 'water', //
    'fire', 'air', 'earth', //
  ];

  test('Windhound formula really does contain an Air tileModification', () {
    // Not a tautology with the test below: this is the precondition that makes
    // the summon case a real regression rather than a vacuous pass. If the
    // effect-pair table ever changes so this no longer holds, the guard test
    // stops proving anything and this one fails loudly first.
    expect(
      formulaEffects(windhoundFormula).any(
        (e) =>
            e.kind == EffectKind.tileModification &&
            e.affinity == SpellAffinity.air,
      ),
      isTrue,
    );
  });

  test('summon-mode spell is never prompted for a conveyor direction', () {
    expect(
      spellNeedsConveyorDirection(
        spell(formula: windhoundFormula, isSummon: true),
      ),
      isFalse,
    );
  });

  test('same formula as an incantation still prompts', () {
    expect(
      spellNeedsConveyorDirection(
        spell(formula: windhoundFormula, isSummon: false),
      ),
      isTrue,
    );
  });

  test('incantation with no Air tileModification does not prompt', () {
    expect(
      spellNeedsConveyorDirection(spell(formula: const ['fire', 'fire', 'fire'])),
      isFalse,
    );
  });

  // ── Slice E: the prompt asks under the match's grammar ────────────────────
  //
  // The prompt exists so the caster can pick a push direction the cast will
  // actually use. Under a mutable leyline the same stored formula may cut
  // differently, mean something else, or mean nothing — and prompting for a
  // direction a noise formula will never consume is the same bug M4.19 fixed
  // for summons, pointed at a leyline instead of a wire field.

  group('under a mutable leyline', () {
    LeylineConfig rivendell(int length) => LeylineConfig.mutable(
          communitySeed: 'rivendell',
          formulaLength: length,
        );

    test('a structurally void spell never prompts', () {
      // Three elements is a complete formula ordinarily and NOTHING at length
      // 4 — so there is no effect of any kind, let alone a conveyor.
      final windhound = spell(formula: windhoundFormula);
      // The same spell prompts under the ordinary grammar…
      expect(spellNeedsConveyorDirection(windhound), isTrue);
      // …and a too-short one does not, under either.
      final short = spell(formula: const ['air', 'air', 'air']);
      expect(
        spellNeedsConveyorDirection(
          short,
          lexicon: IncantationLexicon.of(rivendell(4)),
        ),
        isFalse,
      );
    });

    test('the question is asked through the active lexicon', () {
      // Whatever the mutable answer is, it must equal what the display model
      // says — never what the ordinary table says. Derived rather than
      // hardcoded: the codebook is pinned by the Slice B corpus, and
      // duplicating one of its entries here would be a literal that has to
      // move whenever the corpus does.
      final s = spell(formula: windhoundFormula);
      for (final length in const [4, 5, 6]) {
        final lexicon = IncantationLexicon.of(rivendell(length));
        final expected = incantationViewsFor(s.formula, lexicon).any(
          (v) =>
              v.kind == EffectKind.tileModification &&
              v.affinity == SpellAffinity.air,
        );
        expect(
          spellNeedsConveyorDirection(s, lexicon: lexicon),
          expected,
          reason: 'length $length',
        );
      }
    });

    test('summon mode still wins over any leyline', () {
      // The M4.19 guard is unconditional and stays that way: a summon never
      // reaches EffectResolver, whatever its elements happen to mean.
      expect(
        spellNeedsConveyorDirection(
          spell(formula: windhoundFormula, isSummon: true),
          lexicon: IncantationLexicon.of(rivendell(4)),
        ),
        isFalse,
      );
    });
  });
}
