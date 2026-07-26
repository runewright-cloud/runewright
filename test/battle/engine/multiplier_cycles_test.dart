// SPDX-License-Identifier: GPL-3.0-or-later
//
// multiplier_cycles_test.dart — Air-Fire "Bellows" (multiplierCycles):
// regression coverage for the bug where the pending multiplier was stored
// and then silently discarded on the caster's next cast instead of
// amplifying it (see turn_loop.dart _applySpell). Each flavor of Bellows
// (Fire->Air, Earth->Fire, Water->Earth, Air->Water) is exercised end to
// end through TurnLoop's real cast pipeline (SoloBattleSession: local
// trusted-wire-formula path, mirroring summon_cast_test.dart's style).
//
// Bellows + its amplified effect are packed into a single multi-formula
// spell so both formulas resolve within the same cast: the first formula's
// application sets WizardAvatar.pendingEffectMultipliers before the second
// formula is resolved (see TurnLoop._applySpell's per-formula loop).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

SpellAsset _spell(List<String> formula) => SpellAsset(
      id: 'bellows-${formula.join()}',
      createdAt: DateTime.utc(2026, 7, 18),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo mode
      name: 'Test Bellows',
      commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
      spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
      formula: formula,
    );

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
    _setup({required HexCoord localPos, required HexCoord dummyPos, int radius = 4}) {
  const localId = 'local';
  const dummyId = 'dummy';

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: localPos,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 3,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('Bellows (Air-Fire multiplierCycles) actually amplifies the next matching effect', () {
    test('Air flavor: doubles the next Water-flavor effect (splash damage)', () async {
      // local (0,1) -> dummy (0,-1): distance 2, within baseSpellRange 3.
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));
      final startHp = ctx.dummy.hp;

      // Formula 1 [air,air,fire]: Air-flavor Bellows -> next Water effect x2.
      // Formula 2 [water,fire,fire]: Water-flavor Damage (splash, base amount 2).
      final spell = _spell(['air', 'air', 'fire', 'water', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
      ));

      expect(startHp - ctx.dummy.hp, 4,
          reason: 'base splash damage is 2; Bellows should double it to 4, '
              'not silently drop the pending multiplier');
    });

    test('Air flavor under Potency: triples the next Water-flavor effect', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));
      final startHp = ctx.dummy.hp;

      final spell = _spell(['air', 'air', 'fire', 'water', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position, isPotent: true),
      ));

      expect(startHp - ctx.dummy.hp, 9,
          reason: 'potency raises splash damage 2->3 AND the multiplier 2->3 for the '
              'whole spell; potent Bellows should triple potent splash (3) to 9');
    });

    test('Water flavor: doubles the next Earth-flavor effect (traversal damage)', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));
      final startHp = ctx.dummy.hp;

      // Formula 1 [water,air,fire]: Water-flavor Bellows -> next Earth effect x2.
      // Formula 2 [earth,fire,fire]: Earth-flavor Damage (traversal, base amount 2).
      final spell = _spell(['water', 'air', 'fire', 'earth', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
      ));

      expect(startHp - ctx.dummy.hp, 4,
          reason: 'base traversal damage is 2; Water-flavor Bellows should double it to 4');
    });

    test('Earth flavor: doubles the next Fire-flavor effect (direct damage)', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));
      final startHp = ctx.dummy.hp;

      // Formula 1 [earth,air,fire]: Earth-flavor Bellows -> next Fire effect x2.
      // Formula 2 [fire,fire,fire]: Fire-flavor Damage (direct, base amount 4).
      final spell = _spell(['earth', 'air', 'fire', 'fire', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
      ));

      expect(startHp - ctx.dummy.hp, 8,
          reason: 'base direct damage is 4; Earth-flavor Bellows should double it to 8');
    });

    test('Fire flavor: doubles the next Air-flavor effect (knockback damage)', () async {
      // Small board, dummy pinned at the boundary directly away from the
      // caster: the knockback push lands out of bounds and aborts, so the
      // dummy stays on the target tile for both applications (see
      // EffectApplicator._knockback's out-of-bounds fallback).
      final ctx = _setup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(0, 2),
        radius: 2,
      );
      final startHp = ctx.dummy.hp;
      final startPos = ctx.dummy.position;

      // Formula 1 [fire,air,fire]: Fire-flavor Bellows -> next Air effect x2.
      // Formula 2 [air,fire,fire]: Air-flavor Damage (knockback, base amount 2).
      final spell = _spell(['fire', 'air', 'fire', 'air', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
      ));

      expect(ctx.dummy.position, startPos,
          reason: 'sanity check: knockback should have been a no-op at this boundary tile');
      expect(startHp - ctx.dummy.hp, 4,
          reason: 'base knockback damage is 2; Fire-flavor Bellows should double it to 4');
    });

    test('the multiplier only amplifies the next matching-affinity effect, not others', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));
      final startHp = ctx.dummy.hp;

      // Air-flavor Bellows targets Water, but the second formula here is a
      // Fire-flavor direct-damage effect -- it must NOT be amplified.
      final spell = _spell(['air', 'air', 'fire', 'fire', 'fire', 'fire']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
      ));

      expect(startHp - ctx.dummy.hp, 4,
          reason: 'unrelated Fire-flavor damage (base 4) should be untouched by a '
              'pending Water-targeted multiplier');
    });

    test('the multiplier is consumed once: a second matching effect in a later cast '
        'is not amplified', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));

      // Turn 1: Air-flavor Bellows only (targets Water, multiplier queued).
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['air', 'air', 'fire']),
          targetHex: ctx.dummy.position,
        ),
      ));

      // Turn 2: the queued multiplier should apply here (doubled).
      final hpBeforeFirstWaterCast = ctx.dummy.hp;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['water', 'fire', 'fire']),
          targetHex: ctx.dummy.position,
        ),
      ));
      expect(hpBeforeFirstWaterCast - ctx.dummy.hp, 4,
          reason: 'the queued multiplier from turn 1 should double this first Water cast');

      // Turn 3: a second Water-flavor cast should be back to normal (base 2),
      // since the multiplier was already consumed on turn 2.
      final hpBeforeSecondWaterCast = ctx.dummy.hp;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['water', 'fire', 'fire']),
          targetHex: ctx.dummy.position,
        ),
      ));
      expect(hpBeforeSecondWaterCast - ctx.dummy.hp, 2,
          reason: 'the multiplier must not persist past the one cast that consumed it');
    });

    test('an unused multiplier expires after 2 turns: the cast turn plus one more '
        'turn to spend it', () async {
      final ctx = _setup(localPos: const HexCoord(0, 1), dummyPos: const HexCoord(0, -1));

      // Turn 1: Air-flavor Bellows only (targets Water, multiplier queued).
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['air', 'air', 'fire']),
          targetHex: ctx.dummy.position,
        ),
      ));

      // Turn 2: caster does nothing else with it (passes) -- the buff is
      // still alive at this point (1 turn remaining) but goes unused.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Turn 3: too late -- 2 turns have elapsed since the Bellows cast
      // without a matching Water effect, so this should be back to base (2),
      // not doubled.
      final hpBeforeWaterCast = ctx.dummy.hp;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['water', 'fire', 'fire']),
          targetHex: ctx.dummy.position,
        ),
      ));
      expect(hpBeforeWaterCast - ctx.dummy.hp, 2,
          reason: 'Bellows lasts 2 turns (cast turn + 1 more to use it); left unused '
              'through turn 2 it must expire before turn 3');
    });
  });
}
