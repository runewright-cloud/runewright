// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_pack.dart';
import 'package:rune_duel/spells/spell_art_resolver.dart';
import 'package:rune_duel/spells/spell_art_store.dart';
import 'package:rune_duel/spells/spell_asset.dart';

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

  SpellAsset sample({String id = 'spell-1'}) => SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 6, 19, 12, 0, 0),
        tier: 12,
        t: 5,
        ownerPubkeyHex: '0x1234abcd',
        manaCost: 42,
        segmentCount: 3,
        dotCount: 1,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        name: 'Ember Wake',
        commitmentHex: '0xaabbcc',
        spellHashHex: '0xddeeff',
      );

  test('a spell with no art resolves to null for both full and thumb', () async {
    final spell = sample();
    expect(await resolveSpellArtFull(spell), isNull);
    expect(await resolveSpellArtThumb(spell), isNull);
  });

  group('SpellArtSource.localImport', () {
    test('resolves from SpellArtStore, keyed by spellHashHex', () async {
      final full = Uint8List.fromList([1, 2, 3]);
      final thumb = Uint8List.fromList([4, 5]);
      await SpellArtStore.save('0xddeeff', full: full, thumb: thumb);
      final spell = sample().withArt(hash: '0xaaaa', source: SpellArtSource.localImport);

      expect(await resolveSpellArtFull(spell), equals(full));
      expect(await resolveSpellArtThumb(spell), equals(thumb));
    });

    test('resolves to null on a store miss (pointer with no blob)', () async {
      final spell = sample().withArt(hash: '0xaaaa', source: SpellArtSource.localImport);
      expect(await resolveSpellArtFull(spell), isNull);
    });
  });

  group('SpellArtSource.builtIn', () {
    test('resolves from the asset bundle via artPackId, ignoring SpellArtStore', () async {
      final entry = kPainterlyPack.first;
      // Deliberately store different bytes under spellHashHex, to prove the
      // resolver does NOT fall back to SpellArtStore for built-in art.
      await SpellArtStore.save('0xddeeff',
          full: Uint8List.fromList([9, 9, 9]), thumb: Uint8List.fromList([9, 9]));
      final spell = sample().withPackArt(packId: entry.id);

      final full = await resolveSpellArtFull(spell);
      final thumb = await resolveSpellArtThumb(spell);
      expect(full, isNotNull);
      expect(full!.length, entry.bytes);
      // Same 256px file serves both roles (plan §4 B-1: no separate thumbnail).
      expect(thumb, equals(full));
    });

    test('resolves to null for an artPackId not in kPainterlyPack', () async {
      // Constructed via fromJson since withPackArt() itself validates the id.
      final spell = SpellAsset.fromJson({
        ...sample().toJson(),
        'artHash': '0xsomething',
        'artSource': 'builtIn',
        'artPackId': 'not-a-real-id',
      });
      expect(await resolveSpellArtFull(spell), isNull);
    });
  });
}
