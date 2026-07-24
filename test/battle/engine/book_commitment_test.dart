// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';

void main() {
  group('MembershipProof.leafIndex', () {
    test('recovers the correct sorted index for every leaf, power-of-two size', () {
      final hexes = List.generate(8, (i) => '0x${i.toRadixString(16).padLeft(64, '0')}');
      final root = BookCommitment.computeRoot(hexes);
      for (var i = 0; i < hexes.length; i++) {
        final proof = BookCommitment.proveMembership(hexes, hexes[i])!;
        expect(proof.leafIndex, equals(i), reason: 'leaf $i');
        expect(proof.root, equals(root));
        expect(proof.verify(), isTrue);
      }
    });

    test('recovers the correct sorted index for every leaf, non-power-of-two size', () {
      final hexes = List.generate(5, (i) => '0x${i.toRadixString(16).padLeft(64, '0')}');
      for (var i = 0; i < hexes.length; i++) {
        final proof = BookCommitment.proveMembership(hexes, hexes[i])!;
        expect(proof.leafIndex, equals(i), reason: 'leaf $i');
        expect(proof.verify(), isTrue);
      }
    });

    test('single-spell chapter: leaf index is 0', () {
      final hexes = ['0x${'aa'.padLeft(64, '0')}'];
      final proof = BookCommitment.proveMembership(hexes, hexes[0])!;
      expect(proof.leafIndex, equals(0));
      expect(proof.directions, isEmpty);
    });

    test('leaf index is stable regardless of the caller-supplied (unsorted) input order', () {
      final sorted = List.generate(6, (i) => '0x${i.toRadixString(16).padLeft(64, '0')}');
      final shuffled = [sorted[3], sorted[0], sorted[5], sorted[1], sorted[4], sorted[2]];
      for (var i = 0; i < sorted.length; i++) {
        final proof = BookCommitment.proveMembership(shuffled, sorted[i])!;
        expect(proof.leafIndex, equals(i));
      }
    });
  });
}
