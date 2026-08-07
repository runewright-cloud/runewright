// SPDX-License-Identifier: GPL-3.0-or-later
//
// rod_of_wind_test.dart — the Air-typed Rod of Wind artifact
// (design v3.0 §Artifacts). Renamed from "Rod of Spreading" 2026-07-31; the
// `AccoutrementKind.rodOfSpreading` / `ArtifactKind.rodOfSpreading` Dart
// identifiers are left as-is (out of scope for a terminology pass — the
// sibling `ArtifactKind` in accoutrement_loadout.dart/chapter_asset.dart is
// persisted to on-device storage BY NAME, so renaming it needs its own
// migration decision, not a drive-by rename). A one-shot consumable that adds
// +1 effective radius to a spell's spatial effects and one size rung to a
// summoned minion.
//
// Covers:
//   - the minion size ladder [1 → 3 → 7] (footprintFor, pure);
//   - EffectApplicator footprint expansion: single-target damage becomes an
//     AoE, splash/cloud radii grow, Earth walls block the spread, and meta
//     effects are NOT multiplied;
//   - spread-by-default (2026-08-07): non-damage effects — debuffs, barriers —
//     now resolve independently in every cell of the disc, paired with a
//     negative vector for each of the three named exceptions (traversal
//     damage, the terrain-copy illusion, the Watery chain steal);
//   - the chain steal's "strongest chain in the disc wins" rule, its playerId
//     tie-break, and its unchained-victim fallback;
//   - a multi-tile (rod-enlarged) minion is immovable by knockback;
//   - Minion.sizeBonus is reflected in BattleState.toCanonicalBytes();
//   - end-to-end via SoloBattleSession, BOTH cast modes: a summon cast enlarges
//     the creature and an incantation cast widens its effects, each consuming
//     exactly one rod; requesting a rod without owning one grants nothing (the
//     peer trust boundary).
//
// The exception tests are real negative vectors, not documentation: each was
// verified to FAIL when its entry is removed from _isSpreadableAtTiles (and
// the three chain-steal rules likewise, against _strongestChainTarget). Keep
// that property — a "constraint" whose test passes without it is not a
// constraint. Two drafts of the chain tests passed under mutation before the
// victims were renamed so that strength order and playerId order disagree.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind, SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(String id, HexCoord pos, {String teamId = 'a'}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 3,
    );

BattleState _state({
  required List<WizardAvatar> avatars,
  Map<HexCoord, TileEffect> tileEffects = const {},
  List<Minion> minions = const [],
  int radius = 6,
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
  );
}

ApplyContext _ctx({
  required BattleState state,
  required WizardAvatar caster,
  required SpellEffect effect,
  required HexCoord targetTile,
  int effectiveRadiusBonus = 0,
  SpellAffinity affinity = SpellAffinity.fire,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: affinity,
        effectKind: EffectKind.damage,
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: Random(1),
      effectiveRadiusBonus: effectiveRadiusBonus,
    );

void main() {
  // ── Minion size ladder (pure) ───────────────────────────────────────────────
  group('footprintFor size ladder [1 → 3 → 7]', () {
    const center = HexCoord(0, 0);

    test('normal creature, no bonus → single tile', () {
      expect(footprintFor(center, const {}), hasLength(1));
    });

    test('normal creature + rod → 3-tile triangle', () {
      final f = footprintFor(center, const {}, 1);
      expect(f, hasLength(3));
      expect(f, contains(center));
    });

    test('Big creature, no bonus → 3-tile triangle', () {
      expect(footprintFor(center, {SummonAbility.big}), hasLength(3));
    });

    test('Big creature + rod → full 7-tile hex', () {
      final f = footprintFor(center, {SummonAbility.big}, 1);
      expect(f, hasLength(7));
      expect(f, contains(center));
    });

    test('the ladder caps at 7 tiles (no radius-2)', () {
      expect(footprintFor(center, {SummonAbility.big}, 2), hasLength(7));
      expect(footprintFor(center, const {}, 5), hasLength(7));
    });
  });

  // ── EffectApplicator footprint expansion ────────────────────────────────────
  group('Rod of Wind enlarges spatial effects', () {
    test('single-target direct damage becomes an AoE over the disc', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final onTarget = _avatar('t', const HexCoord(2, 0), teamId: 'foe');
      // (3,0) is a neighbor of the target tile (2,0).
      final onRing = _avatar('r', const HexCoord(3, 0), teamId: 'foe');
      final state = _state(avatars: [caster, onTarget, onRing]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 5, kind: DamageKind.direct),
        effectiveRadiusBonus: 1,
      ));

      expect(onTarget.hp, lessThan(24), reason: 'center tile hit');
      expect(onRing.hp, lessThan(24), reason: 'ring tile hit by the +1 spread');
    });

    test('without a rod, direct damage stays single-target', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final onTarget = _avatar('t', const HexCoord(2, 0), teamId: 'foe');
      final onRing = _avatar('r', const HexCoord(3, 0), teamId: 'foe');
      final state = _state(avatars: [caster, onTarget, onRing]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 5, kind: DamageKind.direct),
      ));

      expect(onTarget.hp, lessThan(24));
      expect(onRing.hp, 24, reason: 'no spread without a rod');
    });

    test('splash damage grows its own radius by the bonus', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      // 2 tiles from the target center — outside a radius-1 splash, inside a 2.
      final far = _avatar('f', const HexCoord(4, 0), teamId: 'foe');
      final state = _state(avatars: [caster, far]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(
            amount: 5, kind: DamageKind.splash, splashRadius: 1),
        effectiveRadiusBonus: 1, // splashRadius 1 → 2, now reaches (4,0)
        affinity: SpellAffinity.water,
      ));

      expect(far.hp, lessThan(24));
    });

    test('a cloud is placed one ring larger', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state(avatars: [caster]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const CloudEffect(
            affinity: SpellAffinity.fire, kind: ToxicCloud(), radius: 1),
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.water,
      ));

      expect(state.clouds, hasLength(1));
      expect(state.clouds.single.radius, 2);
    });

    test('an Earth wall blocks the spread from reaching the tile behind it', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      // Wall at (3,0) is the ONLY 2-step path from center (2,0) to (4,0).
      final shielded = _avatar('s', const HexCoord(4, 0), teamId: 'foe');
      final state = _state(
        avatars: [caster, shielded],
        tileEffects: {const HexCoord(3, 0): const ImpassableTile()},
      );

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 5, kind: DamageKind.direct),
        effectiveRadiusBonus: 2,
      ));

      expect(shielded.hp, 24, reason: 'wall shadows the tile behind it');
    });

    test('same layout WITHOUT the wall does reach the far tile', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final reachable = _avatar('s', const HexCoord(4, 0), teamId: 'foe');
      final state = _state(avatars: [caster, reachable]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 5, kind: DamageKind.direct),
        effectiveRadiusBonus: 2,
      ));

      expect(reachable.hp, lessThan(24));
    });

    test('a meta effect is applied once, never multiplied by the bonus', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state(avatars: [caster]);
      final before = caster.manaGemsEquipped;

      // Self-targeted: ArtifactsInteraction's summon flavors land on
      // whoever occupies the target tile (2026-07-27), not automatically
      // the caster.
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: caster.position,
        effect: const ArtifactsInteractionEffect(
            affinity: SpellAffinity.water, count: 2), // summon 2 mana gems
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.water,
      ));

      expect(caster.manaGemsEquipped, before + 2,
          reason: 'summon count is not multiplied across the disc');
    });
  });

  // ── Spread-by-default (2026-08-07) ──────────────────────────────────────────
  //
  // The case-2 set was a four-entry allowlist until 2026-08-07, justified by a
  // "self-buffs would multiply if looped" claim the 2026-07-27 tile-targeting
  // sweep had already made false. Spreading is now the default and
  // _isSpreadableAtTiles names only the exceptions. These are the positive
  // vectors for the flip and the negative vectors for each exception — the
  // §10/§11 pairing: every one of the three "stays single-target" tests below
  // FAILS if its exception is dropped from that switch.
  group('rod spreads non-damage effects across the disc', () {
    test('a speed debuff lands on every wizard in the disc', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final onTarget = _avatar('t', const HexCoord(2, 0), teamId: 'foe');
      final onRing = _avatar('r', const HexCoord(3, 0), teamId: 'foe');
      final state = _state(avatars: [caster, onTarget, onRing]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const SpeedManipulationEffect(
            affinity: SpellAffinity.earth, speedDelta: -1, durationTurns: 2),
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.earth,
      ));

      for (final av in [onTarget, onRing]) {
        expect(
          av.activeStatusEffects.where((fx) => fx.effectTypeId == StatusEffectId.speedDown),
          hasLength(1),
          reason: '${av.playerId} slowed exactly once (statuses replace, never stack)',
        );
      }
    });

    test('without a rod the same debuff stays on the target tile', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final onTarget = _avatar('t', const HexCoord(2, 0), teamId: 'foe');
      final onRing = _avatar('r', const HexCoord(3, 0), teamId: 'foe');
      final state = _state(avatars: [caster, onTarget, onRing]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const SpeedManipulationEffect(
            affinity: SpellAffinity.earth, speedDelta: -1, durationTurns: 2),
        affinity: SpellAffinity.earth,
      ));

      expect(onTarget.activeStatusEffects, isNotEmpty);
      expect(onRing.activeStatusEffects, isEmpty, reason: 'no spread without a rod');
    });

    test('a barrier is granted to every wizard in the disc', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final ally = _avatar('a', const HexCoord(2, 0));
      final ally2 = _avatar('a2', const HexCoord(3, 0));
      final state = _state(avatars: [caster, ally, ally2]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const BarrierEffect(hp: 4, durationTurns: 3),
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.earth,
      ));

      expect(ally.barriers[SpellAffinity.earth], isNotNull);
      expect(ally2.barriers[SpellAffinity.earth], isNotNull,
          reason: 'the ring ally is armored too');
    });

    // ── Exception 1: traversal damage ────────────────────────────────────────
    test('traversal damage does NOT spread — it is a flight line, not a disc',
        () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final onTarget = _avatar('t', const HexCoord(2, 0), teamId: 'foe');
      final onRing = _avatar('r', const HexCoord(3, 0), teamId: 'foe');
      final state = _state(avatars: [caster, onTarget, onRing]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 5, kind: DamageKind.traversal),
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.earth,
      ));

      expect(onRing.hp, 24,
          reason: 'en-route damage is applied once per cast by TurnLoop, '
              'not once per tile of the disc');
    });

    // ── Exception 2: Earth illusions (terrain copy) ──────────────────────────
    test('the terrain-copy illusion does NOT spread — it already fans out', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state(
        avatars: [caster],
        tileEffects: {const HexCoord(2, 0): const SlowTile()},
      );

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const IllusionEffect(
            affinity: SpellAffinity.earth, copyTerrainExpand: true),
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.earth,
      ));

      // One fan-out onto the source tile's own free neighbours (≤6), never a
      // fan-out per tile of the disc (which would approach ~24).
      expect(state.illusionTerrainTiles.length, lessThanOrEqualTo(6),
          reason: 'the disc must not compound with the effect\'s own fan-out');
    });

    // ── Exception 3: the Watery chain steal ──────────────────────────────────
    // The Watery chain steal writes to the CASTER, so it stays out of the
    // per-tile loop — but the rod still widens it, inside
    // _strongestChainTarget. Ruled 2026-08-07: the strongest chain in the disc
    // takes precedence.
    group('the chain steal robs the strongest chain in the disc', () {
      ({BattleState state, WizardAvatar caster}) crowd() {
        final caster = _avatar('caster', const HexCoord(0, 0));
        // Aimed-at tile holds a weak chain; a bystander one ring out holds a
        // much stronger one. Both fall inside a radius-1 disc on (2,0).
        //
        // Names chosen so playerId order and strength order DISAGREE: the weak
        // one sorts first alphabetically. Without that the playerId tie-break
        // alone would satisfy this test and the strength sort could be deleted
        // unnoticed (it was, on the first draft).
        final weak = _avatar('a_weak', const HexCoord(2, 0), teamId: 'foe')
          ..activeChainElement = SpellAffinity.fire
          ..chainLengths[SpellAffinity.fire] = 2;
        final strong = _avatar('z_strong', const HexCoord(2, 1), teamId: 'foe')
          ..activeChainElement = SpellAffinity.earth
          ..chainLengths[SpellAffinity.earth] = 10;
        return (state: _state(avatars: [caster, weak, strong]), caster: caster);
      }

      void steal(BattleState state, WizardAvatar caster, int bonus) =>
          EffectApplicator.apply(_ctx(
            state: state,
            caster: caster,
            targetTile: const HexCoord(2, 0),
            effect: const ChainInteractionEffect(
              affinity: SpellAffinity.water,
              transferChainFromTarget: true,
              chainTransferBonus: 1,
            ),
            effectiveRadiusBonus: bonus,
            affinity: SpellAffinity.water,
          ));

      test('with a rod: the bystander\'s stronger chain is taken', () {
        final c = crowd();
        steal(c.state, c.caster, 1);

        // 10 half-credits stolen + one bonus cast (2 half-credits) = 12.
        expect(c.caster.activeChainElement, SpellAffinity.earth,
            reason: 'the strongest chain in the disc wins, not the aimed tile');
        expect(c.caster.chainLengths[SpellAffinity.earth], 12);
        expect(c.caster.chainLengths[SpellAffinity.fire], isNull,
            reason: 'the caster ends with exactly one victim\'s chain');
      });

      test('without a rod: only the aimed tile is a candidate', () {
        final c = crowd();
        steal(c.state, c.caster, 0);

        expect(c.caster.activeChainElement, SpellAffinity.fire);
        expect(c.caster.chainLengths[SpellAffinity.fire], 4,
            reason: 'no rod, no disc — the stronger bystander is out of reach');
      });

      test('equal chains break the tie on playerId, not iteration order', () {
        final caster = _avatar('caster', const HexCoord(0, 0));
        // Same strength, different elements. 'aaa' sorts before 'zzz'; 'zzz'
        // sits on the aimed tile, so a playerId tie-break and a first-found
        // tie-break give visibly different answers.
        final onAimed = _avatar('zzz', const HexCoord(2, 0), teamId: 'foe')
          ..activeChainElement = SpellAffinity.fire
          ..chainLengths[SpellAffinity.fire] = 6;
        final onRing = _avatar('aaa', const HexCoord(2, 1), teamId: 'foe')
          ..activeChainElement = SpellAffinity.water
          ..chainLengths[SpellAffinity.water] = 6;
        final state = _state(avatars: [caster, onAimed, onRing]);

        steal(state, caster, 1);

        expect(caster.activeChainElement, SpellAffinity.water,
            reason: 'lowest playerId wins the tie — both devices must agree');
      });

      test('a disc of unchained wizards still wipes the caster\'s own chain',
          () {
        final caster = _avatar('caster', const HexCoord(0, 0))
          ..activeChainElement = SpellAffinity.air
          ..chainLengths[SpellAffinity.air] = 8;
        final empty = _avatar('empty', const HexCoord(2, 0), teamId: 'foe');
        final state = _state(avatars: [caster, empty]);

        steal(state, caster, 1);

        expect(caster.activeChainElement, isNull);
        expect(caster.chainLengths, isEmpty,
            reason: 'strength 0 is still a valid victim when nobody has a '
                'chain — the pre-rod behaviour is preserved');
      });
    });
  });

  // ── Immovability by tile count ──────────────────────────────────────────────
  group('a multi-tile creature is immovable by knockback', () {
    Minion mkMinion(HexCoord pos, {int sizeBonus = 0}) => Minion(
          id: 'm',
          ownerId: 'foe',
          teamId: 'foe',
          position: pos,
          affinity: SpellAffinity.earth,
          stats: const MinionStats(maxHp: 10, damage: 1, moveSpeed: 1, attackRange: 1),
          elementSequence: const [],
          sizeBonus: sizeBonus,
        );

    test('a single-tile creature is pushed', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final m = mkMinion(const HexCoord(2, 0));
      final state = _state(avatars: [caster], minions: [m]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 1, kind: DamageKind.knockback, knockback: 1),
        affinity: SpellAffinity.air,
      ));

      expect(m.position, isNot(const HexCoord(2, 0)));
    });

    test('a rod-enlarged creature holds its ground', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final m = mkMinion(const HexCoord(2, 0), sizeBonus: 1);
      final state = _state(avatars: [caster], minions: [m]);
      expect(m.occupiedTiles.length, greaterThan(1));

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const DamageEffect(amount: 1, kind: DamageKind.knockback, knockback: 1),
        affinity: SpellAffinity.air,
      ));

      expect(m.position, const HexCoord(2, 0));
    });
  });

  // ── Determinism ─────────────────────────────────────────────────────────────
  group('sizeBonus is part of the canonical state', () {
    Minion mk(int sizeBonus) => Minion(
          id: 'm',
          ownerId: 'p',
          teamId: 'p',
          position: const HexCoord(1, 0),
          affinity: SpellAffinity.earth,
          stats: const MinionStats(maxHp: 5, damage: 0, moveSpeed: 0, attackRange: 1),
          elementSequence: const [],
          sizeBonus: sizeBonus,
        );

    test('two identical rod-enlarged states hash the same', () {
      final a = _state(avatars: [_avatar('p', const HexCoord(0, 0))], minions: [mk(1)]);
      final b = _state(avatars: [_avatar('p', const HexCoord(0, 0))], minions: [mk(1)]);
      expect(a.toCanonicalBytes(), b.toCanonicalBytes());
    });

    test('different sizeBonus changes the hash', () {
      final a = _state(avatars: [_avatar('p', const HexCoord(0, 0))], minions: [mk(0)]);
      final b = _state(avatars: [_avatar('p', const HexCoord(0, 0))], minions: [mk(1)]);
      expect(a.toCanonicalBytes(), isNot(b.toCanonicalBytes()));
    });
  });

  // ── End-to-end through the real cast pipeline ───────────────────────────────
  group('summon cast consumes the rod and enlarges the creature', () {
    SpellAsset summonSpell() => SpellAsset(
          id: 'sm',
          createdAt: DateTime.utc(2026, 7, 24),
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
          formula: const ['fire', 'fire', 'earth', 'earth'],
          isSummon: true,
          summonPersonality: 'aggressive',
        );

    ({BattleState state, TurnLoop loop, WizardAvatar local}) setup(
        {List<Accoutrement> accoutrements = const [], bool declareRod = false}) {
      final bf = Battlefield(radius: 6);
      const id = 'local';
      final local = WizardAvatar(
        playerId: id,
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: const HexCoord(0, 3),
        teamId: 'solo',
        baseSpellRange: 3,
        accoutrements: List.of(accoutrements),
      );
      bf.occupancy[id] = local.position;
      final state = BattleState(
        config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 1),
        avatars: [local],
        teams: [Team(id: 'solo', playerIds: const [id])],
        battlefield: bf,
      );
      final loop = TurnLoop(
        state: state,
        session: SoloBattleSession(state: state),
        localPlayerId: id,
        // The rod is declared at Phase 0 now, not folded into the action
        // commit (ARTIFACT_SYSTEM_PLAN.md §3.1) — so a cast that wants the
        // bonus declares it through the picker before the turn opens.
        artifactActivationPicker: declareRod
            ? (_) async => AccoutrementKind.rodOfSpreading
            : (_) async => null,
      );
      return (state: state, loop: loop, local: local);
    }

    test('with a rod owned: creature enlarged one rung, rod consumed', () async {
      final ctx = setup(declareRod: true, accoutrements: [
        const Accoutrement(id: 'rod', kind: AccoutrementKind.rodOfSpreading),
      ]);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.state.minions, hasLength(1));
      // Non-Big creature (no EEEE) enlarged one rung → 3-tile triangle.
      expect(ctx.state.minions.single.sizeBonus, 1);
      expect(ctx.state.minions.single.occupiedTiles, hasLength(3));
      expect(ctx.local.rodOfSpreadingCount, 0, reason: 'rod consumed');
    });

    test('declaring a rod without owning one grants nothing (summon)', () async {
      // Two layers refuse this now: the Phase-0 picker is never even offered
      // (nothing activatable is held), and _validateActivation would discard
      // the declaration if a modified client sent one anyway — see
      // artifact_activation_test.dart for that half.
      final ctx = setup(declareRod: true); // no accoutrements
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.state.minions, hasLength(1));
      expect(ctx.state.minions.single.sizeBonus, 0);
      expect(ctx.state.minions.single.occupiedTiles, hasLength(1));
      expect(ctx.local.rodOfSpreadingCount, 0);
    });
  });

  // ── End-to-end: an INCANTATION cast, through the real turn pipeline ─────────
  //
  // The gap that let the rod reach a play-test feeling broken: the summon
  // branch had an end-to-end vector, the incantation branch did not. Everything
  // above this group tests EffectApplicator with effectiveRadiusBonus handed in
  // by hand, which cannot catch a break anywhere in
  //   Phase-0 declaration → declaredActivation → rodRequested → _applySpell
  //   → _consumeRodOfSpreading → ApplyContext.effectiveRadiusBonus.
  group('incantation cast consumes the rod and widens the effect', () {
    SpellAsset boltSpell() => SpellAsset(
          id: 'inc',
          createdAt: DateTime.utc(2026, 8, 7),
          tier: 12,
          t: 5,
          ownerPubkeyHex: '0x${'0' * 64}',
          manaCost: 1,
          segmentCount: 0,
          dotCount: 1,
          initialGrid: List<int>.filled(469, 0)..[234] = 1,
          proofBytes: Uint8List.fromList([1, 2, 3]),
          name: 'Test Bolt',
          commitmentHex: '0x${'a' * 64}',
          spellHashHex: '0x${'b' * 64}',
          // affinity fire + (fire, fire) → direct damage.
          formula: const ['fire', 'fire', 'fire'],
        );

    ({TurnLoop loop, WizardAvatar local, WizardAvatar onTarget, WizardAvatar onRing})
        setup({required bool declareRod}) {
      final bf = Battlefield(radius: 6);
      final local = WizardAvatar(
        playerId: 'local',
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: const HexCoord(0, 0),
        teamId: 'a',
        baseSpellRange: 3,
        accoutrements: [
          const Accoutrement(id: 'rod', kind: AccoutrementKind.rodOfSpreading),
        ],
      );
      final onTarget = _avatar('foe1', const HexCoord(2, 0), teamId: 'b');
      final onRing = _avatar('foe2', const HexCoord(3, 0), teamId: 'b');
      for (final a in [local, onTarget, onRing]) {
        bf.occupancy[a.playerId] = a.position;
      }
      final state = BattleState(
        config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 3),
        avatars: [local, onTarget, onRing],
        teams: [
          Team(id: 'a', playerIds: const ['local']),
          Team(id: 'b', playerIds: const ['foe1', 'foe2']),
        ],
        battlefield: bf,
      );
      return (
        loop: TurnLoop(
          state: state,
          session: SoloBattleSession(state: state),
          localPlayerId: 'local',
          artifactActivationPicker: declareRod
              ? (_) async => AccoutrementKind.rodOfSpreading
              : (_) async => null,
        ),
        local: local,
        onTarget: onTarget,
        onRing: onRing,
      );
    }

    Future<void> castAt(TurnLoop loop) => loop.runTurn(TurnInput(
          action: SpellCastAction(
            spell: boltSpell(),
            targetHex: const HexCoord(2, 0),
          ),
        ));

    test('rod declared at Phase 0: the ring neighbour is hit too', () async {
      final ctx = setup(declareRod: true);
      await castAt(ctx.loop);

      expect(ctx.onTarget.hp, lessThan(24), reason: 'the aimed tile is hit');
      expect(ctx.onRing.hp, lessThan(24),
          reason: 'the +1 disc reaches the neighbour — this is the assertion '
              'that fails if any link in the declaration→bonus chain breaks');
      expect(ctx.local.rodOfSpreadingCount, 0, reason: 'rod consumed');
    });

    test('nothing declared: the same cast stays single-target', () async {
      final ctx = setup(declareRod: false);
      await castAt(ctx.loop);

      expect(ctx.onTarget.hp, lessThan(24));
      expect(ctx.onRing.hp, 24, reason: 'no declaration, no spread');
      expect(ctx.local.rodOfSpreadingCount, 1, reason: 'rod NOT consumed');
    });
  });
}
