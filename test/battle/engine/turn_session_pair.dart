// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_session_pair.dart — shared test fixture: two coordinated
// [BattleTurnSession]s that simulate a real two-client commit-reveal
// exchange without any network I/O.
//
// Extracted from turn_loop_determinism_test.dart so other engine tests that
// need genuine two-client lockstep (rather than SoloBattleSession, which
// hides divergence by echoing state hashes back) can share it.

import 'dart:async';
import 'dart:typed_data';

import 'package:rune_duel/battle/engine/commit_reveal.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/spell_permission.dart';

/// Fixed joint entropy injected by the test sessions so both loops derive
/// identical RNG seeds regardless of their randomly-generated local nonces.
final fixedJointEntropy = Uint8List(32)..fillRange(0, 32, 0x5A);

/// Two coordinated [BattleTurnSession] implementations that simulate a real
/// two-client commit-reveal exchange without any network I/O.
///
/// Each exchange type has a pair of Completers (one per direction). When
/// session A writes its value and waits for B's, and session B does the
/// same simultaneously, both Completers resolve and both futures return.
/// This is the same causal structure as the real BattleSession over TCP.
class TurnSessionPair {
  TurnSessionPair() {
    sessionA = PairedSession(this, isA: true);
    sessionB = PairedSession(this, isA: false);
  }

  late final PairedSession sessionA;
  late final PairedSession sessionB;

  // Per-turn completers. Call reset() before each new turn.
  var _aActionCommit = Completer<Uint8List>();
  var _bActionCommit = Completer<Uint8List>();
  var _aActionReveal = Completer<Uint8List>();
  var _bActionReveal = Completer<Uint8List>();
  var _aMoveCommit = Completer<Uint8List>();
  var _bMoveCommit = Completer<Uint8List>();
  var _aMoveReveal = Completer<Uint8List>();
  var _bMoveReveal = Completer<Uint8List>();
  var _aMeleeCommit = Completer<Uint8List>();
  var _bMeleeCommit = Completer<Uint8List>();
  var _aMeleeReveal = Completer<Uint8List>();
  var _bMeleeReveal = Completer<Uint8List>();
  var _aFreeMoveCommit = Completer<Uint8List>();
  var _bFreeMoveCommit = Completer<Uint8List>();
  var _aFreeMoveReveal = Completer<Uint8List>();
  var _bFreeMoveReveal = Completer<Uint8List>();
  var _aDelayed = Completer<Uint8List>();
  var _bDelayed = Completer<Uint8List>();
  var _aStateHash = Completer<Uint8List>();
  var _bStateHash = Completer<Uint8List>();
  var _aScryKey = Completer<Uint8List>();
  var _bScryKey = Completer<Uint8List>();
  var _aScryOpen = Completer<Uint8List>();
  var _bScryOpen = Completer<Uint8List>();
  var _aSpellRevealKey = Completer<Uint8List>();
  var _bSpellRevealKey = Completer<Uint8List>();
  var _aSpellRevealOpen = Completer<Uint8List>();
  var _bSpellRevealOpen = Completer<Uint8List>();

  void reset() {
    _aActionCommit = Completer();
    _bActionCommit = Completer();
    _aActionReveal = Completer();
    _bActionReveal = Completer();
    _aMoveCommit = Completer();
    _bMoveCommit = Completer();
    _aMoveReveal = Completer();
    _bMoveReveal = Completer();
    _aMeleeCommit = Completer();
    _bMeleeCommit = Completer();
    _aMeleeReveal = Completer();
    _bMeleeReveal = Completer();
    _aFreeMoveCommit = Completer();
    _bFreeMoveCommit = Completer();
    _aFreeMoveReveal = Completer();
    _bFreeMoveReveal = Completer();
    _aDelayed = Completer();
    _bDelayed = Completer();
    _aStateHash = Completer();
    _bStateHash = Completer();
    _aScryKey = Completer();
    _bScryKey = Completer();
    _aScryOpen = Completer();
    _bScryOpen = Completer();
    _aSpellRevealKey = Completer();
    _bSpellRevealKey = Completer();
    _aSpellRevealOpen = Completer();
    _bSpellRevealOpen = Completer();
  }
}

class PairedSession implements BattleTurnSession {
  PairedSession(this._pair, {required this.isA});

  final TurnSessionPair _pair;
  final bool isA;

  // ── Identity authentication (BATTLE_AUTH_PLAN.md §3) ────────────────────────
  //
  // This fixture tests resolution-RNG determinism, not authentication — both
  // sides report no authenticated peer (mirrors SoloBattleSession's stub) so
  // TurnLoop's cast-authorization and state-hash-signing checks stay skipped,
  // matching this test's pre-existing unsigned/unauthorized behaviour.

  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) async => AuthenticatedPeer.none;

  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) async => const <SpellPermission>[];

  // ── Entropy ───────────────────────────────────────────────────────────────

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    // Derive theirNonce so ourNonce XOR theirNonce = fixedJointEntropy.
    // Both sides independently compute this; no cross-session coordination
    // is needed for the nonce exchange.
    final theirNonce = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      theirNonce[i] = ourNonce[i] ^ fixedJointEntropy[i];
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

  // ── Divination (Water) spell-list reveal ───────────────────────────────────

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) {
    if (isA) {
      _pair._aSpellRevealKey.complete(ourFrame);
      return _pair._bSpellRevealKey.future;
    } else {
      _pair._bSpellRevealKey.complete(ourFrame);
      return _pair._aSpellRevealKey.future;
    }
  }

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) {
    if (isA) {
      _pair._aSpellRevealOpen.complete(ourFrame);
      return _pair._bSpellRevealOpen.future;
    } else {
      _pair._bSpellRevealOpen.complete(ourFrame);
      return _pair._aSpellRevealOpen.future;
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

  // ── Resolution-phase melee commit-reveal ──────────────────────────────────

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) {
    if (isA) {
      _pair._aMeleeCommit.complete(ourCommit);
      return _pair._bMeleeCommit.future;
    } else {
      _pair._bMeleeCommit.complete(ourCommit);
      return _pair._aMeleeCommit.future;
    }
  }

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aMeleeReveal.complete(ourReveal);
      return _pair._bMeleeReveal.future;
    } else {
      _pair._bMeleeReveal.complete(ourReveal);
      return _pair._aMeleeReveal.future;
    }
  }

  // ── Post-resolution free-move commit-reveal ───────────────────────────────

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) {
    if (isA) {
      _pair._aFreeMoveCommit.complete(ourCommit);
      return _pair._bFreeMoveCommit.future;
    } else {
      _pair._bFreeMoveCommit.complete(ourCommit);
      return _pair._aFreeMoveCommit.future;
    }
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aFreeMoveReveal.complete(ourReveal);
      return _pair._bFreeMoveReveal.future;
    } else {
      _pair._bFreeMoveReveal.complete(ourReveal);
      return _pair._aFreeMoveReveal.future;
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
