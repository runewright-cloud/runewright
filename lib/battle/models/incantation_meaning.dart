// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_meaning.dart — what a complete incantation formula MEANS
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §6, §7.3; audit Slice C).
//
// ## The one distinction this file exists to make
//
//     a complete STRUCTURAL formula  ≠  a meaningful incantation EFFECT
//
// Before this file the two were the same thing by construction: every complete
// chunk of `formula_segmentation.dart` fed `effectKindFromPair`, which is
// total over the sixteen tails, so "the formula is complete" and "the formula
// does something" were one fact wearing two names. Under a Mutable Leyline
// they come apart — a chunk can be syntactically complete and semantically
// inert (**noise**, §6) — and every consumer that conflated them would have to
// be found and re-read at that moment. Naming the distinction now, while
// ordinary play still makes it vacuous, is what turns Slice D into a wiring
// change instead of a semantics change.
//
// ## Ordinary play is unchanged, and that is checkable
//
// [ordinaryIncantationMeaning] is `effectKindFromPair` and nothing else, so it
// is TOTAL: under ordinary magic every complete formula is meaningful and
// noise is unreachable. That equivalence is pinned exhaustively over all
// sixteen tails in `test/battle/models/incantation_meaning_test.dart`.
// **`effectKindFromPair` remains the canonical ordinary mapping** — this is a
// wrapper that renames its result, never a second table, and it must never
// grow a branch on a seed, a config, a hash or a codebook.
//
// ## What is deliberately NOT here
//
//   * **No leyline.** Nothing in this file imports `LeylineConfig` or
//     `leyline_codebook.dart`, takes a seed, or hashes anything. That is the
//     dependency boundary the extraction bought: ordinary production code can
//     talk about meaning without being able to *see* `IncantationCodebook`,
//     let alone call `derive` (see the codebook's header for why calling it on
//     an ordinary config would silently rekey every existing spellbook).
//   * **No mutable behaviour.** The types below can represent a mutable
//     result, because a representation that could not would not be worth
//     extracting; nothing reachable from gameplay produces one. Wiring is
//     Slice D and needs `kBattleEngineVersion` 12 → 13.
//   * **No structural rule.** How an element stream is CUT into formulas lives
//     in `formula_segmentation.dart` and stays there. This file is only about
//     what one already-cut chunk means, which is exactly why the count of
//     complete formulas can stay leyline-independent while their meanings do
//     not (§7.3, and [meaningfulIncantationCount]'s header).
//   * **No generic domain abstraction.** Incantations chunk; Summons and
//     Aetherial Armor do overlapping substring search and have no formulas,
//     no tails and no residual. `lookupFormula(domain, leyline, chunk)` is
//     explicitly not ratified (audit §13 R-8). Everything here is named
//     `Incantation…` on purpose.

import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── What a formula means ──────────────────────────────────────────────────────

/// What one complete formula means: an effect, or noise.
///
/// The whole point of the type is that a complete formula has BOTH readings
/// available without a null, a fake [EffectKind], an enum sentinel, or a
/// boolean beside a kind that can contradict it. Ordinary play only ever
/// produces [IncantationEffect] ([ordinaryIncantationMeaning] is total); a
/// Mutable Leyline is what makes [IncantationNoise] reachable, and it is not
/// wired up yet.
///
/// A sealed hierarchy rather than a nullable [EffectKind], a sentinel enum
/// member, or a seventeenth `EffectKind.noise`. All three alternatives were
/// rejected deliberately:
///
///   * **`EffectKind?`** makes "no effect" indistinguishable from "not looked
///     up yet" / "unrecognised element" / "residual chunk" at every call site,
///     and Slice C has to teach four separate consumers to filter it. A `null`
///     that means something specific is a comment, not a type.
///   * **A sentinel member of `EffectKind`** would put a non-effect into the
///     vocabulary that `kEffectKindLabel`, `kEffectDescription`,
///     `effectKindFromPair` and the wire codec all treat as total — sixteen
///     effects is a load-bearing number (§5's per-effect counts, the 4×16
///     table, `kIncantationEffectCode`).
///   * **A separate `bool isNoise` beside a kind** is two fields that can
///     disagree.
///
/// Sealed gives exhaustive `switch` instead, so a consumer cannot
/// forget the noise case — the analyzer refuses to compile a switch that does.
sealed class IncantationMeaning {
  const IncantationMeaning();
}

/// A formula that means one of the sixteen base effects.
final class IncantationEffect extends IncantationMeaning {
  const IncantationEffect(this.kind);

  final EffectKind kind;

  @override
  bool operator ==(Object other) =>
      other is IncantationEffect && kind == other.kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'IncantationEffect(${kind.name})';
}

/// A formula that is syntactically complete but semantically inert
/// (LEYLINE_SEED_PLAN.md §6, audit §6).
///
/// Ratified semantics, for whoever wires this in: the chunk is consumed
/// structurally and still counts toward intrinsic certified base mana cost
/// exactly as a meaningful chunk does; it produces no effect, contributes no
/// affinity, grants no Wild Magic eligibility, and never falls back to another
/// formula. **Leylines change interpretation, not intrinsic certified cost.**
final class IncantationNoise extends IncantationMeaning {
  const IncantationNoise();

  @override
  bool operator ==(Object other) => other is IncantationNoise;

  @override
  int get hashCode => 0x4e4f4953; // 'NOIS'

  @override
  String toString() => 'IncantationNoise()';
}

/// The canonical noise value. A `const` singleton so equality and identity
/// agree and nothing allocates per formula.
const IncantationNoise kIncantationNoise = IncantationNoise();

// ── The ordinary interpretation (no leyline, no codebook) ─────────────────────

/// What a complete formula's tail means under **ordinary** magic.
///
/// A one-line wrapper over [effectKindFromPair], which stays the canonical
/// ordinary mapping — the accumulated scholarship of the 4×16 table, not a
/// thing to be re-derived. This function adds exactly one fact to it: an
/// ordinary tail is ALWAYS meaningful, so the return type is narrowed to
/// [IncantationEffect] rather than [IncantationMeaning]. That narrowing is the
/// whole value: a caller holding this result needs no noise branch, and the
/// analyzer says so.
///
/// [effectType1] and [effectType2] are `chunk[1]` and `chunk[2]` of a complete
/// formula — the TAIL. `chunk[0]` is the affinity and is deliberately not a
/// parameter: §3's protected invariant is that a leyline may change what a
/// tail means but never what an affinity means, so affinity has no business in
/// an interpretation function even when interpretation becomes leyline-aware.
///
/// **Must never take a seed, a config, a hash or a codebook.** Ordinary
/// formulas are leyline-independent by ratification; a derivation here would
/// produce a *permutation* of the fixed table and silently rekey every
/// existing spellbook (`IncantationCodebook.derive` refuses an ordinary config
/// for exactly this reason). If a mutable interpretation is ever needed it is a
/// SEPARATE entry point taking a codebook, chosen by the caller — never a
/// branch inside this one.
IncantationEffect ordinaryIncantationMeaning(
  BorderZone effectType1,
  BorderZone effectType2,
) =>
    IncantationEffect(effectKindFromPair(effectType1, effectType2));

// ── Eligibility (audit §6's ratified table, one row per predicate) ────────────
//
// Three named predicates over one exhaustive switch. They agree today because
// §6 rules all three the same way for noise, and they are named separately
// anyway because they are three separate rows of a ratified table read by three
// separate consumers — `EffectResolver`, `pureAffinityOf`, and
// `WildMagic.eligibleElements`. A later ruling that split them (say: noise
// contributes affinity but no effect) would then be a change to one predicate
// with its own test, not a hunt for which call sites meant which row.
//
// NONE of them is wired into gameplay yet. Ordinary interpretation is total, so
// wiring them today could not change an output — which is exactly why they are
// landed and tested now, before anything can produce noise to trip over.

/// The single exhaustive reading of "does this formula manifest anything".
///
/// A `switch` rather than a virtual getter so that adding a third
/// [IncantationMeaning] variant fails to compile HERE, in the one place that
/// has to decide, instead of silently inheriting a default.
bool _manifests(IncantationMeaning meaning) => switch (meaning) {
      IncantationEffect() => true,
      IncantationNoise() => false,
    };

/// Whether this formula produces an incantation effect at all (§6 row 3).
///
/// The `EffectResolver` question. False for noise: a noise formula resolves to
/// nothing and **never falls back** to another formula's effect.
bool incantationManifestsEffect(IncantationMeaning meaning) =>
    _manifests(meaning);

/// Whether this formula's `chunk[0]` contributes its affinity (§6 row 4).
///
/// The `DeterministicResolution.pureAffinityOf` question — chain
/// discount/advancement purity. False for noise: a noise chunk carries an
/// affinity element structurally, but that element is not a thing the spell
/// *does*, so it can neither establish nor break purity.
bool incantationContributesAffinity(IncantationMeaning meaning) =>
    _manifests(meaning);

/// Whether this formula contributes Wild Magic eligibility (§6 row 5).
///
/// The `WildMagic.eligibleElements` question — the first-entry tally whose
/// most-frequent element(s) become eligible. False for noise: a noise formula
/// adds nothing to the tally, exactly as if the spell had one fewer formula.
///
/// This is eligibility ONLY. It says nothing about the Wild Magic semantic
/// hash, its 3×4 table, its RNG or its coalescing — all of which are keyed to
/// the certified trajectory and `leylineConfigHash` and are ratified as NOT
/// rekeyed by a leyline (audit §8, R-7). Noise suppresses a formula's
/// *contribution to the tally*; it moves no preimage byte.
bool incantationContributesWildMagicEligibility(IncantationMeaning meaning) =>
    _manifests(meaning);

/// How many of [meanings] manifest an effect.
///
/// **This is NOT the structural formula count, and the difference is the whole
/// of §7.3.** Intrinsic pricing — `PeerCastVerifier.certifiedBaseManaCost`,
/// `DeterministicResolution.wireBaseManaCost`, the inscribe-time
/// `SpellAsset.manaCost`, and through that `behaviouralKinKey`, kin stacking
/// and heraldic identity — counts COMPLETE STRUCTURAL CHUNKS
/// (`segmentFormulas(...).length` / `completeFormulaCount`), never this. A
/// noise formula consumes its chunk and is priced exactly like a meaningful
/// one: **leylines change interpretation, not intrinsic certified cost.**
///
/// So this exists for the consumers that ask "what does this spell DO" —
/// effect resolution, affinity purity, Wild Magic eligibility — and for the
/// test that pins the two counts apart. Under ordinary magic it always equals
/// the structural count, which is why nothing changes today.
int meaningfulIncantationCount(Iterable<IncantationMeaning> meanings) {
  var count = 0;
  for (final meaning in meanings) {
    if (_manifests(meaning)) count++;
  }
  return count;
}
