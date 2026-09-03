import 'border_zone.dart';
import 'ca_rules.dart';
import 'formula_segmentation.dart';

// Turns the per-generation dominance signal into a spell formula -- an
// ordered list of elements -- via a three-rule precedence cascade. Fed
// streaming, one generation at a time, via step(); GameScreen is the only
// caller (main.dart), driving it live during interactive play.
//
// At most one element is added per generation. Treating the pre-first
// generation's dominant as "none" (null/0):
//
//   leadChange = zone != null && zone != lastDominant   -- rule 1: an
//     element takes the lead (including re-taking it after a tie/neutral
//     interruption -- a neutral generation resets lastDominant to null, so
//     fire -> neutral -> fire counts as two separate lead changes)
//   else supremeDominant && zone != null                -- rule 2: supreme,
//     add every step
//   else pulseStep && zone != null                       -- rule 3: cadence
//     step, single dominant
//   else: nothing added
//
// A tie or neutral generation (zone == null) never adds anything under any
// branch, but DOES update lastDominant to null, so the next non-neutral
// dominant is always treated as a fresh lead change. Rule 1 is checked
// first, so a generation that's simultaneously a lead change and supreme
// (or a lead change landing on a pulse step) adds that one element once,
// not twice -- the branches can never disagree on which element to add,
// since they all add the same generation's `zone`.
//
// Activations are grouped into formulas by formula_segmentation.dart's one
// segmentation primitive -- ordinarily groups of exactly 3. Any incomplete
// trailing remainder is held as residuals until enough activations arrive to
// complete the next group.
class FormulaTracker {
  // Matches InkRules' default cadence (lib/engine/ink_step.dart) -- the
  // same pulse generations (4, 8, 12, ...) Rule E fires on. Hardcoded
  // rather than imported: InkRules.cadence is a per-instance constructor
  // default, not a standalone constant, and formula.dart has no other
  // reason to depend on the ink ruleset module.
  static const int cadence = 4;

  final List<BorderZone> _committed = [];

  // The previous generation's dominant zone (null = neutral or tie) --
  // used to detect lead changes. Distinct from the committed list itself.
  BorderZone? _lastDominant;

  // Generations fed so far, 1-indexed to match HexGrid.stepCount (the
  // first step() call is generation 1) -- the same convention
  // InkStep.step's pulse check uses directly (generation % cadence == 0),
  // not the 0-indexed `gen` runStepper's loop variable uses internally.
  int _generation = 0;

  // All finalized activations.
  List<BorderZone> get committed => List.unmodifiable(_committed);

  // Complete formula groups, cut by the one segmentation primitive
  // (formula_segmentation.dart). This is the CANONICAL formula stream: the
  // certified replay drives the same tracker, so what this getter returns is
  // what a duel resolves. The length is still the ordinary 3 everywhere --
  // nothing reads a leyline yet.
  List<List<BorderZone>> get formulas => segmentFormulas(
        _committed,
        formulaLength: kIncantationFormulaLength,
      );

  // Activations that haven't yet filled a complete formula (length 0..L-1).
  List<BorderZone> get residuals => List.unmodifiable(
        _committed.sublist(
          completeFormulaElementCount(
            _committed.length,
            formulaLength: kIncantationFormulaLength,
          ),
        ),
      );

  // The current generation's dominant zone, shown as a faint preview, when
  // it did NOT itself get added to the formula this step (e.g. it's
  // leading but not yet supreme or on a pulse step). Unlike the old
  // tracker, this never represents buffered/uncommitted state -- every
  // addition above is committed the instant a rule fires; this is purely
  // "what's currently in front" for FormulaBar's dim preview chip.
  BorderZone? _pendingZone;
  BorderZone? get pendingZone => _pendingZone;

  static BorderZone? zoneFor(CARules rules) {
    const map = {
      'Fire':  BorderZone.fire,
      'Wind':  BorderZone.air,
      'Water': BorderZone.water,
      'Earth': BorderZone.earth,
    };
    return map[rules.name];
  }

  void step(BorderZone? zone, {bool supremeDominant = false}) {
    _generation++;
    final leadChange = zone != null && zone != _lastDominant;
    final pulseStep = _generation % cadence == 0;

    BorderZone? added;
    if (leadChange) {
      added = zone;
    } else if (supremeDominant && zone != null) {
      added = zone;
    } else if (pulseStep && zone != null) {
      added = zone;
    }

    if (added != null) {
      _committed.add(added);
    }

    _pendingZone = (zone != null && added == null) ? zone : null;
    _lastDominant = zone;
  }

  void reset() {
    _committed.clear();
    _pendingZone = null;
    _lastDominant = null;
    _generation = 0;
  }
}
