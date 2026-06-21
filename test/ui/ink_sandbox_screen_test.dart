// SPDX-License-Identifier: GPL-3.0-or-later
//
// ink_sandbox_screen_test.dart — drives the real InkSandboxScreen widget
// tree via WidgetTester taps: presets, step, play/pause, scrubber, rule
// toggles, seed tap-to-edit. No fakes needed -- the sandbox has no FFI,
// identity, or storage dependency.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/ink_sandbox_screen.dart';

void main() {
  testWidgets('preset + step grows the grid and advances the generation readout', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InkSandboxScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Generation: 0'), findsOneWidget);
    expect(find.text('Active cells: 0'), findsOneWidget);
    expect(find.text('Border contact: —'), findsOneWidget);

    await tester.tap(find.text('Straight'));
    await tester.pumpAndSettle();
    expect(find.text('Generation: 0'), findsOneWidget);
    expect(find.text('Active cells: 4'), findsOneWidget);

    await tester.tap(find.text('Step'));
    await tester.pumpAndSettle();
    expect(find.text('Generation: 1'), findsOneWidget);
    // Rule B (default on) extends both free ends of the 4-cell stroke.
    expect(find.text('Active cells: 6'), findsOneWidget);
  });

  testWidgets('reset clears the grid back to generation 0', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InkSandboxScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('X-cross'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step'));
    await tester.pumpAndSettle();
    expect(find.text('Generation: 1'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Generation: 0'), findsOneWidget);
    expect(find.text('Active cells: 0'), findsOneWidget);
  });

  testWidgets('play advances generations over time, pause stops it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InkSandboxScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('X-cross'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Generation: 2'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Generation: 2'), findsOneWidget);
  });

  testWidgets('scrubber jumps to a previously-computed generation without recomputation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InkSandboxScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('X-cross'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step'));
    await tester.pumpAndSettle();
    expect(find.text('Generation: 2'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, equals(2));

    await tester.tap(find.byType(Slider));
    await tester.pumpAndSettle();
    // Tapping the slider's left edge (a smoke check that the scrubber
    // is interactive and doesn't crash mid-history) moves off gen 2.
    expect(find.text('Generation: 2'), findsNothing);
  });

  testWidgets('rule toggles are present and togglable', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InkSandboxScreen()));
    await tester.pumpAndSettle();

    expect(find.text('A: Gap-fill'), findsOneWidget);
    expect(find.text('B: Tip ext.'), findsOneWidget);
    expect(find.text('C: Burst'), findsOneWidget);
    expect(find.text('E: Bloom'), findsOneWidget);
    expect(find.text('N=4'), findsNothing); // E off by default, cadence hidden

    await tester.tap(find.text('E: Bloom'));
    await tester.pumpAndSettle();
    expect(find.text('N=4'), findsOneWidget);
  });
}
