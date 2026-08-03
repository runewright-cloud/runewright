// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_renewal_test.dart — the §5.7 renewal-supersession path: a
// second chapter bundle from the same master, detected via
// ApprenticeshipRecord.forPeer, updates the SAME relationship record and
// the SAME cloned ChapterAsset in place rather than creating a duplicate.
// Covers: old permission files are gone, the chapter id is unchanged
// (so the apprentice's active-chapter selection survives), expiresAt is
// pushed out, and a spell the master dropped from the chapter loses both
// its grant and its chapter entry.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_session.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';
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

  SpellAsset ownedSpell({
    required String id,
    required String ownerPubkeyHex,
    required String commitmentHex,
    required String spellHashHex,
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
        spellHashHex: spellHashHex,
      );

  Future<(ApprenticeSession, ApprenticeSession)> pairedSessions(Identity master, Identity apprentice) async {
    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, master);
    final apprenticeSession = await apprenticeFuture;
    return (masterSession, apprenticeSession);
  }

  test('a renewed bundle supersedes the first: same record, same chapter id, '
      'expiresAt pushed out, a dropped spell loses its grant and entry', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final masterOwnerHex = await master.ownerPubkeyHex();
    final apprenticeOwnerHex = await apprentice.ownerPubkeyHex();

    final spellA = ownedSpell(
      id: 'a1',
      ownerPubkeyHex: masterOwnerHex,
      commitmentHex: '0xaa1122',
      spellHashHex: '0xaaaa',
      name: 'Ember Wake',
    );
    final spellB = ownedSpell(
      id: 'b1',
      ownerPubkeyHex: masterOwnerHex,
      commitmentHex: '0xbb3344',
      spellHashHex: '0xbbbb',
      name: 'Frost Bind',
    );

    // ── First grant: chapter has both spells ──────────────────────────────
    final chapterV1 = ChapterAsset(
      id: 'master-chapter',
      name: 'Starter Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: spellA.id), ChapterEntry(spellId: spellB.id)],
    );

    final (masterSession1, apprenticeSession1) = await pairedSessions(master, apprentice);
    await masterSession1.sendChapterOffer(chapter: chapterV1, spells: [spellA, spellB], isRenewal: false);
    await apprenticeSession1.awaitChapterOffer();
    apprenticeSession1.respondToOffer(true);
    await masterSession1.awaitAcceptance();

    final send1 = masterSession1.sendChapterBundle(master: master, chapter: chapterV1, spells: [spellA, spellB]);
    final receive1 = apprenticeSession1.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession1.peerOwnerPubkeyHex,
    );
    await send1;
    final result1 = await receive1;
    expect(result1.success, isTrue, reason: result1.errors.join('; '));
    final record1 = result1.record!;
    expect(record1.grantedCommitments.toSet(), {spellA.commitmentHex, spellB.commitmentHex});
    expect(record1.permissionIds, hasLength(2));
    expect(record1.receivedSpellIds, hasLength(2));

    final chapter1 = await ChapterAsset.loadById(record1.localChapterId!);
    expect(chapter1!.entries, hasLength(2));

    final assetIdForA1 = (await SpellAsset.loadAll())
        .firstWhere((s) => s.commitmentHex.toLowerCase() == spellA.commitmentHex.toLowerCase())
        .id;

    // ── Renewal: master drops spellB, re-offers a fresh in-person session ──
    final chapterV2 = ChapterAsset(
      id: 'master-chapter',
      name: 'Starter Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: spellA.id)],
    );

    final existingOnApprentice =
        await ApprenticeshipRecord.forPeer(masterOwnerHex, side: ApprenticeSide.apprentice);
    expect(existingOnApprentice, isNotNull);

    final (masterSession2, apprenticeSession2) = await pairedSessions(master, apprentice);
    await masterSession2.sendChapterOffer(chapter: chapterV2, spells: [spellA], isRenewal: true);
    final receivedOffer2 = await apprenticeSession2.awaitChapterOffer();
    expect(receivedOffer2.isRenewal, isTrue);
    apprenticeSession2.respondToOffer(true);
    await masterSession2.awaitAcceptance();

    final send2 = masterSession2.sendChapterBundle(master: master, chapter: chapterV2, spells: [spellA]);
    final receive2 = apprenticeSession2.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession2.peerOwnerPubkeyHex,
    );
    await send2;
    final result2 = await receive2;
    expect(result2.success, isTrue, reason: result2.errors.join('; '));
    final record2 = result2.record!;

    // Same relationship record and clone, not a duplicate.
    expect(record2.id, record1.id);
    expect(record2.localChapterId, record1.localChapterId);
    expect(record2.apprenticePubkeyHex, apprenticeOwnerHex);
    expect(record2.startedAt, record1.startedAt); // origin preserved
    expect(record2.lastRenewedAt.isAfter(record1.lastRenewedAt), isTrue);
    expect(record2.expiresAt.isAfter(record1.expiresAt), isTrue);

    // Only spellA remains granted.
    expect(record2.grantedCommitments, [spellA.commitmentHex]);
    expect(record2.permissionIds, hasLength(1));
    expect(record2.receivedSpellIds, hasLength(1));

    // spellA's local asset id was REUSED across the renewal, not resaved
    // under a new id.
    expect(record2.receivedSpellIds.single, assetIdForA1);

    // The chapter clone kept its id and now has only spellA's entry.
    final chapter2 = await ChapterAsset.loadById(record2.localChapterId!);
    expect(chapter2!.entries, hasLength(1));
    expect(chapter2.entries.single.spellId, assetIdForA1);

    // The OLD permission files (both of them) are gone -- only the new
    // spellA permission remains.
    final allPerms = await SpellPermission.loadAll();
    expect(allPerms, hasLength(1));
    expect(record1.permissionIds, isNot(contains(allPerms.single.id)));

    // spellB's received asset (dropped from the renewed snapshot) was deleted.
    final allSpells = await SpellAsset.loadAll();
    expect(
      allSpells.where((s) => s.commitmentHex.toLowerCase() == spellB.commitmentHex.toLowerCase()),
      isEmpty,
    );
    // spellA's asset is still there (reused).
    expect(allSpells.map((s) => s.id), contains(assetIdForA1));
  });
}
