// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_backup_test.dart — additive-merge semantics for the library
// backup: every dedup key (spellHashHex, sighting id, chapter/permission
// id, recipe key) and the spellId remap chapters need after a spell's id is
// re-minted on import.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/library_backup.dart';
import 'package:rune_duel/spells/recipe_book.dart';
import 'package:rune_duel/spells/sighting_asset.dart';
import 'package:rune_duel/spells/spell_art_store.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_permission.dart';

import 'fake_path_provider.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SpellAsset spell({
    required String id,
    required String spellHashHex,
    String commitmentHex = '0xaabbcc',
    String ownerPubkeyHex = '0x1234',
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
        name: 'Ember Wake',
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
      );

  SpellPermission permission({required String id, required String commitmentHex}) => SpellPermission(
        id: id,
        grantedAt: DateTime.utc(2026, 6, 19),
        commitmentHex: commitmentHex,
        ownerPubkeyHex: '0xowner',
        ownerRawPubkeyBase64: base64Encode(List<int>.filled(32, 7)),
        granteePubkeyHex: '0xgrantee',
        signatureBase64: base64Encode(List<int>.filled(64, 9)),
        kind: SpellGrantKind.transfer,
      );

  group('exportLibraryBackup', () {
    test('produces a self-describing document with everything currently on disk', () async {
      await spell(id: 's1', spellHashHex: '0xh1').save();
      await ChapterAsset(id: 'c1', name: 'Chapter One', createdAt: DateTime.utc(2026, 6, 19))
          .withEntry(const ChapterEntry(spellId: 's1'))
          .save();
      await SightingAsset.record(
        opponentPubkeyHex: '0xopp',
        commitmentHex: '0xcast',
        spellName: 'Frost Bolt',
        t: 3,
        tier: 12,
        manaCost: 5,
      );
      await permission(id: 'p1', commitmentHex: '0xaabbcc').save();
      await RecipeBook.markDiscovered(['fire:burn']);

      final json = await exportLibraryBackup();
      final doc = jsonDecode(json) as Map<String, dynamic>;

      expect(doc['magic'], 'RUNEWRIGHT_LIBRARY_BACKUP');
      expect(doc['version'], 1);
      expect((doc['spells'] as List).length, 1);
      expect((doc['chapters'] as List).length, 1);
      expect((doc['sightings'] as List).length, 1);
      expect((doc['permissions'] as List).length, 1);
      expect((doc['recipes'] as List), contains('fire:burn'));
    });
  });

  group('importLibraryBackup', () {
    test('rejects a file with the wrong magic', () async {
      final bad = jsonEncode({'magic': 'NOT_A_RUNEWRIGHT_BACKUP', 'version': 1});
      expect(() => importLibraryBackup(bad), throwsA(isA<LibraryBackupFormatException>()));
    });

    test('rejects an unsupported version', () async {
      final bad = jsonEncode({'magic': 'RUNEWRIGHT_LIBRARY_BACKUP', 'version': 99});
      expect(() => importLibraryBackup(bad), throwsA(isA<LibraryBackupFormatException>()));
    });

    test('rejects non-JSON text', () async {
      expect(() => importLibraryBackup('not json'), throwsA(isA<LibraryBackupFormatException>()));
    });

    test('adds a spell that is not already on device, minting a fresh id', () async {
      await spell(id: 'their-id-123', spellHashHex: '0xh1').save();
      final json = await exportLibraryBackup();

      // Simulate a clean device: wipe and re-init the fake docs dir.
      tempDir = await installFakePathProvider();

      final summary = await importLibraryBackup(json);
      expect(summary.spellsAdded, 1);
      expect(summary.spellsSkipped, 0);

      final onDevice = await SpellAsset.loadAll();
      expect(onDevice, hasLength(1));
      expect(onDevice.single.spellHashHex, '0xh1');
      // The id is re-minted, not reused verbatim from the backup.
      expect(onDevice.single.id, isNot('their-id-123'));
    });

    test('skips a spell whose spellHashHex is already on device (redundant, not overwritten)',
        () async {
      final mine = spell(id: 'my-id', spellHashHex: '0xh1', ownerPubkeyHex: '0xme');
      await mine.save();
      final theirs = spell(id: 'their-id', spellHashHex: '0xh1', ownerPubkeyHex: '0xthem');
      final backupJson = jsonEncode({
        'magic': 'RUNEWRIGHT_LIBRARY_BACKUP',
        'version': 1,
        'spells': [theirs.toJson()],
        'spellArt': {},
        'chapters': [],
        'sightings': [],
        'sightingArt': {},
        'permissions': [],
        'recipes': [],
      });

      final summary = await importLibraryBackup(backupJson);
      expect(summary.spellsAdded, 0);
      expect(summary.spellsSkipped, 1);

      final onDevice = await SpellAsset.loadAll();
      expect(onDevice, hasLength(1));
      // The pre-existing local copy (bound to my own key) is untouched --
      // it was NOT overwritten with the imported one bound to a stranger's key.
      expect(onDevice.single.ownerPubkeyHex, '0xme');
    });

    test('re-importing the same backup a second time is a no-op', () async {
      await spell(id: 's1', spellHashHex: '0xh1').save();
      final json = await exportLibraryBackup();

      final first = await importLibraryBackup(json);
      final second = await importLibraryBackup(json);

      expect(first.spellsAdded, 0); // it was already on this device
      expect(second.addedNothing, isTrue);
    });

    test('remaps a chapter entry to a newly-minted spell id', () async {
      await spell(id: 'orig-id', spellHashHex: '0xh1').save();
      await ChapterAsset(id: 'c1', name: 'My Chapter', createdAt: DateTime.utc(2026, 6, 19))
          .withEntry(const ChapterEntry(spellId: 'orig-id'))
          .save();
      final json = await exportLibraryBackup();

      tempDir = await installFakePathProvider(); // clean device

      await importLibraryBackup(json);
      final spells = await SpellAsset.loadAll();
      final chapters = await ChapterAsset.loadAll();

      expect(chapters, hasLength(1));
      expect(chapters.single.entries, hasLength(1));
      expect(chapters.single.entries.single.spellId, spells.single.id);
      expect(chapters.single.entries.single.spellId, isNot('orig-id'));
    });

    test('remaps a chapter entry onto an existing local duplicate spell', () async {
      final mine = spell(id: 'my-id', spellHashHex: '0xh1');
      await mine.save();
      final theirChapter = ChapterAsset(id: 'their-chapter', name: 'Theirs', createdAt: DateTime.utc(2026, 6, 19))
          .withEntry(const ChapterEntry(spellId: 'their-spell-id'));
      final backupJson = jsonEncode({
        'magic': 'RUNEWRIGHT_LIBRARY_BACKUP',
        'version': 1,
        'spells': [spell(id: 'their-spell-id', spellHashHex: '0xh1').toJson()],
        'spellArt': {},
        'chapters': [theirChapter.toJson()],
        'sightings': [],
        'sightingArt': {},
        'permissions': [],
        'recipes': [],
      });

      final summary = await importLibraryBackup(backupJson);
      expect(summary.spellsSkipped, 1); // dedup'd against `mine`
      expect(summary.chaptersAdded, 1);

      final chapters = await ChapterAsset.loadAll();
      expect(chapters.single.entries.single.spellId, mine.id);
    });

    test('skips a chapter whose id already exists locally', () async {
      await ChapterAsset(id: 'c1', name: 'Local', createdAt: DateTime.utc(2026, 6, 19)).save();
      final backupJson = jsonEncode({
        'magic': 'RUNEWRIGHT_LIBRARY_BACKUP',
        'version': 1,
        'spells': [],
        'spellArt': {},
        'chapters': [
          ChapterAsset(id: 'c1', name: 'Foreign version', createdAt: DateTime.utc(2026, 1, 1)).toJson(),
        ],
        'sightings': [],
        'sightingArt': {},
        'permissions': [],
        'recipes': [],
      });

      final summary = await importLibraryBackup(backupJson);
      expect(summary.chaptersSkipped, 1);
      expect(summary.chaptersAdded, 0);

      final chapters = await ChapterAsset.loadAll();
      expect(chapters.single.name, 'Local'); // not overwritten
    });

    test('dedupes sightings by opponent+commitment id', () async {
      await SightingAsset.record(
        opponentPubkeyHex: '0xopp',
        commitmentHex: '0xcast',
        spellName: 'Frost Bolt',
        t: 3,
        tier: 12,
        manaCost: 5,
      );
      final json = await exportLibraryBackup();

      final summary = await importLibraryBackup(json);
      expect(summary.sightingsAdded, 0);
      expect(summary.sightingsSkipped, 1);
      expect(await SightingAsset.loadAll(), hasLength(1));
    });

    test('adds a new sighting from a clean device', () async {
      await SightingAsset.record(
        opponentPubkeyHex: '0xopp',
        commitmentHex: '0xcast',
        spellName: 'Frost Bolt',
        t: 3,
        tier: 12,
        manaCost: 5,
      );
      final json = await exportLibraryBackup();

      tempDir = await installFakePathProvider();

      final summary = await importLibraryBackup(json);
      expect(summary.sightingsAdded, 1);
      expect(await SightingAsset.loadAll(), hasLength(1));
    });

    test('dedupes permissions (loans) by id', () async {
      await permission(id: 'p1', commitmentHex: '0xaabbcc').save();
      final json = await exportLibraryBackup();

      final summary = await importLibraryBackup(json);
      expect(summary.permissionsAdded, 0);
      expect(summary.permissionsSkipped, 1);
    });

    test('merges recipes additively, only counting genuinely new ones', () async {
      await RecipeBook.markDiscovered(['fire:burn']);
      final backupJson = jsonEncode({
        'magic': 'RUNEWRIGHT_LIBRARY_BACKUP',
        'version': 1,
        'spells': [],
        'spellArt': {},
        'chapters': [],
        'sightings': [],
        'sightingArt': {},
        'permissions': [],
        'recipes': ['fire:burn', 'water:freeze'],
      });

      final summary = await importLibraryBackup(backupJson);
      expect(summary.recipesAdded, 1); // fire:burn already known
      expect(await RecipeBook.load(), containsAll(['fire:burn', 'water:freeze']));
    });

    test('carries a newly-added spell\'s custom art across, keyed by spellHashHex', () async {
      final withArt = spell(id: 's1', spellHashHex: '0xh1')
          .withArt(hash: '0xarthash', source: SpellArtSource.localImport);
      await withArt.save();
      await SpellArtStore.save(
        '0xh1',
        full: Uint8List.fromList([1, 2, 3]),
        thumb: Uint8List.fromList([4, 5]),
      );
      final json = await exportLibraryBackup();

      tempDir = await installFakePathProvider();

      await importLibraryBackup(json);
      expect(await SpellArtStore.loadFull('0xh1'), Uint8List.fromList([1, 2, 3]));
      expect(await SpellArtStore.loadThumb('0xh1'), Uint8List.fromList([4, 5]));
    });
  });
}
