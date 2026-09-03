// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_segmentation.dart — THE ONE implementation of how an incantation's
// element stream is cut into formulas (docs/LEYLINE_SEED_PLAN.md §7).
//
// ## Why this file exists
//
// Before it, five places independently wrote `for (i = 0; i + 3 <= n; i += 3)`
// — the live `FormulaTracker`, the engine's authored-formula fallback, the
// effect-label helper, the card-geometry helper and the card painter's
// affinity histogram — plus three more that wrote `(n ~/ 3) * 3` for the same
// rule expressed as a count. Every one of them was correct, and every one of
// them would have had to be found again the day formula length stopped being
// the literal 3.
//
// That day is coming: under a Mutable Leyline the length is 4, 5 or 6
// (LEYLINE_SEED_PLAN.md §16), which makes it **consensus-significant** — two
// devices that cut the same certified trajectory into different chunks resolve
// different spells. Consolidating first, while the answer is still 3
// everywhere, is what makes that later change a one-line seam instead of an
// archaeology exercise.
//
// **Nothing here reads a LeylineConfig, and nothing here knows what a leyline
// is.** Every production caller passes [kIncantationFormulaLength] today. Wiring
// the active configuration's length in is a separate, consensus-visible change
// (the audit's Slice D) and must arrive with an engine-version bump.
//
// ## Scope: incantations only
//
// Summons and Aetherial Armor do NOT chunk. Both scan for fixed 4-element
// patterns *anywhere* in a sequence, allow overlapping matches, and grant each
// outcome at most once (`creature_spec.dart`'s `kSummonAbilityPattern`,
// `certified_armor.dart`'s `armorKeywordPatterns`). They have no formulas, no
// tails and no residual. Do not route them through this file, and do not
// generalise it to try to serve them — that generalisation is explicitly not
// ratified.
//
// ## What this file deliberately does NOT do
//
// It does not decode element names, filter unrecognised entries, or interpret a
// chunk. Those belong to the callers, and they legitimately differ: the engine
// and the effect-label helper drop unrecognised names BEFORE segmenting, while
// the card painter's affinity histogram segments the raw stored list so an
// unrecognised entry still occupies a slot. Both behaviours are preserved
// exactly because this primitive is generic over the element type and touches
// only the boundaries.

/// The ordinary grammar's formula length: `Affinity | EffectKey1 | EffectKey2`
/// (LEYLINE_SEED_PLAN.md §3).
///
/// **The one definition of the number 3 as a grammar fact.**
/// `LeylineConfig.kOrdinaryFormulaLength` aliases this rather than restating
/// it, so the config layer's canonicality rule and the segmentation it
/// describes can never disagree.
const int kIncantationFormulaLength = 3;

/// Cuts [elements] into disjoint, non-overlapping groups of [formulaLength],
/// in order, **discarding any incomplete trailing group**.
///
/// LEYLINE_SEED_PLAN.md §7, transcribed: *"Trajectory entries are consumed in
/// sequential non-overlapping groups of the configured formula length. […]
/// Incomplete trailing entries do not form a formula."* That is exactly the
/// behaviour every call site had before this function existed, so adopting it
/// changes nothing at [kIncantationFormulaLength].
///
/// Generic over the element type on purpose: callers hold either
/// `List<BorderZone>` (already decoded) or `List<String>` (the stored
/// `SpellAsset.formula`), and which of those they segment is a real, preserved
/// difference between them — see this file's header.
///
/// The returned groups are unmodifiable views' copies; mutating [elements]
/// afterwards does not affect them.
///
/// ```dart
/// segmentFormulas([f, f, f, e, e], formulaLength: 3) // => [[f, f, f]]
/// segmentFormulas([f, f], formulaLength: 3)          // => []
/// ```
List<List<T>> segmentFormulas<T>(
  List<T> elements, {
  required int formulaLength,
}) {
  _checkLength(formulaLength);
  final out = <List<T>>[];
  for (var i = 0; i + formulaLength <= elements.length; i += formulaLength) {
    out.add(List<T>.unmodifiable(elements.sublist(i, i + formulaLength)));
  }
  return out;
}

/// How many complete formulas [elementCount] elements yield.
///
/// The count form of [segmentFormulas]; `segmentFormulas(xs, …).length` always
/// equals `completeFormulaCount(xs.length, …)`, and that equivalence is pinned
/// by test.
int completeFormulaCount(int elementCount, {required int formulaLength}) {
  _checkLength(formulaLength);
  if (elementCount <= 0) return 0;
  return elementCount ~/ formulaLength;
}

/// How many elements lie INSIDE complete formulas — [elementCount] truncated
/// down to a multiple of [formulaLength].
///
/// The index at which the discarded residual begins, and the length of the
/// prefix a caster is actually expected to recite (`expectedRecitalSlots`).
int completeFormulaElementCount(
  int elementCount, {
  required int formulaLength,
}) =>
    completeFormulaCount(elementCount, formulaLength: formulaLength) *
    formulaLength;

/// A formula of zero or negative length is not a shorter grammar, it is a
/// nonsensical one: it would make every element stream yield infinitely many
/// empty formulas, or none at all, with nothing to signal which.
///
/// The UPPER bound is deliberately NOT enforced here.
/// `LeylineConfig._checkCanonical` owns the ratified 4..6 range for mutable
/// leylines (LEYLINE_SEED_PLAN.md §16) and rejects anything outside it at
/// construction, at decode and at hash time; restating that here would be a
/// second, drift-prone copy of a consensus rule in a layer that does not know
/// what a leyline is.
void _checkLength(int formulaLength) {
  if (formulaLength < 1) {
    throw ArgumentError.value(
      formulaLength,
      'formulaLength',
      'a formula must be at least one element long',
    );
  }
}
