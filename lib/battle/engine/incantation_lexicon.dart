// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_lexicon.dart — THE seam where a leyline decides what a complete
// incantation formula means (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md
// §6, §7.4, §13 Slice D).
//
// ## What this is
//
// One object, built once from the match's canonical [LeylineConfig], that
// answers the only two leyline-dependent questions the engine has:
//
//   1. **How long is a formula?** ([formulaLength]) — a STRUCTURAL fact, and
//      the only thing that may move `certifiedBaseManaCost`.
//   2. **What does this complete formula mean?** ([meaningOf]) — a SEMANTIC
//      fact, and the thing that may never move mana, identity or a proof.
//
// Keeping both on one object is deliberate: they come from the same config, and
// a build that chunked at one length while interpreting under another leyline's
// dictionary would resolve a spell no device agrees with. There is one
// constructor, it takes the whole config, and it cannot be assembled from
// halves.
//
// ## Why a lexicon and not `if (leyline.mutableMagic)` at each call site
//
// Slice C's posture test counted the production readers of `mutableMagic`:
// zero. Slice D adds exactly one — [IncantationLexicon.of] — and the posture
// test now pins that. Every downstream consumer asks this object a question
// instead of asking the config a boolean, so "what does a leyline change"
// stays answerable by reading one file rather than grepping the engine.
//
// ## Derivation happens HERE and only here
//
// A mutable lexicon derives its [IncantationCodebook] once, in the factory.
// Ordinary lexicons derive NOTHING — `IncantationCodebook.derive` refuses an
// ordinary config outright, and this class never asks it to, so ordinary play
// remains completely independent of the seed, the config hash, the noise
// density and every byte of Slice B's machinery. That independence is pinned
// by test, not merely intended.
//
// There is no cache. A codebook is at most 1024 + 16 SHA-256s and one sort,
// `DeterministicResolution` holds its lexicon in a `late final` for the life of
// the match, and a cache keyed on anything less than the full canonical config
// is a consensus hazard for a saving nobody has measured.
//
// ## What this does NOT do
//
//   * **It does not touch the certified trajectory.** `FormulaTracker`'s three
//     commit rules are length-independent, so the flat committed sequence — the
//     thing proofs attest, `behaviouralKinKey` hashes, heraldry draws and the
//     Wild Magic v2 preimage carries — is byte-identical under every leyline.
//     A lexicon re-cuts that sequence; it never rewrites it.
//   * **It does not price anything.** Callers that price a cast count
//     structural chunks and must never call [meaningfulOf] first. See
//     [meaningfulOf]'s header.
//   * **It does not serve Summons or Armor.** Neither chunks; both do
//     overlapping substring search over fixed 4-element patterns, and their
//     mapping is an unruled design problem (audit §14 R-8). Do not route them
//     through here and do not generalise this to try.
//
// ## Three questions, since the 2026-09-04 partial-formula correction
//
// A third question joined the two above, and it is the one place this object
// looks at a whole trajectory rather than a single formula:
//
//   3. **Which affinities does this trajectory speak for?**
//      ([eligibleAffinitiesOf]) — structural, and deliberately answered here so
//      that a spell card and a duel cannot compute it differently.
//
// The correction that added it separated two things Slice D still conflated:
// a formula's START establishes its affinity, and only its COMPLETION
// establishes its meaning. So the trailing incomplete group of a trajectory —
// the residual — bears its first element's affinity even though it can never be
// interpreted. A completed Noise formula remains the opposite case: complete,
// interpretable, and interpreted to nothing, so it lends no affinity at all.
// See [eligibleAffinitiesOf] and [residualBearsAffinity].

import 'package:rune_duel/battle/engine/trajectory_parser.dart'
    show ParsedFormula;
import 'package:rune_duel/battle/models/effect_kind.dart'
    show SpellAffinity, spellAffinityFromZone;
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/battle/models/leyline_codebook.dart'
    show IncantationCodebook;
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/engine/border_zone.dart' show BorderZone;
import 'package:rune_duel/engine/formula_segmentation.dart'
    show completeFormulaElementCount, segmentFormulas;

/// What formulas mean under one leyline.
///
/// Construct with [IncantationLexicon.of] and hold it for the life of the
/// deterministic context (a match). Two lexicons built from equal configs
/// answer every question identically — pinned by test — so passing one down is
/// an optimisation, never a correctness requirement.
class IncantationLexicon {
  const IncantationLexicon._(this.leyline, this._codebook);

  /// The lexicon for [leyline].
  ///
  /// **The one production reader of `LeylineConfig.mutableMagic`.** An ordinary
  /// config yields an ordinary lexicon and derives nothing; a mutable one
  /// derives its codebook here, once.
  factory IncantationLexicon.of(LeylineConfig leyline) =>
      IncantationLexicon._(
        leyline,
        leyline.mutableMagic ? IncantationCodebook.derive(leyline) : null,
      );

  /// The canonical ordinary lexicon — the three-element grammar and the fixed
  /// `effectKindFromPair` table. `const`, so it can be a default.
  static const IncantationLexicon ordinary =
      IncantationLexicon._(LeylineConfig.ordinaryDefault, null);

  /// The leyline this lexicon speaks for.
  final LeylineConfig leyline;

  /// The derived dictionary, or null under an ordinary leyline — where there is
  /// no dictionary to derive, only the fixed table.
  final IncantationCodebook? _codebook;

  /// Whether this lexicon reinterprets formulas through a derived codebook.
  bool get isMutable => _codebook != null;

  /// How many elements make one complete formula: 3 ordinarily, 4–6 under a
  /// mutable leyline (§16).
  ///
  /// The value every structural segmentation call in a match must be given.
  /// **This is the only leyline-dependent input to intrinsic mana cost**, and
  /// that dependence is ratified: §7.4 — *"`certifiedBaseManaCost` … moves only
  /// when `formulaLength` itself changes, which is already a different
  /// `leylineConfigHash`."* Meaning never moves it; length may.
  int get formulaLength => leyline.formulaLength;

  /// What [formula] means under this leyline.
  ///
  /// Ordinary: the tail's two keys go straight to [ordinaryIncantationMeaning],
  /// i.e. to `effectKindFromPair`, which stays the canonical ordinary mapping
  /// and is never permuted, seeded or re-derived.
  ///
  /// Mutable: the tail IS the codebook key. `chunk[0]` — the affinity — is
  /// deliberately not part of it: §3's protected invariant is that a leyline
  /// changes the grammar, never what an affinity means.
  IncantationMeaning meaningOf(ParsedFormula formula) {
    final codebook = _codebook;
    if (codebook == null) {
      return ordinaryIncantationMeaning(
        formula.effectType1,
        formula.effectType2,
      );
    }
    return codebook.lookup(formula.tail);
  }

  /// The formulas of [formulas] that manifest an effect, in their original
  /// order.
  ///
  /// **Never call this before pricing.** §7.4 is explicit that a noise formula
  /// consumes its chunk and counts toward intrinsic base mana cost exactly as a
  /// meaningful one does: *"leylines change interpretation, not intrinsic
  /// certified cost."* So `certifiedBaseManaCost`, `wireBaseManaCost` and the
  /// persisted `SpellAsset.manaCost` read `formulas.length` — the STRUCTURAL
  /// count — and this list is for the three consumers that ask what a spell
  /// *does*: effect resolution, `pureAffinityOf`, and
  /// `WildMagic.eligibleElements`.
  ///
  /// Under an ordinary leyline this is always the identity, because ordinary
  /// interpretation is total. That is why nothing changes today.
  List<ParsedFormula> meaningfulOf(List<ParsedFormula> formulas) {
    if (!isMutable) return formulas;
    return [
      for (final formula in formulas)
        if (incantationManifestsEffect(meaningOf(formula))) formula,
    ];
  }

  // ── Structural affinity (the 2026-09-04 partial-formula correction) ────────

  /// Whether an INCOMPLETE trailing group lends its first element's affinity.
  ///
  /// **True under a mutable grammar only. RATIFIED 2026-09-04 (audit §7.5,
  /// R-11): residual affinity is a Mutable-grammar rule, not a retroactive
  /// change to ordinary magic.**
  ///
  /// The reasoning, kept because it is what the ruling turned on: ordinary
  /// residuals are 1–2 elements and near-universal, so granting them affinity
  /// would retally `WildMagic.eligibleElements` for a large fraction of every
  /// existing spell — a 4-element ordinary trajectory goes from `{fire}` to a
  /// `{fire, earth}` tie, and a 2-element one from no wild magic at all to
  /// some. That is an unrelated change to ordinary battle semantics, and it was
  /// ruled out rather than merely deferred.
  ///
  /// This getter is therefore a decision, not a placeholder. Do not flip it.
  bool get residualBearsAffinity => isMutable;

  /// The affinity of the trailing INCOMPLETE group of [elements] — the
  /// residual — or null when there is no residual, or this grammar grants it
  /// no affinity ([residualBearsAffinity]).
  ///
  /// The residual has an affinity and no MEANING. It is never interpreted:
  /// there is no partial codebook lookup, no padding to length, and no
  /// fallback to the ordinary triplet table. [meaningOf] is only ever asked
  /// about a formula segmentation actually completed.
  SpellAffinity? residualAffinityOf(List<BorderZone> elements) {
    if (!residualBearsAffinity) return null;
    final residualStart = completeFormulaElementCount(
      elements.length,
      formulaLength: formulaLength,
    );
    if (residualStart >= elements.length) return null;
    return spellAffinityFromZone(elements[residualStart]);
  }

  /// Every affinity the flat element sequence [elements] contributes to LIVE
  /// elemental eligibility under this leyline, in trajectory order.
  ///
  /// **The canonical answer to "which elements does this spell speak for".**
  /// `WildMagic.eligibleElements` tallies exactly this list, and
  /// `incantationReadingFor` renders exactly this list, so a card and a duel
  /// cannot disagree about it — which is the whole reason it lives on the
  /// lexicon rather than being recomputed at each surface.
  ///
  /// The rule, one line per structural group of [formulaLength] elements:
  ///
  ///   * complete **and meaningful** → its first element contributes;
  ///   * complete **Noise** → contributes nothing (audit §6, unchanged);
  ///   * the trailing **incomplete residual** → its first element contributes,
  ///     under a mutable grammar ([residualBearsAffinity]).
  ///
  /// [elements] is the flat CERTIFIED committed sequence
  /// (`TrajectoryParser.certifiedElementSequence`) — residual included, which
  /// is the point. Segmenting it here reproduces `TrajectoryParser.parse`'s
  /// complete-formula list exactly (both go through `segmentFormulas` at this
  /// same [formulaLength]); that equivalence is pinned by test.
  ///
  /// **This is ELIGIBILITY, not effect and not chain purity.** A residual makes
  /// an affinity *eligible*; it manifests nothing, prices nothing, and is not a
  /// formula. `DeterministicResolution.pureAffinityOf` reads the meaningful
  /// COMPLETE formulas only, and that is a **ratified** boundary, not an
  /// oversight (audit §7.5, R-10): a residual must never become a new way to
  /// advance an elemental chain, earn a chain discount, or make an
  /// otherwise-pure completed spell hybrid for chain pricing. **Do not pass
  /// this list to `pureAffinityOf`** — a test group exists precisely to catch a
  /// refactor that does.
  List<SpellAffinity> eligibleAffinitiesOf(List<BorderZone> elements) {
    final out = <SpellAffinity>[];
    for (final chunk in segmentFormulas(
      elements,
      formulaLength: formulaLength,
    )) {
      final formula = ParsedFormula.withTail(
        affinity: chunk[0],
        tail: chunk.sublist(1),
      );
      if (incantationContributesWildMagicEligibility(meaningOf(formula))) {
        out.add(spellAffinityFromZone(chunk[0]));
      }
    }
    final residual = residualAffinityOf(elements);
    if (residual != null) out.add(residual);
    return List.unmodifiable(out);
  }

  @override
  String toString() => 'IncantationLexicon(${leyline.displayName}, '
      'L=$formulaLength, ${isMutable ? "mutable" : "ordinary"})';
}
