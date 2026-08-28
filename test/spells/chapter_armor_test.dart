// SPDX-License-Identifier: GPL-3.0-or-later
//
// Aetherial Armor slice 2: the persistence marker, the chapter binding, and
// artifact-slot accounting. Pure model/JSON tests -- no proving, no FFI, and
// (except where a persisted round trip is the point) no file I/O.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/chapter_armor.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'fake_path_provider.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

SpellAsset spell({
  String id = 'spell-1',
  int t = 5,
  bool isSummon = false,
  bool isArmor = false,
  String name = 'Ember Wake',
}) =>
    SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 25),
      tier: t <= 12 ? 12 : (t <= 24 ? 24 : 48),
      t: t,
      ownerPubkeyHex: '0xaa',
      manaCost: 10,
      segmentCount: 1,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: name,
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
      isSummon: isSummon,
      isArmor: isArmor,
    );

SpellAsset armorOfT(int t, {String id = 'armor-1'}) =>
    spell(id: id, t: t, isArmor: true, name: 'Aetherial Plate');

ChapterAsset chapter({
  List<ArtifactEntry> artifacts = const [],
  String? armorSpellId,
}) =>
    ChapterAsset(
      id: 'chapter-1',
      name: 'Test Chapter',
      createdAt: DateTime.utc(2026, 8, 25),
      artifacts: artifacts,
      armorSpellId: armorSpellId,
    );

List<ArtifactEntry> gems(int n) =>
    List.generate(n, (_) => const ArtifactEntry(kind: ArtifactKind.manaGem));

void main() {
  // ── SpellAsset.isArmor ──────────────────────────────────────────────────────

  group('SpellAsset.isArmor', () {
    test('old JSON without isArmor loads as a non-armor spell', () {
      final json = spell().toJson()..remove('isArmor');
      expect(json.containsKey('isArmor'), isFalse);
      expect(SpellAsset.fromJson(json).isArmor, isFalse);
    });

    test('a non-armor spell does not write the key at all — byte-identical to '
        'how it serialised before armor existed', () {
      expect(spell().toJson().containsKey('isArmor'), isFalse);
      expect(spell(isSummon: true).toJson().containsKey('isArmor'), isFalse);
    });

    test('the armor marker round-trips through JSON', () {
      final round = SpellAsset.fromJson(jsonDecode(
          jsonEncode(armorOfT(9).toJson())) as Map<String, dynamic>);
      expect(round.isArmor, isTrue);
      expect(round.isSummon, isFalse);
      expect(round.t, 9);
    });

    test('summon behaviour is untouched', () {
      final round = SpellAsset.fromJson(spell(isSummon: true).toJson());
      expect(round.isSummon, isTrue);
      expect(round.isArmor, isFalse);
    });

    test('an asset cannot be both a Summon and an Armor', () {
      expect(() => spell(isSummon: true, isArmor: true), throwsArgumentError);
    });

    test('JSON claiming both modes loads as a summon, not as a crash', () {
      final json = spell(isSummon: true).toJson()..['isArmor'] = true;
      final loaded = SpellAsset.fromJson(json);
      expect(loaded.isSummon, isTrue);
      expect(loaded.isArmor, isFalse);
    });

    test('every copy path carries the armor marker forward', () {
      final armor = armorOfT(9);
      expect(armor.withName('Runeplate').isArmor, isTrue);
      expect(armor.withSupremeTags(const ['fire']).isArmor, isTrue);
      expect(armor.withSummonPersonality('evasive').isArmor, isTrue);
      expect(armor.withGridWithheld().isArmor, isTrue);
      expect(armor.withoutArt().isArmor, isTrue);
      expect(armor.withoutSound().isArmor, isTrue);
      expect(
        armor.withArt(hash: 'abc', source: SpellArtSource.localImport).isArmor,
        isTrue,
      );
      expect(
        armor.withSound(hash: 'abc', source: SpellSoundSource.localImport).isArmor,
        isTrue,
      );
      // ...and does not invent one on an ordinary spell.
      expect(spell().withName('Other').isArmor, isFalse);
    });
  });

  // ── ChapterAsset.armorSpellId ───────────────────────────────────────────────

  group('ChapterAsset armor binding', () {
    test('old JSON without armorSpellId loads as a no-armor chapter', () {
      final json = chapter(artifacts: gems(2)).toJson();
      expect(json.containsKey('armorSpellId'), isFalse);
      final loaded = ChapterAsset.fromJson(json);
      expect(loaded.armorSpellId, isNull);
      expect(loaded.hasArmor, isFalse);
      expect(loaded.artifacts, hasLength(2));
    });

    test('a bound armor round-trips through JSON', () {
      final bound = chapter().withArmor('armor-1');
      final round = ChapterAsset.fromJson(
          jsonDecode(jsonEncode(bound.toJson())) as Map<String, dynamic>);
      expect(round.armorSpellId, 'armor-1');
      expect(round.hasArmor, isTrue);
    });

    test('at most one armor: binding a second replaces the first', () {
      final bound = chapter().withArmor('armor-1').withArmor('armor-2');
      expect(bound.armorSpellId, 'armor-2');
      // Structural, not validated: the field simply cannot hold two.
      expect(bound.toJson()['armorSpellId'], 'armor-2');
    });

    test('withoutArmor clears the binding', () {
      expect(chapter().withArmor('armor-1').withoutArmor().hasArmor, isFalse);
    });

    test('every chapter copy path preserves the binding', () {
      final bound = chapter(artifacts: gems(2)).withArmor('armor-1');
      expect(bound.rename('New Name').armorSpellId, 'armor-1');
      expect(bound.copyAsNew('Copy').armorSpellId, 'armor-1');
      expect(
        bound.withEntry(const ChapterEntry(spellId: 's1')).armorSpellId,
        'armor-1',
      );
      expect(
        bound
            .withEntry(const ChapterEntry(spellId: 's1'))
            .withoutEntryAt(0)
            .armorSpellId,
        'armor-1',
      );
      expect(
        bound.withArtifact(const ArtifactEntry(kind: ArtifactKind.bookmark))
            .armorSpellId,
        'armor-1',
      );
      expect(
        bound
            .withArtifactAt(0, const ArtifactEntry(kind: ArtifactKind.bookmark))
            .armorSpellId,
        'armor-1',
      );
      expect(bound.withoutArtifactAt(0).armorSpellId, 'armor-1');
    });
  });

  // ── Slot accounting ─────────────────────────────────────────────────────────

  group('slot cost — ceil(T/4) from the locally stored T', () {
    test('T 1-4 costs one slot', () {
      for (final t in [1, 2, 3, 4]) {
        expect(localArmorSlotCost(armorOfT(t)), 1, reason: 'T=$t');
      }
    });

    test('T=5 costs two slots', () => expect(localArmorSlotCost(armorOfT(5)), 2));

    test('T=9 costs three slots', () => expect(localArmorSlotCost(armorOfT(9)), 3));

    test('T=48 costs all twelve slots', () {
      expect(localArmorSlotCost(armorOfT(48)), ChapterAsset.maxArtifactSlots);
    });

    test('slots used = ordinary artifacts + armor cost', () {
      final armor = armorOfT(9);
      final ch = chapter(artifacts: gems(9)).withArmor(armor.id);
      expect(ch.ordinaryArtifactCount, 9);
      expect(chapterSlotsUsed(ch, armor), 12);
      expect(chapterSlotsRemaining(ch, armor), 0);
    });

    test('a chapter with no armor ignores any cost handed to it', () {
      final ch = chapter(artifacts: gems(3));
      expect(ch.artifactSlotsUsed(armorSlotCost: 12), 3);
      expect(ch.artifactSlotsRemaining(armorSlotCost: 12), 9);
    });

    test('replacing a T9 armor with a T4 armor releases two slots', () {
      final big = armorOfT(9, id: 'armor-big');
      final small = armorOfT(4, id: 'armor-small');
      final ch = chapter(artifacts: gems(9)).withArmor(big.id);
      expect(chapterSlotsRemaining(ch, big), 0);

      final swapped = bindArmor(ch, small);
      expect(swapped, isNotNull);
      expect(swapped!.armorSpellId, 'armor-small');
      expect(chapterSlotsRemaining(swapped, small), 2);
    });

    test('removing armor restores ordinary 12-slot behaviour', () {
      final armor = armorOfT(9);
      final ch = chapter(artifacts: gems(3)).withArmor(armor.id);
      expect(chapterSlotsRemaining(ch, armor), 6);

      final bare = unbindArmor(ch);
      expect(bare.hasArmor, isFalse);
      expect(chapterSlotsRemaining(bare, null), 9);
      expect(bare.artifactSlotsRemaining(armorSlotCost: 0), 9);
    });

    test('an unresolvable binding contributes nothing rather than throwing', () {
      // Normally impossible: deleting a spell clears the binding. Pinned so the
      // accounting degrades to "no armor" instead of crashing the editor.
      final ch = chapter(artifacts: gems(3)).withArmor('gone');
      expect(chapterSlotsRemaining(ch, null), 9);
    });
  });

  // ── Binding validation ──────────────────────────────────────────────────────

  group('bindArmor validation', () {
    test('a non-armor spell cannot be bound', () {
      expect(armorBindError(chapter(), spell()), ArmorBindError.notAnArmor);
      expect(bindArmor(chapter(), spell()), isNull);
    });

    test('a summon cannot be bound as armor', () {
      final summon = spell(isSummon: true);
      expect(armorBindError(chapter(), summon), ArmorBindError.notAnArmor);
      expect(bindArmor(chapter(), summon), isNull);
    });

    test('an armor that would put the chapter over budget cannot be equipped',
        () {
      final armor = armorOfT(9); // 3 slots
      final ch = chapter(artifacts: gems(10)); // 10 + 3 = 13
      expect(armorBindError(ch, armor), ArmorBindError.exceedsSlotBudget);
      expect(bindArmor(ch, armor), isNull);
      // The chapter is returned unchanged -- no partial mutation.
      expect(ch.hasArmor, isFalse);
    });

    test('an armor that exactly fills the budget is accepted', () {
      final armor = armorOfT(9); // 3 slots
      final ch = chapter(artifacts: gems(9));
      expect(armorBindError(ch, armor), isNull);
      final bound = bindArmor(ch, armor);
      expect(bound!.armorSpellId, armor.id);
      expect(chapterSlotsRemaining(bound, armor), 0);
    });

    test('a full chapter can still swap to a cheaper armor', () {
      // Replacement measures only ordinary artifacts, since the outgoing
      // armor's slots are released by the swap itself.
      final big = armorOfT(48, id: 'armor-big'); // 12 slots
      final small = armorOfT(4, id: 'armor-small'); // 1 slot
      final ch = chapter().withArmor(big.id);
      expect(chapterSlotsRemaining(ch, big), 0);
      expect(bindArmor(ch, small)?.armorSpellId, 'armor-small');
    });

    test('binding does not require a proof or any I/O', () {
      // The whole group runs with no path provider installed and no verifier:
      // editing a local chapter must not cost a verification.
      expect(bindArmor(chapter(), armorOfT(4)), isNotNull);
    });
  });

  // ── Adding artifacts against the budget ─────────────────────────────────────

  group('addArtifactWithinBudget', () {
    test('T9 armor + 9 ordinary artifacts uses all 12 slots', () {
      final armor = armorOfT(9);
      final ch = chapter(artifacts: gems(9)).withArmor(armor.id);
      expect(chapterSlotsUsed(ch, armor), ChapterAsset.maxArtifactSlots);
    });

    test('adding another artifact in that state is rejected', () {
      final armor = armorOfT(9);
      final ch = chapter(artifacts: gems(9)).withArmor(armor.id);
      final added = addArtifactWithinBudget(
        ch,
        const ArtifactEntry(kind: ArtifactKind.bookmark),
        armor: armor,
      );
      expect(added, isNull);
      expect(ch.artifacts, hasLength(9));
    });

    test('armor cannot be bypassed by adding artifacts one at a time', () {
      final armor = armorOfT(9); // 3 slots
      var ch = chapter().withArmor(armor.id);
      var accepted = 0;
      for (var i = 0; i < 20; i++) {
        final next = addArtifactWithinBudget(
          ch,
          const ArtifactEntry(kind: ArtifactKind.manaGem),
          armor: armor,
        );
        if (next == null) break;
        ch = next;
        accepted++;
      }
      expect(accepted, 9);
      expect(chapterSlotsUsed(ch, armor), 12);
    });

    test('with no armor the budget is the old 12 artifacts', () {
      var ch = chapter();
      var accepted = 0;
      while (true) {
        final next = addArtifactWithinBudget(
          ch,
          const ArtifactEntry(kind: ArtifactKind.manaGem),
          armor: null,
        );
        if (next == null) break;
        ch = next;
        accepted++;
      }
      expect(accepted, ChapterAsset.maxArtifactSlots);
    });
  });

  // ── Persistence round trip through disk ─────────────────────────────────────

  group('persisted round trip', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await installFakePathProvider();
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a chapter armor binding survives save + loadById', () async {
      await chapter(artifacts: gems(2)).withArmor('armor-1').save();
      final loaded = await ChapterAsset.loadById('chapter-1');
      expect(loaded!.armorSpellId, 'armor-1');
      expect(loaded.artifacts, hasLength(2));
    });

    test('deleting the armor spell clears the binding rather than leaving it '
        'dangling and eating slots', () async {
      final armor = armorOfT(9, id: 'armor-1');
      await armor.save();
      await chapter(artifacts: gems(3)).withArmor(armor.id).save();

      await armor.delete();

      final loaded = await ChapterAsset.loadById('chapter-1');
      expect(loaded!.hasArmor, isFalse);
      expect(chapterSlotsRemaining(loaded, null), 9);
    });

    test('deleting an unrelated spell leaves the binding alone', () async {
      final armor = armorOfT(9, id: 'armor-1');
      final other = spell(id: 'other-1');
      await armor.save();
      await other.save();
      await chapter().withArmor(armor.id).save();

      await other.delete();

      expect((await ChapterAsset.loadById('chapter-1'))!.armorSpellId, 'armor-1');
    });
  });
}
