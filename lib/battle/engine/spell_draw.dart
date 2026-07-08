// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_draw.dart — SpellDraw: deterministic, auditable spell hand. REAL.
//
// Populates a player's available spells from their Chapter via a seeded
// Fisher-Yates shuffle so both clients compute the same draw order from the
// same joint commit-reveal entropy — secret in advance, auditable after
// reveal.
//
// Algorithm (BATTLE_PROTOCOL.md §4):
//   rng      ← _HashRng(joint_entropy)         [hash-counter stream]
//   shuffled ← Fisher-Yates(chapter, rng)       [Knuth shuffle]
//   hand     ← shuffled[0 .. bookmarkCount-1]
//   deck     ← shuffled[bookmarkCount ..]
//
// _HashRng block i = SHA-256(joint_entropy ‖ BigEndian32(i)).
// Bytes are consumed sequentially across blocks. nextInt(max) uses power-of-2
// masking with rejection sampling so there is no modulo bias and the exact
// output is fully determined by the entropy bytes alone, independent of any
// Dart SDK or VM internals.
//
// On spell use: the vacated hand slot is filled from the front of the
// remaining deck (the shuffle order is fixed at construction; no new
// randomness is needed for retargeting). This preserves auditability:
// given the entropy and the initial chapter list, any observer can replay
// the full draw sequence.
//
// Chapter spells must be in **canonical order** (sorted by spellId) before
// calling the constructor so both clients compute the same shuffle.

import 'dart:typed_data';

import 'package:rune_duel/spells/spell_asset.dart';

import 'hash_rng.dart';

// ── Fisher-Yates shuffle ──────────────────────────────────────────────────────

List<T> _fisherYates<T>(List<T> items, HashRng rng) {
  final result = List<T>.from(items);
  for (var i = result.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = result[i];
    result[i] = result[j];
    result[j] = tmp;
  }
  return result;
}

// ── SpellDraw ─────────────────────────────────────────────────────────────────

/// Immutable snapshot of a player's draw state: current hand + remaining deck.
///
/// All mutations return a new [SpellDraw]; the original is unchanged — safe
/// to store in [BattleState] and replay for audit.
class SpellDraw {
  SpellDraw._({
    required List<SpellAsset> hand,
    required List<SpellAsset> remaining,
  })  : hand = List.unmodifiable(hand),
        remaining = List.unmodifiable(remaining);

  /// Initialise from a chapter (must already be in canonical order) and
  /// 32-byte joint commit-reveal entropy.
  factory SpellDraw(
    List<SpellAsset> chapter,
    int bookmarkCount,
    Uint8List jointEntropy,
  ) {
    assert(chapter.isNotEmpty, 'chapter must have at least one spell');
    final rng = HashRng(jointEntropy);
    final shuffled = _fisherYates(chapter, rng);
    final handSize = bookmarkCount < shuffled.length ? bookmarkCount : shuffled.length;
    return SpellDraw._(
      hand: shuffled.sublist(0, handSize),
      remaining: shuffled.sublist(handSize),
    );
  }

  /// The current hand (at most [bookmarkCount] spells).
  final List<SpellAsset> hand;

  /// Spells not yet drawn, in their shuffled order.
  final List<SpellAsset> remaining;

  bool get isDeckEmpty => remaining.isEmpty;

  /// Returns a new [SpellDraw] after using the spell at [handIndex].
  ///
  /// The used slot is refilled from the front of [remaining]. If the deck is
  /// empty, the hand shrinks by one.
  SpellDraw useSpell(int handIndex) {
    assert(handIndex >= 0 && handIndex < hand.length);
    final newHand = List<SpellAsset>.from(hand)..removeAt(handIndex);
    final newRemaining = List<SpellAsset>.from(remaining);
    if (newRemaining.isNotEmpty) {
      newHand.add(newRemaining.removeAt(0));
    }
    return SpellDraw._(hand: newHand, remaining: newRemaining);
  }
}
