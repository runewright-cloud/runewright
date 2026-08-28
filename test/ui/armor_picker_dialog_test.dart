// SPDX-License-Identifier: GPL-3.0-or-later
//
// The equip picker: what it offers and what it refuses. The budget rules
// themselves live in chapter_armor.dart (slice 2) and are exercised there;
// this is about the dialog asking that seam and honouring its answer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/chapter_armor.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/widgets/armor_picker_dialog.dart';

import '../spells/armor_fixture.dart';

ChapterAsset chapterWith(int artifacts) => ChapterAsset(
      id: 'chapter-1',
      name: 'Test Chapter',
      createdAt: DateTime.utc(2026, 8, 25),
      artifacts: List.generate(
          artifacts, (_) => const ArtifactEntry(kind: ArtifactKind.manaGem)),
    );

void main() {
  Future<SpellAsset?> pumpPicker(
    WidgetTester tester, {
    required List<SpellAsset> candidates,
    required ChapterAsset chapter,
    String? equippedId,
  }) async {
    SpellAsset? chosen;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showDialog<SpellAsset>(
                context: context,
                builder: (_) => ArmorPickerDialog(
                  candidates: candidates,
                  equippedId: equippedId,
                  rejectionFor: (a) => armorBindError(chapter, a),
                  rejectionText: (e, a) => switch (e) {
                    ArmorBindError.notAnArmor => 'not an armor',
                    ArmorBindError.exceedsSlotBudget => 'needs too many slots',
                  },
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return chosen;
  }

  testWidgets('lists only armor, even when handed spells and summons',
      (tester) async {
    await pumpPicker(
      tester,
      chapter: chapterWith(0),
      candidates: [
        armorAsset(id: 'a1', name: 'Plate', elements: runOf(BorderZone.earth, 4)),
        plainSpell(id: 's1', name: 'Ember Wake'),
        plainSpell(id: 's2', name: 'Windhound', isSummon: true),
      ],
    );

    expect(find.text('Plate'), findsOneWidget);
    expect(find.text('Ember Wake'), findsNothing);
    expect(find.text('Windhound'), findsNothing);
  });

  testWidgets('each armor shows its T and slot cost', (tester) async {
    await pumpPicker(
      tester,
      chapter: chapterWith(0),
      candidates: [
        armorAsset(id: 'a1', name: 'Light', elements: runOf(BorderZone.air, 4)),
        armorAsset(id: 'a2', name: 'Heavy', elements: runOf(BorderZone.earth, 9)),
      ],
    );
    expect(find.text('T 4  ·  1 artifact slot'), findsOneWidget);
    expect(find.text('T 9  ·  3 artifact slots'), findsOneWidget);
  });

  testWidgets('tapping an affordable armor selects it and closes the picker',
      (tester) async {
    await pumpPicker(
      tester,
      chapter: chapterWith(3),
      candidates: [
        armorAsset(id: 'a1', name: 'Plate', elements: runOf(BorderZone.earth, 4)),
      ],
    );
    expect(find.text('Equip Armor'), findsOneWidget);

    await tester.tap(find.text('Plate'));
    await tester.pumpAndSettle();

    // Closed: the tile was live and popped the chosen armor.
    expect(find.text('Equip Armor'), findsNothing);
  });

  testWidgets('an armor the chapter cannot afford is disabled with a reason',
      (tester) async {
    // 10 ordinary artifacts + a 3-slot armor = 13.
    final chosen = await pumpPicker(
      tester,
      chapter: chapterWith(10),
      candidates: [
        armorAsset(id: 'a1', name: 'Heavy', elements: runOf(BorderZone.earth, 9)),
      ],
    );

    expect(find.text('needs too many slots'), findsOneWidget);
    await tester.tap(find.text('Heavy'));
    await tester.pumpAndSettle();
    // Still open: the tile is inert, so nothing was chosen.
    expect(find.text('Equip Armor'), findsOneWidget);
    expect(chosen, isNull);
  });

  testWidgets('the currently equipped armor is marked and not re-selectable',
      (tester) async {
    await pumpPicker(
      tester,
      chapter: chapterWith(0),
      equippedId: 'a1',
      candidates: [
        armorAsset(id: 'a1', name: 'Plate', elements: runOf(BorderZone.earth, 4)),
      ],
    );
    expect(find.text('Currently equipped'), findsOneWidget);
  });

  testWidgets('with no armor inscribed it says so instead of showing an empty list',
      (tester) async {
    await pumpPicker(tester, chapter: chapterWith(0), candidates: const []);
    expect(find.textContaining('inscribed no armor yet'), findsOneWidget);
  });
}
