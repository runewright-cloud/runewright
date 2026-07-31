// SPDX-License-Identifier: GPL-3.0-or-later
//
// status_effect_ids.dart — Well-known StatusEffect.effectTypeId constants.
//
// All StatusEffect instances in the battle engine use one of these IDs.
// The ID determines how the effect is applied by EffectApplicator and how
// WizardAvatar's derived-stat getters interpret the modifiers map.
//
// Modifier keys used alongside each ID are documented inline.

abstract final class StatusEffectId {
  // ── Movement ──────────────────────────────────────────────────────────────
  // modifiers: {'speedDelta': ±int}
  static const speedUp = 'speedUp';
  static const speedDown = 'speedDown';

  // High-mobility: caster may spend HP for extra tiles during move selection.
  // modifiers: {'freeExtraTiles': int}   (0 or 1 under potency)
  // Sorcerer seam: pedometer rate scales with extra-tile count.
  static const highMobility = 'highMobility';

  // High-liquidity: same as highMobility but spends mana instead of HP.
  // modifiers: {'freeExtraTiles': int}
  static const highLiquidity = 'highLiquidity';

  // Flying (wild magic, Updraft — row 2 Air): the bearer ignores terrain
  // entirely while moving — ChasmTile, ImpassableTile, FloorIsLava, SlowTile's
  // extra cost and mana drain, IceTile sliding, and ConveyorTile pushes. Same
  // semantics as SummonAbility.flying / ignoresTerrain already carries for
  // spirit minions, and the `flying:` parameter resolveTileEntry already takes.
  // No modifiers.
  static const flying = 'flying';

  // ── Spell range ───────────────────────────────────────────────────────────
  // modifiers: {'rangeDelta': ±int}
  static const rangeUp = 'rangeUp';
  static const rangeDown = 'rangeDown';

  // Penetrating: spells ignore impassable tiles; deal damage to entities en route.
  // modifiers: {'penetrationDamage': int}
  static const penetrating = 'penetrating';

  // Turbulent: caster's next spell range randomised 1–max (range is still declared).
  static const turbulent = 'turbulent';

  // Cloud-bound targeting: same "adjacent-only" restriction a cloud imposes
  // while an entity stands in it, but lingering after they've left (Earth
  // flavor of Clouds / Water-Fire). No modifiers.
  static const cloudBoundTargeting = 'cloudBoundTargeting';

  // ── Resolution order ──────────────────────────────────────────────────────
  // Sluggish: affected player's spells resolve last each turn.
  static const sluggish = 'sluggish';
  // Quick: affected player's spells resolve first each turn.
  static const quick = 'quick';

  // Next spell cost is doubled; shortfall converts to HP damage.
  // modifiers: {'hpPerManaMissed': int, 'manaPerHp': int}
  static const nextSpellCostDouble = 'nextSpellCostDouble';

  // ── Perception ────────────────────────────────────────────────────────────
  // Blind: all map information beyond adjacent tiles is hidden.
  static const blind = 'blind';

  // ── Chain accumulation rate ───────────────────────────────────────────────
  // modifiers: {'chainAccMultiplierPct': int}  (200 = 2×, 50 = 0.5×)
  static const chainFast = 'chainFast';
  static const chainSlow = 'chainSlow';

  // Potent Air-flavor Chain Interaction: the next spell cast (any affinity,
  // whether or not it matches an active chain) is charged as if the chain
  // length were -1 (a ~11% surcharge), regardless of the target's actual
  // chain state (which the same effect clears to 0 on landing). Consumed on
  // that next cast; ordinary chain building resumes starting with it. No
  // modifiers -- the -1 length is fixed, mirrors nextSpellCostDouble's
  // consume-on-next-cast pattern.
  static const chainSurcharge = 'chainSurcharge';

  // ── Status meta ───────────────────────────────────────────────────────────
  // statusDormant: all other status effects on this avatar do not tick.
  static const statusDormant = 'statusDormant';

  // ── Haymaker buffs ────────────────────────────────────────────────────────
  // Fire haymaker: stacking DoT — each haymaker adds doTStackIncrement turns;
  //   damage on each tick = remainingTurns of the DoT.
  // modifiers: {'doTStackIncrement': int}
  static const haymakerDot = 'haymakerDot';

  // Earth haymaker: each haymaker hit imposes −1 move speed on the target.
  static const haymakerSlow = 'haymakerSlow';

  // Water haymaker: each haymaker causes the target's status effects to lose 1 turn.
  static const haymakerStatusDrain = 'haymakerStatusDrain';

  // Air haymaker: bonus damage equal to caster's tiles moved toward the target.
  static const haymakerDistanceBonus = 'haymakerDistanceBonus';

  // ── Divination ────────────────────────────────────────────────────────────
  // Fire: see opponent's counter charm commitment hashes (rest of match).
  static const revealCounterCharms = 'revealCounterCharms';
  // Water: see opponent's available spell list (requires protocol message).
  static const revealSpells = 'revealSpells';
  // Air: see opponent's committed spell target tile (requires protocol message).
  static const revealTargetTile = 'revealTargetTile';
}
