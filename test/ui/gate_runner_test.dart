// SPDX-License-Identifier: GPL-3.0-or-later
//
// gate_runner_test.dart — confirms the M4 two-device gate harness's
// orchestration logic (gate_runner.dart) against the real stack: real
// on-device proving (tier-12, cached SRS), real Ed25519 identity, and real
// MatchSession protocol exchange over real localhost TCP sockets. This is
// the one piece of confidence available before the actual two-device run,
// which this test cannot substitute for (real mDNS, real radios, real
// second device) -- but it does confirm GateRunner's wiring and step
// reporting are correct against everything that *can* run here.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ffi/prover.dart' as prover;
import 'package:rune_duel/ffi/srs_cache.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';
import 'package:rune_duel/protocol/match_session.dart';
import 'package:rune_duel/protocol/wire.dart';
import 'package:rune_duel/spells/inscribe.dart' show rulesetVersionHex;
import 'package:rune_duel/ui/gate_runner.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

Future<(LanSocketTransport, LanSocketTransport)> _localhostPair() async {
  final listener = await LanSocketTransport.bind(address: InternetAddress.loopbackIPv4);
  final acceptFuture = listener.acceptOnce();
  final client = await LanSocketTransport.connectTo('127.0.0.1', listener.port);
  final server = await acceptFuture;
  return (client, server);
}

Future<Uint8List> _loadVk() async {
  final data = await rootBundle.load(kGateVkAsset);
  return data.buffer.asUint8List();
}

/// Records every (key, state, detail) transition, plus the latest state per
/// key for simple assertions.
class _StepRecorder {
  final transitions = <(String, GateStepState, String?)>[];
  final latest = <String, GateStepState>{};

  void onStep(String key, GateStepState state, String? detail) {
    transitions.add((key, state, detail));
    latest[key] = state;
  }

  void onLog(String step, Object value, String? detail) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // runProverFlow calls Identity.loadOrCreate(), which needs secure
    // storage -- not reachable under `flutter test` for real (see
    // docs/M4_findings.md M4.2: flutter_secure_storage_linux is native-only,
    // never registered under the headless test engine).
    installFakeSecureStorage();
    // Shared across both tests (one fake app-support dir, set up once) so
    // the SRS downloads from crs.aztec.network exactly once for this whole
    // file, not once per test -- initSrsCached writes the cache file to it
    // after the first call, and the second test's call is then a cache hit.
    await installFakePathProvider();
  });

  test(
    'happy path: prover and verifier both reach ACCEPTED, with correct granular steps',
    () async {
      final (tProver, tVerifier) = await _localhostPair();

      final verifierAcceptFuture = MatchSession.accept(tVerifier);
      final proverSession = await MatchSession.initiate(tProver);
      final verifierSession = await verifierAcceptFuture;

      final proverRecorder = _StepRecorder();
      final verifierRecorder = _StepRecorder();
      final circuitJson = await rootBundle.loadString(kGateCircuitAsset);
      final cachePath = await srsCachePath();

      final proverRunner = GateRunner(onStep: proverRecorder.onStep, onLog: proverRecorder.onLog, loadVk: _loadVk);
      final verifierRunner = GateRunner(
        onStep: verifierRecorder.onStep,
        onLog: verifierRecorder.onLog,
        loadVk: _loadVk,
      );

      await Future.wait([
        proverRunner.runProverFlow(session: proverSession, circuitJson: circuitJson, srsCachePath: cachePath),
        verifierRunner.runVerifierFlow(session: verifierSession, circuitJson: circuitJson, srsCachePath: cachePath),
      ]);

      expect(proverRecorder.latest['final'], GateStepState.pass);
      expect(verifierRecorder.latest['final'], GateStepState.pass);

      expect(proverRecorder.latest['proof_generated'], GateStepState.pass);
      final proofGenDetail = proverRecorder.transitions.lastWhere((t) => t.$1 == 'proof_generated').$3;
      expect(proofGenDetail, contains('wall_ms='));

      // proof_verified is the one step with genuine live visibility (the
      // injected verifyProof callback) -- confirm it actually fired, not
      // just that the overall call succeeded.
      expect(verifierRecorder.latest['proof_verified'], GateStepState.pass);
      expect(verifierRecorder.latest['owner_pubkey_matched'], GateStepState.pass);
      expect(verifierRecorder.latest['challenge_signature'], GateStepState.pass);

      await proverSession.close();
      await verifierSession.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'rejection path: a real, valid proof presented under the wrong pubkey fails at '
    'owner_pubkey_matched specifically, not proof_verified',
    () async {
      // A real, independently-proven proof (own prove cycle -- not shared
      // with the happy-path test above) bound to Alice's owner_pubkey.
      final alice = await Identity.ephemeral();
      final circuitJson = await rootBundle.loadString(kGateCircuitAsset);
      final bytecode = await prover.extractBytecode(circuitJson);
      final cachePath = await srsCachePath();
      await prover.initSrsCached(bytecode, cachePath: cachePath);
      final vk = await _loadVk();
      final ownerPubkeyHex = await alice.ownerPubkeyHex();
      final timedResult = await prover.proveAndTime(
        bytecode,
        kGateGrid,
        keyHiHex: alice.keyHiHex,
        keyLoHex: alice.keyLoHex,
        tHex: kGateTHex,
        ownerPubkeyHex: ownerPubkeyHex,
        rulesetVersionHex: rulesetVersionHex,
        vkBytes: vk,
      );
      final realProofBytes = timedResult.proofBytes;

      final mallory = await Identity.ephemeral();
      final (tMallory, tVerifier) = await _localhostPair();

      final verifierAcceptFuture = MatchSession.accept(tVerifier);
      final malloryReader = FrameReader();
      tMallory.onReceive.listen(malloryReader.addChunk);
      tMallory.send(Frame(MsgType.hello, Uint8List(16)).encode());
      await malloryReader.frames.first; // helloAck
      final verifierSession = await verifierAcceptFuture;

      final verifierRecorder = _StepRecorder();
      final verifierRunner = GateRunner(
        onStep: verifierRecorder.onStep,
        onLog: verifierRecorder.onLog,
        loadVk: _loadVk,
      );

      final verifyFuture = verifierRunner.runVerifierFlow(
        session: verifierSession,
        circuitJson: circuitJson,
        srsCachePath: cachePath,
      );

      // The real, cryptographically valid proof above, but presented with
      // Mallory's pubkey instead of Alice's -- verify_ultra_honk must pass
      // (the proof itself is genuinely valid), but the owner_pubkey
      // recompute must fail (Mallory's key doesn't hash to the proof's
      // owner_pubkey).
      tMallory.send(
        Frame(MsgType.proofPresentation, lengthPrefixedConcat([mallory.publicKeyBytes, realProofBytes])).encode(),
      );

      await verifyFuture;

      expect(verifierRecorder.latest['proof_verified'], GateStepState.pass);
      expect(verifierRecorder.latest['owner_pubkey_matched'], GateStepState.fail);
      expect(verifierRecorder.latest['final'], GateStepState.fail);

      await verifierSession.close();
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
