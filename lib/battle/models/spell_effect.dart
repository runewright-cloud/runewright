// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_effect.dart — Sealed SpellEffect hierarchy.
//
// One concrete class per EffectKind (16 total). EffectResolver.resolve()
// constructs the appropriate subclass with potency already folded in (bracketed
// values pre-selected). EffectApplicator.apply() pattern-matches on these to
// mutate BattleState.
//
// Fields document the flavor dimension inline:
//   "Fire affinity" / "Earth affinity" / "Water affinity" / "Air affinity"
// describe which fields are set by each of the four formula-affinity columns.
// Fields unused by a given affinity are left at their defaults.

import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/terrain.dart' show TileEffect, CloudKind;

sealed class SpellEffect {
  const SpellEffect();
}

// ── Fire-Fire: Damage ─────────────────────────────────────────────────────────

enum DamageKind {
  /// Fire affinity: direct damage to the target hex.
  direct,

  /// Earth affinity: passes through en route, dealing damage to barriers,
  /// spirits, and entities in traversed hexes before hitting the target.
  traversal,

  /// Water affinity: AoE centred on target hex.
  splash,

  /// Air affinity: direct damage + physical knockback (pushed away from caster).
  knockback,
}

/// Damage effect. Potency: +50% to [amount] (rounded up), pre-applied.
class DamageEffect extends SpellEffect {
  const DamageEffect({
    required this.amount,
    required this.kind,
    this.splashRadius = 0,
    this.knockback = 0,
  });

  final int amount;
  final DamageKind kind;

  /// Water affinity: AoE radius in tiles (2).
  final int splashRadius;

  /// Air affinity: tiles pushed away from the caster (1).
  /// Sorcerer seam: shown as an on-screen indicator in real-time mode.
  // TODO(sorcerer): knockback indicator in real-time mode.
  final int knockback;
}

// ── Earth-Earth: Barrier ──────────────────────────────────────────────────────

/// Body-armor HP buffer applied to the caster. Potency: duration 2→3 turns.
///
///   Fire affinity:  hp=2; [fireAura]=true (1 fire dmg/turn to adjacent entities)
///   Earth affinity: hp=4; no special
///   Water affinity: hp=2; [manaRegenBonusPct]=10 while active
///   Air affinity:   hp=2; [freeMoveOnCollapse]=true
class BarrierEffect extends SpellEffect {
  const BarrierEffect({
    required this.hp,
    required this.durationTurns,
    this.fireAura = false,
    this.manaRegenBonusPct = 0,
    this.freeMoveOnCollapse = false,
  });

  final int hp;
  final int durationTurns;
  final bool fireAura;
  final int manaRegenBonusPct;
  final bool freeMoveOnCollapse;
}

// ── Water-Water: Reflections ──────────────────────────────────────────────────

/// Links the caster to an enemy target for the rest of the match.
///
/// At cast time [triggerCount] triggers are randomly selected from the pool
/// of four [ReflectionTrigger] values. The spell fizzles if no enemy avatar
/// occupies the target tile.
///
///   Fire affinity:  damageReflect — caster takes damage → target takes equal
///   Earth affinity: summonMirror  — target summons → caster gets identical copy
///   Water affinity: manaMirror    — target gains mana → caster gains equal
///   Air affinity:   statusMirror  — target self-casts buff → caster gets same
///
/// Potency: 3 triggers instead of 2.
class ReflectionEffect extends SpellEffect {
  const ReflectionEffect({required this.triggerCount, required this.durationTurns});

  /// How many of the 4 possible triggers are randomly selected at cast time.
  /// Base: 2, Potent: 3.
  final int triggerCount;

  /// How many turns the link remains active. Base: 2, Potent: 3.
  final int durationTurns;
}

// ── Air-Air: Speed Manipulation ───────────────────────────────────────────────

/// Modifies movement. Potency applied before construction (bracketed values).
///
///   Fire affinity:  [highMobility]=true; caster may spend HP for extra move tiles.
///                   n extra tiles cost n(n+1)/2 HP; [freeExtraTiles]=1 under potency.
///                   Sorcerer seam: pedometer rate scales with tile count.
///   Earth affinity: [speedDelta]=−1 on target for [durationTurns] (3/4 potent)
///   Water affinity: [highLiquidity]=true; same as Fire but spends mana.
///                   Sorcerer seam: pedometer rate scales with tile count.
///   Air affinity:   [speedDelta]=+1 on caster for [durationTurns] (2/3 potent)
// TODO(sorcerer): high-mobility and high-liquidity extra tiles map to pedometer
//   rate multipliers in real-time mode rather than discrete tile jumps.
class SpeedManipulationEffect extends SpellEffect {
  const SpeedManipulationEffect({
    required this.affinity,
    this.speedDelta = 0,
    this.durationTurns = 0,
    this.affectsTarget = false,
    this.highMobility = false,
    this.highLiquidity = false,
    this.freeExtraTiles = 0,
  });

  final SpellAffinity affinity;

  /// −1 for Earth (debuff), +1 for Air (buff), 0 for Fire/Water.
  final int speedDelta;
  final int durationTurns;

  /// True when the effect applies to the entity on the target tile (Earth/Air).
  /// False when it grants an option to the caster themselves (Fire/Water).
  final bool affectsTarget;

  final bool highMobility;
  final bool highLiquidity;

  /// Under potency: first extra tile costs nothing (Fire and Water affinity).
  final int freeExtraTiles;
}

// ── Fire-Earth: Status Effect Interaction ─────────────────────────────────────

/// Acts on active status effects on the target (or all players). Moved here
/// from Water-Air in the v3.0 effect-table rework (content unchanged).
///
///   Fire affinity:  deal [damagePerEffect] HP per active status effect on target
///   Earth affinity: all target status effects are dormant for [durationTurns] (2/3 potent)
///   Water affinity: all target status effects lose [turnsRemoved] remaining turns (1/2 potent)
///   Air affinity:   all target status effects gain [turnsAdded] remaining turns (1/2 potent)
class StatusEffectInteractionEffect extends SpellEffect {
  const StatusEffectInteractionEffect({
    required this.affinity,
    this.damagePerEffect = 0,
    this.durationTurns = 0,
    this.isDormant = false,
    this.turnsRemoved = 0,
    this.turnsAdded = 0,
  });

  final SpellAffinity affinity;

  /// Fire: 1 normally, 2 under potency.
  final int damagePerEffect;

  /// Earth: 2 normally, 3 under potency.
  final int durationTurns;
  final bool isDormant;

  /// Water: 1 normally, 2 under potency.
  final int turnsRemoved;

  /// Air: 1 normally, 2 under potency.
  final int turnsAdded;
}

// ── Fire-Water: Chain Interaction ─────────────────────────────────────────────

/// Acts on chain-discount accumulation. Potency extends durations.
///
///   Fire affinity:  chain accrues 2× as fast for [durationTurns] (2/3 potent)
///   Earth affinity: chain accrues ½ as fast for [durationTurns] (3/4 potent)
///   Water affinity: [transferChainFromTarget]=true; caster inherits the chain
///                   state of the entity on the target tile, replacing own.
///                   [chainTransferBonus]=1 under potency (adds +1 to gained length).
///   Air affinity:   [setAllChainsToNegative]=true; all chains → [negativeValue]=−1
///                   (chain discount becomes a cost multiplier at negative lengths)
class ChainInteractionEffect extends SpellEffect {
  const ChainInteractionEffect({
    required this.affinity,
    this.chainAccumulationMultiplier = 1.0,
    this.durationTurns = 0,
    this.transferChainFromTarget = false,
    this.chainTransferBonus = 0,
    this.setAllChainsToNegative = false,
    this.negativeValue = 0,
  });

  final SpellAffinity affinity;

  /// Fire: 2.0; Earth: 0.5; others: 1.0 (identity).
  final double chainAccumulationMultiplier;
  final int durationTurns;
  final bool transferChainFromTarget;

  /// Under potency: +1 to the chain length inherited from the target.
  final int chainTransferBonus;

  /// Air flavor's dispatch flag: clears the target's chain outright. Always
  /// true for Air (both potency brackets); [negativeValue] is what
  /// distinguishes base (0, plain clear) from potent (-1, clear + curse the
  /// target's next cast — see StatusEffectId.chainSurcharge).
  final bool setAllChainsToNegative;
  final int negativeValue;
}

// ── Fire-Air: Spell Interaction ───────────────────────────────────────────────

/// Modifies spell cost, resolution order, or copies spells.
///
///   Fire affinity:  next spell costs [nextSpellCostMultiplier]×; shortfall
///                   converts at [hpPerManaMissed] HP per [manaPerHp] mana
///   Earth affinity: target's spells resolve last (sluggish) for [durationTurns]
///   Water affinity: caster copies target's last-cast spell [copySpellCount] times
///   Air affinity:   caster's spells resolve first (quick) for [durationTurns]
class SpellInteractionEffect extends SpellEffect {
  const SpellInteractionEffect({
    required this.affinity,
    this.nextSpellCostMultiplier = 1,
    this.hpPerManaMissed = 0,
    this.manaPerHp = 10,
    this.durationTurns = 0,
    this.affectsTarget = false,
    this.isSlugEffect = false,
    this.isQuickEffect = false,
    this.copySpellCount = 0,
  });

  final SpellAffinity affinity;

  /// Fire: 2 (next spell costs double mana).
  final int nextSpellCostMultiplier;

  /// Fire: HP lost per [manaPerHp] unpaid mana (potent: 2, base: 1).
  final int hpPerManaMissed;
  final int manaPerHp;

  final int durationTurns;

  /// Earth: slug effect applies to opponent; Air: quick applies to self (false).
  final bool affectsTarget;

  final bool isSlugEffect;
  final bool isQuickEffect;

  /// Water: 1 normally, 2 under potency.
  final int copySpellCount;
}

// ── Earth-Fire: Fuel Transmutation ────────────────────────────────────────────

/// Burns one of the caster's own resources to gain another. All four flavors
/// are self-targeting (no [ApplyContext.targetTile] entity involved). Moved
/// here from Water-Fire in the v3.0 effect-table rework (content unchanged).
///
///   Fire affinity:  wither [witherSpellCount] random active (hand) spells
///                   (found by bookmark); gain [gainArtifactCount] random
///                   noncountercharm artifact(s)
///   Earth affinity: burn [burnLife] HP; reactivate [reactivateSpellCount]
///                   withered hand spell(s)
///   Water affinity: burn [burnMana] mana; gain [gainLife] HP
///   Air affinity:   burn [burnArtifactCount] random artifact(s) (not the
///                   core gem); gain [gainMana] mana
class FuelTransmutationEffect extends SpellEffect {
  const FuelTransmutationEffect({
    required this.affinity,
    this.witherSpellCount = 0,
    this.gainArtifactCount = 0,
    this.burnLife = 0,
    this.reactivateSpellCount = 0,
    this.burnMana = 0,
    this.gainLife = 0,
    this.burnArtifactCount = 0,
    this.gainMana = 0,
  });

  final SpellAffinity affinity;

  /// Fire: 1 normally, 2 under potency.
  final int witherSpellCount;

  /// Fire: 1 normally, 2 under potency.
  final int gainArtifactCount;

  /// Earth: 4 normally, 8 under potency.
  final int burnLife;

  /// Earth: 1 normally, 2 under potency.
  final int reactivateSpellCount;

  /// Water: 100 normally, 200 under potency.
  final int burnMana;

  /// Water: 4 normally, 8 under potency.
  final int gainLife;

  /// Air: 1 normally, 2 under potency.
  final int burnArtifactCount;

  /// Air: 100 normally, 200 under potency.
  final int gainMana;
}

// ── Earth-Water: Tile Modification ────────────────────────────────────────────

/// Places a permanent [tileEffect] on the target hex. Potency: [canPlaceSecond]
/// allows placing the same effect on an adjacent tile of the caster's choice.
///
///   Fire affinity:  FloorIsLava(damage:2)
///   Earth affinity: ImpassableTile()
///   Water affinity: SlowTile()
///   Air affinity:   ConveyorTile() — direction chosen at resolution
///
/// Sorcerer seam: forced-movement tile effects show an indicator in real-time.
// TODO(sorcerer): forced-movement tile indicator for real-time mode.
class TileModificationEffect extends SpellEffect {
  const TileModificationEffect({
    required this.affinity,
    required this.tileEffect,
    this.canPlaceSecond = false,
  });

  final SpellAffinity affinity;
  final TileEffect tileEffect;

  /// Potency: caster may place a second copy on an adjacent tile.
  final bool canPlaceSecond;
}

// ── Earth-Air: Range Modification ─────────────────────────────────────────────

/// Modifies spell range. Potency extends duration or boosts penetration damage.
///
///   Fire affinity:  [penetrating]=true; 1[2 potent] damage to entities in
///                   traversed hexes; lasts [durationTurns] (2/3 potent)
///   Earth affinity: target's range [rangeDelta]=−1 for [durationTurns] (3/4 potent)
///   Water affinity: target's next spell range randomised 1–max ([turbulent]=true)
///                   for [durationTurns] (3/4 potent)
///   Air affinity:   caster's range [rangeDelta]=+1 for [durationTurns] (2/3 potent)
class RangeModificationEffect extends SpellEffect {
  const RangeModificationEffect({
    required this.affinity,
    this.rangeDelta = 0,
    this.durationTurns = 0,
    this.affectsTarget = false,
    this.penetrating = false,
    this.penetrationDamage = 0,
    this.turbulent = false,
  });

  final SpellAffinity affinity;

  /// Earth: −1; Air: +1; others: 0.
  final int rangeDelta;
  final int durationTurns;

  /// True for Earth (debuff on target) and Water (turbulent on target).
  /// False for Fire (penetrating on caster) and Air (range buff on caster).
  final bool affectsTarget;

  final bool penetrating;
  final int penetrationDamage;
  final bool turbulent;
}

// ── Water-Fire: Clouds ─────────────────────────────────────────────────────────

/// Places a CloudObject at the target hex. Base effect (all flavors, applied
/// by EffectApplicator/TurnLoop, not carried as a field here): entities in the
/// cloud's radius may only target/be targeted by adjacent entities.
///
///   Fire affinity:  ToxicCloud(damagePerTurn: 1)
///   Earth affinity: DustCloud(restrictionTurnsAfterLeaving: 2) -- the
///                   targeting restriction lingers after leaving
///   Water affinity: WaterCloud(), [radius] = 2 instead of 1
///   Air affinity:   MobileCloud() -- auto-seeks the nearest enemy
///
/// No potency brackets are given for Clouds in the design doc -- [radius] and
/// [durationTurns] are flat regardless of potency.
class CloudEffect extends SpellEffect {
  const CloudEffect({
    required this.affinity,
    required this.kind,
    this.radius = 1,
    this.durationTurns = 2,
  });

  final SpellAffinity affinity;
  final CloudKind kind;
  final int radius;
  final int durationTurns;
}

// ── Water-Earth: Artifacts Interaction ───────────────────────────────────────

/// Acts on artifact loadouts. [count] = 1 normally, 2 under potency.
///
///   Fire affinity:  burn [count] random artifact(s) from target; deal that
///                   many HP damage; target drawn from commit-reveal entropy;
///                   burning a counter charm reveals its commitment
///   Earth affinity: summon [count] Deflection Totem artifact(s) for caster
///                   (functions identically to Absorption Rod — new mechanic)
///   Water affinity: summon [count] Mana Gem artifact(s) for caster
///   Air affinity:   summon [count] Bookmark artifact(s) for caster
class ArtifactsInteractionEffect extends SpellEffect {
  const ArtifactsInteractionEffect({
    required this.affinity,
    required this.count,
  });

  final SpellAffinity affinity;
  final int count;
}

// ── Water-Air: Illusions ───────────────────────────────────────────────────────

/// Illusory copies -- of a summon, of terrain, or of the wizard themself.
/// No potency brackets are given for Illusions in the design doc.
///
///   Fire affinity:  [copyAggressiveMinion]=true -- clone the minion on the
///                   target tile for the caster, at 1 HP, always closing to
///                   attack (see Minion.aggressive / TurnLoop._spiritTurn)
///   Earth affinity: [copyTerrainExpand]=true -- clone the TileEffect on the
///                   target tile onto every terrain-free neighbor; the
///                   copies have 1 HP (destroyed by any damage that touches
///                   their tile -- see BattleState.illusionTerrainTiles)
///   Water affinity: [wizardDecoyCount]=3 -- surround the caster with decoys;
///                   see WizardIllusionSet / EffectApplicator._resolveIllusionRedirect
///   Air affinity:   [convertToIllusion]=true -- the non-wizard entity on the
///                   target tile is reduced to 1 HP
class IllusionEffect extends SpellEffect {
  const IllusionEffect({
    required this.affinity,
    this.copyAggressiveMinion = false,
    this.copyTerrainExpand = false,
    this.wizardDecoyCount = 0,
    this.convertToIllusion = false,
  });

  final SpellAffinity affinity;
  final bool copyAggressiveMinion;
  final bool copyTerrainExpand;
  final int wizardDecoyCount;
  final bool convertToIllusion;
}

// ── Air-Fire: Multiplier Cycles ───────────────────────────────────────────────

/// Caster's next spell effect of [targetElement] is amplified by [multiplier].
/// Potency: 2×→3×.
///
///   Fire affinity:  next Air effect ×2[3]
///   Earth affinity: next Fire effect ×2[3]
///   Water affinity: next Earth effect ×2[3]
///   Air affinity:   next Water effect ×2[3]
class MultiplierCyclesEffect extends SpellEffect {
  const MultiplierCyclesEffect({
    required this.targetElement,
    required this.multiplier,
  });

  /// Element whose next effect is amplified.
  final SpellAffinity targetElement;

  /// 2 normally, 3 under potency.
  final int multiplier;
}

// ── Air-Earth: Haymaker Interaction ──────────────────────────────────────────

/// Buffs the caster's haymaker for [durationTurns] (2/3 potent).
///
///   Fire affinity:  stacking fire DoT — each haymaker hit adds [doTStackIncrement]
///                   turns of burning; damage per tick = remaining DoT turns
///   Earth affinity: [slowsTarget]=true — each haymaker also imposes −1 move speed
///   Water affinity: [drainTargetStatus]=true — each haymaker strips 1 turn from
///                   all of the target's active status effects
///   Air affinity:   [distanceBonusDamage]=true — bonus damage = half the
///                   tiles actually traversed this turn (path length,
///                   including conveyor detours), rounded down
class HaymakerInteractionEffect extends SpellEffect {
  const HaymakerInteractionEffect({
    required this.affinity,
    required this.durationTurns,
    this.doTStackIncrement = 0,
    this.slowsTarget = false,
    this.drainTargetStatus = false,
    this.distanceBonusDamage = false,
  });

  final SpellAffinity affinity;
  final int durationTurns;

  /// Fire: turns of DoT added per haymaker hit (2 = two ticks of decrement dmg).
  final int doTStackIncrement;
  final bool slowsTarget;
  final bool drainTargetStatus;
  final bool distanceBonusDamage;
}

// ── Air-Water: Divination ─────────────────────────────────────────────────────

/// Reveals private information about the target. Potency extends duration.
///
///   Fire affinity:  [revealsCounterCharms]=true for rest of match;
///                   opponent's bookmarks targeting those spells turn red
///   Water affinity: see target's available spell list for [durationTurns] (2/3 potent)
///                   — [requiresOpponentReveal]=true; driven by
///                   `TurnLoop._exchangeSpellRevealOpenings` (spellRevealKey/
///                   spellRevealOpen), verified against the target's already-
///                   exchanged `peerBookRoot` — no separate hand/deck
///                   commitment needed since "available spells" is the
///                   target's whole chapter today (SpellDraw is unwired; see
///                   docs/OUTSTANDING_ITEMS.md)
///   Air affinity:   see target's committed spell target tile for [durationTurns]
///                   (2/3 potent) — [requiresOpponentReveal]=true; driven by
///                   `TurnLoop._exchangeScryOpenings` (scryKey/scryOpen)
///
class DivinationEffect extends SpellEffect {
  const DivinationEffect({
    required this.affinity,
    required this.durationTurns,
    this.revealsCounterCharms = false,
    this.requiresOpponentReveal = false,
  });

  final SpellAffinity affinity;

  /// 0 = rest-of-match (Fire affinity); otherwise turn count.
  final int durationTurns;

  final bool revealsCounterCharms;

  /// True for Water and Air: opponent's client must send hidden information.
  final bool requiresOpponentReveal;
}
