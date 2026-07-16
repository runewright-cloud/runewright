// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_determinism_test.dart — Verifies B-5: resolution RNG is
// platform-independent and identical on both clients given the same inputs.
//
// Two independent TurnLoop instances run concurrently using a _TurnSessionPair
// that coordinates commit-reveal exchanges via Completers — the same protocol
// structure as a real two-client duel, not the SoloBattleSession stub which
// hides divergence by echoing state hashes back.
//
// The key invariant: after each turn both clients must produce byte-identical
// canonical state. If any resolution RNG call diverges between clients (wrong
// seed, platform-specific PRNG, or non-deterministic consumption order), the
// state hash will mismatch and the test fails.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/commit_reveal.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  // ── HashRng unit tests ────────────────────────────────────────────────────

  group('HashRng', () {
    test('identical seeds produce identical nextInt sequences', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x42);
      final r1 = HashRng(Uint8List.fromList(seed));
      final r2 = HashRng(Uint8List.fromList(seed));
      for (var i = 0; i < 200; i++) {
        expect(r1.nextInt(1000), equals(r2.nextInt(1000)),
            reason: 'diverged at index $i');
      }
    });

    test('different seeds produce different sequences', () {
      final s1 = Uint8List(32)..fillRange(0, 32, 0xAA);
      final s2 = Uint8List(32)..fillRange(0, 32, 0x55);
      final r1 = HashRng(s1);
      final r2 = HashRng(s2);
      final out1 = List.generate(20, (_) => r1.nextInt(1 << 30));
      final out2 = List.generate(20, (_) => r2.nextInt(1 << 30));
      expect(out1, isNot(equals(out2)));
    });

    test('nextInt has no modulo bias for small max', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x11);
      final rng = HashRng(seed);
      final counts = List.filled(3, 0);
      const n = 3000;
      for (var i = 0; i < n; i++) {
        counts[rng.nextInt(3)]++;
      }
      // Each bucket should be ~1000 ± 10%. Accept ±15% for CI flakiness margin.
      for (final c in counts) {
        expect(c, greaterThan(n ~/ 3 * 85 ~/ 100));
        expect(c, lessThan(n ~/ 3 * 115 ~/ 100));
      }
    });

    test('nextDouble is in [0, 1)', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x7F);
      final rng = HashRng(seed);
      for (var i = 0; i < 100; i++) {
        final v = rng.nextDouble();
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThan(1.0));
      }
    });

    test('List.shuffle produces identical result with same seed', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x33);
      final list1 = [1, 2, 3, 4, 5, 6, 7, 8];
      final list2 = List<int>.from(list1);
      list1.shuffle(HashRng(Uint8List.fromList(seed)));
      list2.shuffle(HashRng(Uint8List.fromList(seed)));
      expect(list1, equals(list2));
    });
  });

  // ── TurnLoop two-client determinism (B-5) ────────────────────────────────

  group('TurnLoop two-client determinism (B-5)', () {
    test(
        'two independent loops produce identical canonical state after each turn',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();

      final pair = _TurnSessionPair();
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
      );

      final input = TurnInput(action: PassAction());

      // Both loops run concurrently. The paired sessions coordinate all
      // commit-reveal exchanges via Completers so the exchange structure
      // is identical to a real two-client duel.
      //
      // The key observable: if both loops derive identical joint entropy and
      // use HashRng(phaseSeed) for all resolution randomness, canonical state
      // must match. The TurnLoop's own _exchangeStateHash already asserts this
      // internally; we also assert it here explicitly so a failure shows as a
      // test failure rather than an unhandled StateError.
      await Future.wait([
        loop1.runTurn(input),
        loop2.runTurn(input),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Turn 1: canonical state diverged between the two loops. '
            'Check phase-seed construction and HashRng wiring.',
      );

      // Second turn — verifies the invariant holds across turns and that
      // state.turnNumber increments identically on both sides.
      pair.reset();
      await Future.wait([
        loop1.runTurn(input),
        loop2.runTurn(input),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Turn 2: canonical state diverged.',
      );
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

BattleState _makeState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(2, -2);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}

// ── Paired session ────────────────────────────────────────────────────────────

/// Fixed joint entropy injected by the test sessions so both loops derive
/// identical RNG seeds regardless of their randomly-generated local nonces.
final _fixedJointEntropy = Uint8List(32)..fillRange(0, 32, 0x5A);

/// Two coordinated [BattleTurnSession] implementations that simulate a real
/// two-client commit-reveal exchange without any network I/O.
///
/// Each exchange type has a pair of Completers (one per direction). When
/// session A writes its value and waits for B's, and session B does the
/// same simultaneously, both Completers resolve and both futures return.
/// This is the same causal structure as the real BattleSession over TCP.
class _TurnSessionPair {
  _TurnSessionPair() {
    sessionA = _PairedSession(this, isA: true);
    sessionB = _PairedSession(this, isA: false);
  }

  late final _PairedSession sessionA;
  late final _PairedSession sessionB;

  // Per-turn completers. Call reset() before each new turn.
  var _aActionCommit = Completer<Uint8List>();
  var _bActionCommit = Completer<Uint8List>();
  var _aActionReveal = Completer<Uint8List>();
  var _bActionReveal = Completer<Uint8List>();
  var _aMoveCommit = Completer<Uint8List>();
  var _bMoveCommit = Completer<Uint8List>();
  var _aMoveReveal = Completer<Uint8List>();
  var _bMoveReveal = Completer<Uint8List>();
  var _aDelayed = Completer<Uint8List>();
  var _bDelayed = Completer<Uint8List>();
  var _aStateHash = Completer<Uint8List>();
  var _bStateHash = Completer<Uint8List>();
  var _aScryKey = Completer<Uint8List>();
  var _bScryKey = Completer<Uint8List>();
  var _aScryOpen = Completer<Uint8List>();
  var _bScryOpen = Completer<Uint8List>();

  void reset() {
    _aActionCommit = Completer();
    _bActionCommit = Completer();
    _aActionReveal = Completer();
    _bActionReveal = Completer();
    _aMoveCommit = Completer();
    _bMoveCommit = Completer();
    _aMoveReveal = Completer();
    _bMoveReveal = Completer();
    _aDelayed = Completer();
    _bDelayed = Completer();
    _aStateHash = Completer();
    _bStateHash = Completer();
    _aScryKey = Completer();
    _bScryKey = Completer();
    _aScryOpen = Completer();
    _bScryOpen = Completer();
  }
}

class _PairedSession implements BattleTurnSession {
  _PairedSession(this._pair, {required this.isA});

  final _TurnSessionPair _pair;
  final bool isA;

  // ── Entropy ───────────────────────────────────────────────────────────────

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    // Derive theirNonce so ourNonce XOR theirNonce = _fixedJointEntropy.
    // Both sides independently compute this; no cross-session coordination
    // is needed for the nonce exchange.
    final theirNonce = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      theirNonce[i] = ourNonce[i] ^ _fixedJointEntropy[i];
    }
    final theirCommit = await CommitRevealEntropy.commit(theirNonce);
    return (theirNonce: theirNonce, theirCommit: theirCommit);
  }

  // ── Action commit-reveal ──────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) {
    if (isA) {
      _pair._aActionCommit.complete(ourCommit);
      return _pair._bActionCommit.future;
    } else {
      _pair._bActionCommit.complete(ourCommit);
      return _pair._aActionCommit.future;
    }
  }

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aActionReveal.complete(ourReveal);
      return _pair._bActionReveal.future;
    } else {
      _pair._bActionReveal.complete(ourReveal);
      return _pair._aActionReveal.future;
    }
  }

  // ── Divination scrying pattern (§13b) ─────────────────────────────────────

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) {
    if (isA) {
      _pair._aScryKey.complete(ourFrame);
      return _pair._bScryKey.future;
    } else {
      _pair._bScryKey.complete(ourFrame);
      return _pair._aScryKey.future;
    }
  }

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) {
    if (isA) {
      _pair._aScryOpen.complete(ourFrame);
      return _pair._bScryOpen.future;
    } else {
      _pair._bScryOpen.complete(ourFrame);
      return _pair._aScryOpen.future;
    }
  }

  // ── Move commit-reveal ────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) {
    if (isA) {
      _pair._aMoveCommit.complete(ourCommit);
      return _pair._bMoveCommit.future;
    } else {
      _pair._bMoveCommit.complete(ourCommit);
      return _pair._aMoveCommit.future;
    }
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aMoveReveal.complete(ourReveal);
      return _pair._bMoveReveal.future;
    } else {
      _pair._bMoveReveal.complete(ourReveal);
      return _pair._aMoveReveal.future;
    }
  }

  // ── Delayed spell reveals ─────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals) {
    if (isA) {
      _pair._aDelayed.complete(ourReveals);
      return _pair._bDelayed.future;
    } else {
      _pair._bDelayed.complete(ourReveals);
      return _pair._aDelayed.future;
    }
  }

  // ── State hash ────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) {
    // Each side sends its hash and receives the other's. TurnLoop asserts
    // equality internally; any divergence throws StateError, failing the test.
    if (isA) {
      _pair._aStateHash.complete(ourHash);
      return _pair._bStateHash.future;
    } else {
      _pair._bStateHash.complete(ourHash);
      return _pair._aStateHash.future;
    }
  }

  // ── Entropy refresh (seam) ────────────────────────────────────────────────

  @override
  Future<Uint8List> refreshEntropy(String reason) async {
    // Not exercised in this test. Return a fixed value — if any effect calls
    // this without coordination, the test will catch the resulting desync.
    return Uint8List(32);
  }

  // ── Control ───────────────────────────────────────────────────────────────

  @override
  void sendForfeit(String reason) {}
}
