// SPDX-License-Identifier: GPL-3.0-or-later
//
// dev_surfaces_hidden_test.dart — DEV FLAG (kShowDevSurfaces, lib/dev_flags.dart).
// Delete this file when the flag goes.
//
// The flag hides three developer-only entry points from a build that goes to
// players. Two things need guarding, and neither is caught by the analyzer:
//
//   1. The Library's TESTS tab is gated in three places that must stay in
//      step — DefaultTabController's `length`, the TabBar's `tabs`, and the
//      TabBarView's `children`. Miss one and TabController throws at build
//      time, so only actually pumping the screen proves it.
//   2. Spell Test Lab spells live in the same store as real ones, so
//      Craftings shows them unless filtered. A leftover `[TEST]` spell that
//      stays castable carries no proof, and with kAllowProoflessSpells off
//      the opponent forfeits on receipt.
//
// The assertions are written both ways round so this still passes with the
// flag flipped back on for development.
//
// LibraryScreen does real dart:io file I/O on load (spells, chapters,
// identity). See spell_test_lab_drive_test.dart's header for why that needs
// runAsync + a real delay rather than pumpAndSettle, which hangs here.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/dev_flags.dart' show kShowDevSurfaces;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/library_screen.dart';
import 'package:rune_duel/ui/spell_test_lab_screen.dart' show kTestSpellNamePrefix;

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

Future<void> _settleReal(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await tester.pump();
  await tester.pump();
}

/// Mirrors SpellTestLabScreen._persistTestSpell: an all-zero grid, no proof
/// bytes, and a placeholder commitment (never a real Poseidon2 one — CLAUDE.md
/// invariant 1). That empty `proofBytes` is exactly what makes a leftover test
/// spell a forfeit once verification is on.
Future<void> _fabricateTestSpell(String name) async {
  final spell = SpellAsset(
    id: 'testlab_seed_fixture',
    createdAt: DateTime.now(),
    tier: 12,
    t: 2,
    ownerPubkeyHex: '0x${'0' * 64}',
    manaCost: 0,
    segmentCount: 0,
    dotCount: 0,
    initialGrid: List<int>.filled(469, 0),
    proofBytes: Uint8List(0),
    name: name,
    commitmentHex: '0x${'a' * 64}',
    spellHashHex: '0x${'b' * 64}',
    formula: const ['fire', 'inner', 'outer'],
  );
  await spell.save();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // Craftings renders the wizard's sigil from Identity.ownerPubkeyHex, which
  // hashes through the Rust bridge (poseidon2Hash2) — an in-process hash, no
  // SRS, but the bridge still needs initializing once.
  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tempDir = await installFakePathProvider();
    installFakeSecureStorage();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('the Library builds, and the TESTS tab follows the flag',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);

      // A length/children mismatch throws during build, so reaching here at
      // all is most of the point.
      expect(tester.takeException(), isNull);

      expect(find.text('CRAFTINGS'), findsOneWidget);
      expect(find.text('CHAPTERS'), findsOneWidget);
      expect(
        find.text('TESTS'),
        kShowDevSurfaces ? findsOneWidget : findsNothing,
      );
    });
  });

  testWidgets('Craftings hides Spell Test Lab spells while the flag is off',
      (tester) async {
    await tester.runAsync(() async {
      await _fabricateTestSpell('${kTestSpellNamePrefix}Fire Bolt');

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);

      expect(
        find.textContaining('Fire Bolt'),
        kShowDevSurfaces ? findsWidgets : findsNothing,
        reason: 'a `[TEST]` spell must not be castable in a build that ships '
            'with proof verification on',
      );

      // Hidden, not deleted — it has to come back when the flag does.
      final onDisk = await SpellAsset.loadAll();
      expect(
        onDisk.where((s) => s.name.startsWith(kTestSpellNamePrefix)),
        hasLength(1),
      );
    });
  });
}
