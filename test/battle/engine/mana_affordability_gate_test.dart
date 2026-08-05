// SPDX-License-Identifier: GPL-3.0-or-later
//
// mana_affordability_gate_test.dart — TurnLoop.previewSpellCost /
// canAffordSpell, the price the UI's cast barrier reads.
//
// The bug this exists for: the caster's own deduction clamps
// (`av.mana = (av.mana - cost).clamp(0, _kMaxMana)`), so overspending looks
// harmless locally — the bar just empties. The *peer* is what notices:
// _verifyPeerSpellCast sends `insufficient_mana_for_spell` and forfeits.
// One device plays on, the other stops: a desync. battle_screen.dart greys
// the card and kills the CAST button off these two methods, so what they
// must guarantee is:
//
//   1. the preview equals what the cast actually charges (a preview that's
//      cheaper than the deduction is the same bug with extra steps), and
//   2. the preview charges NOTHING — no consumed status effect, no HP —
//      because the UI calls it on every frame of every build.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

void main() {
  // Base cost is 5×segmentCount + dotCount, grown by 1.05^t × 1.5^effectCount
  // (effectCount = complete formulas − 1). One 3-zone formula ⇒ effectCount 0,
  // so cost is just `(5×segmentCount + dotCount) × 1.05^t` — small enough to
  // reason about by hand, which is the point: these tests pin the gate, not
  // the pricing curve (chain_discount_test.dart owns that).
  SpellAsset spell({
    required int segmentCount,
    int dotCount = 0,
    int t = 1,
    List<String> formula = const ['fire', 'air', 'water'],
    List<String> supremeTags = const [],
    int fillByte = 1,
  }) => SpellAsset(
    id: 'spell$fillByte',
    createdAt: DateTime.utc(2026, 7, 31),
    tier: 12,
    t: t,
    ownerPubkeyHex: '0x${'0' * 64}',
    manaCost: 0,
    segmentCount: segmentCount,
    dotCount: dotCount,
    initialGrid: const [],
    proofBytes: Uint8List.fromList([1, 2, 3]),
    name: 'spell$fillByte',
    commitmentHex:
        '0x${Uint8List.fromList(List.filled(32, fillByte)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    spellHashHex: '',
    formula: formula,
    supremeTags: supremeTags,
  );

  ({BattleState state, TurnLoop loop, WizardAvatar local}) setup({
    int mana = 100,
    int hp = 24,
    bool sorcererMode = false,
    bool allowProoflessSpells = false,
    List<StatusEffect> statusEffects = const [],
  }) {
    final bf = Battlefield(radius: 6);
    const id = 'local';
    final local = WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: hp,
      mana: mana,
      maxMana: 200,
      position: const HexCoord(0, 3),
      teamId: 'solo',
      baseSpellRange: 3,
    );
    local.activeStatusEffects.addAll(statusEffects);
    bf.occupancy[id] = local.position;
    final state = BattleState(
      config: MatchConfig(
        playerHp: hp,
        gridRadius: 6,
        maxPlayers: 1,
        sorcererMode: sorcererMode,
      ),
      avatars: [local],
      teams: [const Team(id: 'solo', playerIds: [id])],
      battlefield: bf,
    );
    final loop = TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: id,
      // Set on the loop, not read off MatchConfig — battle_screen.dart passes
      // `state.config.sorcererMode` here at construction (battle_screen.dart
      // :876), so mirror that wiring rather than assuming the loop infers it.
      isSorcererMode: sorcererMode,
      allowProoflessSpells: allowProoflessSpells,
    );
    return (state: state, loop: loop, local: local);
  }

  group('previewSpellCost', () {
    test('matches the mana the cast actually deducts', () async {
      final ctx = setup(mana: 200);
      final s = spell(segmentCount: 10); // 50 × 1.05 = 52.5 → 53

      final quoted = ctx.loop.previewSpellCost(s);
      final before = ctx.local.mana;
      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(spell: s, targetHex: ctx.local.position),
        ),
      );

      // Meditate/regen never runs on a cast turn, so the whole delta is the
      // spell — if that ever stops holding, compare against a PassAction turn
      // rather than loosening this to a range.
      expect(before - ctx.local.mana, quoted);
    });

    test('does not consume the status effects it prices with', () {
      // Both consumable modifiers at once: previewing must leave the caster
      // holding them, or a player who merely LOOKS at their hand loses a
      // nextSpellCostDouble for free.
      final ctx = setup(
        mana: 200,
        statusEffects: [
          StatusEffect(
            effectTypeId: StatusEffectId.chainSurcharge,
            remainingTurns: -1,
          ),
          StatusEffect(
            effectTypeId: StatusEffectId.nextSpellCostDouble,
            remainingTurns: -1,
          ),
        ],
      );
      final s = spell(segmentCount: 4);
      final hpBefore = ctx.local.hp;
      final manaBefore = ctx.local.mana;

      final first = ctx.loop.previewSpellCost(s);
      for (var i = 0; i < 5; i++) {
        expect(
          ctx.loop.previewSpellCost(s),
          first,
          reason: 'preview #${i + 2} differs — something is being consumed',
        );
      }

      expect(ctx.local.activeStatusEffects, hasLength(2));
      expect(ctx.local.hp, hpBefore);
      expect(ctx.local.mana, manaBefore);
    });

    test('Efficiency (Water) quotes the −1/3 discount', () {
      final ctx = setup(mana: 200);
      final s = spell(segmentCount: 12, supremeTags: const ['water']);

      final full = ctx.loop.previewSpellCost(s);
      final discounted = ctx.loop.previewSpellCost(s, isEfficiency: true);

      expect(discounted, (full * 2 / 3).ceil());
      expect(discounted, lessThan(full));
    });

    test('a proofless dev-flag spell quotes 0 (free on both devices)', () {
      // allowProoflessSpells is a per-loop constructor flag (only BattleScreen
      // wires kAllowProoflessSpells into it), so set it here rather than
      // relying on the global default.
      final ctx = setup(mana: 1, allowProoflessSpells: true);
      final s = SpellAsset(
        id: 'lab',
        createdAt: DateTime.utc(2026, 7, 31),
        tier: 12,
        t: 1,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 0,
        segmentCount: 40,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List(0), // no proof — the Spell Test Lab shape
        name: 'lab',
        commitmentHex: '0x${'ab' * 32}',
        spellHashHex: '',
        formula: const ['fire', 'air', 'water'],
      );

      // The gate must not lock a player out of a spell the engine charges
      // nothing for: the deduction path skips _isProoflessBypass spells
      // entirely. Delete this test alongside the temporary dev flag
      // (lib/dev_flags.dart) rather than relaxing it.
      expect(ctx.loop.previewSpellCost(s), 0);
      expect(ctx.loop.canAffordSpell(s), isTrue);
    });
  });

  group('canAffordSpell', () {
    test('true at exactly the caster\'s mana, false one above it', () {
      final ctx = setup(mana: 100);
      // 1.05^1 growth: segmentCount 19, dotCount 5 → 100 × 1.05 = 105 → 105.
      final exact = spell(segmentCount: 19, fillByte: 2);
      final cost = ctx.loop.previewSpellCost(exact);
      ctx.local.mana = cost;
      expect(
        ctx.loop.canAffordSpell(exact),
        isTrue,
        reason: 'the peer forfeits on `mana < cost`, so cost == mana is legal',
      );

      ctx.local.mana = cost - 1;
      expect(ctx.loop.canAffordSpell(exact), isFalse);
    });

    test('the expensive-spell case that desynced: gate says no', () {
      final ctx = setup(mana: 40);
      final pricey = spell(segmentCount: 30); // 150 × 1.05 ≈ 158
      expect(ctx.loop.previewSpellCost(pricey), greaterThan(40));
      expect(ctx.loop.canAffordSpell(pricey), isFalse);
    });

    test('a pending nextSpellCostDouble stays castable — its shortfall is '
        'paid in HP, not refused', () {
      // This is the one route by which an over-budget cast is legal, and the
      // gate must not block it: _spellCostBreakdown converts the excess to HP
      // damage and clamps the price to what the caster holds, so the peer's
      // `mana < cost` check passes too.
      final ctx = setup(
        mana: 20,
        statusEffects: [
          StatusEffect(
            effectTypeId: StatusEffectId.nextSpellCostDouble,
            remainingTurns: -1,
          ),
        ],
      );
      final s = spell(segmentCount: 30); // ~158 doubled — far over 20 mana

      expect(ctx.loop.previewSpellCost(s), 20, reason: 'pays what they have');
      expect(ctx.loop.canAffordSpell(s), isTrue);
    });
  });

  group('sorcerer mode', () {
    // REVERSED 2026-08-04 (VOCAL_RECALL_PLAN.md §4). This used to quote a 1.50x
    // worst case, because a bad incantation could inflate a cast the gate had
    // approved at 1.0x into one the peer forfeited over — a desync.
    //
    // Fizzle-with-refund removes that failure mode at the source: a shortfall
    // in sorcerer mode is now legal, fizzles, and refunds the mana (the turn is
    // still spent). With nothing left to protect against, quoting a price
    // nobody pays only misinformed the player, so the gate quotes the honest
    // base cost — which is also what a clean recital actually charges.
    test('quotes the honest base cost, same as wizard mode', () {
      final wizard = setup(mana: 200);
      final sorcerer = setup(mana: 200, sorcererMode: true);
      final s = spell(segmentCount: 12);

      expect(
        sorcerer.loop.previewSpellCost(s),
        wizard.loop.previewSpellCost(s),
      );
    });

    test('applies the Efficiency discount, which no longer hinges on a fizzle',
        () {
      // Recall never gates the loadout enhancement (§4: wrong words cost mana,
      // full stop), so Efficiency is live in the quote whenever the caster is
      // eligible for it.
      final ctx = setup(mana: 200, sorcererMode: true);
      final s = spell(segmentCount: 12, supremeTags: const ['water']);

      expect(
        ctx.loop.previewSpellCost(s, isEfficiency: true),
        lessThan(ctx.loop.previewSpellCost(s)),
      );
    });
  });
}
