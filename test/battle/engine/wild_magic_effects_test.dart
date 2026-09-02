// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_effects_test.dart — the twelve wild-magic effects
// (docs/WILD_MAGIC_PLAN.md §12, "per-effect tests").
//
// Every effect gets: its base value, one bracketed value, SYMMETRY (the caster
// is affected too — §10 invariant 10), and a canonical-bytes round trip, since
// every field WildMagicState carries is consensus state and a missing byte is
// a silent mid-match desync.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/wild_magic_applicator.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart'
    show EffectKind, SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(
  String id,
  HexCoord pos, {
  String teamId = 'a',
  int hp = 24,
  int mana = 100,
}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: hp,
      mana: mana,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 3,
    );

BattleState _state({
  required List<WizardAvatar> avatars,
  Map<HexCoord, TileEffect> tileEffects = const {},
  List<Minion> minions = const [],
  int radius = 4,
  int turnNumber = 1,
}) {
  final battlefield = Battlefield(radius: radius);
  for (final a in avatars) {
    battlefield.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: avatars,
    teams: const [],
    battlefield: battlefield,
    tileEffects: Map.of(tileEffects),
    minions: List.of(minions),
    turnNumber: turnNumber,
  );
}

HashRng _rng([int salt = 0]) =>
    HashRng(Uint8List.fromList(List.generate(32, (i) => (i + salt) & 0xFF)));

/// Fires one wild-magic effect and returns the events it emitted.
List<WildMagicEvent> _fire(
  BattleState state,
  WizardAvatar caster,
  WildMagicRow row,
  SpellAffinity element, {
  int bracketSteps = 0,
  WildMagicHooks? hooks,
  HashRng? rng,
}) {
  final events = <WildMagicEvent>[];
  WildMagicApplicator.apply(
    WildMagicApplyContext(
      state: state,
      caster: caster,
      rng: rng ?? _rng(),
      trigger: WildMagicTrigger(
        row: row,
        element: element,
        bracketSteps: bracketSteps,
      ),
      events: events,
      hooks: hooks,
    ),
  );
  return events;
}

class _RecordingHooks implements WildMagicHooks {
  final List<(Set<String>, int, String)> forced = [];

  @override
  void queueForcedCast(Set<String> ids, int count, String tag) =>
      forced.add((ids, count, tag));
}

void main() {
  // ── Row 1, Fire — Burning Hot ─────────────────────────────────────────────

  group('Burning Hot', () {
    test('arms +1 damage for NEXT turn, base bracket', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 3);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire);

      expect(state.wildMagic.spellDamageBonusFor(3), 0, reason: 'not this turn');
      expect(state.wildMagic.spellDamageBonusFor(4), 1);
      expect(state.wildMagic.spellDamageBonusFor(5), 0);
    });

    test('bracket steps scale the bonus', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 3);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire,
          bracketSteps: 2);
      expect(state.wildMagic.spellDamageBonusFor(4), 3);
    });

    test('two Burning Hots targeting the same turn SUM', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 3);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire);
      expect(state.wildMagic.spellDamageBonusFor(4), 2);
    });

    test('SYMMETRY: it boosts the damage of any caster, including the enemy', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final state = _state(avatars: [me, foe], turnNumber: 3);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire);
      state.turnNumber = 4;

      // The FOE casts a 4-damage direct hit at the wild-magic caster.
      EffectApplicator.apply(
        ApplyContext(
          descriptor: const EffectDescriptor(
            affinity: SpellAffinity.fire,
            effectKind: EffectKind.damage,
            spellEffect: DamageEffect(amount: 4, kind: DamageKind.direct),
          ),
          targetTile: me.position,
          caster: foe,
          state: state,
          rng: _rng(),
        ),
      );
      expect(me.hp, 24 - 5, reason: '4 base + 1 Burning Hot');
    });

    test('applies once per damage EFFECT, so a 3-formula spell gets it 3×', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final state = _state(avatars: [me, foe], turnNumber: 3);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.fire);
      state.turnNumber = 4;

      for (var i = 0; i < 3; i++) {
        EffectApplicator.apply(
          ApplyContext(
            descriptor: const EffectDescriptor(
              affinity: SpellAffinity.fire,
              effectKind: EffectKind.damage,
              spellEffect: DamageEffect(amount: 2, kind: DamageKind.direct),
            ),
            targetTile: foe.position,
            caster: me,
            state: state,
            rng: _rng(),
          ),
        );
      }
      expect(foe.hp, 24 - 9, reason: '3 × (2 base + 1)');
    });
  });

  // ── Row 1, Earth — Mountains ──────────────────────────────────────────────

  group('Mountains', () {
    test('walls every tile adjacent to every wizard, on an expiry clock', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(3, 0), teamId: 'b');
      final state = _state(avatars: [me, foe], turnNumber: 5);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);

      for (final around in [me.position, foe.position]) {
        for (final n in hexNeighborsOf(around)) {
          if (!state.battlefield.isInBounds(n)) continue;
          if (n == me.position || n == foe.position) continue;
          expect(state.tileEffects[n], isA<ImpassableTile>(), reason: '$n');
          expect(state.expiringTiles[n], 6, reason: 'turnNumber + 1 + 0');
        }
      }
    });

    test('bracket steps extend the expiry', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 5);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
          bracketSteps: 2);
      expect(state.expiringTiles.values.first, 8);
    });

    test('does not overwrite existing terrain — no hidden destroy effect', () {
      final me = _avatar('a', const HexCoord(0, 0));
      const lavaTile = HexCoord(1, 0);
      final state = _state(
        avatars: [me],
        tileEffects: {lavaTile: const FloorIsLava()},
      );
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(state.tileEffects[lavaTile], isA<FloorIsLava>());
      expect(state.expiringTiles.containsKey(lavaTile), isFalse);
    });

    test('does not bury an occupied tile', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(1, 0), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(state.tileEffects.containsKey(foe.position), isFalse);
      expect(state.tileEffects.containsKey(me.position), isFalse);
    });

    test('SYMMETRY: the caster is walled in too', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(3, 0), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      final events = _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(events.single.affectedPlayerIds, containsAll(['a', 'b']));
      expect(state.tileEffects.containsKey(const HexCoord(1, 0)), isTrue);
    });
  });

  // ── Row 1, Water — Mana Flood ─────────────────────────────────────────────

  group('Mana Flood', () {
    test('fills every living wizard to max, caster included', () {
      final me = _avatar('a', const HexCoord(0, 0), mana: 5);
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b', mana: 0);
      final dead = _avatar('c', const HexCoord(-2, 0), teamId: 'c', hp: 0, mana: 0);
      final state = _state(avatars: [me, foe, dead]);

      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.water);

      expect(me.mana, 100);
      expect(foe.mana, 100);
      expect(dead.mana, 0, reason: 'the dead do not drink');
    });
  });

  // ── Row 1, Air — Zephyr ───────────────────────────────────────────────────

  group('Zephyr', () {
    test('relocates every wizard and minion, keeping occupancy in step', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(3, 0), teamId: 'b');
      final minion = Minion(
        id: 'm1',
        ownerId: 'a',
        teamId: 'a',
        position: const HexCoord(1, 1),
        affinity: SpellAffinity.fire,
        stats: const MinionStats(maxHp: 3, damage: 1, moveSpeed: 1, attackRange: 1),
        elementSequence: const [],
        abilities: const {},
      );
      final state = _state(avatars: [me, foe], minions: [minion]);

      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.air);

      // position and battlefield.occupancy are two mirrors of one fact.
      expect(state.battlefield.occupancy['a'], me.position);
      expect(state.battlefield.occupancy['b'], foe.position);
      // Everyone lands somewhere legal and distinct.
      final occupied = {me.position, foe.position, minion.position};
      expect(occupied.length, 3);
      for (final p in occupied) {
        expect(state.battlefield.isInBounds(p), isTrue);
      }
    });

    test('never lands anyone on a wall or a chasm', () {
      final me = _avatar('a', const HexCoord(0, 0));
      // Wall off everything except a small pocket.
      final tiles = <HexCoord, TileEffect>{};
      for (var q = -4; q <= 4; q++) {
        for (var r = -4; r <= 4; r++) {
          final h = HexCoord(q, r);
          if (hexDistance(const HexCoord(0, 0), h) > 4) continue;
          if (h == const HexCoord(2, 2)) continue;
          tiles[h] = q.isEven ? const ImpassableTile() : const ChasmTile();
        }
      }
      final state = _state(avatars: [me], tileEffects: tiles);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.air);
      expect(me.position, const HexCoord(2, 2));
    });

    test('is deterministic for a given RNG seed', () {
      HexCoord run() {
        final me = _avatar('a', const HexCoord(0, 0));
        final state = _state(avatars: [me]);
        _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.air,
            rng: _rng(7));
        return me.position;
      }

      expect(run(), run());
    });
  });

  // ── Row 2, Fire — Spontaneous Combustion ──────────────────────────────────

  group('Spontaneous Combustion', () {
    test('queues a forced cast for every living wizard', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final dead = _avatar('c', const HexCoord(-2, 0), teamId: 'c', hp: 0);
      final state = _state(avatars: [me, foe, dead]);
      final hooks = _RecordingHooks();

      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire, hooks: hooks);

      expect(hooks.forced.length, 1);
      expect(hooks.forced.single.$1, {'a', 'b'});
      expect(hooks.forced.single.$2, 1);
      expect(hooks.forced.single.$3, 'spontaneousCombustion');
    });

    test('bracket steps raise the count per player', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      final hooks = _RecordingHooks();
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire,
          bracketSteps: 2, hooks: hooks);
      expect(hooks.forced.single.$2, 3);
    });

    test('no hooks (unit context) is a safe no-op, not a crash', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      expect(
        () => _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire),
        returnsNormally,
      );
    });
  });

  // ── Row 2, Earth — Chasm ──────────────────────────────────────────────────

  group('Chasm', () {
    test('lays a ChasmTile along one full axis through the origin', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 2);
      final events = _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.earth);

      final chasms = state.tileEffects.entries
          .where((e) => e.value is ChasmTile)
          .map((e) => e.key)
          .toList();
      expect(chasms, isNotEmpty);
      expect(chasms.contains(const HexCoord(0, 0)), isTrue,
          reason: 'every axis passes through the centre');
      // All on one axis.
      final axis = events.single.note;
      for (final c in chasms) {
        switch (axis) {
          case 'q = 0':
            expect(c.q, 0);
          case 'r = 0':
            expect(c.r, 0);
          default:
            expect(c.q + c.r, 0);
        }
      }
      for (final c in chasms) {
        expect(state.expiringTiles[c], 3);
      }
    });

    test('the axis is one of exactly three, chosen from the RNG', () {
      final notes = <String>{};
      for (var s = 0; s < 30; s++) {
        final me = _avatar('a', const HexCoord(0, 0));
        final state = _state(avatars: [me]);
        notes.addAll(
          _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.earth,
                  rng: _rng(s))
              .map((e) => e.note!),
        );
      }
      expect(notes, isNotEmpty);
      expect(notes.every((n) => ['q = 0', 'r = 0', 'q + r = 0'].contains(n)),
          isTrue);
    });

    test('a live chasm cannot be paved over by a tile-modification spell', () {
      final me = _avatar('a', const HexCoord(0, 0));
      const target = HexCoord(1, 0);
      final state = _state(
        avatars: [me],
        tileEffects: {target: const ChasmTile()},
      );
      EffectApplicator.apply(
        ApplyContext(
          descriptor: const EffectDescriptor(
            affinity: SpellAffinity.earth,
            effectKind: EffectKind.tileModification,
            spellEffect: TileModificationEffect(
              affinity: SpellAffinity.earth,
              tileEffect: ImpassableTile(),
            ),
          ),
          targetTile: target,
          caster: me,
          state: state,
          rng: _rng(),
        ),
      );
      expect(state.tileEffects[target], isA<ChasmTile>());
    });
  });

  // ── Row 2, Water — Glacier ────────────────────────────────────────────────

  group('Glacier', () {
    test('ices every tile that has no terrain, and only those', () {
      final me = _avatar('a', const HexCoord(0, 0));
      const walled = HexCoord(1, 0);
      final state = _state(
        avatars: [me],
        tileEffects: {walled: const ImpassableTile()},
        turnNumber: 4,
      );
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.water);

      expect(state.tileEffects[walled], isA<ImpassableTile>());
      expect(state.tileEffects[const HexCoord(0, 0)], isA<IceTile>());
      expect(state.tileEffects[const HexCoord(2, 0)], isA<IceTile>());
      // Radius 4 → 61 tiles, minus the one wall.
      expect(state.tileEffects.values.whereType<IceTile>().length, 60);
      expect(state.expiringTiles[const HexCoord(2, 0)], 5);
    });

    test('bracket steps extend the thaw', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 4);
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.water,
          bracketSteps: 3);
      expect(state.expiringTiles[const HexCoord(0, 0)], 8);
    });
  });

  // ── Row 2, Air — Updraft ──────────────────────────────────────────────────

  group('Updraft', () {
    test('grants flying to every living wizard for 2 turns', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.air);

      for (final av in [me, foe]) {
        expect(av.isFlying, isTrue);
        expect(
          av.activeStatusEffects
              .firstWhere((f) => f.effectTypeId == StatusEffectId.flying)
              .remainingTurns,
          2,
        );
      }
    });

    test('bracket steps extend the duration; re-firing stacks it', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.air,
          bracketSteps: 2);
      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.air,
          bracketSteps: 2);
      final flying = me.activeStatusEffects
          .where((f) => f.effectTypeId == StatusEffectId.flying)
          .toList();
      // Still ONE entry — re-applying a status merges into the effect already
      // there (StatusEffect.applyTo) — but its duration is the sum of both
      // 4-turn grants, per the 2026-08-07 stacking rule.
      expect(flying.length, 1);
      expect(flying.single.remainingTurns, 8);
    });
  });

  // ── Row 3 — the persistent globals ────────────────────────────────────────

  group('Phoenix', () {
    test('marks every living wizard, caster included', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final dead = _avatar('c', const HexCoord(-2, 0), teamId: 'c', hp: 0);
      final state = _state(avatars: [me, foe, dead]);
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.fire);
      expect(state.wildMagic.phoenixWindows.keys.toSet(), {'a', 'b'});
      // Armed for the two rounds after this one — not this one.
      expect(state.wildMagic.phoenixAvailableFor('a', state.turnNumber), isFalse);
      expect(
          state.wildMagic.phoenixAvailableFor('a', state.turnNumber + 1), isTrue);
      expect(
          state.wildMagic.phoenixAvailableFor('a', state.turnNumber + 2), isTrue);
      expect(state.wildMagic.phoenixAvailableFor('a', state.turnNumber + 3),
          isFalse);
    });
  });

  group('Statuesque', () {
    test('arms for next round, not this one — the triggering cast cannot '
        'break it', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.earth);
      expect(state.wildMagic.statuesqueWindows.keys.toSet(), {'a', 'b'});
      expect(
          state.wildMagic.statuesqueActiveFor('a', state.turnNumber), isFalse);
      expect(state.wildMagic.statuesqueActiveFor('a', state.turnNumber + 1),
          isTrue);
      expect(state.wildMagic.statuesqueActiveFor('a', state.turnNumber + 2),
          isTrue);
      expect(state.wildMagic.statuesqueActiveFor('a', state.turnNumber + 3),
          isFalse);
    });
  });

  group('Rippling Reflections', () {
    test('arms the coin at 50%', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.water);
      expect(state.wildMagic.ripplingFizzlePct, 50);
      // One round, starting next round.
      expect(state.wildMagic.ripplingFizzlePctOn(state.turnNumber), isNull);
      expect(state.wildMagic.ripplingFizzlePctOn(state.turnNumber + 1), 50);
      expect(state.wildMagic.ripplingFizzlePctOn(state.turnNumber + 2), isNull);
    });

    test('a second firing does NOT reset a drifted counter', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.water);
      state.wildMagic.ripplingFizzlePct = 80;
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.water);
      expect(state.wildMagic.ripplingFizzlePct, 80);
    });
  });

  group('Scattered Gusts', () {
    test('arms every living wizard for next round, individually', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final dead = _avatar('c', const HexCoord(-2, 0), teamId: 'c', hp: 0);
      final state = _state(avatars: [me, foe, dead]);
      expect(state.wildMagic.scatteredGustsArmedFrom, isEmpty);
      _fire(state, me, WildMagicRow.ascendingRun, SpellAffinity.air);
      expect(state.wildMagic.scatteredGustsArmedFrom.keys.toSet(), {'a', 'b'});
      // Not consumable by a cast still inside the round that armed it.
      expect(state.wildMagic.scatteredGustPendingFor('a', state.turnNumber),
          isFalse);
      expect(state.wildMagic.scatteredGustPendingFor('a', state.turnNumber + 1),
          isTrue);
    });
  });

  // ── §7.4 — canonical bytes ────────────────────────────────────────────────

  group('BattleState.toCanonicalBytes covers all wild-magic state', () {
    BattleState fresh() => _state(avatars: [
          _avatar('a', const HexCoord(0, 0)),
          _avatar('b', const HexCoord(2, 0), teamId: 'b'),
        ]);

    void expectMutationVisible(String label, void Function(BattleState) mutate) {
      test('$label changes the state hash', () {
        final s = fresh();
        final before = s.toCanonicalBytes();
        mutate(s);
        expect(s.toCanonicalBytes(), isNot(before), reason: label);
      });
    }

    expectMutationVisible('Burning Hot', (s) => s.wildMagic.armSpellDamageBonus(4, 2));
    expectMutationVisible(
        'Phoenix', (s) => s.wildMagic.armPhoenix('a', triggerTurn: 3));
    expectMutationVisible('Phoenix expiry (same player, later window)', (s) {
      s.wildMagic.armPhoenix('a', triggerTurn: 3);
      final before = s.toCanonicalBytes();
      s.wildMagic.armPhoenix('a', triggerTurn: 9);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible(
        'Statuesque', (s) => s.wildMagic.armStatuesque('a', triggerTurn: 3));
    expectMutationVisible('Statuesque expiry (same player, later window)', (s) {
      s.wildMagic.armStatuesque('a', triggerTurn: 3);
      final before = s.toCanonicalBytes();
      s.wildMagic.armStatuesque('a', triggerTurn: 9);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible(
        'Rippling Reflections', (s) => s.wildMagic.armRippling(triggerTurn: 3));
    expectMutationVisible('Rippling drift', (s) {
      s.wildMagic.armRippling(triggerTurn: 3);
      final before = s.toCanonicalBytes();
      s.wildMagic.driftRippling(4, 10);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible('Rippling window (same pct, later window)', (s) {
      s.wildMagic.armRippling(triggerTurn: 3);
      final before = s.toCanonicalBytes();
      s.wildMagic.armRippling(triggerTurn: 9);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible('Scattered Gusts',
        (s) => s.wildMagic.armScatteredGusts('a', triggerTurn: 3));
    expectMutationVisible('Scattered Gusts armed-from turn', (s) {
      s.wildMagic.armScatteredGusts('a', triggerTurn: 9);
      final before = s.toCanonicalBytes();
      s.wildMagic.armScatteredGusts('a', triggerTurn: 3);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible('Scattered Gusts for a second player', (s) {
      s.wildMagic.armScatteredGusts('a', triggerTurn: 3);
      final before = s.toCanonicalBytes();
      s.wildMagic.armScatteredGusts('b', triggerTurn: 3);
      expect(s.toCanonicalBytes(), isNot(before));
    });
    expectMutationVisible('an expiring tile', (s) {
      s.tileEffects[const HexCoord(1, 1)] = const IceTile();
      s.expiringTiles[const HexCoord(1, 1)] = 5;
    });

    test('a fizzle percentage of 0 is distinguishable from inactive', () {
      final a = fresh()
        ..wildMagic.armRippling(triggerTurn: 3)
        ..wildMagic.ripplingFizzlePct = 0;
      final b = fresh();
      expect(a.toCanonicalBytes(), isNot(b.toCanonicalBytes()));
    });

    test('map INSERTION ORDER does not change the bytes', () {
      final a = fresh();
      a.wildMagic.armPhoenix('a', triggerTurn: 3);
      a.wildMagic.armPhoenix('b', triggerTurn: 3);
      a.wildMagic.armStatuesque('b', triggerTurn: 3);
      a.wildMagic.armStatuesque('a', triggerTurn: 3);
      a.wildMagic.armScatteredGusts('b', triggerTurn: 3);
      a.wildMagic.armScatteredGusts('a', triggerTurn: 3);

      final b = fresh();
      b.wildMagic.armPhoenix('b', triggerTurn: 3);
      b.wildMagic.armPhoenix('a', triggerTurn: 3);
      b.wildMagic.armStatuesque('a', triggerTurn: 3);
      b.wildMagic.armStatuesque('b', triggerTurn: 3);
      b.wildMagic.armScatteredGusts('a', triggerTurn: 3);
      b.wildMagic.armScatteredGusts('b', triggerTurn: 3);

      expect(a.toCanonicalBytes(), b.toCanonicalBytes());
    });

    test('IceTile and ChasmTile get distinct tags, and 0–3 are unchanged', () {
      Uint8List withTile(TileEffect e) {
        final s = fresh();
        s.tileEffects[const HexCoord(1, 1)] = e;
        return s.toCanonicalBytes();
      }

      final encodings = [
        withTile(const FloorIsLava()),
        withTile(const ImpassableTile()),
        withTile(const SlowTile()),
        withTile(const ConveyorTile(direction: HexCoord(1, 0))),
        withTile(const IceTile()),
        withTile(const ChasmTile()),
      ].map(String.fromCharCodes).toSet();
      expect(encodings.length, 6);
    });
  });
}

/// Local copy of the six neighbour offsets, so this test doesn't depend on
/// which module happens to export them.
List<HexCoord> hexNeighborsOf(HexCoord c) => [
      HexCoord(c.q + 1, c.r),
      HexCoord(c.q + 1, c.r - 1),
      HexCoord(c.q, c.r - 1),
      HexCoord(c.q - 1, c.r),
      HexCoord(c.q - 1, c.r + 1),
      HexCoord(c.q, c.r + 1),
    ];
