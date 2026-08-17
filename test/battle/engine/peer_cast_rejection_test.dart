// SPDX-License-Identifier: GPL-3.0-or-later
//
// peer_cast_rejection_test.dart — characterization of the peer-cast trust
// boundary's rejection branches.
//
// `_verifyPeerSpellCast` can reject a peer's cast for twelve distinct reasons,
// each with its own `sendForfeit` tag that BattleScreen renders back to the
// player. Six of those tags were pinned by existing tests when this file was
// written:
//
//   missing_spell_proof        proofless_spell_flag_test
//   ruleset_version_mismatch   ruleset_version_bind_test
//   duplicate_spell_cast       basic_spell_duplicate_chapter_test + replay
//   unbacked_enhancement_claim replay golden unbacked_mystery_claim_forfeits
//   cast_out_of_hand           spell_draw_wiring_test
//   unauthorized_spell         turn_loop_cast_authorization_test
//
// The other six were not pinned anywhere. They are covered here, at the same
// altitude as the existing ones (a real two-client turn through
// TurnSessionPair), asserting BOTH the exact forfeit tag the peer receives and
// the StateError the local turn aborts with — the two externally visible
// artifacts of a rejection.
//
// These are characterization tests: they describe what the code does today so
// the trust surface can be moved behind `PeerCastVerifier` without silently
// changing which rejection fires, or what it is called.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;
import 'package:rune_duel/spells/spell_asset.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

/// A verifier stub that rejects every proof, for the `invalid_spell_proof`
/// branch. The counterpart to the fixture's [alwaysOk].
Future<bool> alwaysFails(Uint8List vk, Uint8List proof) async => false;

/// A spell whose wire fields and proof fields can be driven apart
/// independently — which is the whole point at a trust boundary, since
/// nothing but the proof binds any of them.
///
/// [wireT] / [wireCommitmentByte] are what the caster *declares*;
/// [proofT] / [proofCommitmentByte] are what the proof *attests*. They default
/// to agreeing, so a test only sets the one field it is driving apart.
SpellAsset fixture({
  required String id,
  int wireT = 3,
  int? proofT,
  int wireCommitmentByte = 0x70,
  int? proofCommitmentByte,
  int tier = 12,
  int? wireTier,
}) {
  final elements = List.filled(kActivations, BorderZone.earth);
  final commitBytes = Uint8List.fromList(List.filled(32, wireCommitmentByte));
  final proofCommitBytes = Uint8List.fromList(
    List.filled(32, proofCommitmentByte ?? wireCommitmentByte),
  );
  String hexOf(Uint8List b) =>
      '0x${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';

  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 17),
    tier: wireTier ?? tier,
    t: wireT,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: 0,
    segmentCount: kSegmentCount,
    dotCount: kDotCount,
    initialGrid: const [],
    proofBytes: syntheticProof(
      tier: tier,
      t: proofT ?? wireT,
      commitmentBytes: proofCommitBytes,
      rulesetVersion: kRulesetVersion,
      elements: elements,
    ),
    name: id,
    commitmentHex: hexOf(commitBytes),
    spellHashHex: '',
    formula: [for (final e in elements) e.name],
  );
}

void main() {
  /// Runs one turn in which `player_a` casts [spell] and `player_b` — the
  /// device under test — rejects it. Returns the forfeit tag `player_b` sent
  /// and asserts the StateError message it aborted with contains [message].
  ///
  /// The caster's `runTurn` is started unawaited: the verifier aborts partway
  /// through resolution, so no reply ever comes for the exchange after it and
  /// awaiting the caster directly would hang. Same shape as
  /// ruleset_version_bind_test.dart's harness.
  Future<String> forfeitTagFor(
    SpellAsset spell, {
    required String message,
    String? peerBookRoot,
    Uint8List? Function(int tier)? vkBytesForTier,
    Future<bool> Function(Uint8List, Uint8List) verifyProof = alwaysOk,
  }) async {
    // A per-tier resolver replaces the match-wide key rather than sitting
    // alongside it — otherwise the empty fallback would satisfy every lookup
    // and `missing_vk_for_tier` would be unreachable.
    final vkBytes = vkBytesForTier == null ? Uint8List(0) : null;
    final pair = TurnSessionPair();
    final loopCaster = TurnLoop(
      state: makeDuelState(),
      session: pair.sessionA,
      localPlayerId: 'player_a',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    )..localChapterCommitments = [spell.commitmentHex];
    final loopPeer = TurnLoop(
      state: makeDuelState(),
      session: pair.sessionB,
      localPlayerId: 'player_b',
      verifyProof: verifyProof,
      vkBytes: vkBytes,
      vkBytesForTier: vkBytesForTier,
      peerBookRoot: peerBookRoot,
    );

    unawaited(loopCaster
        .runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        ))
        .catchError((Object _) => null));

    await expectLater(
      loopPeer.runTurn(TurnInput(action: PassAction())),
      throwsA(isA<StateError>()
          .having((e) => e.toString(), 'message', contains(message))),
    );

    // The tag the OTHER device actually receives, which is what BattleScreen
    // switches on to explain the loss.
    return pair.sessionA.peerForfeit.timeout(const Duration(seconds: 5));
  }

  test('a declared T outside the circuit range forfeits: invalid_spell_tier',
      () async {
    // 49 > kMaxInscribableSteps, so no tier covers it and no VK could ever be
    // selected. Rejected before the proof is even parsed — the tier choice is
    // what picks the parse layout.
    final tag = await forfeitTagFor(
      fixture(id: 'over-tier', wireT: 49, proofT: 3, tier: 48, wireTier: 48),
      message: 'outside the circuit range',
    );
    expect(tag, equals('invalid_spell_tier'));
  });

  test('no bundled VK for the spell\'s tier forfeits: missing_vk_for_tier',
      () async {
    // A per-tier resolver that has no key for this tier, and no match-wide
    // fallback. Distinct from "verification not wired up" (both null), which
    // returns early and certifies nothing instead of forfeiting.
    final tag = await forfeitTagFor(
      fixture(id: 'no-vk'),
      message: 'no bundled verification key for tier',
      vkBytesForTier: (_) => null,
    );
    expect(tag, equals('missing_vk_for_tier'));
  });

  test('a proof the backend rejects forfeits: invalid_spell_proof', () async {
    final tag = await forfeitTagFor(
      fixture(id: 'bad-proof'),
      message: 'peer spell proof rejected',
      verifyProof: alwaysFails,
    );
    expect(tag, equals('invalid_spell_proof'));
  });

  test('a proof certifying a different T than the wire declares forfeits: '
      't_mismatch', () async {
    // Both Ts land in tier 12, so the VK selection and the parse layout both
    // succeed and the binding check is genuinely what rejects — not a
    // downstream parse failure wearing its name.
    final tag = await forfeitTagFor(
      fixture(id: 't-lie', wireT: 2, proofT: 3),
      message: 'but the wire declared T=',
    );
    expect(tag, equals('t_mismatch'));
  });

  test('a proof certifying a different commitment than the wire declares '
      'forfeits: commitment_mismatch', () async {
    final tag = await forfeitTagFor(
      fixture(
        id: 'commit-lie',
        wireCommitmentByte: 0x71,
        proofCommitmentByte: 0x72,
      ),
      message: 'does not match wire value',
    );
    expect(tag, equals('commitment_mismatch'));
  });

  test('a spell outside the peer\'s committed book forfeits: '
      'book_membership_failed', () async {
    final spell = fixture(id: 'not-a-member', wireCommitmentByte: 0x73);
    // A root over somebody else's chapter: the membership path the caster
    // sends is well-formed and proves membership of ITS OWN root, just not
    // of the one committed at handshake.
    final foreignRoot = BookCommitment.computeRoot([
      '0x${'aa' * 32}',
      '0x${'bb' * 32}',
    ]);
    final tag = await forfeitTagFor(
      spell,
      message: 'is not a member of their committed book',
      peerBookRoot: foreignRoot,
    );
    expect(tag, equals('book_membership_failed'));
  });
}
