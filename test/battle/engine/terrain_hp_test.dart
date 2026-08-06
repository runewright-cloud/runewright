// SPDX-License-Identifier: GPL-3.0-or-later
//
// terrain_hp_test.dart — destructible spell-placed terrain
// (docs/WALL_LOS_PLAN.md §2.2–§2.6, §3.1–§3.8).
//
// Terrain used to be permanent and unkillable, which left a lava- or
// slow-tile spam build with no counterplay at all (§1/§4). Every tile a
// Terrain Sculpting spell can place now carries an HP pool, an elemental
// affinity, and a barrier slot.
//
// Covers, in plan order:
//   - the §2.2 worked example: all four Blast flavors against a 4 HP wall;
//   - the resistance wheel on every terrain type, not just walls;
//   - the 1-damage fallback (§2.4), typed (§3.1), and its exclusivity (§3.6);
//   - illusory terrain staying at 1 HP (§3.7);
//   - repair-on-matching / replace-on-differing, dropping barriers (§3.2/§3.4);
//   - all four barrier flavors on terrain, including the Airy collapse
//     knockback, the Firey aura, and the Watery regen that motivated the whole
//     scope expansion (§2.6/§4);
//   - serialization of both new side-maps (§7) — the test that catches a
//     missed field before a two-device run does.

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/terrain_ops.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart'
    show EffectKind, SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _wall = HexCoord(2, 0);

WizardAvatar _avatar(String id, HexCoord pos, {String teamId = 'a'}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 50,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 6,
    );

BattleState _state({
  List<WizardAvatar> avatars = const [],
  List<Minion> minions = const [],
  Map<HexCoord, TileEffect> terrain = const {},
  int radius = 6,
}) {
  final bf = Battlefield(radius: radius);
  for (final a in avatars) {
    bf.occupancy[a.playerId] = a.position;
  }
  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: List.of(avatars),
    teams: const [],
    battlefield: bf,
    minions: List.of(minions),
  );
  terrain.forEach(state.placeTerrain);
  return state;
}

ApplyContext _ctx({
  required BattleState state,
  required WizardAvatar caster,
  required SpellEffect effect,
  required HexCoord targetTile,
  required SpellAffinity affinity,
  required EffectKind kind,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: affinity,
        effectKind: kind,
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: Random(7),
    );

/// The Blast (Fire-Fire) flavor for [affinity], transcribed from
/// EffectResolver so the §2.2 table is exercised with the real numbers.
SpellEffect _blast(SpellAffinity affinity) => switch (affinity) {
      SpellAffinity.fire =>
        const DamageEffect(amount: 4, kind: DamageKind.direct),
      SpellAffinity.earth =>
        const DamageEffect(amount: 2, kind: DamageKind.traversal),
      SpellAffinity.water => const DamageEffect(
          amount: 2, kind: DamageKind.splash, splashRadius: 2),
      SpellAffinity.air =>
        const DamageEffect(amount: 2, kind: DamageKind.knockback, knockback: 1),
    };

/// Casts [affinity]'s Blast at the wall and returns its remaining HP.
int _blastWall(SpellAffinity affinity, {int times = 1}) {
  final caster = _avatar('caster', const HexCoord(0, 0));
  final state = _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});
  for (var i = 0; i < times; i++) {
    EffectApplicator.apply(_ctx(
      state: state,
      caster: caster,
      effect: _blast(affinity),
      targetTile: _wall,
      affinity: affinity,
      kind: EffectKind.damage,
    ));
  }
  return state.terrainHpAt(_wall);
}

void main() {
  // ── §2.2's worked example, exactly ────────────────────────────────────────

  group('the four Blasts against a 4 HP wall (§2.2)', () {
    test('Firey Blast (4, normal vs Earth) — one shot', () {
      expect(_blastWall(SpellAffinity.fire), 0);
    });

    test('Airy Blast (2, doubled — Air opposes Earth) — one shot', () {
      expect(_blastWall(SpellAffinity.air), 0);
    });

    test('Watery Blast (2, normal) — 2 damage', () {
      expect(_blastWall(SpellAffinity.water), 2);
    });

    test('Earthen Blast (2, halved — Earth resists Earth) — 1 damage', () {
      expect(_blastWall(SpellAffinity.earth), 3);
    });

    test('Earthen Blast four times destroys the wall', () {
      expect(_blastWall(SpellAffinity.earth, times: 3), 1);
      expect(_blastWall(SpellAffinity.earth, times: 4), 0);
    });

    test('a destroyed wall is gone from all three maps, not just tileEffects', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});
      addTerrainBarrier(
        state,
        _wall,
        BarrierState(
            element: SpellAffinity.earth, hp: 1, maxHp: 1, remainingTurns: 3),
      );

      damageTerrain(state, _wall, 99, SpellAffinity.fire, Random(1));

      expect(state.tileEffects[_wall], isNull);
      expect(state.terrainHp[_wall], isNull);
      expect(state.terrainBarriers[_wall], isNull);
    });
  });

  // ── The wheel on every terrain type (§9) ──────────────────────────────────

  group('the resistance wheel on every terrain type', () {
    // affinity of the tile → (resisting attack, opposing attack)
    final cases = <String, (TileEffect, SpellAffinity, SpellAffinity)>{
      'lava (Fire)':
          (const FloorIsLava(), SpellAffinity.fire, SpellAffinity.water),
      'wall (Earth)':
          (const ImpassableTile(), SpellAffinity.earth, SpellAffinity.air),
      'slow (Water)': (const SlowTile(), SpellAffinity.water, SpellAffinity.fire),
      'conveyor (Air)':
          (const ConveyorTile(), SpellAffinity.air, SpellAffinity.earth),
    };

    cases.forEach((label, spec) {
      final (tile, resists, vulnerable) = spec;
      test('$label halves its own element and doubles its opposite', () {
        // Same element: 2 → 1.
        final a = _state(terrain: {_wall: tile});
        final maxHp = terrainMaxHpOf(tile);
        damageTerrain(a, _wall, 2, resists, Random(1));
        expect(a.terrainHpAt(_wall), maxHp - 1, reason: '$label resists $resists');

        // Opposite element: 1 → 2.
        final b = _state(terrain: {_wall: tile});
        damageTerrain(b, _wall, 1, vulnerable, Random(1));
        expect(b.terrainHpAt(_wall), maxHp - 2,
            reason: '$label is vulnerable to $vulnerable');
      });
    });

    test('Watery Blast one-shots a lava tile; Firey Blast does not', () {
      // The pairing most likely to be transcribed backwards (§9).
      final doused = _state(terrain: {_wall: const FloorIsLava()});
      damageTerrain(doused, _wall, 1, SpellAffinity.water, Random(1));
      expect(doused.tileEffects[_wall], isNull, reason: '1 → 2 vs 2 HP');

      final stoked = _state(terrain: {_wall: const FloorIsLava()});
      damageTerrain(stoked, _wall, 1, SpellAffinity.fire, Random(1));
      expect(stoked.terrainHpAt(_wall), 1, reason: '1 → 1 vs 2 HP');
    });

    test('a chasm has no HP pool and cannot be damaged', () {
      final state = _state(terrain: {_wall: const ChasmTile()});
      final hit = damageTerrain(state, _wall, 99, SpellAffinity.air, Random(1));
      expect(hit.hitSomething, isFalse);
      expect(state.tileEffects[_wall], isA<ChasmTile>());
    });
  });

  // ── The 1-damage fallback (§2.4, §3.1, §3.6) ──────────────────────────────

  group('non-applicable effects fall back to 1 typed damage', () {
    test('two non-applicable Earth effects deal exactly 2 to a wall (§2.4)', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});

      // Reduce move speed (Air-Air) …
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const SpeedManipulationEffect(
            affinity: SpellAffinity.earth, speedDelta: -1),
        targetTile: _wall,
        affinity: SpellAffinity.earth,
        kind: EffectKind.speedManipulation,
      ));
      // … and mana reflection (Water-Water).
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ReflectionEffect(triggerCount: 2, durationTurns: 3),
        targetTile: _wall,
        affinity: SpellAffinity.earth,
        kind: EffectKind.reflections,
      ));

      // Earth-typed 1s against an Earth wall halve to 1 each: 4 - 2 = 2.
      expect(state.terrainHpAt(_wall), 2);
    });

    test('the fallback is TYPED — an Airy one deals 2 to an Earth wall (§3.1)',
        () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ReflectionEffect(triggerCount: 2, durationTurns: 3),
        targetTile: _wall,
        affinity: SpellAffinity.air,
        kind: EffectKind.reflections,
      ));

      expect(state.terrainHpAt(_wall), 2, reason: '1 doubled by the wheel');
    });

    test('exclusive: a Reflections cast on an occupied lava tile leaves it alone',
        () {
      // The double-dip is the likely bug (§3.6): the effect found its
      // recipient, so the terrain under them is not collateral.
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final victim = _avatar('victim', _wall, teamId: 'b');
      final state = _state(
        avatars: [caster, victim],
        terrain: {_wall: const FloorIsLava()},
      );

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ReflectionEffect(triggerCount: 2, durationTurns: 3),
        targetTile: _wall,
        affinity: SpellAffinity.water,
        kind: EffectKind.reflections,
      ));

      expect(state.reflectionLinks, hasLength(1), reason: 'the wizard was linked');
      expect(state.terrainHpAt(_wall), 2, reason: 'the lava is untouched');
    });

    test('an empty tile with no terrain and no entity does nothing at all', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state(avatars: [caster]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ReflectionEffect(triggerCount: 2, durationTurns: 3),
        targetTile: _wall,
        affinity: SpellAffinity.air,
        kind: EffectKind.reflections,
      ));

      expect(state.reflectionLinks, isEmpty);
      expect(state.tileEffects, isEmpty);
    });

    test('a self-buff resolving on bare terrain is lost and chips it (§2.5)', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});

      // Firey Scrying Pool: never reads the target tile, but a blocked cast
      // buys wall damage instead of the reveal.
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const DivinationEffect(
            affinity: SpellAffinity.fire,
            revealsCounterCharms: true,
            durationTurns: 0),
        targetTile: _wall,
        affinity: SpellAffinity.fire,
        kind: EffectKind.divination,
      ));

      expect(caster.canRevealCounterCharms, isFalse,
          reason: 'the buff did not land');
      expect(state.terrainHpAt(_wall), 3, reason: '1 fire damage, normal vs Earth');
    });
  });

  // ── Illusory terrain (§3.7) ───────────────────────────────────────────────

  test('an illusory terrain copy dies to a single point of damage', () {
    final caster = _avatar('caster', const HexCoord(0, 0));
    final state = _state(avatars: [caster]);
    state.placeTerrain(_wall, const ImpassableTile(), illusionOwner: 'caster');

    expect(state.terrainHpAt(_wall), 1,
        reason: 'not the wall type\'s 4 — the illusion map wins');
    damageTerrain(state, _wall, 1, SpellAffinity.earth, Random(1));

    expect(state.tileEffects[_wall], isNull);
    expect(state.illusionTerrainTiles[_wall], isNull);
  });

  // ── Placement: repair, replace, and dropped barriers (§3.2, §3.4) ─────────

  group('Terrain Sculpting onto existing terrain', () {
    test('the SAME type repairs it to full instead of no-opping (§3.2)', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});
      damageTerrain(state, _wall, 2, SpellAffinity.fire, Random(1));
      expect(state.terrainHpAt(_wall), 2);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const TileModificationEffect(
            affinity: SpellAffinity.earth, tileEffect: ImpassableTile()),
        targetTile: _wall,
        affinity: SpellAffinity.earth,
        kind: EffectKind.tileModification,
      ));

      expect(state.terrainHpAt(_wall), 4);
    });

    test('a DIFFERING type replaces outright and drops the old barriers (§3.4)',
        () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state =
          _state(avatars: [caster], terrain: {_wall: const ImpassableTile()});
      addTerrainBarrier(
        state,
        _wall,
        BarrierState(
            element: SpellAffinity.earth, hp: 4, maxHp: 4, remainingTurns: 3),
      );

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const TileModificationEffect(
            affinity: SpellAffinity.fire, tileEffect: FloorIsLava()),
        targetTile: _wall,
        affinity: SpellAffinity.fire,
        kind: EffectKind.tileModification,
      ));

      expect(state.tileEffects[_wall], isA<FloorIsLava>());
      expect(state.terrainHpAt(_wall), 2, reason: 'lava\'s own full pool');
      expect(state.terrainBarriers[_wall], isNull, reason: 'no inherited armor');
    });
  });

  // ── Barrier on terrain (§2.3, §2.6) ───────────────────────────────────────

  group('barrier on terrain', () {
    BattleState imbue(SpellAffinity affinity, BarrierEffect effect,
        {TileEffect tile = const ImpassableTile()}) {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state(avatars: [caster], terrain: {_wall: tile});
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: effect,
        targetTile: _wall,
        affinity: affinity,
        kind: EffectKind.barrier,
      ));
      return state;
    }

    test('Earthen (4 HP) absorbs before the terrain HP', () {
      final state = imbue(SpellAffinity.earth,
          const BarrierEffect(hp: 4, durationTurns: 3));
      expect(state.terrainBarriers[_wall]?[SpellAffinity.earth]?.hp, 4);

      // A Firey Blast that would one-shot a bare wall is eaten by the barrier.
      damageTerrain(state, _wall, 4, SpellAffinity.fire, Random(1));
      expect(state.tileEffects[_wall], isA<ImpassableTile>());
      expect(state.terrainHpAt(_wall), 4, reason: 'the wall itself is untouched');
    });

    test('Firey scorches every adjacent tile at end of turn', () {
      final state = imbue(
        SpellAffinity.fire,
        const BarrierEffect(hp: 2, durationTurns: 3, fireAura: true),
      );
      final neighbour = _avatar('neighbour', const HexCoord(3, 0), teamId: 'b');
      state.avatars.add(neighbour);
      state.battlefield.occupancy['neighbour'] = neighbour.position;

      tickTerrainBarrierAuras(state, Random(1), (_, _) {});

      expect(neighbour.hp, 23, reason: 'a burning wall');
    });

    test('Watery pays mana to whoever stands on the tile (§4)', () {
      // The case the whole scope expansion exists for: an ImpassableTile can
      // never be occupied, so the rider is only live on lava/slow/conveyor.
      final state = imbue(
        SpellAffinity.water,
        const BarrierEffect(hp: 2, durationTurns: 3, manaRegenBonusPct: 10),
        tile: const FloorIsLava(),
      );
      final burner = _avatar('burner', _wall, teamId: 'b');
      state.avatars.add(burner);
      state.battlefield.occupancy['burner'] = burner.position;

      var paid = 0;
      tickTerrainBarrierAuras(state, Random(1), (av, amount) {
        expect(av.playerId, 'burner');
        paid += amount;
      });

      expect(paid, 10, reason: '10% of a 100 mana pool');
    });

    test('Watery on a wall pays nobody — nothing can stand there', () {
      final state = imbue(
        SpellAffinity.water,
        const BarrierEffect(hp: 2, durationTurns: 3, manaRegenBonusPct: 10),
      );
      var paid = 0;
      tickTerrainBarrierAuras(state, Random(1), (_, amount) => paid += amount);
      expect(paid, 0);
    });

    test('Airy knocks back adjacent entities when it collapses (§2.6)', () {
      final state = imbue(
        SpellAffinity.air,
        const BarrierEffect(hp: 2, durationTurns: 3, freeMoveOnCollapse: true),
      );
      final bystander = _avatar('bystander', const HexCoord(3, 0), teamId: 'b');
      state.avatars.add(bystander);
      state.battlefield.occupancy['bystander'] = bystander.position;

      // 2 fire damage exactly exhausts the barrier and collapses it.
      damageTerrain(state, _wall, 2, SpellAffinity.fire, Random(1));

      expect(state.terrainBarriers[_wall], isNull, reason: 'collapsed');
      expect(bystander.position, const HexCoord(4, 0),
          reason: 'shoved one tile directly away from the wall');
      expect(state.battlefield.occupancy['bystander'], const HexCoord(4, 0),
          reason: 'occupancy tracks the push');
    });

    test('a barrier aimed at an occupied tile still goes to the occupant', () {
      // §3.6 again, from the other side: terrain only receives it when the
      // effect found no entity.
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final ally = _avatar('ally', _wall, teamId: 'a');
      final state =
          _state(avatars: [caster, ally], terrain: {_wall: const FloorIsLava()});

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const BarrierEffect(hp: 4, durationTurns: 3),
        targetTile: _wall,
        affinity: SpellAffinity.earth,
        kind: EffectKind.barrier,
      ));

      expect(ally.barriers[SpellAffinity.earth], isNotNull);
      expect(state.terrainBarriers[_wall], isNull);
    });

    test('an expiring Airy barrier collapses the same way a burst one does', () {
      final state = imbue(
        SpellAffinity.air,
        const BarrierEffect(hp: 2, durationTurns: 1, freeMoveOnCollapse: true),
      );
      final bystander = _avatar('bystander', const HexCoord(3, 0), teamId: 'b');
      state.avatars.add(bystander);
      state.battlefield.occupancy['bystander'] = bystander.position;

      tickTerrainBarriers(state, Random(1));

      expect(state.terrainBarriers[_wall], isNull);
      expect(bystander.position, const HexCoord(4, 0));
    });
  });

  // ── Determinism (§7) ──────────────────────────────────────────────────────

  group('canonical serialization', () {
    test('two states differing only in terrain HP hash differently', () {
      final a = _state(terrain: {_wall: const ImpassableTile()});
      final b = _state(terrain: {_wall: const ImpassableTile()});
      expect(a.toCanonicalBytes(), b.toCanonicalBytes());

      damageTerrain(b, _wall, 1, SpellAffinity.fire, Random(1));
      expect(a.toCanonicalBytes(), isNot(b.toCanonicalBytes()));
    });

    test('two states differing only in a terrain barrier hash differently', () {
      final a = _state(terrain: {_wall: const ImpassableTile()});
      final b = _state(terrain: {_wall: const ImpassableTile()});

      addTerrainBarrier(
        b,
        _wall,
        BarrierState(
            element: SpellAffinity.water, hp: 2, maxHp: 2, remainingTurns: 3),
      );

      expect(a.toCanonicalBytes(), isNot(b.toCanonicalBytes()));
    });

    test('barrier insertion order does not change the bytes', () {
      // An unsorted inner map is the easy way to produce a mismatch that only
      // shows up on a two-device run (§7).
      BattleState build(List<SpellAffinity> order) {
        final s = _state(terrain: {_wall: const ImpassableTile()});
        for (final el in order) {
          addTerrainBarrier(s, _wall,
              BarrierState(element: el, hp: 2, maxHp: 2, remainingTurns: 3));
        }
        return s;
      }

      expect(
        build([SpellAffinity.air, SpellAffinity.fire]).toCanonicalBytes(),
        build([SpellAffinity.fire, SpellAffinity.air]).toCanonicalBytes(),
      );
    });
  });
}
