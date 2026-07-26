// SPDX-License-Identifier: GPL-3.0-or-later
//
// rod_of_spreading_test.dart — the Air-typed Rod of Spreading artifact
// (design v3.0 §Artifacts). A one-shot consumable that adds +1 effective
// radius to a spell's spatial effects and one size rung to a summoned minion.
//
// Covers:
//   - the minion size ladder [1 → 3 → 7] (footprintFor, pure);
//   - EffectApplicator footprint expansion: single-target damage becomes an
//     AoE, splash/cloud radii grow, Earth walls block the spread, and meta
//     effects are NOT multiplied;
//   - a multi-tile (rod-enlarged) minion is immovable by knockback;
//   - Minion.sizeBonus is reflected in BattleState.toCanonicalBytes();
//   - end-to-end via SoloBattleSession: a summon cast with the rod enlarges the
//     creature and consumes exactly one rod, and requesting a rod without owning
//     one grants nothing (the peer trust boundary).

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
  group('Rod of Spreading enlarges spatial effects', () {
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

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: const HexCoord(2, 0),
        effect: const ArtifactsInteractionEffect(
            affinity: SpellAffinity.water, count: 2), // summon 2 mana gems
        effectiveRadiusBonus: 1,
        affinity: SpellAffinity.water,
      ));

      expect(caster.manaGemsEquipped, before + 2,
          reason: 'summon count is not multiplied across the disc');
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
        {List<Accoutrement> accoutrements = const []}) {
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
      );
      return (state: state, loop: loop, local: local);
    }

    test('with a rod owned: creature enlarged one rung, rod consumed', () async {
      final ctx = setup(accoutrements: [
        const Accoutrement(id: 'rod', kind: AccoutrementKind.rodOfSpreading),
      ]);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: ctx.local.position,
          isRodOfSpreading: true,
        ),
      ));

      expect(ctx.state.minions, hasLength(1));
      // Non-Big creature (no EEEE) enlarged one rung → 3-tile triangle.
      expect(ctx.state.minions.single.sizeBonus, 1);
      expect(ctx.state.minions.single.occupiedTiles, hasLength(3));
      expect(ctx.local.rodOfSpreadingCount, 0, reason: 'rod consumed');
    });

    test('requesting a rod without owning one grants nothing', () async {
      final ctx = setup(); // no accoutrements
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: summonSpell(),
          targetHex: ctx.local.position,
          isRodOfSpreading: true,
        ),
      ));

      expect(ctx.state.minions, hasLength(1));
      expect(ctx.state.minions.single.sizeBonus, 0);
      expect(ctx.state.minions.single.occupiedTiles, hasLength(1));
      expect(ctx.local.rodOfSpreadingCount, 0);
    });
  });
}
