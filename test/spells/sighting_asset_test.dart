// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/sighting_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart' show SpellArtSource, SpellSoundSource;

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

  final opponentPubkeyHex = '0x${'ab' * 32}';
  final commitmentHex = '0x${'cd' * 32}';

  test('record() creates a fresh sighting with timesSeen == 1', () async {
    final sighting = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      formula: const ['fire', 'fire', 'fire'],
      t: 5,
      tier: 24,
      manaCost: 42,
    );

    expect(sighting.opponentPubkeyHex, equals(opponentPubkeyHex));
    expect(sighting.commitmentHex, equals(commitmentHex));
    expect(sighting.spellName, equals('Ember Wake'));
    expect(sighting.formula, equals(['fire', 'fire', 'fire']));
    expect(sighting.t, equals(5));
    expect(sighting.tier, equals(24));
    expect(sighting.manaCost, equals(42));
    expect(sighting.timesSeen, equals(1));
    expect(sighting.firstSeen, equals(sighting.lastSeen));
    expect(sighting.opponentName, isNull);

    final all = await SightingAsset.loadAll();
    expect(all, hasLength(1));
  });

  test('record() upserts: increments timesSeen, advances lastSeen, preserves firstSeen',
      () async {
    final first = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      formula: const ['fire', 'fire', 'fire'],
      t: 5,
      tier: 24,
      manaCost: 42,
    );

    // Ensure a real clock delta so lastSeen can be observed to move forward.
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final second = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      formula: const ['fire', 'fire', 'fire'],
      t: 5,
      tier: 24,
      manaCost: 42,
    );

    expect(second.timesSeen, equals(2));
    expect(second.firstSeen, equals(first.firstSeen));
    expect(second.lastSeen.isAfter(first.lastSeen), isTrue);

    final all = await SightingAsset.loadAll();
    expect(all, hasLength(1), reason: 'repeat cast upserts, never duplicates');
    expect(all.single.timesSeen, equals(2));
  });

  test('record() refreshes formula/spellName/manaCost when a later call carries fuller data',
      () async {
    await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: '',
      formula: const [],
      t: 1,
      tier: 12,
      manaCost: 0,
    );

    final second = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      formula: const ['fire', 'fire', 'fire'],
      t: 1,
      tier: 12,
      manaCost: 42,
    );

    expect(second.spellName, equals('Ember Wake'));
    expect(second.formula, equals(['fire', 'fire', 'fire']));
    expect(second.manaCost, equals(42));
  });

  test('record() never clears a previously-known opponentName with a null', () async {
    await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      opponentName: 'Mordecai',
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );

    final second = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );

    expect(second.opponentName, equals('Mordecai'));
  });

  test('toJson/fromJson round-trips exactly', () async {
    final original = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      opponentName: 'Mordecai',
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      formula: const ['fire', 'fire', 'fire'],
      t: 5,
      tier: 24,
      manaCost: 42,
    );
    final restored = SightingAsset.fromJson(original.toJson());

    expect(restored.opponentPubkeyHex, equals(original.opponentPubkeyHex));
    expect(restored.opponentName, equals(original.opponentName));
    expect(restored.commitmentHex, equals(original.commitmentHex));
    expect(restored.spellName, equals(original.spellName));
    expect(restored.formula, equals(original.formula));
    expect(restored.t, equals(original.t));
    expect(restored.tier, equals(original.tier));
    expect(restored.manaCost, equals(original.manaCost));
    expect(restored.firstSeen, equals(original.firstSeen));
    expect(restored.lastSeen, equals(original.lastSeen));
    expect(restored.timesSeen, equals(original.timesSeen));
  });

  test('loadAll() groups distinct spells under distinct opponents', () async {
    final otherOpponent = '0x${'ef' * 32}';
    final otherCommitment = '0x${'12' * 32}';

    await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );
    await SightingAsset.record(
      opponentPubkeyHex: otherOpponent,
      commitmentHex: otherCommitment,
      spellName: 'Frost Bolt',
      t: 1,
      tier: 12,
      manaCost: 10,
    );

    final all = await SightingAsset.loadAll();
    expect(all, hasLength(2));
    final byOpponent = <String, List<SightingAsset>>{};
    for (final s in all) {
      byOpponent.putIfAbsent(s.opponentPubkeyHex, () => []).add(s);
    }
    expect(byOpponent.keys, containsAll([opponentPubkeyHex, otherOpponent]));
    expect(byOpponent[opponentPubkeyHex], hasLength(1));
    expect(byOpponent[otherOpponent], hasLength(1));
  });

  test('delete() removes the persisted file', () async {
    final sighting = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );
    expect(await SightingAsset.loadAll(), hasLength(1));

    await sighting.delete();
    expect(await SightingAsset.loadAll(), isEmpty);
  });

  test('deleteAllForOpponent() removes only that opponent\'s sightings', () async {
    final otherOpponent = '0x${'ef' * 32}';
    final otherCommitment = '0x${'12' * 32}';

    await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );
    await SightingAsset.record(
      opponentPubkeyHex: otherOpponent,
      commitmentHex: otherCommitment,
      spellName: 'Frost Bolt',
      t: 1,
      tier: 12,
      manaCost: 10,
    );

    await SightingAsset.deleteAllForOpponent(opponentPubkeyHex);

    final remaining = await SightingAsset.loadAll();
    expect(remaining, hasLength(1));
    expect(remaining.single.opponentPubkeyHex, equals(otherOpponent));
  });

  test('loadAll() on an empty sightings directory returns an empty list', () async {
    expect(await SightingAsset.loadAll(), isEmpty);
  });

  test('withArt() sets artHash/artSource/artUpdatedAt', () async {
    final sighting = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );
    expect(sighting.artHash, isNull);

    final withArt = sighting.withArt(hash: '0xdeadbeef');
    expect(withArt.artHash, equals('0xdeadbeef'));
    expect(withArt.artSource, equals(SpellArtSource.synced));
    expect(withArt.artUpdatedAt, isNotNull);
  });

  test('withoutArt() clears art metadata', () async {
    final sighting = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withArt(hash: '0xdeadbeef');

    final cleared = sighting.withoutArt();
    expect(cleared.artHash, isNull);
    expect(cleared.artSource, isNull);
    expect(cleared.artUpdatedAt, isNull);
  });

  test('toJson/fromJson round-trips art fields', () async {
    final withArt = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withArt(hash: '0xdeadbeef');

    final restored = SightingAsset.fromJson(withArt.toJson());
    expect(restored.artHash, equals('0xdeadbeef'));
    expect(restored.artSource, equals(SpellArtSource.synced));
    expect(restored.artUpdatedAt, equals(withArt.artUpdatedAt));
  });

  test('record() upsert never clears art written by a prior Sync Art session', () async {
    final first = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 24,
      manaCost: 42,
    );
    await first.withArt(hash: '0xdeadbeef').save();

    // A later battle-cast upsert (no knowledge of art) must not erase it.
    final second = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 24,
      manaCost: 42,
    );

    expect(second.artHash, equals('0xdeadbeef'));
    expect(second.artSource, equals(SpellArtSource.synced));

    final all = await SightingAsset.loadAll();
    expect(all.single.artHash, equals('0xdeadbeef'));
  });

  test('toDisplaySpell() surfaces spellHashHex == id and passes through art fields', () async {
    final sighting = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withArt(hash: '0xdeadbeef');

    final display = sighting.toDisplaySpell();
    expect(display.spellHashHex, equals(sighting.id));
    expect(display.artHash, equals('0xdeadbeef'));
    expect(display.artSource, equals(SpellArtSource.synced));
    expect(display.commitmentHex, equals(commitmentHex));
    expect(display.ownerPubkeyHex, equals(opponentPubkeyHex));
  });

  test('withSound() sets soundHash/soundSource/soundUpdatedAt (synced, no pack id)', () async {
    final sighting = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );
    expect(sighting.soundHash, isNull);

    final withSound =
        sighting.withSound(hash: '0xf00d', source: SpellSoundSource.synced);
    expect(withSound.soundHash, equals('0xf00d'));
    expect(withSound.soundSource, equals(SpellSoundSource.synced));
    expect(withSound.soundUpdatedAt, isNotNull);
    expect(withSound.soundPackId, isNull);
  });

  test('withSound() with a packId records a built-in-sourced opponent sound (D-5)', () async {
    final sighting = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    );

    final withPack = sighting.withSound(
      hash: '0xabc123',
      source: SpellSoundSource.builtIn,
      packId: 'zap',
    );
    expect(withPack.soundSource, equals(SpellSoundSource.builtIn));
    expect(withPack.soundPackId, equals('zap'));
  });

  test('withoutSound() clears sound metadata but leaves art alone', () async {
    final sighting = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withArt(hash: '0xdeadbeef')
        .withSound(hash: '0xf00d', source: SpellSoundSource.synced);

    final cleared = sighting.withoutSound();
    expect(cleared.soundHash, isNull);
    expect(cleared.soundSource, isNull);
    expect(cleared.artHash, equals('0xdeadbeef'));
  });

  test('toJson/fromJson round-trips sound fields', () async {
    final withSound = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withSound(hash: '0xf00d', source: SpellSoundSource.builtIn, packId: 'zap');

    final restored = SightingAsset.fromJson(withSound.toJson());
    expect(restored.soundHash, equals('0xf00d'));
    expect(restored.soundSource, equals(SpellSoundSource.builtIn));
    expect(restored.soundPackId, equals('zap'));
    expect(restored.soundUpdatedAt, equals(withSound.soundUpdatedAt));
  });

  test('record() upsert never clears sound written by a prior Sync Sound session', () async {
    final first = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 24,
      manaCost: 42,
    );
    await first.withSound(hash: '0xf00d', source: SpellSoundSource.synced).save();

    final second = await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 24,
      manaCost: 42,
    );

    expect(second.soundHash, equals('0xf00d'));
    expect(second.soundSource, equals(SpellSoundSource.synced));
  });

  test('toDisplaySpell() passes through sound fields', () async {
    final sighting = (await SightingAsset.record(
      opponentPubkeyHex: opponentPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 1,
      tier: 12,
      manaCost: 10,
    ))
        .withSound(hash: '0xf00d', source: SpellSoundSource.synced);

    final display = sighting.toDisplaySpell();
    expect(display.soundHash, equals('0xf00d'));
    expect(display.soundSource, equals(SpellSoundSource.synced));
  });
}
