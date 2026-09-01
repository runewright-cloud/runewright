import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/main.dart';

void main() {
  testWidgets('Game screen renders hex grid', (WidgetTester tester) async {
    // RuneDuelApp's home is now AppRoot (identity-gated onboarding/menu
    // routing, see docs/step1_identity_onboarding_brief.md), not GameScreen
    // directly -- pump GameScreen itself, matching
    // test/ui/game_screen_inscribe_test.dart's pattern, rather than trying
    // to navigate the full app shell just to assert on the game screen.
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();
    expect(find.text('Runewright'), findsOneWidget);
    expect(find.text('Step'), findsOneWidget);
    // The elemental tracker's four counters, which read "<Element>: N".
    // (This used to assert a bare "Fire" -- the ink bar's preset chip --
    // but that bar is gone; infusion is earned, never chosen.)
    expect(find.text('Fire: 0'), findsOneWidget);
  });
}
