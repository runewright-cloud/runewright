// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_dominance_characterization_test.dart — drives the real
// GameScreen widget through seeds that reach the border and captures the
// per-step zone-counter / supreme-banner / active-rule sequence.
//
// Originally written as the behavior-preservation proof for consolidating
// GameScreen's private dominance/decay/supreme statics onto ca_run.dart's
// shared activeZoneFor/isSupreme/advanceDominance. The first test's
// captured baseline was then updated for the A1 (supreme-gated dispatch) /
// A2 (tie-aware decay) / A3 (tie reporting) behavior change -- see the
// note at its assertion for what changed and why. The second test was
// added specifically because the first test's seed never exercises A1 or
// A3 (single zone throughout, never tied, supreme on first touch) -- it
// uses three zones so a real "leading but not supreme" gap and a real tie
// both occur, and checks the most directly player-visible signal of A1's
// effect: which preset is highlighted in the RuleBar (i.e. what's actually
// dispatched), not just the zone counters/banner.
//
// _GameScreenState's functions are private to main.dart and unreachable
// from a test in a different library, so the only way to characterize its
// behavior is to drive the actual widget tree and read rendered text --
// there is no shortcut through internal state.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

// Avoid pumpAndSettle anywhere in these tests: the supreme banner
// (_SupremeDominanceBanner) runs a perpetually-repeating pulse
// AnimationController once mounted, which pumpAndSettle can never observe
// as "settled" -- it would hang/timeout. Bounded pumps only throughout.

Offset _hexScreenPosition(WidgetTester tester, Finder paintFinder, HexCoord coord) {
  final canvasSize = tester.getSize(paintFinder);
  final canvasTopLeft = tester.getTopLeft(paintFinder);
  final hexSize = (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
  final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
  final local = Offset(
    center.dx + hexSize * (3 / 2 * coord.q),
    center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
  );
  return canvasTopLeft + local;
}

Future<void> _tapHex(WidgetTester tester, Finder paintFinder, HexCoord coord) async {
  await tester.tapAt(_hexScreenPosition(tester, paintFinder, coord));
  await tester.pump();
}

Map<String, int> _zoneCounters(WidgetTester tester) {
  final result = <String, int>{};
  for (final label in ['Fire', 'Air', 'Water', 'Earth']) {
    final widgets = tester.widgetList<Text>(find.textContaining('$label: '));
    expect(widgets, isNotEmpty, reason: 'expected a "$label: N" counter to be rendered');
    result[label] = int.parse(widgets.first.data!.split(': ')[1]);
  }
  return result;
}

bool _supremeBannerShown() => find.textContaining('SUPREME DOMINANCE').evaluate().isNotEmpty;

// Map has identity-based == (and Dart records compare fields with each
// field's own ==), so a List<(Map<String,int>, bool)> can't be compared
// with equals() across two separately-built lists even when the maps'
// *contents* match. Snapshot each step as a plain deterministic string
// instead, which has real value equality.
String _snapshot(Map<String, int> counters, bool supreme) =>
    '${['Fire', 'Air', 'Water', 'Earth'].map((z) => '$z:${counters[z]}').join(',')},supreme:$supreme';

// The RuleBar highlights exactly one preset -- the active/dispatched one --
// with the bright ink color; every other preset is dimmed. This is the most
// directly player-visible signal of what's actually running, distinct from
// the zone counters (which reflect pressure, not dispatch) and the supreme
// banner (which already existed pre-A1 and doesn't by itself prove dispatch
// is gated).
//
// The bar is a read-only readout, so there is no tappable ancestor to key
// off: each preset is keyed 'rule-chip-<Name>' and carries its state in its
// own Text color. (It used to be a row of TextButtons whose active one was
// disabled -- but those buttons let a player *set* the infusion by hand,
// bypassing supreme dominance entirely, so they're gone.)
String _activeRuleBarLabel(WidgetTester tester) {
  for (final label in ['Neutral', 'Fire', 'Earth', 'Water', 'Wind']) {
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('rule-chip-$label')),
        matching: find.byType(Text),
      ),
    );
    if (text.style?.color == const Color(0xFFF5F0E8)) return label;
  }
  throw StateError('no RuleBar preset is highlighted as active');
}

void main() {
  testWidgets('seed reaching the border: zone counters and supreme banner per step', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    final paintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);

    // A 2-cell straight stroke pointed directly at a border cell: (7,0) and
    // (8,0) are both within the tappable inner radius (8); Rule B's tip
    // extension carries (8,0) straight out to (12,0) -- a border cell --
    // over 4 generations of plain growth (no other rule fires on this
    // geometry before then, see ink_step_test.dart's straight-stroke case).
    await _tapHex(tester, paintFinder, const HexCoord(7, 0));
    await _tapHex(tester, paintFinder, const HexCoord(8, 0));
    await tester.pump();

    expect(_zoneCounters(tester).values.every((v) => v == 0), isTrue, reason: 'no border contact yet');
    expect(_supremeBannerShown(), isFalse);

    final stepButton = find.text('Step');
    final captured = <String>[];
    for (var i = 0; i < 8; i++) {
      await tester.tap(stepButton);
      await tester.pump();
      // Let the 400ms AnimatedSwitcher banner transition finish without
      // using pumpAndSettle (see note above).
      await tester.pump(const Duration(milliseconds: 500));
      captured.add(_snapshot(_zoneCounters(tester), _supremeBannerShown()));
    }

    // Gen 4 (index 3): the tip reaches the border, the first border touch.
    final firstTouch = captured.indexWhere((s) => !s.startsWith('Fire:0,Air:0,Water:0,Earth:0'));
    expect(firstTouch, equals(3), reason: 'border contact should land on generation 4 (index 3)');
    // A lone zone's first activation is trivially supreme: with only one
    // zone holding any pressure, that zone's pressure equals the total, and
    // value*2 > value for any positive value.
    expect(captured[firstTouch], endsWith('supreme:true'));

    // Full captured sequence pinned as the current baseline (captured
    // empirically, not hand-derived).
    //
    // This DIFFERS from the previous baseline (1,2,3,7,11 for Water from
    // gen4) at gen6 onward, because of a change one commit later than the
    // A1/A2/A3 dispatch rework: 42c75c6 revised CARules.water from
    // surviveOn {3,4,5,6}/bornOn {1,2} to the much more restrictive
    // surviveOn {2,3}/bornOn {1}. Once Water is dispatched at gen4, the
    // grid evolves under that restrictive ruleset, and the stroke's growth
    // against the border stops being a steady ramp -- it goes quiet for a
    // generation, then bursts (raw per-generation border-activation deltas
    // are actually 0,0,0,3,3,0,0,3, not a smooth +1,+1,+4,+4). Decay
    // (D = stepCount~/2, applied every generation regardless of new
    // arrivals) fully absorbs the later bursts the same generation they
    // land -- e.g. at gen8, D=4 exactly cancels that generation's raw +3
    // -- so displayed pressure never climbs again after gen5.
    //
    // Because this particular seed never exercises a tie or a
    // leading-but-not-yet-supreme gap, it doesn't demonstrate A1 or A3's
    // player-visible effect -- see the second test below for a seed that
    // does.
    expect(captured, equals(<String>[
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
      'Fire:0,Air:0,Water:1,Earth:0,supreme:true',
      'Fire:0,Air:0,Water:2,Earth:0,supreme:true',
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
      'Fire:0,Air:0,Water:0,Earth:0,supreme:false',
    ]));
  });

  testWidgets('three-zone seed: a leading-but-not-supreme generation dispatches neutral, not the leader', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    final paintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);

    // Three straight strokes toward three different border zones (Water,
    // Air, Fire -- found via BorderZones.forRadius(12) on the three
    // straight-line directions), Water one generation closer than the
    // other two so it touches first and alone (supreme immediately, same
    // as the first test), then Air and Fire touch together a generation
    // later.
    //
    // This exact seed was re-verified directly against
    // CAStep.step/advanceDominance after 42c75c6's water-rule revision
    // (see the first test's note): the trajectory it produces changed, but
    // it still exercises both non-obvious dispatch behaviors, one
    // generation later than before --
    //   gen5: water and air both land at decayed pressure 3 (fire at 2) --
    //         a genuine tie for the lead, so dominant reports neutral and
    //         nothing is supreme (A3's tie-to-neutral branch).
    //   gen6: fire is now the sole leader (2, vs water/air at 1 each) but
    //         2*2 == 4 does not exceed the total of 4, so it isn't supreme
    //         -- dispatch is gated back to neutral even though fire is
    //         visibly, uniquely ahead (A1's gate).
    await _tapHex(tester, paintFinder, const HexCoord(7, 0));
    await _tapHex(tester, paintFinder, const HexCoord(8, 0));
    await _tapHex(tester, paintFinder, const HexCoord(6, -6));
    await _tapHex(tester, paintFinder, const HexCoord(7, -7));
    await _tapHex(tester, paintFinder, const HexCoord(0, -6));
    await _tapHex(tester, paintFinder, const HexCoord(0, -7));
    await tester.pump();

    final stepButton = find.text('Step');

    // Gen 1-3: no border contact yet, neutral throughout.
    for (var i = 0; i < 3; i++) {
      await tester.tap(stepButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_activeRuleBarLabel(tester), equals('Neutral'));
      expect(_supremeBannerShown(), isFalse);
    }

    // Gen 4: Water alone touches the border -- trivially supreme (same
    // mechanism as the first test) -- so Water IS dispatched.
    await tester.tap(stepButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_activeRuleBarLabel(tester), equals('Water'));
    expect(_supremeBannerShown(), isTrue);

    // Gen 5: Air and Fire both touch the border this generation. Water and
    // Air land in an exact tie for the lead (fire trails) -- a real tie,
    // not a unique leader -- so dominant reports neutral (A3) regardless
    // of supremacy.
    await tester.tap(stepButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_activeRuleBarLabel(tester), equals('Neutral'),
        reason: 'water and air are tied for the lead -- a tie always dispatches neutral');
    expect(_supremeBannerShown(), isFalse);
    final gen5Counters = _zoneCounters(tester);
    expect(gen5Counters['Water'], equals(gen5Counters['Air']),
        reason: 'water and air land in an exact tie for the lead this generation');
    expect(gen5Counters['Water'], greaterThan(gen5Counters['Fire']!));

    // Gen 6: no new border contact. Decay breaks the gen5 tie -- fire (not
    // decayed as heavily, having never been a tied leader) is now the sole
    // leader -- but fire's pressure (2) doesn't exceed the other zones'
    // combined pressure (1 + 1 = 2), so it isn't supreme. This is the A1
    // proof: under the OLD ungated dispatch, the RuleBar would now
    // highlight "Fire" (the new unique leader) -- under the gated system,
    // dispatch stays at neutral because the leader isn't supreme, even
    // though fire visibly, uniquely leads the zone counters.
    await tester.tap(stepButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_activeRuleBarLabel(tester), equals('Neutral'),
        reason: 'fire leads this generation but is not supreme -- A1 must gate dispatch back to neutral');
    expect(_supremeBannerShown(), isFalse);
    final gen6Counters = _zoneCounters(tester);
    expect(gen6Counters['Fire'], greaterThan(gen6Counters['Water']!),
        reason: 'fire should visibly be ahead in the zone counters even though it is not dispatched');
    expect(gen6Counters['Fire'], greaterThan(gen6Counters['Air']!));
  });
}
