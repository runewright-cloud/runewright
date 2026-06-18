// scripts/find_mask_vector.dart — finds/verifies the neg_mask_abuse golden
// vector for GOLDEN_VECTORS.md §3: a grid that is quiet under the stepper for
// generations < T but produces border activity once more generations run.
// Run with: dart run scripts/find_mask_vector.dart
//
// This is the discovery + verification record for the active_cells/T/
// declared_override values in test_vectors/seeds.json's neg_mask_abuse entry.
// Re-run after any stepper change to confirm the vector still holds.

import 'dart:math';
import 'package:rune_duel/engine/ca_run.dart';
import 'package:rune_duel/engine/hex_grid.dart';

List<HexCoord> _buildFlatIndex(int radius) {
  final coords = <HexCoord>[];
  for (int q = -radius; q <= radius; q++) {
    final rMin = max(-radius, -q - radius);
    final rMax = min(radius, -q + radius);
    for (int r = rMin; r <= rMax; r++) {
      coords.add(HexCoord(q, r));
    }
  }
  return coords;
}

int _hexDist(int q, int r) => [q.abs(), r.abs(), (q + r).abs()].reduce(max);

void main() {
  final coords = _buildFlatIndex(12);
  final idxOf = <HexCoord, int>{};
  for (int i = 0; i < coords.length; i++) {
    idxOf[coords[i]] = i;
  }

  // Full ring-8: the maximal inscribable ring (hex distance == 8).
  final cells = coords
      .where((c) => _hexDist(c.q, c.r) == 8)
      .map((c) => idxOf[c]!)
      .toList()
    ..sort();

  final grid = List<int>.filled(469, 0);
  for (final i in cells) {
    grid[i] = 1;
  }

  final quiet = runStepper(grid, 3, 12);
  final leaked = runStepper(grid, 4, 12);

  print('active_cells (n=${cells.length}): $cells');
  print('T=3 (true, masked)  border_activations=${quiet.borderActivations}');
  print('T=4 (one gen later) border_activations=${leaked.borderActivations}');

  final ok = quiet.borderActivations.every((v) => v == 0) &&
      leaked.borderActivations.any((v) => v != 0);
  print(ok
      ? 'OK: quiet at T=3, active at T=4 - valid neg_mask_abuse shape.'
      : 'FAIL: vector no longer has the quiet-then-active shape.');
}
