// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unit tests for the pure VerifiedSpellOutputs -> CertifiedArmor derivation.
// No proving, no FFI, no Flutter: fixtures are built directly.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/proof_outputs.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

// Element indices in dominance_trajectory: 0=neutral, 1=fire, 2=air,
// 3=water, 4=earth (CLAUDE.md: the stepper's order).
const Map<String, int> _codeToIndex = {
  'n': 0,
  'F': 1,
  'A': 2,
  'W': 3,
  'E': 4,
};

int _tierFor(int t) => t <= 12 ? 12 : (t <= 24 ? 24 : 48);

/// Build outputs whose active trajectory is [codes] (one char per generation,
/// 'n' = neutral). T defaults to the code length; pass [t] to declare a
/// different active generation count, e.g. to exercise slot cost independently
/// of the sequence, or to prove that generations at or beyond T are ignored.
VerifiedSpellOutputs _outputs(
  String codes, {
  int? t,
  List<int>? borderActivations,
  List<int>? supremeFlags,
  int segmentCount = 0,
  int dotCount = 0,
  String commitmentHex = '0x00',
}) {
  final activeT = t ?? codes.length;
  final tierMax = _tierFor(activeT > codes.length ? activeT : codes.length);
  final trajectory = List<int>.filled(tierMax, 0);
  for (var i = 0; i < codes.length; i++) {
    trajectory[i] = _codeToIndex[codes[i]]!;
  }
  return VerifiedSpellOutputs(
    proofBytes: Uint8List(0),
    t: activeT,
    ownerPubkeyHex: '0x${'00' * 32}',
    rulesetVersion: 3,
    commitmentHex: commitmentHex,
    tierMax: tierMax,
    borderActivations: borderActivations ?? const [0, 0, 0, 0],
    dominanceTrajectory: trajectory,
    supremeDominanceFlags:
        supremeFlags ?? List<int>.filled(tierMax, 0),
    segmentCount: segmentCount,
    dotCount: dotCount,
  );
}

/// An armor derived from [count] repetitions of one element code.
CertifiedArmor _armorOf(String code, int count) =>
    CertifiedArmor.fromOutputs(_outputs(code * count));

void main() {
  // ── Slot cost ───────────────────────────────────────────────────────────────

  group('slot cost — ceil(T / 4)', () {
    // Sequence content is irrelevant to slot cost; declare T directly.
    int slotsFor(int t) => CertifiedArmor.fromOutputs(_outputs('', t: t)).slotCost;

    test('every boundary from T=1 to T=48', () {
      for (var t = 1; t <= 48; t++) {
        expect(slotsFor(t), (t / 4).ceil(), reason: 'T=$t');
      }
    });

    test('the 4/5 boundary', () {
      expect(slotsFor(4), 1);
      expect(slotsFor(5), 2);
    });

    test('the 8/9 boundary', () {
      expect(slotsFor(8), 2);
      expect(slotsFor(9), 3);
    });

    test('the 44/45 boundary', () {
      expect(slotsFor(44), 11);
      expect(slotsFor(45), 12);
    });

    test('T=1 costs one slot; T=48 costs twelve — no diminishing returns', () {
      expect(slotsFor(1), 1);
      expect(slotsFor(48), 12);
    });
  });

  // ── Element counting ────────────────────────────────────────────────────────

  group('element counting', () {
    test('counts each element in the certified dominance sequence', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('FFAWWWE'));
      expect(armor.fireCount, 2);
      expect(armor.airCount, 1);
      expect(armor.waterCount, 3);
      expect(armor.earthCount, 1);
    });

    test('neutral generations do not count', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('FnFnnAnn'));
      expect(armor.fireCount, 2);
      expect(armor.airCount, 1);
      expect(armor.waterCount, 0);
      expect(armor.earthCount, 0);
      expect(armor.elementSequence,
          [BorderZone.fire, BorderZone.fire, BorderZone.air]);
      // Neutrals still occupy generations, so they still cost slots.
      expect(armor.slotCost, 2);
    });

    test('repeated elements count normally, unlike formula accumulation', () {
      // FormulaTracker would commit fire twice here (lead change + pulse);
      // armor counts all four generations it led.
      final armor = CertifiedArmor.fromOutputs(_outputs('FFFF'));
      expect(armor.fireCount, 4);
      expect(armor.elementSequence.length, 4);
    });

    test('only generations 0..T-1 are considered', () {
      // Ten fire generations present in the array, but only four are active.
      final armor = CertifiedArmor.fromOutputs(_outputs('FFFFFFFFFF', t: 4));
      expect(armor.fireCount, 4);
      expect(armor.slotCost, 1);
      expect(armor.keywords, {ArmorKeyword.cleave});
    });

    test('an all-neutral trajectory yields an empty sequence and no bonuses', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('nnnnnnnn'));
      expect(armor.elementSequence, isEmpty);
      expect(armor.fireCount, 0);
      expect(armor.meleeBonus, 0);
      expect(armor.moveSpeedBonus, 0);
      expect(armor.spellRangeBonus, 0);
      expect(armor.armorHpBonus, 0);
      expect(armor.keywords, isEmpty);
      expect(armor.slotCost, 2);
    });
  });

  // ── Fire / Air / Water ladder ───────────────────────────────────────────────

  group('Fire/Air/Water ladder — 4/10/18/28/40', () {
    const expected = {
      0: 0, 1: 0, 3: 0,
      4: 1, 5: 1, 9: 1,
      10: 2, 11: 2, 17: 2,
      18: 3, 19: 3, 27: 3,
      28: 4, 29: 4, 39: 4,
      40: 5, 41: 5, 48: 5,
    };

    test('fire drives the melee bonus at, below, and above every breakpoint',
        () {
      expected.forEach((count, bonus) {
        expect(_armorOf('F', count).meleeBonus, bonus, reason: 'fire=$count');
      });
    });

    test('air drives the move-speed bonus at, below, and above every breakpoint',
        () {
      expected.forEach((count, bonus) {
        expect(_armorOf('A', count).moveSpeedBonus, bonus, reason: 'air=$count');
      });
    });

    test(
        'water drives the spell-range bonus at, below, and above every breakpoint',
        () {
      expected.forEach((count, bonus) {
        expect(_armorOf('W', count).spellRangeBonus, bonus,
            reason: 'water=$count');
      });
    });

    test('each element only feeds its own stat', () {
      final armor = _armorOf('F', 10);
      expect(armor.meleeBonus, 2);
      expect(armor.moveSpeedBonus, 0);
      expect(armor.spellRangeBonus, 0);
      expect(armor.armorHpBonus, 0);
    });
  });

  // ── Earth ladder ────────────────────────────────────────────────────────────

  group('Earth ladder — 2/6/12/20/30/42, stored as armor HP', () {
    const expected = {
      0: 0, 1: 0,
      2: 2, 3: 2, 5: 2,
      6: 5, 7: 5, 11: 5,
      12: 8, 13: 8, 19: 8,
      20: 11, 21: 11, 29: 11,
      30: 14, 31: 14, 41: 14,
      42: 17, 43: 17, 48: 17,
    };

    test('at, below, and above every breakpoint', () {
      expected.forEach((count, bonus) {
        expect(_armorOf('E', count).armorHpBonus, bonus, reason: 'earth=$count');
      });
    });

    test('earth does not feed melee, move, or range', () {
      final armor = _armorOf('E', 42);
      expect(armor.armorHpBonus, 17);
      expect(armor.meleeBonus, 0);
      expect(armor.moveSpeedBonus, 0);
      expect(armor.spellRangeBonus, 0);
    });
  });

  // ── Keywords ────────────────────────────────────────────────────────────────

  group('armor keywords', () {
    test('each pattern grants exactly its own keyword', () {
      const cases = {
        'AAAA': ArmorKeyword.flying,
        'FFFF': ArmorKeyword.cleave,
        'FAFA': ArmorKeyword.charger,
        'WEWE': ArmorKeyword.muddy,
        'EFEF': ArmorKeyword.moltenCarapace,
        'AWAW': ArmorKeyword.stealthy,
        'EEEE': ArmorKeyword.anchored,
      };
      cases.forEach((codes, keyword) {
        final armor = CertifiedArmor.fromOutputs(_outputs(codes));
        expect(armor.keywords, {keyword}, reason: codes);
        expect(armor.hasKeyword(keyword), isTrue, reason: codes);
      });
    });

    test('WWWW grants no keyword — Morphic is not implemented', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('WWWW'));
      expect(armor.keywords, isEmpty);
      // The water count still ladders normally.
      expect(armor.spellRangeBonus, 1);
    });

    test('a pattern anywhere in the sequence counts, not just at the start', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('WWEFFFFW'));
      expect(armor.keywords, {ArmorKeyword.cleave});
    });

    test('a pattern broken by a neutral generation still matches — neutrals '
        'do not appear in the certified sequence', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('AAnAA'));
      expect(armor.elementSequence.length, 4);
      expect(armor.keywords, {ArmorKeyword.flying});
    });

    test('elements may be reused: overlapping matches of one keyword', () {
      // AWAWAW matches AWAW at offsets 0 and 2.
      final armor = CertifiedArmor.fromOutputs(_outputs('AWAWAW'));
      expect(armor.keywords, {ArmorKeyword.stealthy});
    });

    test('elements may be reused across two different keywords', () {
      // AAAAWAW: flying at 0..3 and stealthy at 3..6 share generation 3.
      final armor = CertifiedArmor.fromOutputs(_outputs('AAAAWAW'));
      expect(armor.keywords, {ArmorKeyword.flying, ArmorKeyword.stealthy});
    });

    test('a keyword is granted at most once however often its pattern repeats',
        () {
      final armor = CertifiedArmor.fromOutputs(_outputs('FFFFFFFFFFFF'));
      expect(armor.keywords, {ArmorKeyword.cleave});
      expect(armor.keywords.length, 1);
      expect(armor.fireCount, 12);
    });

    test('several keywords can be granted by one armor', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('EEEEnWEWEnFAFA'));
      expect(armor.keywords, {
        ArmorKeyword.anchored,
        ArmorKeyword.muddy,
        ArmorKeyword.charger,
      });
    });

    test('a run of three does not grant the keyword', () {
      expect(CertifiedArmor.fromOutputs(_outputs('AAA')).keywords, isEmpty);
      expect(CertifiedArmor.fromOutputs(_outputs('FAF')).keywords, isEmpty);
    });

    test('the keyword set is unmodifiable', () {
      final armor = CertifiedArmor.fromOutputs(_outputs('AAAA'));
      expect(() => armor.keywords.add(ArmorKeyword.cleave), throwsUnsupportedError);
      expect(() => armor.elementSequence.add(BorderZone.fire),
          throwsUnsupportedError);
    });
  });

  // ── Trust boundary ──────────────────────────────────────────────────────────

  group('derivation reads only the certified trajectory', () {
    // CertifiedArmor.fromOutputs takes VerifiedSpellOutputs and nothing else,
    // so authored SpellAsset fields (formula, manaCost, supremeTags, cached
    // armor stats) cannot participate by construction. What is still worth
    // pinning is that the *proof* fields an attacker could vary independently
    // of the trajectory change nothing either.
    test('border activations, segment/dot counts, commitment and owner do not '
        'affect the result', () {
      final plain = CertifiedArmor.fromOutputs(_outputs('FFFFAAEE'));
      final noisy = CertifiedArmor.fromOutputs(_outputs(
        'FFFFAAEE',
        borderActivations: const [999, 999, 999, 999],
        segmentCount: 47,
        dotCount: 13,
        commitmentHex: '0x${'ff' * 32}',
      ));
      expect(noisy.toString(), plain.toString());
      expect(noisy.elementSequence, plain.elementSequence);
      expect(noisy.keywords, plain.keywords);
      expect(noisy.slotCost, plain.slotCost);
    });

    test('supreme-dominance flags do not affect armor semantics', () {
      final tier = _tierFor(8);
      final plain = CertifiedArmor.fromOutputs(_outputs('FFFFAAEE'));
      final supreme = CertifiedArmor.fromOutputs(_outputs(
        'FFFFAAEE',
        supremeFlags: List<int>.filled(tier, 1),
      ));
      expect(supreme.toString(), plain.toString());
      expect(supreme.elementSequence, plain.elementSequence);
    });

    test('the same outputs always derive the same armor', () {
      final a = CertifiedArmor.fromOutputs(_outputs('EFEFWWWWAAAA'));
      final b = CertifiedArmor.fromOutputs(_outputs('EFEFWWWWAAAA'));
      expect(a.toString(), b.toString());
      expect(a.keywords, b.keywords);
    });
  });
}
