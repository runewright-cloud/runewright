// SPDX-License-Identifier: GPL-3.0-or-later
//
// draw_schedule.dart — DrawSchedule: the public, position-only half of a
// player's hand/deck state. REAL.
//
// SPELL_DRAW_WIRING_PLAN.md §2's structural insight: a chapter's Merkle root
// hides *contents*, but a draw is a permutation of *positions*, and positions
// are public (a function of public per-turn entropy + the public action log).
// So both clients can track — for BOTH players — which chapter positions are
// currently in-hand, drawn-and-gone, or withered, without either client ever
// learning the *other* player's card contents.
//
// DrawSchedule is exactly [SpellDraw]'s index arithmetic (see spell_draw.dart)
// factored out to operate on bare chapter positions (0 <= p < chapterSize)
// instead of SpellAssets, so TurnLoop can run it identically for both players.
// It adds one thing SpellDraw doesn't need: a withered-position set, for the
// FuelTransmutation wither/reactivate flavors (§9).
//
// SpellDraw is left untouched (it's small, fully tested, and owns *contents*
// for the local player only) — TurnLoop drives SpellDraw and DrawSchedule
// from two independently-constructed HashRng instances seeded with the same
// bytes, so a given draw always resolves to the same position in both,
// without either ever consuming the other's RNG state.

import 'hash_rng.dart';

/// Immutable snapshot of one player's hand/deck **positions** — no card
/// contents. Both clients compute this identically for both players.
class DrawSchedule {
  DrawSchedule._({
    required List<int> hand,
    required List<int> remaining,
    required Set<int> withered,
  })  : hand = List.unmodifiable(hand),
        remaining = List.unmodifiable(remaining),
        withered = Set.unmodifiable(withered);

  /// Deals the opening hand: draws up to [bookmarkCount] positions one at a
  /// time from `[0, chapterSize)` using [rng]. Mirrors [SpellDraw.opening]
  /// exactly (same rng.nextInt(pool.length) sequence over a same-size pool),
  /// so a DrawSchedule dealt from the same seed as a SpellDraw always agrees
  /// on which position sits in which hand slot.
  factory DrawSchedule.opening(int chapterSize, int bookmarkCount, HashRng rng) {
    assert(chapterSize > 0, 'chapter must have at least one spell');
    final pool = List<int>.generate(chapterSize, (i) => i);
    final handSize = bookmarkCount < pool.length ? bookmarkCount : pool.length;
    final hand = <int>[];
    for (var i = 0; i < handSize; i++) {
      hand.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return DrawSchedule._(hand: hand, remaining: pool, withered: const {});
  }

  /// Positions currently in hand, in draw order.
  final List<int> hand;

  /// Undrawn positions, in canonical (chapter) order.
  final List<int> remaining;

  /// Subset of [hand] currently withered (FuelTransmutation Fire, §9) —
  /// in-hand but not castable until reactivated.
  final Set<int> withered;

  bool get isDeckEmpty => remaining.isEmpty;

  bool isInHand(int position) => hand.contains(position);

  bool isWithered(int position) => withered.contains(position);

  /// A position is castable iff it's in-hand and not withered — the exact
  /// check SPELL_DRAW_WIRING_PLAN.md §6 enforces on every peer cast.
  bool isCastable(int position) => isInHand(position) && !withered.contains(position);

  /// Removes [position] from hand and refills the slot from [remaining]
  /// using [drawRng] — the position-only mirror of [SpellDraw.useSpell].
  /// [position] must currently be in hand (both the owning client, who
  /// chose it, and an observer, who learned it from the cast's authenticated
  /// Merkle leaf index, call this identically). Clears [position] from
  /// [withered] if it was set — a spell leaves withered-ness behind once cast.
  DrawSchedule useSlotAtPosition(int position, HashRng drawRng) {
    assert(hand.contains(position), 'position $position is not in hand');
    final newHand = List<int>.from(hand)..remove(position);
    final newWithered = Set<int>.from(withered)..remove(position);
    final newRemaining = List<int>.from(remaining);
    if (newRemaining.isNotEmpty) {
      final j = drawRng.nextInt(newRemaining.length);
      newHand.add(newRemaining.removeAt(j));
    }
    return DrawSchedule._(hand: newHand, remaining: newRemaining, withered: newWithered);
  }

  /// Marks each of [positions] withered, if currently in hand (silently
  /// ignores positions not in hand — mirrors the clamping style other
  /// EffectApplicator handlers use when a pool is smaller than requested).
  DrawSchedule witherPositions(Iterable<int> positions) {
    final newWithered = Set<int>.from(withered);
    for (final p in positions) {
      if (hand.contains(p)) newWithered.add(p);
    }
    return DrawSchedule._(hand: hand, remaining: remaining, withered: newWithered);
  }

  /// Clears the withered flag on each of [positions].
  DrawSchedule reactivatePositions(Iterable<int> positions) {
    final newWithered = Set<int>.from(withered)..removeAll(positions);
    return DrawSchedule._(hand: hand, remaining: remaining, withered: newWithered);
  }
}
