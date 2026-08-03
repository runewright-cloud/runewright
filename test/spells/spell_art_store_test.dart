// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_store.dart';

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

  const spellHashHex = '0xabc123';
  final full = Uint8List.fromList([1, 2, 3, 4]);
  final thumb = Uint8List.fromList([9, 8, 7]);

  test('loadFull/loadThumb return null when nothing is stored', () async {
    expect(await SpellArtStore.loadFull(spellHashHex), isNull);
    expect(await SpellArtStore.loadThumb(spellHashHex), isNull);
  });

  test('save() then load() round-trips both variants', () async {
    await SpellArtStore.save(spellHashHex, full: full, thumb: thumb);

    expect(await SpellArtStore.loadFull(spellHashHex), equals(full));
    expect(await SpellArtStore.loadThumb(spellHashHex), equals(thumb));
  });

  test('save() overwrites previously stored art for the same key', () async {
    await SpellArtStore.save(spellHashHex, full: full, thumb: thumb);
    final newFull = Uint8List.fromList([5, 5, 5]);
    final newThumb = Uint8List.fromList([6, 6]);
    await SpellArtStore.save(spellHashHex, full: newFull, thumb: newThumb);

    expect(await SpellArtStore.loadFull(spellHashHex), equals(newFull));
    expect(await SpellArtStore.loadThumb(spellHashHex), equals(newThumb));
  });

  test('delete() removes stored art and is a no-op if already absent', () async {
    await SpellArtStore.save(spellHashHex, full: full, thumb: thumb);
    await SpellArtStore.delete(spellHashHex);

    expect(await SpellArtStore.loadFull(spellHashHex), isNull);
    expect(await SpellArtStore.loadThumb(spellHashHex), isNull);

    // No-op on an already-empty key.
    await SpellArtStore.delete(spellHashHex);
  });

  test('different spellHashHex keys do not collide', () async {
    await SpellArtStore.save('0xaaaa', full: full, thumb: thumb);
    await SpellArtStore.save('0xbbbb', full: Uint8List.fromList([0]), thumb: Uint8List.fromList([1]));

    expect(await SpellArtStore.loadFull('0xaaaa'), equals(full));
    expect(await SpellArtStore.loadFull('0xbbbb'), equals(Uint8List.fromList([0])));
  });
}
