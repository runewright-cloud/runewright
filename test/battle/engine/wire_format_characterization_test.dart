// SPDX-License-Identifier: GPL-3.0-or-later
//
// wire_format_characterization_test.dart — EXACT-BYTE pins for the battle
// protocol's on-the-wire payloads, captured through TurnLoop's public path.
//
// ## Why this file exists
//
// Every codec in the battle protocol lived as a private method of TurnLoop,
// so the only coverage it had was indirect: a two-client turn resolved the
// same way on both sides, therefore the bytes "must have been" right. That
// is behavioural equivalence, not byte compatibility — it cannot tell a
// field-order change from a field-order change applied consistently to both
// encoder and decoder, and it cannot tell a widened integer from a narrowed
// one when the test values are all small.
//
// These tests capture the literal payloads a real turn puts on the wire and
// freeze them as hex. They are deliberately written against the PUBLIC
// surface only (construct a TurnLoop, run a turn, record what the session
// was handed), so they are indifferent to which class owns the encoder —
// which is the point: they must keep passing verbatim across the codec
// extraction, and they are the evidence that no byte moved.
//
// ## Reading a failure
//
// A diff here is a protocol-compatibility break. It means a build of this
// app can no longer duel a build from before the change, and
// `kBattleProtocolVersion` (match_discovery.dart, currently 5) would have to
// be bumped for the mismatch to be detected at handshake rather than as a
// mid-match state-hash forfeit. Do not "re-bless" these vectors to make a
// refactor pass.
//
// ## What is NOT pinned here
//
// Anything whose bytes are legitimately nondeterministic: the X25519
// ephemeral keys and AEAD ciphertexts in the scry / spell-reveal exchanges.
// Those get structural pins (lead byte, frame length) instead — the parts a
// decoder actually branches on.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';

// ── Recording session ─────────────────────────────────────────────────────────

/// Wraps [SoloBattleSession] and records every payload the loop hands it.
///
/// Delegation rather than subclassing: the recorder must not change a single
/// answer the solo session gives back, or the captured bytes would be of a
/// turn that never happens in production.
class _RecordingSession implements BattleTurnSession {
  _RecordingSession(this._inner);

  final SoloBattleSession _inner;

  final sent = <String, List<Uint8List>>{};

  void _record(String slot, Uint8List bytes) =>
      (sent[slot] ??= <Uint8List>[]).add(Uint8List.fromList(bytes));

  Uint8List only(String slot) {
    final frames = sent[slot];
    expect(frames, isNotNull, reason: 'nothing was sent on slot "$slot"');
    expect(frames!, hasLength(1), reason: 'slot "$slot" was written more than once');
    return frames.single;
  }

  Uint8List first(String slot) {
    final frames = sent[slot];
    expect(frames, isNotNull, reason: 'nothing was sent on slot "$slot"');
    return frames!.first;
  }

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
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) {
    _record('actionCommit', ourCommit);
    return _inner.exchangeActionCommit(ourCommit);
  }

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) {
    _record('actionReveal', ourReveal);
    return _inner.exchangeActionReveal(ourReveal);
  }

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) {
    _record('moveCommit', ourCommit);
    return _inner.exchangeMoveCommit(ourCommit);
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) {
    _record('moveReveal', ourReveal);
    return _inner.exchangeMoveReveal(ourReveal);
  }

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) {
    _record('artifactCommit', ourCommit);
    return _inner.exchangeArtifactActivationCommit(ourCommit);
  }

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) {
    _record('artifactReveal', ourReveal);
    return _inner.exchangeArtifactActivationReveal(ourReveal);
  }

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) {
    _record('meleeCommit', ourCommit);
    return _inner.exchangeMeleeCommit(ourCommit);
  }

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) {
    _record('meleeReveal', ourReveal);
    return _inner.exchangeMeleeReveal(ourReveal);
  }

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) {
    _record('freeMoveCommit', ourCommit);
    return _inner.exchangeFreeMoveCommit(ourCommit);
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) {
    _record('freeMoveReveal', ourReveal);
    return _inner.exchangeFreeMoveReveal(ourReveal);
  }

  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ours) {
    _record('delayedReveal', ours);
    return _inner.exchangeDelayedSpellReveals(ours);
  }

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) {
    _record('scryKey', ourFrame);
    return _inner.exchangeScryKey(ourFrame);
  }

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) {
    _record('scryOpen', ourFrame);
    return _inner.exchangeScryOpen(ourFrame);
  }

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) {
    _record('spellRevealKey', ourFrame);
    return _inner.exchangeSpellRevealKey(ourFrame);
  }

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) {
    _record('spellRevealOpen', ourFrame);
    return _inner.exchangeSpellRevealOpen(ourFrame);
  }

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ours) {
    _record('forcedReveal', ours);
    return _inner.exchangeForcedReveal(ours);
  }

  @override
  Future<Uint8List> refreshEntropy(String reason) =>
      _inner.refreshEntropy(reason);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<String> get peerConnectionLost => _inner.peerConnectionLost;

  /// The one place this recorder does not simply pass the solo session's
  /// answer through. Solo echoes whatever it is handed, which is right for
  /// an unsigned 32-byte hash but wrong once [TurnLoop.signMessage] is set:
  /// the loop would then compare its own `hash ‖ signature` against a bare
  /// hash and forfeit. Truncating to 32 keeps the echo meaning "the peer
  /// agrees", which is what solo has always meant, for signed turns too.
  /// A no-op on unsigned turns.
  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) async {
    _record('stateHash', ourHash);
    final echoed = await _inner.exchangeStateHash(ourHash);
    return Uint8List.fromList(echoed.sublist(0, 32));
  }

  @override
  void sendForfeit(String reason) => _inner.sendForfeit(reason);

  @override
  Future<String> get peerForfeit => _inner.peerForfeit;
}

// ── Fixture ───────────────────────────────────────────────────────────────────

/// Deterministic commit salts, numbered in draw order.
///
/// A counter rather than a constant fill so the pins below distinguish
/// saltA from saltB (an action commit hashes them into *different* leaves —
/// a constant fill would let a swap pass unnoticed) and so each phase's
/// reveal carries a visibly different nonce.
class _CountingNonces {
  int _n = 0;
  Uint8List call(int length) =>
      Uint8List(length)..fillRange(0, length, ++_n & 0xFF);
}

const _localId = 'local';
const _dummyId = 'dummy';

/// 32 bytes of commitment, distinct per spell so a pin cannot pass by
/// accident of every field being zero.
String _commitmentHex(int fill) => '0x${fill.toRadixString(16).padLeft(2, '0') * 32}';

SpellAsset _spell({
  int commitmentFill = 0xC1,
  int t = 3,
  String name = 'Ember',
  List<String> formula = const ['fire', 'fire'],
  bool isSummon = false,
  String summonPersonality = 'aggressive',
  Uint8List? proofBytes,
}) => SpellAsset(
      id: 'pinned-spell',
      createdAt: DateTime.utc(2026, 8, 18),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: proofBytes ?? Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
      name: name,
      commitmentHex: _commitmentHex(commitmentFill),
      spellHashHex: '0x${'ab' * 32}',
      formula: formula,
      isSummon: isSummon,
      summonPersonality: summonPersonality,
    );

({TurnLoop loop, _RecordingSession rec, BattleState state}) _setup({
  bool isVocalComponents = false,
  Uint8List? matchId,
  Future<List<int>> Function(List<int>)? signMessage,
}) {
  const lp = HexCoord(0, 0);
  const dp = HexCoord(0, 3);
  final battlefield = Battlefield(radius: 6)
    ..occupancy[_localId] = lp
    ..occupancy[_dummyId] = dp;

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2),
    avatars: [
      WizardAvatar(
        playerId: _localId,
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: lp,
        teamId: 'solo',
        baseSpellRange: 6,
      ),
      WizardAvatar(
        playerId: _dummyId,
        ownerPubkeyHex: '0x${'1' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: dp,
        teamId: 'foe',
        baseSpellRange: 6,
      ),
    ],
    teams: [
      Team(id: 'solo', playerIds: const [_localId]),
      Team(id: 'foe', playerIds: const [_dummyId]),
    ],
    battlefield: battlefield,
  );

  final rec = _RecordingSession(SoloBattleSession(state: state));
  final loop = TurnLoop(
    state: state,
    session: rec,
    localPlayerId: _localId,
    matchId: matchId,
    isVocalComponents: isVocalComponents,
    signMessage: signMessage,
    commitNonceSource: _CountingNonces().call,
  );
  return (loop: loop, rec: rec, state: state);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The reveal frame minus its leading salt(s): `nonce(16) ‖ payload` for the
/// move/melee/artifact rounds, `saltA(16) ‖ saltB(16) ‖ payload` for actions.
String _payloadHex(Uint8List reveal, {int saltBytes = 16}) =>
    _hex(reveal.sublist(saltBytes));

/// Length in bytes of the trailing proof tail on a spell-cast payload.
///
/// Computed by re-walking the head fields rather than hardcoded, so the pins
/// above stay readable when a fixture's formula or name length changes.
int _tailLength(Uint8List payload) {
  var pos = 1 + 32 + 2 + 4; // type, commitment, t, target coord
  final formulaLen = (payload[pos] << 8) | payload[pos + 1];
  pos += 2 + formulaLen;
  final nameLen = (payload[pos] << 8) | payload[pos + 1];
  pos += 2 + nameLen;
  pos += 3; // isPotent, isVelocity, isEfficiency
  final hasConveyor = payload[pos] == 1;
  pos += 1 + (hasConveyor ? 4 : 0);
  pos += 2; // summon bytes
  return payload.length - pos;
}

void main() {
  group('action payload bytes', () {
    Future<String> encoded(TurnAction action, {bool vocal = false}) async {
      final ctx = _setup(isVocalComponents: vocal);
      await ctx.loop.runTurn(TurnInput(action: action));
      return _payloadHex(ctx.rec.only('actionReveal'), saltBytes: 32);
    }

    test('Pass is a single 0x00', () async {
      expect(await encoded(PassAction()), '00');
    });

    test('Dash is a single 0x04', () async {
      expect(await encoded(DashAction()), '04');
    });

    test('Meditate is a single 0x05', () async {
      expect(await encoded(MeditateAction()), '05');
    });

    test('spell cast field order and widths', () async {
      final bytes = await encoded(
        SpellCastAction(spell: _spell(), targetHex: const HexCoord(-1, 2)),
      );
      expect(bytes, '01c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c10003ffff00020009666972652c666972650005456d626572000000000000');
    });

    test('summon bytes ride the cast verbatim (M4.19: authored, uncertified)',
        () async {
      final bytes = await encoded(
        SpellCastAction(
          spell: _spell(isSummon: true, summonPersonality: 'defensive'),
          targetHex: const HexCoord(0, 1),
        ),
      );
      expect(bytes, '01c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c10003000000010009666972652c666972650005456d626572000000000100');
    });

    test('enhancement flags and conveyor direction', () async {
      final bytes = await encoded(
        SpellCastAction(
          spell: _spell(),
          targetHex: const HexCoord(1, 1),
          isPotent: true,
          isVelocity: true,
          isEfficiency: true,
          conveyorDirection: const HexCoord(-1, 0),
        ),
      );
      expect(bytes, '01c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c10003000100010009666972652c666972650005456d62657201010101ffff00000000');
    });

    test('vocal mode appends the trailing recall suffix', () async {
      final bytes = await encoded(
        SpellCastAction(
          spell: _spell(),
          targetHex: const HexCoord(0, 1),
          recall: IncantationRecall.silent,
        ),
        vocal: true,
      );
      expect(bytes, '01c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c10003000000010009666972652c666972650005456d626572000000000000020002');
    });

    test('mystery cast, immediate', () async {
      final bytes = await encoded(
        MysterySpellCastAction(
          spell: _spell(commitmentFill: 0xC2, t: 5, name: 'Veil'),
          mysteryCommitment: Uint8List(32)..fillRange(0, 32, 0x7E),
          immediateTarget: const HexCoord(0, 2),
          immediateNonce: Uint8List(16)..fillRange(0, 16, 0x6D),
        ),
      );
      expect(bytes, '03c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c200050009666972652c6669726500045665696c7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e01000000026d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d00000000');
    });

    test('mystery cast, delayed (no plaintext target)', () async {
      final bytes = await encoded(
        MysterySpellCastAction(
          spell: _spell(commitmentFill: 0xC2, t: 5, name: 'Veil'),
          mysteryCommitment: Uint8List(32)..fillRange(0, 32, 0x7E),
        ),
      );
      expect(bytes, '03c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c200050009666972652c6669726500045665696c7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e0000000000');
    });
  });

  group('movement payload bytes', () {
    Future<String> moved({
      required List<HexCoord> path,
      bool dash = false,
      bool meditateInMove = false,
    }) async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: dash ? DashAction() : PassAction(),
        movePath: path,
        meditateInMove: meditateInMove,
      ));
      return _payloadHex(ctx.rec.only('moveReveal'));
    }

    test('flags then count then coords', () async {
      expect(
        await moved(path: const [HexCoord(1, 0), HexCoord(2, -1)]),
        '000002000100000002ffff',
      );
    });

    test('dash flag rides the movement payload, not the action', () async {
      expect(await moved(path: const [HexCoord(1, 0)], dash: true), '01000100010000');
    });

    test('meditateInMove forces an empty path on the wire', () async {
      expect(
        await moved(path: const [HexCoord(1, 0)], meditateInMove: true),
        '000100',
      );
    });

    test('empty path is count 0', () async {
      expect(await moved(path: const []), '000000');
    });
  });

  group('melee and artifact payload bytes', () {
    test('declining melee is a single 0x00', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(_payloadHex(ctx.rec.only('meleeReveal')), '00');
    });

    test('a melee target is 0x01 then the coord', () async {
      const lp = HexCoord(0, 0);
      const dp = HexCoord(0, 1);
      final battlefield = Battlefield(radius: 6)
        ..occupancy[_localId] = lp
        ..occupancy[_dummyId] = dp;
      final state = BattleState(
        config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2),
        avatars: [
          WizardAvatar(
            playerId: _localId,
            ownerPubkeyHex: '0x${'0' * 64}',
            hp: 24,
            mana: 100,
            maxMana: 100,
            position: lp,
            teamId: 'solo',
            baseSpellRange: 3,
          ),
          WizardAvatar(
            playerId: _dummyId,
            ownerPubkeyHex: '0x${'1' * 64}',
            hp: 24,
            mana: 100,
            maxMana: 100,
            position: dp,
            teamId: 'foe',
            baseSpellRange: 3,
          ),
        ],
        teams: [
          Team(id: 'solo', playerIds: const [_localId]),
          Team(id: 'foe', playerIds: const [_dummyId]),
        ],
        battlefield: battlefield,
      );
      final rec = _RecordingSession(SoloBattleSession(state: state));
      final loop = TurnLoop(
        state: state,
        session: rec,
        localPlayerId: _localId,
        meleeTargetPicker: (candidates) async => dp,
        commitNonceSource: _CountingNonces().call,
      );
      await loop.runTurn(TurnInput(action: PassAction()));
      expect(_payloadHex(rec.only('meleeReveal')), '0100000001');
    });

    test('declaring no artifact is a single 0x00', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(_payloadHex(ctx.rec.only('artifactReveal')), '00');
    });
  });

  group('commitment preimages', () {
    test('action commit is the split-leaf hash over the pinned salts', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _spell(), targetHex: const HexCoord(-1, 2)),
      ));
      expect(_hex(ctx.rec.only('actionCommit')), '45597338f022e034d632b7d0db348a5fdd62d2e78d437712c74cb866ecd5ce3d');
    });

    test('pass commit (no plaintext target leaf) differs in shape', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(_hex(ctx.rec.only('actionCommit')), '2d9d5957a3a0d2c391d9eef7b8a1516df5edcd0f1bef27aa27702d323a7f6d0c');
    });

    test('move commit is SHA-256(payload ‖ nonce)', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0)],
      ));
      expect(_hex(ctx.rec.only('moveCommit')), '38df1865b98a6dc3375f099ae68683bed14477ce4ec63802ab10e0a542c4b167');
    });
  });

  group('state-hash signature framing', () {
    test('tag, matchId, turn number BE4, then the hash', () async {
      final signed = <List<int>>[];
      final ctx = _setup(
        matchId: Uint8List.fromList([0xA0, 0xA1, 0xA2, 0xA3]),
        signMessage: (m) async {
          signed.add(List<int>.from(m));
          return List<int>.filled(64, 0);
        },
      );
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(signed, hasLength(1));
      final msg = signed.single;
      // 'RUNEWRIGHT_BATTLE_STATE_V1\x00' is 27 bytes.
      expect(_hex(msg.sublist(0, 27)), _hex(utf8.encode(kStateHashSignatureTag)));
      expect(_hex(msg.sublist(27, 31)), 'a0a1a2a3');
      expect(_hex(msg.sublist(31, 35)), '00000001', reason: 'turn 1 as BE4');
      expect(msg.length, 27 + 4 + 4 + 32);
    });
  });

  group('encrypted-exchange frame shape', () {
    test('no active link sends the single-byte 0x00 decline on both slots',
        () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(_hex(ctx.rec.first('scryKey')), '00');
      expect(_hex(ctx.rec.first('scryOpen')), '00');
      expect(_hex(ctx.rec.first('spellRevealKey')), '00');
      expect(_hex(ctx.rec.first('spellRevealOpen')), '00');
    });
  });

  group('delayed-reveal payload bytes', () {
    test('an empty reveal list is a single count byte', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(_hex(ctx.rec.only('delayedReveal')), '00');
    });

    test('one entry is id(16) coord(4) delay(1) nonce(16)', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        delayedSpellReveals: [
          DelayedSpellReveal(
            pendingSpellId: '0f' * 16,
            targetTile: const HexCoord(2, -3),
            delay: 2,
            nonce: Uint8List(16)..fillRange(0, 16, 0x5C),
          ),
        ],
      ));
      expect(_hex(ctx.rec.only('delayedReveal')), '010f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0002fffd025c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c');
    });
  });

  group('spell proof tail bytes', () {
    // The tail is written only when the loop has a chapter to prove against.
    // Both shapes matter: a single-spell chapter writes depth 0 (the leaf is
    // the root), and a multi-spell chapter writes real siblings — the second
    // is the shape that went unexercised long enough to hide a decoder bug
    // (see _decodeAction's parseProofTail comment).
    Future<String> tailOf(List<String> chapter, SpellAsset spell) async {
      final ctx = _setup();
      ctx.loop.localChapterCommitments = chapter;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: const HexCoord(0, 1)),
      ));
      final payload = ctx.rec.only('actionReveal').sublist(32);
      // Everything up to and including the two summon bytes is pinned by the
      // "spell cast field order" test above; the tail is what follows.
      return _hex(payload.sublist(payload.length - _tailLength(payload)));
    }

    test('single-spell chapter writes proof_len, proof, depth 0', () async {
      final spell = _spell();
      expect(
        await tailOf([spell.commitmentHex], spell),
        '00000004deadbeef00',
      );
    });

    test('multi-spell chapter writes depth then (sibling:32, direction:1) pairs',
        () async {
      final spell = _spell();
      final tail = await tailOf(
        [spell.commitmentHex, _commitmentHex(0xC3), _commitmentHex(0xC4)],
        spell,
      );
      // proof_len(4) ‖ DEADBEEF ‖ depth ‖ depth × (sibling 32 + direction 1)
      expect(tail.substring(0, 8), '00000004', reason: 'proof_len BE4');
      expect(tail.substring(8, 16), 'deadbeef', reason: 'proof bytes verbatim');
      final depth = int.parse(tail.substring(16, 18), radix: 16);
      expect(depth, 2, reason: '3-leaf tree: two siblings on the path');
      expect(tail.length, 18 + depth * 66);
      // Direction bytes are the last byte of each 33-byte pair and are 0/1.
      for (var d = 0; d < depth; d++) {
        final dir = tail.substring(18 + d * 66 + 64, 18 + d * 66 + 66);
        expect(dir, anyOf('00', '01'));
      }
    });
  });
}

