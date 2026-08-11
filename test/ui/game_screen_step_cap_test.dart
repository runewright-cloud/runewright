// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_step_cap_test.dart — confirms the GameScreen stepper hard-stops
// at T=kMaxInscribableSteps (48): there is no tier beyond 48
// (CLAUDE.md invariant #6, tier_max ∈ {12, 24, 48}), so stepping further can
// never be inscribed and the UI must refuse rather than let the grid wander
// past it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/main.dart';
import 'package:rune_duel/spells/inscribe.dart' show kMaxInscribableSteps;

void main() {
  testWidgets('Step button disables at kMaxInscribableSteps and stepCount never exceeds it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pumpAndSettle();

    ElevatedButton stepButton() => tester.widget<ElevatedButton>(
          find.ancestor(of: find.text('Step'), matching: find.byType(ElevatedButton)),
        );

    for (var i = 0; i < kMaxInscribableSteps; i++) {
      expect(stepButton().onPressed, isNotNull, reason: 'expected Step enabled before tap $i');
      await tester.tap(find.text('Step'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Step $kMaxInscribableSteps (max)'), findsOneWidget);
    expect(stepButton().onPressed, isNull);

    // A further tap must be a no-op: the button is disabled, and even if it
    // weren't, _stepOnce's own guard must refuse to advance past the cap.
    await tester.tap(find.text('Step'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Step $kMaxInscribableSteps (max)'), findsOneWidget);
  });

  testWidgets('Run button disables once stepped to the cap', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pumpAndSettle();

    for (var i = 0; i < kMaxInscribableSteps; i++) {
      await tester.tap(find.text('Step'));
      await tester.pumpAndSettle();
    }

    final runButton = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('Run'), matching: find.byType(ElevatedButton)),
    );
    expect(runButton.onPressed, isNull);
  });
}
