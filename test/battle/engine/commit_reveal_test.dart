// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/commit_reveal.dart';

void main() {
  group('CommitRevealEntropy', () {
    // Fixed 32-byte test nonces.
    final nonceA = Uint8List.fromList(List.generate(32, (i) => i));
    final nonceB = Uint8List.fromList(List.generate(32, (i) => 255 - i));

    // ── commit ─────────────────────────────────────────────────────────────

    test('commit produces 32 bytes', () async {
      final c = await CommitRevealEntropy.commit(nonceA);
      expect(c.length, equals(32));
    });

    test('commit is deterministic', () async {
      final c1 = await CommitRevealEntropy.commit(nonceA);
      final c2 = await CommitRevealEntropy.commit(nonceA);
      expect(c1, equals(c2));
    });

    test('different nonces produce different commits', () async {
      final c1 = await CommitRevealEntropy.commit(nonceA);
      final c2 = await CommitRevealEntropy.commit(nonceB);
      expect(c1, isNot(equals(c2)));
    });

    // ── revealAndCombine — valid ────────────────────────────────────────────

    test('valid reveal returns XOR of the two nonces', () async {
      final commitB = await CommitRevealEntropy.commit(nonceB);
      final result = await CommitRevealEntropy.revealAndCombine(
        ourNonce: nonceA,
        theirNonce: nonceB,
        theirCommit: commitB,
      );
      expect(result, isNotNull);
      expect(result, equals(CommitRevealEntropy.xorBytes(nonceA, nonceB)));
    });

    test('reveal is symmetric: A XOR B == B XOR A', () async {
      final commitA = await CommitRevealEntropy.commit(nonceA);
      final commitB = await CommitRevealEntropy.commit(nonceB);

      final entropyFromA = await CommitRevealEntropy.revealAndCombine(
        ourNonce: nonceA,
        theirNonce: nonceB,
        theirCommit: commitB,
      );
      final entropyFromB = await CommitRevealEntropy.revealAndCombine(
        ourNonce: nonceB,
        theirNonce: nonceA,
        theirCommit: commitA,
      );

      expect(entropyFromA, isNotNull);
      expect(entropyFromB, isNotNull);
      expect(entropyFromA, equals(entropyFromB));
    });

    // ── revealAndCombine — invalid ──────────────────────────────────────────

    test('mismatched reveal returns null (withheld/forged nonce)', () async {
      final commitB = await CommitRevealEntropy.commit(nonceB);
      final fakeNonce = Uint8List.fromList(List.filled(32, 0xAB));

      final result = await CommitRevealEntropy.revealAndCombine(
        ourNonce: nonceA,
        theirNonce: fakeNonce, // does not hash to commitB
        theirCommit: commitB,
      );
      expect(result, isNull);
    });

    test('all-zero reveal against non-zero commit returns null', () async {
      final commitB = await CommitRevealEntropy.commit(nonceB);
      final zeroNonce = Uint8List(32);

      final result = await CommitRevealEntropy.revealAndCombine(
        ourNonce: nonceA,
        theirNonce: zeroNonce,
        theirCommit: commitB,
      );
      expect(result, isNull);
    });

    // ── xorBytes ──────────────────────────────────────────────────────────

    test('xorBytes: A XOR A is all-zero', () {
      final result = CommitRevealEntropy.xorBytes(nonceA, nonceA);
      expect(result, equals(Uint8List(32)));
    });

    test('xorBytes: A XOR zero is A', () {
      final zero = Uint8List(32);
      final result = CommitRevealEntropy.xorBytes(nonceA, zero);
      expect(result, equals(nonceA));
    });

    test('xorBytes: matches manual byte-by-byte XOR', () {
      final expected = Uint8List.fromList(
        List.generate(32, (i) => nonceA[i] ^ nonceB[i]),
      );
      expect(CommitRevealEntropy.xorBytes(nonceA, nonceB), equals(expected));
    });

    // ── generateNonce ─────────────────────────────────────────────────────

    test('generateNonce produces 32 bytes', () {
      expect(CommitRevealEntropy.generateNonce().length, equals(32));
    });

    test('two generateNonce calls produce different values (probabilistic)', () {
      final a = CommitRevealEntropy.generateNonce();
      final b = CommitRevealEntropy.generateNonce();
      // Probability of collision with a 32-byte secure RNG is negligible.
      expect(a, isNot(equals(b)));
    });
  });
}
