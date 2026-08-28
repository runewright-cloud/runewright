// SPDX-License-Identifier: GPL-3.0-or-later
//
// inscribe_test.dart — exercises the full inscribeSpell pipeline (prove,
// self-verify, persist) against the real stack: real on-device proving
// (tier-12), a real ephemeral Ed25519 identity, real file persistence and
// real SRS disk caching (only the documents/support directories are
// faked, via fake_path_provider.dart). Mirrors test/ui/gate_runner_test.dart's
// "exercise the real stack" approach.
//
// The genuinely-offline failure path (fresh device, no cache, no network)
// can't be exercised from here -- this process has real network, and the
// SRS download URL is hardcoded in noir_rs, not mockable. That path is
// covered at the Rust level instead: ffi/src/api/prover.rs's
// `missing_cache_with_no_network_returns_err_not_hang` test, run for real
// under `unshare --user --net` (see that test's doc comment).

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/ffi/srs_cache.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/inscribe.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import 'fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('tierForSteps picks the smallest covering tier', () {
    expect(tierForSteps(1), equals(12));
    expect(tierForSteps(12), equals(12));
    expect(tierForSteps(13), equals(24));
    expect(tierForSteps(24), equals(24));
    expect(tierForSteps(25), equals(48));
    expect(tierForSteps(48), equals(48));
    expect(tierForSteps(49), isNull);
    expect(tierForSteps(0), isNull);
  });

  test('rejects an out-of-range step count without proving', () async {
    final grid = HexGrid(12);
    final identity = await Identity.ephemeral();

    expect(
      () => inscribeSpell(
        initialGrid: grid,
        steps: 0,
        identity: identity,
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        name: 'Irrelevant',
        loadCircuitJson: (_) async => throw StateError('should not load a circuit for an invalid step count'),
        loadVkBytes: (_) async => throw StateError('should not load a VK for an invalid step count'),
      ),
      throwsA(isA<InscribeException>()),
    );
  });

  test('Armor mode persists isArmor without a second proof pipeline', () async {
    final grid = HexGrid(12);
    grid.setState(Element.alive, const HexCoord(0, 0));
    final identity = await Identity.ephemeral();

    final asset = await inscribeSpell(
      initialGrid: grid,
      steps: 1,
      identity: identity,
      manaCost: 7,
      segmentCount: 0,
      dotCount: 1,
      name: 'Stormplate',
      isArmor: true,
      loadCircuitJson: rootBundle.loadString,
      loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
    );

    expect(asset.isArmor, isTrue);
    expect(asset.isSummon, isFalse);
    // The same proof path as any other spell: real bytes, real commitment,
    // self-verified before persisting.
    expect(asset.proofBytes, isNotEmpty);
    expect(asset.commitmentHex, isNotEmpty);
    expect(asset.tier, equals(12));

    final reloaded = (await SpellAsset.loadAll()).firstWhere((s) => s.id == asset.id);
    expect(reloaded.isArmor, isTrue);
    expect(reloaded.isSummon, isFalse);
  });

  test('rejects a spell claiming to be both a Summon and an Armor, without '
      'proving', () async {
    final grid = HexGrid(12);
    final identity = await Identity.ephemeral();

    expect(
      () => inscribeSpell(
        initialGrid: grid,
        steps: 1,
        identity: identity,
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        name: 'Irrelevant',
        isSummon: true,
        isArmor: true,
        loadCircuitJson: (_) async =>
            throw StateError('should not load a circuit for a contradictory mode'),
        loadVkBytes: (_) async =>
            throw StateError('should not load a VK for a contradictory mode'),
      ),
      throwsA(isA<InscribeException>()),
    );
  });

  test('prove -> self-verify -> persist round-trips a real spell', () async {
    final grid = HexGrid(12);
    grid.setState(Element.alive, const HexCoord(0, 0));
    final identity = await Identity.ephemeral();
    final progress = <String>[];

    final asset = await inscribeSpell(
      initialGrid: grid,
      steps: 1,
      identity: identity,
      manaCost: 7,
      segmentCount: 0,
      dotCount: 1,
      name: 'Ember Wake',
      loadCircuitJson: rootBundle.loadString,
      loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
      onProgress: progress.add,
    );

    expect(asset.tier, equals(12));
    expect(asset.t, equals(1));
    expect(asset.manaCost, equals(7));
    expect(asset.name, equals('Ember Wake'));
    expect(asset.commitmentHex, isNotEmpty);
    expect(asset.spellHashHex, isNotEmpty);
    expect(asset.ownerPubkeyHex, equals(await identity.ownerPubkeyHex()));
    expect(asset.initialGrid.length, equals(469));
    expect(asset.initialGrid[234], equals(1)); // center cell, per GRID_ORDERING_v2.md
    expect(asset.proofBytes, isNotEmpty);

    final loaded = await SpellAsset.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, equals(asset.id));
    expect(loaded.first.proofBytes, equals(asset.proofBytes));

    // No SRS cache existed yet for this fresh fake support directory, so
    // the very first progress message must warn honestly that this
    // particular call needs a connection.
    expect(progress.first, contains('first inscription needs a connection'));
    expect(progress, containsAllInOrder(['Inscribing your spell…', 'Verifying…']));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a second inscription reuses the on-disk SRS cache and says so', () async {
    // Two sequential real on-device proofs; default 30s timeout isn't enough.
    final grid = HexGrid(12);
    final identity = await Identity.ephemeral();

    // First call: no cache yet -- downloads and writes the cache file.
    await inscribeSpell(
      initialGrid: grid,
      steps: 1,
      identity: identity,
      manaCost: 1,
      segmentCount: 0,
      dotCount: 0,
      name: 'First Spell',
      loadCircuitJson: rootBundle.loadString,
      loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
    );

    final cachePath = await srsCachePath();
    expect(await File(cachePath).exists(), isTrue, reason: 'first inscription should have written the SRS cache');

    // Second call: cache file already exists, so this must read it instead
    // of downloading again, and the progress message must not carry the
    // "needs a connection" warning this time.
    // Uses steps: 2 (different T → different spellHashHex → not a duplicate).
    final secondProgress = <String>[];
    final secondAsset = await inscribeSpell(
      initialGrid: grid,
      steps: 2,
      identity: identity,
      manaCost: 2,
      segmentCount: 0,
      dotCount: 0,
      name: 'Second Spell',
      loadCircuitJson: rootBundle.loadString,
      loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
      onProgress: secondProgress.add,
    );

    expect(secondAsset.proofBytes, isNotEmpty);
    expect(secondProgress.first, equals('Preparing the loom…'));
    expect(secondProgress.first, isNot(contains('connection')));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
