// SPDX-License-Identifier: GPL-3.0-or-later
//
// graduation_settlement_test.dart — post-battle graduation settlement
// (docs/MASTER_APPRENTICE_PLAN.md §7.4/§7.5): resolveGraduationSettlement's
// pre-settlement trust gate, then each direction's actual transfer.
//
// apprentice-won reuses sendBequest/receiveBequestAndSave verbatim (the
// plan says so explicitly: "master emits the chapter's spells, identical to
// §7.1") — already covered end-to-end in graduation_bequest_test.dart, so
// this file's apprentice-won case focuses on resolveGraduationSettlement
// correctly authorizing it. master-won is new: sendStakeSettlement /
// receiveStakeSettlementAndSave, plus the critical §2.5 decision 13
// assertion that the apprentice KEEPS their staked spells (a settlement is
// always a copy, never a confiscation).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_session.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';
import 'package:rune_duel/apprentice/graduation_pact.dart';
import 'package:rune_duel/battle/models/match_outcome.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../spells/fake_path_provider.dart';

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

  SpellAsset spellFor({
    required String id,
    required String ownerPubkeyHex,
    required String commitmentHex,
    String name = 'Ember Wake',
  }) =>
      SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 6, 19),
        tier: 12,
        t: 5,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: 10,
        segmentCount: 1,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: '0x${commitmentHex.substring(2)}ff',
      );

  Future<(ApprenticeSession, ApprenticeSession)> pairedSessions(Identity master, Identity apprentice) async {
    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, master);
    final apprenticeSession = await apprenticeFuture;
    return (masterSession, apprenticeSession);
  }

  Future<({ApprenticeshipRecord masterRecord, ApprenticeshipRecord apprenticeRecord})> grantChapter(
    Identity master,
    Identity apprentice,
    SpellAsset owned,
  ) async {
    final chapter = ChapterAsset(
      id: 'master-chapter',
      name: 'Starter Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: owned.id)],
    );
    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);
    await masterSession.sendChapterOffer(chapter: chapter, spells: [owned], isRenewal: false);
    await apprenticeSession.awaitChapterOffer();
    apprenticeSession.respondToOffer(true);
    await masterSession.awaitAcceptance();
    final sendFuture = masterSession.sendChapterBundle(master: master, chapter: chapter, spells: [owned]);
    final receiveFuture = apprenticeSession.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    final sendResult = await sendFuture;
    final receiveResult = await receiveFuture;
    return (masterRecord: sendResult.record!, apprenticeRecord: receiveResult.record!);
  }

  Future<SignedGraduationPact> agreedPact({
    required Identity master,
    required Identity apprentice,
    required List<String> chapterCommitments,
    required List<String> stakeCommitments,
  }) async {
    final pact = GraduationPact(
      pactIdHex: generatePactIdHex(),
      masterPubkeyHex: await master.ownerPubkeyHex(),
      apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
      chapterName: 'Starter Chapter',
      chapterCommitments: chapterCommitments,
      stakeCommitments: stakeCommitments,
      agreedAt: DateTime.utc(2026, 7, 30),
    );
    var signed = await SignedGraduationPact.proposedByMaster(pact: pact, masterIdentity: master);
    signed = await signed.signedByApprentice(apprenticeIdentity: apprentice);
    return signed;
  }

  Future<MatchOutcomeRecord> agreedOutcome({
    required Identity victor,
    required Identity loser,
    required String pactIdHex,
  }) async {
    final outcome = MatchOutcome(
      matchIdHex: '0x${'ab' * 16}',
      victorPubkeyHex: await victor.ownerPubkeyHex(),
      loserPubkeyHex: await loser.ownerPubkeyHex(),
      finalStateHashHex: '0x${'cd' * 32}',
      pactIdHex: pactIdHex,
      endedAtTurn: 12,
    );
    final byVictor = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: victor);
    final byLoser = await SignedMatchOutcome.sign(outcome: outcome, signerIdentity: loser);
    return MatchOutcomeRecord(outcome: outcome, mine: byVictor, theirs: byLoser);
  }

  group('resolveGraduationSettlement', () {
    test('resolves apprentice as victor when the outcome names them', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const [],
      );
      final outcome =
          await agreedOutcome(victor: apprentice, loser: master, pactIdHex: pact.pact.pactIdHex);
      expect(await resolveGraduationSettlement(pact: pact, outcome: outcome), GraduationVictor.apprentice);
    });

    test('resolves master as victor when the outcome names them', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const ['0xee9900'],
      );
      final outcome =
          await agreedOutcome(victor: master, loser: apprentice, pactIdHex: pact.pact.pactIdHex);
      expect(await resolveGraduationSettlement(pact: pact, outcome: outcome), GraduationVictor.master);
    });

    test('rejects an outcome whose pactIdHex does not match', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const [],
      );
      final outcome = await agreedOutcome(victor: apprentice, loser: master, pactIdHex: generatePactIdHex());
      expect(await resolveGraduationSettlement(pact: pact, outcome: outcome), isNull);
    });

    test('rejects an outcome carrying only one valid signature', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const [],
      );
      final outcome0 = MatchOutcome(
        matchIdHex: '0x${'ab' * 16}',
        victorPubkeyHex: await apprentice.ownerPubkeyHex(),
        loserPubkeyHex: await master.ownerPubkeyHex(),
        finalStateHashHex: '0x${'cd' * 32}',
        pactIdHex: pact.pact.pactIdHex,
        endedAtTurn: 12,
      );
      final onlyVictorSigned = await SignedMatchOutcome.sign(outcome: outcome0, signerIdentity: apprentice);
      // "theirs" is the SAME signature again -- not an independent second party.
      final oneSided = MatchOutcomeRecord(outcome: outcome0, mine: onlyVictorSigned, theirs: onlyVictorSigned);
      expect(await resolveGraduationSettlement(pact: pact, outcome: oneSided), isNull);
    });

    test('rejects an outcome naming a third party as victor', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final outsider = await Identity.ephemeral();
      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: ['0xaa1122'],
        stakeCommitments: const [],
      );
      final outcome = await agreedOutcome(victor: outsider, loser: master, pactIdHex: pact.pact.pactIdHex);
      expect(await resolveGraduationSettlement(pact: pact, outcome: outcome), isNull);
    });

    test('rejects a half-signed pact even with a perfectly valid outcome', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final unsignedPact = GraduationPact(
        pactIdHex: generatePactIdHex(),
        masterPubkeyHex: await master.ownerPubkeyHex(),
        apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
        chapterName: 'Starter Chapter',
        chapterCommitments: const ['0xaa1122'],
        stakeCommitments: const [],
        agreedAt: DateTime.utc(2026, 7, 30),
      );
      final halfSigned =
          await SignedGraduationPact.proposedByMaster(pact: unsignedPact, masterIdentity: master);
      final outcome =
          await agreedOutcome(victor: apprentice, loser: master, pactIdHex: unsignedPact.pactIdHex);
      expect(await resolveGraduationSettlement(pact: halfSigned, outcome: outcome), isNull);
    });
  });

  group('settling', () {
    test('apprentice-won settles the chapter via the bequest path', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final masterOwnerHex = await master.ownerPubkeyHex();
      final owned = spellFor(id: 'a1', ownerPubkeyHex: masterOwnerHex, commitmentHex: '0xaa1122');
      final granted = await grantChapter(master, apprentice, owned);

      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: granted.masterRecord.grantedCommitments,
        stakeCommitments: const [],
      );
      final outcome =
          await agreedOutcome(victor: apprentice, loser: master, pactIdHex: pact.pact.pactIdHex);
      final victor = await resolveGraduationSettlement(pact: pact, outcome: outcome);
      expect(victor, GraduationVictor.apprentice);

      final (masterSession2, apprenticeSession2) = await pairedSessions(master, apprentice);
      final sendFuture =
          masterSession2.sendBequest(master: master, masterRecord: granted.masterRecord, spells: [owned]);
      final receiveFuture = apprenticeSession2.receiveBequestAndSave(
        me: apprentice,
        masterPubkeyHex: apprenticeSession2.peerOwnerPubkeyHex,
      );
      final sendResult = await sendFuture;
      final receiveResult = await receiveFuture;

      expect(sendResult.success, isTrue);
      expect(sendResult.record!.status, ApprenticeshipStatus.graduated);
      expect(receiveResult.success, isTrue);
      expect(receiveResult.record!.status, ApprenticeshipStatus.graduated);
    });

    test('master-won settles the stakes AND tears down the loan; the apprentice keeps '
        'their staked spell files', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final masterOwnerHex = await master.ownerPubkeyHex();
      final apprenticeOwnerHex = await apprentice.ownerPubkeyHex();
      final owned = spellFor(id: 'a1', ownerPubkeyHex: masterOwnerHex, commitmentHex: '0xaa1122');
      final granted = await grantChapter(master, apprentice, owned);

      final stake = spellFor(
        id: 'stake1',
        ownerPubkeyHex: apprenticeOwnerHex,
        commitmentHex: '0xee9900',
        name: "Apprentice's Own Rune",
      );
      // The apprentice must own it locally for the stake to be real.
      await stake.save();

      final pact = await agreedPact(
        master: master,
        apprentice: apprentice,
        chapterCommitments: granted.masterRecord.grantedCommitments,
        stakeCommitments: [stake.commitmentHex],
      );
      final outcome =
          await agreedOutcome(victor: master, loser: apprentice, pactIdHex: pact.pact.pactIdHex);
      final victor = await resolveGraduationSettlement(pact: pact, outcome: outcome);
      expect(victor, GraduationVictor.master);

      final (masterSession2, apprenticeSession2) = await pairedSessions(master, apprentice);
      final sendFuture = apprenticeSession2.sendStakeSettlement(
        apprentice: apprentice,
        pact: pact,
        spells: [stake],
      );
      final receiveFuture = masterSession2.receiveStakeSettlementAndSave(
        master: master,
        apprenticePubkeyHex: masterSession2.peerOwnerPubkeyHex,
      );
      final sendResult = await sendFuture;
      final receiveResult = await receiveFuture;

      expect(sendResult.success, isTrue, reason: sendResult.errors.join('; '));
      expect(sendResult.record!.status, ApprenticeshipStatus.graduatedByLoss);
      expect(receiveResult.success, isTrue, reason: receiveResult.errors.join('; '));
      expect(receiveResult.record!.status, ApprenticeshipStatus.graduatedByLoss);

      // §2.5 decision 13: the apprentice KEEPS their staked spell -- only a
      // copy was sent, nothing local was deleted for it.
      final apprenticeSpellsAfter = await SpellAsset.loadAll();
      expect(apprenticeSpellsAfter.any((s) => s.id == stake.id), isTrue);

      // The master now holds a genuine copy too, with a perpetual transfer grant.
      final masterCopy = apprenticeSpellsAfter
          .where((s) => s.commitmentHex.toLowerCase() == stake.commitmentHex.toLowerCase())
          .toList();
      expect(masterCopy, hasLength(2)); // apprentice's original + master's new copy
      final stakePerms = await SpellPermission.loadForCommitment(stake.commitmentHex);
      expect(stakePerms, hasLength(1));
      expect(stakePerms.single.kind, SpellGrantKind.transfer);
      expect(stakePerms.single.granteePubkeyHex, masterOwnerHex);

      // The loan (chapter clone + its permissions/withheld assets) is torn down.
      expect(await ChapterAsset.loadById(granted.apprenticeRecord.localChapterId!), isNull);
      final remainingPerms = await SpellPermission.loadAll();
      expect(remainingPerms.any((p) => granted.apprenticeRecord.permissionIds.contains(p.id)), isFalse);
    });
  });
}
