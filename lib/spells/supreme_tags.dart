// SPDX-License-Identifier: GPL-3.0-or-later
//
// supreme_tags.dart — derives a spell's supreme/torrential-dominance zone
// tags by replaying its own CA trajectory locally (Dart-only, no proving).
//
// Used both to backfill SpellAsset.supremeTags for spells inscribed before
// that tracking existed, and by battle_screen.dart's cast-time enhancement
// picker to determine which zones a spell is eligible for.

import '../engine/ca_rules.dart';
import '../engine/ca_run.dart' show advanceDominance;
import '../engine/formula.dart';
import '../engine/hex_grid.dart';
import '../engine/stepper.dart' show CAStep;
import 'spell_asset.dart';

/// Replays [spell].initialGrid for [spell].t generations and returns the
/// zone names of any elements that achieved supreme dominance.
Set<String> deriveSupremeTags(SpellAsset spell) {
  if (spell.initialGrid.isEmpty) return {};
  var grid = HexGrid.fromPackedState(spell.initialGrid, 12);
  var rule = CARules.neutral;
  final tags = <String>{};
  for (int gen = 0; gen < spell.t; gen++) {
    final next = CAStep.step(grid, rule);
    final dom = advanceDominance(rule, next);
    if (dom.isSupreme) {
      final zone = FormulaTracker.zoneFor(dom.dominant);
      if (zone != null) tags.add(zone.name);
    }
    grid = next;
    rule = dom.rule;
  }
  return tags;
}
