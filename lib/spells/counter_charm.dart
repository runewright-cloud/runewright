// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm.dart — the trajectory counter charm's pure rules
// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2, §3.2, Phase 2).
//
// A counter charm is no longer bound to one spell's grid. The player types an
// elemental TRAJECTORY when the charm is created, and any spell whose
// certified element sequence opens with that trajectory is countered — effect
// by effect, for as long as the two sequences stay in lockstep.
//
// Everything here is pure and dependency-free (BorderZone only) so both the
// library UI, which authors charms, and TurnLoop, which fires them, run the
// SAME rules. Do not reimplement the match or the cost anywhere else: the
// charm fires inside the deterministic turn resolution both devices replay,
// so a second copy of these rules that drifts is a desync, not a display bug.

import 'package:rune_duel/engine/border_zone.dart';

/// One formula is exactly three activations (FormulaTracker groups committed
/// elements into threes), and the charm's unit of matching is the formula —
/// so a charm's trajectory is always a whole number of formulas.
const int kElementsPerFormula = 3;

/// Entry cap on charm length, in formulas.
///
/// Not a balance rule — [counterCharmManaCost] is the balance rule, and it is
/// already brutal at this length (a 4-formula charm costs a full innate mana
/// pool *per trigger*, MatchConfig.innateManaPool). This exists so the entry
/// UI has a finite surface and so a malformed loadout can be rejected rather
/// than resolved.
const int kMaxCharmFormulas = 4;

/// The `k` in §3.2's `cost = k · F(F+1)/2`.
///
/// `[TODO — playtest]`, like the other artifact constants (the melee proc rate
/// and the Rod of Wind rate in turn_loop.dart). Grounding for 10, from §3.2:
/// the innate pool is 100 and Meditate restores 25, so a one-formula charm
/// (10) costs under half a Meditate — cheap enough that baiting it out with a
/// single-effect spell is a real trade — while a four-formula charm (100)
/// costs a whole innate pool per trigger. Tune `k`; keep the triangular shape,
/// which is what stops long charms from being strictly correct.
///
/// Phase 1's histogram (scripts/trajectory_histogram.dart) is what should set
/// this: if one 3-element opening covers a large share of real spells, raise
/// it. Run the script against a library export from the playtest.
const int kCounterCharmCostPerFormula = 10;

// ── Validity ─────────────────────────────────────────────────────────────────

/// True iff [trajectory] is a legal charm: a whole number of formulas, at
/// least one, at most [kMaxCharmFormulas].
///
/// Neutral is deliberately unrepresentable — [BorderZone] has no neutral
/// member, and `FormulaTracker` never commits a neutral or tied generation, so
/// the matching alphabet is 4 symbols on both sides by construction (§2.1).
bool isValidCharmTrajectory(List<BorderZone> trajectory) =>
    trajectory.isNotEmpty &&
    trajectory.length % kElementsPerFormula == 0 &&
    trajectory.length <= kMaxCharmFormulas * kElementsPerFormula;

// ── Cost ─────────────────────────────────────────────────────────────────────

/// Mana the charm's OWNER pays each time the charm triggers (§2.4, §3.2):
/// triangular in formulas, `k · F(F+1)/2`.
///
/// Charged on every trigger regardless of how many effects were actually
/// cancelled — that is the balance lever against absurdly long charms, and it
/// is why a long charm firing against a short spell is a bad trade rather
/// than a free one.
int counterCharmManaCost(List<BorderZone> trajectory) {
  final f = trajectory.length ~/ kElementsPerFormula;
  return kCounterCharmCostPerFormula * f * (f + 1) ~/ 2;
}

// ── Matching ─────────────────────────────────────────────────────────────────

/// How many whole formulas of [spellSequence] this [charm] cancels: walk both
/// sequences from the start, stop at the first divergence (§2.3), and keep
/// only the whole formulas that agreed.
///
/// Returns 0 when fewer than three leading elements agree — three is the
/// trigger threshold (§2.2), and it is exactly one formula.
///
/// **Whole formulas for summons too.** A summon reads its element sequence as
/// stat contributors rather than effects, and §5's wording is "cancel the
/// first 3 stat contributors"; a partially-agreeing fourth-to-sixth element
/// therefore cancels nothing extra. Keeping one number for both cast modes is
/// also what lets the mana charge, the UI copy, and the canonical state all
/// speak in formulas — see TurnLoop's counter-charm section.
int counterCharmFormulaMatch(
  List<BorderZone> charm,
  List<BorderZone> spellSequence,
) {
  final limit =
      charm.length < spellSequence.length ? charm.length : spellSequence.length;
  var agreed = 0;
  while (agreed < limit && charm[agreed] == spellSequence[agreed]) {
    agreed++;
  }
  return agreed ~/ kElementsPerFormula;
}

// ── Display / serialization ──────────────────────────────────────────────────

/// Human-readable trajectory, formula-grouped: `Fire·Fire·Air / Water·Air·Air`.
///
/// Derived, never stored: a persisted display string would be a second source
/// of truth for the same trajectory and could only ever drift out of step with
/// it (which is what the old `targetSpellName` did once a bound spell was
/// renamed).
String charmTrajectoryLabel(List<BorderZone> trajectory) {
  final formulas = <String>[];
  for (var i = 0; i < trajectory.length; i += kElementsPerFormula) {
    final end = (i + kElementsPerFormula).clamp(0, trajectory.length);
    formulas.add(
      trajectory.sublist(i, end).map(_capitalized).join('·'),
    );
  }
  return formulas.join(' / ');
}

String _capitalized(BorderZone z) =>
    z.name[0].toUpperCase() + z.name.substring(1);

/// Lowercase element names, the form persisted in chapter JSON and sent on the
/// artifact-loadout wire. Matches `SpellAsset.formula`'s encoding so the two
/// can be compared by eye in a log.
List<String> charmTrajectoryToNames(List<BorderZone> trajectory) =>
    [for (final z in trajectory) z.name];

/// Inverse of [charmTrajectoryToNames]. Unknown names are dropped, so a
/// trajectory persisted by a future build with a wider alphabet degrades to a
/// shorter (and, if it stops being a whole number of formulas, invalid) charm
/// rather than throwing on load.
List<BorderZone> charmTrajectoryFromNames(List<String> names) =>
    [for (final n in names) ?borderZoneFromName(n)];

/// Case-insensitive [BorderZone] lookup; null for anything else (including
/// `'neutral'`, which is not a border zone and never enters a trajectory).
BorderZone? borderZoneFromName(String name) => switch (name.toLowerCase()) {
      'fire' => BorderZone.fire,
      'air' => BorderZone.air,
      'water' => BorderZone.water,
      'earth' => BorderZone.earth,
      _ => null,
    };
