// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_test.dart — Chapter.fromChapterAsset's per-entry personality
// binding (design doc "Personalities"): a summon's battlefield-behavior
// glyph is chosen when the spell is added to a Chapter, not at inscription,
// so ChapterEntry.summonPersonality (when set) must override the resolved
// SpellAsset's own summonPersonality default rather than being ignored.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/chapter.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../../spells/fake_path_provider.dart';

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

  SpellAsset summonSpell(String id) => SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 7, 27),
        tier: 12,
        t: 1,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: 'Test Summon',
        commitmentHex: '0x$id',
        spellHashHex: '0xhash$id',
        isSummon: true,
      );

  test(
      'a chapter entry with a chosen personality overrides the resolved '
      "spell's own summonPersonality default", () async {
    final spell = summonSpell('a');
    expect(spell.summonPersonality, equals('aggressive')); // the class default
    await spell.save();

    final asset = ChapterAsset(
      id: 'chapter-1',
      name: 'Test Chapter',
      createdAt: DateTime.utc(2026, 7, 27),
      entries: const [ChapterEntry(spellId: 'a', summonPersonality: 'evasive')],
    );

    final chapter = await Chapter.fromChapterAsset(asset, 3);

    expect(chapter.spells, hasLength(1));
    expect(chapter.spells.single.summonPersonality, equals('evasive'));
  });

  test('a chapter entry with no chosen personality falls back to the '
      "spell's own summonPersonality default", () async {
    final spell = summonSpell('b');
    await spell.save();

    final asset = ChapterAsset(
      id: 'chapter-2',
      name: 'Test Chapter',
      createdAt: DateTime.utc(2026, 7, 27),
      entries: const [ChapterEntry(spellId: 'b')],
    );

    final chapter = await Chapter.fromChapterAsset(asset, 3);

    expect(chapter.spells.single.summonPersonality, equals('aggressive'));
  });
}
