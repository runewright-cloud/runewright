// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:rune_duel/identity/seed_derivation.dart';

void main() {
  group('encodeRolls', () {
    test('encodes 24 rolls as one byte each, in order', () {
      final rolls = List.generate(24, (i) => (i % 20) + 1);
      expect(encodeRolls(rolls), equals(rolls));
    });

    test('rejects a roll count other than 24', () {
      expect(() => encodeRolls(List.filled(23, 1)), throwsA(isA<InvalidRollsException>()));
      expect(() => encodeRolls(List.filled(25, 1)), throwsA(isA<InvalidRollsException>()));
    });

    test('rejects out-of-range d20 values', () {
      final rolls = List.generate(24, (_) => 1)..[0] = 0;
      expect(() => encodeRolls(rolls), throwsA(isA<InvalidRollsException>()));
      final rolls2 = List.generate(24, (_) => 1)..[0] = 21;
      expect(() => encodeRolls(rolls2), throwsA(isA<InvalidRollsException>()));
    });
  });

  group('deriveSeedFromRolls', () {
    // Pinned golden vector -- independently computed as
    // SHA-512(utf8(kSeedDerivationDomainTag) ++ bytes(rolls))[0:32].
    // Regenerating this requires updating every prior Rite-of-Four-and-
    // Twenty key derived under the old vector, so treat a mismatch here as
    // a derivation regression, not a vector to "fix".
    final goldenRolls = List.generate(24, (i) => (i % 20) + 1); // 1..20,1,2,3,4
    const goldenSeedHex = '2b943c61b1876c67958bc9b6908ac8a228402722fe5f0ddeee7caa2849c76fac';

    test('matches the pinned golden vector', () async {
      final seed = await deriveSeedFromRolls(goldenRolls);
      expect(hex.encode(seed), equals(goldenSeedHex));
    });

    test('is deterministic: same rolls always derive the same seed', () async {
      final a = await deriveSeedFromRolls(goldenRolls);
      final b = await deriveSeedFromRolls(List.of(goldenRolls));
      expect(hex.encode(a), equals(hex.encode(b)));
    });

    test('restore-from-rolls reproduces the exact original key (roundtrip)', () async {
      final rolls = [20, 1, 19, 2, 18, 3, 17, 4, 16, 5, 15, 6, 14, 7, 13, 8, 12, 9, 11, 10, 1, 1, 1, 1];
      final created = await deriveSeedFromRolls(rolls);
      final restored = await deriveSeedFromRolls(List.of(rolls));
      expect(restored, equals(created));
    });

    test('different rolls derive different seeds', () async {
      final a = await deriveSeedFromRolls(goldenRolls);
      final differentRolls = List.of(goldenRolls)..[0] = 20;
      final b = await deriveSeedFromRolls(differentRolls);
      expect(hex.encode(a), isNot(equals(hex.encode(b))));
    });

    test('derived seed is 32 bytes', () async {
      final seed = await deriveSeedFromRolls(goldenRolls);
      expect(seed.length, equals(32));
    });
  });
}

const HexCodec hex = HexCodec();

class HexCodec {
  const HexCodec();
  String encode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
