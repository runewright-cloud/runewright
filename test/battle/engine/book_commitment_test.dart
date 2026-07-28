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

  group('proveMembershipAt', () {
    test('matches proveMembership exactly when there are no duplicate leaves', () {
      final hexes = List.generate(7, (i) => '0x${i.toRadixString(16).padLeft(64, '0')}');
      final root = BookCommitment.computeRoot(hexes);
      final sorted = List<String>.from(hexes)..sort();
      for (var idx = 0; idx < sorted.length; idx++) {
        final byPosition = BookCommitment.proveMembershipAt(hexes, idx)!;
        final byHex = BookCommitment.proveMembership(hexes, sorted[idx])!;
        expect(byPosition.leafHex, equals(byHex.leafHex));
        expect(byPosition.siblings, equals(byHex.siblings));
        expect(byPosition.directions, equals(byHex.directions));
        expect(byPosition.root, equals(root));
        expect(byPosition.verify(), isTrue);
      }
    });

    test('out-of-range index returns null', () {
      final hexes = List.generate(4, (i) => '0x${i.toRadixString(16).padLeft(64, '0')}');
      expect(BookCommitment.proveMembershipAt(hexes, -1), isNull);
      expect(BookCommitment.proveMembershipAt(hexes, hexes.length), isNull);
    });

    test(
      'duplicate leaves (docs/BASIC_SPELLS_PLAN.md §7): each occurrence gets its own '
      'leafIndex and verifies against the shared root, unlike proveMembership which '
      'always collapses onto the first occurrence',
      () {
        // Three copies of one Basic spell's commitment, sorted adjacent to
        // each other by construction (equal strings sort together).
        final dup = '0xaa'.padRight(66, '0');
        final hexes = [
          '0x01'.padRight(66, '0'),
          dup,
          dup,
          dup,
          '0xff'.padRight(66, '0'),
        ];
        final root = BookCommitment.computeRoot(hexes);
        final sorted = List<String>.from(hexes)..sort();
        final dupIndices = [
          for (var i = 0; i < sorted.length; i++)
            if (sorted[i] == dup) i,
        ];
        expect(dupIndices.length, 3, reason: 'sanity: 3 copies present in the sorted list');

        // proveMembership can only ever prove the FIRST duplicate occurrence.
        final byHex = BookCommitment.proveMembership(hexes, dup)!;
        expect(byHex.leafIndex, equals(dupIndices.first));

        // proveMembershipAt proves each occurrence independently — this is
        // what a duplicate-safe cast (identified by hand SLOT, not by
        // commitment) needs.
        final proofs = dupIndices
            .map((idx) => BookCommitment.proveMembershipAt(hexes, idx)!)
            .toList();
        for (var i = 0; i < proofs.length; i++) {
          expect(proofs[i].leafIndex, equals(dupIndices[i]));
          expect(proofs[i].root, equals(root));
          expect(proofs[i].verify(), isTrue);
        }
        // Distinct positions, even though the leaf VALUE is identical.
        expect(proofs.map((p) => p.leafIndex).toSet().length, 3);
      },
    );
  });
}
