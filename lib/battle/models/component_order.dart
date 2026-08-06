// SPDX-License-Identifier: GPL-3.0-or-later
//
// component_order.dart — who performs their spell components first, and in
// what order the rest follow. See docs/SPELL_COMPONENTS_PLAN.md §5.2.
//
// Two things are derived here, and both must land identically on every device
// or the sequential gate deadlocks (one client waiting on a player the other
// client thinks has already gone):
//
//   1. The SEATING — players ordered clockwise around the battlefield by the
//      vertex they SPAWNED on. Starting positions, never current ones: the
//      seating must not shuffle as wizards walk around.
//   2. The ROTATION — which seat leads on a given turn. Chosen at battle start
//      from the joint commit-reveal entropy (so neither device picks it), then
//      advanced by one seat every turn.
//
// Both are pure functions of values both devices already agree on, so no
// exchange is needed to establish either.

import 'dart:typed_data';

import 'package:rune_duel/engine/hex_grid.dart';

/// Battlefield vertices in visual clockwise order, for a field of [radius].
///
/// Transcribed from [Battlefield.spawnPositions]' own vertex table — that
/// method's comment ("Vertices in visual clockwise order") is the source of
/// truth for this ordering, and the two lists must stay identical. Kept as a
/// separate function rather than exported from there because spawn assignment
/// and seating are different questions: `spawnPositions` returns vertices in
/// PLAYER-COUNT order (e.g. 4 players sit on opposite pairs), which is not
/// clockwise at all.
List<HexCoord> clockwiseVertices(int radius) => [
      HexCoord(0, -radius), // top
      HexCoord(radius, -radius), // upper-right
      HexCoord(radius, 0), // lower-right
      HexCoord(0, radius), // bottom
      HexCoord(-radius, radius), // lower-left
      HexCoord(-radius, 0), // upper-left
    ];

/// Orders [playerIds] clockwise around the field by their [startPositions].
///
/// [startPositions] must be indexed to match [playerIds] — the spawn each
/// player was assigned at setup, before anyone moved.
///
/// A player whose start position is not a vertex (there is no such case in the
/// shipped setup builders, but a test fixture or a future asymmetric map could
/// produce one) sorts after every seated player, in playerId order, so the
/// result is still total and still identical on both devices.
List<String> clockwiseComponentOrder({
  required List<String> playerIds,
  required List<HexCoord> startPositions,
  required int radius,
}) {
  assert(playerIds.length == startPositions.length);
  final vertices = clockwiseVertices(radius);
  final seats = <({String id, int seat})>[
    for (var i = 0; i < playerIds.length; i++)
      (
        id: playerIds[i],
        seat: () {
          final idx = vertices.indexOf(startPositions[i]);
          return idx < 0 ? vertices.length : idx;
        }(),
      ),
  ]..sort((a, b) {
      final bySeat = a.seat.compareTo(b.seat);
      return bySeat != 0 ? bySeat : a.id.compareTo(b.id);
    });
  return [for (final s in seats) s.id];
}

/// Which seat leads on the first turn, derived from the battle-start joint
/// entropy so that neither device chooses it unilaterally.
///
/// Folds the whole entropy buffer rather than reading one byte: the joint
/// entropy is the XOR/hash of both sides' reveals, and using a single byte of
/// it would let a peer who grinds their own nonce bias the draw far more
/// cheaply than grinding the whole digest.
int componentStartSeat(Uint8List jointEntropy, int playerCount) {
  if (playerCount <= 1) return 0;
  var acc = 0;
  for (final b in jointEntropy) {
    acc = (acc * 31 + b) & 0x1FFFFFFF;
  }
  return acc % playerCount;
}

/// The full performing order for [turnNumber] (1-based), leading seat first.
///
/// The lead advances by exactly one seat per turn — whoever performed second
/// on turn 1 leads turn 2, and so on around the table. Everyone therefore
/// spends the same number of turns holding the informational short straw of
/// going first.
List<String> componentOrderForTurn({
  required List<String> seating,
  required int startSeat,
  required int turnNumber,
}) {
  if (seating.isEmpty) return const [];
  final n = seating.length;
  final lead = (startSeat + turnNumber - 1) % n;
  return [for (var i = 0; i < n; i++) seating[(lead + i) % n]];
}

/// Where [playerId] sits in [turnNumber]'s performing order, or -1 if they
/// are not in it (a spectator, or a state built before seating existed).
int componentSlotOf({
  required List<String> seating,
  required int startSeat,
  required int turnNumber,
  required String playerId,
}) =>
    componentOrderForTurn(
      seating: seating,
      startSeat: startSeat,
      turnNumber: turnNumber,
    ).indexOf(playerId);
