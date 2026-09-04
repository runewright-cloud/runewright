// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_picker.dart — the player-facing way to choose a Mutable Leyline
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E,
// docs/LEYLINE_SEED_PLAN.md §1, §16).
//
// ## What this is
//
// The one UI that constructs `LeylineConfig.mutable`. Slice D landed mutable
// interpretation in the engine and deliberately left it unreachable; this is
// the reachable end of it. It emits a whole [LeylineConfig] — never a bag of
// fields for a caller to reassemble — because the config is canonical
// (`LeylineConfig._checkCanonical`) and reassembling it elsewhere is how a
// second, non-canonical spelling of the same leyline gets minted.
//
// ## Where it is offered, and why only there
//
// **Solo practice only, for now.** Not the duel host screen, and the reason
// is a fairness coupling rather than a technical one: the guest picks its
// chapter in `duel_join_chapter_screen.dart` and only learns the host's
// leyline inside `runDuelSetup` step 3, after that choice is locked. The mDNS
// advertisement carries `displayName` + `DeviceCapabilities` and no config, so
// there is nowhere earlier to put it without a discovery/protocol change —
// which Slice E excludes. A host who could pick length 6 would be able to
// leave a guest's whole chapter incantation-incomplete — every spell casting
// for its affinity alone and working no effect — with no warning and no way
// out. Solo practice has no guest, so it has none of that: it is where a
// player learns what a leyline does to their own spellbook before anyone
// duels under one. Wiring this into the host screen is Slice F's job, and it
// needs the leyline visible BEFORE chapter lock.
//
// ## The seed word is not chosen here
//
// [communitySeed] comes in from the screen (the device's own saved word). A
// leyline's tradition and its grammar are separate settings with separate
// homes — Settings owns the word — and offering a second place to type it is
// how two spellings of one tradition end up disagreeing.

import 'package:flutter/material.dart';

import '../../battle/models/leyline_config.dart' show LeylineConfig;
import '../manuscript_theme.dart';
import 'int_stepper_row.dart';

/// The Ordinary / Mutable choice plus, when Mutable, the grammar controls.
///
/// Stateless: the owning screen holds the [LeylineConfig] and rebuilds this
/// with it, so there is exactly one copy of the answer and it lives where the
/// `MatchConfig` is assembled.
class LeylinePicker extends StatelessWidget {
  const LeylinePicker({
    super.key,
    required this.communitySeed,
    required this.value,
    required this.onChanged,
  });

  /// The tradition word this device follows, from Settings. Carried through
  /// both branches unchanged — switching to a Mutable leyline changes the
  /// grammar, never the tradition.
  final String communitySeed;

  /// The config currently chosen. Ordinary or mutable; canonical either way.
  final LeylineConfig value;

  final ValueChanged<LeylineConfig> onChanged;

  /// The formula length a player lands on the first time they switch to
  /// Mutable. (Noise density defaults separately, to §5's ratified 50/50 rule
  /// — `LeylineConfig.kDefaultNoiseDensityPermille`.)
  ///
  /// Length 4 rather than 5 or 6 on purpose — it is the gentlest change from
  /// ordinary play and the one that voids the fewest existing spells, since a
  /// trajectory yields `floor(n / L)` complete formulas and short spells fall
  /// off a cliff as `L` grows.
  static const int kInitialMutableFormulaLength =
      LeylineConfig.kMinMutableFormulaLength;

  /// Which of the two options is selected.
  ///
  /// Inferred from [LeylineConfig.formulaLength] rather than read off the
  /// config's own flag, on purpose. Two reasons, and both matter:
  ///
  ///   * **The flag is not the UI's to read.** `IncantationLexicon` is the one
  ///     production reader of it, and a posture test enforces that — every
  ///     other consumer asks the lexicon a question instead, which is what
  ///     keeps "what does a leyline change" answerable from one file.
  ///   * **Asking the lexicon here would be too expensive.** `IncantationLexicon
  ///     .of` derives the whole codebook eagerly (~1040 SHA-256s), and this is
  ///     read from `build`.
  ///
  /// The inference is exact, not a heuristic: `LeylineConfig._checkCanonical`
  /// requires an ordinary config to have exactly [LeylineConfig
  /// .kOrdinaryFormulaLength] and a mutable one to be in 4..6, and there is no
  /// public path to a non-canonical config. `mutable_leyline_surfaces_test`'s
  /// "the selected-option inference agrees with the lexicon" pins that over
  /// every canonical config, so if the ratified range ever overlaps 3 the test
  /// fails rather than the picker quietly showing the wrong option selected.
  bool get _isMutable =>
      value.formulaLength != LeylineConfig.kOrdinaryFormulaLength;

  void _select({required bool mutable}) {
    if (mutable == _isMutable) return;
    onChanged(
      mutable
          ? LeylineConfig.mutable(
              communitySeed: communitySeed,
              formulaLength: kInitialMutableFormulaLength,
            )
          : LeylineConfig.ordinary(communitySeed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('LEYLINE', style: manuscriptCaptionStyle()),
        const SizedBox(height: 2),
        Text(
          'The tradition this match is fought under: ${value.displayName}',
          style: manuscriptCaptionStyle(
            color: kInkMutedColor.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 12),
        // IntrinsicHeight so the two cards match. Their captions are different
        // lengths and wrap to different line counts on a narrow phone — at
        // ~390px the Mutable card runs six lines to Ordinary's four — and two
        // ragged boxes stop reading as one either/or choice. Two children, so
        // the extra layout pass is free.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _LeylineOption(
                  key: const Key('leyline-ordinary'),
                  label: 'ORDINARY',
                  caption: 'Three elements to a formula. The standard grammar.',
                  selected: !_isMutable,
                  onTap: () => _select(mutable: false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _LeylineOption(
                  key: const Key('leyline-mutable'),
                  label: 'MUTABLE',
                  caption:
                      'A rekeyed grammar. Longer formulas, and some of them '
                      'mean nothing at all.',
                  selected: _isMutable,
                  onTap: () => _select(mutable: true),
                ),
              ),
            ],
          ),
        ),
        if (_isMutable) ...[
          const SizedBox(height: 24),
          IntStepperRow(
            key: const Key('leyline-formula-length'),
            label: 'FORMULA LENGTH',
            // The one number a player MUST see. It decides how a trajectory
            // is cut, and therefore how many formulas a spell has at all — a
            // spell with fewer than this many elements works no incantation
            // effect. It is NOT inert, though: the 2026-09-04 partial-formula
            // correction gives the unfinished group its first element's
            // affinity, so such a spell can still be eligible for wild magic,
            // and a caption promising "does nothing" would be a lie the player
            // only finds out about mid-duel.
            caption: 'Elements per formula. A spell with fewer elements than '
                'this works no effect — only the affinity it began with.',
            value: value.formulaLength,
            min: LeylineConfig.kMinMutableFormulaLength,
            max: LeylineConfig.kMaxMutableFormulaLength,
            step: 1,
            onChanged: (v) => onChanged(
              LeylineConfig.mutable(
                communitySeed: communitySeed,
                formulaLength: v,
                noiseDensityPermille: value.noiseDensityPermille,
              ),
            ),
          ),
          const SizedBox(height: 28),
          IntStepperRow(
            key: const Key('leyline-noise-density'),
            label: 'NOISE',
            // Shown in the canonical unit the config stores and the hash
            // hashes (parts per thousand), not a percentage recomputed for
            // display — a second representation of a consensus field is how
            // two devices end up disagreeing about what they agreed on.
            caption: 'Formulas per thousand that this leyline leaves inert. '
                '500 is half of them.',
            value: value.noiseDensityPermille,
            min: 0,
            max: _kMaxNoisePermille,
            step: _kNoisePermilleStep,
            // Three digits. The row's default width fits two and wraps a
            // third onto its own line ("500" as "50" over "0"), which is what
            // the on-screen pass caught.
            valueWidth: 84,
            onChanged: (v) => onChanged(
              LeylineConfig.mutable(
                communitySeed: communitySeed,
                formulaLength: value.formulaLength,
                noiseDensityPermille: v,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The stepper's ceiling, well inside `LeylineConfig`'s 0..999 canonical
/// bound. 1000‰ would be a leyline in which nothing means anything; the
/// config layer refuses it outright, and there is no reason to walk a player
/// up to the edge of that.
const int _kMaxNoisePermille = 900;

/// Coarse on purpose. This is a playtest dial, not a tuning knob, and 1‰
/// steps would make reaching 500 a chore.
const int _kNoisePermilleStep = 50;

/// One of the two leyline choices — a bordered, tappable card.
class _LeylineOption extends StatelessWidget {
  const _LeylineOption({
    super.key,
    required this.label,
    required this.caption,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String caption;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? kIlluminationGold : kInkColor.withValues(alpha: 0.25),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: 'serif',
                fontSize: 14,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
                color: selected ? kIlluminationGold : kInkColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              caption,
              style: manuscriptCaptionStyle(
                color: kInkMutedColor.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
