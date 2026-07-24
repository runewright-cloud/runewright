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
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_permission.dart';

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

    test(
        'Dash + Meditate + Melee stay in lockstep across two independent loops',
        () async {
      final state1 = _makeAdjacentState();
      final state2 = _makeAdjacentState();

      final pair = _TurnSessionPair();
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (candidates) async => candidates.first,
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        meleeTargetPicker: (candidates) async => candidates.first,
      );

      // player_a dashes; player_b meditates. Both melee their adjacent foe
      // — exercising the new isDashing/meditateInMove move-payload bits and
      // the melee commit-reveal round together, on two independently-driven
      // clients, the same way a real duel would.
      await Future.wait([
        loop1.runTurn(TurnInput(action: DashAction())),
        loop2.runTurn(TurnInput(action: MeditateAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Dash/Meditate/Melee turn diverged between the two loops. '
            'Check the move-payload isDashing/meditateInMove bits and the '
            'melee commit-reveal wiring.',
      );

      // Sanity: the melee round actually fired on both sides.
      final a = state1.avatars.firstWhere((av) => av.playerId == 'player_a');
      final b = state1.avatars.firstWhere((av) => av.playerId == 'player_b');
      expect(a.hp, 23);
      expect(b.hp, 23);
      expect(b.mana, 75); // player_b: Meditate (main), starting 50 + 25.
    });
  });

  // ── Spell-cast wire round trip (SIGHTINGS_PLAN.md §2 wire change) ────────

  group('SpellCastAction wire round trip', () {
    test(
        "receiving loop decodes the caster's spell name off the 0x01 wire "
        'action unchanged', () async {
      final state1 = _makeAdjacentState();
      final state2 = _makeAdjacentState();

      final pair = _TurnSessionPair();
      // Both loops verify (rather than skip verification, as the other
      // tests in this file do) so the receiving loop actually decodes and
      // certifies the peer's proof outputs instead of short-circuiting at
      // TurnLoop._verifyPeerSpellCast's "verify == null" bail-out — that
      // path would leave the caster's mana deducted on one side only and
      // diverge canonical state for reasons unrelated to the wire format
      // under test here.
      Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      // Empty formula + segmentCount/dotCount == 0 keeps this a "whiff"
      // cast on both the wire-trust side (spell.formula, read directly by
      // the caster's own loop) and the certified side (TrajectoryParser
      // output from the all-zero synthetic trajectory below, read by the
      // receiving loop) — zero effect, zero certified base cost, so the
      // two independently-computed mana/effect paths can't diverge for
      // reasons unrelated to the thing this test actually checks: does the
      // name survive the wire round trip.
      final commitmentBytes = Uint8List.fromList(List.filled(32, 0xab));
      final commitmentHex =
          '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final spell = SpellAsset(
        id: 'test-spell',
        createdAt: DateTime.utc(2026, 7, 19),
        tier: 24,
        t: 1,
        ownerPubkeyHex: '0x${'00' * 32}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: _syntheticProofFor(
          tier: 24,
          t: 1,
          commitmentBytes: commitmentBytes,
          segmentCount: 0,
          dotCount: 0,
        ),
        name: 'Ember Wake',
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: const [],
      );
      // _encodeAction only appends the [proof_len][proof_bytes]... tail
      // (which the receiving loop needs — verifyProof != null means it
      // decodes withProof: true and forfeits on an empty proof) when the
      // caster has a local chapter to prove membership against. A
      // single-spell "chapter" is enough (depth-0 membership proof).
      loop1.localChapterCommitments = [spell.commitmentHex];

      // player_a casts at the adjacent player_b; player_b passes. Both
      // loops independently decode/resolve BOTH actions to reach identical
      // canonical state, so loop2's lastResolvedSpells reflects what it
      // decoded off the wire from loop1's encoded action — the real
      // encode -> wire bytes -> decode round trip, not a direct call into
      // the private _encodeAction/_decodeAction methods.
      await Future.wait([
        loop1.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        )),
        loop2.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Spell-cast turn diverged between the two loops.',
      );

      expect(loop2.lastResolvedSpells, hasLength(1));
      final resolved = loop2.lastResolvedSpells.single;
      expect(resolved.spell.name, equals('Ember Wake'),
          reason: 'name must survive the 0x01 wire encode/decode round trip');
      expect(resolved.spell.commitmentHex, equals(spell.commitmentHex));
      expect(resolved.spell.formula, equals(spell.formula));
      expect(resolved.casterId, equals('player_a'));
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Build synthetic proof bytes in the canonical wire format ProofIntake
/// parses: `[4 BE bytes: field count N][N × 32-byte fields][proof body]`
/// (mirrors test/battle/engine/proof_intake_test.dart's `_syntheticProof`,
/// extended to stamp the commitment/segmentCount/dotCount fields a real
/// `_verifyPeerSpellCast` call reads). All other fields (owner_pubkey,
/// border_activations, dominance_trajectory, supreme_dominance_flags) stay
/// zero, which TrajectoryParser reads as "no certified effect zones" —
/// paired with an empty wire `formula` on the caster's [SpellAsset] so both
/// the wire-trust and certified resolution paths agree on a no-op cast.
Uint8List _syntheticProofFor({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
  required int segmentCount,
  required int dotCount,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);

  data.setUint32(0, count, Endian.big);
  data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
  data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3: commitment
  data.setUint32(4 + (8 + 2 * tier) * 32 + 28, segmentCount, Endian.big);
  data.setUint32(4 + (8 + 2 * tier + 1) * 32 + 28, dotCount, Endian.big);
  return bytes;
}

/// Like [_makeState] but with adjacent avatars (so both have a melee target)
/// and headroom below maxMana (so a Meditate gain is observable rather than
/// clamped away).
BattleState _makeAdjacentState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        maxMana: 100,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
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

class _PairedSession implements BattleTurnSession {
  _PairedSession(this._pair, {required this.isA});

  final _TurnSessionPair _pair;
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
