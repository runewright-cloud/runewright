// SPDX-License-Identifier: GPL-3.0-or-later
//
// hash_rng.dart — HashRng: deterministic, platform-independent PRNG.
//
// Used wherever both battle clients must generate identical random sequences
// from a shared seed (resolution RNG, spell-draw shuffle).
//
// DO NOT seed with Random.secure() or any platform-specific entropy source —
// those break cross-client determinism. For cryptographic nonces use
// CommitRevealEntropy.generateNonce() instead.

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Deterministic byte stream derived from 32-byte entropy via a hash counter.
///
/// Block i = SHA-256(entropy ‖ BigEndian32(i)). Bytes are consumed
/// sequentially across blocks. Fully platform-independent — identical output
/// on any Dart runtime given the same seed.
///
/// Implements [Random] so it can be passed to [List.shuffle] and accepted
/// wherever [Random] is expected (e.g. [ApplyContext.rng]). [nextDouble] and
/// [nextBool] satisfy the interface; [nextInt] is the primary entry point.
class HashRng implements Random {
  HashRng(Uint8List entropy) : _entropy = Uint8List.fromList(entropy);

  final Uint8List _entropy;
  int _counter = 0;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  Uint8List _nextBlock() {
    // 36 bytes: 32 entropy + 4 counter (BE uint32)
    final msg = Uint8List(36)..setRange(0, 32, _entropy);
    ByteData.sublistView(msg, 32).setUint32(0, _counter++, Endian.big);
    return Uint8List.fromList(sha256.convert(msg).bytes);
  }

  int _nextByte() {
    if (_pos >= _buf.length) {
      _buf = _nextBlock();
      _pos = 0;
    }
    return _buf[_pos++];
  }

  /// Returns an integer in [0, max) with no modulo bias.
  ///
  /// Power-of-2 masking + rejection sampling. Expected iterations < 2
  /// for all realistic max values (≤ 100 spells in a chapter, ≤ 6 directions).
  @override
  int nextInt(int max) {
    assert(max > 0);
    if (max == 1) return 0;
    var mask = max - 1;
    mask |= mask >> 1;
    mask |= mask >> 2;
    mask |= mask >> 4;
    mask |= mask >> 8;
    mask |= mask >> 16;
    while (true) {
      final v =
          (_nextByte() << 24) | (_nextByte() << 16) | (_nextByte() << 8) | _nextByte();
      final candidate = v & mask;
      if (candidate < max) return candidate;
    }
  }

  /// 53-bit precision: (high26 * 2^27 + low27) / 2^53.
  @override
  double nextDouble() =>
      (nextInt(1 << 26) * (1 << 27) + nextInt(1 << 27)) / 9007199254740992.0;

  @override
  bool nextBool() => (_nextByte() & 1) == 1;
}
