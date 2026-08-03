// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_test_lab_drive_test.dart — drives the real SpellTestLabScreen widget
// tree via WidgetTester taps/text entry: add an effect, name the spell, save
// it, and confirm it both renders in the "YOUR TEST SPELLS" list and
// persists as a zero-cost, unproven SpellAsset on disk.
//
// SpellAsset.save/loadAll do real dart:io file I/O. Under testWidgets' default
// FakeAsync zone, tester.pump()/pumpAndSettle() always advance a *fake* clock
// regardless of ambient zone, so a real I/O completion never gets picked up
// by pumpAndSettle alone — even inside tester.runAsync. The fix: run the
// whole interaction inside runAsync (so real Futures actually resolve), and
// after each action that triggers file I/O, await a real Future.delayed to
// let the event loop actually spin before pump()ing again to pick up the
// resulting setState.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/spell_test_lab_screen.dart';

import '../spells/fake_path_provider.dart';

Future<void> _settleReal(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await tester.pump();
  await tester.pump();
}

/// Like [_settleReal], but keeps polling [condition] (which reads real
/// on-disk state) until it's satisfied instead of guessing a fixed delay.
/// Needed after actions that trigger many sequential real file writes (e.g.
/// seeding 64 test spells) where a single 50ms delay is not reliably enough,
/// especially under CPU contention from other test files running in parallel.
Future<void> _settleUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await _settleReal(tester);
    if (await condition()) return;
  }
}

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

  testWidgets('build a Fire Blast test spell and save it', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SpellTestLabScreen()));
      await _settleReal(tester);

      expect(find.text('No test spells yet.'), findsOneWidget);

      // Default slot is already Firey + Blast — just name and save it.
      await tester.enterText(find.byType(TextField), 'Test Fireball');
      await tester.pump();

      await tester.tap(find.text('SAVE TEST SPELL'));
      await _settleUntil(tester, () async => (await SpellAsset.loadAll()).isNotEmpty);

      expect(find.text('Test Fireball'), findsOneWidget);
      expect(find.text('No test spells yet.'), findsNothing);

      final saved = await SpellAsset.loadAll();
      expect(saved, hasLength(1));
      final spell = saved.single;
      expect(spell.name, '[TEST] Test Fireball');
      expect(spell.manaCost, 0);
      expect(spell.proofBytes, isEmpty);
      expect(spell.formula, ['fire', 'fire', 'fire']);
    });
  });

  testWidgets('delete a saved test spell', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SpellTestLabScreen()));
      await _settleReal(tester);

      await tester.tap(find.text('SAVE TEST SPELL'));
      await _settleUntil(tester, () async => (await SpellAsset.loadAll()).isNotEmpty);
      expect(await SpellAsset.loadAll(), hasLength(1));

      await tester.ensureVisible(find.byIcon(Icons.delete_outline));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await _settleUntil(tester, () async => (await SpellAsset.loadAll()).isEmpty);

      expect(find.text('No test spells yet.'), findsOneWidget);
      expect(await SpellAsset.loadAll(), isEmpty);
    });
  });

  testWidgets('seed all 64 element x effect pairings', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SpellTestLabScreen()));
      await _settleReal(tester);

      final expectedCount = SpellAffinity.values.length * EffectKind.values.length;
      await tester.tap(find.text('Seed all pairings (64)'));
      await _settleUntil(tester, () async => (await SpellAsset.loadAll()).length >= expectedCount);

      final saved = await SpellAsset.loadAll();
      expect(saved, hasLength(expectedCount));
      for (final affinity in SpellAffinity.values) {
        for (final kind in EffectKind.values) {
          final match = saved.where(
            (s) => s.name == '[TEST] ${kAffinityLabel[affinity]} ${kEffectKindLabel[kind]}',
          );
          expect(match, hasLength(1), reason: 'missing seed for $affinity/$kind');
          expect(match.single.formula, hasLength(3));
          expect(match.single.formula.first, affinity.name);
          expect(match.single.manaCost, 0);
          expect(match.single.proofBytes, isEmpty);
        }
      }

      // Re-seeding is idempotent: no duplicates, same ids.
      final idsBefore = saved.map((s) => s.id).toSet();
      await tester.tap(find.text('Seed all pairings (64)'));
      await _settleUntil(tester, () async => (await SpellAsset.loadAll()).length >= expectedCount);
      final resaved = await SpellAsset.loadAll();
      expect(resaved, hasLength(expectedCount));
      expect(resaved.map((s) => s.id).toSet(), idsBefore);
    });
  });
}
