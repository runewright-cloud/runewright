// SPDX-License-Identifier: GPL-3.0-or-later
//
// An Aetherial Armor must never reach the castable hand. The library UI
// refuses to add one to a chapter's spell list, but chapter data does not only
// come from this build's UI — a hand-edited file, a backup restored from an
// older build, or an import path that forgets the rule can all produce one.
// Chapter.fromChapterAsset is the last place to catch it before the engine is
// asked to resolve a cast for something that has no cast.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/chapter.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../../spells/fake_path_provider.dart';

SpellAsset spell({
  required String id,
  required String commitmentHex,
  bool isArmor = false,
  bool isSummon = false,
}) =>
    SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 25),
      tier: 12,
      t: 4,
      ownerPubkeyHex: '0x2a',
      manaCost: 5,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: Uint8List(0),
      name: id,
      commitmentHex: commitmentHex,
      spellHashHex: '',
      isArmor: isArmor,
      isSummon: isSummon,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('an armor present as a castable chapter entry is dropped from the '
      'battle chapter', () async {
    await spell(id: 'ordinary', commitmentHex: '0x01').save();
    await spell(id: 'armour', commitmentHex: '0x02', isArmor: true).save();
    await spell(id: 'summon', commitmentHex: '0x03', isSummon: true).save();

    final asset = ChapterAsset(
      id: 'c1',
      name: 'Hand-edited Chapter',
      createdAt: DateTime.utc(2026, 8, 25),
      entries: const [
        ChapterEntry(spellId: 'ordinary'),
        ChapterEntry(spellId: 'armour'), // must not survive
        ChapterEntry(spellId: 'summon'),
      ],
    );

    final chapter = await Chapter.fromChapterAsset(asset, 3);

    expect(chapter.spells.map((s) => s.id), ['ordinary', 'summon']);
    expect(chapter.spells.any((s) => s.isArmor), isFalse);
    expect(chapter.commitmentHexes, ['0x01', '0x03']);
  });

  test('a chapter whose only entry is an armor yields an empty spell list, '
      'not a hand with an unresolvable card', () async {
    await spell(id: 'armour', commitmentHex: '0x02', isArmor: true).save();

    final chapter = await Chapter.fromChapterAsset(
      ChapterAsset(
        id: 'c2',
        name: 'Armor Only',
        createdAt: DateTime.utc(2026, 8, 25),
        entries: const [ChapterEntry(spellId: 'armour')],
      ),
      3,
    );

    expect(chapter.spells, isEmpty);
  });

  test('the armor BINDING is untouched — it is not a spell entry', () async {
    await spell(id: 'ordinary', commitmentHex: '0x01').save();
    await spell(id: 'armour', commitmentHex: '0x02', isArmor: true).save();

    final asset = ChapterAsset(
      id: 'c3',
      name: 'Normal Chapter',
      createdAt: DateTime.utc(2026, 8, 25),
      entries: const [ChapterEntry(spellId: 'ordinary')],
      armorSpellId: 'armour',
    );
    final chapter = await Chapter.fromChapterAsset(asset, 3);

    expect(chapter.spells.map((s) => s.id), ['ordinary']);
    expect(asset.armorSpellId, 'armour');
  });
}
