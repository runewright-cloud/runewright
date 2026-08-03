// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_loan_view_test.dart — the Phase D presentation seam
// (docs/MASTER_APPRENTICE_PLAN.md §8): MasterLoanView, which tells the library
// UI which loans/chapter came from a master, and expiringMastership, which
// drives the main menu's days-remaining nag.
//
// These are deliberately data-layer tests, not widget tests. Every screen
// involved loads its data through real dart:io calls, a pattern this project's
// widget-test harness cannot settle (see MASTER_APPRENTICE_PLAN.md's Phase B
// status note) — so the behaviour is pinned here and the widgets only consume
// it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';

import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  final now = DateTime.utc(2026, 8, 3);

  ApprenticeshipRecord record({
    required ApprenticeSide side,
    ApprenticeshipStatus status = ApprenticeshipStatus.active,
    String id = 'appr-1',
    DateTime? expiresAt,
  }) =>
      ApprenticeshipRecord(
        id: id,
        side: side,
        masterPubkeyHex: '0xaa',
        apprenticePubkeyHex: '0xbb',
        chapterName: 'Starter Chapter',
        sourceChapterId: 'master-chapter-1',
        localChapterId: side == ApprenticeSide.apprentice ? 'local-chapter-1' : null,
        grantedCommitments: ['0x${'cc' * 32}'],
        permissionIds: ['perm-1', 'perm-2'],
        receivedSpellIds: ['appr-spell-1', 'appr-spell-2'],
        startedAt: now,
        lastRenewedAt: now,
        expiresAt: expiresAt ?? now.add(const Duration(days: kApprenticeshipTermDays)),
        status: status,
      );

  group('MasterLoanView', () {
    test('none marks nothing and reports no master', () {
      const view = MasterLoanView.none;
      expect(view.hasMaster, isFalse);
      expect(view.isChapterFromMaster('local-chapter-1'), isFalse);
      expect(view.isSpellFromMaster('appr-spell-1'), isFalse);
      expect(view.isPermissionFromMaster('perm-1'), isFalse);
      expect(view.remainingLabel(now: now), isEmpty);
    });

    test('load() with no records is equivalent to none', () async {
      final view = await MasterLoanView.load();
      expect(view.hasMaster, isFalse);
      expect(view.isChapterFromMaster('local-chapter-1'), isFalse);
    });

    test('identifies the cloned chapter, its spells, and its grants', () async {
      await record(side: ApprenticeSide.apprentice).save();
      final view = await MasterLoanView.load();

      expect(view.hasMaster, isTrue);
      expect(view.isChapterFromMaster('local-chapter-1'), isTrue);
      expect(view.isSpellFromMaster('appr-spell-2'), isTrue);
      expect(view.isPermissionFromMaster('perm-2'), isTrue);
    });

    test("does not mark the player's own chapters, spells, or trade loans", () async {
      await record(side: ApprenticeSide.apprentice).save();
      final view = await MasterLoanView.load();

      expect(view.isChapterFromMaster('my-own-chapter'), isFalse);
      expect(view.isChapterFromMaster(null), isFalse);
      // The master's OWN chapter id is not the apprentice's clone id: a
      // collision here would freeze the wrong chapter on the wrong device.
      expect(view.isChapterFromMaster('master-chapter-1'), isFalse);
      expect(view.isSpellFromMaster('trade-loan-spell'), isFalse);
      expect(view.isPermissionFromMaster('trade-perm'), isFalse);
    });

    test('a master-side record marks nothing — a master owns their chapter', () async {
      await record(side: ApprenticeSide.master).save();
      final view = await MasterLoanView.load();

      expect(view.hasMaster, isFalse);
      expect(view.isChapterFromMaster('master-chapter-1'), isFalse);
    });

    test('a closed apprenticeship marks nothing', () async {
      for (final status in [
        ApprenticeshipStatus.abandoned,
        ApprenticeshipStatus.graduated,
        ApprenticeshipStatus.graduatedByLoss,
      ]) {
        await record(
          side: ApprenticeSide.apprentice,
          status: status,
          id: 'appr-${status.name}',
        ).save();
      }
      final view = await MasterLoanView.load();

      expect(view.hasMaster, isFalse);
      expect(view.isChapterFromMaster('local-chapter-1'), isFalse);
    });

    test('a lapsed-but-open apprenticeship still marks its chapter', () async {
      // The grants have expired, so the spells stop passing
      // localIdentityMayUse — but the cloned chapter is still on disk and must
      // stay read-only, because renewal revives it in place (§5.7).
      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.subtract(const Duration(days: 1)),
      ).save();
      final view = await MasterLoanView.load();

      expect(view.hasMaster, isTrue);
      expect(view.isChapterFromMaster('local-chapter-1'), isTrue);
      expect(view.remainingLabel(now: now), 'Lapsed');
    });

    test('remainingLabel counts down and singularizes the last day', () async {
      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.add(const Duration(days: 12)),
      ).save();
      expect((await MasterLoanView.load()).remainingLabel(now: now), '12 days remain');

      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.add(const Duration(days: 1, hours: 3)),
      ).save();
      expect((await MasterLoanView.load()).remainingLabel(now: now), '1 day remains');
    });
  });

  group('expiringMastership (the §8 nag)', () {
    test('stays silent with no apprenticeship at all', () async {
      expect(await ApprenticeshipRecord.expiringMastership(now: now), isNull);
    });

    test('stays silent while the term is comfortably open', () async {
      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.add(const Duration(days: 20)),
      ).save();
      expect(await ApprenticeshipRecord.expiringMastership(now: now), isNull);
    });

    test('stays silent at exactly the nag threshold, fires inside it', () async {
      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.add(const Duration(days: kApprenticeshipNagDays)),
      ).save();
      expect(await ApprenticeshipRecord.expiringMastership(now: now), isNull);

      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.add(const Duration(days: kApprenticeshipNagDays - 1)),
      ).save();
      expect(await ApprenticeshipRecord.expiringMastership(now: now), isNotNull);
    });

    test('keeps nagging once lapsed — renewal is still possible', () async {
      await record(
        side: ApprenticeSide.apprentice,
        expiresAt: now.subtract(const Duration(days: 5)),
      ).save();
      final nag = await ApprenticeshipRecord.expiringMastership(now: now);
      expect(nag, isNotNull);
      expect(nag!.isLapsed(now: now), isTrue);
    });

    test('ignores a closed record and a master-side one', () async {
      await record(
        side: ApprenticeSide.apprentice,
        status: ApprenticeshipStatus.graduated,
        id: 'closed',
        expiresAt: now.add(const Duration(days: 1)),
      ).save();
      await record(
        side: ApprenticeSide.master,
        id: 'teaching',
        expiresAt: now.add(const Duration(days: 1)),
      ).save();
      expect(await ApprenticeshipRecord.expiringMastership(now: now), isNull);
    });
  });
}
