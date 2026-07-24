// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_cast_authorization_test.dart — Stage 2 (LAN_BATTLE_WIREUP_PLAN.md
// §4 item 3): _verifyPeerSpellCast's cast-authorization wiring
// (BATTLE_AUTH_PLAN.md §4). castingPlayerMayUse itself is already
// comprehensively unit-tested at the pure-function level
// (test/spells/spell_authorization_test.dart) — these tests cover the
// INTEGRATION: does TurnLoop actually pass peerOwnerPubkeyHex/peerPermissions
// through and forfeit+throw when authorization fails, for a real (if
// synthetic) proof decoded off the wire.
//
// Uses a synthetic proof (like turn_loop_determinism_test.dart's own wire-
// round-trip test) with `verifyProof: alwaysOk` — a stub, not real FFI
// verification — because these tests are about the AUTHORIZATION layer
// (peerOwnerPubkeyHex/peerPermissions), which sits after proof verification
// and doesn't care whether the proof was cryptographically real; the real-
// FFI-proof path is separately covered by turn_loop_proof_verification_test.dart.

import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/transport.dart';
import 'package:rune_duel/spells/spell_asset.dart';
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

  BattleState makeAdjacentState(String casterHex, String verifierHex) {
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

  /// A synthetic proof declaring [ownerPubkeyHex] as its owner_pubkey public
  /// input, matching turn_loop_determinism_test.dart's `_syntheticProofFor`
  /// but extended with a controllable owner field (that helper leaves owner
  /// at all-zero, which isn't useful for authorization testing).
  Uint8List syntheticProofFor({
    required int tier,
    required int t,
    required Uint8List commitmentBytes,
    required String ownerPubkeyHex,
  }) {
    final count = 10 + 2 * tier;
    final bytes = Uint8List(4 + count * 32 + 1);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, count, Endian.big);
    data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
    final ownerHexStripped =
        ownerPubkeyHex.startsWith('0x') ? ownerPubkeyHex.substring(2) : ownerPubkeyHex;
    final ownerPadded = ownerHexStripped.padLeft(64, '0');
    for (var i = 0; i < 32; i++) {
      bytes[4 + 1 * 32 + i] = int.parse(ownerPadded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
    bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3: commitment
    // segmentCount/dotCount left at 0 -- a "whiff" cast, no effect resolution
    // surprises unrelated to what this test checks.
    return bytes;
  }

  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  ({TurnLoop caster, TurnLoop verifier, Transport transportCaster, Transport transportVerifier})
      buildLoopPair({
    required String casterOwnerHex,
    required String peerOwnerPubkeyHex,
    required List<SpellPermission> peerPermissions,
    required String commitmentHex,
  }) {
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportCaster, transportVerifier) = InMemoryTransport.pair();
    final sessionCaster = BattleSession(transportCaster, matchId);
    final sessionVerifier = BattleSession(transportVerifier, matchId);

    final stateCaster = makeAdjacentState(casterOwnerHex, peerOwnerPubkeyHex);
    final stateVerifier = makeAdjacentState(casterOwnerHex, peerOwnerPubkeyHex);

    // Required so _encodeAction attaches the proof + membership-proof tail
    // to the outgoing wire action -- without this, the caster sends NO
    // proof bytes at all and the verifier forfeits on missing_spell_proof
    // regardless of what this test is actually trying to check (found the
    // hard way: a "success" test hung because both sides forfeited/threw
    // in ways that don't reach the exchanges each side then waited on).
    final loopCaster = TurnLoop(
      state: stateCaster,
      session: sessionCaster,
      localPlayerId: 'caster',
      matchId: matchId,
      tier: 12,
    )..localChapterCommitments = [commitmentHex];
    final loopVerifier = TurnLoop(
      state: stateVerifier,
      session: sessionVerifier,
      localPlayerId: 'verifier',
      matchId: matchId,
      tier: 12,
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
      peerOwnerPubkeyHex: peerOwnerPubkeyHex,
      peerPermissions: peerPermissions,
    );
    return (
      caster: loopCaster,
      verifier: loopVerifier,
      transportCaster: transportCaster,
      transportVerifier: transportVerifier,
    );
  }

  /// Runs one turn expecting BOTH sides to complete normally: `caster` casts
  /// [spell]; `verifier` passes and authorizes the cast. Returns the
  /// verifier loop so callers can inspect lastResolvedSpells.
  Future<TurnLoop> runCastExpectingSuccess({
    required SpellAsset spell,
    required String peerOwnerPubkeyHex,
    required List<SpellPermission> peerPermissions,
  }) async {
    final pair = buildLoopPair(
      casterOwnerHex: spell.ownerPubkeyHex,
      peerOwnerPubkeyHex: peerOwnerPubkeyHex,
      peerPermissions: peerPermissions,
      commitmentHex: spell.commitmentHex,
    );
    await Future.wait([
      pair.caster.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
      )),
      pair.verifier.runTurn(TurnInput(action: PassAction())),
    ]);
    await pair.transportCaster.disconnect();
    await pair.transportVerifier.disconnect();
    return pair.verifier;
  }

  /// Runs one turn expecting the VERIFIER to reject the cast (forfeit +
  /// throw) partway through resolution. The caster's own `runTurn` never
  /// gets an answering reply for whatever exchange comes after resolution
  /// (melee/free-move/state-hash — the verifier already aborted before
  /// reaching them), so it would hang forever if awaited directly; this
  /// starts it unawaited with errors swallowed and only awaits the
  /// verifier's side, which is the one under test.
  Future<void> expectVerifierRejects({
    required SpellAsset spell,
    required String peerOwnerPubkeyHex,
    required List<SpellPermission> peerPermissions,
  }) async {
    final pair = buildLoopPair(
      casterOwnerHex: spell.ownerPubkeyHex,
      peerOwnerPubkeyHex: peerOwnerPubkeyHex,
      peerPermissions: peerPermissions,
      commitmentHex: spell.commitmentHex,
    );
    unawaited(pair.caster.runTurn(TurnInput(
      action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
    )).catchError((Object _) => null));

    // Specifically the authorization rejection, not just any StateError —
    // a too-loose assertion here previously let a "missing_spell_proof"
    // test bug (proof tail never attached) pass for the wrong reason.
    await expectLater(
      pair.verifier.runTurn(TurnInput(action: PassAction())),
      throwsA(isA<StateError>().having(
        (e) => e.toString(),
        'message',
        contains('neither own nor hold a grant'),
      )),
    );

    await pair.transportCaster.disconnect();
    await pair.transportVerifier.disconnect();
  }

  test('a forged-owner cast with no covering permission forfeits and throws',
      () async {
    final foreignOwnerIdentity = await Identity.ephemeral();
    final peerIdentity = await Identity.ephemeral(); // the authenticated caster
    final foreignOwnerHex = await foreignOwnerIdentity.ownerPubkeyHex();
    final peerOwnerHex = await peerIdentity.ownerPubkeyHex();

    final commitmentBytes = Uint8List.fromList(List.filled(32, 0xAB));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    final spell = SpellAsset(
      id: 'forged-owner-spell',
      createdAt: DateTime.utc(2026, 7, 20),
      tier: 12,
      t: 1,
      ownerPubkeyHex: foreignOwnerHex, // wire-trust value; irrelevant to the check
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProofFor(
        tier: 12,
        t: 1,
        commitmentBytes: commitmentBytes,
        ownerPubkeyHex: foreignOwnerHex, // the PROOF declares this owner
      ),
      name: 'Forged Owner Spell',
      commitmentHex: commitmentHex,
      spellHashHex: '',
      formula: const [],
    );

    await expectVerifierRejects(
      spell: spell,
      peerOwnerPubkeyHex: peerOwnerHex, // caster's AUTHENTICATED identity
      peerPermissions: const [], // no grant covers this cast
    );
  });

  test('a forged-owner cast backed by a valid, unexpired loan grant is '
      'authorized', () async {
    final foreignOwnerIdentity = await Identity.ephemeral();
    final peerIdentity = await Identity.ephemeral();
    final foreignOwnerHex = await foreignOwnerIdentity.ownerPubkeyHex();
    final peerOwnerHex = await peerIdentity.ownerPubkeyHex();

    final commitmentBytes = Uint8List.fromList(List.filled(32, 0xCD));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    final spell = SpellAsset(
      id: 'loaned-spell',
      createdAt: DateTime.utc(2026, 7, 20),
      tier: 12,
      t: 1,
      ownerPubkeyHex: foreignOwnerHex,
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProofFor(
        tier: 12,
        t: 1,
        commitmentBytes: commitmentBytes,
        ownerPubkeyHex: foreignOwnerHex,
      ),
      name: 'Loaned Spell',
      commitmentHex: commitmentHex,
      spellHashHex: '',
      formula: const [],
    );

    final grant = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: foreignOwnerIdentity,
      granteePubkeyHex: peerOwnerHex,
      kind: SpellGrantKind.loan,
      expiresAt: DateTime.utc(2027, 1, 1), // unexpired
    );

    final verifierLoop = await runCastExpectingSuccess(
      spell: spell,
      peerOwnerPubkeyHex: peerOwnerHex,
      peerPermissions: [grant],
    );

    expect(verifierLoop.lastResolvedSpells, hasLength(1));
    expect(
      verifierLoop.lastResolvedSpells.single.spell.commitmentHex,
      equals(spell.commitmentHex),
    );
  });

  test('a forged-owner cast backed by an EXPIRED loan grant forfeits and '
      'throws', () async {
    final foreignOwnerIdentity = await Identity.ephemeral();
    final peerIdentity = await Identity.ephemeral();
    final foreignOwnerHex = await foreignOwnerIdentity.ownerPubkeyHex();
    final peerOwnerHex = await peerIdentity.ownerPubkeyHex();

    final commitmentBytes = Uint8List.fromList(List.filled(32, 0xEF));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    final spell = SpellAsset(
      id: 'expired-loan-spell',
      createdAt: DateTime.utc(2026, 7, 20),
      tier: 12,
      t: 1,
      ownerPubkeyHex: foreignOwnerHex,
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProofFor(
        tier: 12,
        t: 1,
        commitmentBytes: commitmentBytes,
        ownerPubkeyHex: foreignOwnerHex,
      ),
      name: 'Expired Loan Spell',
      commitmentHex: commitmentHex,
      spellHashHex: '',
      formula: const [],
    );

    final expiredGrant = await SpellPermission.createAndSign(
      spell: spell,
      ownerIdentity: foreignOwnerIdentity,
      granteePubkeyHex: peerOwnerHex,
      kind: SpellGrantKind.loan,
      expiresAt: DateTime.utc(2020, 1, 1), // already expired
    );

    await expectVerifierRejects(
      spell: spell,
      peerOwnerPubkeyHex: peerOwnerHex,
      peerPermissions: [expiredGrant],
    );
  });
}
