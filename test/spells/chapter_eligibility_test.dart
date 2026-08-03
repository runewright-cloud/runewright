// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_eligibility_test.dart — chapterEligibleForApprenticeLoan
// (docs/MASTER_APPRENTICE_PLAN.md §5.2/§5.9): the stricter, apprentice-loan-
// specific gate distinct from localIdentityMayUse — only natively owned
// spells (or shipped Basic spells) may be lent onward.
//
// Needs the real FFI bridge (Poseidon2, via Identity.ownerPubkeyHex) --
// run with `flutter test`, not `dart test`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import 'fake_path_provider.dart';

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

  Future<SpellAsset> ownedSpell(Identity owner, {String id = 'owned-1'}) async {
    final ownerPubkeyHex = await owner.ownerPubkeyHex();
    return SpellAsset(
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
      name: 'Ember Wake',
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
    );
  }

  Future<SpellAsset> loanedSpell({String id = 'loaned-1'}) async {
    // ownerPubkeyHex belongs to nobody the test controls -- any spell whose
    // owner isn't `master` demonstrates the "held on loan, not owned" case.
    return SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 6, 19),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'99' * 32}',
      manaCost: 10,
      segmentCount: 1,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: "Someone Else's Rune",
      commitmentHex: '0x112233',
      spellHashHex: '0x445566',
    );
  }

  Future<SpellAsset> basicSpell() async {
    final entry = kBasicSpells.first;
    final raw = await rootBundle.loadString(entry.assetPath);
    return SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  test('a chapter of entirely natively-owned spells is eligible', () async {
    final master = await Identity.ephemeral();
    final spell = await ownedSpell(master);
    final chapter = ChapterAsset(
      id: 'c1',
      name: 'Starter',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: spell.id)],
    );
    final result = await chapterEligibleForApprenticeLoan(
      chapter: chapter,
      localSpells: [spell],
      master: master,
    );
    expect(result.eligible, isTrue);
    expect(result.reasons, isEmpty);
  });

  test('a loaned-in (non-owned) spell makes the chapter ineligible with a reason', () async {
    final master = await Identity.ephemeral();
    final owned = await ownedSpell(master);
    final loaned = await loanedSpell();
    final chapter = ChapterAsset(
      id: 'c1',
      name: 'Mixed',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: owned.id), ChapterEntry(spellId: loaned.id)],
    );
    final result = await chapterEligibleForApprenticeLoan(
      chapter: chapter,
      localSpells: [owned, loaned],
      master: master,
    );
    expect(result.eligible, isFalse);
    expect(result.reasons, hasLength(1));
    expect(result.reasons.first, contains('held on loan, not owned'));
    expect(result.reasons.first, contains(loaned.name));
  });

  test('a Basic spell does not fail eligibility even though master does not own it', () async {
    final master = await Identity.ephemeral();
    final basic = await basicSpell();
    // Sanity: the master's identity is NOT the basic spell's shipped owner.
    expect(basic.ownerPubkeyHex, isNot(await master.ownerPubkeyHex()));

    final chapter = ChapterAsset(
      id: 'c1',
      name: 'All Basic',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [ChapterEntry(spellId: basic.id)],
    );
    final result = await chapterEligibleForApprenticeLoan(
      chapter: chapter,
      localSpells: [basic],
      master: master,
    );
    expect(result.eligible, isTrue);
  });

  test('an entry whose spell is no longer in the library fails with a reason', () async {
    final master = await Identity.ephemeral();
    final chapter = ChapterAsset(
      id: 'c1',
      name: 'Broken',
      createdAt: DateTime.utc(2026, 7, 29),
      entries: [const ChapterEntry(spellId: 'deleted-spell')],
    );
    final result = await chapterEligibleForApprenticeLoan(
      chapter: chapter,
      localSpells: const [],
      master: master,
    );
    expect(result.eligible, isFalse);
    expect(result.reasons, contains('spell no longer in library'));
  });

  test('an empty chapter is ineligible ("nothing to teach")', () async {
    final master = await Identity.ephemeral();
    final chapter = ChapterAsset(id: 'c1', name: 'Empty', createdAt: DateTime.utc(2026, 7, 29));
    final result = await chapterEligibleForApprenticeLoan(
      chapter: chapter,
      localSpells: const [],
      master: master,
    );
    expect(result.eligible, isFalse);
    expect(result.reasons, ['nothing to teach']);
  });
}
