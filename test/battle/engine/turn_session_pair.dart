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

/// A one-directional FIFO of payloads, used for exchanges that happen more
/// than once per turn. Mirrors production's `BattleFrameReader.framesOfType`
/// semantics: a value that arrives before the peer waits for it is buffered
/// rather than dropped, and waiters are served in order — so round 2 of a
/// repeated exchange can never consume round 1's payload.
class _ByteQueue {
  final _pending = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];

  void push(Uint8List value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _pending.add(value);
    }
  }

  Future<Uint8List> pop() {
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final waiter = Completer<Uint8List>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void clear() {
    _pending.clear();
    _waiters.clear();
  }
}

/// Latched record of which turns one side has announced its components done
/// for. Twin of [BattleSession]'s `_peerComponentsDoneTurns` +
/// `_componentsDoneWaiters`: a signal that arrives before anyone waits is
/// remembered, never dropped.
class _ComponentsDoneLatch {
  final _seen = <int>{};
  final _waiters = <int, Completer<void>>{};

  void add(int turnNumber) {
    _seen.add(turnNumber);
    _waiters.remove(turnNumber)?.complete();
  }

  Future<void> wait(int turnNumber) {
    if (_seen.contains(turnNumber)) return Future.value();
    return (_waiters[turnNumber] ??= Completer<void>()).future;
  }
}

/// Two coordinated [BattleTurnSession] implementations that simulate a real
/// two-client commit-reveal exchange without any network I/O.
///
/// Each exchange type has a pair of Completers (one per direction). When
/// session A writes its value and waits for B's, and session B does the
/// same simultaneously, both Completers resolve and both futures return.
/// This is the same causal structure as the real BattleSession over TCP.
///
/// One-shot Completers work because every phase exchanges exactly once per
/// turn — except the free-move round, which runs twice (Phase 5.5 for
/// spell-resolution bursts and Phase 6.5 for end-of-turn bursts). Those slots
/// use [_ByteQueue] instead; see its doc comment.
class TurnSessionPair {
  TurnSessionPair() {
    sessionA = PairedSession(this, isA: true);
    sessionB = PairedSession(this, isA: false);
  }

  late final PairedSession sessionA;
  late final PairedSession sessionB;

  // Match-scoped, NOT reset per turn: the pacing signal is keyed by turn
  // number and outlives any single turn's exchanges, exactly as production's
  // set-of-turns latch does.
  final _aComponentsDone = _ComponentsDoneLatch();
  final _bComponentsDone = _ComponentsDoneLatch();

  /// [peer] true selects A's latch, false selects B's — i.e. "the side whose
  /// announcements this latch holds".
  _ComponentsDoneLatch _componentsDoneFor({required bool peer}) =>
      peer ? _aComponentsDone : _bComponentsDone;

  // Per-turn completers. Call reset() before each new turn.
  var _aActionCommit = Completer<Uint8List>();
  var _bActionCommit = Completer<Uint8List>();
  var _aActionReveal = Completer<Uint8List>();
  var _bActionReveal = Completer<Uint8List>();
  var _aMoveCommit = Completer<Uint8List>();
  var _bMoveCommit = Completer<Uint8List>();
  var _aMoveReveal = Completer<Uint8List>();
  var _bMoveReveal = Completer<Uint8List>();
  var _aArtifactCommit = Completer<Uint8List>();
  var _bArtifactCommit = Completer<Uint8List>();
  var _aArtifactReveal = Completer<Uint8List>();
  var _bArtifactReveal = Completer<Uint8List>();
  var _aMeleeCommit = Completer<Uint8List>();
  var _bMeleeCommit = Completer<Uint8List>();
  var _aMeleeReveal = Completer<Uint8List>();
  var _bMeleeReveal = Completer<Uint8List>();
  // Queues, not one-shot Completers: the free-move round runs twice per turn.
  final _aFreeMoveCommit = _ByteQueue();
  final _bFreeMoveCommit = _ByteQueue();
  final _aFreeMoveReveal = _ByteQueue();
  final _bFreeMoveReveal = _ByteQueue();
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
  var _aForcedReveal = Completer<Uint8List>();
  var _bForcedReveal = Completer<Uint8List>();

  /// Forfeit reasons, routed to the OTHER session's [PairedSession.peerForfeit].
  /// Deliberately not cleared by [reset]: a forfeit ends the match, so unlike
  /// every other slot here it is once per pair, not once per turn.
  final _aForfeit = Completer<String>();
  final _bForfeit = Completer<String>();

  void reset() {
    _aActionCommit = Completer();
    _bActionCommit = Completer();
    _aActionReveal = Completer();
    _bActionReveal = Completer();
    _aMoveCommit = Completer();
    _bMoveCommit = Completer();
    _aMoveReveal = Completer();
    _bMoveReveal = Completer();
    _aArtifactCommit = Completer();
    _bArtifactCommit = Completer();
    _aArtifactReveal = Completer();
    _bArtifactReveal = Completer();
    _aMeleeCommit = Completer();
    _bMeleeCommit = Completer();
    _aMeleeReveal = Completer();
    _bMeleeReveal = Completer();
    _aFreeMoveCommit.clear();
    _bFreeMoveCommit.clear();
    _aFreeMoveReveal.clear();
    _bFreeMoveReveal.clear();
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
    _aForcedReveal = Completer();
    _bForcedReveal = Completer();
  }
}

class PairedSession implements BattleTurnSession {
  PairedSession(this._pair, {required this.isA});

  final TurnSessionPair _pair;
  final bool isA;

  // ── Spell-component pacing (docs/SPELL_COMPONENTS_PLAN.md §5.3) ─────────────
  //
  // Modelled with the same latch production uses: the signal is recorded per
  // turn on the RECEIVING side, so a peer that finished performing before
  // anyone asked still satisfies the wait. Getting this wrong in the fixture
  // would hide exactly the bug the latch exists to prevent.

  @override
  void sendComponentsDone(int turnNumber) =>
      _pair._componentsDoneFor(peer: !isA).add(turnNumber);

  @override
  Future<void> peerComponentsDone(int turnNumber) =>
      _pair._componentsDoneFor(peer: isA).wait(turnNumber);

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

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame) {
    if (isA) {
      _pair._aForcedReveal.complete(ourFrame);
      return _pair._bForcedReveal.future;
    } else {
      _pair._bForcedReveal.complete(ourFrame);
      return _pair._aForcedReveal.future;
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

  // ── Phase 0 artifact-activation commit-reveal ─────────────────────────────

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) {
    if (isA) {
      _pair._aArtifactCommit.complete(ourCommit);
      return _pair._bArtifactCommit.future;
    } else {
      _pair._bArtifactCommit.complete(ourCommit);
      return _pair._aArtifactCommit.future;
    }
  }

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aArtifactReveal.complete(ourReveal);
      return _pair._bArtifactReveal.future;
    } else {
      _pair._bArtifactReveal.complete(ourReveal);
      return _pair._aArtifactReveal.future;
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
      _pair._aFreeMoveCommit.push(ourCommit);
      return _pair._bFreeMoveCommit.pop();
    } else {
      _pair._bFreeMoveCommit.push(ourCommit);
      return _pair._aFreeMoveCommit.pop();
    }
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) {
    if (isA) {
      _pair._aFreeMoveReveal.push(ourReveal);
      return _pair._bFreeMoveReveal.pop();
    } else {
      _pair._bFreeMoveReveal.push(ourReveal);
      return _pair._aFreeMoveReveal.pop();
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

  /// Routed to the peer, unlike [SoloBattleSession]'s no-op: this fixture
  /// stands in for two real clients, and the whole point of the forfeit frame
  /// is that the OTHER device hears it.
  @override
  void sendForfeit(String reason) {
    final target = isA ? _pair._bForfeit : _pair._aForfeit;
    if (!target.isCompleted) target.complete(reason);
  }

  @override
  Future<String> get peerForfeit =>
      (isA ? _pair._aForfeit : _pair._bForfeit).future;
}
