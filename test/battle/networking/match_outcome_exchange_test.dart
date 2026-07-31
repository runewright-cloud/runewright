// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_outcome_exchange_test.dart — BattleSession.exchangeMatchOutcome
// (docs/MASTER_APPRENTICE_PLAN.md §4.2): each side sends its signed
// MatchOutcome and receives the peer's. This is a pure transport method —
// it does not validate what it gets back — so these tests exercise the
// transport (both sides receive exactly what the other sent, over a real
// InMemoryTransport pair) plus the validation battle_screen.dart's
// _handleMatchEnd layers on top: agreeing outcomes validate, and a peer
// that signs a DIFFERENT outcome (wrong victor) is caught by
// MatchOutcome.sameFieldsAs / MatchOutcomeRecord.isFullyValid, exactly as
// the real call site checks before ever calling record.save().

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/match_outcome.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  test('both sides receive exactly what the other sent', () async {
    final victor = await Identity.ephemeral();
    final loser = await Identity.ephemeral();
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final outcome = MatchOutcome(
      matchIdHex: '0x${'ab' * 16}',
      victorPubkeyHex: await victor.ownerPubkeyHex(),
      loserPubkeyHex: await loser.ownerPubkeyHex(),
      finalStateHashHex: '0x${'cd' * 32}',
      endedAtTurn: 3,
    );
    final signedByVictor = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
    final signedByLoser = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: loser);

    final results = await Future.wait([
      sessionA.exchangeMatchOutcome(signedByVictor),
      sessionB.exchangeMatchOutcome(signedByLoser),
    ]);
    final seenByA = results[0];
    final seenByB = results[1];

    expect(seenByA.signerPubkeyHex, equals(signedByLoser.signerPubkeyHex));
    expect(seenByB.signerPubkeyHex, equals(signedByVictor.signerPubkeyHex));
    expect(await seenByA.isSignatureValid(), isTrue);
    expect(await seenByB.isSignatureValid(), isTrue);

    // Both sides agreeing on identical outcome fields (the real-world case:
    // both TurnLoops derived the same victor/loser/state from lockstep
    // state) is what makes the combined record settleable.
    final recordSeenByA =
        MatchOutcomeRecord(outcome: outcome, mine: signedByVictor, theirs: seenByA);
    expect(await recordSeenByA.isFullyValid(), isTrue);

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a peer reporting a different victor fails MatchOutcome.sameFieldsAs, '
      'so the caller never saves a record', () async {
    final me = await Identity.ephemeral();
    final honestPeer = await Identity.ephemeral();
    final wrongVictor = await Identity.ephemeral();
    final (transportMe, transportPeer) = InMemoryTransport.pair();
    final sessionMe = BattleSession(transportMe, matchId);
    final sessionPeer = BattleSession(transportPeer, matchId);

    final myOutcome = MatchOutcome(
      matchIdHex: '0x${'ab' * 16}',
      victorPubkeyHex: await me.ownerPubkeyHex(),
      loserPubkeyHex: await honestPeer.ownerPubkeyHex(),
      finalStateHashHex: '0x${'cd' * 32}',
      endedAtTurn: 3,
    );
    // The dishonest peer signs a DIFFERENT outcome — claiming a third party
    // won, not the honest victor.
    final peerOutcome = MatchOutcome(
      matchIdHex: myOutcome.matchIdHex,
      victorPubkeyHex: await wrongVictor.ownerPubkeyHex(),
      loserPubkeyHex: myOutcome.loserPubkeyHex,
      finalStateHashHex: myOutcome.finalStateHashHex,
      endedAtTurn: myOutcome.endedAtTurn,
    );
    final mySigned = await SignedMatchOutcome.sign(outcome: myOutcome, signerIdentity: me);
    final peerSigned =
        await SignedMatchOutcome.sign(outcome: peerOutcome, signerIdentity: honestPeer);

    final results = await Future.wait([
      sessionMe.exchangeMatchOutcome(mySigned),
      sessionPeer.exchangeMatchOutcome(peerSigned),
    ]);
    final theirsSeenByMe = results[0];

    // The peer's signature is perfectly valid over ITS OWN (dishonest)
    // outcome -- the defense is field agreement, not signature validity.
    expect(await theirsSeenByMe.isSignatureValid(), isTrue);
    expect(myOutcome.sameFieldsAs(theirsSeenByMe.outcome), isFalse);

    await transportMe.disconnect();
    await transportPeer.disconnect();
  });
}
