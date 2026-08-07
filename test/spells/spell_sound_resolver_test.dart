// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/sighting_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_sound_pack.dart';
import 'package:rune_duel/spells/spell_sound_resolver.dart';
import 'package:rune_duel/spells/spell_sound_store.dart';

import 'fake_path_provider.dart';

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

  SpellAsset sample({
    List<String> formula = const [],
    String commitmentHex = '0xaabbcc',
    String spellHashHex = '0xddeeff',
  }) =>
      SpellAsset(
        id: 'spell-1',
        createdAt: DateTime.utc(2026, 6, 19),
        tier: 12,
        t: 5,
        ownerPubkeyHex: '0x1234abcd',
        manaCost: 42,
        segmentCount: 3,
        dotCount: 1,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: 'Ember Wake',
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
      );

  group('elementForSoundDefault', () {
    test('picks the most frequent recognized element', () {
      expect(
        elementForSoundDefault(['fire', 'fire', 'air']),
        equals('fire'),
      );
    });

    test('defaults to neutral for an empty formula', () {
      expect(elementForSoundDefault(const []), equals('neutral'));
    });

    test('is case-insensitive and ignores unrecognized tokens', () {
      expect(elementForSoundDefault(['WATER', 'bogus']), equals('water'));
    });
  });

  group('defaultPackSoundFor (D-6)', () {
    test('picks a spell-category clip matching the dominant element', () {
      final entry = defaultPackSoundFor(formula: ['fire', 'fire'], identity: '0xabc');
      expect(entry, isNotNull);
      expect(entry!.element, equals('fire'));
      expect(entry.category, equals('spell'));
    });

    test('is deterministic for the same identity', () {
      final a = defaultPackSoundFor(formula: ['air'], identity: '0xsame');
      final b = defaultPackSoundFor(formula: ['air'], identity: '0xsame');
      expect(a!.id, equals(b!.id));
    });

    test('never returns an ambient-category clip', () {
      for (final element in ['fire', 'air', 'water', 'earth', 'neutral']) {
        final entry = defaultPackSoundFor(formula: [element], identity: '0x$element');
        expect(entry!.category, equals('spell'));
      }
    });
  });

  group('resolveSpellSound', () {
    test('resolves a built-in pack sound via soundPackId, no store access', () async {
      final entry = kSpellSoundPack.firstWhere((e) => e.category == 'spell');
      final spell = sample().withPackSound(packId: entry.id);

      final bytes = await resolveSpellSound(spell);
      expect(bytes, isNotNull);
      expect(bytes!.isNotEmpty, isTrue);
    });

    test('resolves an imported sound from SpellSoundStore', () async {
      final spell = sample().withSound(hash: '0xf00d', source: SpellSoundSource.localImport);
      await SpellSoundStore.save(spell.spellHashHex, Uint8List.fromList([1, 2, 3]));

      final bytes = await resolveSpellSound(spell);
      expect(bytes, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('falls back to the D-6 elemental default when no sound is set', () async {
      final spell = sample(formula: ['water', 'water']);
      final bytes = await resolveSpellSound(spell);
      expect(bytes, isNotNull);
      expect(bytes!.isNotEmpty, isTrue);
    });
  });

  group('resolveSightingSound', () {
    test('resolves a built-in pack sound via soundPackId for a sighting', () async {
      final entry = kSpellSoundPack.firstWhere((e) => e.category == 'spell');
      final sighting = await SightingAsset.record(
        opponentPubkeyHex: '0xopponent',
        commitmentHex: '0xaabbcc',
        spellName: 'Ember Wake',
        t: 1,
        tier: 12,
        manaCost: 10,
      );
      final withSound = sighting.withSound(
        hash: entry.sha256,
        source: SpellSoundSource.builtIn,
        packId: entry.id,
      );

      final bytes = await resolveSightingSound(withSound);
      expect(bytes, isNotNull);
      expect(bytes!.isNotEmpty, isTrue);
    });

    test('falls back to the D-6 elemental default for a sighting with no sound', () async {
      final sighting = await SightingAsset.record(
        opponentPubkeyHex: '0xopponent',
        commitmentHex: '0xaabbcc',
        spellName: 'Ember Wake',
        formula: const ['earth', 'earth'],
        t: 1,
        tier: 12,
        manaCost: 10,
      );

      final bytes = await resolveSightingSound(sighting);
      expect(bytes, isNotNull);
    });
  });
}
