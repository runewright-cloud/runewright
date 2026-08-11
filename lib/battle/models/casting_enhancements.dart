// SPDX-License-Identifier: GPL-3.0-or-later
//
// casting_enhancements.dart — CastingEnhancements and GameMode.
//
// Enhancements come from two sources:
//   1. Cast-time choice: the player picks one of Fire=Potency, Air=Velocity,
//      Water=Efficiency, or Earth=Mystery (routed separately via
//      MysterySpellCastAction) at the moment they cast, gated by whether that
//      spell achieved supreme dominance in the matching zone
//      (SpellAsset.supremeTags). See battle_screen.dart's enhancement picker.
//   2. Sorcerer-mode per-cast somatic/vocal quality scores — the seam lives
//      here; somatic implementation is deferred until gesture capture is
//      built (see lib/sorcerer/gesture.dart), vocal is implemented via
//      fromSorcererQuality below.
//
// Potency:  bracketed values in the effect table become active.
// Velocity: spell range +2 (CastingEnhancements.velocityRangeBonus), applied
//   to `castRange` in TurnLoop._resolveActions' SpellCastAction branch, and
//   mirrored by battle_screen._maxCastRange for the UI's own targeting gate
//   and range highlight.
// Efficiency: mana cost −1/3 (applied in _spellManaCost/_certifiedManaCost in
//   turn_loop.dart, not here).
//
// In sorcerer mode the vocal quality score (and eventually somatic) modifies
// which enhancements are active and scales the mana cost multiplier. High
// quality turns on the loadout enhancement; poor quality raises the cost
// multiplier on an accelerating curve; very poor quality fizzles the cast
// entirely. See fromSorcererQuality() below.
//
// Sorcerer seam: forced-movement effects (conveyor, knockback, high-mobility
// extra tiles) in real-time mode display an on-screen indicator and affect
// pedometer tile-transition rate rather than applying discrete tile jumps.
// Each affected SpellEffect is annotated with a TODO(sorcerer) comment.


enum GameMode { wizard, sorcerer }

class CastingEnhancements {
  const CastingEnhancements({
    this.isPotent = false,
    this.isVelocity = false,
    this.isEfficiency = false,
    this.manaCostMultiplier = 1.0,
    this.gameMode = GameMode.wizard,
    this.enhancementEnabled = true,
    this.fizzle = false,
  });

  /// Fire loadout enhancement — use bracketed values in the effect table.
  final bool isPotent;

  /// Air loadout enhancement — spell range +[velocityRangeBonus].
  final bool isVelocity;

  /// Tiles added to spell range when [isVelocity] is active. Shared constant
  /// so TurnLoop's engine-side enforcement and battle_screen's UI gate can't
  /// drift apart on the magnitude.
  static const int velocityRangeBonus = 2;

  /// Water loadout enhancement — mana cost −1/3, applied in
  /// TurnLoop._spellManaCost/_certifiedManaCost.
  final bool isEfficiency;

  /// Mana cost factor from somatic/vocal quality (sorcerer mode only).
  /// 1.0 = normal; >1.0 = poor casting (more expensive); <1.0 = exceptional.
  final double manaCostMultiplier;

  final GameMode gameMode;

  /// Sorcerer mode only: whether the loadout enhancement ([isPotent] /
  /// [isVelocity]) is actually active this cast. Always true in wizard mode.
  /// Kept distinct from [isPotent]/[isVelocity] so the curve's gating
  /// decision is visible even when the caster has no matching loadout.
  final bool enhancementEnabled;

  /// Sorcerer mode only: vocal quality was below [qFizzle] — the spell fails
  /// entirely (no effect applied). Mana is still spent; see
  /// EffectResolver/TurnLoop._resolveActions for how callers must check this
  /// before applying a spell's effects.
  final bool fizzle;

  // ── Sorcerer mode seam ────────────────────────────────────────────────────
  //
  // RETIRED (VOCAL_RECALL_PLAN.md §3/§4): fromSorcererQuality() and its curve
  // constants (qMin/qFizzle/rampExponent/maxManaCostMultiplier) are gone.
  //
  // They scored PRONUNCIATION QUALITY, which the receiving device can never
  // recheck — it has no access to the caster's microphone — so the whole curve
  // ran on a number the peer had to take on trust. The verbal component now
  // measures trajectory RECALL, which the peer recomputes from the certified
  // trajectory; the multiplier is applied in TurnLoop's mana chain by
  // IncantationRecall, in exact integers, and never appears here.
  //
  // Two consequences worth stating, because both removed machinery:
  //   - Recall NEVER gates the loadout enhancement. Getting words wrong costs
  //     mana, full stop (§4), so [enhancementEnabled] no longer varies with
  //     how well the caster spoke.
  //   - Recall NEVER fizzles a cast. [fizzle] now means one thing only: the
  //     cost outran the caster's pool, in which case the mana is REFUNDED and
  //     the turn is spent (TurnLoop._fizzlesForMana).
  //
  // maxManaCostMultiplier existed purely so previewSpellCost could quote a
  // worst case and guarantee a bad incantation never turned an affordable
  // spell into a peer-side forfeit. Fizzle-with-refund makes a shortfall
  // legal, which retires that guarantee's only purpose.

  CastingEnhancements copyWith({
    bool? isPotent,
    bool? isVelocity,
    bool? isEfficiency,
    double? manaCostMultiplier,
    GameMode? gameMode,
    bool? enhancementEnabled,
    bool? fizzle,
  }) =>
      CastingEnhancements(
        isPotent: isPotent ?? this.isPotent,
        isVelocity: isVelocity ?? this.isVelocity,
        isEfficiency: isEfficiency ?? this.isEfficiency,
        manaCostMultiplier: manaCostMultiplier ?? this.manaCostMultiplier,
        gameMode: gameMode ?? this.gameMode,
        enhancementEnabled: enhancementEnabled ?? this.enhancementEnabled,
        fizzle: fizzle ?? this.fizzle,
      );
}
