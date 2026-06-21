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
}
