// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_recall_cost_test.dart — the recall multiplier where it meets the mana
// ledger (VOCAL_RECALL_PLAN.md §3/§4/§6).
//
// incantation_recall_test.dart owns the arithmetic. This file owns the three
// things that can only go wrong at the engine seam:
//
//   1. the recall actually reaches the cost, and a clean recital is cheaper
//      than a blank one by the ratified amount;
//   2. a shortfall FIZZLES AND REFUNDS in sorcerer mode but still FORFEITS in
//      wizard mode — the one place this change deliberately weakens a peer
//      verification gate, so the wizard half has to be pinned; and
//   3. previewSpellCost quotes the honest base price now, not a worst case.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/spells/spell_asset.dart';

void main() {
  // A 3-zone formula: one complete triplet, so the expected recital is the
  // opener plus fire/air/water.
  SpellAsset spell({
    int segmentCount = 10,
    List<String> formula = const ['fire', 'air', 'water'],
    bool isSummon = false,
  }) => SpellAsset(
    id: 'spell1',
    createdAt: DateTime.utc(2026, 8, 4),
    tier: 12,
    t: 1,
    ownerPubkeyHex: '0x${'0' * 64}',
    manaCost: 0,
    segmentCount: segmentCount,
    dotCount: 0,
    initialGrid: const [],
    proofBytes: Uint8List.fromList([1, 2, 3]),
    name: 'spell1',
    commitmentHex: '0x${'01' * 32}',
    spellHashHex: '',
    formula: formula,
    isSummon: isSummon,
  );

  ({BattleState state, TurnLoop loop, WizardAvatar local}) setup({
    int mana = 200,
    bool sorcererMode = true,
  }) {
    final bf = Battlefield(radius: 6);
    const id = 'local';
    final local = WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: mana,
      maxMana: 400,
      position: const HexCoord(0, 3),
      teamId: 'solo',
      baseSpellRange: 3,
    );
    bf.occupancy[id] = local.position;
    final state = BattleState(
      config: MatchConfig(
        playerHp: 24,
        gridRadius: 6,
        maxPlayers: 1,
        sorcererMode: sorcererMode,
      ),
      avatars: [local],
      teams: [const Team(id: 'solo', playerIds: [id])],
      battlefield: bf,
    );
    return (
      state: state,
      loop: TurnLoop(
        state: state,
        session: SoloBattleSession(state: state),
        localPlayerId: id,
        isSorcererMode: sorcererMode,
      ),
      local: local,
    );
  }

  const perfect = IncantationRecall(
    opener: VocalSlot.openerGeneral,
    elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
  );

  Future<int> manaSpent(
    TurnLoop loop,
    WizardAvatar local,
    SpellAsset s,
    IncantationRecall? recall,
  ) async {
    final before = local.mana;
    await loop.runTurn(
      TurnInput(
        action: SpellCastAction(
          spell: s,
          targetHex: local.position,
          recall: recall,
        ),
      ),
    );
    return before - local.mana;
  }

  group('the recall reaches the mana ledger', () {
    test('a perfect recital costs less than a blank one', () async {
      final a = setup();
      final clean = await manaSpent(a.loop, a.local, spell(), perfect);

      final b = setup();
      final blank =
          await manaSpent(b.loop, b.local, spell(), IncantationRecall.silent);

      expect(clean, lessThan(blank));
    });

    test('a perfect recital lands on the ratified -26.3%', () async {
      final a = setup();
      final clean = await manaSpent(a.loop, a.local, spell(), perfect);

      final b = setup();
      final base = await manaSpent(b.loop, b.local, spell(), null);

      expect(clean / base, closeTo(0.737, 0.02));
    });

    test('a wrong opener costs more than a right one', () async {
      final a = setup();
      final right = await manaSpent(a.loop, a.local, spell(), perfect);

      final b = setup();
      final wrong = await manaSpent(
        b.loop,
        b.local,
        spell(),
        const IncantationRecall(
          opener: VocalSlot.openerSummon, // the spell is not a summon
          elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
        ),
      );

      expect(wrong, greaterThan(right));
    });

    test('a summon expects the summon opener', () async {
      final a = setup();
      final matched = await manaSpent(
        a.loop,
        a.local,
        spell(isSummon: true),
        const IncantationRecall(
          opener: VocalSlot.openerSummon,
          elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
        ),
      );

      final b = setup();
      final mismatched =
          await manaSpent(b.loop, b.local, spell(isSummon: true), perfect);

      expect(matched, lessThan(mismatched));
    });

    test('wizard mode ignores the recall entirely', () async {
      final a = setup(sorcererMode: false);
      final withRecall = await manaSpent(a.loop, a.local, spell(), perfect);

      final b = setup(sorcererMode: false);
      final without = await manaSpent(b.loop, b.local, spell(), null);

      expect(withRecall, without);
    });

    // Residual activations resolve to no effect, so the drill never teaches
    // them and the cost must not price against them.
    test('residual activations are not part of the expected recital', () async {
      // 5 activations = one complete triplet + 2 residuals.
      final s = spell(formula: const ['fire', 'air', 'water', 'earth', 'fire']);
      final a = setup();
      final spent = await manaSpent(a.loop, a.local, s, perfect);

      final b = setup();
      final base = await manaSpent(b.loop, b.local, s, null);

      // Reciting only the 3 complete-triplet words still scores as perfect.
      expect(spent / base, closeTo(0.737, 0.02));
    });
  });

  group('§4 fizzle-with-refund', () {
    test('an unaffordable recall-inflated cast refunds the mana', () async {
      // Price the honest cast, then leave barely too little for the inflated
      // one a total blank produces.
      final probe = setup();
      final base = probe.loop.previewSpellCost(spell());

      final ctx = setup(mana: base);
      final before = ctx.local.mana;
      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: spell(),
            targetHex: ctx.local.position,
            recall: IncantationRecall.silent,
          ),
        ),
      );
      // Refunded: never deducted at all. The turn is still spent.
      expect(ctx.local.mana, before);
    });

    test('an affordable cast still charges normally', () async {
      final ctx = setup(mana: 200);
      final before = ctx.local.mana;
      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: spell(),
            targetHex: ctx.local.position,
            recall: perfect,
          ),
        ),
      );
      expect(ctx.local.mana, lessThan(before));
    });

    test('the fizzled cast is marked so resolution skips its effects', () async {
      final probe = setup();
      final base = probe.loop.previewSpellCost(spell());

      final ctx = setup(mana: base);
      final action = SpellCastAction(
        spell: spell(),
        targetHex: ctx.local.position,
        recall: IncantationRecall.silent,
      );
      await ctx.loop.runTurn(TurnInput(action: action));
      expect(action.fizzledForMana, isTrue);
    });

    test('wizard mode never fizzles for mana — that stays a forfeit', () async {
      // The gate prices exactly what the deduction charges in wizard mode, so
      // a shortfall there means a desync or a cheating peer. Weakening this
      // half would be the actual bug.
      final probe = setup(sorcererMode: false);
      final base = probe.loop.previewSpellCost(spell());

      final ctx = setup(mana: base, sorcererMode: false);
      final action = SpellCastAction(
        spell: spell(),
        targetHex: ctx.local.position,
      );
      await ctx.loop.runTurn(TurnInput(action: action));
      expect(action.fizzledForMana, isFalse);
      expect(ctx.local.mana, 0); // charged in full, not refunded
    });
  });

  group('§4 previewSpellCost quotes the honest price', () {
    test('sorcerer and wizard mode quote the same base', () {
      final sorcerer = setup(sorcererMode: true);
      final wizard = setup(sorcererMode: false);
      expect(
        sorcerer.loop.previewSpellCost(spell()),
        wizard.loop.previewSpellCost(spell()),
      );
    });

    test('a clean recital costs no more than the quote', () async {
      final ctx = setup();
      final quoted = ctx.loop.previewSpellCost(spell());
      final spent = await manaSpent(ctx.loop, ctx.local, spell(), perfect);
      expect(spent, lessThanOrEqualTo(quoted));
    });
  });

  // NOTE: the wire round trip is covered at the byte level in
  // test/sorcerer/incantation_recall_test.dart, and the encode->decode path
  // through an action is exercised by turn_loop_determinism_test's two-loop
  // setup. A recall-specific two-loop parity test (both devices deriving the
  // same multiplier from the same certified trajectory) is still worth adding
  // — it is the exact shape of desync this change could introduce.
}
