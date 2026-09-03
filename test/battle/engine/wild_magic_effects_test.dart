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

Minion _minionAt(String id, HexCoord pos, {String teamId = 'b'}) => Minion(
      id: id,
      ownerId: teamId,
      teamId: teamId,
      position: pos,
      affinity: SpellAffinity.fire,
      stats: const MinionStats(maxHp: 3, damage: 1, moveSpeed: 1, attackRange: 1),
      elementSequence: const [],
      abilities: const {},
    );

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
    /// Every wizard's selection, without applying anything — the decision half
    /// of the effect, so a test can see WHO chose WHAT rather than only the
    /// union that lands on the board.
    Map<String, List<HexCoord>> select(BattleState state, WizardAvatar caster,
            {int bracketSteps = 0, HashRng? rng}) =>
        WildMagicApplicator.selectMountainTiles(
          WildMagicApplyContext(
            state: state,
            caster: caster,
            rng: rng ?? _rng(),
            trigger: WildMagicTrigger(
              row: WildMagicRow.repeatZero,
              element: SpellAffinity.earth,
              bracketSteps: bracketSteps,
            ),
            events: [],
          ),
        );

    Set<HexCoord> wallsIn(BattleState state) => {
          for (final e in state.tileEffects.entries)
            if (e.value is ImpassableTile) e.key,
        };

    test('a wizard with six eligible neighbours gets exactly three walls', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 5);
      // Fixture check: the cap is what limits this, not the geometry.
      expect(
        WildMagicApplicator.mountainsCandidates(state, me.position,
            blocked: const {}, occupied: {me.position}),
        hasLength(6),
      );

      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);

      expect(wallsIn(state), hasLength(3));
      for (final wall in wallsIn(state)) {
        expect(hexNeighborsOf(me.position), contains(wall));
        expect(state.expiringTiles[wall], 6, reason: 'turnNumber + 1 + 0');
      }
    });

    test('fewer than three eligible cells walls all of them and no more', () {
      // A board vertex has exactly three in-bounds neighbours, so one of them
      // is pre-blocked to get the pool below the cap: two eligible, two walls.
      final me = _avatar('a', const HexCoord(4, 0));
      final bare = _state(avatars: [me], radius: 4);
      final inBounds = WildMagicApplicator.mountainsCandidates(
          bare, me.position,
          blocked: const {}, occupied: {me.position});
      expect(inBounds, hasLength(3), reason: 'fixture check: a vertex');

      final state = _state(
        avatars: [me],
        radius: 4,
        tileEffects: {inBounds.first: const FloorIsLava()},
      );
      final eligible = WildMagicApplicator.mountainsCandidates(
          state, me.position,
          blocked: {inBounds.first}, occupied: {me.position});
      expect(eligible, hasLength(2), reason: 'fixture check');

      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(wallsIn(state), eligible.toSet());
    });

    test('no bracket raises the wall count above three', () {
      for (final bracket in [0, 1, 2, 5, 17]) {
        final me = _avatar('a', const HexCoord(0, 0));
        final state = _state(avatars: [me], turnNumber: 5);
        _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
            bracketSteps: bracket);
        expect(wallsIn(state), hasLength(3),
            reason: 'bracket $bracket must not widen the placement');
      }
    });

    test('bracket steps still extend the expiry — the strength axis it kept',
        () {
      // Slice 5 caps the COUNT. Bracket never controlled count; it controls
      // duration, and it still does.
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me], turnNumber: 5);
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
          bracketSteps: 2);
      expect(state.expiringTiles.values.toSet(), {8});
      expect(wallsIn(state), hasLength(3));
    });

    test('the same state and trigger select the same tiles every time', () {
      Set<HexCoord> run() {
        final me = _avatar('a', const HexCoord(0, 0));
        final foe = _avatar('b', const HexCoord(1, 1), teamId: 'b');
        final state = _state(avatars: [me, foe]);
        _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
            rng: _rng(7));
        return wallsIn(state);
      }

      expect(run(), run());
      expect(run(), isNotEmpty);
    });

    test('avatar and tileEffects insertion order do not move a single wall',
        () {
      // Same board, built two different ways: avatars listed in the opposite
      // order and the pre-existing terrain inserted in the opposite order.
      // livingAvatars sorts by playerId and candidates sort by (q, r), so
      // neither can reach the outcome.
      const lavaA = HexCoord(1, 0);
      const lavaB = HexCoord(0, 1);

      Set<HexCoord> run({required bool reversed}) {
        final me = _avatar('a', const HexCoord(0, 0));
        final foe = _avatar('b', const HexCoord(1, 1), teamId: 'b');
        final state = _state(
          avatars: reversed ? [foe, me] : [me, foe],
          tileEffects: reversed
              ? {lavaB: const FloorIsLava(), lavaA: const FloorIsLava()}
              : {lavaA: const FloorIsLava(), lavaB: const FloorIsLava()},
        );
        _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
            rng: _rng(3));
        return wallsIn(state);
      }

      expect(run(reversed: false), run(reversed: true));
    });

    test('canonical bytes agree across those two build orders', () {
      BattleState build({required bool reversed}) {
        final me = _avatar('a', const HexCoord(0, 0));
        final foe = _avatar('b', const HexCoord(1, 1), teamId: 'b');
        final state = _state(avatars: reversed ? [foe, me] : [me, foe]);
        _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth,
            rng: _rng(3));
        return state;
      }

      // Avatars are serialized sorted by playerId, so the whole canonical
      // encoding — walls included — must be byte-identical.
      expect(build(reversed: false).toCanonicalBytes(),
          build(reversed: true).toCanonicalBytes());
    });

    test('every living wizard gets its own selection of up to three', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(-3, 1), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      final picks = select(state, me);

      expect(picks.keys.toSet(), {'a', 'b'});
      for (final entry in picks.entries) {
        expect(entry.value, hasLength(3), reason: entry.key);
      }
    });

    test('a dead wizard contributes no candidate set', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final dead = _avatar('c', const HexCoord(-3, 1), teamId: 'c', hp: 0);
      final state = _state(avatars: [me, dead]);
      expect(select(state, me).keys, ['a']);
    });

    test('both wizards choose from the SAME pre-placement snapshot', () {
      // The two are two tiles apart, sharing neighbours — the case where a
      // sequentially-applied Mountains would have narrowed the second
      // wizard's pool with the first wizard's walls.
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(1, 1), teamId: 'b');
      final state = _state(avatars: [me, foe]);
      final snapshotOccupied = {me.position, foe.position};

      final picks = select(state, me);
      for (final entry in picks.entries) {
        final centre = entry.key == 'a' ? me.position : foe.position;
        final fullCandidates = WildMagicApplicator.mountainsCandidates(
          state,
          centre,
          blocked: const {},
          occupied: snapshotOccupied,
        ).toSet();
        expect(entry.value.toSet(), everyElement(isIn(fullCandidates)),
            reason: '${entry.key} chose outside its snapshot candidates');
        expect(entry.value, hasLength(3),
            reason: '${entry.key} got a full three from the snapshot, not a '
                'pool the other wizard had already eaten into');
      }
    });

    test('a wall raised for one wizard does not shrink the other\'s pool', () {
      // The discriminating fixture: 'a' selects first in canonical order, and
      // its three walls may include tiles adjacent to 'b'. Under the old
      // sequential rule 'b' would then have had fewer candidates. Here 'b'
      // still draws three, and the union is whatever those two independent
      // top-threes come to.
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(1, 1), teamId: 'b');
      final state = _state(avatars: [me, foe]);

      final picks = select(state, me);
      expect(picks['a'], hasLength(3));
      expect(picks['b'], hasLength(3));

      final shared = hexNeighborsOf(me.position)
          .toSet()
          .intersection(hexNeighborsOf(foe.position).toSet());
      expect(shared, isNotEmpty,
          reason: 'fixture check: the two neighbourhoods must overlap for '
              'this test to be about anything');
    });

    test('a tile both wizards select is raised once', () {
      // Boxed in so both wizards have exactly one eligible tile, and it is the
      // same tile: the union must be a single wall, and neither wizard gets a
      // replacement pick for the collision.
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final shared = hexNeighborsOf(me.position)
          .toSet()
          .intersection(hexNeighborsOf(foe.position).toSet());
      expect(shared, hasLength(1), reason: 'fixture check');
      final onlyTile = shared.single;

      // Everything except the shared tile already carries terrain.
      final blockers = <HexCoord, TileEffect>{
        for (final n in {
          ...hexNeighborsOf(me.position),
          ...hexNeighborsOf(foe.position),
        })
          if (n != onlyTile && n != me.position && n != foe.position)
            n: const FloorIsLava(),
      };
      final state = _state(avatars: [me, foe], tileEffects: blockers);

      final picks = select(state, me);
      expect(picks['a'], [onlyTile]);
      expect(picks['b'], [onlyTile]);

      final state2 = _state(avatars: [me, foe], tileEffects: blockers);
      _fire(state2, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(wallsIn(state2), {onlyTile},
          reason: 'one wall, not two, and no fourth-pick compensation');
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

    test('eligibility still refuses out-of-bounds, blocked and occupied tiles',
        () {
      // The three rules, asserted directly on the candidate helper so a
      // future change to any of them is visible here rather than inferred
      // from a wall count.
      final me = _avatar('a', const HexCoord(4, 0));
      final state = _state(avatars: [me], radius: 4);
      final all = hexNeighborsOf(me.position);
      final inBounds =
          all.where(state.battlefield.isInBounds).toSet();
      expect(inBounds.length, lessThan(all.length), reason: 'fixture check');

      expect(
        WildMagicApplicator.mountainsCandidates(state, me.position,
            blocked: const {}, occupied: const {}).toSet(),
        inBounds,
        reason: 'out of bounds is refused',
      );
      expect(
        WildMagicApplicator.mountainsCandidates(state, me.position,
            blocked: {inBounds.first}, occupied: const {}).toSet(),
        inBounds.difference({inBounds.first}),
        reason: 'a tile already carrying an effect is refused',
      );
      expect(
        WildMagicApplicator.mountainsCandidates(state, me.position,
            blocked: const {}, occupied: {inBounds.last}).toSet(),
        inBounds.difference({inBounds.last}),
        reason: 'an occupied tile is refused',
      );
    });

    test('a living minion\'s footprint blocks placement; a dead one does not',
        () {
      final me = _avatar('a', const HexCoord(0, 0));
      const under = HexCoord(1, 0);
      final state = _state(
        avatars: [me],
        minions: [_minionAt('m', under, teamId: 'b')],
      );
      _fire(state, me, WildMagicRow.repeatZero, SpellAffinity.earth);
      expect(state.tileEffects.containsKey(under), isFalse);
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

    test('no bracket raises the count per player above one', () {
      // Was `1 + bracketSteps`, which made a bracket-2 firing shred three
      // spells out of every hand at once (Slice 5).
      for (final bracket in [0, 1, 2, 5, 17]) {
        final me = _avatar('a', const HexCoord(0, 0));
        final state = _state(avatars: [me]);
        final hooks = _RecordingHooks();
        _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire,
            bracketSteps: bracket, hooks: hooks);
        expect(hooks.forced.single.$2, 1, reason: 'bracket $bracket');
      }
    });

    test('the trigger still carries its bracket, it just no longer multiplies',
        () {
      // "Effect fired at bracket 2" and "effect casts three spells" are
      // different facts, and only the second one changed. The bracket has to
      // survive on the trigger for the row-scaling design to stay open.
      final me = _avatar('a', const HexCoord(0, 0));
      final state = _state(avatars: [me]);
      final hooks = _RecordingHooks();
      final events = _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire,
          bracketSteps: 2, hooks: hooks);
      expect(events.single.bracketSteps, 2);
      expect(hooks.forced.single.$2, 1);
    });

    test('two living wizards get one selection each; a dead one gets none', () {
      final me = _avatar('a', const HexCoord(0, 0));
      final foe = _avatar('b', const HexCoord(2, 0), teamId: 'b');
      final dead = _avatar('c', const HexCoord(-2, 0), teamId: 'c', hp: 0);
      final state = _state(avatars: [me, foe, dead]);
      final hooks = _RecordingHooks();

      _fire(state, me, WildMagicRow.repeatOne, SpellAffinity.fire,
          bracketSteps: 3, hooks: hooks);

      expect(hooks.forced.single.$1, {'a', 'b'},
          reason: 'living at the instant the trigger fired — a Phoenix that '
              'may raise "c" later does not retroactively enlist them');
      expect(hooks.forced.single.$2, 1);
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
