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
// docs/SPELL_DRAW_WIRING_PLAN.md §2). Because draws only ever remove elements
// (never reorder them), the untouched remainder always stays in that
// canonical order.
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

  /// Deals the opening hand: draws up to [bookmarkCount] spells one at a time
  /// from [chapter] (must already be in canonical order) using [rng].
  ///
  /// The opening hand is dealt once, at battle start, from the initial joint
  /// entropy — it is legitimately knowable to its owner the moment it's
  /// dealt. Only *later* refills need fresh, turn/tick-scoped entropy (see
  /// [useSpell]).
  factory SpellDraw.opening(
    List<SpellAsset> chapter,
    int bookmarkCount,
    HashRng rng,
  ) {
    assert(chapter.isNotEmpty, 'chapter must have at least one spell');
    final pool = List<SpellAsset>.from(chapter);
    final handSize = bookmarkCount < pool.length ? bookmarkCount : pool.length;
    final hand = <SpellAsset>[];
    for (var i = 0; i < handSize; i++) {
      hand.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return SpellDraw._(hand: hand, remaining: pool);
  }

  /// The current hand (at most [bookmarkCount] spells).
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
}
