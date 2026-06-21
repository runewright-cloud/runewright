// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_asset.dart';

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
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
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
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List.fromList([9]),
    );
    final newerAsset = SpellAsset(
      id: 'newer',
      createdAt: DateTime.utc(2026, 6, 19),
      tier: 24,
      t: 10,
      ownerPubkeyHex: '0xbb',
      manaCost: 2,
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List.fromList([8]),
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
}
