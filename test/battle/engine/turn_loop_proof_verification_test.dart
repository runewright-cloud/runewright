// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_proof_verification_test.dart — Stage 2 (LAN_BATTLE_WIREUP_PLAN.md
// §4): a REAL FFI-proven spell cast, verified end-to-end through TurnLoop's
// verifyProof/vkBytes/peerBookRoot/peerOwnerPubkeyHex path — not the
// synthetic/hand-crafted proof bytes turn_loop_determinism_test.dart's wire-
// round-trip test uses (that test deliberately stubs verification to isolate
// wire-format concerns). This is the "real-device proof round trip" the plan
// asks for, run over real BattleSessions (paired InMemoryTransport, like
// auth_handshake_test.dart), mirroring inscribe_test.dart's real prove/self-
// verify pattern but carrying the proof through an actual two-client duel.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/ffi/prover.dart' as prover;
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/inscribe.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  BattleState makeState(String casterHex, String verifierHex) {
    final battlefield = Battlefield();
    const posCaster = HexCoord(0, 0);
    const posVerifier = HexCoord(1, 0);
    battlefield.occupancy['caster'] = posCaster;
    battlefield.occupancy['verifier'] = posVerifier;
    return BattleState(
      config: const MatchConfig(),
      avatars: [
        WizardAvatar(
          playerId: 'caster',
          ownerPubkeyHex: casterHex,
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posCaster,
          teamId: 'team_caster',
          baseSpellRange: 3,
        ),
        WizardAvatar(
          playerId: 'verifier',
          ownerPubkeyHex: verifierHex,
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posVerifier,
          teamId: 'team_verifier',
          baseSpellRange: 3,
        ),
      ],
      teams: [
        const Team(id: 'team_caster', playerIds: ['caster']),
        const Team(id: 'team_verifier', playerIds: ['verifier']),
      ],
      battlefield: battlefield,
    );
  }

  test(
      'a real FFI-proven spell cast is proof-verified and cast-authorized '
      'end-to-end through TurnLoop', () async {
    final casterIdentity = await Identity.ephemeral();
    final verifierIdentity = await Identity.ephemeral();
    final casterOwnerHex = await casterIdentity.ownerPubkeyHex();
    final verifierOwnerHex = await verifierIdentity.ownerPubkeyHex();

    // Real proof: all-neutral grid, T=1, tier-12 — a deterministic "whiff"
    // cast (no certified activations), so resolution can't diverge for
    // reasons unrelated to what this test actually checks: does a REAL
    // proof survive verifyAndParse + cast authorization inside a real turn.
    final grid = HexGrid(12);
    final spell = await inscribeSpell(
      initialGrid: grid,
      steps: 1,
      identity: casterIdentity,
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      name: 'Verification Test Spell',
      loadCircuitJson: rootBundle.loadString,
      loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
    );
    expect(spell.tier, equals(12));
    expect(spell.ownerPubkeyHex, equals(casterOwnerHex));
    expect(spell.proofBytes, isNotEmpty);

    final vkBytes =
        (await rootBundle.load('assets/circuits/ca_v2_4_tier12.vk')).buffer.asUint8List();
    final peerBookRoot = BookCommitment.computeRoot([spell.commitmentHex]);

    final stateCaster = makeState(casterOwnerHex, verifierOwnerHex);
    final stateVerifier = makeState(casterOwnerHex, verifierOwnerHex);

    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportCaster, transportVerifier) = InMemoryTransport.pair();
    final sessionCaster = BattleSession(transportCaster, matchId);
    final sessionVerifier = BattleSession(transportVerifier, matchId);

    final loopCaster = TurnLoop(
      state: stateCaster,
      session: sessionCaster,
      localPlayerId: 'caster',
      matchId: matchId,
      tier: 12,
    )..localChapterCommitments = [spell.commitmentHex];
    final loopVerifier = TurnLoop(
      state: stateVerifier,
      session: sessionVerifier,
      localPlayerId: 'verifier',
      matchId: matchId,
      tier: 12,
      verifyProof: prover.verifyProof,
      vkBytes: vkBytes,
      peerBookRoot: peerBookRoot,
      peerOwnerPubkeyHex: casterOwnerHex,
      peerPermissions: const <SpellPermission>[],
    );

    await Future.wait([
      loopCaster.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
      )),
      loopVerifier.runTurn(TurnInput(action: PassAction())),
    ]);

    // The verifier actually verified the real proof and certified the cast
    // (not just trusted the wire bytes — verifyProof/vkBytes were real).
    expect(loopVerifier.lastResolvedSpells, hasLength(1));
    expect(
      loopVerifier.lastResolvedSpells.single.spell.commitmentHex,
      equals(spell.commitmentHex),
    );
    expect(loopVerifier.lastResolvedSpells.single.casterId, equals('caster'));

    // Both clients converge on identical canonical state.
    expect(stateCaster.toCanonicalBytes(), equals(stateVerifier.toCanonicalBytes()));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
