// SPDX-License-Identifier: GPL-3.0-or-later
//
// potent_summon_bonus_events_test.dart — regression suite for M4.17
// (docs/M4_findings.md): a Potent summon's immediate Phase-5 bonus action must
// appear in the turn's playback stream, ahead of the ordinary Phase-5b sweep.
//
// ## The invariant these tests defend
//
// **Every per-turn `lastX` event list is freshly allocated at the top of
// `runTurn`, and every phase that emits events during that turn APPENDS into
// those same list objects. No phase ever reassigns one mid-turn.**
//
// Two phases write the summon sinks, in this order:
//
//   Phase 5   `_castSummon`, when `enhancements.isPotent`
//               -> `_creatureTurn(..., moveEvents: ctx.minionMoveEvents, ...)`
//   Phase 5b  `resolveSummonActions`
//               -> appends the AI sweep to the SAME lists
//
// so `lastMinionMoveEvents` reads chronologically: bonus action first, sweep
// second, sweep entries in `state.minions` creation order.
//
// The bug this replaces: Phase 5b used to allocate fresh lists and assign them
// over the fields, which (a) discarded the bonus action's entire playback
// record — the creature visibly teleported across a move it really made and
// landed a blow with no animation at all — and (b) meant `_castContext`
// captured the PREVIOUS turn's outcome list, so the append silently landed in
// an already-delivered collection. Both halves are pinned below.
//
// Nothing here is about gameplay: the bonus action's movement, damage and
// deaths were always correct in canonical state, and still are. These events
// are UI playback records only (see [MinionMoveEvent]).
//
// Solo mode (SoloBattleSession) for the local path, TurnSessionPair for the
// peer path, mirroring summon_cast_test.dart / peer_summon_replication_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

// ── Fixtures ─────────────────────────────────────────────────────────────────

/// A summon-mode spell. `supremeTags` is documentation in solo mode (the
/// enhancement gate lives in the UI picker and, for a peer, in
/// PeerCastVerifier); the engine reads `SpellCastAction.isPotent`.
SpellAsset _summonSpell({
  required List<String> formula,
  String summonPersonality = 'aggressive',
}) => SpellAsset(
  id: 'summon-${formula.join()}',
  createdAt: DateTime.utc(2026, 8, 19),
  tier: 12,
  t: 5,
  ownerPubkeyHex: '0x${'0' * 64}',
  manaCost: 1,
  segmentCount: 0,
  dotCount: 1,
  initialGrid: List<int>.filled(469, 0)..[234] = 1,
  proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo
  name: 'Test Summon',
  commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
  spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
  formula: formula,
  supremeTags: const ['fire'],
  isSummon: true,
  summonPersonality: summonPersonality,
);

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
_setup({
  HexCoord localPos = const HexCoord(0, 3),
  HexCoord dummyPos = const HexCoord(0, -3),
  int radius = 6,
  int range = 6,
  Map<HexCoord, TileEffect> tileEffects = const {},
  SummonMovementPlayback? onSummonMovementResolved,
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
    baseSpellRange: range,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: range,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
    tileEffects: tileEffects,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    onSummonMovementResolved: onSummonMovementResolved,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

/// 1 fire / 4 air / 2 earth: Flying (AAAA), moveSpeed 2, hp 2, damage 0,
/// range 0 — the same walker summon_cast_test.dart's Potency tests use, so
/// "moved twice" is legible as distance. Damage 0 keeps this purely about
/// movement events.
const _walkerFormula = ['fire', 'air', 'air', 'air', 'air', 'earth', 'earth'];

/// 2 fire / 2 air / 2 earth ("FFAAEE"): no ability pattern matches, hp 2,
/// damage 1, moveSpeed 1, attackRange 0 — a melee creature that can actually
/// land a blow, which is what makes the attack-event half testable.
const _brawlerFormula = ['fire', 'fire', 'air', 'air', 'earth', 'earth'];

/// 1 fire / 2 air / 3 earth ("FAAEEE"): moveSpeed 1, hp 3, damage 0, range 0,
/// and — unlike the walker — NOT Flying, so conveyor tiles apply to it.
const _plodderFormula = ['fire', 'air', 'air', 'earth', 'earth', 'earth'];

/// Open road: 9 tiles between spawn and the enemy, so a moveSpeed-2 creature's
/// two actions read as two distinct 2-tile walks rather than one saturated
/// one. Same geometry as summon_cast_test's "moves further" case.
({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
_openRoad({SummonMovementPlayback? onSummonMovementResolved}) => _setup(
  localPos: const HexCoord(4, 0),
  dummyPos: const HexCoord(0, 6),
  radius: 8,
  range: 8,
  onSummonMovementResolved: onSummonMovementResolved,
);

const _spawnTile = HexCoord(0, -3);

void main() {
  group('M4.17 — the Potent bonus action is played back, in order', () {
    test(
      'both walks are present, bonus first, and the sweep walk resumes where '
      'the bonus walk stopped',
      () async {
        final ctx = _openRoad();

        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _walkerFormula),
              targetHex: _spawnTile,
              isPotent: true,
            ),
          ),
        );

        final creature = ctx.state.minions.single;
        final moves = ctx.loop.lastMinionMoveEvents;

        expect(
          moves,
          hasLength(2),
          reason: 'one walk per action, and Potency grants two actions',
        );
        expect(moves.every((e) => e.minionId == creature.id), isTrue);

        // Chronological order: the bonus action happened in Phase 5, so its
        // walk is the one that starts at the spawn tile.
        final bonus = moves.first;
        final sweep = moves.last;
        expect(
          bonus.path.first,
          _spawnTile,
          reason: 'the bonus walk is FIRST and starts where the creature spawned',
        );
        expect(bonus.path.length, greaterThan(1));
        expect(
          sweep.path.first,
          bonus.path.last,
          reason: 'the sweep walk resumes exactly where the bonus walk stopped '
              '— one continuous route, no visible teleport',
        );
        expect(sweep.path.last, creature.position);

        // The whole displacement is covered by the two walks end to end, so
        // nothing the creature did is missing from the playback.
        expect(
          hexDistance(_spawnTile, creature.position),
          hexDistance(bonus.path.first, bonus.path.last) +
              hexDistance(sweep.path.first, sweep.path.last),
        );
      },
    );

    test(
      'control: a non-Potent summon still records exactly one walk, starting '
      'at the spawn tile',
      () async {
        final ctx = _openRoad();

        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _walkerFormula),
              targetHex: _spawnTile,
            ),
          ),
        );

        expect(
          ctx.loop.lastMinionMoveEvents,
          hasLength(1),
          reason: 'no Potency, no bonus action, one walk',
        );
        expect(ctx.loop.lastMinionMoveEvents.single.path.first, _spawnTile);
        expect(
          ctx.loop.lastMinionMoveEvents.single.path.last,
          ctx.state.minions.single.position,
        );
      },
    );

    test('the UI playback callback receives both actions, in the same order',
        () async {
      final delivered = <List<MinionMoveEvent>>[];
      final ctx = _openRoad(
        onSummonMovementResolved: (moves, attacks) async {
          delivered.add(moves);
        },
      );

      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: _summonSpell(formula: _walkerFormula),
            targetHex: _spawnTile,
            isPotent: true,
          ),
        ),
      );

      expect(delivered, hasLength(1), reason: 'one Summons phase per turn');
      expect(
        delivered.single,
        hasLength(2),
        reason: 'the UI is shown the bonus action as well as the sweep',
      );
      expect(delivered.single.first.path.first, _spawnTile);
      expect(
        delivered.single.last.path.first,
        delivered.single.first.path.last,
      );
    });

    test('both Potent blows are recorded when both blows land', () async {
      // Spawn adjacent to the dummy so a melee creature can strike without
      // spending its whole budget closing (see M4_findings M4.16: a creature
      // that arrives with 0 movement left cannot lunge).
      const spawnTile = HexCoord(0, -2); // adjacent to dummy at (0,-3)
      final ctx = _setup();
      final dummyStartHp = ctx.dummy.hp;

      await ctx.loop.runTurn(
        TurnInput(
          action: SpellCastAction(
            spell: _summonSpell(formula: _brawlerFormula),
            targetHex: spawnTile,
            isPotent: true,
          ),
        ),
      );

      final creature = ctx.state.minions.single;
      expect(creature.position, spawnTile, reason: 'melee, already adjacent');
      expect(creature.stats.damage, 1);

      // Canonical state: two blows landed — unchanged by this fix.
      expect(ctx.dummy.hp, dummyStartHp - 2);

      // Playback: one AttackEvent per blow, both attributed to the creature.
      expect(
        ctx.loop.lastMinionAttackEvents,
        hasLength(2),
        reason: 'two blows, two attack animations',
      );
      // The lunge half of each action rides the movement stream alongside it.
      expect(ctx.loop.lastMinionMoveEvents, hasLength(2));
      expect(
        ctx.loop.lastMinionMoveEvents.every(
          (e) => e.lungeTile == ctx.dummy.position,
        ),
        isTrue,
        reason: 'a melee creature\'s whole attack IS the lunge-and-recoil',
      );
    });

    test(
      'the conveyor chain stays aligned with the walk that produced it',
      () async {
        // A non-Flying creature (conveyors do not move flyers) whose first
        // greedy step lands on a conveyor. The step happens during the Phase-5
        // bonus action, so `_creatureTurn` writes all three sinks at once —
        // and all three are now per-turn lists that only ever get appended to.
        const spawnTile = HexCoord(0, 3);
        const conveyorTile = HexCoord(0, 2); // first step toward the dummy
        final ctx = _setup(
          localPos: const HexCoord(0, 5),
          dummyPos: const HexCoord(0, -5),
          radius: 8,
          range: 8,
          tileEffects: {
            conveyorTile: const ConveyorTile(direction: HexCoord(0, -1)),
          },
        );

        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _plodderFormula),
              targetHex: spawnTile,
              isPotent: true,
            ),
          ),
        );

        final creature = ctx.state.minions.single;
        final chains = ctx.loop.lastConveyorChainEvents;
        expect(chains, hasLength(1), reason: 'one push, on the bonus step');
        expect(chains.single.entityId, creature.id);

        final moves = ctx.loop.lastMinionMoveEvents;
        expect(moves, hasLength(2));
        expect(
          moves.first.path,
          contains(conveyorTile),
          reason: 'the push belongs to the FIRST walk, which is now played '
              'back — the two halves of one action animate together',
        );
        expect(
          moves.first.path.last,
          chains.single.path.last,
          reason: 'the bonus walk ends where the conveyor left the creature',
        );
        expect(moves.last.path.first, moves.first.path.last);
        expect(moves.last.path.last, creature.position);
      },
    );
  });

  group('M4.17 — per-turn list lifecycle', () {
    test(
      'the minion event lists are fresh objects each turn and are never '
      'reassigned mid-turn',
      () async {
        // The direct identity/lifecycle regression. `_castContext` captures the
        // LIST OBJECTS, not the fields, so the two properties it depends on are
        // (a) the objects are replaced at the top of runTurn, and (b) they are
        // not replaced again by any later phase.
        final ctx = _openRoad();

        // Turn 1.
        final turn1Start = ctx.loop.lastMinionMoveEvents;
        final turn1AttacksStart = ctx.loop.lastMinionAttackEvents;
        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _walkerFormula),
              targetHex: _spawnTile,
              isPotent: true,
            ),
          ),
        );
        final turn1End = ctx.loop.lastMinionMoveEvents;

        expect(
          identical(turn1End, turn1Start),
          isFalse,
          reason: 'runTurn allocates a fresh list at the top of the turn',
        );
        expect(
          identical(ctx.loop.lastMinionAttackEvents, turn1AttacksStart),
          isFalse,
          reason: 'and does the same for the attack sink',
        );
        expect(turn1End, hasLength(2));
        final turn1Snapshot = List<MinionMoveEvent>.from(turn1End);

        // Turn 2: a second Potent summon, whose bonus action is exactly what
        // used to land in turn 1's list.
        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _plodderFormula),
              targetHex: const HexCoord(2, -3),
              isPotent: true,
            ),
          ),
        );
        final turn2End = ctx.loop.lastMinionMoveEvents;

        expect(
          identical(turn2End, turn1End),
          isFalse,
          reason: "turn 2 does not reuse turn 1's list object",
        );
        expect(
          turn1End,
          orderedEquals(turn1Snapshot),
          reason: "turn 2 never mutated or appended into turn 1's "
              'already-delivered list — the stale-capture half of M4.17',
        );
        // Turn 2 holds turn 2's events only: the new creature's bonus walk,
        // then both creatures' sweep walks in state.minions creation order.
        expect(turn2End, hasLength(3));
        final firstCreatureId = ctx.state.minions.first.id;
        final secondCreatureId = ctx.state.minions.last.id;
        expect(turn2End[0].minionId, secondCreatureId, reason: 'bonus action');
        expect(turn2End[1].minionId, firstCreatureId, reason: 'sweep, in order');
        expect(turn2End[2].minionId, secondCreatureId);
      },
    );

    test(
      'a turn with no summon activity leaves both lists empty rather than '
      'carrying the previous turn forward',
      () async {
        final ctx = _openRoad();

        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _brawlerFormula),
              targetHex: const HexCoord(3, 0),
              isPotent: true,
            ),
          ),
        );
        expect(ctx.loop.lastMinionMoveEvents, isNotEmpty);

        // Kill the creature off the books so the next turn has no sweep at all.
        ctx.state.minions.clear();
        await ctx.loop.runTurn(TurnInput(action: PassAction()));

        expect(ctx.loop.lastMinionMoveEvents, isEmpty);
        expect(ctx.loop.lastMinionAttackEvents, isEmpty);
      },
    );

    test(
      'the playback callback is handed the events as of the Summons phase, and '
      'the field still holds them afterwards',
      () async {
        List<MinionMoveEvent>? handed;
        final ctx = _openRoad(
          onSummonMovementResolved: (moves, attacks) async {
            handed = moves;
          },
        );

        await ctx.loop.runTurn(
          TurnInput(
            action: SpellCastAction(
              spell: _summonSpell(formula: _walkerFormula),
              targetHex: _spawnTile,
              isPotent: true,
            ),
          ),
        );

        expect(handed, isNotNull);
        expect(handed!.map((e) => e.path), ctx.loop.lastMinionMoveEvents.map((e) => e.path));
      },
    );
  });

  group('M4.17 — peer parity', () {
    test(
      'caster and verifier produce identical event sequences and identical '
      'canonical state',
      () async {
        final casterState = makeDuelState();
        final verifierState = makeDuelState();
        final pair = TurnSessionPair();
        final caster = TurnLoop(
          state: casterState,
          session: pair.sessionA,
          localPlayerId: 'player_a',
          verifyProof: alwaysOk,
          vkBytes: Uint8List(0),
        );
        final verifier = TurnLoop(
          state: verifierState,
          session: pair.sessionB,
          localPlayerId: 'player_b',
          verifyProof: alwaysOk,
          vkBytes: Uint8List(0),
        );

        // 2 fire / 2 air / 2 earth, as _brawlerFormula. Fire is certified
        // supreme on its generation, which is what backs the Potency claim at
        // PeerCastVerifier (an unbacked claim forfeits the match).
        final summon = spellFromElements(
          elements: const [
            BorderZone.fire,
            BorderZone.fire,
            BorderZone.air,
            BorderZone.air,
            BorderZone.earth,
            BorderZone.earth,
          ],
          variant: 51,
          name: 'Potent Brawler',
          isSummon: true,
        );
        caster.localChapterCommitments = [summon.commitmentHex];

        await Future.wait([
          caster.runTurn(
            TurnInput(
              action: SpellCastAction(
                spell: summon,
                targetHex: const HexCoord(2, 0),
                isPotent: true,
              ),
            ),
          ),
          verifier.runTurn(TurnInput(action: PassAction())),
        ]);

        expect(casterState.minions, hasLength(1), reason: 'sanity');
        expect(verifierState.minions, hasLength(1), reason: 'sanity');

        // The turn did not throw, so `_exchangeStateHash` already agreed; this
        // asserts it directly as well, because the whole claim of this fix is
        // that it moves nothing canonical.
        expect(
          bytesEqual(
            casterState.toCanonicalBytes(),
            verifierState.toCanonicalBytes(),
          ),
          isTrue,
        );

        expect(caster.lastMinionMoveEvents, hasLength(2));
        expect(
          verifier.lastMinionMoveEvents.map((e) => e.path),
          caster.lastMinionMoveEvents.map((e) => e.path),
          reason: 'both devices build the same playback timeline, in the same '
              'order — the bonus action is not a local-only flourish',
        );
        expect(
          verifier.lastMinionAttackEvents.length,
          caster.lastMinionAttackEvents.length,
        );
      },
    );
  });
}
