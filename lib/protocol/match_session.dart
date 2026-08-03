// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_session.dart — the M4 match protocol: proof exchange + verification
// + per-match Ed25519 ownership challenge + replay/relay rejection.
//
// Scope (M4 brief): proof exchange, verify_ultra_honk, ownership signing,
// replay prevention. NOT full battle/lockstep turn resolution -- that's the
// (still out-of-scope per CLAUDE.md) Battlefield system.
//
// Security design (plan amendment 1, "the ownership challenge must bind to
// the proof and the match, not just the nonce"): signing a bare nonce only
// proves "someone holding this key is live right now," not that they're
// live *for this proof, in this match*. A peer could present a proof it
// doesn't own, relay the verifier's nonce to the true owner under cover of
// an unrelated session, and pass off the resulting signature. The fix binds
// all three together:
//
//   signature = Sign_owner( SHA256(len-prefixed(nonce, proof_public_inputs, match_id)) )
//
// `match_id` is the linchpin: it is established once, locally, at session
// handshake (`initiate`/`accept`) and never re-read from a later message --
// so a relayed challenge from session A cannot produce a signature valid
// for session B, because A and B have independently random match_ids and
// nothing in this protocol lets a remote peer overwrite this session's
// local copy. (This defeats relaying an established challenge across
// sessions; it does not by itself authenticate the very first handshake
// against an active on-path adversary -- a deeper channel-binding question
// out of scope for M4's protocol layer.)

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/identity.dart';
import 'proof_wire.dart';
import 'transport.dart';
import 'wire.dart';

enum RejectReason {
  handshakeFailed,
  invalidProof,
  ownerPubkeyMismatch,
  invalidSignature,
}

class ProtocolException implements Exception {
  ProtocolException(this.reason, this.message);
  final RejectReason reason;
  final String message;
  @override
  String toString() => 'ProtocolException($reason): $message';
}

/// A successfully verified incoming proof presentation, post ownership
/// challenge.
class VerifiedPresentation {
  VerifiedPresentation({required this.presentedPubkey, required this.proofBytes});
  final Uint8List presentedPubkey;
  final Uint8List proofBytes;
}

/// Type alias for the `verifyProof` FFI call (`lib/ffi/prover.dart`),
/// injected rather than imported directly so the protocol layer stays
/// testable without a real proof/VK in the common-path tests.
typedef ProofVerifier = Future<bool> Function(Uint8List vkBytes, Uint8List proofBytes);

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// `H(nonce ‖ proof_public_inputs ‖ match_id)` -- the exact payload the
/// ownership challenge signs over (plan amendment 1). Each field is
/// length-prefixed (`lengthPrefixedConcat`) so the framing is unambiguous
/// regardless of any field's length.
Future<List<int>> buildChallengeDigest({
  required List<int> nonce,
  required List<int> proofPublicInputs,
  required List<int> matchId,
}) async {
  final input = lengthPrefixedConcat([nonce, proofPublicInputs, matchId]);
  final hash = await Sha256().hash(input);
  return hash.bytes;
}

/// One peer-to-peer match connection: owns a [Transport] and the match_id
/// established at handshake time (see file-level doc for why match_id must
/// never be read from a later message).
class MatchSession {
  MatchSession._(this._transport, this.matchId, this._reader, this._sub) {
    _reader.frames.listen(_onFrame);
  }

  final Transport _transport;
  final Uint8List matchId;
  final FrameReader _reader;
  final StreamSubscription<List<int>> _sub;

  Completer<Frame>? _pending;

  // A frame that arrived before anything called _awaitNextFrame() to wait
  // for it. Real gap, not hypothetical: found via the M4 gate-harness
  // cleanup, where adding a CRS-init step before runVerifierFlow's
  // verifyIncomingProof() call widened the window between a session
  // becoming reachable and something actually listening for its first
  // frame, enough to reliably lose the race in tests. Without buffering,
  // _onFrame had nowhere to put a frame that beat the listener into
  // existence and silently dropped it -- the receiver then waits forever
  // for a frame that already came and went. In the real game this is not
  // just a test-timing artifact: any verifier-side setup latency (asset
  // loads, SRS/CRS init, anything) before the first await creates the same
  // window against a prover fast enough to have already sent. Only one
  // frame is ever buffered, matching the strict request/response,
  // no-pipelining design FrameReader already documents.
  Frame? _bufferedFrame;

  void _onFrame(Frame frame) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      _pending = null;
      pending.complete(frame);
    } else {
      _bufferedFrame = frame;
    }
  }

  Future<Frame> _awaitNextFrame() {
    final buffered = _bufferedFrame;
    if (buffered != null) {
      _bufferedFrame = null;
      return Future.value(buffered);
    }
    final completer = Completer<Frame>();
    _pending = completer;
    return completer.future;
  }

  Future<Frame> _request(Frame toSend) {
    final future = _awaitNextFrame();
    _transport.send(toSend.encode());
    return future;
  }

  /// Initiator side of the match_id handshake: generates a fresh random
  /// match_id (16 bytes) and sends it. Each call to [initiate] produces an
  /// independent match_id, even between the same two peers.
  static Future<MatchSession> initiate(Transport transport) async {
    final reader = FrameReader();
    final sub = transport.onReceive.listen(reader.addChunk);
    final matchId = _randomBytes(16);
    final session = MatchSession._(transport, matchId, reader, sub);
    final ack = await session._request(Frame(MsgType.hello, matchId));
    if (ack.type != MsgType.helloAck) {
      throw ProtocolException(RejectReason.handshakeFailed, 'expected helloAck, got ${ack.type}');
    }
    return session;
  }

  /// Responder side: waits for the peer's `Hello` and adopts its match_id
  /// as this session's own -- it is never re-read from any later message.
  static Future<MatchSession> accept(Transport transport) async {
    final reader = FrameReader();
    final sub = transport.onReceive.listen(reader.addChunk);
    final hello = await reader.frames.first;
    if (hello.type != MsgType.hello) {
      throw ProtocolException(RejectReason.handshakeFailed, 'expected hello, got ${hello.type}');
    }
    final session = MatchSession._(transport, hello.payload, reader, sub);
    transport.send(Frame(MsgType.helloAck, Uint8List(0)).encode());
    return session;
  }

  Future<void> close() async {
    await _sub.cancel();
    await _reader.close();
  }

  // ── Presenter / prover role ────────────────────────────────────────────

  /// Presents [proofBytes] (already proven, confirmed wire format) and this
  /// device's raw Ed25519 public key, then answers the verifier's ownership
  /// challenge. Throws [ProtocolException] on rejection at any stage.
  Future<void> presentProof({
    required Identity identity,
    required Uint8List proofBytes,
  }) async {
    final presentation = lengthPrefixedConcat([identity.publicKeyBytes, proofBytes]);
    final response = await _request(Frame(MsgType.proofPresentation, presentation));

    if (response.type == MsgType.reject) {
      throw ProtocolException(RejectReason.invalidProof, utf8.decode(response.payload));
    }
    if (response.type != MsgType.challenge) {
      throw ProtocolException(RejectReason.invalidProof, 'unexpected response ${response.type}');
    }

    final nonce = response.payload;
    final digest = await buildChallengeDigest(
      nonce: nonce,
      proofPublicInputs: publicInputsSlice(proofBytes),
      matchId: matchId,
    );
    final signature = await identity.sign(digest);
    final outcome = await _request(Frame(MsgType.challengeResponse, Uint8List.fromList(signature)));

    if (outcome.type != MsgType.accept) {
      throw ProtocolException(RejectReason.invalidSignature, utf8.decode(outcome.payload));
    }
  }

  // ── Verifier role ───────────────────────────────────────────────────────

  /// Waits for a peer's proof presentation, verifies the proof and that the
  /// presented pubkey hashes to the proof's `owner_pubkey`, issues a fresh
  /// nonce challenge, and checks the signed response. Throws
  /// [ProtocolException] on any rejection (invalid proof, owner_pubkey
  /// mismatch, bad/relayed/stale signature).
  Future<VerifiedPresentation> verifyIncomingProof({
    required ProofVerifier verifyProof,
    required Uint8List vkBytes,
  }) async {
    final presentationFrame = await _awaitNextFrame();
    final parts = lengthPrefixedSplit(presentationFrame.payload, 2);
    final presentedPubkey = parts[0];
    final proofBytes = parts[1];

    final proofOk = await verifyProof(vkBytes, proofBytes);
    if (!proofOk) {
      _transport.send(Frame(MsgType.reject, utf8.encode('invalid proof')).encode());
      throw ProtocolException(RejectReason.invalidProof, 'verify_ultra_honk rejected the proof');
    }

    final claimedOwnerPubkeyHex = ownerPubkeyHexFromProof(proofBytes);
    final ownerOk = await Identity.ownerPubkeyMatches(
      presentedPubkeyBytes: presentedPubkey,
      claimedOwnerPubkeyHex: claimedOwnerPubkeyHex,
    );
    if (!ownerOk) {
      _transport.send(Frame(MsgType.reject, utf8.encode('owner_pubkey mismatch')).encode());
      throw ProtocolException(
        RejectReason.ownerPubkeyMismatch,
        'presented pubkey does not hash to the proof\'s owner_pubkey',
      );
    }

    final nonce = _randomBytes(32);
    final responseFrame = await _request(Frame(MsgType.challenge, nonce));
    if (responseFrame.type != MsgType.challengeResponse) {
      throw ProtocolException(RejectReason.invalidSignature, 'expected challengeResponse, got ${responseFrame.type}');
    }

    final digest = await buildChallengeDigest(
      nonce: nonce,
      proofPublicInputs: publicInputsSlice(proofBytes),
      matchId: matchId,
    );
    final sigOk = await Identity.verify(
      message: digest,
      signatureBytes: responseFrame.payload,
      publicKeyBytes: presentedPubkey,
    );
    if (!sigOk) {
      _transport.send(Frame(MsgType.reject, utf8.encode('invalid signature')).encode());
      throw ProtocolException(RejectReason.invalidSignature, 'ownership challenge signature did not verify');
    }

    _transport.send(Frame(MsgType.accept, Uint8List(0)).encode());
    return VerifiedPresentation(presentedPubkey: presentedPubkey, proofBytes: proofBytes);
  }
}
