// SPDX-License-Identifier: GPL-3.0-or-later
//
// line_of_sight_test.dart — the shared LOS predicate (docs/WALL_LOS_PLAN.md
// §5.1) and its consequences on spell resolution.
//
// Every test here asserts a BEHAVIOURAL difference, never a status chip or a
// field value: the reason `penetrating` shipped broken is that its only test
// asserted the chip landed on the avatar and never that it changed an outcome
// (§9).
//
// Covers:
//   - the predicate itself: clear line, wall mid-line, wall ON the target,
//     wall behind the target, Big creature mid-line and AS the target, the
//     shooter's own Big body, and a chasm (which deliberately does NOT block);
//   - the traversal-damage regression: an Earthen Blast at a target behind a
//     wall damages the wall and NOT the target (this test fails on the code
//     that shipped);
//   - a ranged summon cannot shoot through a wall but still advances;
//   - penetrating: the same blocked cast reaches the real target, and deals
//     penetrationDamage to entities en route.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/line_of_sight.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(String id, HexCoord pos, {String teamId = 'a', int hp = 24}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: hp,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 6,
    );

Minion _minion(
  String id,
  HexCoord pos, {
  String teamId = 'b',
  Set<SummonAbility> abilities = const {},
  int maxHp = 10,
  int attackRange = 0,
  int moveSpeed = 0,
}) =>
    Minion(
      id: id,
      ownerId: teamId,
      teamId: teamId,
      position: pos,
      affinity: SpellAffinity.fire,
      stats: MinionStats(
        maxHp: maxHp,
        damage: 3,
        moveSpeed: moveSpeed,
        attackRange: attackRange,
      ),
      elementSequence: const [],
      abilities: abilities,
    );

BattleState _state({
  List<WizardAvatar> avatars = const [],
  List<Minion> minions = const [],
  Map<HexCoord, TileEffect> tileEffects = const {},
  int radius = 6,
}) {
  final bf = Battlefield(radius: radius);
  for (final a in avatars) {
    bf.occupancy[a.playerId] = a.position;
  }
  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: List.of(avatars),
    teams: [
      for (final a in avatars) Team(id: a.teamId, playerIds: [a.playerId]),
    ],
    battlefield: bf,
    minions: List.of(minions),
  );
  // Through placeTerrain so the HP side-map is seeded exactly as it would be
  // in play — a fixture that skips it would test a state the game never has.
  tileEffects.forEach(state.placeTerrain);
  return state;
}

/// A one-formula spell. [formula] is a single triplet: affinity, then the two
/// effect-type zones that name the effect kind.
SpellAsset _spell(List<String> formula, {String name = 'Test'}) => SpellAsset(
      id: 'sp_$name',
      createdAt: DateTime.utc(2026, 8, 5),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: name,
      commitmentHex: '0x${'a' * 64}',
      spellHashHex: '0x${'b' * 64}',
      formula: formula,
    );

TurnLoop _loop(BattleState state, String localId) => TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: localId,
    );

void main() {
  // ── The predicate ─────────────────────────────────────────────────────────

  group('losBlockerTile', () {
    test('a clear line has no blocker', () {
      final state = _state();
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        isNull,
      );
    });

    test('a wall mid-line is the blocker', () {
      final state = _state(tileEffects: {
        const HexCoord(2, 0): ImpassableTile(),
      });
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        const HexCoord(2, 0),
      );
    });

    test('the FIRST wall along the line wins, not the nearest to the target', () {
      final state = _state(tileEffects: {
        const HexCoord(1, 0): ImpassableTile(),
        HexCoord(3, 0): ImpassableTile(),
      });
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(5, 0)),
        const HexCoord(1, 0),
      );
    });

    test('a wall ON the target tile does not block — it IS the target', () {
      final state = _state(tileEffects: {
        const HexCoord(4, 0): ImpassableTile(),
      });
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        isNull,
      );
    });

    test('a wall behind the target is irrelevant', () {
      final state = _state(tileEffects: {
        const HexCoord(5, 0): ImpassableTile(),
      });
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        isNull,
      );
    });

    test('a chasm mid-line does NOT block (movement yes, targeting no)', () {
      final state = _state(tileEffects: {
        const HexCoord(2, 0): ChasmTile(),
      });
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        isNull,
      );
    });

    test('a Big creature mid-line blocks on whichever of its tiles the line crosses',
        () {
      final big = _minion('big', const HexCoord(2, 0),
          abilities: const {SummonAbility.big});
      final state = _state(minions: [big]);
      final blocker =
          losBlockerTile(state, const HexCoord(0, 0), const HexCoord(5, 0));
      expect(blocker, isNotNull);
      expect(big.occupiedTiles, contains(blocker));
    });

    test('a single-tile creature mid-line does not block', () {
      final state = _state(minions: [_minion('small', const HexCoord(2, 0))]);
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(4, 0)),
        isNull,
      );
    });

    test('a Big creature you are AIMING AT never blocks itself', () {
      final big = _minion('big', const HexCoord(4, 0),
          abilities: const {SummonAbility.big});
      final state = _state(minions: [big]);
      // Aim at an outlying tile of its own footprint: the body between here
      // and there is the target's, so the shot lands.
      for (final t in big.occupiedTiles) {
        expect(losBlockerTile(state, const HexCoord(0, 0), t), isNull,
            reason: 'aiming at $t, part of the target creature');
      }
    });

    test("the shooter's own Big body never blocks its own shot", () {
      final big = _minion('big', const HexCoord(0, 0),
          teamId: 'a', abilities: const {SummonAbility.big});
      final state = _state(minions: [big]);
      for (final from in big.occupiedTiles) {
        expect(losBlockerTile(state, from, const HexCoord(4, 0)), isNull,
            reason: 'shooting from $from, part of the shooter');
      }
    });

    test('a dead Big creature stops blocking', () {
      final big = _minion('big', const HexCoord(2, 0),
          abilities: const {SummonAbility.big});
      final state = _state(minions: [big]);
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(5, 0)),
        isNotNull,
      );
      big.hp = 0;
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(5, 0)),
        isNull,
      );
    });

    test('penetrating: nothing blocks, ever', () {
      final state = _state(
        minions: [
          _minion('big', const HexCoord(2, 0),
              abilities: const {SummonAbility.big}),
        ],
        tileEffects: {const HexCoord(3, 0): const ImpassableTile()},
      );
      expect(
        losBlockerTile(state, const HexCoord(0, 0), const HexCoord(5, 0),
            penetrating: true),
        isNull,
      );
    });
  });

  // ── The traversal-damage regression ───────────────────────────────────────

  group('Earthen Blast through a wall (the bug this plan exists for)', () {
    // Before the fix, the path loop `break`ed at the wall — suppressing the
    // incidental en-route damage, which is Earthen Blast's whole upside — and
    // then hit the final target unconditionally anyway. The wall cost the
    // caster the bonus and cost the victim nothing.
    test('damages the wall and NOT the wizard standing behind it', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state(
        avatars: [caster, victim],
        tileEffects: {const HexCoord(2, 0): const ImpassableTile()},
      );
      final loop = _loop(state, 'caster');

      await loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(const ['earth', 'fire', 'fire'], name: 'EarthenBlast'),
          targetHex: victim.position,
        ),
      ));

      expect(victim.hp, 24, reason: 'the wall stopped the blast');
      // Earthen Blast is 2 earth damage; an Earth wall RESISTS earth, so
      // 2 → 1, leaving 3 of its 4 HP.
      expect(state.terrainHpAt(const HexCoord(2, 0)), 3);
    });

    test('with the wall gone, the same cast hits the wizard', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state(avatars: [caster, victim]);
      final loop = _loop(state, 'caster');

      await loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(const ['earth', 'fire', 'fire'], name: 'EarthenBlast'),
          targetHex: victim.position,
        ),
      ));

      expect(victim.hp, lessThan(24));
    });
  });

  // ── penetrating (Firey Inertia) ───────────────────────────────────────────

  group('penetrating', () {
    Future<(BattleState, WizardAvatar, WizardAvatar)> cast(
        {required bool withPenetrating}) async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state(
        avatars: [caster, victim],
        tileEffects: {const HexCoord(2, 0): const ImpassableTile()},
      );
      if (withPenetrating) {
        caster.activeStatusEffects.add(StatusEffect(
          effectTypeId: StatusEffectId.penetrating,
          remainingTurns: 3,
          modifiers: const {'penetrationDamage': 1},
        ));
      }
      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(const ['fire', 'fire', 'fire'], name: 'FireyBlast'),
          targetHex: victim.position,
        ),
      ));
      return (state, caster, victim);
    }

    test('without it the blast lands on the wall; with it, on the wizard',
        () async {
      final (blockedState, _, blockedVictim) = await cast(withPenetrating: false);
      expect(blockedVictim.hp, 24);
      expect(blockedState.tileEffects[const HexCoord(2, 0)], isNull,
          reason: 'Firey Blast is 4 damage; an Earth wall is 4 HP, normal '
              'against fire — one shot');

      final (_, _, victim) = await cast(withPenetrating: true);
      expect(victim.hp, lessThan(24), reason: 'the spell went through');
    });

    test('deals penetrationDamage to entities in the hexes en route', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final bystander = _avatar('bystander', const HexCoord(2, 0), teamId: 'b');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state(avatars: [caster, bystander, victim]);
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.penetrating,
        remainingTurns: 3,
        modifiers: const {'penetrationDamage': 1},
      ));

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(const ['fire', 'fire', 'fire'], name: 'FireyBlast'),
          targetHex: victim.position,
        ),
      ));

      expect(bystander.hp, 23, reason: '1 damage in passing, and only that');
      expect(victim.hp, lessThan(24), reason: 'the real target still gets hit');
    });
  });

  // ── Blocked summon casts land short of the wall ───────────────────────────

  group('tileBeforeBlocker', () {
    test('is the last clear hex before the blocker', () {
      expect(
        tileBeforeBlocker(
            const HexCoord(0, 0), const HexCoord(5, 0), const HexCoord(3, 0)),
        const HexCoord(2, 0),
      );
    });

    test('is the caster tile when the blocker is adjacent to them', () {
      expect(
        tileBeforeBlocker(
            const HexCoord(0, 0), const HexCoord(5, 0), const HexCoord(1, 0)),
        const HexCoord(0, 0),
      );
    });
  });

  group('a summon cast into a wall', () {
    SpellAsset summonSpell() => SpellAsset(
          id: 'sp_summon',
          createdAt: DateTime.utc(2026, 8, 5),
          tier: 12,
          t: 5,
          ownerPubkeyHex: '0x${'0' * 64}',
          manaCost: 1,
          segmentCount: 0,
          dotCount: 1,
          initialGrid: List<int>.filled(469, 0)..[234] = 1,
          proofBytes: Uint8List.fromList([1, 2, 3]),
          name: 'Test Summon',
          commitmentHex: '0x${'a' * 64}',
          spellHashHex: '0x${'b' * 64}',
          // Three earths, not four: EEEE is the Big ability, and a 3-tile
          // footprint makes the spawn search step sideways for reasons that
          // have nothing to do with line of sight.
          formula: const ['earth', 'earth', 'earth'],
          isSummon: true,
          summonPersonality: 'aggressive',
        );

    test('spawns on the last clear tile, NOT in the wall', () async {
      // A creature needs somewhere to stand, so unlike an incantation effect a
      // blocked summon does not resolve ON the blocker.
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final state = _state(
        avatars: [caster],
        tileEffects: {const HexCoord(3, 0): const ImpassableTile()},
      );

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: const HexCoord(5, 0),
        ),
      ));

      expect(state.minions, hasLength(1));
      expect(state.minions.single.position, const HexCoord(2, 0),
          reason: 'one hex short of the wall');
      expect(state.tileEffects[const HexCoord(3, 0)], isA<ImpassableTile>(),
          reason: 'the wall is untouched — a summon does not damage it');
    });

    test('with a clear line it spawns at the declared tile', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final state = _state(avatars: [caster]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: const HexCoord(5, 0),
        ),
      ));

      expect(state.minions.single.position, const HexCoord(5, 0));
    });

    test('a wall adjacent to the caster spawns it next to the caster', () async {
      // tileBeforeBlocker returns the caster's own tile; _castSummon's spawn
      // search then steps outward because a body already occupies it.
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final state = _state(
        avatars: [caster],
        tileEffects: {const HexCoord(1, 0): const ImpassableTile()},
      );

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: const HexCoord(4, 0),
        ),
      ));

      expect(state.minions, hasLength(1));
      final pos = state.minions.single.position;
      expect(pos, isNot(const HexCoord(1, 0)), reason: 'never inside the wall');
      expect(pos, isNot(caster.position), reason: 'bodies are exclusive');
      expect(hexDistance(pos, caster.position), 1);
    });
  });

  // ── Ranged summons ────────────────────────────────────────────────────────

  group('ranged summon', () {
    test('cannot shoot through a wall, but still advances toward its target',
        () async {
      final owner = _avatar('owner', const HexCoord(-4, 0), teamId: 'a');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final archer = _minion('archer', const HexCoord(0, 0),
          teamId: 'a', attackRange: 4, moveSpeed: 1);
      final state = _state(
        avatars: [owner, victim],
        minions: [archer],
        tileEffects: {const HexCoord(2, 0): const ImpassableTile()},
      );

      await _loop(state, 'owner')
          .runTurn(TurnInput(action: PassAction()));

      expect(victim.hp, 24, reason: 'the wall is in the way');
      expect(archer.position, isNot(const HexCoord(0, 0)),
          reason: 'it closes rather than freezing');
    });

    test('with a clear line it shoots without moving into contact', () async {
      final owner = _avatar('owner', const HexCoord(-4, 0), teamId: 'a');
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final archer = _minion('archer', const HexCoord(0, 0),
          teamId: 'a', attackRange: 4, moveSpeed: 1);
      final state = _state(avatars: [owner, victim], minions: [archer]);

      await _loop(state, 'owner')
          .runTurn(TurnInput(action: PassAction()));

      expect(victim.hp, lessThan(24));
    });
  });
}
