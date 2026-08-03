// SPDX-License-Identifier: GPL-3.0-or-later
//
// graduation_bequest_test.dart — the simple graduation path
// (docs/MASTER_APPRENTICE_PLAN.md §7.1/§7.5): a master converts an
// apprentice's loan grants to perpetual transfers. Covers the full flow
// starting from a real chapter-offer round trip (so the apprentice has a
// genuine cloned chapter + loan permissions to upgrade), then bequeathing:
// the grid arrives, loan permissions are deleted, the clone's entries now
// point at the new full assets, and both sides' records close `graduated`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_session.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/basic_spells.dart';
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

  Future<SpellAsset> seedLocalBasicSpell() async {
    final entry = kBasicSpells.first;
    final raw = await rootBundle.loadString(entry.assetPath);
    final spell = SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await spell.save();
    return spell;
  }

  Future<(ApprenticeSession, ApprenticeSession)> pairedSessions(Identity master, Identity apprentice) async {
    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, master);
    final apprenticeSession = await apprenticeFuture;
    return (masterSession, apprenticeSession);
  }

  /// Runs a full chapter-offer round trip identical to
  /// apprentice_session_test.dart's, returning both sides' resulting
  /// records so a test can bequeath on top of a genuine loan relationship.
  Future<({ApprenticeshipRecord masterRecord, ApprenticeshipRecord apprenticeRecord, ChapterAsset chapter})>
      grantChapter(Identity master, Identity apprentice, SpellAsset owned, SpellAsset basic) async {
    final chapter = ChapterAsset(
      id: 'master-chapter',
      name: 'Starter Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: owned.id), ChapterEntry(spellId: basic.id)],
    );
    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);
    await masterSession.sendChapterOffer(chapter: chapter, spells: [owned, basic], isRenewal: false);
    await apprenticeSession.awaitChapterOffer();
    apprenticeSession.respondToOffer(true);
    await masterSession.awaitAcceptance();
    final sendFuture = masterSession.sendChapterBundle(master: master, chapter: chapter, spells: [owned, basic]);
    final receiveFuture = apprenticeSession.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    final sendResult = await sendFuture;
    final receiveResult = await receiveFuture;
    return (
      masterRecord: sendResult.record!,
      apprenticeRecord: receiveResult.record!,
      chapter: chapter,
    );
  }

  test('bequest converts the loan to a transfer: grid arrives, loan permissions gone, '
      'clone entries upgraded, both records close graduated', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final masterOwnerHex = await master.ownerPubkeyHex();
    final apprenticeOwnerHex = await apprentice.ownerPubkeyHex();

    final owned = ownedSpell(id: 'a1', ownerPubkeyHex: masterOwnerHex);
    final basic = await seedLocalBasicSpell();
    final granted = await grantChapter(master, apprentice, owned, basic);

    final oldLoanPermIds = granted.apprenticeRecord.permissionIds;
    final oldWithheldAssetIds = granted.apprenticeRecord.receivedSpellIds;
    expect(oldLoanPermIds, hasLength(1));
    expect(oldWithheldAssetIds, hasLength(1));

    // ── Bequest: fresh pairing (a real in-person session), master gives it away ──
    final (masterSession2, apprenticeSession2) = await pairedSessions(master, apprentice);
    final sendFuture = masterSession2.sendBequest(
      master: master,
      masterRecord: granted.masterRecord,
      spells: [owned],
    );
    final receiveFuture = apprenticeSession2.receiveBequestAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession2.peerOwnerPubkeyHex,
    );
    final sendResult = await sendFuture;
    final receiveResult = await receiveFuture;

    expect(sendResult.success, isTrue, reason: sendResult.errors.join('; '));
    expect(sendResult.grantedSpellCount, 1);
    expect(sendResult.record!.status, ApprenticeshipStatus.graduated);

    expect(receiveResult.success, isTrue, reason: receiveResult.errors.join('; '));
    final closedApprenticeRecord = receiveResult.record!;
    expect(closedApprenticeRecord.status, ApprenticeshipStatus.graduated);
    expect(closedApprenticeRecord.id, granted.apprenticeRecord.id); // same relationship, not a new one

    // The old grid-withheld loan copy and its permission are gone.
    final allPermsAfter = await SpellPermission.loadAll();
    expect(allPermsAfter.any((p) => oldLoanPermIds.contains(p.id)), isFalse);
    final allSpellsAfter = await SpellAsset.loadAll();
    expect(allSpellsAfter.any((s) => oldWithheldAssetIds.contains(s.id)), isFalse);

    // A full, grid-included copy exists now, naming the apprentice as
    // grantee on a perpetual transfer permission.
    final fullCopy = allSpellsAfter.firstWhere((s) => s.commitmentHex.toLowerCase() == owned.commitmentHex.toLowerCase());
    expect(fullCopy.initialGrid, isNotEmpty);
    expect(fullCopy.gridWithheld, isFalse);
    final transferPerms = await SpellPermission.loadForCommitment(owned.commitmentHex);
    expect(transferPerms, hasLength(1));
    expect(transferPerms.single.kind, SpellGrantKind.transfer);
    expect(transferPerms.single.expiresAt, isNull);
    expect(transferPerms.single.granteePubkeyHex, apprenticeOwnerHex);

    // The cloned chapter (same id) now points at the full copy for the
    // upgraded entry, and is unchanged for the untouched Basic entry.
    final clonedChapter = await ChapterAsset.loadById(closedApprenticeRecord.localChapterId!);
    expect(clonedChapter!.id, granted.apprenticeRecord.localChapterId);
    expect(clonedChapter.entries, hasLength(2));
    expect(clonedChapter.entries.map((e) => e.spellId), contains(fullCopy.id));
    expect(clonedChapter.entries.map((e) => e.spellId), contains(basic.id));

    // Neither side's record is active any more.
    expect(await ApprenticeshipRecord.activeMastership(), isNull);
    final apprenticesOfMaster = await ApprenticeshipRecord.apprentices();
    expect(apprenticesOfMaster.every((r) => r.status != ApprenticeshipStatus.active), isTrue);
  });

  test('receiveBequestAndSave still saves a genuine transfer with no active local '
      'apprenticeship for the peer, but skips the chapter/record bookkeeping', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);

    // Nobody ever ran a chapter offer -- there is no relationship to graduate.
    // This exercises the defensive path: the wire handshake (frame read +
    // ack) must still complete so the sender never hangs, even though there
    // is no local ApprenticeshipRecord to attach the result to.
    final owned = ownedSpell(id: 'a1', ownerPubkeyHex: await master.ownerPubkeyHex());
    final fakeMasterRecord = ApprenticeshipRecord(
      id: 'fake',
      side: ApprenticeSide.master,
      masterPubkeyHex: await master.ownerPubkeyHex(),
      apprenticePubkeyHex: masterSession.peerOwnerPubkeyHex,
      chapterName: 'Nonexistent',
      sourceChapterId: 'none',
      grantedCommitments: [owned.commitmentHex],
      startedAt: DateTime.utc(2026, 7, 30),
      lastRenewedAt: DateTime.utc(2026, 7, 30),
      expiresAt: DateTime.utc(2026, 8, 29),
    );

    final sendFuture =
        masterSession.sendBequest(master: master, masterRecord: fakeMasterRecord, spells: [owned]);
    final receiveFuture = apprenticeSession.receiveBequestAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    final sendResult = await sendFuture;
    final receiveResult = await receiveFuture;

    expect(sendResult.success, isTrue);
    expect(receiveResult.success, isTrue);
    expect(receiveResult.record, isNull); // no record existed to close
    expect(receiveResult.grantedSpellCount, 1);
    final saved = await SpellAsset.loadAll();
    expect(saved.any((s) => s.commitmentHex.toLowerCase() == owned.commitmentHex.toLowerCase()), isTrue);
  });
}
