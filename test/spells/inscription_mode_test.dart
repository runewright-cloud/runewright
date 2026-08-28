// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/inscription_mode.dart';

import 'armor_fixture.dart';

void main() {
  test('the three modes map onto exactly the two persisted flags', () {
    expect(InscriptionMode.values, [
      InscriptionMode.incantation,
      InscriptionMode.summon,
      InscriptionMode.armor,
    ]);

    expect(InscriptionMode.incantation.isSummon, isFalse);
    expect(InscriptionMode.incantation.isArmor, isFalse);

    expect(InscriptionMode.summon.isSummon, isTrue);
    expect(InscriptionMode.summon.isArmor, isFalse);

    expect(InscriptionMode.armor.isSummon, isFalse);
    expect(InscriptionMode.armor.isArmor, isTrue);
  });

  test('no mode can produce the Summon+Armor combination SpellAsset rejects', () {
    for (final mode in InscriptionMode.values) {
      expect(mode.isSummon && mode.isArmor, isFalse, reason: mode.name);
    }
  });

  test('InscriptionMode.of recovers the mode a spell was inscribed in', () {
    expect(InscriptionMode.of(plainSpell()), InscriptionMode.incantation);
    expect(InscriptionMode.of(plainSpell(isSummon: true)), InscriptionMode.summon);
    expect(
      InscriptionMode.of(armorAsset(elements: const [])),
      InscriptionMode.armor,
    );
  });

  test('labels are the three the mode bar shows', () {
    expect(InscriptionMode.values.map((m) => m.label).toList(),
        ['Incantation', 'Summon', 'Armor']);
  });
}
