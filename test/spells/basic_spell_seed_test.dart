// SPDX-License-Identifier: GPL-3.0-or-later
//
// basic_spell_seed_test.dart — seedBasicSpells: idempotency, the
// deletable-stays-deleted rule, and the force-restore path.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/basic_spell_seed.dart';
import 'package:rune_duel/spells/basic_spells.dart';
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

  test('seeds all five basics into an empty library', () async {
    final written = await seedBasicSpells();
    expect(written, 5);

    final all = await SpellAsset.loadAll();
    expect(all.length, 5);
    expect(
      all.map((s) => s.spellHashHex).toSet(),
      kBasicSpells.map((e) => e.spellHashHex).toSet(),
    );
  });

  test('a second call writes nothing (marker gate)', () async {
    expect(await seedBasicSpells(), 5);
    expect(await seedBasicSpells(), 0);

    final all = await SpellAsset.loadAll();
    expect(all.length, 5);
  });

  test('a renamed basic spell is not overwritten by a later seed call', () async {
    await seedBasicSpells();
    final all = await SpellAsset.loadAll();
    final firebolt = all.firstWhere((s) => s.name == 'Basic Firebolt');
    await firebolt.delete();
    final renamed = SpellAsset(
      id: firebolt.id,
      createdAt: firebolt.createdAt,
      tier: firebolt.tier,
      t: firebolt.t,
      ownerPubkeyHex: firebolt.ownerPubkeyHex,
      manaCost: firebolt.manaCost,
      segmentCount: firebolt.segmentCount,
      dotCount: firebolt.dotCount,
      initialGrid: firebolt.initialGrid,
      proofBytes: firebolt.proofBytes,
      name: 'My Custom Firebolt',
      commitmentHex: firebolt.commitmentHex,
      spellHashHex: firebolt.spellHashHex,
      formula: firebolt.formula,
      supremeTags: firebolt.supremeTags,
    );
    await renamed.save();

    // Bump past the marker so a reseed pass actually runs its per-spell scan.
    await seedBasicSpells(force: true);

    final after = await SpellAsset.loadAll();
    final matches = after.where((s) => s.spellHashHex == firebolt.spellHashHex);
    expect(matches.length, 1, reason: 'renaming must not create a duplicate');
    expect(matches.single.name, 'My Custom Firebolt');
  });

  test('deleting a basic spell is respected on a normal (non-forced) reseed', () async {
    await seedBasicSpells();
    final all = await SpellAsset.loadAll();
    final firebolt = all.firstWhere((s) => s.name == 'Basic Firebolt');
    await firebolt.delete();

    final written = await seedBasicSpells();
    expect(written, 0, reason: 'marker already at current version — no-op');

    final after = await SpellAsset.loadAll();
    expect(after.length, 4);
    expect(after.any((s) => s.name == 'Basic Firebolt'), isFalse);
  });

  test('force:true restores a deleted basic spell', () async {
    await seedBasicSpells();
    final all = await SpellAsset.loadAll();
    final firebolt = all.firstWhere((s) => s.name == 'Basic Firebolt');
    await firebolt.delete();

    final written = await seedBasicSpells(force: true);
    expect(written, 1);

    final after = await SpellAsset.loadAll();
    expect(after.length, 5);
    expect(after.any((s) => s.name == 'Basic Firebolt'), isTrue);
  });

  test('force:true does not duplicate spells already present', () async {
    await seedBasicSpells();
    final written = await seedBasicSpells(force: true);
    expect(written, 0);

    final all = await SpellAsset.loadAll();
    expect(all.length, 5);
  });
}
