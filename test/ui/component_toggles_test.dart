// SPDX-License-Identifier: GPL-3.0-or-later
//
// component_toggles_test.dart — the lobby's Vocal / Somatic / Simultaneous
// switches (docs/SPELL_COMPONENTS_PLAN.md §1, §5.1).
//
// The switch worth guarding is Simultaneous: it is off by default for a
// reason (two people chanting a metre apart put each other's words into each
// other's microphones), and the warning is what makes that an informed
// choice rather than a surprise mid-duel. A switch that flipped without the
// dialog, or a dialog whose Cancel still flipped it, would quietly undo the
// default.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:rune_duel/ui/widgets/component_toggles.dart';

void main() {
  /// Pumps the toggles with live state, so a switch's effect is observable
  /// rather than merely reported through a callback.
  Future<
      ({
        bool Function() vocal,
        bool Function() somatic,
        bool Function() simultaneous,
      })> pump(
    WidgetTester tester, {
    bool showSimultaneous = true,
  }) async {
    var vocal = false;
    var somatic = false;
    var simultaneous = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ComponentToggles(
              vocalComponents: vocal,
              somaticComponents: somatic,
              simultaneousCasting: simultaneous,
              showSimultaneous: showSimultaneous,
              onVocalChanged: (v) => setState(() => vocal = v),
              onSomaticChanged: (v) => setState(() => somatic = v),
              onSimultaneousChanged: (v) => setState(() => simultaneous = v),
            ),
          ),
        ),
      ),
    );
    return (
      vocal: () => vocal,
      somatic: () => somatic,
      simultaneous: () => simultaneous,
    );
  }

  Finder switchFor(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(Row),
      );

  Future<void> tapSwitch(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: switchFor(label), matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the two components toggle independently', (tester) async {
    final s = await pump(tester);

    await tapSwitch(tester, 'VOCAL COMPONENTS');
    expect(s.vocal(), isTrue);
    expect(s.somatic(), isFalse, reason: 'one component must not imply the other');

    await tapSwitch(tester, 'SOMATIC COMPONENTS');
    expect(s.vocal(), isTrue);
    expect(s.somatic(), isTrue);
  });

  testWidgets('simultaneous casting is inert until a component is on',
      (tester) async {
    final s = await pump(tester);

    final sw = tester.widget<Switch>(
      find.descendant(
        of: switchFor('SIMULTANEOUS CASTING'),
        matching: find.byType(Switch),
      ),
    );
    expect(sw.onChanged, isNull, reason: 'nothing to order without components');
    expect(s.simultaneous(), isFalse);
  });

  testWidgets('switching simultaneous on warns first, and Cancel means off',
      (tester) async {
    final s = await pump(tester);
    await tapSwitch(tester, 'VOCAL COMPONENTS');

    await tapSwitch(tester, 'SIMULTANEOUS CASTING');
    expect(find.text(kSimultaneousCastingWarning), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(
      s.simultaneous(),
      isFalse,
      reason: 'declining the warning must leave the default in place',
    );
  });

  testWidgets('Proceed accepts the warning and switches it on', (tester) async {
    final s = await pump(tester);
    await tapSwitch(tester, 'VOCAL COMPONENTS');

    await tapSwitch(tester, 'SIMULTANEOUS CASTING');
    await tester.tap(find.text('PROCEED'));
    await tester.pumpAndSettle();
    expect(s.simultaneous(), isTrue);
  });

  testWidgets('switching it back off is not gated on a dialog', (tester) async {
    // Returning to the recommended default should never need confirming.
    final s = await pump(tester);
    await tapSwitch(tester, 'VOCAL COMPONENTS');
    await tapSwitch(tester, 'SIMULTANEOUS CASTING');
    await tester.tap(find.text('PROCEED'));
    await tester.pumpAndSettle();

    await tapSwitch(tester, 'SIMULTANEOUS CASTING');
    expect(find.text(kSimultaneousCastingWarning), findsNothing);
    expect(s.simultaneous(), isFalse);
  });

  testWidgets('solo practice is offered no simultaneous switch', (tester) async {
    await pump(tester, showSimultaneous: false);
    expect(find.text('SIMULTANEOUS CASTING'), findsNothing);
    expect(find.text('VOCAL COMPONENTS'), findsOneWidget);
    expect(find.text('SOMATIC COMPONENTS'), findsOneWidget);
  });
}
