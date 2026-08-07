// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_pack.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_sound_pack.dart';

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

  test('toJson/fromJson round-trips exactly', () {
    final original = sample();
    final restored = SpellAsset.fromJson(original.toJson());

    expect(restored.id, equals(original.id));
    expect(restored.createdAt, equals(original.createdAt));
    expect(restored.tier, equals(original.tier));
    expect(restored.t, equals(original.t));
    expect(restored.ownerPubkeyHex, equals(original.ownerPubkeyHex));
    expect(restored.manaCost, equals(original.manaCost));
    expect(restored.initialGrid, equals(original.initialGrid));
    expect(restored.proofBytes, equals(original.proofBytes));
    expect(restored.name, equals(original.name));
    expect(restored.commitmentHex, equals(original.commitmentHex));
    expect(restored.spellHashHex, equals(original.spellHashHex));
    expect(restored.artHash, isNull);
    expect(restored.artSource, isNull);
    expect(restored.artUpdatedAt, isNull);
    expect(restored.soundHash, isNull);
    expect(restored.soundSource, isNull);
    expect(restored.soundUpdatedAt, isNull);
    expect(restored.soundPackId, isNull);
  });

  test('withSound() sets soundHash/soundSource and stamps soundUpdatedAt, leaving other '
      'fields unchanged', () {
    final original = sample();
    final withSound =
        original.withSound(hash: '0xf00d', source: SpellSoundSource.localImport);

    expect(withSound.soundHash, equals('0xf00d'));
    expect(withSound.soundSource, equals(SpellSoundSource.localImport));
    expect(withSound.soundUpdatedAt, isNotNull);
    expect(withSound.id, equals(original.id));
    expect(withSound.spellHashHex, equals(original.spellHashHex));

    final restored = SpellAsset.fromJson(withSound.toJson());
    expect(restored.soundHash, equals('0xf00d'));
    expect(restored.soundSource, equals(SpellSoundSource.localImport));
    expect(restored.soundUpdatedAt, equals(withSound.soundUpdatedAt));
  });

  test('withoutSound() clears sound metadata', () {
    final withSound =
        sample().withSound(hash: '0xf00d', source: SpellSoundSource.localImport);
    final cleared = withSound.withoutSound();

    expect(cleared.soundHash, isNull);
    expect(cleared.soundSource, isNull);
    expect(cleared.soundUpdatedAt, isNull);

    final restored = SpellAsset.fromJson(cleared.toJson());
    expect(restored.soundHash, isNull);
  });

  test(
      'withPackSound() sets soundHash/soundSource/soundPackId from the pack entry, leaving '
      'other fields unchanged', () {
    final original = sample();
    final entry = kSpellSoundPack.first;
    final withPack = original.withPackSound(packId: entry.id);

    expect(withPack.soundHash, equals(entry.sha256));
    expect(withPack.soundSource, equals(SpellSoundSource.builtIn));
    expect(withPack.soundPackId, equals(entry.id));
    expect(withPack.soundUpdatedAt, isNotNull);
    expect(withPack.id, equals(original.id));
    expect(withPack.spellHashHex, equals(original.spellHashHex));

    final restored = SpellAsset.fromJson(withPack.toJson());
    expect(restored.soundHash, equals(entry.sha256));
    expect(restored.soundSource, equals(SpellSoundSource.builtIn));
    expect(restored.soundPackId, equals(entry.id));
    expect(restored.soundUpdatedAt, equals(withPack.soundUpdatedAt));
  });

  test('withPackSound() throws for an id not in kSpellSoundPack', () {
    expect(() => sample().withPackSound(packId: 'not-a-real-id'), throwsArgumentError);
  });

  test('withSound() clears a previous soundPackId (import supersedes pack selection)', () {
    final withPack = sample().withPackSound(packId: kSpellSoundPack.first.id);
    final withImport =
        withPack.withSound(hash: '0xf00d', source: SpellSoundSource.localImport);

    expect(withImport.soundPackId, isNull);
    expect(withImport.soundHash, equals('0xf00d'));
    expect(withImport.soundSource, equals(SpellSoundSource.localImport));
  });

  test('withoutSound() clears soundPackId along with the rest of the sound metadata', () {
    final withPack = sample().withPackSound(packId: kSpellSoundPack.first.id);
    final cleared = withPack.withoutSound();

    expect(cleared.soundHash, isNull);
    expect(cleared.soundSource, isNull);
    expect(cleared.soundPackId, isNull);
  });

  test('a spell JSON predating any sound field still loads, with sound fields null', () {
    final original = sample().withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);
    final legacyJson = original.toJson();

    final restored = SpellAsset.fromJson(legacyJson);
    expect(restored.soundHash, isNull);
    expect(restored.soundSource, isNull);
    expect(restored.soundPackId, isNull);
    // Confirms art still round-trips fine on the same object -- this isn't
    // testing sound in isolation, it's testing that adding sound fields
    // didn't disturb the pre-existing art fields.
    expect(restored.artHash, equals('0xdeadbeef'));
  });

  test('withArt() and withGridWithheld() carry sound metadata through unchanged', () {
    final withSound = sample().withSound(hash: '0xf00d', source: SpellSoundSource.synced);

    final afterArt = withSound.withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);
    expect(afterArt.soundHash, equals('0xf00d'));
    expect(afterArt.soundSource, equals(SpellSoundSource.synced));

    final afterLoan = withSound.withGridWithheld();
    expect(afterLoan.soundHash, equals('0xf00d'));
    expect(afterLoan.soundSource, equals(SpellSoundSource.synced));
    expect(afterLoan.gridWithheld, isTrue);
  });

  test('withArt() sets artHash/artSource and stamps artUpdatedAt, leaving other fields unchanged',
      () {
    final original = sample();
    final withArt =
        original.withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);

    expect(withArt.artHash, equals('0xdeadbeef'));
    expect(withArt.artSource, equals(SpellArtSource.localImport));
    expect(withArt.artUpdatedAt, isNotNull);
    expect(withArt.id, equals(original.id));
    expect(withArt.spellHashHex, equals(original.spellHashHex));

    final restored = SpellAsset.fromJson(withArt.toJson());
    expect(restored.artHash, equals('0xdeadbeef'));
    expect(restored.artSource, equals(SpellArtSource.localImport));
    expect(restored.artUpdatedAt, equals(withArt.artUpdatedAt));
  });

  test('withoutArt() clears art metadata', () {
    final withArt =
        sample().withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);
    final cleared = withArt.withoutArt();

    expect(cleared.artHash, isNull);
    expect(cleared.artSource, isNull);
    expect(cleared.artUpdatedAt, isNull);

    final restored = SpellAsset.fromJson(cleared.toJson());
    expect(restored.artHash, isNull);
  });

  test(
      'withPackArt() sets artHash/artSource/artPackId from the pack entry, leaving other '
      'fields unchanged', () {
    final original = sample();
    final entry = kPainterlyPack.first;
    final withPack = original.withPackArt(packId: entry.id);

    expect(withPack.artHash, equals(entry.sha256));
    expect(withPack.artSource, equals(SpellArtSource.builtIn));
    expect(withPack.artPackId, equals(entry.id));
    expect(withPack.artUpdatedAt, isNotNull);
    expect(withPack.id, equals(original.id));
    expect(withPack.spellHashHex, equals(original.spellHashHex));

    final restored = SpellAsset.fromJson(withPack.toJson());
    expect(restored.artHash, equals(entry.sha256));
    expect(restored.artSource, equals(SpellArtSource.builtIn));
    expect(restored.artPackId, equals(entry.id));
    expect(restored.artUpdatedAt, equals(withPack.artUpdatedAt));
  });

  test('withPackArt() throws for an id not in kPainterlyPack', () {
    expect(() => sample().withPackArt(packId: 'not-a-real-id'), throwsArgumentError);
  });

  test('withArt() clears a previous artPackId (import supersedes pack selection)', () {
    final withPack = sample().withPackArt(packId: kPainterlyPack.first.id);
    final withImport = withPack.withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);

    expect(withImport.artPackId, isNull);
    expect(withImport.artHash, equals('0xdeadbeef'));
    expect(withImport.artSource, equals(SpellArtSource.localImport));
  });

  test('withoutArt() clears artPackId along with the rest of the art metadata', () {
    final withPack = sample().withPackArt(packId: kPainterlyPack.first.id);
    final cleared = withPack.withoutArt();

    expect(cleared.artHash, isNull);
    expect(cleared.artSource, isNull);
    expect(cleared.artPackId, isNull);
  });

  test('a spell JSON predating artPackId (no such key) still loads, with artPackId null', () {
    final original = sample().withArt(hash: '0xdeadbeef', source: SpellArtSource.localImport);
    final legacyJson = original.toJson()..remove('artPackId');

    final restored = SpellAsset.fromJson(legacyJson);
    expect(restored.artPackId, isNull);
    expect(restored.artHash, equals('0xdeadbeef'));
  });

  test('gridWithheld defaults to false and round-trips', () {
    final original = sample();
    expect(original.gridWithheld, isFalse);

    final restored = SpellAsset.fromJson(original.toJson());
    expect(restored.gridWithheld, isFalse);
    // Default-false is omitted from the wire entirely, not serialized as
    // an explicit `false` -- confirms old JSON (pre-dating this field)
    // still parses to the same default.
    expect(original.toJson().containsKey('gridWithheld'), isFalse);
  });

  test('withGridWithheld() redacts the grid, sets the flag, and preserves everything else', () {
    final original = sample();
    final redacted = original.withGridWithheld();

    expect(redacted.gridWithheld, isTrue);
    expect(redacted.initialGrid, isEmpty);
    expect(redacted.proofBytes, equals(original.proofBytes));
    expect(redacted.commitmentHex, equals(original.commitmentHex));
    expect(redacted.ownerPubkeyHex, equals(original.ownerPubkeyHex));
    expect(redacted.name, equals(original.name));

    final restored = SpellAsset.fromJson(redacted.toJson());
    expect(restored.gridWithheld, isTrue);
    expect(restored.initialGrid, isEmpty);
  });

  test('withGridWithheld() preserves art metadata (regression: this previously dropped '
      'artHash/artSource/artUpdatedAt silently -- a loaned spell with custom art lost its '
      'art on the wire)', () {
    final withPack = sample().withPackArt(packId: kPainterlyPack.first.id);
    final redacted = withPack.withGridWithheld();

    expect(redacted.artHash, equals(withPack.artHash));
    expect(redacted.artSource, equals(SpellArtSource.builtIn));
    expect(redacted.artPackId, equals(withPack.artPackId));
    expect(redacted.artUpdatedAt, equals(withPack.artUpdatedAt));
  });

  test('save() writes a JSON file under <docs>/spells/<id>.json', () async {
    final asset = sample();
    final file = await asset.save();

    expect(file.path, equals('${tempDir.path}/docs/spells/${asset.id}.json'));
    expect(await file.exists(), isTrue);
  });

  test('loadAll() returns saved spells, newest first', () async {
    final olderAsset = SpellAsset(
      id: 'older',
      createdAt: DateTime.utc(2026, 6, 1),
      tier: 12,
      t: 1,
      ownerPubkeyHex: '0xaa',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List.fromList([9]),
      name: 'Older Spell',
      commitmentHex: '0x11',
      spellHashHex: '0x22',
    );
    final newerAsset = SpellAsset(
      id: 'newer',
      createdAt: DateTime.utc(2026, 6, 19),
      tier: 24,
      t: 10,
      ownerPubkeyHex: '0xbb',
      manaCost: 2,
      segmentCount: 1,
      dotCount: 0,
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List.fromList([8]),
      name: 'Newer Spell',
      commitmentHex: '0x33',
      spellHashHex: '0x44',
    );
    await olderAsset.save();
    await newerAsset.save();

    final all = await SpellAsset.loadAll();
    expect(all.map((a) => a.id).toList(), equals(['newer', 'older']));
  });

  test('loadAll() on an empty spells directory returns an empty list', () async {
    final all = await SpellAsset.loadAll();
    expect(all, isEmpty);
  });

  test('summonPersonality defaults to aggressive', () {
    expect(sample().summonPersonality, equals('aggressive'));
  });

  test('withSummonPersonality() overrides only summonPersonality, leaving everything else '
      '(including art metadata) unchanged -- used to bind the per-chapter-entry glyph '
      '(design doc "Personalities") rather than at inscription', () {
    final original =
        sample().withPackArt(packId: kPainterlyPack.first.id).withGridWithheld();
    final rebound = original.withSummonPersonality('evasive');

    expect(rebound.summonPersonality, equals('evasive'));
    expect(rebound.id, equals(original.id));
    expect(rebound.name, equals(original.name));
    expect(rebound.artHash, equals(original.artHash));
    expect(rebound.artPackId, equals(original.artPackId));
    expect(rebound.gridWithheld, isTrue);

    final restored = SpellAsset.fromJson(rebound.toJson());
    expect(restored.summonPersonality, equals('evasive'));
  });
}
