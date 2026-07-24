// SPDX-License-Identifier: GPL-3.0-or-later
//
// auth_handshake_test.dart — BattleSession.exchangeIdentityAuth
// (BATTLE_AUTH_PLAN.md §3): the mutual Ed25519 challenge-response that
// authenticates each peer's owner_pubkey before any spell cast is trusted.
//
// Two real BattleSession instances are paired over InMemoryTransport (no
// mocks) — the same "protocol first, radio later" approach as
// trade_session_test.dart. Attack scenarios drive one side's raw wire API
// (send/framesOfType, both public on BattleSession) to play a byzantine
// peer, while the honest side calls the real exchangeIdentityAuth.
//
// Not covered here (out of scope for this handshake in isolation): a peer
// presenting a raw pubkey that hashes to a DIFFERENT owner_pubkey than a
// proof later declares. exchangeIdentityAuth has no prior claim to check the
// presented key against — whatever raw key a peer proves possession of
// becomes their authenticated identity. Catching an authenticated identity
// that doesn't match a spell's declared owner is Phase B's job; see
// castingPlayerMayUse's tests in spell_authorization_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  test('two honest peers authenticate each other to their real owner_pubkey', () async {
    final identityA = await Identity.ephemeral();
    final identityB = await Identity.ephemeral();
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    // Both sides run the handshake simultaneously — same causal structure as
    // a real duel (BattleSession.exchangeIdentityAuth's doc comment).
    final results = await Future.wait([
      sessionA.exchangeIdentityAuth(localIdentity: identityA, matchId: matchId),
      sessionB.exchangeIdentityAuth(localIdentity: identityB, matchId: matchId),
    ]);
    final peerSeenByA = results[0];
    final peerSeenByB = results[1];

    expect(peerSeenByA.ownerPubkeyHex, equals(await identityB.ownerPubkeyHex()));
    expect(peerSeenByB.ownerPubkeyHex, equals(await identityA.ownerPubkeyHex()));
    expect(peerSeenByA.rawPubkey, equals(identityB.publicKeyBytes));
    expect(peerSeenByB.rawPubkey, equals(identityA.publicKeyBytes));

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a garbled signature is rejected (auth_failed) and the honest side forfeits', () async {
    final identityA = await Identity.ephemeral();
    final attackerIdentity = await Identity.ephemeral();
    final (transportA, transportAttacker) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final attackerSession = BattleSession(transportAttacker, matchId);

    final authFuture =
        sessionA.exchangeIdentityAuth(localIdentity: identityA, matchId: matchId);

    // Attacker must send some authChallenge frame for A to proceed past its
    // own await; content is irrelevant to this test (A's outgoing signature
    // over it is never inspected here).
    await attackerSession.framesOfType(BattleMsgType.authChallenge).first;
    attackerSession.send(BattleMsgType.authChallenge, Uint8List(32));

    // Wait for A's own (real, honest) authResponse to arrive before sending
    // ours: this proves A has moved past reading noncePeer and re-subscribed
    // to await the peer's authResponse — sending too early can race a fresh
    // subscription on a broadcast stream and silently drop the frame.
    await attackerSession.framesOfType(BattleMsgType.authResponse).first;

    // Attacker responds with a real raw pubkey but a signature that was never
    // produced by that key at all.
    final garbageSig = Uint8List(64);
    attackerSession.send(
      BattleMsgType.authResponse,
      Uint8List.fromList([...attackerIdentity.publicKeyBytes, ...garbageSig]),
    );

    final forfeitFrame = attackerSession.framesOfType(BattleMsgType.forfeit).first;
    await expectLater(authFuture, throwsA(isA<StateError>()));
    expect(utf8.decode((await forfeitFrame).payload), equals('auth_failed'));

    await transportA.disconnect();
    await transportAttacker.disconnect();
  });

  test('a valid signature over the wrong (stale/replayed) nonce is rejected', () async {
    final identityA = await Identity.ephemeral();
    final attackerIdentity = await Identity.ephemeral();
    final (transportA, transportAttacker) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final attackerSession = BattleSession(transportAttacker, matchId);

    final authFuture =
        sessionA.exchangeIdentityAuth(localIdentity: identityA, matchId: matchId);

    // A's real challenge nonce — the attacker deliberately signs a different
    // one below, simulating a signature captured from a prior session.
    await attackerSession.framesOfType(BattleMsgType.authChallenge).first;
    attackerSession.send(BattleMsgType.authChallenge, Uint8List(32));

    // See the "garbled signature" test above for why this wait is required
    // before sending our own authResponse (broadcast-stream subscribe race).
    await attackerSession.framesOfType(BattleMsgType.authResponse).first;

    final staleNonce = Uint8List(32)..fillRange(0, 32, 0x99);
    final wrongMessage = [
      ...utf8.encode(kIdentityAuthSignatureTag),
      ...matchId,
      ...staleNonce,
    ];
    final sigOverWrongNonce = await attackerIdentity.sign(wrongMessage);
    attackerSession.send(
      BattleMsgType.authResponse,
      Uint8List.fromList([...attackerIdentity.publicKeyBytes, ...sigOverWrongNonce]),
    );

    final forfeitFrame = attackerSession.framesOfType(BattleMsgType.forfeit).first;
    await expectLater(authFuture, throwsA(isA<StateError>()));
    expect(utf8.decode((await forfeitFrame).payload), equals('auth_failed'));

    await transportA.disconnect();
    await transportAttacker.disconnect();
  });

  test('a malformed (too-short) auth response is rejected', () async {
    final identityA = await Identity.ephemeral();
    final (transportA, transportAttacker) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final attackerSession = BattleSession(transportAttacker, matchId);

    final authFuture =
        sessionA.exchangeIdentityAuth(localIdentity: identityA, matchId: matchId);

    await attackerSession.framesOfType(BattleMsgType.authChallenge).first;
    attackerSession.send(BattleMsgType.authChallenge, Uint8List(32));

    // See the "garbled signature" test above for why this wait is required
    // before sending our own authResponse (broadcast-stream subscribe race).
    await attackerSession.framesOfType(BattleMsgType.authResponse).first;
    attackerSession.send(BattleMsgType.authResponse, Uint8List(10)); // way too short

    final forfeitFrame = attackerSession.framesOfType(BattleMsgType.forfeit).first;
    await expectLater(authFuture, throwsA(isA<StateError>()));
    expect(utf8.decode((await forfeitFrame).payload), equals('auth_malformed_response'));

    await transportA.disconnect();
    await transportAttacker.disconnect();
  });

  test('a peer presenting our own identity is rejected as self/reflection', () async {
    final sharedIdentity = await Identity.ephemeral();
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final future = Future.wait([
      sessionA.exchangeIdentityAuth(localIdentity: sharedIdentity, matchId: matchId),
      sessionB.exchangeIdentityAuth(localIdentity: sharedIdentity, matchId: matchId),
    ]);

    await expectLater(future, throwsA(isA<StateError>()));

    await transportA.disconnect();
    await transportB.disconnect();
  });
}
