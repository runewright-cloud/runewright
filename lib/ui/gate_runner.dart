// SPDX-License-Identifier: GPL-3.0-or-later
//
// gate_runner.dart — pure async orchestration for the M4 two-device gate
// harness (gate_screen.dart). Separated from the widget so the exchange
// logic is independently testable without driving a real GUI.
//
// This is wiring, not new protocol logic: every call here is to an
// existing, already-tested entry point (MatchSession, the FFI prover,
// Identity). See gate_screen.dart's file header for why most step results
// below are reconstructed from a thrown ProtocolException's
// (reason, message) or from successful completion, rather than from live
// mid-call callbacks -- match_session.dart is not modified to add
// progress hooks. The one step with genuine live visibility
// ("proof_verified") uses the `verifyProof` injection seam
// `verifyIncomingProof` already exposed for testing.

import 'dart:typed_data';

import '../ffi/prover.dart' as prover;
import '../identity/identity.dart';
import '../protocol/match_session.dart';

enum GateRole { proverSigner, verifierChallenger }

enum GateStepState { pending, running, pass, fail, skip }

/// Canonical step keys, in display order -- identical list shown regardless
/// of role, with role-inapplicable steps marked `skip` rather than hidden,
/// so both devices' screens read the same shape side by side.
const List<String> kGateStepOrder = [
  'connect',
  'handshake',
  'identity', // prover only
  'vk', // verifier only
  'proof_generated', // prover only, wall-clock ms
  'proof_sent', // prover: sent / verifier: received
  'proof_verified', // verifier only, live via injected verifyProof
  'owner_pubkey_matched',
  'challenge_signature', // challenge issued + signature returned + verified
  'final',
];

typedef GateStepCallback = void Function(String key, GateStepState state, String? detail);
typedef GateLogCallback = void Function(String step, Object value, String? detail);

/// Mutable display model for one step row (gate_screen.dart renders one
/// per [kGateStepOrder] entry).
class GateStep {
  GateStep(this.key);
  final String key;
  GateStepState state = GateStepState.pending;
  String? detail;
}

/// Fixed, known-good witness reused from the M3.4 on-device gate
/// (spike_screen.dart): all-zero grid, T=1. Proven to prove+verify
/// end-to-end already -- the only thing this harness changes is using a
/// real identity's key_hi/key_lo/owner_pubkey instead of the zero stub.
final List<int> kGateGrid = List<int>.filled(469, 0);
const kGateTHex = '0x1';
const kGateRulesetVersionHex = '0x1';
const kGateCircuitAsset = 'assets/circuits/ca_v2_4_tier12.json';
const kGateVkAsset = 'assets/circuits/ca_v2_4_tier12.vk';

class GateRunner {
  GateRunner({required this.onStep, required this.onLog, required this.loadVk});

  final GateStepCallback onStep;
  final GateLogCallback onLog;

  /// Loads the tier-12 VK bytes. Production: the bundled asset
  /// (`rootBundle.load(kGateVkAsset)`, same as spike_screen.dart) -- passed
  /// in rather than called directly so this class has no Flutter-widget
  /// dependency and is testable without driving a real GUI.
  final Future<Uint8List> Function() loadVk;

  void _step(String key, GateStepState state, [String? detail]) => onStep(key, state, detail);
  void _log(String step, Object value, [String? detail]) => onLog(step, value, detail);

  /// Prover/signer role: load identity, prove the fixed witness, present
  /// it over [session], and report the outcome.
  ///
  /// [srsCachePath] is the on-disk SRS cache file (see
  /// `lib/ffi/srs_cache.dart`'s `srsCachePath()`) -- first run on a device
  /// downloads over the network and writes this file; every run after that
  /// reads it instead. Distinct from the now-dead `initSrs(srsPath:)`
  /// parameter (silently ignored, see that function's doc comment) -- this
  /// harness uses the real player-facing `initSrsCached` path.
  Future<void> runProverFlow({
    required MatchSession session,
    required String circuitJson,
    required String srsCachePath,
  }) async {
    try {
      _step('vk', GateStepState.skip, 'n/a (prover role)');

      _step('identity', GateStepState.running, 'loading...');
      final identity = await Identity.loadOrCreate();
      final ownerPubkeyHex = await identity.ownerPubkeyHex();
      _step('identity', GateStepState.pass, 'pubkey=${_hexPreview(identity.publicKeyBytes)}');
      _log('identity_loaded', true, 'owner_pubkey=$ownerPubkeyHex');

      _step('proof_generated', GateStepState.running, 'proving tier-12 (known-good fixed witness)...');
      final bytecode = await prover.extractBytecode(circuitJson);
      await prover.initSrsCached(bytecode, cachePath: srsCachePath);
      final vk = await loadVk();
      final result = await prover.proveAndTime(
        bytecode,
        kGateGrid,
        keyHiHex: identity.keyHiHex,
        keyLoHex: identity.keyLoHex,
        tHex: kGateTHex,
        ownerPubkeyHex: ownerPubkeyHex,
        rulesetVersionHex: kGateRulesetVersionHex,
        vkBytes: vk,
      );
      _step('proof_generated', GateStepState.pass, 'wall_ms=${result.wallMs} proof_len=${result.proofBytes.length}B');
      _log('proof_generated', true, 'wall_ms=${result.wallMs}');

      _step('proof_sent', GateStepState.running, 'sending, awaiting ownership challenge...');
      _log('proof_sent', true, null);
      await session.presentProof(identity: identity, proofBytes: result.proofBytes);

      // presentProof only returns once the verifier has fully accepted:
      // verify_ultra_honk passed, owner_pubkey recompute matched, and the
      // ownership-challenge signature verified. See match_session.dart.
      _step('proof_sent', GateStepState.pass, 'verifier received and processed the proof');
      _step('owner_pubkey_matched', GateStepState.pass, 'true (implied by acceptance)');
      _step('challenge_signature', GateStepState.pass, 'challenge answered, signature accepted');
      _step('final', GateStepState.pass, 'ACCEPTED');
      _log('signature_returned', true, null);
      _log('final', 'accepted', null);
    } on ProtocolException catch (e) {
      _handleProverRejection(e);
    } catch (e) {
      _step('final', GateStepState.fail, '$e');
      _log('final', 'error', '$e');
    }
  }

  void _handleProverRejection(ProtocolException e) {
    _log('final', 'rejected', '${e.reason} ${e.message}');
    switch (e.reason) {
      case RejectReason.invalidProof:
        _step('proof_sent', GateStepState.fail, 'verifier rejected the proof: ${e.message}');
        _step('owner_pubkey_matched', GateStepState.skip, 'not reached');
        _step('challenge_signature', GateStepState.skip, 'not reached');
      case RejectReason.ownerPubkeyMismatch:
        _step('proof_sent', GateStepState.pass, 'verifier accepted the proof');
        _step('owner_pubkey_matched', GateStepState.fail, e.message);
        _step('challenge_signature', GateStepState.skip, 'not reached');
      case RejectReason.invalidSignature:
        _step('proof_sent', GateStepState.pass, 'verifier accepted the proof');
        _step('owner_pubkey_matched', GateStepState.pass, 'true');
        _step('challenge_signature', GateStepState.fail, e.message);
      case RejectReason.handshakeFailed:
        _step('handshake', GateStepState.fail, e.message);
    }
    _step('final', GateStepState.fail, 'REJECTED (${e.reason.name}): ${e.message}');
  }

  /// Verifier/challenger role: await the peer's proof, verify it, recompute
  /// owner_pubkey, issue the ownership challenge, and report the outcome.
  ///
  /// **Real bug found via the two-device hardware run (not harness-only):**
  /// `verify_ultra_honk` needs barretenberg's global CRS initialized via a
  /// prior `srs_init` call -- on the prove side this always happens
  /// incidentally (proving calls `initSrsCached` first), but a pure
  /// verifier that never proves in that session never initializes it,
  /// and verification fails with "Backend error: You need to initialize
  /// the global CRS with a call to init_crs_factory(...)". This affects the
  /// *real* match protocol too, not just this harness: any real duel
  /// verifier who hasn't proven anything yet in that app session would hit
  /// the same failure. Fix: the verifier also calls `initSrsCached` (sized
  /// to the same circuit) before verifying, even though it never proves.
  Future<void> runVerifierFlow({
    required MatchSession session,
    required String circuitJson,
    required String srsCachePath,
  }) async {
    try {
      _step('identity', GateStepState.skip, 'n/a (verifier role)');
      _step('proof_generated', GateStepState.skip, 'n/a (verifier role)');

      _step('vk', GateStepState.running, 'loading VK asset + initializing CRS...');
      final vk = await loadVk();
      final bytecode = await prover.extractBytecode(circuitJson);
      await prover.initSrsCached(bytecode, cachePath: srsCachePath);
      _step('vk', GateStepState.pass, '${vk.length} bytes, CRS initialized');

      _step('proof_sent', GateStepState.running, "waiting for peer's proof...");

      final verified = await session.verifyIncomingProof(
        verifyProof: (vkBytes, proofBytes) async {
          _step('proof_sent', GateStepState.pass, 'proof received (${proofBytes.length}B)');
          _log('proof_received', true, '${proofBytes.length}B');
          _step('proof_verified', GateStepState.running, 'calling verify_ultra_honk...');
          final ok = await prover.verifyProof(vkBytes, proofBytes);
          _step('proof_verified', ok ? GateStepState.pass : GateStepState.fail, '$ok');
          _log('proof_verified', ok, null);
          return ok;
        },
        vkBytes: vk,
      );

      // verifyIncomingProof only returns once every check passed: proof
      // verified live above, owner_pubkey recomputed & matched, and the
      // ownership-challenge signature verified. See match_session.dart.
      _step('owner_pubkey_matched', GateStepState.pass, 'true');
      _step('challenge_signature', GateStepState.pass, 'challenge issued, signature verified');
      _step('final', GateStepState.pass, 'ACCEPTED, presented pubkey=${_hexPreview(verified.presentedPubkey)}');
      _log('owner_pubkey_matched', true, null);
      _log('challenge_issued', true, null);
      _log('signature_verified', true, null);
      _log('final', 'accepted', null);
    } on ProtocolException catch (e) {
      _handleVerifierRejection(e);
    } catch (e) {
      _step('final', GateStepState.fail, '$e');
      _log('final', 'error', '$e');
    }
  }

  void _handleVerifierRejection(ProtocolException e) {
    _log('final', 'rejected', '${e.reason} ${e.message}');
    switch (e.reason) {
      case RejectReason.invalidProof:
        // proof_verified already set to fail live, inside the callback.
        _step('owner_pubkey_matched', GateStepState.skip, 'not reached');
        _step('challenge_signature', GateStepState.skip, 'not reached');
      case RejectReason.ownerPubkeyMismatch:
        _step('owner_pubkey_matched', GateStepState.fail, e.message);
        _log('owner_pubkey_matched', false, e.message);
        _step('challenge_signature', GateStepState.skip, 'not reached');
      case RejectReason.invalidSignature:
        _step('owner_pubkey_matched', GateStepState.pass, 'true');
        _log('owner_pubkey_matched', true, null);
        _step('challenge_signature', GateStepState.fail, e.message);
        _log('signature_verified', false, e.message);
      case RejectReason.handshakeFailed:
        _step('handshake', GateStepState.fail, e.message);
    }
    _step('final', GateStepState.fail, 'REJECTED (${e.reason.name}): ${e.message}');
  }
}

String _hexPreview(List<int> bytes) {
  final hex = bytes.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '0x$hex…';
}

