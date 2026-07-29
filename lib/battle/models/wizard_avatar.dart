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

  /// Air-typed loadout artifact (design v3.0 §Artifacts). One-shot: activated
  /// before a cast to add +1 effective radius to that spell's effects (and one
  /// size rung to a summoned minion), then consumed. Only one per spell.
  /// Appended last so pre-existing AccoutrementKind indices — hashed into
  /// BattleState.toCanonicalBytes() — don't shift.
  rodOfSpreading,
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

// ── PendingMultiplier (Air-Fire Bellows) ───────────────────────────────────────

/// A queued Bellows amplification, landing on whoever occupies the spell's
/// target tile (see EffectApplicator._applyMultiplierCycles) — not
/// automatically the caster. Consumed the moment a later formula — in the
/// same spell, or in a spell the *recipient* casts on the immediately
/// following turn — matches [targetElement] stored in
/// [WizardAvatar.pendingEffectMultipliers]'s key. Expires (is removed by
/// [WizardAvatar.tickStatusEffects]) if unused by the end of that following
/// turn: cast turn + 1 turn to use it, 2 turns total.
class PendingMultiplier {
  PendingMultiplier({required this.multiplier, required this.remainingTurns});

  /// 2 normally, 3 under potency.
  final int multiplier;

  int remainingTurns;

  bool tick() {
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
    this.wizardName = '',
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
    Map<SpellAffinity, PendingMultiplier>? pendingEffectMultipliers,
    this.activeChainElement,
  })  : accoutrements = accoutrements ?? [],
        activeStatusEffects = activeStatusEffects ?? [],
        barriers = barriers ?? {},
        chainLengths = chainLengths ?? {},
        pendingEffectMultipliers = pendingEffectMultipliers ?? {};

  final String playerId;

  /// Poseidon2(inscriber's Ed25519 pubkey) — matches the proof's owner_pubkey.
  final String ownerPubkeyHex;

  /// Player-chosen display name (Identity.loadWizardName()), exchanged
  /// unauthenticated over LAN alongside the artifact loadout — presentation
  /// only, never fed into toCanonicalBytes()'s state-hash lockstep. Empty
  /// when unknown (e.g. solo/practice dummy); callers fall back to a
  /// playerId-derived label.
  final String wizardName;

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

  /// Chain length in **half-credits**, always ≥ 0 — a normal advance is +2,
  /// `chainFast` (200% rate) is +4, `chainSlow` (50% rate) is +1, so the slow
  /// effect isn't a no-op despite chain length itself always being a whole
  /// number of casts. Effective chain length is `credits ~/ 2`. Regression
  /// floors at 0 (see [TurnLoop._regressChain]).
  ///
  /// Only [activeChainElement]'s entry is ever "live" (only one chain is
  /// active at a time — see design doc's 2026-07-26 simplification); other
  /// entries can briefly exist mid-transfer (Fire-Water/Water Chain
  /// Interaction copies an opponent's whole map) but are otherwise unused.
  ///
  /// The Fire-Water/Air Chain Interaction effect's "−1 chain length"
  /// surcharge does **not** live here — a stored negative value has no
  /// element to attach to once the effect also clears [activeChainElement].
  /// It's instead a one-shot [StatusEffectId.chainSurcharge] consumed on the
  /// wizard's next cast (see [TurnLoop._spellManaCost]).
  final Map<SpellAffinity, int> chainLengths;

  /// Effective chain length (whole casts) for [activeChainElement], or 0 if
  /// no chain is active.
  int get chainLength {
    final el = activeChainElement;
    if (el == null) return 0;
    return (chainLengths[el] ?? 0) ~/ 2;
  }

  // ── Pending effect multipliers (Air-Fire) ─────────────────────────────────

  /// Element → queued Bellows amplification. Always self-applied (never the
  /// spell's target tile). When the caster's next matching-affinity effect
  /// resolves — in the same spell (immediately) or a spell cast on the
  /// following turn — it is amplified by the stored multiplier and the entry
  /// is consumed. Unused entries expire via [tickStatusEffects] (2 turns
  /// total: the cast turn plus one more to use it).
  final Map<SpellAffinity, PendingMultiplier> pendingEffectMultipliers;

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

  /// Rods of Spreading currently carried (each is consumed on use). A cast may
  /// activate at most one; see TurnLoop's rod-consumption in the cast path.
  int get rodOfSpreadingCount => accoutrements
      .where((a) => a.kind == AccoutrementKind.rodOfSpreading)
      .length;

  /// Bookmarks currently carried. Drives hand size (handSize == bookmarkCount
  /// + 1, see TurnLoop._dealOpeningHandsIfNeeded / _reconcileHandSize) —
  /// design v3.0 §Artifacts: "each bookmark tracks a spell... players toggle
  /// between bookmarked spells for casting (effectively hand size)."
  int get bookmarkCount =>
      accoutrements.where((a) => a.kind == AccoutrementKind.bookmark).length;

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

  /// Mana cost multiplier for casting a spell whose single pure affinity is
  /// [pureAffinity] (null for a hybrid spell — never discount-eligible, see
  /// design doc's 2026-07-26 simplification).
  ///
  /// Returns `0.9 ^ chainLength` (always in `(0, 1]`, since [chainLength] is
  /// never negative) when [pureAffinity] matches the active chain element.
  /// Returns `1.0` (no effect) otherwise — no active chain, a hybrid spell,
  /// or a pure spell of a different element. This is a cost *multiplier*,
  /// meant to compose multiplicatively with Efficiency / sorcerer /
  /// cost-double, never additively.
  ///
  /// The Air-flavor Chain Interaction surcharge is *not* expressed through
  /// this getter — see [chainLengths]'s doc comment.
  double chainCostMultiplier(SpellAffinity? pureAffinity) {
    if (pureAffinity == null || activeChainElement != pureAffinity) return 1.0;
    return pow(0.9, chainLength).toDouble();
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

    // Bellows: an unused pending multiplier expires 2 turns after being cast
    // (the cast turn plus one more turn to land a matching effect).
    pendingEffectMultipliers.removeWhere((_, m) => !m.tick());
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

  /// Set by [absorbDamage] when a barrier with [BarrierState.freeMoveOnCollapse]
  /// is destroyed by damage this turn ("burst" — as distinct from expiring
  /// from old age via [tickBarriers], which is a separate, still-unwired
  /// path). Consumed and cleared once per turn by TurnLoop's post-resolution
  /// free-move phase, after every spell for the turn has fully resolved.
  bool pendingFreeMoveBurst = false;

  /// Absorb [damage] through active barriers in element order
  /// (fire → earth → water → air), then into real [hp].
  /// Returns the final HP damage dealt to real [hp] for state-hash tracking.
  int absorbDamage(int damage) {
    var remaining = damage;
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null || !b.isAlive || remaining <= 0) continue;
      remaining = b.absorb(remaining);
      if (!b.isAlive) {
        if (b.freeMoveOnCollapse) pendingFreeMoveBurst = true;
        barriers.remove(element);
      }
    }
    if (remaining > 0) {
      hp = (hp - remaining).clamp(0, 999999);
    }
    return remaining;
  }

  bool get isAlive => hp > 0;
}
