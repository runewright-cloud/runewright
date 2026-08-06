// SPDX-License-Identifier: GPL-3.0-or-later
//
// effect_resolver.dart — EffectResolver: formula → EffectDescriptor.
//
// Maps a parsed formula triplet (affinity + two effect-type border zones) to
// an EffectDescriptor containing the affinity, EffectKind, and a fully-
// constructed SpellEffect with potency already folded in (bracketed values
// pre-selected when enhancements.isPotent is true).
//
// Covers all 64 entries (4 affinities × 16 effect kinds). See the effect table
// in docs/runewright_design_v3_0.md §Effect Table for source values.
//
// Wild-magic path: tryResolveWildMagic is a stub hook; void eligibility +
// joint-entropy tier-bracket scan are deferred.

import 'dart:typed_data';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/casting_enhancements.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/terrain.dart';

import 'proof_intake.dart' show VerifiedSpellOutputs;
import 'trajectory_parser.dart' show ParsedFormula;

class EffectResolver {
  /// Resolve a [ParsedFormula] into a fully-typed [EffectDescriptor].
  ///
  /// [enhancements.isPotent] selects bracketed values from the effect table.
  /// Call once per formula triplet in a spell's trajectory.
  static EffectDescriptor resolve(
    ParsedFormula formula, [
    CastingEnhancements enhancements = const CastingEnhancements(),
  ]) {
    final affinity = spellAffinityFromZone(formula.affinity);
    final effectKind = effectKindFromPair(formula.effectType1, formula.effectType2);
    return EffectDescriptor(
      affinity: affinity,
      effectKind: effectKind,
      spellEffect: _build(affinity, effectKind, enhancements.isPotent),
    );
  }

  // ignore: long-method
  static SpellEffect _build(SpellAffinity affinity, EffectKind kind, bool p) {
    return switch ((affinity, kind)) {
      // ── Damage (Fire-Fire) [+50% amount under potency] ────────────────────
      (SpellAffinity.fire, EffectKind.damage) =>
        DamageEffect(amount: p ? 6 : 4, kind: DamageKind.direct),
      (SpellAffinity.earth, EffectKind.damage) =>
        DamageEffect(amount: p ? 3 : 2, kind: DamageKind.traversal),
      (SpellAffinity.water, EffectKind.damage) =>
        DamageEffect(amount: p ? 3 : 2, kind: DamageKind.splash, splashRadius: 2),
      (SpellAffinity.air, EffectKind.damage) =>
        DamageEffect(amount: p ? 3 : 2, kind: DamageKind.knockback, knockback: 1),

      // ── Barrier (Earth-Earth) 2[3] turns ──────────────────────────────────
      (SpellAffinity.fire, EffectKind.barrier) =>
        BarrierEffect(hp: 2, durationTurns: p ? 4 : 3, fireAura: true),
      (SpellAffinity.earth, EffectKind.barrier) =>
        BarrierEffect(hp: 4, durationTurns: p ? 4 : 3),
      (SpellAffinity.water, EffectKind.barrier) =>
        BarrierEffect(hp: 2, durationTurns: p ? 4 : 3, manaRegenBonusPct: 10),
      (SpellAffinity.air, EffectKind.barrier) =>
        BarrierEffect(hp: 2, durationTurns: p ? 4 : 3, freeMoveOnCollapse: true),

      // ── Reflections (Water-Water) 2[3] triggers ───────────────────────────
      // All affinities produce the same pool of 4 triggers; potency grants 3
      // random triggers instead of 2. Affinity has no effect on trigger type.
      (_, EffectKind.reflections) => ReflectionEffect(triggerCount: p ? 3 : 2, durationTurns: p ? 4 : 3),

      // ── Speed Manipulation (Air-Air) ──────────────────────────────────────
      (SpellAffinity.fire, EffectKind.speedManipulation) =>
        SpeedManipulationEffect(
          affinity: SpellAffinity.fire,
          highMobility: true,
          freeExtraTiles: p ? 1 : 0,
        ),
      (SpellAffinity.earth, EffectKind.speedManipulation) =>
        SpeedManipulationEffect(
          affinity: SpellAffinity.earth,
          speedDelta: -1,
          durationTurns: p ? 5 : 4,
        ),
      (SpellAffinity.water, EffectKind.speedManipulation) =>
        SpeedManipulationEffect(
          affinity: SpellAffinity.water,
          highLiquidity: true,
          freeExtraTiles: p ? 1 : 0,
        ),
      (SpellAffinity.air, EffectKind.speedManipulation) =>
        SpeedManipulationEffect(
          affinity: SpellAffinity.air,
          speedDelta: 1,
          durationTurns: p ? 4 : 3,
        ),

      // ── Status Effect Interaction (Fire-Earth) ────────────────────────────
      (SpellAffinity.fire, EffectKind.statusEffectInteraction) =>
        StatusEffectInteractionEffect(
          affinity: SpellAffinity.fire,
          damagePerEffect: p ? 2 : 1,
        ),
      (SpellAffinity.earth, EffectKind.statusEffectInteraction) =>
        StatusEffectInteractionEffect(
          affinity: SpellAffinity.earth,
          isDormant: true,
          durationTurns: p ? 4 : 3,
        ),
      (SpellAffinity.water, EffectKind.statusEffectInteraction) =>
        StatusEffectInteractionEffect(
          affinity: SpellAffinity.water,
          turnsRemoved: p ? 2 : 1,
        ),
      (SpellAffinity.air, EffectKind.statusEffectInteraction) =>
        StatusEffectInteractionEffect(
          affinity: SpellAffinity.air,
          turnsAdded: p ? 2 : 1,
        ),

      // ── Chain Interaction (Fire-Water) ────────────────────────────────────
      (SpellAffinity.fire, EffectKind.chainInteraction) =>
        ChainInteractionEffect(
          affinity: SpellAffinity.fire,
          chainAccumulationMultiplier: 2.0,
          durationTurns: p ? 4 : 3,
        ),
      (SpellAffinity.earth, EffectKind.chainInteraction) =>
        ChainInteractionEffect(
          affinity: SpellAffinity.earth,
          chainAccumulationMultiplier: 0.5,
          durationTurns: p ? 5 : 4,
        ),
      (SpellAffinity.water, EffectKind.chainInteraction) =>
        ChainInteractionEffect(
          affinity: SpellAffinity.water,
          transferChainFromTarget: true,
          chainTransferBonus: p ? 1 : 0,
        ),
      // Base: clear all chains. Potent: additionally curse the next cast
      // (chainSurcharge). Both brackets take the "clear" path in
      // EffectApplicator._applyChainInteraction -- setAllChainsToNegative is
      // the dispatch flag for that whole branch, not just the potent half.
      (SpellAffinity.air, EffectKind.chainInteraction) =>
        ChainInteractionEffect(
          affinity: SpellAffinity.air,
          setAllChainsToNegative: true,
          negativeValue: p ? -1 : 0,
        ),

      // ── Spell Interaction (Fire-Air) ──────────────────────────────────────
      (SpellAffinity.fire, EffectKind.spellInteraction) =>
        SpellInteractionEffect(
          affinity: SpellAffinity.fire,
          nextSpellCostMultiplier: 2,
          hpPerManaMissed: p ? 2 : 1,
          manaPerHp: 10,
        ),
      (SpellAffinity.earth, EffectKind.spellInteraction) =>
        SpellInteractionEffect(
          affinity: SpellAffinity.earth,
          durationTurns: p ? 5 : 4,
          isSlugEffect: true,
        ),
      (SpellAffinity.water, EffectKind.spellInteraction) =>
        SpellInteractionEffect(
          affinity: SpellAffinity.water,
          copySpellCount: p ? 2 : 1,
        ),
      (SpellAffinity.air, EffectKind.spellInteraction) =>
        SpellInteractionEffect(
          affinity: SpellAffinity.air,
          durationTurns: p ? 4 : 3,
          isQuickEffect: true,
        ),

      // ── Fuel Transmutation (Earth-Fire) 1[2] / 4[8] / 100[200] ────────────
      (SpellAffinity.fire, EffectKind.fuelTransmutation) =>
        FuelTransmutationEffect(
          affinity: SpellAffinity.fire,
          witherSpellCount: p ? 2 : 1,
          gainArtifactCount: p ? 2 : 1,
        ),
      (SpellAffinity.earth, EffectKind.fuelTransmutation) =>
        FuelTransmutationEffect(
          affinity: SpellAffinity.earth,
          burnLife: p ? 8 : 4,
          reactivateSpellCount: p ? 2 : 1,
        ),
      (SpellAffinity.water, EffectKind.fuelTransmutation) =>
        FuelTransmutationEffect(
          affinity: SpellAffinity.water,
          burnMana: p ? 200 : 100,
          gainLife: p ? 8 : 4,
        ),
      (SpellAffinity.air, EffectKind.fuelTransmutation) =>
        FuelTransmutationEffect(
          affinity: SpellAffinity.air,
          burnArtifactCount: p ? 2 : 1,
          gainMana: p ? 200 : 100,
        ),

      // ── Tile Modification (Earth-Water) [canPlaceSecond under potency] ────
      // ConveyorTile direction is HexCoord(0,0) sentinel — direction chosen by
      // EffectApplicator at resolution time from the caster's choice.
      (SpellAffinity.fire, EffectKind.tileModification) =>
        TileModificationEffect(
          affinity: SpellAffinity.fire,
          tileEffect: const FloorIsLava(damage: 2),
          canPlaceSecond: p,
        ),
      (SpellAffinity.earth, EffectKind.tileModification) =>
        TileModificationEffect(
          affinity: SpellAffinity.earth,
          tileEffect: const ImpassableTile(),
          canPlaceSecond: p,
        ),
      (SpellAffinity.water, EffectKind.tileModification) =>
        TileModificationEffect(
          affinity: SpellAffinity.water,
          tileEffect: const SlowTile(extraMoveCost: 2, manaDrainOnEntry: 10),
          canPlaceSecond: p,
        ),
      (SpellAffinity.air, EffectKind.tileModification) =>
        TileModificationEffect(
          affinity: SpellAffinity.air,
          tileEffect: const ConveyorTile(direction: HexCoord(0, 0)),
          canPlaceSecond: p,
        ),

      // ── Range Modification (Earth-Air) ────────────────────────────────────
      (SpellAffinity.fire, EffectKind.rangeModification) =>
        RangeModificationEffect(
          affinity: SpellAffinity.fire,
          penetrating: true,
          penetrationDamage: p ? 2 : 1,
          durationTurns: p ? 4 : 3,
        ),
      (SpellAffinity.earth, EffectKind.rangeModification) =>
        RangeModificationEffect(
          affinity: SpellAffinity.earth,
          rangeDelta: -1,
          durationTurns: p ? 5 : 4,
        ),
      (SpellAffinity.water, EffectKind.rangeModification) =>
        RangeModificationEffect(
          affinity: SpellAffinity.water,
          turbulent: true,
          durationTurns: p ? 5 : 4,
        ),
      (SpellAffinity.air, EffectKind.rangeModification) =>
        RangeModificationEffect(
          affinity: SpellAffinity.air,
          rangeDelta: 1,
          durationTurns: p ? 4 : 3,
        ),

      // ── Clouds (Water-Fire) radius 1 (2 for Water), 2 turns ───────────────
      // No potency brackets given in the design doc for Clouds.
      (SpellAffinity.fire, EffectKind.clouds) =>
        const CloudEffect(affinity: SpellAffinity.fire, kind: ToxicCloud(damagePerTurn: 1)),
      (SpellAffinity.earth, EffectKind.clouds) =>
        const CloudEffect(affinity: SpellAffinity.earth, kind: DustCloud(restrictionTurnsAfterLeaving: 3)),
      (SpellAffinity.water, EffectKind.clouds) =>
        const CloudEffect(affinity: SpellAffinity.water, kind: WaterCloud(), radius: 2),
      (SpellAffinity.air, EffectKind.clouds) =>
        const CloudEffect(affinity: SpellAffinity.air, kind: MobileCloud()),

      // ── Artifacts Interaction (Water-Earth) 1[2] count ────────────────────
      (_, EffectKind.artifactsInteraction) =>
        ArtifactsInteractionEffect(affinity: affinity, count: p ? 2 : 1),

      // ── Illusions (Water-Air) ──────────────────────────────────────────────
      // No potency brackets given in the design doc for Illusions.
      (SpellAffinity.fire, EffectKind.illusions) =>
        const IllusionEffect(affinity: SpellAffinity.fire, copyAggressiveMinion: true),
      (SpellAffinity.earth, EffectKind.illusions) =>
        const IllusionEffect(affinity: SpellAffinity.earth, copyTerrainExpand: true),
      (SpellAffinity.water, EffectKind.illusions) =>
        const IllusionEffect(affinity: SpellAffinity.water, wizardDecoyCount: 3),
      (SpellAffinity.air, EffectKind.illusions) =>
        const IllusionEffect(affinity: SpellAffinity.air, convertToIllusion: true),

      // ── Multiplier Cycles (Air-Fire) 2[3]× ───────────────────────────────
      // Cycle: Fire→Air→Water→Earth→Fire (each affinity amplifies the next).
      (SpellAffinity.fire, EffectKind.multiplierCycles) =>
        MultiplierCyclesEffect(targetElement: SpellAffinity.air, multiplier: p ? 3 : 2),
      (SpellAffinity.earth, EffectKind.multiplierCycles) =>
        MultiplierCyclesEffect(targetElement: SpellAffinity.fire, multiplier: p ? 3 : 2),
      (SpellAffinity.water, EffectKind.multiplierCycles) =>
        MultiplierCyclesEffect(targetElement: SpellAffinity.earth, multiplier: p ? 3 : 2),
      (SpellAffinity.air, EffectKind.multiplierCycles) =>
        MultiplierCyclesEffect(targetElement: SpellAffinity.water, multiplier: p ? 3 : 2),

      // ── Haymaker Interaction (Air-Earth) 2[3] turns ───────────────────────
      (SpellAffinity.fire, EffectKind.haymakerInteraction) =>
        HaymakerInteractionEffect(
          affinity: SpellAffinity.fire,
          durationTurns: p ? 4 : 3,
          doTStackIncrement: 2,
        ),
      (SpellAffinity.earth, EffectKind.haymakerInteraction) =>
        HaymakerInteractionEffect(
          affinity: SpellAffinity.earth,
          durationTurns: p ? 4 : 3,
          slowsTarget: true,
        ),
      (SpellAffinity.water, EffectKind.haymakerInteraction) =>
        HaymakerInteractionEffect(
          affinity: SpellAffinity.water,
          durationTurns: p ? 4 : 3,
          drainTargetStatus: true,
        ),
      (SpellAffinity.air, EffectKind.haymakerInteraction) =>
        HaymakerInteractionEffect(
          affinity: SpellAffinity.air,
          durationTurns: p ? 4 : 3,
          distanceBonusDamage: true,
        ),

      // ── Divination (Air-Water) ────────────────────────────────────────────
      // Fire: durationTurns=0 signals rest-of-match (see DivinationEffect docs).
      (SpellAffinity.fire, EffectKind.divination) =>
        DivinationEffect(
          affinity: SpellAffinity.fire,
          durationTurns: 0,
          revealsCounterCharms: true,
        ),
      (SpellAffinity.earth, EffectKind.divination) =>
        DivinationEffect(
          affinity: SpellAffinity.earth,
          durationTurns: p ? 3 : 2,
          grantsScryingSight: true,
        ),
      (SpellAffinity.water, EffectKind.divination) =>
        DivinationEffect(
          affinity: SpellAffinity.water,
          durationTurns: p ? 4 : 3,
          requiresOpponentReveal: true,
        ),
      (SpellAffinity.air, EffectKind.divination) =>
        DivinationEffect(
          affinity: SpellAffinity.air,
          durationTurns: p ? 4 : 3,
          requiresOpponentReveal: true,
        ),
    };
  }

  /// Wild-magic hook: returns null until the wild-magic seam is defined.
  ///
  /// A non-null return indicates the spell qualifies for a void effect instead
  /// of a formula effect. Requires:
  ///   - Zero formula activations in [outputs] (void eligibility).
  ///   - [entropy] (joint commit-reveal) to seed the tier bracket scan.
  ///
  // TODO(battle): implement — check void eligibility (zero formulas), run
  //   the seed-word scan seeded from entropy, return a WildMagicDescriptor
  //   (subtype of EffectDescriptor). Depends on power-audit tier thresholds
  //   and the wild-magic table (design doc §wild-magic, §void-spells).
  static EffectDescriptor? tryResolveWildMagic(
    VerifiedSpellOutputs outputs,
    Uint8List entropy,
  ) {
    return null;
  }
}
