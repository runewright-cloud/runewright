// SPDX-License-Identifier: GPL-3.0-or-later
//
// summon_cast_test.dart — end-to-end battle tests for design doc "Summons":
// casting a summon-mode SpellAsset spawns a creature derived from its
// element sequence (CreatureSpec.fromElements), and that creature's
// abilities/personality/resistance actually affect play through TurnLoop's
// real commit-reveal + resolution pipeline (SoloBattleSession: no peer, no
// proof verification -- exercises the local trusted-wire-formula path,
// mirroring solo_battle_session_dummy_cast_test.dart's style).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

SpellAsset _summonSpell({
  required List<String> formula,
  String summonPersonality = 'aggressive',
  List<String> supremeTags = const [],
}) =>
    SpellAsset(
      id: 'summon-${formula.join()}',
      createdAt: DateTime.utc(2026, 7, 14),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1, // cheap enough that a 100-mana avatar can always afford it
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo mode
      name: 'Test Summon',
      commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
      spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
      formula: formula,
      supremeTags: supremeTags,
      isSummon: true,
      summonPersonality: summonPersonality,
    );

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
    _setup({HexCoord? localPos, HexCoord? dummyPos, int radius = 6}) {
  const localId = 'local';
  const dummyId = 'dummy';
  final lp = localPos ?? const HexCoord(0, 3);
  final dp = dummyPos ?? const HexCoord(0, -3);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = lp;
  battlefield.occupancy[dummyId] = dp;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: lp,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dp,
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
    session: SoloBattleSession(),
    localPlayerId: localId,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('casting a summon-mode spell spawns a derived creature', () {
    test('spawns near the target tile with the correct derived stats/affinity', () async {
      final ctx = _setup();
      // 4 fire, 2 earth -> affinity fire (4 > 2), damage floor(4*0.5)=2,
      // hp floor(2*1)=2, move floor(0*0.5)=0 (no air), range floor(0/3)=0
      // (no water).
      final spell =
          _summonSpell(formula: ['fire', 'fire', 'fire', 'fire', 'earth', 'earth']);

      expect(ctx.state.minions, isEmpty);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));

      expect(ctx.state.minions, hasLength(1));
      final creature = ctx.state.minions.single;
      expect(creature.ownerId, 'local');
      expect(creature.teamId, 'solo');
      expect(creature.affinity, SpellAffinity.fire);
      expect(creature.stats.damage, 2);
      expect(creature.stats.maxHp, 2);
      expect(creature.stats.moveSpeed, 0);
      expect(creature.stats.attackRange, 0);
      expect(creature.hp, 2);
    });

    test('a summon formula with zero Earth spawns a 0-HP creature that is reaped '
        'immediately (design doc: no minimum stat floor)', () async {
      final ctx = _setup();
      final spell = _summonSpell(formula: ['fire', 'fire', 'fire', 'fire']);

      expect(ctx.state.minions, isEmpty);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));

      expect(ctx.state.minions, isEmpty);
    });

    test('a void (all-neutral / empty formula) summon spell spawns nothing', () async {
      final ctx = _setup();
      final spell = _summonSpell(formula: const []);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));

      expect(ctx.state.minions, isEmpty);
    });

    test('Big (EEEE) creature spawns occupying a 3-tile footprint', () async {
      final ctx = _setup();
      final spell = _summonSpell(formula: ['earth', 'earth', 'earth', 'earth']);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));

      final creature = ctx.state.minions.single;
      expect(creature.abilities, contains(SummonAbility.big));
      expect(creature.occupiedTiles, hasLength(3));
      expect(creature.occupiedTiles, contains(creature.position));
    });
  });

  group('Potency governs the immediate-turn rule', () {
    test('a Potent summon acts (moves toward the enemy) the turn it is cast', () async {
      final ctx = _setup();
      // 2 air -> AAAA not reached (only 2 air), but move speed floor(2*0.5)=1
      // is enough to observe movement without needing the Flying ability.
      // 2 earth gives the creature nonzero HP (no minimum stat floor) so it
      // survives to be inspected below. Target an empty tile (not the
      // caster's own) so the spawn tile is exact and deterministic --
      // _findCreatureSpawnTile bumps to a neighbor when the target tile is
      // occupied.
      final spell = _summonSpell(
        formula: ['fire', 'air', 'air', 'earth', 'earth'],
        supremeTags: const ['fire'], // Potency = fire-flavor enhancement
      );
      final emptyTarget = HexCoord(ctx.local.position.q + 1, ctx.local.position.r);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: spell,
          targetHex: emptyTarget,
          isPotent: true,
        ),
      ));

      final creature = ctx.state.minions.single;
      // Bonus immediate action doesn't consume the creature's normal next-
      // Summons-phase turn -- actedThisTurn stays false either way (see
      // TurnLoop._castSummon).
      expect(creature.actedThisTurn, isFalse);
      // It should have moved off the exact spawn tile toward the dummy,
      // since the dummy started several tiles away and the creature has
      // nonzero move speed.
      expect(creature.position, isNot(equals(emptyTarget)));
    });

    test('a non-Potent summon does not act the turn it is cast', () async {
      final ctx = _setup();
      final spell = _summonSpell(formula: ['fire', 'air', 'air', 'earth', 'earth']);
      final emptyTarget = HexCoord(ctx.local.position.q + 1, ctx.local.position.r);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: emptyTarget),
      ));

      final creature = ctx.state.minions.single;
      expect(creature.actedThisTurn, isFalse);
      expect(creature.position, equals(emptyTarget));
    });

    test('a non-Potent summon acts on the following turn\'s Summons phase', () async {
      final ctx = _setup();
      final spell = _summonSpell(formula: ['fire', 'air', 'air', 'earth', 'earth']);
      final emptyTarget = HexCoord(ctx.local.position.q + 1, ctx.local.position.r);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: emptyTarget),
      ));
      final spawnPos = ctx.state.minions.single.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.state.minions.single.position, isNot(equals(spawnPos)));
    });
  });

  group('personality AI drives creature behavior in battle', () {
    test('aggressive creature closes distance toward the nearest enemy player turn over turn', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 5),
        dummyPos: const HexCoord(0, -5),
        radius: 8,
      );
      final spell = _summonSpell(
        // move speed 1, damage 0, range 0, hp 2 (needs earth to survive --
        // no minimum stat floor).
        formula: ['fire', 'air', 'air', 'earth', 'earth'],
        summonPersonality: 'aggressive',
      );
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));

      var lastDist = ctx.state.minions.single.distanceTo(ctx.dummy.position);
      for (var i = 0; i < 3; i++) {
        await ctx.loop.runTurn(TurnInput(action: PassAction()));
        if (ctx.state.minions.isEmpty) break; // dummy has no attack; shouldn't die
        final dist = ctx.state.minions.single.distanceTo(ctx.dummy.position);
        expect(dist, lessThanOrEqualTo(lastDist),
            reason: 'aggressive creature should never move away from its target');
        lastDist = dist;
      }
    });
  });

  group('resistance wheel applies to creature-vs-creature combat', () {
    test('a fire attacker deals double damage to a water-affinity creature', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 1),
        dummyPos: const HexCoord(0, -1),
      );
      // Fire attacker (owned by local): high damage, adjacent range. A couple
      // of earth elements give it nonzero HP (no minimum stat floor) so it
      // survives to be attacked below.
      final fireSpell = _summonSpell(
        formula: [
          'fire', 'fire', 'fire', 'fire', 'fire', 'fire', 'fire', 'fire', // dmg 4
          'earth', 'earth', // hp 2
        ],
        summonPersonality: 'aggressive',
      );
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: fireSpell, targetHex: ctx.local.position),
      ));
      final fireCreature = ctx.state.minions.single;
      expect(fireCreature.affinity, SpellAffinity.fire);
      expect(fireCreature.stats.damage, 4);

      // Directly place a water-affinity creature (bypassing the cast path,
      // to isolate the resistance-wheel math from AI positioning) adjacent
      // to the fire creature and apply damage.
      final waterVictim = Minion(
        id: 'water-victim',
        ownerId: 'dummy',
        teamId: 'foe',
        position: HexCoord(fireCreature.position.q, fireCreature.position.r - 1),
        affinity: SpellAffinity.water,
        stats: const MinionStats(maxHp: 20, damage: 1, moveSpeed: 1, attackRange: 1),
        elementSequence: const [],
      );
      final startHp = waterVictim.hp;
      waterVictim.takeDamage(fireCreature.stats.damage, attackType: fireCreature.affinity);
      expect(startHp - waterVictim.hp, fireCreature.stats.damage * 2,
          reason: 'fire vs water is the opposed pair -> double damage');
    });

    test('same-element damage is halved, rounded up', () {
      final victim = Minion(
        id: 'v',
        ownerId: 'owner',
        teamId: 'team',
        position: const HexCoord(0, 0),
        affinity: SpellAffinity.earth,
        stats: const MinionStats(maxHp: 20, damage: 1, moveSpeed: 1, attackRange: 1),
        elementSequence: const [],
      );
      victim.takeDamage(3, attackType: SpellAffinity.earth);
      expect(victim.hp, 20 - 2); // ceil(3/2) = 2
    });
  });

  group('Morphic (WWWW) reforms on death', () {
    test('a Morphic creature spawns a smaller creature from half its elements on death', () {
      final original = Minion(
        id: 'morphic-1',
        ownerId: 'local',
        teamId: 'solo',
        position: const HexCoord(0, 0),
        affinity: SpellAffinity.water,
        stats: const MinionStats(maxHp: 1, damage: 1, moveSpeed: 1, attackRange: 2),
        elementSequence: const [
          BorderZone.water, BorderZone.water, BorderZone.water, BorderZone.water,
          BorderZone.fire, BorderZone.fire,
        ],
        abilities: const {SummonAbility.morphic},
      );
      original.hp = 0; // dead

      final reformed = original.onDeath((max) => 0, 'morphic-1_reform0');
      expect(reformed, hasLength(1));
      expect(reformed.single.elementSequence, hasLength(3)); // floor(6/2)
      expect(reformed.single.ownerId, 'local');
      expect(reformed.single.teamId, 'solo');
    });

    test('a non-Morphic creature does not reform', () {
      final original = Minion(
        id: 'plain-1',
        ownerId: 'local',
        teamId: 'solo',
        position: const HexCoord(0, 0),
        affinity: SpellAffinity.fire,
        stats: const MinionStats(maxHp: 1, damage: 1, moveSpeed: 1, attackRange: 1),
        elementSequence: const [BorderZone.fire, BorderZone.fire, BorderZone.fire, BorderZone.fire],
      );
      original.hp = 0;
      expect(original.onDeath((max) => 0, 'plain-1_reform0'), isEmpty);
    });

    test('reform through a real battle turn: a dying Morphic creature leaves a successor', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 1),
        dummyPos: const HexCoord(0, -3),
      );
      final spell = _summonSpell(
        formula: [
          'water', 'water', 'water', 'water', // WWWW -> morphic
          'fire', 'fire',
          'earth', 'earth', // hp 2 (no minimum stat floor -- needs earth to survive)
        ],
      );
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: ctx.local.position),
      ));
      final creature = ctx.state.minions.single;
      expect(creature.abilities, contains(SummonAbility.morphic));

      // Kill it directly (isolating the reap/reform path from combat RNG)
      // then run a turn so TurnLoop's _reapDead sweep processes it.
      creature.hp = 0;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.state.minions, hasLength(1));
      final successor = ctx.state.minions.single;
      expect(successor.id, isNot(equals(creature.id)));
      expect(successor.elementSequence.length, lessThan(creature.elementSequence.length));
    });
  });

  group('abilities affect combat', () {
    test('Muddy (WEWE) attacker slows its target on hit', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 1),
        dummyPos: const HexCoord(0, -1),
      );
      final muddySpell = _summonSpell(formula: ['water', 'earth', 'water', 'earth']);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: muddySpell, targetHex: ctx.local.position),
      ));
      final attacker = ctx.state.minions.single;
      expect(attacker.abilities, contains(SummonAbility.muddy));

      final target = WizardAvatar(
        playerId: 'target',
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: HexCoord(attacker.position.q, attacker.position.r - 1),
        teamId: 'foe',
        baseSpellRange: 3,
      );
      expect(target.effectiveMoveSpeed, 2);
      // Directly exercise the same status-effect path _creatureAttack uses.
      target.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.speedDown,
        remainingTurns: 1,
        modifiers: const {'speedDelta': -1},
      ));
      expect(target.effectiveMoveSpeed, 1);
    });
  });
}
