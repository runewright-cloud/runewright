// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_session_suite.dart — the M4 protocol test suite, parameterized over
// a `Transport` pair factory so the *exact same* test bodies run against
// both InMemoryTransport and LanSocketTransport. This is the abstraction-
// integrity check the M4 plan calls for: if MatchSession needed any change
// to pass over real sockets, the Transport interface leaked an abstraction.
// It didn't -- see match_session_test.dart vs match_session_socket_test.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/match_session.dart';
import 'package:rune_duel/protocol/proof_wire.dart';
import 'package:rune_duel/protocol/transport.dart';
import 'package:rune_duel/protocol/wire.dart';

import 'fixtures.dart';

void runMatchSessionTests(String transportLabel, Future<(Transport, Transport)> Function() makePair) {
  group('MatchSession ($transportLabel) happy path', () {
    test('valid proof + correct ownership signature is accepted', () async {
      final alice = await Identity.ephemeral();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      final (tAlice, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final aliceSession = await MatchSession.initiate(tAlice);
      final bobSession = await bobFuture;

      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysValid, vkBytes: dummyVk);
      await aliceSession.presentProof(identity: alice, proofBytes: proofBytes);
      final verified = await verifyFuture;

      expect(verified.presentedPubkey, alice.publicKeyBytes);
      expect(verified.proofBytes, proofBytes);
    });
  });

  group('MatchSession ($transportLabel) rejections', () {
    test('tampered/invalid proof is rejected', () async {
      final alice = await Identity.ephemeral();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      final (tAlice, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final aliceSession = await MatchSession.initiate(tAlice);
      final bobSession = await bobFuture;

      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysInvalid, vkBytes: dummyVk);
      final presentFuture = aliceSession.presentProof(identity: alice, proofBytes: proofBytes);

      await expectLater(
        verifyFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.invalidProof)),
      );
      await expectLater(
        presentFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.invalidProof)),
      );
    });

    test('owner_pubkey mismatch is rejected (presented key does not match the proof)', () async {
      final alice = await Identity.ephemeral();
      final mallory = await Identity.ephemeral();
      // Proof's owner_pubkey is bound to Alice's key, but the presentation
      // (built by hand here, not via presentProof) claims Mallory's pubkey.
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      final (tMallory, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final malloryReader = FrameReader();
      tMallory.onReceive.listen(malloryReader.addChunk);
      tMallory.send(Frame(MsgType.hello, Uint8List(16)).encode());
      await malloryReader.frames.first; // helloAck

      final bobSession = await bobFuture;
      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysValid, vkBytes: dummyVk);

      tMallory.send(
        Frame(MsgType.proofPresentation, lengthPrefixedConcat([mallory.publicKeyBytes, proofBytes])).encode(),
      );

      await expectLater(
        verifyFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.ownerPubkeyMismatch)),
      );
    });

    test('wrong signer: attacker holds the victim\'s public proof+pubkey but not their '
        'private key, so the ownership challenge fails', () async {
      final alice = await Identity.ephemeral();
      final mallory = await Identity.ephemeral();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      // Alice's genuine, internally-consistent (proof, pubkey) pair -- both
      // are public data Mallory could have observed. Mallory does NOT have
      // Alice's private key.
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      final (tMallory, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final malloryReader = FrameReader();
      tMallory.onReceive.listen(malloryReader.addChunk);
      tMallory.send(Frame(MsgType.hello, Uint8List(16)).encode());
      await malloryReader.frames.first; // helloAck

      final bobSession = await bobFuture;
      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysValid, vkBytes: dummyVk);

      tMallory.send(
        Frame(MsgType.proofPresentation, lengthPrefixedConcat([alice.publicKeyBytes, proofBytes])).encode(),
      );
      final challengeFrame = await malloryReader.frames.first;
      expect(challengeFrame.type, MsgType.challenge);

      // Mallory can't sign as Alice -- she signs with her own key instead.
      final digest = await buildChallengeDigest(
        nonce: challengeFrame.payload,
        proofPublicInputs: publicInputsSlice(proofBytes),
        matchId: bobSession.matchId,
      );
      final forgedSignature = await mallory.sign(digest);
      tMallory.send(Frame(MsgType.challengeResponse, Uint8List.fromList(forgedSignature)).encode());

      await expectLater(
        verifyFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.invalidSignature)),
      );
    });

    test('replayed (stale) signature from an old nonce/match_id is rejected', () async {
      final alice = await Identity.ephemeral();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      // A validly-produced signature, but bound to a stale nonce/match_id --
      // standing in for one captured from an earlier, separate exchange.
      final staleDigest = await buildChallengeDigest(
        nonce: Uint8List.fromList(List.filled(32, 0xAA)),
        proofPublicInputs: publicInputsSlice(proofBytes),
        matchId: Uint8List.fromList(List.filled(16, 0xBB)),
      );
      final staleSignature = await alice.sign(staleDigest);

      final (tMallory, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final malloryReader = FrameReader();
      tMallory.onReceive.listen(malloryReader.addChunk);
      tMallory.send(Frame(MsgType.hello, Uint8List(16)).encode());
      await malloryReader.frames.first; // helloAck

      final bobSession = await bobFuture;
      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysValid, vkBytes: dummyVk);

      tMallory.send(
        Frame(MsgType.proofPresentation, lengthPrefixedConcat([alice.publicKeyBytes, proofBytes])).encode(),
      );
      await malloryReader.frames.first; // the fresh challenge -- ignored, replaying the stale signature instead

      tMallory.send(Frame(MsgType.challengeResponse, Uint8List.fromList(staleSignature)).encode());

      await expectLater(
        verifyFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.invalidSignature)),
      );
    });

    test('relay attack: a signature obtained by relaying the challenge into a different '
        'session (different match_id) does not verify (plan amendment 1)', () async {
      final alice = await Identity.ephemeral();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final proofBytes = buildFakeProof(ownerPubkeyHex);

      // Session A: "Mallory" <-> Bob (the real MatchSession under test).
      final (tMallory, tBob) = await makePair();
      final bobFuture = MatchSession.accept(tBob);
      final malloryReader = FrameReader();
      tMallory.onReceive.listen(malloryReader.addChunk);
      tMallory.send(Frame(MsgType.hello, Uint8List(16)).encode());
      await malloryReader.frames.first; // helloAck
      final bobSession = await bobFuture; // bobSession.matchId == session A's match_id

      final verifyFuture = bobSession.verifyIncomingProof(verifyProof: alwaysValid, vkBytes: dummyVk);
      tMallory.send(
        Frame(MsgType.proofPresentation, lengthPrefixedConcat([alice.publicKeyBytes, proofBytes])).encode(),
      );
      final challengeFrame = await malloryReader.frames.first;
      expect(challengeFrame.type, MsgType.challenge);

      // Mallory relays Bob's nonce into a *separate* session with Alice
      // (session B), under cover of an unrelated match. Alice's own client
      // builds the digest using session B's match_id -- never Bob's --
      // because match_id is intrinsic to each session's own handshake, not
      // attacker-suppliable. Session B's match_id is independently random;
      // standing in for it directly here since the relay's defeat doesn't
      // depend on *how* Alice's session B was established, only that its
      // match_id necessarily differs from session A's.
      final sessionBMatchId = Uint8List.fromList(List.filled(16, 0x42));
      expect(sessionBMatchId, isNot(bobSession.matchId));
      final digestAliceActuallySigned = await buildChallengeDigest(
        nonce: challengeFrame.payload, // the relayed nonce -- Mallory can forward bytes freely
        proofPublicInputs: publicInputsSlice(proofBytes),
        matchId: sessionBMatchId, // but not Alice's own session's match_id
      );
      final relayedSignature = await alice.sign(digestAliceActuallySigned);

      // Mallory relays Alice's signature back into session A.
      tMallory.send(Frame(MsgType.challengeResponse, Uint8List.fromList(relayedSignature)).encode());

      await expectLater(
        verifyFuture,
        throwsA(isA<ProtocolException>().having((e) => e.reason, 'reason', RejectReason.invalidSignature)),
      );
    });
  });
}
