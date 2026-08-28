// SPDX-License-Identifier: GPL-3.0-or-later
//
// inscription_mode.dart — what a grid is being inscribed AS.
//
// The Rune Craft screen used to hold this as a single `bool _isSummonMode`,
// which stopped being expressible the moment Aetherial Armor became a third
// thing a grid could become. This enum is the screen's mode state and the one
// place that maps a mode onto the two persisted booleans, so
// "summon and armor at once" -- which [SpellAsset] rejects outright -- cannot
// be constructed by a UI that forgets to clear the other flag.

import 'spell_asset.dart';

enum InscriptionMode {
  /// The default: the trajectory resolves as a 16-cell incantation effect.
  incantation,

  /// design doc "Summons": the trajectory becomes a creature.
  summon,

  /// Aetherial Armor: the trajectory becomes worn equipment
  /// (lib/battle/models/certified_armor.dart).
  armor;

  bool get isSummon => this == InscriptionMode.summon;
  bool get isArmor => this == InscriptionMode.armor;

  /// The mode [spell] was inscribed in. A spell claiming both flags cannot
  /// exist ([SpellAsset]'s constructor rejects it, and its `fromJson`
  /// sanitises), so the order of these checks is not load-bearing.
  static InscriptionMode of(SpellAsset spell) {
    if (spell.isArmor) return InscriptionMode.armor;
    if (spell.isSummon) return InscriptionMode.summon;
    return InscriptionMode.incantation;
  }

  String get label => switch (this) {
        InscriptionMode.incantation => 'Incantation',
        InscriptionMode.summon => 'Summon',
        InscriptionMode.armor => 'Armor',
      };
}
