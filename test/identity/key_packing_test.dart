// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:test/test.dart';
import 'package:rune_duel/identity/key_packing.dart';

void main() {
  group('splitPubkeyToFieldHex', () {
    test('round-trips an arbitrary 32-byte key', () {
      final bytes = List<int>.generate(32, (i) => i);
      final split = splitPubkeyToFieldHex(bytes);
      expect(fieldHexToLeBytes(split.keyHiHex, 16), bytes.sublist(0, 16));
      expect(fieldHexToLeBytes(split.keyLoHex, 16), bytes.sublist(16, 32));
    });

    test('matches the M4 golden vector cross-checked against the real circuit '
        'via nargo execute (docs/M4_findings.md)', () {
      final bytes = List<int>.generate(32, (i) => i);
      final split = splitPubkeyToFieldHex(bytes);
      expect(split.keyHiHex, '0xf0e0d0c0b0a09080706050403020100');
      expect(split.keyLoHex, '0x1f1e1d1c1b1a19181716151413121110');
    });

    test('matches the M4 high-entropy golden vector cross-checked against the real '
        'circuit via nargo execute -- not a sequential pattern, exercises the full '
        'field width (docs/M4_findings.md)', () {
      final bytes = [
        30, 30, 127, 127, 175, 40, 221, 58, 138, 40, 240, 227, 175, 2, 149, 201, //
        236, 198, 73, 211, 168, 1, 246, 75, 35, 209, 90, 95, 166, 18, 39, 203,
      ];
      final split = splitPubkeyToFieldHex(bytes);
      expect(split.keyHiHex, '0xc99502afe3f0288a3add28af7f7f1e1e');
      expect(split.keyLoHex, '0xcb2712a65f5ad1234bf601a8d349c6ec');
    });

    test('all-zero key matches the known-good owner_pubkey witness value', () {
      final split = splitPubkeyToFieldHex(List<int>.filled(32, 0));
      expect(split.keyHiHex, '0x0');
      expect(split.keyLoHex, '0x0');
    });

    test('rejects a key that is not exactly 32 bytes', () {
      expect(() => splitPubkeyToFieldHex(List<int>.filled(31, 0)), throwsArgumentError);
      expect(() => splitPubkeyToFieldHex(List<int>.filled(33, 0)), throwsArgumentError);
    });
  });

  // Canonical identity ordering — the tie-break-free order two devices use to
  // serialize simultaneous deterministic effects. The free-move window
  // (turn_loop.dart's _runFreeMoveRound) is the first consumer; see
  // test/battle/engine/free_move_ordering_test.dart for the lockstep half.
  group('canonical pubkey ordering', () {
    test('canonicalPubkeyBytes is fixed-width big-endian', () {
      final bytes = canonicalPubkeyBytes('0x01');
      expect(bytes, hasLength(kCanonicalPubkeyByteWidth));
      expect(bytes.last, 1);
      expect(bytes.take(kCanonicalPubkeyByteWidth - 1), everyElement(0));
    });

    test('ignores 0x prefix, case, and leading zeros', () {
      final forms = ['0xAB', '0xab', 'ab', '0x00ab', '0x000000AB'];
      for (final form in forms) {
        expect(canonicalPubkeyBytes(form), canonicalPubkeyBytes('0xab'),
            reason: '$form must canonicalize to the same bytes');
        expect(compareCanonicalPubkeyHex(form, '0xab'), 0);
      }
    });

    // The reason this compares bytes rather than the hex string it is carried
    // in: key_packing's _leBytesToFieldHex emits toRadixString(16) with NO
    // zero padding, so a shorter string can hold the larger number. A textual
    // compare gets this pair backwards.
    test('orders by value, not by string — "0x2" sorts before "0x10"', () {
      expect(compareCanonicalPubkeyHex('0x2', '0x10'), lessThan(0));
      expect(compareCanonicalPubkeyHex('0x10', '0x2'), greaterThan(0));
      // ...which is the opposite of what comparing the text would say.
      expect('0x2'.compareTo('0x10'), greaterThan(0));
    });

    test('is antisymmetric and total over realistic owner_pubkey hexes', () {
      final keys = [
        '',
        '0x0',
        '0x${'0' * 64}',
        '0x11',
        '0x${'11' * 32}',
        '0x${'ff' * 32}',
      ];
      for (final a in keys) {
        for (final b in keys) {
          expect(compareCanonicalPubkeyHex(a, b).sign,
              -compareCanonicalPubkeyHex(b, a).sign,
              reason: 'compare($a, $b) must be the negation of compare($b, $a)');
        }
      }
      // The empty string (AuthenticatedPeer.none) and an all-zero key are the
      // same value: zero. Callers break that tie on playerId.
      expect(compareCanonicalPubkeyHex('', '0x${'0' * 64}'), 0);
    });

    test('a value wider than the default width still compares correctly', () {
      // 33 bytes: both sides widen to a common width rather than truncating.
      final wide = '0x${'ff' * 33}';
      expect(compareCanonicalPubkeyHex(wide, '0x${'ff' * 32}'), greaterThan(0));
      expect(compareCanonicalPubkeyHex('0x${'ff' * 32}', wide), lessThan(0));
    });
  });
}
