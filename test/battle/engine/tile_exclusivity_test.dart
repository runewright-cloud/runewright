// SPDX-License-Identifier: GPL-3.0-or-later
//
// tile_exclusivity_test.dart — bodies are exclusive: no two entities may
// occupy the same tile, and the one deliberate exception, the melee lunge.
//
// Two rules, tested together because they only make sense together:
//
//   1. An avatar or summon may not enter a tile another body stands on. It
//      stops in front of it, the way it stops in front of a wall.
//   2. A summon with attack range 0 therefore *cannot* reach its target from
//      where it is standing. So it spends one movement point stepping onto
//      the target's tile, strikes, and is immediately shoved back out. No
//      movement left over means no attack that turn.
//
// Rule 2 exists because of rule 1: melee is the one case where "you have to
// be on the tile" and "you may not be on the tile" are both true, and the
// lunge is how the engine says both at once. Without it, range 0 would either
// be unplayable or would have to be quietly clamped up to 1 — which is
// exactly what it used to be.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Harness ───────────────────────────────────────────────────────────────────

/// Stat derivation (creature_spec.dart) in the terms this file cares about:
/// `maxHp = earth`, `damage = fire ~/ 2`, `moveSpeed = air ~/ 2`,
/// `attackRange = water ~/ 3`. Every creature below therefore needs at least
/// one earth (there is no minimum stat floor — a 0-HP creature is reaped the
/// instant it spawns) and gets range 0 unless it is given three waters.
SpellAsset _summonSpell({
  required List<String> formula,
  String summonPersonality = 'aggressive',
}) => SpellAsset(
  id: 'summon-${formula.join()}',
  createdAt: DateTime.utc(2026, 8, 4),
  tier: 12,
  t: 5,
  ownerPubkeyHex: '0x${'0' * 64}',
  manaCost: 1,
  segmentCount: 0,
  dotCount: 1,
  initialGrid: List<int>.filled(469, 0)..[234] = 1,
  proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
  name: 'Test Summon',
  commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
  spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
  formula: formula,
  isSummon: true,
  summonPersonality: summonPersonality,
);

({
  BattleState state,
  TurnLoop loop,
  WizardAvatar local,
  WizardAvatar dummy,
  List<List<MinionMoveEvent>> summonPlaybacks,
})
_setup({
  HexCoord localPos = const HexCoord(0, 3),
  HexCoord dummyPos = const HexCoord(0, -3),
  int radius = 6,
}) {
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

  final playbacks = <List<MinionMoveEvent>>[];
  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    onSummonMovementResolved: (moves, attacks) async => playbacks.add(moves),
  );

  return (
    state: state,
    loop: loop,
    local: local,
    dummy: dummy,
    summonPlaybacks: playbacks,
  );
}

Future<Minion> _summon(
  ({
    BattleState state,
    TurnLoop loop,
    WizardAvatar local,
    WizardAvatar dummy,
    List<List<MinionMoveEvent>> summonPlaybacks,
  })
  ctx,
  List<String> formula,
  HexCoord at, {
  String personality = 'aggressive',
}) async {
  await ctx.loop.runTurn(
    TurnInput(
      action: SpellCastAction(
        spell: _summonSpell(formula: formula, summonPersonality: personality),
        targetHex: at,
      ),
    ),
  );
  return ctx.state.minions.single;
}

void main() {
  group('bodies are exclusive', () {
    test('a summon stops in front of an enemy wizard instead of onto it',
        () async {
      // move 1, damage 0 (no fire), range 0. Spawns 2 tiles from the dummy
      // with the whole column between them empty, so the only thing that can
      // stop it short is the dummy's body.
      final ctx = _setup();
      final creature = await _summon(
        ctx,
        const ['air', 'air', 'earth', 'earth'],
        const HexCoord(0, -1),
      );

      // Cast turn's own Phase 5b action already ran: (0,-1) -> (0,-2).
      expect(creature.position, const HexCoord(0, -2));

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.minions.single.position,
        const HexCoord(0, -2),
        reason: 'the only tile that closes the gap is the one the dummy is '
            'standing on, so the creature holds where it is',
      );
      expect(ctx.state.minions.single.distanceTo(ctx.dummy.position), 1);
    });

    test('a summon will not walk onto another summon', () async {
      final ctx = _setup(radius: 8);
      // Both are the local player's, both hunting the dummy up the q=0 column;
      // the leader ends up between the follower and the target.
      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: _summonSpell(formula: const ['earth', 'earth']),
            targetHex: const HexCoord(0, -2),
          ),
        ),
      );
      final blocker = ctx.state.minions.single; // move speed 0: never budges
      expect(blocker.position, const HexCoord(0, -2));

      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: _summonSpell(formula: const ['air', 'air', 'earth']),
            targetHex: const HexCoord(0, -1),
          ),
        ),
      );

      final follower = ctx.state.minions.firstWhere((m) => m.id != blocker.id);
      expect(follower.position, isNot(blocker.position));
      expect(
        ctx.state.minions.map((m) => m.position).toSet(),
        hasLength(2),
        reason: 'two creatures may never share a tile',
      );
    });

    test('a wizard walks into a summon and stops one tile short', () async {
      final ctx = _setup();
      // Move speed 0, so it sits exactly where it spawns and blocks the road.
      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: _summonSpell(formula: const ['earth', 'earth']),
            targetHex: const HexCoord(0, 1),
          ),
        ),
      );
      expect(ctx.state.minions.single.position, const HexCoord(0, 1));

      await ctx.loop.runTurn(
        TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(0, 2), HexCoord(0, 1)],
        ),
      );

      expect(ctx.local.position, const HexCoord(0, 2));
      final event = ctx.loop.lastAvatarMoveEvents.firstWhere(
        (e) => e.playerId == 'local',
      );
      expect(event.path.last, const HexCoord(0, 2));
      expect(
        event.lungeTile,
        const HexCoord(0, 1),
        reason: 'the walk visibly rebounds off the creature rather than '
            'stopping early for no shown reason',
      );
    });
  });

  group('a range-0 summon lunges to attack', () {
    // damage 1 (2 fire), move 1 (2 air), hp 2, range 0.
    const melee = ['fire', 'fire', 'air', 'air', 'earth', 'earth'];

    test('spends a movement point, strikes, and ends where it started',
        () async {
      final ctx = _setup();
      final before = ctx.dummy.hp;
      final creature = await _summon(ctx, melee, const HexCoord(0, -2));

      expect(creature.position, const HexCoord(0, -2),
          reason: 'it was already adjacent, so it never took a walking step');
      expect(ctx.dummy.hp, before - 1, reason: 'the lunge landed');
      expect(
        ctx.state.avatars.every((a) => a.position != creature.position),
        isTrue,
        reason: 'and it did not stay on the tile it struck',
      );
    });

    test('the lunge is reported to the UI as a lunge, not as a move', () async {
      final ctx = _setup();
      await _summon(ctx, melee, const HexCoord(0, -2));

      final event = ctx.loop.lastMinionMoveEvents.single;
      expect(event.path, [const HexCoord(0, -2)]);
      expect(event.lungeTile, const HexCoord(0, -3));
      // Kept by the playback filter despite the single-tile path: the lunge is
      // the whole visible attack.
      expect(ctx.summonPlaybacks.last, hasLength(1));
    });

    test('a creature that spent its whole budget closing cannot strike, and '
        'strikes on the following turn instead', () async {
      final ctx = _setup();
      final before = ctx.dummy.hp;
      // Spawns 2 away with move speed 1: the one step it can afford puts it
      // adjacent with nothing left to lunge with.
      final creature = await _summon(ctx, melee, const HexCoord(0, -1));

      expect(creature.position, const HexCoord(0, -2));
      expect(creature.distanceTo(ctx.dummy.position), 1);
      expect(ctx.dummy.hp, before, reason: 'no movement left, so no blow');
      expect(ctx.loop.lastMinionMoveEvents.single.lungeTile, isNull);

      // Next turn it has nowhere to walk (the only closing tile is the dummy's
      // own), so its full budget is available for the lunge.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.minions.single.position, const HexCoord(0, -2));
      expect(ctx.dummy.hp, before - 1);
      expect(
        ctx.loop.lastMinionMoveEvents.single.lungeTile,
        const HexCoord(0, -3),
      );
    });

    test('a creature with reach strikes from where it stands, no lunge',
        () async {
      // 3 water -> range 1. Same "adjacent to the dummy" geometry as the melee
      // case, so the only difference under test is the reach itself.
      final ctx = _setup();
      final before = ctx.dummy.hp;
      final creature = await _summon(
        ctx,
        const [
          'fire', 'fire', //
          'water', 'water', 'water',
          'air', 'air',
          'earth', 'earth',
        ],
        const HexCoord(0, -2),
      );

      expect(creature.effectiveAttackRange, 1);
      expect(ctx.dummy.hp, before - 1);
      expect(
        ctx.loop.lastMinionMoveEvents,
        isEmpty,
        reason: 'it neither moved nor lunged, so there is nothing to animate',
      );
    });
  });

  group('summon walks are reported for playback', () {
    test('the route the creature really took, origin first', () async {
      final ctx = _setup(radius: 8);
      // move 2, so the walk covers two tiles and a teleport would be obvious.
      final creature = await _summon(
        ctx,
        const ['air', 'air', 'air', 'air', 'earth', 'earth'],
        const HexCoord(0, 2),
      );

      final event = ctx.loop.lastMinionMoveEvents.single;
      expect(event.minionId, creature.id);
      expect(event.path.first, const HexCoord(0, 2));
      expect(event.path.last, creature.position);
      expect(event.path, hasLength(3)); // origin + two steps
      for (var i = 1; i < event.path.length; i++) {
        expect(hexDistance(event.path[i - 1], event.path[i]), 1,
            reason: 'every leg of the animated route is a single hex step');
      }
      expect(ctx.summonPlaybacks.last.single.path, event.path);
    });

    test('a creature that neither moved nor lunged is not reported', () async {
      // Move 0, range 0, and nothing in reach: it does nothing at all.
      final ctx = _setup();
      await _summon(ctx, const ['earth', 'earth'], const HexCoord(0, 1));

      expect(ctx.loop.lastMinionMoveEvents, isEmpty);
      // The hook still fires (same convention as onMovementResolved); it is the
      // UI that returns immediately rather than holding the turn on an empty
      // animation — see _playSummonWalks.
      expect(ctx.summonPlaybacks.last, isEmpty);
    });
  });
}
