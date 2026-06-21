// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_inscribe_test.dart — drives the real GameScreen widget tree
// to confirm the Inscribe button's enable/disable gating (stepCount must be
// 1..48) without actually running a proof -- the real prove/verify/persist
// pipeline is already covered end-to-end by test/spells/inscribe_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/main.dart';

void main() {
  testWidgets('Inscribe is disabled at T=0 and enabled after one step', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pumpAndSettle();

    Widget inscribeButton() => tester.widget<ElevatedButton>(
          find.ancestor(of: find.text('Inscribe'), matching: find.byType(ElevatedButton)),
        );

    expect((inscribeButton() as ElevatedButton).onPressed, isNull);

    await tester.tap(find.text('Step'));
    await tester.pumpAndSettle();

    expect((inscribeButton() as ElevatedButton).onPressed, isNotNull);
  });
}
