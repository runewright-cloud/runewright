// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_summary_view.dart — the compact read-out of what an Aetherial Armor
// does, shown in the library and in the chapter editor.
//
// Every number here comes from [localCertifiedArmor], i.e. from the spell's
// own proof bytes (armor_summary.dart). Nothing on this widget reads
// SpellAsset.formula, manaCost, supremeTags or any cached stat: those are
// authored fields no proof binds, and showing them would mean advertising an
// armor the duel would not honour. When the proof cannot be read the widget
// says so and shows nothing else -- there is deliberately no fallback.
//
// ## Leyline (Slice F)
//
// The KEYWORD line is read under the leyline currently in force
// ([activeLeylineConfig] — the same channel the spell card uses: this device's
// own tradition in the library, the match's for the duration of a duel), so it
// can never name a keyword the duel would not grant. T, the slot cost and every
// element bonus are intrinsic and identical under every leyline, so they are
// not qualified by anything.

import 'package:flutter/material.dart';

// `ArmorLexicon` comes through certified_armor.dart's re-export — the two are
// one boundary and importing them separately is redundant.
import '../../battle/models/certified_armor.dart';
import '../../spells/armor_summary.dart';
import '../../spells/spell_asset.dart';
import '../../spells/wild_magic_preview.dart' show activeLeylineConfig;
import '../manuscript_theme.dart';

/// Proof-derived summary of [spell]. Renders a short refusal if its proof
/// bytes are missing or unparseable.
///
/// [dense] drops the element/bonus grid and keeps only the headline line --
/// what the chapter editor's equipped-armor row shows.
class ArmorSummaryView extends StatelessWidget {
  const ArmorSummaryView({super.key, required this.spell, this.dense = false});

  final SpellAsset spell;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final lexicon = ArmorLexicon.of(activeLeylineConfig);
    final armor = localCertifiedArmor(spell, lexicon: lexicon);
    if (armor == null) {
      return Text(
        "This armor's proof could not be read, so its properties are unknown.",
        style: manuscriptCaptionStyle(color: kRubricRed),
      );
    }
    return ArmorSummaryBody(armor: armor, dense: dense, lexicon: lexicon);
  }
}

/// The rendering half, over an already-derived [CertifiedArmor]. Split out so
/// a caller that has one in hand does not re-parse the proof to draw it.
class ArmorSummaryBody extends StatelessWidget {
  const ArmorSummaryBody({
    super.key,
    required this.armor,
    this.dense = false,
    this.lexicon = ArmorLexicon.ordinary,
  });

  final CertifiedArmor armor;
  final bool dense;

  /// The tradition [armor]'s keywords were read under. Presentation only — it
  /// names the reading, it does not perform it: [armor] already carries the
  /// keyword set its own derivation produced, and a caller that passed a
  /// different lexicon here than it derived with would only mislabel, never
  /// change, what is shown.
  final ArmorLexicon lexicon;

  @override
  Widget build(BuildContext context) {
    final keywords = armor.keywords.map((k) => kArmorKeywordLabel[k]!).toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'T ${armor.t}  ·  ${armor.slotCost} artifact '
          'slot${armor.slotCost == 1 ? '' : 's'}',
          style: manuscriptCaptionStyle(color: kInkColor),
        ),
        if (!dense) ...[
          const SizedBox(height: 4),
          // Elements are always shown, bonuses only where earned: a count with
          // no bonus yet is the useful half of the signal (it tells the player
          // how far off the next rung they are), while a column of "+0"s is
          // just noise.
          _ElementRow(label: 'Fire', count: armor.fireCount, bonus: armor.meleeBonus, bonusLabel: 'melee'),
          _ElementRow(label: 'Air', count: armor.airCount, bonus: armor.moveSpeedBonus, bonusLabel: 'move'),
          _ElementRow(label: 'Water', count: armor.waterCount, bonus: armor.spellRangeBonus, bonusLabel: 'range'),
          _ElementRow(label: 'Earth', count: armor.earthCount, bonus: armor.armorHpBonus, bonusLabel: 'armor HP'),
        ],
        if (keywords.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            lexicon.isMutable
                ? '${keywords.join('  ·  ')}  '
                    '(under ${lexicon.leyline.displayName})'
                : keywords.join('  ·  '),
            style: manuscriptCaptionStyle(color: kIlluminationGold),
          ),
        ] else if (lexicon.isMutable && !dense) ...[
          // Silence would read as "this armor does nothing special", which is
          // both wrong and demoralising: every bonus above still applies. Say
          // which half is empty, and under which tradition.
          const SizedBox(height: 4),
          Text(
            'No keyed Armor ability under ${lexicon.leyline.displayName}. '
            'Its bonuses above are unchanged.',
            style: manuscriptCaptionStyle(color: kInkMutedColor),
          ),
        ],
      ],
    );
  }
}

class _ElementRow extends StatelessWidget {
  const _ElementRow({
    required this.label,
    required this.count,
    required this.bonus,
    required this.bonusLabel,
  });

  final String label;
  final int count;
  final int bonus;
  final String bonusLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text('$label $count', style: manuscriptCaptionStyle(color: kInkColor)),
          ),
          if (bonus > 0)
            Text('+$bonus $bonusLabel',
                style: manuscriptCaptionStyle(color: kIlluminationGold)),
        ],
      ),
    );
  }
}
