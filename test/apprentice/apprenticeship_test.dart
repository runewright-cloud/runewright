// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprenticeship_test.dart — ApprenticeshipRecord (docs/MASTER_APPRENTICE_PLAN.md
// §5.1/§5.9): JSON round-trip, the isLapsed live-clock boundary, and the
// §2.2 relationship-shape queries (activeMastership/apprentices/forPeer).

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

  ApprenticeshipRecord sample({
    required ApprenticeSide side,
    ApprenticeshipStatus status = ApprenticeshipStatus.active,
    String? id,
    String masterPubkeyHex = '0x${'aa'}',
    String apprenticePubkeyHex = '0x${'bb'}',
    DateTime? startedAt,
    DateTime? expiresAt,
  }) {
    final now = DateTime.utc(2026, 7, 29);
    return ApprenticeshipRecord(
      id: id ?? 'appr-${side.name}-${masterPubkeyHex.hashCode}-${apprenticePubkeyHex.hashCode}',
      side: side,
      masterPubkeyHex: masterPubkeyHex,
      apprenticePubkeyHex: apprenticePubkeyHex,
      chapterName: 'Starter Chapter',
      sourceChapterId: 'chapter-1',
      localChapterId: side == ApprenticeSide.apprentice ? 'local-chapter-1' : null,
      grantedCommitments: ['0x${'cc' * 32}'],
      permissionIds: ['perm-1'],
      receivedSpellIds: ['spell-1'],
      startedAt: startedAt ?? now,
      lastRenewedAt: startedAt ?? now,
      expiresAt: expiresAt ?? now.add(const Duration(days: kApprenticeshipTermDays)),
      status: status,
    );
  }

  group('JSON round-trip', () {
    test('all fields round-trip, including nullable localChapterId/closedAt', () async {
      final record = sample(side: ApprenticeSide.master).copyWith(
        status: ApprenticeshipStatus.graduated,
        closedAt: DateTime.utc(2026, 8, 1),
      );
      final decoded = ApprenticeshipRecord.fromJson(record.toJson());
      expect(decoded.id, record.id);
      expect(decoded.side, record.side);
      expect(decoded.masterPubkeyHex, record.masterPubkeyHex);
      expect(decoded.apprenticePubkeyHex, record.apprenticePubkeyHex);
      expect(decoded.chapterName, record.chapterName);
      expect(decoded.sourceChapterId, record.sourceChapterId);
      expect(decoded.localChapterId, isNull); // master side
      expect(decoded.grantedCommitments, record.grantedCommitments);
      expect(decoded.permissionIds, record.permissionIds);
      expect(decoded.receivedSpellIds, record.receivedSpellIds);
      expect(decoded.status, ApprenticeshipStatus.graduated);
      expect(decoded.closedAt, record.closedAt);
    });

    test('save()/loadById() round-trips through disk', () async {
      final record = sample(side: ApprenticeSide.apprentice);
      await record.save();
      final loaded = await ApprenticeshipRecord.loadById(record.id);
      expect(loaded, isNotNull);
      expect(loaded!.localChapterId, 'local-chapter-1');
    });

    test('loadById returns null for an unknown id', () async {
      expect(await ApprenticeshipRecord.loadById('nope'), isNull);
    });
  });

  group('isLapsed', () {
    test('active exactly at expiresAt - 1s', () {
      final expiresAt = DateTime.utc(2026, 8, 28);
      final record = sample(side: ApprenticeSide.apprentice, expiresAt: expiresAt);
      expect(record.isLapsed(now: expiresAt.subtract(const Duration(seconds: 1))), isFalse);
    });

    test('lapsed exactly at expiresAt', () {
      final expiresAt = DateTime.utc(2026, 8, 28);
      final record = sample(side: ApprenticeSide.apprentice, expiresAt: expiresAt);
      expect(record.isLapsed(now: expiresAt), isTrue);
    });

    test('a non-active status is never "lapsed" regardless of the clock', () {
      final expiresAt = DateTime.utc(2026, 8, 28);
      final record = sample(
        side: ApprenticeSide.apprentice,
        status: ApprenticeshipStatus.abandoned,
        expiresAt: expiresAt,
      );
      expect(record.isLapsed(now: expiresAt.add(const Duration(days: 100))), isFalse);
    });
  });

  group('daysRemaining', () {
    test('floors to 0 once lapsed, never negative', () {
      final expiresAt = DateTime.utc(2026, 8, 28);
      final record = sample(side: ApprenticeSide.apprentice, expiresAt: expiresAt);
      expect(record.daysRemaining(now: expiresAt.add(const Duration(days: 5))), 0);
    });

    test('counts whole days remaining', () {
      final expiresAt = DateTime.utc(2026, 8, 28);
      final record = sample(side: ApprenticeSide.apprentice, expiresAt: expiresAt);
      expect(record.daysRemaining(now: expiresAt.subtract(const Duration(days: 10))), 10);
    });
  });

  group('activeMastership / apprentices / forPeer (§2.2 shape)', () {
    test('activeMastership returns only the active apprentice-side record', () async {
      await sample(side: ApprenticeSide.master).save();
      final active = sample(side: ApprenticeSide.apprentice);
      await active.save();

      final found = await ApprenticeshipRecord.activeMastership();
      expect(found, isNotNull);
      expect(found!.id, active.id);
    });

    test('activeMastership is null once the apprentice-side record is abandoned', () async {
      final abandoned = sample(side: ApprenticeSide.apprentice, status: ApprenticeshipStatus.abandoned);
      await abandoned.save();
      expect(await ApprenticeshipRecord.activeMastership(), isNull);
    });

    test('apprentices() returns every master-side record, unlimited', () async {
      final a = sample(side: ApprenticeSide.master, apprenticePubkeyHex: '0x${'01' * 32}');
      final b = sample(side: ApprenticeSide.master, apprenticePubkeyHex: '0x${'02' * 32}');
      await a.save();
      await b.save();
      final found = await ApprenticeshipRecord.apprentices();
      expect(found.map((r) => r.id).toSet(), {a.id, b.id});
    });

    test('forPeer finds the active apprentice-side record naming its master (case-insensitive)', () async {
      final master = sample(
        side: ApprenticeSide.apprentice,
        masterPubkeyHex: '0x${'ff' * 32}',
        apprenticePubkeyHex: '0x${'ee' * 32}',
      );
      await master.save();
      final found =
          await ApprenticeshipRecord.forPeer('0x${'FF' * 32}', side: ApprenticeSide.apprentice);
      expect(found, isNotNull);
      expect(found!.id, master.id);
    });

    test('forPeer prefers an active record over a closed one for the same peer', () async {
      final peer = '0x${'ff' * 32}';
      final closed = sample(
        side: ApprenticeSide.apprentice,
        id: 'closed-record',
        masterPubkeyHex: peer,
        status: ApprenticeshipStatus.abandoned,
        startedAt: DateTime.utc(2026, 1, 1),
      );
      final active = sample(
        side: ApprenticeSide.apprentice,
        id: 'active-record',
        masterPubkeyHex: peer,
        startedAt: DateTime.utc(2026, 6, 1),
      );
      await closed.save();
      await active.save();
      final found = await ApprenticeshipRecord.forPeer(peer, side: ApprenticeSide.apprentice);
      expect(found!.id, 'active-record');
    });

    test('forPeer returns null when no record names the peer', () async {
      expect(await ApprenticeshipRecord.forPeer('0x${'99' * 32}', side: ApprenticeSide.apprentice), isNull);
    });

    test('forPeer never crosses sides -- a master-side record for X does not answer '
        'an apprentice-side lookup for X, even though the same pubkey X appears in both', () async {
      // The exact shape that broke graduation settlement before this fix:
      // one device simultaneously holds "my apprentice-side record naming
      // master X" and "my master-side record naming apprentice X" (the same
      // pubkey X on both, e.g. a multi-identity test harness, or in
      // principle two independent real relationships that happen to share a
      // peer key). An unfiltered lookup could return either one.
      final peer = '0x${'12' * 32}';
      final asApprentice = sample(
        side: ApprenticeSide.apprentice,
        id: 'my-apprentice-side-record',
        masterPubkeyHex: peer,
      );
      final asMaster = sample(
        side: ApprenticeSide.master,
        id: 'my-master-side-record',
        apprenticePubkeyHex: peer,
      );
      await asApprentice.save();
      await asMaster.save();

      final foundAsApprentice = await ApprenticeshipRecord.forPeer(peer, side: ApprenticeSide.apprentice);
      expect(foundAsApprentice!.id, 'my-apprentice-side-record');

      final foundAsMaster = await ApprenticeshipRecord.forPeer(peer, side: ApprenticeSide.master);
      expect(foundAsMaster!.id, 'my-master-side-record');
    });
  });
}
