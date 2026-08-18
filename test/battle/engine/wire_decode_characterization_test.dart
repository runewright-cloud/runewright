// SPDX-License-Identifier: GPL-3.0-or-later
//
// wire_decode_characterization_test.dart — CHARACTERIZATION of how the battle
// protocol reads bytes it did not write.
//
// The encode direction is pinned byte-for-byte in
// wire_format_characterization_test.dart. This file pins the other half: what
// a decoder does with a payload that is truncated, over-long, or carries a
// field value this build does not know about.
//
// That behaviour is protocol, not implementation detail. Every branch here is
// reachable by a modified peer choosing to send exactly these bytes, and the
// choice each one makes — degrade to Pass, fall back to a default, ignore the
// excess — is what keeps two honest devices in lockstep and what an attacker
// gets to work with. A refactor that "tightens" one of these into a rejection
// is a protocol change, not a cleanup: it turns a turn that used to resolve
// into a forfeit.
//
// These are assertions of TODAY'S behaviour. Nothing here claims it is the
// behaviour we want.
//
// ## Trust boundary note (M4.19)
//
// The summon cases below assert that the two authored summon bytes are read
// back verbatim and steer resolution. That is the open trust gap characterized
// in summon_declaration_trust_test.dart, deliberately unfixed. Decoding is not
// the layer that should close it — the codec's only job is to say what the
// bytes mean, not whether to believe them.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_permission.dart';

// ── Scripted peer ─────────────────────────────────────────────────────────────

/// A [SoloBattleSession] whose "peer" sends action bytes chosen by the test,
/// with a correctly-formed split-leaf commitment over them.
///
/// The commitment is recomputed here rather than borrowed from the engine, so
/// that a change to the preimage layout shows up as a forfeit in these tests
/// rather than being silently tracked. The layout it mirrors is pinned
/// independently by wire_format_characterization_test.dart's
/// "commitment preimages" group.
class _ScriptedPeer implements BattleTurnSession {
  _ScriptedPeer(this._inner, this.peerActionBytes, {this.peerMoveBytes});

  final SoloBattleSession _inner;
  final Uint8List peerActionBytes;
  final Uint8List? peerMoveBytes;

  static final _saltA = Uint8List(16)..fillRange(0, 16, 0xA1);
  static final _saltB = Uint8List(16)..fillRange(0, 16, 0xB2);
  static final _moveNonce = Uint8List(16)..fillRange(0, 16, 0xC3);

  static Uint8List _leaf(List<int> data, List<int> salt) =>
      Uint8List.fromList(sha256.convert([...data, ...salt]).bytes);

  static (List<int> target, List<int> remainder) _split(Uint8List action) {
    if (action.isEmpty) return (const [], action);
    final targetOffset = action[0] == 0x01 ? 1 + 32 + 2 : null;
    if (targetOffset == null || action.length < targetOffset + 4) {
      return (const [], action);
    }
    return (
      action.sublist(targetOffset, targetOffset + 4),
      [...action.sublist(0, targetOffset), ...action.sublist(targetOffset + 4)],
    );
  }

  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) async {
    final (target, remainder) = _split(peerActionBytes);
    final leafA = _leaf(remainder, _saltA);
    final leafB = _leaf(target, _saltB);
    return Uint8List.fromList(sha256.convert([...leafA, ...leafB]).bytes);
  }

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) async =>
      Uint8List.fromList([..._saltA, ..._saltB, ...peerActionBytes]);

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) async {
    final bytes = peerMoveBytes;
    if (bytes == null) return _inner.exchangeMoveCommit(ourCommit);
    return Uint8List.fromList(sha256.convert([...bytes, ..._moveNonce]).bytes);
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) async {
    final bytes = peerMoveBytes;
    if (bytes == null) return _inner.exchangeMoveReveal(ourReveal);
    return Uint8List.fromList([..._moveNonce, ...bytes]);
  }

  // ── Everything else is the ordinary solo stub ────────────────────────────

  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) => _inner.exchangeIdentityAuth(localIdentity: localIdentity, matchId: matchId);

  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) => _inner.exchangeSpellPermissions(ours, peerOwnerPubkeyHex: peerOwnerPubkeyHex);

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) => _inner.exchangeNonce(ourCommit: ourCommit, ourNonce: ourNonce);

  @override
  void sendComponentsDone(int turnNumber) => _inner.sendComponentsDone(turnNumber);

  @override
  Future<void> peerComponentsDone(int turnNumber) =>
      _inner.peerComponentsDone(turnNumber);

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) =>
      _inner.exchangeArtifactActivationCommit(ourCommit);

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) =>
      _inner.exchangeArtifactActivationReveal(ourReveal);

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) =>
      _inner.exchangeMeleeCommit(ourCommit);

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) =>
      _inner.exchangeMeleeReveal(ourReveal);

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) =>
      _inner.exchangeFreeMoveCommit(ourCommit);

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) =>
      _inner.exchangeFreeMoveReveal(ourReveal);

  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ours) =>
      _inner.exchangeDelayedSpellReveals(ours);

  @override
  Future<Uint8List> exchangeScryKey(Uint8List f) => _inner.exchangeScryKey(f);

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List f) => _inner.exchangeScryOpen(f);

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List f) =>
      _inner.exchangeSpellRevealKey(f);

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List f) =>
      _inner.exchangeSpellRevealOpen(f);

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List f) =>
      _inner.exchangeForcedReveal(f);

  @override
  Future<Uint8List> refreshEntropy(String reason) => _inner.refreshEntropy(reason);

  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) =>
      _inner.exchangeStateHash(ourHash);

  @override
  void sendForfeit(String reason) => _inner.sendForfeit(reason);

  @override
  Future<String> get peerForfeit => _inner.peerForfeit;

  @override
  Future<String> get peerConnectionLost => _inner.peerConnectionLost;

  @override
  Future<void> close() => _inner.close();
}

// ── Fixture ───────────────────────────────────────────────────────────────────

const _localId = 'local';
const _peerId = 'peer';

({TurnLoop loop, BattleState state}) _setup(
  Uint8List peerActionBytes, {
  Uint8List? peerMoveBytes,
}) {
  const lp = HexCoord(0, 0);
  const pp = HexCoord(0, 3);
  final battlefield = Battlefield(radius: 6)
    ..occupancy[_localId] = lp
    ..occupancy[_peerId] = pp;

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2),
    avatars: [
      WizardAvatar(
        playerId: _localId,
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 200,
        position: lp,
        teamId: 'blue',
        baseSpellRange: 6,
      ),
      WizardAvatar(
        playerId: _peerId,
        ownerPubkeyHex: '0x${'1' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 200,
        position: pp,
        teamId: 'red',
        baseSpellRange: 6,
      ),
    ],
    teams: [
      Team(id: 'blue', playerIds: const [_localId]),
      Team(id: 'red', playerIds: const [_peerId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: _ScriptedPeer(
      SoloBattleSession(state: state),
      peerActionBytes,
      peerMoveBytes: peerMoveBytes,
    ),
    localPlayerId: _localId,
    commitNonceSource: (n) => Uint8List(n)..fillRange(0, n, 0x11),
  );
  return (loop: loop, state: state);
}

Uint8List _be2(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

Uint8List _coord(int q, int r) => Uint8List.fromList([
      (q >> 8) & 0xFF, q & 0xFF, (r >> 8) & 0xFF, r & 0xFF,
    ]);

/// A well-formed 0x01 spell cast: three earths at a tile next to the local
/// wizard, with the two summon bytes appended.
Uint8List _spellCast({
  List<String> formula = const ['earth', 'earth', 'earth'],
  String name = 'Peer Spell',
  int isSummon = 0,
  int personality = 0,
  List<int> trailing = const [],
}) {
  final formulaBytes = formula.join(',').codeUnits;
  final nameBytes = name.codeUnits;
  return Uint8List.fromList([
    0x01,
    ...List<int>.filled(32, 0xEE), // commitment
    ..._be2(4), // t
    ..._coord(0, 1), // target
    ..._be2(formulaBytes.length), ...formulaBytes,
    ..._be2(nameBytes.length), ...nameBytes,
    0, 0, 0, // isPotent, isVelocity, isEfficiency
    0, // no conveyor direction
    isSummon, personality,
    ...trailing,
  ]);
}

void main() {
  group('action decode', () {
    test('a well-formed peer cast resolves', () async {
      final ctx = _setup(_spellCast());
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.loop.lastResolvedSpells.where((e) => e.casterId == _peerId),
        hasLength(1),
      );
    });

    test('an unknown leading type byte degrades to Pass, not a forfeit',
        () async {
      final ctx = _setup(Uint8List.fromList([0x7F, 0xFF, 0xFF]));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.lastResolvedSpells, isEmpty);
    });

    test('empty action bytes decode as Pass', () async {
      final ctx = _setup(Uint8List(0));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.lastResolvedSpells, isEmpty);
    });

    test('a cast truncated below the fixed-field minimum degrades to Pass',
        () async {
      // 1 + 32 + 2 + 4 + 2 + 2 + 3 is the guard; one byte short of it.
      final full = _spellCast();
      final ctx = _setup(Uint8List.fromList(full.sublist(0, 1 + 32 + 2 + 4 + 2 + 2 + 3 - 1)));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.lastResolvedSpells, isEmpty);
    });

    test('trailing bytes past the last known field are ignored', () async {
      final ctx = _setup(_spellCast(trailing: const [0xDE, 0xAD, 0xBE, 0xEF]));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.loop.lastResolvedSpells.where((e) => e.casterId == _peerId),
        hasLength(1),
        reason: 'a longer payload from a newer build still resolves',
      );
    });
  });

  group('summon bytes (M4.19: authored, uncertified, read verbatim)', () {
    test('isSummon=1 spawns the peer creature', () async {
      final ctx = _setup(_spellCast(isSummon: 1));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.minions.where((m) => m.ownerId == _peerId), hasLength(1));
    });

    test('isSummon=0 on the same formula spawns nothing', () async {
      final ctx = _setup(_spellCast());
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.minions.where((m) => m.ownerId == _peerId), isEmpty);
    });

    test('a personality index this build does not know falls back to aggressive',
        () async {
      final ctx = _setup(_spellCast(isSummon: 1, personality: 0xFF));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      final minion = ctx.state.minions.firstWhere((m) => m.ownerId == _peerId);
      expect(minion.personality, SummonPersonality.aggressive);
    });

    test('a payload truncated before the summon bytes reads them as absent',
        () async {
      final full = _spellCast(isSummon: 1, personality: 1);
      final ctx = _setup(Uint8List.fromList(full.sublist(0, full.length - 2)));
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.minions.where((m) => m.ownerId == _peerId),
        isEmpty,
        reason: 'missing isSummon reads as 0, i.e. an ordinary incantation',
      );
    });
  });

  group('movement decode', () {
    test('a truncated movement payload reads as no dash and no path', () async {
      final ctx = _setup(
        Uint8List.fromList([0x00]),
        peerMoveBytes: Uint8List.fromList([0x00]), // one byte: needs two
      );
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.avatars.firstWhere((a) => a.playerId == _peerId).position,
        const HexCoord(0, 3),
      );
    });

    test('meditateInMove discards a declared path even when one is sent',
        () async {
      final ctx = _setup(
        Uint8List.fromList([0x00]),
        // isDashing=0, meditateInMove=1, count=1, coord(0,2)
        peerMoveBytes: Uint8List.fromList([0x00, 0x01, 0x01, ..._coord(0, 2)]),
      );
      final before = ctx.state.avatars.firstWhere((a) => a.playerId == _peerId).mana;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      final peer = ctx.state.avatars.firstWhere((a) => a.playerId == _peerId);
      expect(peer.position, const HexCoord(0, 3), reason: 'path forced empty');
      expect(peer.mana, greaterThan(before), reason: 'meditation still paid out');
    });

    test('a path count larger than the bytes present stops at the underflow',
        () async {
      final ctx = _setup(
        Uint8List.fromList([0x00]),
        // claims 4 coords, supplies one
        peerMoveBytes: Uint8List.fromList([0x00, 0x00, 0x04, ..._coord(0, 2)]),
      );
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.avatars.firstWhere((a) => a.playerId == _peerId).position,
        const HexCoord(0, 2),
        reason: 'the one decodable step is taken; the phantom three are dropped',
      );
    });
  });
}
