// SPDX-License-Identifier: GPL-3.0-or-later
//
// enhancement_zone.dart — shared display metadata for the four elemental
// cast-time enhancements (Fire=Potency, Air=Velocity, Water=Efficiency,
// Earth=Mystery). Eligibility itself is SpellAsset.supremeTags (see
// supreme_tags.dart) — a zone is choosable at cast time iff it's in that
// spell's own supremeTags. This file only maps a zone tag to its
// label/color/description for the battle_screen.dart cast-time picker.

import 'package:flutter/material.dart' show Color;

const List<String> kEnhancementZones = ['fire', 'air', 'water', 'earth'];

const Map<String, String> kEnhancementLabel = {
  'fire': 'Potency',
  'air': 'Velocity',
  'water': 'Efficiency',
  'earth': 'Mystery',
};

const Map<String, Color> kEnhancementColor = {
  'fire': Color(0xFFB84040),
  'air': Color(0xFF5588BB),
  'water': Color(0xFF3399AA),
  'earth': Color(0xFF7A6040),
};

const Map<String, String> kEnhancementDescription = {
  'fire': 'Increase the power of your spell.',
  'air': 'Increase spell range by 2.',
  'water': 'Reduce mana cost by a third.',
  'earth': 'Delay casting 0 to 3 turns; the delay and target are secret.',
};
