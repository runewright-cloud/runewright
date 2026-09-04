// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_display.dart — the one interpreted view of a stored spell's
// incantation that UI is allowed to render
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E).
//
// ## What this is
//
// One function, [incantationReadingFor], that turns `SpellAsset.formula` plus
// an [IncantationLexicon] into an [IncantationReading]: an ordered list of
// [IncantationFormulaView] — one entry per COMPLETE STRUCTURAL formula, in
// trajectory order, carrying both the formula's affinity and what it actually
// means under that leyline — plus the affinity of the trailing INCOMPLETE
// group, and the canonical list of affinities the spell speaks for.
//
// That last pair arrived with the 2026-09-04 partial-formula correction, which
// separated a formula's START (which fixes its affinity at once) from its
// COMPLETION (which fixes its meaning). Before it, `views.isEmpty` was taken to
// mean "this spell does nothing", and under a mutable grammar that is simply
// false: a three-element spell at length 4 has no formula and still speaks for
// its first element. Any surface about to tell a player their cast is inert
// must ask [IncantationReading.isSilent], never `views.isEmpty`.
//
// It exists because Slice D made battle resolution leyline-aware while every
// card, tray and label kept reading the ordinary triplet table. Under a
// Mutable Leyline those two answers differ in three separate ways — the
// grammar is 4–6 elements instead of 3, the tail→effect mapping is permuted,
// and some tails mean nothing at all — so a display built on the ordinary
// reading does not merely look stale, it names a different spell than the one
// that will be cast. This is the single seam where that stops.
//
// ## Structural correspondence is the point
//
// The list is **one entry per complete chunk, noise included**, never a
// filtered effect list. `Formula 2 → Noise` has to keep position 2, because
// the surfaces that render this — the card's rules box, the cast tray's
// summary — are showing the player the shape of their own spell, and a list
// that silently dropped the inert chunks would renumber everything after it.
// Callers that genuinely want effects-only (`spellNeedsConveyorDirection` asks
// "does this spell produce an Air tileModification", where position is
// irrelevant) filter with [IncantationFormulaView.manifests] themselves, at
// the call site, where the choice is visible.
//
// ## What it does NOT do
//
//   * **It does not derive a codebook.** It takes a lexicon and asks it
//     questions. `IncantationLexicon.of` remains the only production caller of
//     `IncantationCodebook.derive`, and that is pinned by the posture test in
//     `test/battle/models/incantation_meaning_test.dart`.
//   * **It does not price anything.** `views.length` is the STRUCTURAL count
//     and happens to be the right number for pricing, but nothing here is a
//     pricing path — §7.4 is emphatic that cost reads the certified
//     trajectory, never a display helper over the authored one.
//   * **It does not touch heraldry.** The card's frame gradient and emblem
//     symbol ring stay on `spell_card_painter`'s own raw-string structural
//     histogram and stay leyline-INDEPENDENT (Slice E ruling): those are a
//     spell's identity, and a library that re-skinned itself per duel would be
//     a worse lie than the one this file fixes. What this file feeds is the
//     card's *claim about what the spell does*.
//   * **It does not read the authored formula in battle.** `SpellAsset
//     .formula` is a wire/display field; M4.22 established resolution must
//     read the certified trajectory. This is a display helper over a display
//     field, and the agreement it guarantees is with `lexicon.meaningOf` — the
//     same interpretation the engine applies — not with a particular cast.

import 'package:rune_duel/battle/engine/incantation_lexicon.dart'
    show IncantationLexicon;
import 'package:rune_duel/battle/engine/trajectory_parser.dart'
    show ParsedFormula;
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/formula_segmentation.dart' show segmentFormulas;

/// The player-facing label for a syntactically complete formula that means
/// nothing under the active leyline (audit §6).
///
/// A real word in the vocabulary, not a blank and not a fake [EffectKind]. A
/// noise formula is a thing that HAPPENED — the caster inscribed it, recites
/// it, and pays for it — and it just does not manifest. Blank space in the
/// rules box would read as a rendering failure; an ordinary effect label would
/// be the exact lie this slice exists to prevent.
const String kIncantationNoiseLabel = 'Noise';

/// The one-line explanation shown beside [kIncantationNoiseLabel].
const String kIncantationNoiseDescription =
    'A complete formula that this leyline leaves inert. It is still spoken '
    'and still costs mana, but it produces no effect and lends no affinity.';

/// The player-facing NOUN for an affinity — `Fire`, not `Firey`.
///
/// `kAffinityLabel`'s adjectives read correctly in an effect name (*Firey
/// Blast*) and wrongly on their own (*this spell has Firey affinity*), so
/// prose about an element as an element uses these. Lives here, at the display
/// seam, because the card and the cast tray both name residual affinities now
/// and a second copy of four strings is how two surfaces start disagreeing
/// about what to call water.
const Map<SpellAffinity, String> kAffinityElementName = {
  SpellAffinity.fire: 'Fire',
  SpellAffinity.air: 'Air',
  SpellAffinity.water: 'Water',
  SpellAffinity.earth: 'Earth',
};

/// How a player is told that their trajectory ends mid-formula.
///
/// One sentence, one place, shared by the card's rules box and the cast tray,
/// because the correction's whole point is that these two surfaces must not
/// describe the same spell differently. It states exactly what the ruling
/// grants and no more: the affinity is real, the effect is not, and eligibility
/// is not itself an effect.
String residualAffinityNote(
  SpellAffinity affinity,
  IncantationLexicon lexicon,
) =>
    'A formula begun and left short of the ${lexicon.formulaLength} elements '
    'this leyline reads to one. It works no effect, but still lends the spell '
    '${kAffinityElementName[affinity]} affinity, which wild magic can read.';

/// What one complete structural formula of a stored spell means, ready to
/// render.
///
/// Immutable and compared by value so a widget holding a list of these can be
/// diffed cheaply across a leyline change.
class IncantationFormulaView {
  const IncantationFormulaView({
    required this.index,
    required this.affinity,
    required this.meaning,
    required this.name,
    required this.description,
  });

  /// This formula's position in the spell, 0-based — its STRUCTURAL index,
  /// counting noise. Kept explicitly rather than left to the list position so
  /// a caller that filters can still say "formula 3".
  final int index;

  /// The formula's first element. Structural, and leyline-independent by
  /// ratification: §3's protected invariant is that a leyline changes what a
  /// tail means, never what an affinity means.
  ///
  /// **Present on a noise formula too, and that is deliberate** — the element
  /// really is there in the trajectory. Whether it counts for anything is
  /// [manifests], which is the question every eligibility consumer asks.
  final SpellAffinity affinity;

  /// The interpretation itself: [IncantationEffect] or [IncantationNoise].
  /// Held whole rather than flattened to a nullable [EffectKind] for the
  /// reasons `incantation_meaning.dart` sets out at length.
  final IncantationMeaning meaning;

  /// Display name: `"Firey Blast"` for an effect, [kIncantationNoiseLabel]
  /// for noise.
  final String name;

  /// Flavour text for an effect, [kIncantationNoiseDescription] for noise.
  final String description;

  /// Whether this formula produces an effect — false for noise.
  ///
  /// **This is also the affinity-eligibility answer FOR A COMPLETE FORMULA.**
  /// §6 rules effect, affinity contribution and Wild Magic eligibility
  /// identically for noise, and the three predicates in
  /// `incantation_meaning.dart` are the canonical statement of that; this
  /// getter reads the effect row, and for a complete formula a display that
  /// wants "does this affinity count" wants exactly the same bit.
  ///
  /// It says nothing about the trailing incomplete residual, which has no
  /// meaning to read a row from and is not represented here at all. Do not
  /// build a spell's affinity list out of these — use
  /// [IncantationReading.eligibleAffinities], which is the lexicon's.
  bool get manifests => incantationManifestsEffect(meaning);

  /// The [EffectKind] this formula produces, or null when it is noise.
  ///
  /// A convenience for `switch`-free call sites that genuinely want the kind
  /// or nothing (`spellNeedsConveyorDirection`). Do not use it to *render* —
  /// render [name], so noise gets its word instead of an empty cell.
  EffectKind? get kind =>
      meaning is IncantationEffect ? (meaning as IncantationEffect).kind : null;

  @override
  bool operator ==(Object other) =>
      other is IncantationFormulaView &&
      other.index == index &&
      other.affinity == affinity &&
      other.meaning == meaning;

  @override
  int get hashCode => Object.hash(index, affinity, meaning);

  @override
  String toString() => 'IncantationFormulaView($index, ${affinity.name}, $name)';
}

/// A stored spell's incantation as the active leyline reads it: the complete
/// structural formulas, and the trailing incomplete group's affinity.
///
/// The display counterpart of the 2026-09-04 partial-formula correction. Before
/// it, [views] alone was the whole answer and an empty list meant "this spell
/// does nothing"; now a spell can have no complete formula and still speak for
/// an element, so the surfaces that tell a player what their cast will do need
/// both halves and must be handed them together.
class IncantationReading {
  const IncantationReading({
    required this.views,
    required this.residualAffinity,
    required this.eligibleAffinities,
  });

  /// One view per COMPLETE structural formula, noise included and in order.
  final List<IncantationFormulaView> views;

  /// The affinity of the trailing INCOMPLETE group, or null when the
  /// trajectory divides evenly (or the grammar grants a residual no affinity —
  /// `IncantationLexicon.residualBearsAffinity`).
  ///
  /// It has an affinity and no meaning: no name, no description, no effect. Do
  /// not render it as a formula, and do not look it up.
  final SpellAffinity? residualAffinity;

  /// The affinities this spell speaks for, in trajectory order, **straight
  /// from `IncantationLexicon.eligibleAffinitiesOf`** — the same list
  /// `WildMagic.eligibleElements` tallies at cast time.
  ///
  /// Taken from the lexicon rather than recomputed from [views] and
  /// [residualAffinity] on purpose: the point of the correction's architecture
  /// section is that a card and a duel read ONE derivation, so a second one
  /// here — however obviously equivalent — would be the exact drift it exists
  /// to prevent. That the two agree is pinned by test instead.
  final List<SpellAffinity> eligibleAffinities;

  /// True when nothing about this spell can matter: no complete formula, and
  /// no residual affinity either.
  ///
  /// **This, and not `views.isEmpty`, is the "does nothing" question.** A
  /// three-element spell under a length-4 leyline has no complete formula but
  /// does have Fire affinity, and telling the player it does nothing at the
  /// moment they commit mana would be false — its affinity can still reach
  /// Wild Magic eligibility.
  bool get isSilent => views.isEmpty && eligibleAffinities.isEmpty;
}

/// Reads a stored [formula] (flat `BorderZone` names, as `SpellAsset.formula`
/// holds them) under [lexicon].
///
/// Segmentation follows `lexicon.formulaLength`, so a length-5 leyline yields
/// length-5 chunks and a spell with three elements under it yields no complete
/// formula at all — but, since the correction, it still yields a residual
/// affinity. Callers must not fall back to an ordinary reading to rescue an
/// empty [IncantationReading.views], which is precisely the fallback §6
/// forbids, and must not try to interpret the residual: there is no partial
/// lookup and no padding.
///
/// Unrecognised element names are dropped BEFORE segmenting, matching
/// `DeterministicResolution.parsedFormulas` and the [formulaEffects] this
/// replaces. (That is deliberately NOT what `spell_card_painter`'s heraldic
/// histogram does — see this file's header on why the two differ.)
IncantationReading incantationReadingFor(
  List<String> formula,
  IncantationLexicon lexicon,
) {
  final zones = _zonesOf(formula);
  return IncantationReading(
    views: _viewsOf(zones, lexicon),
    residualAffinity: lexicon.residualAffinityOf(zones),
    eligibleAffinities: lexicon.eligibleAffinitiesOf(zones),
  );
}

/// [incantationReadingFor]'s complete-formula half, for the callers that
/// genuinely only ask what a spell's formulas mean (`formulaEffects`'
/// replacements, `spellNeedsConveyorDirection`).
///
/// An empty result means "no complete formula", never "no effects" and — since
/// the correction — never "nothing happens". Ask [incantationReadingFor] if
/// you are about to tell the player the latter.
List<IncantationFormulaView> incantationViewsFor(
  List<String> formula,
  IncantationLexicon lexicon,
) =>
    _viewsOf(_zonesOf(formula), lexicon);

List<BorderZone> _zonesOf(List<String> formula) {
  final zones = <BorderZone>[];
  for (final name in formula) {
    final zone = switch (name.toLowerCase()) {
      'fire' => BorderZone.fire,
      'earth' => BorderZone.earth,
      'water' => BorderZone.water,
      'air' => BorderZone.air,
      _ => null,
    };
    if (zone != null) zones.add(zone);
  }
  return zones;
}

List<IncantationFormulaView> _viewsOf(
  List<BorderZone> zones,
  IncantationLexicon lexicon,
) {
  final views = <IncantationFormulaView>[];
  final chunks = segmentFormulas(zones, formulaLength: lexicon.formulaLength);
  for (var i = 0; i < chunks.length; i++) {
    final chunk = chunks[i];
    final parsed = ParsedFormula.withTail(
      affinity: chunk[0],
      tail: chunk.sublist(1),
    );
    final affinity = spellAffinityFromZone(chunk[0]);
    final meaning = lexicon.meaningOf(parsed);
    final (name, description) = switch (meaning) {
      IncantationEffect(:final kind) => (
          '${kAffinityLabel[affinity]!} ${kEffectKindLabel[kind]!}',
          kEffectDescription[kind]![affinity]!,
        ),
      IncantationNoise() => (
          kIncantationNoiseLabel,
          kIncantationNoiseDescription,
        ),
    };
    views.add(IncantationFormulaView(
      index: i,
      affinity: affinity,
      meaning: meaning,
      name: name,
      description: description,
    ));
  }
  return views;
}

/// The cast tray's one-line "what am I about to cast" summary.
///
/// Composed here rather than in `battle_screen.dart` so it can be asserted
/// without a battle-screen widget harness — and so the sentence the player
/// reads at the moment they commit mana lives beside the card's, where the two
/// can be kept honest with each other.
///
/// One entry per COMPLETE STRUCTURAL formula, noise included and in position,
/// then the residual's affinity if there is one. It never says the cast does
/// nothing: since the partial-formula correction that is false whenever a
/// residual exists, and [IncantationReading.isSilent] is the only thing
/// entitled to claim it.
String incantationCastSummary(
  List<String> formula,
  IncantationLexicon lexicon,
) {
  final reading = incantationReadingFor(formula, lexicon);
  final labels = [for (final v in reading.views) v.name];
  final residual = reading.residualAffinity;
  if (labels.isEmpty) {
    if (!lexicon.isMutable) return 'No recorded effects';
    return residual == null
        ? 'No complete formula — this cast works no effect'
        : 'No complete formula — no effect, '
            '${kAffinityElementName[residual]!.toLowerCase()} affinity only';
  }
  final line = labels.join('  ·  ');
  return residual == null
      ? line
      : '$line  ·  +${kAffinityElementName[residual]!.toLowerCase()} '
          'affinity (unfinished)';
}

/// [incantationViewsFor]'s names, in order — the list form the cast tray and
/// the old [formulaEffectLabels] both want.
///
/// Noise keeps its slot and shows as [kIncantationNoiseLabel]; see this file's
/// header on why filtering here would renumber the spell.
List<String> incantationLabelsFor(
  List<String> formula,
  IncantationLexicon lexicon,
) =>
    [for (final v in incantationViewsFor(formula, lexicon)) v.name];
