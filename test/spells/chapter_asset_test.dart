// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/border_zone.dart';
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
    test('isUnattunedCounterCharm is true only for a trajectory-less charm', () {
      const unattuned = ArtifactEntry(kind: ArtifactKind.counterCharm);
      const attuned = ArtifactEntry(
        kind: ArtifactKind.counterCharm,
        trajectory: [BorderZone.fire, BorderZone.fire, BorderZone.air],
      );
      const gem = ArtifactEntry(kind: ArtifactKind.manaGem);

      expect(unattuned.isUnattunedCounterCharm, isTrue);
      expect(attuned.isUnattunedCounterCharm, isFalse);
      expect(gem.isUnattunedCounterCharm, isFalse);
    });

    test('copyWith attunes a trajectory without disturbing kind', () {
      const unattuned = ArtifactEntry(kind: ArtifactKind.counterCharm);
      final attuned = unattuned.copyWith(
        trajectory: const [BorderZone.water, BorderZone.water, BorderZone.earth],
      );

      expect(attuned.kind, ArtifactKind.counterCharm);
      expect(attuned.trajectory,
          const [BorderZone.water, BorderZone.water, BorderZone.earth]);
      expect(unattuned.trajectory, isNull); // original untouched
    });

    test('toJson/fromJson round-trips an unattuned charm', () {
      const entry = ArtifactEntry(kind: ArtifactKind.counterCharm);
      final restored = ArtifactEntry.fromJson(entry.toJson());

      expect(restored.kind, ArtifactKind.counterCharm);
      expect(restored.trajectory, isNull);
      expect(restored.isUnattunedCounterCharm, isTrue);
    });

    test('toJson/fromJson round-trips an attuned charm', () {
      const entry = ArtifactEntry(
        kind: ArtifactKind.counterCharm,
        trajectory: [
          BorderZone.fire, BorderZone.air, BorderZone.water,
          BorderZone.earth, BorderZone.fire, BorderZone.fire,
        ],
      );
      final restored = ArtifactEntry.fromJson(entry.toJson());

      expect(restored.trajectory, entry.trajectory);
      expect(restored.isUnattunedCounterCharm, isFalse);
    });

    test('a charm persisted under the old grid binding loads as unattuned', () {
      // targetCommitmentHex said nothing about behaviour, so there is nothing
      // to migrate it to — the player re-types a trajectory.
      final restored = ArtifactEntry.fromJson({
        'kind': 'counterCharm',
        'targetCommitmentHex': '0xabc',
        'targetSpellName': 'Ember Wake',
      });

      expect(restored.kind, ArtifactKind.counterCharm);
      expect(restored.isUnattunedCounterCharm, isTrue);
    });

    test('a trajectory that is not a whole number of formulas loads as '
        'unattuned rather than as a charm that silently never fires', () {
      final restored = ArtifactEntry.fromJson({
        'kind': 'counterCharm',
        'trajectory': ['fire', 'air'],
      });
      expect(restored.isUnattunedCounterCharm, isTrue);
    });
  });

  group('ChapterAsset.unattunedCounterCharmCount', () {
    test('counts only trajectory-less counter charms', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          trajectory: [BorderZone.fire, BorderZone.fire, BorderZone.fire],
        ),
        ArtifactEntry(kind: ArtifactKind.manaGem),
      ]);

      expect(chapter.unattunedCounterCharmCount, 2);
    });

    test('is zero for a chapter with no charms', () {
      final chapter = sample();
      expect(chapter.unattunedCounterCharmCount, 0);
    });
  });

  group('ChapterAsset.attuneFirstUnattunedCounterCharm', () {
    const fff = [BorderZone.fire, BorderZone.fire, BorderZone.fire];
    const www = [BorderZone.water, BorderZone.water, BorderZone.water];

    test('returns null when there is no unattuned charm', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.counterCharm, trajectory: fff),
      ]);

      expect(chapter.attuneFirstUnattunedCounterCharm(trajectory: www), isNull);
    });

    test('returns null for a trajectory that is not whole formulas', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
      ]);

      expect(
        chapter.attuneFirstUnattunedCounterCharm(
          trajectory: const [BorderZone.fire, BorderZone.air],
        ),
        isNull,
      );
      expect(
        chapter.attuneFirstUnattunedCounterCharm(trajectory: const []),
        isNull,
      );
    });

    test('attunes the first unattuned charm and leaves the rest untouched', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
      ]);

      final result = chapter.attuneFirstUnattunedCounterCharm(trajectory: fff);

      expect(result, isNotNull);
      expect(result!.artifacts.length, 3);
      expect(result.unattunedCounterCharmCount, 1);

      final attuned = result.artifacts.firstWhere(
          (a) => a.isCounterCharm && !a.isUnattunedCounterCharm);
      expect(attuned.trajectory, fff);

      // Original chapter is unmodified (immutable model).
      expect(chapter.unattunedCounterCharmCount, 2);
    });

    test('attuning twice consumes two separate unattuned charms', () {
      var chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(kind: ArtifactKind.counterCharm),
      ]);

      chapter = chapter.attuneFirstUnattunedCounterCharm(trajectory: fff)!;
      expect(chapter.unattunedCounterCharmCount, 1);

      chapter = chapter.attuneFirstUnattunedCounterCharm(trajectory: www)!;
      expect(chapter.unattunedCounterCharmCount, 0);

      final trajectories = chapter.artifacts
          .where((a) => a.isCounterCharm)
          .map((a) => a.trajectory)
          .toList();
      expect(trajectories, containsAll(<List<BorderZone>>[fff, www]));
    });
  });

  group('ChapterAsset.withArtifactAt', () {
    test('re-attunes an already-attuned charm in place', () {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          trajectory: [BorderZone.fire, BorderZone.fire, BorderZone.fire],
        ),
      ]);

      final updated = chapter.withArtifactAt(
        1,
        const ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          trajectory: [BorderZone.air, BorderZone.air, BorderZone.air],
        ),
      );

      expect(updated.artifacts.length, 2);
      expect(updated.artifacts[0].kind, ArtifactKind.manaGem);
      expect(updated.artifacts[1].trajectory,
          const [BorderZone.air, BorderZone.air, BorderZone.air]);
      // Original untouched.
      expect(chapter.artifacts[1].trajectory,
          const [BorderZone.fire, BorderZone.fire, BorderZone.fire]);
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
    test('save/loadById round-trips unattuned and attuned charms', () async {
      final chapter = sample(artifacts: const [
        ArtifactEntry(kind: ArtifactKind.counterCharm),
        ArtifactEntry(
          kind: ArtifactKind.counterCharm,
          trajectory: [BorderZone.fire, BorderZone.air, BorderZone.water],
        ),
      ]);
      await chapter.save();

      final loaded = await ChapterAsset.loadById('chapter-1');
      expect(loaded, isNotNull);
      expect(loaded!.unattunedCounterCharmCount, 1);
      expect(
        loaded.artifacts.any((a) =>
            a.trajectory != null &&
            listEquals(a.trajectory,
                const [BorderZone.fire, BorderZone.air, BorderZone.water])),
        isTrue,
      );
    });
  });
}
