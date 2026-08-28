// SPDX-License-Identifier: GPL-3.0-or-later
//
// The displayed armor summary, at the widget level. Every value on screen must
// come from the spell's proof bytes; the fixtures deliberately carry authored
// metadata that contradicts the proof.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/ui/widgets/armor_summary_view.dart';

import '../spells/armor_fixture.dart';

void main() {
  Future<void> pumpSummary(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('shows T, slot cost, element counts, earned bonuses and keywords',
      (tester) async {
    // 4 fire (+1 melee, Cleave), 4 air (+1 move, Flying), 2 water, 2 earth
    // (+2 armor HP). T=12 -> 3 slots.
    await pumpSummary(
      tester,
      ArmorSummaryView(
        spell: armorAsset(elements: [
          ...runOf(BorderZone.fire, 4),
          ...runOf(BorderZone.air, 4),
          ...runOf(BorderZone.water, 2),
          ...runOf(BorderZone.earth, 2),
        ]),
      ),
    );

    expect(find.text('T 12  ·  3 artifact slots'), findsOneWidget);
    expect(find.text('Fire 4'), findsOneWidget);
    expect(find.text('Air 4'), findsOneWidget);
    expect(find.text('Water 2'), findsOneWidget);
    expect(find.text('Earth 2'), findsOneWidget);
    expect(find.text('+1 melee'), findsOneWidget);
    expect(find.text('+1 move'), findsOneWidget);
    expect(find.text('+2 armor HP'), findsOneWidget);
    // Water 2 has earned nothing yet, so no range row is drawn.
    expect(find.textContaining('range'), findsNothing);
    expect(find.text('Cleave  ·  Flying'), findsOneWidget);
  });

  testWidgets('a single slot is singular', (tester) async {
    await pumpSummary(
      tester,
      ArmorSummaryView(spell: armorAsset(elements: runOf(BorderZone.earth, 3))),
    );
    expect(find.text('T 3  ·  1 artifact slot'), findsOneWidget);
  });

  testWidgets('a stale authored formula/manaCost/supremeTags cannot change it',
      (tester) async {
    final elements = runOf(BorderZone.air, 10);
    await pumpSummary(
      tester,
      ArmorSummaryView(
        spell: armorAsset(
          elements: elements,
          // Claims twelve earths, an earth supreme tag and a huge price.
          formula: List.filled(12, 'earth'),
          supremeTags: const ['earth'],
          manaCost: 9999,
        ),
      ),
    );

    expect(find.text('Air 10'), findsOneWidget);
    expect(find.text('+2 move'), findsOneWidget);
    expect(find.text('Earth 0'), findsOneWidget);
    expect(find.textContaining('armor HP'), findsNothing);
    expect(find.text('Flying'), findsOneWidget);
    expect(find.textContaining('9999'), findsNothing);
  });

  testWidgets('WWWW grants no keyword line', (tester) async {
    await pumpSummary(
      tester,
      ArmorSummaryView(spell: armorAsset(elements: runOf(BorderZone.water, 4))),
    );
    expect(find.text('Water 4'), findsOneWidget);
    expect(find.text('+1 range'), findsOneWidget);
    expect(find.text('Morphic'), findsNothing);
  });

  testWidgets('missing proof bytes fail gracefully, with no invented stats',
      (tester) async {
    await pumpSummary(
      tester,
      ArmorSummaryView(
        spell: armorAsset(
          elements: const [],
          proofBytes: Uint8List(0),
          formula: List.filled(12, 'earth'),
          supremeTags: const ['earth'],
        ),
      ),
    );

    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.textContaining('Earth'), findsNothing);
    expect(find.textContaining('artifact slot'), findsNothing);
  });

  testWidgets('a corrupt proof fails the same way', (tester) async {
    await pumpSummary(
      tester,
      ArmorSummaryView(
        spell: armorAsset(
          elements: const [],
          proofBytes: Uint8List.fromList([9, 9, 9, 9, 9]),
        ),
      ),
    );
    expect(find.textContaining('could not be read'), findsOneWidget);
  });

  testWidgets('dense drops the element grid but keeps the headline',
      (tester) async {
    await pumpSummary(
      tester,
      ArmorSummaryView(
        spell: armorAsset(elements: runOf(BorderZone.fire, 4)),
        dense: true,
      ),
    );
    expect(find.text('T 4  ·  1 artifact slot'), findsOneWidget);
    expect(find.text('Fire 4'), findsNothing);
    expect(find.text('Cleave'), findsOneWidget);
  });
}
