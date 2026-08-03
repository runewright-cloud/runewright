// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_session_test.dart — full Master/Apprentice round-trip over
// InMemoryTransport (docs/MASTER_APPRENTICE_PLAN.md §5.4-§5.6/§5.9): offer
// preview, accept, signed bundle delivery, and the apprentice-side clone
// (ChapterAsset + ApprenticeshipRecord). Also covers the rejection paths
// that make the trust boundary real: a loan bundle that (illegally) carries
// a grid, and a grant naming a third party as grantee — both must fail the
// WHOLE bundle (nothing saved, no record), per §5.6's "a half-built chapter
// is worse than no chapter."
//
// Renewal is covered separately in apprentice_renewal_test.dart.

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_session.dart';
import 'package:rune_duel/apprentice/apprentice_wire.dart';
import 'package:rune_duel/apprentice/apprenticeship.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/transport.dart';
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

  /// Loads and persists (to the fake apprentice-side library) the first
  /// shipped Basic spell -- receiveChapterBundleAndSave resolves a Basic
  /// chapter entry against the RECEIVER's own local copy, not anything the
  /// master sends.
  Future<SpellAsset> seedLocalBasicSpell() async {
    final entry = kBasicSpells.first;
    final raw = await rootBundle.loadString(entry.assetPath);
    final spell = SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await spell.save();
    return spell;
  }

  Future<(ApprenticeSession, ApprenticeSession, Transport, Transport)> pairedSessionsWithTransports(
    Identity master,
    Identity apprentice,
  ) async {
    final (tMaster, tApprentice) = InMemoryTransport.pair();
    final apprenticeFuture = ApprenticeSession.accept(tApprentice, apprentice);
    final masterSession = await ApprenticeSession.initiate(tMaster, master);
    final apprenticeSession = await apprenticeFuture;
    return (masterSession, apprenticeSession, tMaster, tApprentice);
  }

  Future<(ApprenticeSession, ApprenticeSession)> pairedSessions(Identity master, Identity apprentice) async {
    final (masterSession, apprenticeSession, _, _) = await pairedSessionsWithTransports(master, apprentice);
    return (masterSession, apprenticeSession);
  }

  test('handshake resolves each side\'s peerOwnerPubkeyHex to the other\'s real identity', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);

    expect(masterSession.peerOwnerPubkeyHex, await apprentice.ownerPubkeyHex());
    expect(apprenticeSession.peerOwnerPubkeyHex, await master.ownerPubkeyHex());
    expect(masterSession.sessionId, equals(apprenticeSession.sessionId));
  });

  test('full round trip: offer -> accept -> bundle -> clone', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    final masterOwnerHex = await master.ownerPubkeyHex();

    final owned = ownedSpell(id: 'a1', ownerPubkeyHex: masterOwnerHex);
    final basic = await seedLocalBasicSpell();

    final chapter = ChapterAsset(
      id: 'master-chapter',
      name: 'Starter Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [
        ChapterEntry(spellId: owned.id),
        ChapterEntry(spellId: basic.id),
        ChapterEntry(spellId: basic.id), // duplicate Basic entry, deliberately
      ],
      artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
    );

    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);

    final masterOfferFuture =
        masterSession.sendChapterOffer(chapter: chapter, spells: [owned, basic], isRenewal: false);
    final apprenticeOfferFuture = apprenticeSession.awaitChapterOffer();
    final sentManifest = await masterOfferFuture;
    final receivedManifest = await apprenticeOfferFuture;

    expect(sentManifest.entries, hasLength(3));
    expect(receivedManifest.entries, hasLength(3));
    expect(receivedManifest.chapterName, 'Starter Chapter');
    expect(receivedManifest.isRenewal, isFalse);
    expect(receivedManifest.termDays, kApprenticeshipTermDays);
    expect(receivedManifest.artifacts, hasLength(1));

    final acceptanceFuture = masterSession.awaitAcceptance();
    apprenticeSession.respondToOffer(true);
    final acceptance = await acceptanceFuture;
    expect(acceptance.accepted, isTrue);
    expect(acceptance.reason, isNull);

    final sendFuture = masterSession.sendChapterBundle(master: master, chapter: chapter, spells: [owned, basic]);
    final receiveFuture = apprenticeSession.receiveChapterBundleAndSave(
      me: apprentice,
      masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
    );
    final sendResult = await sendFuture;
    final receiveResult = await receiveFuture;

    // Only the non-Basic spell needs (or gets) a signed grant.
    expect(sendResult.success, isTrue);
    expect(sendResult.grantedSpellCount, 1);
    expect(sendResult.entryCount, 3);

    // The master's own bookkeeping record is saved too -- without this,
    // "Your apprentices" on the hub screen would never show anyone.
    final masterRecord = sendResult.record!;
    expect(masterRecord.side, ApprenticeSide.master);
    expect(masterRecord.apprenticePubkeyHex, await apprentice.ownerPubkeyHex());
    expect(masterRecord.sourceChapterId, chapter.id);
    expect(masterRecord.grantedCommitments, [owned.commitmentHex]);
    expect(masterRecord.permissionIds, isEmpty);
    final apprenticesOfMaster = await ApprenticeshipRecord.apprentices();
    expect(apprenticesOfMaster.map((r) => r.id), contains(masterRecord.id));

    expect(receiveResult.success, isTrue, reason: receiveResult.errors.join('; '));
    final record = receiveResult.record!;
    expect(record.side, ApprenticeSide.apprentice);
    expect(record.status, ApprenticeshipStatus.active);
    expect(record.masterPubkeyHex, masterOwnerHex);
    expect(record.apprenticePubkeyHex, await apprentice.ownerPubkeyHex());
    expect(record.grantedCommitments, [owned.commitmentHex]);
    expect(record.permissionIds, hasLength(1));
    expect(record.receivedSpellIds, hasLength(1));
    expect(record.daysRemaining(now: record.startedAt), kApprenticeshipTermDays - 1);

    final clonedChapter = await ChapterAsset.loadById(record.localChapterId!);
    expect(clonedChapter, isNotNull);
    expect(clonedChapter!.name, 'Starter Chapter (Apprentice)');
    expect(clonedChapter.entries, hasLength(3)); // 1:1 with the master's, dup preserved
    expect(clonedChapter.artifacts, hasLength(1));
    expect(clonedChapter.artifacts.first.kind, ArtifactKind.manaGem);

    // The received (non-Basic) asset must be grid-withheld.
    final allSpells = await SpellAsset.loadAll();
    final receivedAsset = allSpells.firstWhere((s) => s.id == record.receivedSpellIds.first);
    expect(receivedAsset.gridWithheld, isTrue);
    expect(receivedAsset.initialGrid, isEmpty);
    expect(receivedAsset.commitmentHex, owned.commitmentHex);

    // Two entries resolve to the pre-seeded Basic spell's own local id; one
    // resolves to the freshly received asset.
    final entrySpellIds = clonedChapter.entries.map((e) => e.spellId).toList();
    expect(entrySpellIds.where((id) => id == basic.id).length, 2);
    expect(entrySpellIds, contains(receivedAsset.id));

    // The saved SpellPermission is a loan naming the apprentice as grantee.
    final perms = await SpellPermission.loadForCommitment(owned.commitmentHex);
    expect(perms, hasLength(1));
    expect(perms.single.kind, SpellGrantKind.loan);
    expect(perms.single.granteePubkeyHex, await apprentice.ownerPubkeyHex());
  });

  group('rejection paths (§5.6: any failing grant fails the whole bundle)', () {
    test('a loan bundle entry that (illegally) carries a grid is rejected wholesale', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final masterOwnerHex = await master.ownerPubkeyHex();
      final owned = ownedSpell(id: 'a1', ownerPubkeyHex: masterOwnerHex);

      final (masterSession, apprenticeSession, tMaster, _) =
          await pairedSessionsWithTransports(master, apprentice);

      final perm = await SpellPermission.createAndSign(
        spell: owned,
        ownerIdentity: master,
        granteePubkeyHex: await apprentice.ownerPubkeyHex(), // correct grantee -- isolates the grid forgery
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      );
      // Forged: the FULL asset (grid included), not withGridWithheld().
      final forgedBundle = {
        'chapterName': 'Forged',
        'grants': [
          {'permission': perm.toJson(), 'asset': owned.toJson()},
        ],
        'entries': [
          {'commitmentHex': owned.commitmentHex},
        ],
        'artifacts': const [],
      };
      tMaster.send(
        ApprenticeFrame(
          ApprenticeMsgType.chapterBundle,
          Uint8List.fromList(utf8.encode(jsonEncode(forgedBundle))),
        ).encode(),
      );

      final result = await apprenticeSession.receiveChapterBundleAndSave(
        me: apprentice,
        masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
      );

      expect(result.success, isFalse);
      expect(result.errors, isNotEmpty);
      expect(result.errors.first, contains('grid state'));
      expect(await SpellAsset.loadAll(), isEmpty);
      expect(await ApprenticeshipRecord.loadAll(), isEmpty);
      unawaited(masterSession.close());
    });

    test('a grant naming a third party as grantee is rejected wholesale', () async {
      final master = await Identity.ephemeral();
      final apprentice = await Identity.ephemeral();
      final outsider = await Identity.ephemeral();
      final masterOwnerHex = await master.ownerPubkeyHex();
      final owned = ownedSpell(id: 'a1', ownerPubkeyHex: masterOwnerHex);

      final (masterSession, apprenticeSession, tMaster, _) =
          await pairedSessionsWithTransports(master, apprentice);

      final perm = await SpellPermission.createAndSign(
        spell: owned,
        ownerIdentity: master,
        granteePubkeyHex: await outsider.ownerPubkeyHex(), // NOT the connected apprentice
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      );
      final forgedBundle = {
        'chapterName': 'Misdirected',
        'grants': [
          {'permission': perm.toJson(), 'asset': owned.withGridWithheld().toJson()},
        ],
        'entries': [
          {'commitmentHex': owned.commitmentHex},
        ],
        'artifacts': const [],
      };
      tMaster.send(
        ApprenticeFrame(
          ApprenticeMsgType.chapterBundle,
          Uint8List.fromList(utf8.encode(jsonEncode(forgedBundle))),
        ).encode(),
      );

      final result = await apprenticeSession.receiveChapterBundleAndSave(
        me: apprentice,
        masterPubkeyHex: apprenticeSession.peerOwnerPubkeyHex,
      );

      expect(result.success, isFalse);
      expect(result.errors, isNotEmpty);
      expect(result.errors.first, contains('does not name this device as grantee'));
      expect(await SpellAsset.loadAll(), isEmpty);
      expect(await ApprenticeshipRecord.loadAll(), isEmpty);
      unawaited(masterSession.close());
    });
  });

  test('sendChapterBundle fails (and sends nothing) if the master does not actually own an entry', () async {
    final master = await Identity.ephemeral();
    final apprentice = await Identity.ephemeral();
    // Owned by someone else -- simulates chapterEligibleForApprenticeLoan
    // being bypassed; createAndSign must still refuse to sign it.
    final notOwned = ownedSpell(id: 'a1', ownerPubkeyHex: '0x${'99' * 32}');
    final chapter = ChapterAsset(
      id: 'c1',
      name: 'Bad Chapter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: notOwned.id)],
    );

    final (masterSession, apprenticeSession) = await pairedSessions(master, apprentice);
    final result = await masterSession.sendChapterBundle(master: master, chapter: chapter, spells: [notOwned]);

    expect(result.success, isFalse);
    expect(result.errors, isNotEmpty);
    unawaited(apprenticeSession.close());
  });
}
