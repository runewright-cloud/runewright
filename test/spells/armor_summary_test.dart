// SPDX-License-Identifier: GPL-3.0-or-later
//
// The local proof -> CertifiedArmor path: what the library and chapter editor
// display an armor's properties FROM. The point of every test here is that
// authored metadata cannot reach the answer.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/armor_summary.dart';

import 'armor_fixture.dart';

void main() {
  test('reads the armor out of the spell\'s own proof bytes', () {
    // 4 fire (+1 melee, Cleave), 2 earth (+2 armor HP), T=6 -> 2 slots.
    final armor = localCertifiedArmor(armorAsset(elements: [
      ...runOf(BorderZone.fire, 4),
      ...runOf(BorderZone.earth, 2),
    ]))!;

    expect(armor.t, 6);
    expect(armor.slotCost, 2);
    expect(armor.fireCount, 4);
    expect(armor.earthCount, 2);
    expect(armor.meleeBonus, 1);
    expect(armor.armorHpBonus, 2);
    expect(armor.keywords, {ArmorKeyword.cleave});
  });

  test('a contradictory authored formula/manaCost/supremeTags changes nothing',
      () {
    final elements = [...runOf(BorderZone.air, 4), BorderZone.water];
    final honest = localCertifiedArmor(armorAsset(
      elements: elements,
      formula: const [],
      supremeTags: const [],
      manaCost: 0,
    ))!;
    final lying = localCertifiedArmor(armorAsset(
      elements: elements,
      // Claims to be all-earth, 12 elements long, and expensive.
      formula: List.filled(12, 'earth'),
      supremeTags: const ['earth', 'fire', 'water'],
      manaCost: 4242,
    ))!;

    expect(lying.toString(), honest.toString());
    expect(lying.airCount, 4);
    expect(lying.earthCount, 0);
    expect(lying.armorHpBonus, 0);
    expect(lying.moveSpeedBonus, 1);
    expect(lying.keywords, {ArmorKeyword.flying});
  });

  test('the parsing tier is re-derived from T, not taken from the asset', () {
    // A T=20 armor proves at tier 24. Its trajectory arrays sit at offsets
    // only tier 24 produces; reading it as tier 12 would yield garbage.
    final armor = localCertifiedArmor(armorAsset(
      elements: runOf(BorderZone.water, 20),
      t: 20,
    ))!;
    expect(armor.t, 20);
    expect(armor.waterCount, 20);
    expect(armor.spellRangeBonus, 3);
    expect(armor.slotCost, 5);
  });

  test('missing proof bytes yield null, never synthesised semantics', () {
    expect(
      localCertifiedArmor(armorAsset(
        elements: const [],
        proofBytes: Uint8List(0),
        formula: List.filled(12, 'earth'),
      )),
      isNull,
    );
  });

  test('a truncated or corrupt proof yields null', () {
    expect(
      localCertifiedArmor(
          armorAsset(elements: const [], proofBytes: Uint8List.fromList([1, 2, 3]))),
      isNull,
    );
    final short = Uint8List(64);
    short[3] = 34; // claims 34 fields, carries none
    expect(localCertifiedArmor(armorAsset(elements: const [], proofBytes: short)),
        isNull);
  });

  test('every granted keyword has a display name, and Morphic has none', () {
    for (final k in ArmorKeyword.values) {
      expect(kArmorKeywordLabel[k], isNotNull, reason: k.name);
    }
    expect(kArmorKeywordLabel.length, ArmorKeyword.values.length);
    expect(kArmorKeywordLabel.values, isNot(contains('Morphic')));
  });
}
