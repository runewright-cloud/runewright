// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/chapter_asset.dart';

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

  ChapterAsset sample({List<ArtifactEntry> artifacts = const []}) => ChapterAsset(
        id: 'chapter-1',
        name: 'Test Chapter',
        createdAt: DateTime.utc(2026, 7, 24, 12, 0, 0),
        artifacts: artifacts,
      );

  group('ArtifactEntry', () {
    test('isUnboundCounterCharm is true only for a commitment-less counter charm', () {
      const unbound = ArtifactEntry(kind: ArtifactKind.counterCharm);
      const bound = ArtifactEntry(
        kind: ArtifactKind.counterCharm,
        targetCommitmentHex: '0xabc',
        targetSpellName: 'Ember Wake',
      );
      const gem = ArtifactEntry(kind: ArtifactKind.manaGem);

      expect(unbound.isUnboundCounterCharm, isTrue);
      expect(bound.isUnboundCounterCharm, isFalse);
      expect(gem.isUnboundCounterCharm, isFalse);
    });

    test('copyWith binds a target without disturbing kind', () {
      const unbound = ArtifactEntry(kind: ArtifactKind.counterCharm);
      final bound = unbound.copyWith(
        targetCommitmentHex: '0xabc',
        targetSpellName: 'Ember Wake',
      );

      expect(bound.kind, ArtifactKind.counterCharm);
      expect(bound.targetCommitmentHex, '0xabc');
      expect(bound.targetSpellName, 'Ember Wake');
      expect(unbound.targetCommitmentHex, isNull); // original untouched
    });

    test('toJson/fromJson round-trips an unbound charm', () {
      const entry = ArtifactEntry(kind: ArtifactKind.counterCharm);
      final restored = ArtifactEntry.fromJson(entry.toJson());

      expect(restored.kind, ArtifactKind.counterCharm);
      expect(restored.targetCommitmentHex, isNull);
      expect(restored.targetSpellName, isNull);
      expect(restored.isUnboundCounterCharm, isTrue);
    });

    test('toJson/fromJson round-trips a bound charm', () {
      const entry = ArtifactEntry(
        kind: ArtifactKind.counterCharm,
        targetCommitmentHex: '0xabc',
        targetSpellName: 'Ember Wake',
      );
      final restored = ArtifactEntry.fromJson(entry.toJson());

      expect(restored.targetCommitmentHex, '0xabc');
      expect(restored.targetSpellName, 'Ember Wake');
      expect(restored.isUnboundCounterCharm, isFalse);
    });
  });

  group('ChapterAsset.unboundCounterCharmCount', () {
    test('counts only commitment-less counter charms', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          targetCommitmentHex: '0xabc',
          targetSpellName: 'Ember Wake',
        ),
        ArtifactEntry(kind: ArtifactKind.manaGem),
      ]);

      expect(chapter.unboundCounterCharmCount, 2);
    });

    test('is zero for a chapter with no charms', () {
      final chapter = sample();
      expect(chapter.unboundCounterCharmCount, 0);
    });
  });

  group('ChapterAsset.bindFirstUnboundCounterCharm', () {
    test('returns null when there is no unbound charm', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          targetCommitmentHex: '0xalready',
          targetSpellName: 'Bound Already',
        ),
      ]);

      final result = chapter.bindFirstUnboundCounterCharm(
        commitmentHex: '0xnew',
        spellName: 'New Target',
      );

      expect(result, isNull);
    });

    test('binds the first unbound charm and leaves the rest untouched', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
      ]);

      final result = chapter.bindFirstUnboundCounterCharm(
        commitmentHex: '0xnew',
        spellName: 'New Target',
      );

      expect(result, isNotNull);
      expect(result!.artifacts.length, 3);
      expect(result.unboundCounterCharmCount, 1);

      final bound = result.artifacts.firstWhere((a) => !a.isUnboundCounterCharm && a.kind == ArtifactKind.counterCharm);
      expect(bound.targetCommitmentHex, '0xnew');
      expect(bound.targetSpellName, 'New Target');

      // Original chapter is unmodified (immutable model).
      expect(chapter.unboundCounterCharmCount, 2);
    });

    test('binding twice consumes two separate unbound charms', () {
      var chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
      ]);

      chapter = chapter.bindFirstUnboundCounterCharm(
        commitmentHex: '0xfirst',
        spellName: 'First',
      )!;
      expect(chapter.unboundCounterCharmCount, 1);

      chapter = chapter.bindFirstUnboundCounterCharm(
        commitmentHex: '0xsecond',
        spellName: 'Second',
      )!;
      expect(chapter.unboundCounterCharmCount, 0);

      final commitments = chapter.artifacts
          .where((a) => a.kind == ArtifactKind.counterCharm)
          .map((a) => a.targetCommitmentHex)
          .toSet();
      expect(commitments, {'0xfirst', '0xsecond'});
    });
  });

  group('ChapterEntry.summonPersonality', () {
    test('defaults to null (use the spell\'s own default)', () {
      const entry = ChapterEntry(spellId: 'spell-1');
      expect(entry.summonPersonality, isNull);
      expect(entry.toJson().containsKey('summonPersonality'), isFalse);
    });

    test('toJson/fromJson round-trips a chosen personality', () {
      const entry = ChapterEntry(spellId: 'spell-1', summonPersonality: 'evasive');
      final restored = ChapterEntry.fromJson(entry.toJson());

      expect(restored.spellId, equals('spell-1'));
      expect(restored.summonPersonality, equals('evasive'));
    });

    test('a legacy entry JSON predating this field (no such key) still loads, with '
        'summonPersonality null', () {
      final restored = ChapterEntry.fromJson({'spellId': 'spell-1'});
      expect(restored.summonPersonality, isNull);
    });
  });

  group('ChapterAsset persistence', () {
    test('save/loadById round-trips unbound and bound charms', () async {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          targetCommitmentHex: '0xabc',
          targetSpellName: 'Ember Wake',
        ),
      ]);
      await chapter.save();

      final loaded = await ChapterAsset.loadById('chapter-1');
      expect(loaded, isNotNull);
      expect(loaded!.unboundCounterCharmCount, 1);
      expect(
        loaded.artifacts.any((a) => a.targetCommitmentHex == '0xabc'),
        isTrue,
      );
    });
  });
}
