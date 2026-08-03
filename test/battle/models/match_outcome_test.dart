// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_outcome_test.dart — the signed, mutually-agreed match-result record
// (docs/MASTER_APPRENTICE_PLAN.md §4). Covers the canonical-message contract
// (every field folded into the signed bytes, so tampering any of them on
// disk breaks the signature) and MatchOutcomeRecord.isFullyValid's combined
// two-signature check.
//
// Needs the real FFI bridge (Poseidon2, via Identity.ownerPubkeyMatches) --
// run with `flutter test`, not `dart test`.

import 'dart:convert' show base64Encode;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/match_outcome.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<MatchOutcome> sampleOutcome(Identity victor, Identity loser) async {
    return MatchOutcome(
      matchIdHex: '0x${'ab' * 16}',
      victorPubkeyHex: await victor.ownerPubkeyHex(),
      loserPubkeyHex: await loser.ownerPubkeyHex(),
      finalStateHashHex: '0x${'cd' * 32}',
      endedAtTurn: 7,
    );
  }

  group('SignedMatchOutcome.isSignatureValid', () {
    test('a genuine signature verifies', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final signed = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      expect(await signed.isSignatureValid(), isTrue);
    });

    test('tampering victorPubkeyHex after signing invalidates the signature', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final attacker = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final signed = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);

      final tampered = SignedMatchOutcome(
        outcome: MatchOutcome(
          matchIdHex: outcome.matchIdHex,
          victorPubkeyHex: await attacker.ownerPubkeyHex(), // swapped in
          loserPubkeyHex: outcome.loserPubkeyHex,
          finalStateHashHex: outcome.finalStateHashHex,
          pactIdHex: outcome.pactIdHex,
          endedAtTurn: outcome.endedAtTurn,
        ),
        signerPubkeyHex: signed.signerPubkeyHex,
        rawPubkeyBase64: signed.rawPubkeyBase64,
        signatureBase64: signed.signatureBase64,
      );
      expect(await tampered.isSignatureValid(), isFalse);
    });

    test('tampering pactIdHex after signing invalidates the signature', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final signed = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);

      final tampered = SignedMatchOutcome(
        outcome: MatchOutcome(
          matchIdHex: outcome.matchIdHex,
          victorPubkeyHex: outcome.victorPubkeyHex,
          loserPubkeyHex: outcome.loserPubkeyHex,
          finalStateHashHex: outcome.finalStateHashHex,
          pactIdHex: 'some-graduation-pact-id',
          endedAtTurn: outcome.endedAtTurn,
        ),
        signerPubkeyHex: signed.signerPubkeyHex,
        rawPubkeyBase64: signed.rawPubkeyBase64,
        signatureBase64: signed.signatureBase64,
      );
      expect(await tampered.isSignatureValid(), isFalse);
    });

    test('tampering endedAtTurn after signing invalidates the signature', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final signed = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);

      final tampered = SignedMatchOutcome(
        outcome: MatchOutcome(
          matchIdHex: outcome.matchIdHex,
          victorPubkeyHex: outcome.victorPubkeyHex,
          loserPubkeyHex: outcome.loserPubkeyHex,
          finalStateHashHex: outcome.finalStateHashHex,
          pactIdHex: outcome.pactIdHex,
          endedAtTurn: outcome.endedAtTurn + 1,
        ),
        signerPubkeyHex: signed.signerPubkeyHex,
        rawPubkeyBase64: signed.rawPubkeyBase64,
        signatureBase64: signed.signatureBase64,
      );
      expect(await tampered.isSignatureValid(), isFalse);
    });

    test('a presented rawPubkey that does not hash to signerPubkeyHex is rejected', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final attacker = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final signed = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);

      final tampered = SignedMatchOutcome(
        outcome: outcome,
        signerPubkeyHex: signed.signerPubkeyHex,
        rawPubkeyBase64: base64Encode(attacker.publicKeyBytes),
        signatureBase64: signed.signatureBase64,
      );
      expect(await tampered.isSignatureValid(), isFalse);
    });
  });

  group('MatchOutcome.sameFieldsAs', () {
    test('identical fields (case-insensitive hex digits, lowercase 0x prefix) match', () async {
      // Every hex string this codebase produces is lowercase-'0x'-prefixed
      // (see spell_permission.dart's identical _hexEq) -- only the digit
      // portion's case varies in practice (e.g. a peer's JSON round-trip),
      // never the prefix itself.
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mixedCaseDigits = MatchOutcome(
        matchIdHex: '0x${outcome.matchIdHex.substring(2).toUpperCase()}',
        victorPubkeyHex: outcome.victorPubkeyHex,
        loserPubkeyHex: outcome.loserPubkeyHex,
        finalStateHashHex: outcome.finalStateHashHex,
        pactIdHex: outcome.pactIdHex,
        endedAtTurn: outcome.endedAtTurn,
      );
      expect(outcome.sameFieldsAs(mixedCaseDigits), isTrue);
    });

    test('a different endedAtTurn does not match', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final other = MatchOutcome(
        matchIdHex: outcome.matchIdHex,
        victorPubkeyHex: outcome.victorPubkeyHex,
        loserPubkeyHex: outcome.loserPubkeyHex,
        finalStateHashHex: outcome.finalStateHashHex,
        pactIdHex: outcome.pactIdHex,
        endedAtTurn: outcome.endedAtTurn + 1,
      );
      expect(outcome.sameFieldsAs(other), isFalse);
    });
  });

  group('MatchOutcomeRecord.isFullyValid', () {
    test('two genuine, distinct signatures over the same outcome validate', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mine = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      final theirs = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: loser);
      final record = MatchOutcomeRecord(outcome: outcome, mine: mine, theirs: theirs);
      expect(await record.isFullyValid(), isTrue);
    });

    test('a signature from a party not named in the outcome is rejected', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outsider = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mine = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      final theirs = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: outsider);
      final record = MatchOutcomeRecord(outcome: outcome, mine: mine, theirs: theirs);
      expect(await record.isFullyValid(), isFalse);
    });

    test('two copies of the victor\'s own signature do not count as agreement', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mine = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      final record = MatchOutcomeRecord(outcome: outcome, mine: mine, theirs: mine);
      expect(await record.isFullyValid(), isFalse);
    });

    test('an invalid signature on either side fails the whole record', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mine = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      final badTheirs = SignedMatchOutcome(
        outcome: outcome,
        signerPubkeyHex: outcome.loserPubkeyHex,
        rawPubkeyBase64: mine.rawPubkeyBase64, // wrong key for the claimed loser identity
        signatureBase64: mine.signatureBase64,
      );
      final record = MatchOutcomeRecord(outcome: outcome, mine: mine, theirs: badTheirs);
      expect(await record.isFullyValid(), isFalse);
    });
  });

  group('JSON round-trip', () {
    test('MatchOutcome round-trips including default pactIdHex', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final decoded = MatchOutcome.fromJson(outcome.toJson());
      expect(decoded.sameFieldsAs(outcome), isTrue);
      expect(decoded.pactIdHex, equals(kNoGraduationPact));
    });

    test('MatchOutcomeRecord round-trips through save()/loadByMatchId()', () async {
      final victor = await Identity.ephemeral();
      final loser = await Identity.ephemeral();
      final outcome = await sampleOutcome(victor, loser);
      final mine = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
      final theirs = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: loser);
      final record = MatchOutcomeRecord(outcome: outcome, mine: mine, theirs: theirs);
      await record.save();

      final loaded = await MatchOutcomeRecord.loadByMatchId(outcome.matchIdHex);
      expect(loaded, isNotNull);
      expect(loaded!.outcome.sameFieldsAs(outcome), isTrue);
      expect(await loaded.isFullyValid(), isTrue);
    });

    test('loadByMatchId returns null for an unknown matchId', () async {
      final loaded = await MatchOutcomeRecord.loadByMatchId('0x${'00' * 16}');
      expect(loaded, isNull);
    });
  });
}
