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
// Velocity: spell range +2. No engine-side range enforcement exists to hook
//   this into yet (see turn_loop.dart/battle_screen.dart) — the flag is wired
//   everywhere but currently has no mechanical effect; tracked as a follow-up.
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

import 'dart:math' show pow;

import '../../sorcerer/vocal_score.dart';

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

  /// Air loadout enhancement — spell range +2.
  final bool isVelocity;

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

  // ── Sorcerer mode seam ──────────────────────────────────────────────────────
  //
  // Curve constants — playtest-tunable. Forgiving defaults: a hexagonal-room,
  // mid-volume, roughly-on-target attempt should clear qMin; only near-silence
  // or a wildly wrong word should fizzle.

  /// Quality at/above which the loadout enhancement is fully active and mana
  /// cost is unpenalised.
  static const double qMin = 0.55;

  /// Quality below which the cast fizzles outright (no effect, mana still spent).
  static const double qFizzle = 0.20;

  /// Ease-in exponent for the [qFizzle, qMin) penalty ramp: penalty
  /// accelerates as quality drops toward qFizzle rather than scaling linearly.
  static const double rampExponent = 2.2;

  /// Derive enhancements from a per-cast [VocalScore].
  ///
  /// Reads only [VocalScore.pronunciationU8]/[VocalScore.volumeU8] — the
  /// wire-quantised values — never the raw doubles. This is what keeps the
  /// result identical on the casting device (which has the raw score, before
  /// it's ever put on the wire) and the peer device (which only ever sees the
  /// wire-decoded score): both snap to the same u8 grid before the curve runs.
  ///
  /// [hasPotentLoadout]/[hasVelocityLoadout]/[hasEfficiencyLoadout] gate
  /// which loadout enhancement (if any) the caster is even eligible for;
  /// [VocalScore] quality then gates whether that eligibility is actually
  /// realised this cast.
  ///
  // TODO(sorcerer): combine seam — pronunciation and volume are weighted
  //   equally (simple mean) for now. Weighting them differently is a later,
  //   playtest-driven decision.
  // TODO(sorcerer): somatic score is not yet folded into Q (somatic capture
  //   doesn't exist this pass — see vocal_score.dart's 0xFF sentinel).
  static CastingEnhancements fromSorcererQuality({
    required VocalScore vocalScore,
    required bool hasPotentLoadout,
    required bool hasVelocityLoadout,
    required bool hasEfficiencyLoadout,
  }) {
    final q = (vocalScore.pronunciationU8 + vocalScore.volumeU8) / (2 * 254.0);

    if (q < qFizzle) {
      return const CastingEnhancements(
        gameMode: GameMode.sorcerer,
        fizzle: true,
        enhancementEnabled: false,
        manaCostMultiplier: 1.50,
      );
    }

    if (q < qMin) {
      // t: 0 at the qMin edge (best in this bracket) → 1 at the qFizzle edge
      // (worst before fizzling). Raising t to rampExponent (>1) makes the
      // penalty grow slowly near qMin and accelerate near qFizzle (ease-in).
      final t = (qMin - q) / (qMin - qFizzle);
      final eased = pow(t, rampExponent).toDouble();
      final multiplier = 1.01 + eased * (1.50 - 1.01);
      return CastingEnhancements(
        gameMode: GameMode.sorcerer,
        enhancementEnabled: false,
        manaCostMultiplier: multiplier,
      );
    }

    return CastingEnhancements(
      gameMode: GameMode.sorcerer,
      enhancementEnabled: true,
      isPotent: hasPotentLoadout,
      isVelocity: hasVelocityLoadout,
      isEfficiency: hasEfficiencyLoadout,
      manaCostMultiplier: 1.0,
    );
  }

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
