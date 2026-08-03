// SPDX-License-Identifier: GPL-3.0-or-later
//
// barrier.dart — BarrierState: per-element body-armor buffer on WizardAvatar.
//
// Barriers travel with the avatar and absorb incoming damage from any source
// before the avatar's real HP is touched. Each element has at most one barrier
// at a time; receiving a new barrier of the same element resets its HP to the
// new maximum (not additive) rather than stacking.
//
// Both HP and duration gate expiry: whichever runs out first collapses the
// barrier. Fire's aura tick lives in TurnLoop._endOfTurn. Air's free-move
// grant has two separate paths: a damage-caused collapse ("burst") sets
// WizardAvatar.pendingFreeMoveBurst in absorbDamage, consumed once per turn
// by TurnLoop's post-resolution free-move phase (right after Phase 5, before
// Phase 6); a duration-expiry collapse is flagged by WizardAvatar.tickBarriers
// but that signal is not yet wired to anything (see the TODO at its call site
// in TurnLoop._endOfTurn) — out of scope until playtesting asks for it.
//
// Barrier HP is drained in element order (fire → earth → water → air) when
// multiple elements are simultaneously active. The remainder after all barriers
// are exhausted flows to the avatar's real HP.
//
// Flavor summary (affinity of the Earth-Earth formula's first triplet entry):
//   Fire:  HP 2; fire aura — 1 fire damage/turn to all adjacent entities
//   Earth: HP 4; no special
//   Water: HP 2; +10% mana regen per turn while active
//   Air:   HP 2; grants one free extra movement when this barrier collapses

import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;

class BarrierState {
  BarrierState({
    required this.element,
    required this.hp,
    required this.maxHp,
    required this.remainingTurns,
    this.fireAura = false,
    this.manaRegenBonusPct = 0,
    this.freeMoveOnCollapse = false,
  });

  final SpellAffinity element;

  int hp;

  /// Used when a replacement barrier of the same element resets to full.
  final int maxHp;

  int remainingTurns;

  /// Fire affinity: deal 1 fire damage per turn to all entities occupying
  /// tiles adjacent to this barrier's avatar.
  final bool fireAura;

  /// Water affinity: while active, add manaRegenBonusPct% of max mana to
  /// the avatar's per-turn mana regeneration.
  final int manaRegenBonusPct;

  /// Air affinity: when this barrier collapses (from damage or expiry), grant
  /// the avatar one free extra movement outside the normal move turn.
  final bool freeMoveOnCollapse;

  bool get isAlive => hp > 0 && remainingTurns > 0;

  /// Absorb up to [damage] HP. Returns any overflow that should propagate
  /// to the next barrier or to the avatar's real HP pool.
  int absorb(int damage) {
    if (damage >= hp) {
      final overflow = damage - hp;
      hp = 0;
      return overflow;
    }
    hp -= damage;
    return 0;
  }

  /// Tick end-of-turn duration. Returns true if still alive after this tick.
  bool tick() {
    if (remainingTurns > 0) remainingTurns--;
    return isAlive;
  }
}
