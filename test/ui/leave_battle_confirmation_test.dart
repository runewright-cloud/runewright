// SPDX-License-Identifier: GPL-3.0-or-later
//
// leave_battle_confirmation_test.dart — leavingNeedsConfirmation, the
// predicate behind the battle screen's "leave this duel?" guard.
//
// Why the guard exists: leaving a live duel now genuinely ends it. The screen
// closes its session and socket on dispose, so the opponent gets "lost
// contact" and there is no rejoin — which makes a stray tap on the app-bar
// close button, or an accidental Android back-swipe, a thrown match.
//
// Tested at the predicate rather than through the widget because nothing in
// the suite builds a full BattleScreen (it needs a BattleState, avatars, a
// session, VK assets and a live FFI bridge), and because the predicate is what
// the two call sites share: the close button and PopScope.canPop must agree,
// and a guard that only covers one of them is half a guard on Android, where
// the back gesture is the easier of the two to trigger by accident.
//
// NOT covered here: that the dialog renders, reads correctly, or that
// "Keep duelling" really cancels. That needs an on-screen pass.

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/battle_screen.dart';

void main() {
  test('a live duel against a real peer is guarded', () {
    expect(
      leavingNeedsConfirmation(isRealDuel: true, matchEnded: false),
      isTrue,
    );
  });

  test('a finished duel is not guarded', () {
    // Nothing left to abandon — the close button is just "go back" now, and
    // making the winner confirm their way off the result screen would be
    // noise.
    expect(
      leavingNeedsConfirmation(isRealDuel: true, matchEnded: true),
      isFalse,
    );
  });

  test('solo and practice are not guarded', () {
    // No peer to strand, and no session whose teardown costs anything.
    expect(
      leavingNeedsConfirmation(isRealDuel: false, matchEnded: false),
      isFalse,
    );
    expect(
      leavingNeedsConfirmation(isRealDuel: false, matchEnded: true),
      isFalse,
    );
  });
}
