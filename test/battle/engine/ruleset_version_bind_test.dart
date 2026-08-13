// SPDX-License-Identifier: GPL-3.0-or-later
//
// ruleset_version_bind_test.dart — the negotiated ruleset epoch must actually
// gate something.
//
// `ProofIntake` has parsed `ruleset_version` since it was added and nothing
// ever read it, while `MatchConfig.rulesetVersion` still defaulted to a
// hardcoded 2 after the circuits moved to 3. The field named itself a
// negotiated consensus parameter, agreed on a stale value, and enforced no
// property whatsoever.
//
// This was never exploitable: RULESET_VERSION is a circuit global, so it is
// baked into each tier's verification key, and a proof from another epoch
// cannot satisfy the bundled key. That implicit guarantee is exactly why the
// check has to be explicit — it disappears the moment two VKs are bundled,
// which is what a ruleset bump is for.
//
// See docs/M4_findings.md M4.14 and docs/OUTSTANDING_ITEMS.md §6.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

void main() {
  test('a proof from a different ruleset epoch forfeits the match', () async {
    // Verification is stubbed to `alwaysOk` precisely to reach past the VK's
    // implicit guarantee and prove the explicit check exists.
    final stateCaster = makeDuelState();
    final statePeer = makeDuelState();
    final pair = TurnSessionPair();
    final loopCaster = TurnLoop(
      state: stateCaster,
      session: pair.sessionA,
      localPlayerId: 'player_a',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    );
    final loopPeer = TurnLoop(
      state: statePeer,
      session: pair.sessionB,
      localPlayerId: 'player_b',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    );

    final spell = forgedSpell(rulesetVersion: kRulesetVersion + 1);
    loopCaster.localChapterCommitments = [spell.commitmentHex];

    // The caster's runTurn is started unawaited: the verifier aborts partway
    // through resolution, so no reply ever comes for the exchange after it and
    // awaiting the caster directly would hang. Same shape as
    // turn_loop_cast_authorization_test.dart's rejection harness.
    unawaited(loopCaster
        .runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        ))
        .catchError((Object _) => null));

    await expectLater(
      loopPeer.runTurn(TurnInput(action: PassAction())),
      throwsA(isA<StateError>().having(
        (e) => e.toString(),
        'message',
        contains('ruleset_version'),
      )),
    );
  });

  test('a matching ruleset epoch resolves normally', () async {
    // The positive half of the pairing: the check must not be rejecting every
    // cast for unrelated reasons.
    final stateCaster = makeDuelState();
    final statePeer = makeDuelState();
    final pair = TurnSessionPair();
    final loopCaster = TurnLoop(
      state: stateCaster,
      session: pair.sessionA,
      localPlayerId: 'player_a',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    );
    final loopPeer = TurnLoop(
      state: statePeer,
      session: pair.sessionB,
      localPlayerId: 'player_b',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    );

    // Honest, not forged: an immediate cast of the forged spell legitimately
    // desyncs (the verifier resolves certified earth, the caster its own wire
    // fire) and would fail here for a reason that has nothing to do with the
    // ruleset epoch.
    final spell = honestSpell();
    loopCaster.localChapterCommitments = [spell.commitmentHex];

    await Future.wait([
      loopCaster.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
      )),
      loopPeer.runTurn(TurnInput(action: PassAction())),
    ], eagerError: true).timeout(const Duration(seconds: 20));

    expect(
      bytesEqual(stateCaster.toCanonicalBytes(), statePeer.toCanonicalBytes()),
      isTrue,
      reason: 'an in-epoch cast must resolve identically on both devices',
    );
  });

  test('MatchConfig defaults to the canonical ruleset version', () {
    expect(const MatchConfig().rulesetVersion, equals(kRulesetVersion),
        reason: 'the default drifted to a hardcoded 2 while the circuits moved '
            'to 3, which made the negotiated value meaningless');
  });
}
