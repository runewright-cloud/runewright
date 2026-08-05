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
import 'package:rune_duel/battle/models/effect_kind.dart';
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
}
