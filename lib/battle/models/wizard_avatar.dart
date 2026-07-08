// SPDX-License-Identifier: GPL-3.0-or-later
//
// wizard_avatar.dart — WizardAvatar, Accoutrement, and StatusEffect models.
//
// Accoutrement kinds (design doc §artifacts):
//   Water — Mana Gems (first = indestructible core gem; +100 pool / +10 regen)
//   Fire  — Counter Charms (keyed to a spell's commitmentHex; commit-reveal)
//   Air   — Bookmarks (hand size; auto-retarget on use — SpellDraw)
//   Earth — Absorption Rods: when hit by an enemy spell, all time-based
//            effects from that spell have their duration halved (rounded up);
//            consumes 1 rod per spell hit.
//   (summoned) Deflection Totem: functionally identical to Absorption Rod;
//            summoned by Water-Earth/Earth (ArtifactsInteractionEffect).
//
// WizardAvatar carries:
//   - Barriers (per-element body-armor HP buffers, 1 per element max)
//   - Chain state (active element, per-element chain lengths — can be negative)
//   - Pending effect multipliers (Air-Fire multiplierCycles results)
//   - Derived stat getters (effectiveMoveSpeed, effectiveSpellRange, etc.)
//     computed from base values + active status-effect modifiers
//
// StatusEffect.effectTypeId must be one of the constants in StatusEffectId.
// StatusEffect.modifiers keys are documented in status_effect_ids.dart.

import 'dart:math' show pow;

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';

// ── Accoutrement ──────────────────────────────────────────────────────────────

enum AccoutrementKind {
  manaGem,
  counterCharm,
  bookmark,
  absorptionRod,

  /// Summoned by Water-Earth/Earth (ArtifactsInteractionEffect, Earth affinity).
  /// Mechanically identical to [absorptionRod]: halves timed effect durations
  /// from an incoming enemy spell, consuming this totem.
  deflectionTotem,
}

class Accoutrement {
  const Accoutrement({
    required this.id,
    required this.kind,
    this.isCoreGem = false,
    this.targetCommitmentHex,
    this.counterCharmRevealed = false,
  });

  final String id;
  final AccoutrementKind kind;

  /// [manaGem] only: true for the first gem — indestructible; never targeted
  /// by burn effects (design doc: "can't hit core gem").
  final bool isCoreGem;

  /// [counterCharm] only: the Poseidon2 grid-hash of the targeted spell.
  /// Triggers when the opponent casts a spell whose commitment matches —
  /// revealed via commit-reveal-with-salt at activation time.
  final String? targetCommitmentHex;

  /// [counterCharm] only: true once the charm has activated and its target
  /// has been publicly revealed.
  final bool counterCharmRevealed;

  // Absorption Rod / Deflection Totem mechanic:
  // When the owning avatar is hit by any enemy spell, BEFORE applying each
  // time-based effect, check if the avatar has absorptionRod or deflectionTotem
  // accoutrements. If so: halve all time-based effect durations (ceil), consume
  // 1 rod/totem per spell (not per effect). Implemented in EffectApplicator.

  // TODO(battle): counter charm reveal hook — reveal targetCommitmentHex via
  //   commit-reveal-with-salt (design doc §mystery-and-counter-charms).
  //   Trigger: opponent's spell commitmentHex == targetCommitmentHex AND
  //   the casting ownerPubkeyHex != this charm's owner's ownerPubkeyHex.
  // TODO(battle): burn hook — remove this accoutrement from avatar and apply
  //   burn effect; targeting drawn from CommitRevealEntropy (design doc §burn).
  //   Burning a counter charm reveals its targetCommitmentHex.

  Accoutrement copyWith({
    String? targetCommitmentHex,
    bool? counterCharmRevealed,
  }) =>
      Accoutrement(
        id: id,
        kind: kind,
        isCoreGem: isCoreGem,
        targetCommitmentHex: targetCommitmentHex ?? this.targetCommitmentHex,
        counterCharmRevealed: counterCharmRevealed ?? this.counterCharmRevealed,
      );
}

// ── StatusEffect ──────────────────────────────────────────────────────────────

class StatusEffect {
  StatusEffect({
    required this.effectTypeId,
    required this.remainingTurns,
    Map<String, int>? modifiers,
    this.isDormant = false,
  }) : modifiers = Map.unmodifiable(modifiers ?? {});

  /// One of the constants in [StatusEffectId].
  final String effectTypeId;

  int remainingTurns;

  /// Open key→value modifier map. Well-known keys are documented in
  /// status_effect_ids.dart alongside the effectTypeId that uses them.
  final Map<String, int> modifiers;

  /// True when this status effect is suppressed (Water-Air / statusDormant).
  /// Dormant effects do not tick and do not apply their modifiers.
  bool isDormant;

  bool tick() {
    if (isDormant) return remainingTurns > 0;
    if (remainingTurns > 0) remainingTurns--;
    return remainingTurns > 0;
  }
}

// ── WizardAvatar ──────────────────────────────────────────────────────────────

/// Base values used for derived-stat calculations.
const int _kBaseMoveSpeed = 2;

class WizardAvatar {
  WizardAvatar({
    required this.playerId,
    required this.ownerPubkeyHex,
    required this.hp,
    required this.mana,
    required this.maxMana,
    required this.position,
    required this.teamId,
    required this.baseSpellRange,
    List<Accoutrement>? accoutrements,
    List<StatusEffect>? activeStatusEffects,
    Map<SpellAffinity, BarrierState>? barriers,
    Map<SpellAffinity, int>? chainLengths,
    Map<SpellAffinity, int>? pendingEffectMultipliers,
    this.activeChainElement,
  })  : accoutrements = accoutrements ?? [],
        activeStatusEffects = activeStatusEffects ?? [],
        barriers = barriers ?? {},
        chainLengths = chainLengths ?? {},
        pendingEffectMultipliers = pendingEffectMultipliers ?? {};

  final String playerId;

  /// Poseidon2(inscriber's Ed25519 pubkey) — matches the proof's owner_pubkey.
  final String ownerPubkeyHex;

  int hp;
  int mana;
  int maxMana;
  HexCoord position;
  final String teamId;

  /// Base spell range from MatchConfig (default 3). Velocity enhancement (+2)
  /// is added by EffectResolver; range status effects stack on top.
  final int baseSpellRange;

  final List<Accoutrement> accoutrements;
  final List<StatusEffect> activeStatusEffects;

  // ── Barriers (Earth-Earth effect) ─────────────────────────────────────────

  /// At most one barrier per element. Damage is absorbed in element order
  /// (fire → earth → water → air); overflow flows to real [hp].
  final Map<SpellAffinity, BarrierState> barriers;

  // ── Chain discount system ─────────────────────────────────────────────────

  SpellAffinity? activeChainElement;

  /// Per-element chain lengths. Can be negative (Fire-Water/Air effect sets
  /// chains to −1, making the discount formula a cost multiplier instead).
  final Map<SpellAffinity, int> chainLengths;

  // ── Pending effect multipliers (Air-Fire) ─────────────────────────────────

  /// Element → multiplier (2 or 3). When the caster's next spell contains an
  /// effect whose affinity matches a key here, that effect is amplified by the
  /// stored value and the entry is consumed.
  final Map<SpellAffinity, int> pendingEffectMultipliers;

  // ── Derived stats from accoutrements ──────────────────────────────────────

  int get manaGemsEquipped =>
      accoutrements.where((a) => a.kind == AccoutrementKind.manaGem).length;

  int get manaRegenPerTurn => manaGemsEquipped * 10;

  int get maxManaFromGems => manaGemsEquipped * 100;

  int get absorptionRodCount => accoutrements
      .where((a) =>
          a.kind == AccoutrementKind.absorptionRod ||
          a.kind == AccoutrementKind.deflectionTotem)
      .length;

  // ── Derived stats from status effects ─────────────────────────────────────

  int get effectiveMoveSpeed {
    var speed = _kBaseMoveSpeed;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.speedUp ||
          fx.effectTypeId == StatusEffectId.speedDown) {
        speed += fx.modifiers['speedDelta'] ?? 0;
      }
    }
    return speed.clamp(0, 999);
  }

  int get effectiveSpellRange {
    var range = baseSpellRange;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.rangeUp ||
          fx.effectTypeId == StatusEffectId.rangeDown) {
        range += fx.modifiers['rangeDelta'] ?? 0;
      }
    }
    return range.clamp(1, 999);
  }

  bool get hasPenetrating => activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.penetrating);

  int get penetrationDamage {
    for (final fx in activeStatusEffects) {
      if (!fx.isDormant && fx.effectTypeId == StatusEffectId.penetrating) {
        return fx.modifiers['penetrationDamage'] ?? 1;
      }
    }
    return 0;
  }

  bool get hasTurbulent => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.turbulent);

  bool get isSluggish => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.sluggish);

  bool get isQuick => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.quick);

  bool get isBlind => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.blind);

  bool get nextSpellCostDoubled => activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.nextSpellCostDouble);

  /// Chain accumulation multiplier from active chainFast / chainSlow effects.
  /// 1.0 = normal; 2.0 = fast (Fire-Water/Fire); 0.5 = slow (Fire-Water/Earth).
  /// If both are active the last one applied wins (expected never to overlap).
  double get chainAccumulationMultiplier {
    for (final fx in activeStatusEffects.reversed) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.chainFast ||
          fx.effectTypeId == StatusEffectId.chainSlow) {
        return (fx.modifiers['chainAccMultiplierPct'] ?? 100) / 100.0;
      }
    }
    return 1.0;
  }

  bool get hasHighMobility => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.highMobility);

  bool get hasHighLiquidity => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.highLiquidity);

  int get highMobilityFreeTiles {
    for (final fx in activeStatusEffects) {
      if (!fx.isDormant && fx.effectTypeId == StatusEffectId.highMobility) {
        return fx.modifiers['freeExtraTiles'] ?? 0;
      }
    }
    return 0;
  }

  int get highLiquidityFreeTiles {
    for (final fx in activeStatusEffects) {
      if (!fx.isDormant && fx.effectTypeId == StatusEffectId.highLiquidity) {
        return fx.modifiers['freeExtraTiles'] ?? 0;
      }
    }
    return 0;
  }

  bool get hasHaymakerDot => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.haymakerDot);

  bool get hasHaymakerSlow => activeStatusEffects
      .any((fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.haymakerSlow);

  bool get hasHaymakerStatusDrain => activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.haymakerStatusDrain);

  bool get hasHaymakerDistanceBonus => activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.haymakerDistanceBonus);

  bool get canRevealCounterCharms => activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.revealCounterCharms);

  // ── Barrier-derived stats ─────────────────────────────────────────────────

  /// Extra mana regen per turn from active Water barriers.
  int barrierManaRegenFor(int currentMaxMana) {
    final wb = barriers[SpellAffinity.water];
    if (wb == null || !wb.isAlive) return 0;
    return (currentMaxMana * wb.manaRegenBonusPct / 100).round();
  }

  // ── Chain discount ────────────────────────────────────────────────────────

  /// Mana discount multiplier for a spell with [alignmentFraction] of its
  /// formulas aligned with the active chain element.
  ///
  /// Returns a value in (0, 1) for a discount (positive chain length),
  /// returns >1 for a cost increase (negative chain length).
  /// Returns 0 (no discount) when there is no active chain.
  double chainDiscountMultiplier(double alignmentFraction) {
    final el = activeChainElement;
    if (el == null || alignmentFraction == 0) return 0;
    final length = chainLengths[el] ?? 0;
    if (length == 0) return 0;
    // 0.9^length: negative length gives >1 (cost increase as designed).
    return pow(0.9, length).toDouble() * alignmentFraction;
  }

  // ── Status effect lifecycle ────────────────────────────────────────────────

  /// Ticks all active status effects, removing expired ones and ticking
  /// barriers. Call once per turn after spell resolution.
  void tickStatusEffects() {
    // Dormant effects: tick the dormant state separately — the statusDormant
    // effect itself still ticks and expires normally.
    final dormantActive =
        activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.statusDormant && !fx.isDormant);
    for (final fx in activeStatusEffects) {
      if (fx.effectTypeId != StatusEffectId.statusDormant) {
        fx.isDormant = dormantActive;
      }
    }
    activeStatusEffects.removeWhere((e) => !e.tick());
  }

  /// Ticks all barriers, handling collapse side-effects. Returns true if any
  /// barrier with [freeMoveOnCollapse] collapsed this tick (granting free move).
  bool tickBarriers() {
    bool freeMove = false;
    final toRemove = <SpellAffinity>[];
    for (final entry in barriers.entries) {
      final wasAlive = entry.value.isAlive;
      final stillAlive = entry.value.tick();
      if (wasAlive && !stillAlive) {
        if (entry.value.freeMoveOnCollapse) freeMove = true;
        toRemove.add(entry.key);
      }
    }
    toRemove.forEach(barriers.remove);
    return freeMove;
  }

  /// Absorb [damage] through active barriers in element order
  /// (fire → earth → water → air), then into real [hp].
  /// Returns the final HP damage dealt to real [hp] for state-hash tracking.
  int absorbDamage(int damage) {
    var remaining = damage;
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null || !b.isAlive || remaining <= 0) continue;
      remaining = b.absorb(remaining);
      if (!b.isAlive) barriers.remove(element);
    }
    if (remaining > 0) {
      hp = (hp - remaining).clamp(0, 999999);
    }
    return remaining;
  }

  bool get isAlive => hp > 0;
}
