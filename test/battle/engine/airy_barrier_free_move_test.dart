// SPDX-License-Identifier: GPL-3.0-or-later
//
// airy_barrier_free_move_test.dart — engine tests for the post-resolution
// free-move commit-reveal round: the free step granted when an Airy Barrier
// bursts from damage this turn (WizardAvatar.pendingFreeMoveBurst, set in
// absorbDamage), and the paid run granted by a Boost
// (WizardAvatar.pendingBoostMove — Air-Air Speed Manipulation, Fire or Water
// flavor), which shares the same window.
// Uses SoloBattleSession the same way dash_meditate_melee_test.dart does —
// scripts the dummy to cast a Fire-Fire-Fire (4 damage) bolt at the local
// avatar to burst a 2 HP Air barrier.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart' show FloorIsLava, SlowTile;
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _setup({
  int airBarrierHp = 2,
  FreeMovePathPicker? freeMovePicker,
  bool dummyCasts = true,
  bool localOnLava = false,
  int localMana = 50,
  int localHp = 24,
}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const localPos = HexCoord(0, 0);
  const dummyPos = HexCoord(0, 3);

  final battlefield = Battlefield(radius: 8);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: localHp,
    mana: localMana,
    maxMana: 1000,
    position: localPos,
    teamId: 'solo',
    baseSpellRange: 6,
  );
  if (airBarrierHp > 0) {
    local.barriers[SpellAffinity.air] = BarrierState(
      element: SpellAffinity.air,
      hp: airBarrierHp,
      maxHp: airBarrierHp,
      remainingTurns: 3,
      freeMoveOnCollapse: true,
    );
  }

  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 6,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: 8, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );
  if (localOnLava) {
    state.tileEffects[localPos] = const FloorIsLava(damage: 4);
  }

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(
      state: state,
      dummyAutoCast: dummyCasts,
      dummyCastTarget: localPos,
      dummyCastFormula: const ['fire', 'fire', 'fire'], // 4 damage
    ),
    localPlayerId: localId,
    freeMoveDirectionPicker: freeMovePicker ?? (grant) async => null,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

// The local wizard starts at (0,0) on a radius-8 board with the dummy far off
// at (0,3), so this whole line of tiles is always free to walk.
const _step1 = HexCoord(1, 0);
const _step2 = HexCoord(2, 0);
const _step3 = HexCoord(3, 0);

void main() {
  group('Airy Barrier burst free-move', () {
    test('barrier destroyed by damage grants a free move to the picked tile', () async {
      FreeMoveGrant? seenGrant;
      final ctx = _setup(
        airBarrierHp: 2,
        freeMovePicker: (grant) async {
          seenGrant = grant;
          return const [_step1];
        },
      );
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(seenGrant, isNotNull, reason: 'picker should have been prompted');
      expect(seenGrant!.burstStep, isTrue);
      expect(seenGrant!.boostResource, isNull, reason: 'no Boost was cast');
      expect(seenGrant!.maxTiles, 1, reason: 'a bare burst is exactly one step');
      expect(ctx.local.position, _step1);
      expect(ctx.local.position, isNot(startPos));
      expect(ctx.local.barriers.containsKey(SpellAffinity.air), isFalse,
          reason: '2 HP barrier fully absorbed the 4 damage bolt (with overflow to real HP)');
      expect(ctx.local.pendingFreeMoveBurst, isFalse,
          reason: 'one-shot grant must be cleared after being consumed');
    });

    test('a burst step never charges anything', () async {
      final ctx = _setup(
        airBarrierHp: 2,
        localMana: 500,
        freeMovePicker: (grant) async => const [_step1],
      );
      final startHp = ctx.local.hp;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.mana, 500);
      expect(ctx.local.hp, lessThan(startHp),
          reason: 'the bolt overflowed the barrier — but the step itself was free');
    });

    test('a burst grant cannot be stretched into a second, unpaid step', () async {
      // The picker lies and declares two tiles on a one-tile grant. The engine
      // re-derives maxTiles from state, so the walk simply stops after one.
      final ctx = _setup(
        airBarrierHp: 2,
        freeMovePicker: (grant) async => const [_step1, _step2],
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, _step1);
    });

    test('declining the free-move prompt (picker returns null) leaves position unchanged',
        () async {
      final ctx = _setup(airBarrierHp: 2, freeMovePicker: (grant) async => null);
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, startPos);
      expect(ctx.local.pendingFreeMoveBurst, isFalse,
          reason: 'the one-shot grant is still cleared even if unused');
    });

    test('no prompt when the barrier absorbs damage but survives', () async {
      var pickerCalled = false;
      final ctx = _setup(
        airBarrierHp: 10, // 4 damage this turn is not enough to burst it
        freeMovePicker: (grant) async {
          pickerCalled = true;
          return const [_step1];
        },
      );
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(pickerCalled, isFalse);
      expect(ctx.local.position, startPos);
      expect(ctx.local.barriers[SpellAffinity.air]?.hp, 6);
    });

    test('an end-of-turn burst is granted in the same turn, by the Phase 6.5 window',
        () async {
      // Phase 6 (lava) bursts the barrier *after* Phase 5.5's window has
      // closed. The second window catches it in the same turn rather than
      // dropping the grant or leaking it into the next turn's Phase 5.5.
      var promptCount = 0;
      final ctx = _setup(
        airBarrierHp: 2,
        dummyCasts: false, // no spell damage — only the end-of-turn lava tick
        localOnLava: true,
        freeMovePicker: (grant) async {
          promptCount++;
          return const [_step1];
        },
      );
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.barriers.containsKey(SpellAffinity.air), isFalse,
          reason: 'lava (4) burst the 2 HP barrier at end of turn');
      expect(promptCount, 1,
          reason: 'Phase 6.5 offers the step Phase 5.5 was too early to see');
      expect(ctx.local.position, isNot(startPos), reason: 'stepped off the lava');
      expect(ctx.local.pendingFreeMoveBurst, isFalse);

      // Off the lava now, so nothing bursts on turn 2 — and crucially the
      // turn-1 grant must not reappear.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(promptCount, 1, reason: 'no stale prompt on the following turn');
    });

    test('a Phase 5 burst does not also prompt again in the Phase 6.5 window',
        () async {
      // The one-shot clear at the end of each round is what prevents the same
      // burst being offered twice in one turn.
      var promptCount = 0;
      final ctx = _setup(
        airBarrierHp: 2,
        freeMovePicker: (grant) async {
          promptCount++;
          return const [_step1];
        },
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(promptCount, 1, reason: 'one burst grants exactly one step');
    });

    test('no prompt when no damage is dealt at all', () async {
      var pickerCalled = false;
      final ctx = _setup(
        airBarrierHp: 2,
        dummyCasts: false, // dummy just passes — no damage this turn
        freeMovePicker: (grant) async {
          pickerCalled = true;
          return const [_step1];
        },
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(pickerCalled, isFalse);
      expect(ctx.local.barriers.containsKey(SpellAffinity.air), isTrue);
    });
  });

  // ── Boost (Air-Air Speed Manipulation) ──────────────────────────────────
  //
  // Granted by EffectApplicator when the spell resolves; taken in the same
  // post-resolution window as a burst step. These drive it by setting
  // pendingBoostMove directly rather than casting an Air-Air spell, so the
  // arithmetic under test is the free-move round's and not the applicator's
  // (which target_tile_effects_test.dart covers).
  group('Boost run', () {
    /// Runs one turn with a boost pre-granted to the local wizard. No barrier,
    /// no incoming bolt — nothing but the boost in the window.
    Future<({WizardAvatar local, FreeMoveGrant? grant})> runBoost({
      required SpellAffinity resource,
      int freeTiles = 0,
      int mana = 500,
      int hp = 24,
      required List<HexCoord> Function(FreeMoveGrant) path,
    }) async {
      FreeMoveGrant? seen;
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        localMana: mana,
        localHp: hp,
        freeMovePicker: (grant) async {
          seen ??= grant;
          return path(grant);
        },
      );
      ctx.local.grantBoostMove(resource, freeTiles);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      return (local: ctx.local, grant: seen);
    }

    test('Watery Boost: one tile costs 100 mana and moves the wizard', () async {
      final r = await runBoost(
        resource: SpellAffinity.water,
        mana: 500,
        path: (_) => const [_step1],
      );

      expect(r.grant, isNotNull, reason: 'a pending boost must open the prompt');
      expect(r.grant!.boostResource, SpellAffinity.water);
      expect(r.grant!.burstStep, isFalse);
      expect(r.grant!.freeTiles, 0, reason: 'base cast pays for every tile');
      expect(r.local.position, _step1);
      expect(r.local.mana, 400);
    });

    test('Watery Boost: cost is triangular, not linear', () async {
      // 2 tiles = (2×3)/2 × 100 = 300 mana, NOT 200.
      final r = await runBoost(
        resource: SpellAffinity.water,
        mana: 500,
        path: (_) => const [_step1, _step2],
      );

      expect(r.local.position, _step2);
      expect(r.local.mana, 200);
    });

    test('Watery Boost: Potency makes the first tile free', () async {
      // freeTiles 1, so 2 tiles walked = 1 paid = 100 mana.
      final r = await runBoost(
        resource: SpellAffinity.water,
        freeTiles: 1,
        mana: 500,
        path: (_) => const [_step1, _step2],
      );

      expect(r.grant!.freeTiles, 1);
      expect(r.local.position, _step2);
      expect(r.local.mana, 400);
    });

    test('Watery Boost: standing fast costs nothing', () async {
      final r = await runBoost(
        resource: SpellAffinity.water,
        mana: 500,
        path: (_) => const [],
      );

      expect(r.local.position, const HexCoord(0, 0));
      expect(r.local.mana, 500);
    });

    test('Watery Boost: the grant is capped at what the wizard can pay for', () async {
      // 250 mana affords 1 tile (100) but not 2 (300). A picker that asks for
      // 2 gets truncated to 1 and billed 100 — never 300 on a 250 pool.
      final r = await runBoost(
        resource: SpellAffinity.water,
        mana: 250,
        path: (_) => const [_step1, _step2],
      );

      expect(r.grant!.maxTiles, 1);
      expect(r.local.position, _step1);
      expect(r.local.mana, 150);
    });

    test('Firey Boost: pays life, and can never take the wizard below 1 HP', () async {
      // 3 HP affords 1 tile (1 HP) and 2 tiles (3 HP would leave 0) is refused
      // — the cap is hp-1 = 2.
      final r = await runBoost(
        resource: SpellAffinity.fire,
        hp: 3,
        path: (_) => const [_step1, _step2, _step3],
      );

      expect(r.grant!.boostResource, SpellAffinity.fire);
      expect(r.grant!.maxTiles, 1, reason: '2 paid tiles cost 3 HP, leaving 0');
      expect(r.local.position, _step1);
      expect(r.local.hp, 2);
      expect(r.local.isAlive, isTrue);
    });

    test('Firey Boost: a barrier does not soak the price', () async {
      // The life cost is a price, not damage — an Earth barrier absorbing it
      // would make the tiles free.
      FreeMoveGrant? seen;
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        freeMovePicker: (grant) async {
          seen = grant;
          return const [_step1];
        },
      );
      ctx.local.barriers[SpellAffinity.earth] = BarrierState(
        element: SpellAffinity.earth,
        hp: 10,
        maxHp: 10,
        remainingTurns: 3,
      );
      ctx.local.grantBoostMove(SpellAffinity.fire, 0);
      final startHp = ctx.local.hp;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(seen, isNotNull);
      expect(ctx.local.hp, startHp - 1);
      expect(ctx.local.barriers[SpellAffinity.earth]?.hp, 10,
          reason: 'the barrier must be untouched by a self-paid cost');
    });

    test('a burst step and a Boost stack into one run, burst step free', () async {
      // Burst (1 free) + boost = 3 tiles walked, 2 paid = 300 mana.
      FreeMoveGrant? seen;
      final ctx = _setup(
        airBarrierHp: 2, // bursts on the dummy's 4-damage bolt
        localMana: 500,
        freeMovePicker: (grant) async {
          seen ??= grant;
          return const [_step1, _step2, _step3];
        },
      );
      ctx.local.grantBoostMove(SpellAffinity.water, 0);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(seen!.burstStep, isTrue);
      expect(seen!.boostResource, SpellAffinity.water);
      expect(seen!.freeTiles, 1, reason: 'the burst step is the free one');
      expect(ctx.local.position, _step3);
      expect(ctx.local.mana, 200);
    });

    test('the boost grant is one-shot — cleared even when unused', () async {
      var promptCount = 0;
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        localMana: 500,
        freeMovePicker: (grant) async {
          promptCount++;
          return null;
        },
      );
      ctx.local.grantBoostMove(SpellAffinity.water, 0);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(promptCount, 1);
      expect(ctx.local.pendingBoostMove, isNull);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(promptCount, 1, reason: 'no stale boost prompt on the following turn');
    });

    test('a wizard who cannot afford even one tile is never prompted', () async {
      // 50 mana against a 100-mana first tile, and no free tile to fall back
      // on. Offering a choice that can't be taken is worse than offering none.
      var promptCount = 0;
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        localMana: 50,
        freeMovePicker: (grant) async {
          promptCount++;
          return const [_step1];
        },
      );
      ctx.local.grantBoostMove(SpellAffinity.water, 0);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(promptCount, 0);
      expect(ctx.local.position, const HexCoord(0, 0));
      expect(ctx.local.mana, 50);
      expect(ctx.local.pendingBoostMove, isNull,
          reason: 'still cleared — an unaffordable grant does not carry over');
    });

    test('Potency\'s free tile is offered even to a wizard with no mana', () async {
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        localMana: 0,
        freeMovePicker: (grant) async => const [_step1],
      );
      ctx.local.grantBoostMove(SpellAffinity.water, 1);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, _step1);
      expect(ctx.local.mana, 0);
    });

    test('a slow tile costs two budget points, and is billed as two tiles',
        () async {
      // The seam this pins: the engine bills off _walkAvatar's *budget spent*,
      // while BattleScreen's preview bills off predictAvatarMove's
      // budgetRemaining. A slow tile is where "tiles walked" and "budget
      // spent" come apart (1 tile, 2 points), so it's where the two mirrors
      // would silently disagree. One step onto a slow tile = 2 paid = 300
      // mana, plus the tile's own 10-mana entry drain.
      final ctx = _setup(
        airBarrierHp: 0,
        dummyCasts: false,
        localMana: 500,
        freeMovePicker: (grant) async => const [_step1],
      );
      ctx.state.tileEffects[_step1] =
          const SlowTile(extraMoveCost: 1, manaDrainOnEntry: 10);
      ctx.local.grantBoostMove(SpellAffinity.water, 0);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, _step1);
      expect(ctx.local.mana, 190, reason: '500 − 300 boost − 10 entry drain');
    });

    test('boostMoveCost matches the design table in both resources', () {
      expect(TurnLoop.boostMoveCost(SpellAffinity.water, 0), 0);
      expect(TurnLoop.boostMoveCost(SpellAffinity.water, 1), 100);
      expect(TurnLoop.boostMoveCost(SpellAffinity.water, 2), 300);
      expect(TurnLoop.boostMoveCost(SpellAffinity.water, 3), 600);
      expect(TurnLoop.boostMoveCost(SpellAffinity.fire, 1), 1);
      expect(TurnLoop.boostMoveCost(SpellAffinity.fire, 2), 3);
      expect(TurnLoop.boostMoveCost(SpellAffinity.fire, 3), 6);
    });
  });
}
