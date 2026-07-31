// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_constraints_test.dart — the §2.2 relationship-shape rules
// (docs/MASTER_APPRENTICE_PLAN.md §2.2 decision 4, §7.5): a device with an
// active mastership refuses a second master, and stakes a graduation pact
// proposes must be genuinely deliverable before the apprentice accepts.
//
// "Refuses to offer an apprenticeship" (the master-side half of decision 4)
// is enforced at the UI layer only (apprenticeship_screen.dart disables
// "Offer an Apprenticeship" while `activeMastership() != null`) — see
// sendChapterOffer's doc comment for why it isn't duplicated at the session
// layer: `ApprenticeshipRecord.activeMastership()` reflects the single
// local identity's OWN state, which this test harness's shared-fake-
// filesystem convention (both simulated devices' records in one directory,
// same as every other test in test/apprentice/) can't reliably isolate for
// a "my own device" check outside of a clean, standalone test like this one.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_session.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';
import 'package:rune_duel/apprentice/graduation_pact.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
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

  SpellAsset ownedSpell({
    required String id,
    required String ownerPubkeyHex,
    String commitmentHex = '0xaa1122',
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
        spellHashHex: '0xddeeff',
      );

  ApprenticeshipRecord activeApprenticeRecord({
    required String masterPubkeyHex,
    required String apprenticePubkeyHex,
  }) {
    final now = DateTime.utc(2026, 7, 30);
    return ApprenticeshipRecord(
      id: 'existing-master',
      side: ApprenticeSide.apprentice,
      masterPubkeyHex: masterPubkeyHex,
      apprenticePubkeyHex: apprenticePubkeyHex,
      chapterName: 'An Existing Master\'s Chapter',
      sourceChapterId: 'unused',
      localChapterId: 'unused-chapter',
      startedAt: now,
      lastRenewedAt: now,
      expiresAt: now.add(const Duration(days: kApprenticeshipTermDays)),
    );
  }

  test('a device with an active mastership refuses a fresh (non-renewal) grant '
      'from a different master', () async {
    final existingMaster = await Identity.ephemeral();
    final newMaster = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();

    // The apprentice already studies under `existingMaster`.
    await activeApprenticeRecord(
      masterPubkeyHex: await existingMaster.ownerPubkeyHex(),
      apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
    ).save();
    expect(await ApprenticeshipRecord.activeMastership(), isNotNull);

    // A second, unrelated master tries to offer a chapter.
    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, newMaster);
    final apprenticeSession = await apprenticeFuture;

    final chapter = ChapterAsset(
      id: 'new-master-chapter',
      name: 'A Rival Chapter',
      createdAt: DateTime.utc(2026, 7, 30),
      entries: [ChapterEntry(spellId: 'a1')],
    );
    final owned = ownedSpell(id: 'a1', ownerPubkeyHex: await newMaster.ownerPubkeyHex());

    await masterSession.sendChapterOffer(chapter: chapter, spells: [owned], isRenewal: false);
    await apprenticeSession.awaitChapterOffer();
    apprenticeSession.respondToOffer(true);
    await masterSession.awaitAcceptance();

    final sendFuture = masterSession.sendChapterBundle(master: newMaster, chapter: chapter, spells: [owned]);
    final receiveFuture = apprenticeSession.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    await sendFuture; // must not hang -- the wire handshake completes regardless
    final receiveResult = await receiveFuture;

    expect(receiveResult.success, isFalse);
    expect(receiveResult.errors.single, contains('already have an active master'));
    // The one true master relationship is untouched.
    final stillActive = await ApprenticeshipRecord.activeMastership();
    expect(stillActive!.masterPubkeyHex, await existingMaster.ownerPubkeyHex());
  });

  test('the same device CAN renew its existing master without tripping the guard', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final masterOwnerHex = await master.ownerPubkeyHex();

    await activeApprenticeRecord(
      masterPubkeyHex: masterOwnerHex,
      apprenticePubkeyHex: await apprentice.ownerPubkeyHex(),
    ).save();

    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, master);
    final apprenticeSession = await apprenticeFuture;

    final chapter = ChapterAsset(
      id: 'existing-chapter', // matches sourceChapterId's spirit -- irrelevant to the guard
      name: "An Existing Master's Chapter",
      createdAt: DateTime.utc(2026, 7, 30),
      entries: [ChapterEntry(spellId: 'a1')],
    );
    final owned = ownedSpell(id: 'a1', ownerPubkeyHex: masterOwnerHex);

    await masterSession.sendChapterOffer(chapter: chapter, spells: [owned], isRenewal: true);
    await apprenticeSession.awaitChapterOffer();
    apprenticeSession.respondToOffer(true);
    await masterSession.awaitAcceptance();

    final sendFuture = masterSession.sendChapterBundle(master: master, chapter: chapter, spells: [owned]);
    final receiveFuture = apprenticeSession.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    await sendFuture;
    final receiveResult = await receiveFuture;

    expect(receiveResult.success, isTrue, reason: receiveResult.errors.join('; '));
  });

  group('unresolvableStakeCommitments (§7.2: "do not let a pact promise something '
      'that cannot be delivered")', () {
    test('every stake resolving to a natively-owned, non-Basic local spell is empty', () async {
      final apprentice = await Identity.ephemeral();
      final apprenticeOwnerHex = await apprentice.ownerPubkeyHex();
      final owned = ownedSpell(id: 's1', ownerPubkeyHex: apprenticeOwnerHex, commitmentHex: '0xaa1122');

      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: [owned.commitmentHex],
        apprenticeOwnerPubkeyHex: apprenticeOwnerHex,
        localSpells: [owned],
      );
      expect(unresolvable, isEmpty);
    });

    test('a stake for a spell the apprentice does not have locally is unresolvable', () {
      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: const ['0xdeadbeef'],
        apprenticeOwnerPubkeyHex: '0x${'11' * 32}',
        localSpells: const [],
      );
      expect(unresolvable, ['0xdeadbeef']);
    });

    test('a stake the apprentice holds only on loan (foreign owner) is unresolvable', () async {
      final apprentice = await Identity.ephemeral();
      final loaned = ownedSpell(id: 's1', ownerPubkeyHex: '0x${'99' * 32}', commitmentHex: '0xaa1122');
      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: [loaned.commitmentHex],
        apprenticeOwnerPubkeyHex: await apprentice.ownerPubkeyHex(),
        localSpells: [loaned],
      );
      expect(unresolvable, [loaned.commitmentHex]);
    });

    test('a Basic spell is never a legal stake, even though it resolves locally', () async {
      // isBasicSpell requires a real bundled asset match -- simulate the
      // shape without depending on the asset bundle by asserting the
      // ownership branch alone catches the common real-world case (Basic
      // spells never carry the apprentice's own ownerPubkeyHex), and rely
      // on chapter_eligibility_test.dart / basic_spells_test.dart for
      // direct isBasicSpell coverage.
      final apprentice = await Identity.ephemeral();
      final apprenticeOwnerHex = await apprentice.ownerPubkeyHex();
      final foreignBasicLike =
          ownedSpell(id: 'basic', ownerPubkeyHex: '0x${'00' * 32}', commitmentHex: '0xbeef01');
      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: [foreignBasicLike.commitmentHex],
        apprenticeOwnerPubkeyHex: apprenticeOwnerHex,
        localSpells: [foreignBasicLike],
      );
      expect(unresolvable, [foreignBasicLike.commitmentHex]);
    });

    test('an empty stakeCommitments list has nothing unresolvable (an unwagered battle is legal)', () {
      final unresolvable = unresolvableStakeCommitments(
        stakeCommitments: const [],
        apprenticeOwnerPubkeyHex: '0x${'11' * 32}',
        localSpells: const [],
      );
      expect(unresolvable, isEmpty);
    });
  });
}
