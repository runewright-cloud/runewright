// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_draw.dart — SpellDraw: deterministic, auditable spell hand. REAL.
//
// Draw-on-demand. SpellDraw never owns a seed: the opening hand is dealt from
// an injected HashRng (seeded from battle-start joint entropy), and each
// later refill draw takes its own injected HashRng, which the caller must
// seed from the entropy of the turn (or tick) that reveals that draw.
// See docs/SPELL_DRAW_ENTROPY_PLAN.md.
//
// Why not "shuffle the whole chapter once, walk forward" (the prior design):
// a player always knows their own chapter, so shuffling it all from one seed
// at construction lets them compute their entire future draw order the
// instant that seed is revealed. Injecting a fresh RNG per draw bounds
// foreknowledge to "one draw ahead" — same as a physically shuffled deck —
// while staying fully replayable/auditable from the recorded sequence of
// per-draw entropy (every joint-entropy value used is revealed as part of
// the existing per-turn commit-reveal protocol).
//
// [remaining] is held in **canonical order** (sorted by commitmentHex — the
// same key BookCommitment's Merkle tree sorts leaves by, see chapter.dart),
// never pre-shuffled, so both clients agree on which index a given draw value
// selects, and a drawn position lines up with a Merkle leaf index (see
// docs/SPELL_DRAW_WIRING_PLAN.md §2). Draws only ever remove elements; the
// only way an element re-enters [remaining] is [removeSlot] (a bookmark
// accoutrement destroyed mid-battle, TurnLoop._reconcileHandSize), which
// reinserts at the sorted position — so [remaining] always stays in
// canonical order, whether shrinking or regrowing.
//
// Chapter spells must be in canonical order before calling [SpellDraw.opening]
// so both clients compute the same opening hand.

import 'package:rune_duel/spells/spell_asset.dart';

import 'hash_rng.dart';

// ── SpellDraw ─────────────────────────────────────────────────────────────────

/// Immutable snapshot of a player's draw state: current hand + remaining pool.
///
/// All mutations return a new [SpellDraw]; the original is unchanged — safe
/// to store in [BattleState] and replay for audit.
class SpellDraw {
  SpellDraw._({
    required List<SpellAsset> hand,
    required List<SpellAsset> remaining,
  })  : hand = List.unmodifiable(hand),
        remaining = List.unmodifiable(remaining);

  /// Deals the opening hand: draws up to [handSize] spells one at a time
  /// from [chapter] (must already be in canonical order) using [rng].
  ///
  /// The opening hand is dealt once, at battle start, from the initial joint
  /// entropy — it is legitimately knowable to its owner the moment it's
  /// dealt. Only *later* refills need fresh, turn/tick-scoped entropy (see
  /// [useSpell]).
  factory SpellDraw.opening(
    List<SpellAsset> chapter,
    int handSize,
    HashRng rng,
  ) {
    assert(chapter.isNotEmpty, 'chapter must have at least one spell');
    final pool = List<SpellAsset>.from(chapter);
    final dealSize = handSize < pool.length ? handSize : pool.length;
    final hand = <SpellAsset>[];
    for (var i = 0; i < dealSize; i++) {
      hand.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return SpellDraw._(hand: hand, remaining: pool);
  }

  /// The current hand (at most bookmarkCount + 1 spells — see
  /// TurnLoop._dealOpeningHandsIfNeeded / _reconcileHandSize).
  final List<SpellAsset> hand;

  /// Spells not yet drawn, in canonical order.
  final List<SpellAsset> remaining;

  bool get isDeckEmpty => remaining.isEmpty;

  /// Returns a new [SpellDraw] after using the spell at [handIndex].
  ///
  /// The used slot is refilled with a fresh draw from [remaining], seeded by
  /// [drawRng] — the caller must derive this from the entropy of the turn (or
  /// tick) that reveals this draw, never from a value known in advance of
  /// that reveal. If the pool is empty, the hand shrinks by one instead.
  SpellDraw useSpell(int handIndex, HashRng drawRng) {
    assert(handIndex >= 0 && handIndex < hand.length);
    final newHand = List<SpellAsset>.from(hand)..removeAt(handIndex);
    final newRemaining = List<SpellAsset>.from(remaining);
    if (newRemaining.isNotEmpty) {
      final j = drawRng.nextInt(newRemaining.length);
      newHand.add(newRemaining.removeAt(j));
    }
    return SpellDraw._(hand: newHand, remaining: newRemaining);
  }

  /// Adds a hand slot, drawing a fresh spell from [remaining] via [rng] —
  /// a bookmark accoutrement gained mid-battle (TurnLoop._reconcileHandSize).
  /// No-op if [remaining] is empty (every chapter spell is already in hand).
  SpellDraw addSlot(HashRng rng) {
    if (remaining.isEmpty) return this;
    final newRemaining = List<SpellAsset>.from(remaining);
    final newHand = List<SpellAsset>.from(hand)
      ..add(newRemaining.removeAt(rng.nextInt(newRemaining.length)));
    return SpellDraw._(hand: newHand, remaining: newRemaining);
  }

  /// Removes the hand slot at [handIndex], reinserting its spell back into
  /// [remaining] in canonical (commitmentHex) order — the reverse of a draw.
  /// A bookmark accoutrement lost mid-battle (TurnLoop._reconcileHandSize).
  SpellDraw removeSlot(int handIndex) {
    assert(handIndex >= 0 && handIndex < hand.length);
    final newHand = List<SpellAsset>.from(hand);
    final removed = newHand.removeAt(handIndex);
    final newRemaining = List<SpellAsset>.from(remaining);
    var i = 0;
    while (i < newRemaining.length &&
        newRemaining[i].commitmentHex.compareTo(removed.commitmentHex) < 0) {
      i++;
    }
    newRemaining.insert(i, removed);
    return SpellDraw._(hand: newHand, remaining: newRemaining);
  }

  /// Returns the ENTIRE hand to [remaining] in canonical order, then draws a
  /// fresh hand of [handSize] — wild magic's Scattered Gusts (row 3, Air):
  /// "all their bookmarks are blown out of place and they randomly find a new
  /// set of spells to mark."
  ///
  /// Reuses [removeSlot]'s sorted-insertion so [remaining] stays in canonical
  /// order throughout (that sortedness is load-bearing — see this file's
  /// header), and draws with the same one-at-a-time `removeAt(rng.nextInt(n))`
  /// pattern [SpellDraw.opening] uses, so [DrawSchedule.redrawHand] driven
  /// from the same seed picks the same positions.
  SpellDraw redrawHand(int handSize, HashRng rng) {
    var pool = this;
    while (pool.hand.isNotEmpty) {
      pool = pool.removeSlot(0);
    }
    final remainingPool = List<SpellAsset>.from(pool.remaining);
    final dealSize = handSize < remainingPool.length ? handSize : remainingPool.length;
    final newHand = <SpellAsset>[];
    for (var i = 0; i < dealSize; i++) {
      newHand.add(remainingPool.removeAt(rng.nextInt(remainingPool.length)));
    }
    return SpellDraw._(hand: newHand, remaining: remainingPool);
  }
}
