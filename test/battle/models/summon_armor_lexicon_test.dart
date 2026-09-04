// SPDX-License-Identifier: GPL-3.0-or-later
//
// summon_armor_lexicon_test.dart — the SEMANTICS of Mutable Summon and Armor
// (audit R-8, Slice F).
//
// Where `leyline_pattern_codebook_test.dart` pins the dictionary BYTES against
// an independent generator, this pins what the two lexicons DO with them: that
// ordinary play is untouched, that the recognisers (sliding four-element
// window, overlapping, at-most-once) survive the rekeying, and — the review
// gate's real content — that a leyline moves the ability set and the keyword
// set and moves nothing else.
//
// The vectors used as fixtures come from the codebook test, which got them from
// `scripts/gen_leyline_pattern_vectors.py`. Under `rivendell 4`:
//
//   summon  EWWE -> stealthy, WEWF -> flying; every ORDINARY pattern is inert
//   armor   EFWA -> muddy,    AEEF -> cleave; every ORDINARY pattern is inert

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:rune_duel/battle/engine/proof_outputs.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/creature_spec.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/summon_lexicon.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

LeylineConfig _rivendell([int length = 4]) => LeylineConfig.mutable(
      communitySeed: 'rivendell',
      formulaLength: length,
    );

final LeylineConfig _glassmountain =
    LeylineConfig.mutable(communitySeed: 'glassmountain', formulaLength: 4);

List<BorderZone> _seq(String initials) => [
      for (final c in initials.split(''))
        switch (c) {
          'F' => BorderZone.fire,
          'A' => BorderZone.air,
          'W' => BorderZone.water,
          'E' => BorderZone.earth,
          _ => throw ArgumentError('bad initial "$c"'),
        },
    ];

const Map<String, int> _codeToIndex = {'n': 0, 'F': 1, 'A': 2, 'W': 3, 'E': 4};

/// The armor test's fixture, transcribed: outputs whose active dominance
/// trajectory is [codes].
VerifiedSpellOutputs _outputs(String codes) {
  final tierMax = codes.length <= 12 ? 12 : (codes.length <= 24 ? 24 : 48);
  final trajectory = List<int>.filled(tierMax, 0);
  for (var i = 0; i < codes.length; i++) {
    trajectory[i] = _codeToIndex[codes[i]]!;
  }
  return VerifiedSpellOutputs(
    proofBytes: Uint8List(0),
    t: codes.length,
    ownerPubkeyHex: '0x${'00' * 32}',
    rulesetVersion: 3,
    commitmentHex: '0x00',
    tierMax: tierMax,
    borderActivations: const [0, 0, 0, 0],
    dominanceTrajectory: trajectory,
    supremeDominanceFlags: List<int>.filled(tierMax, 0),
    segmentCount: 0,
    dotCount: 0,
  );
}

void main() {
  // ── SUMMON ─────────────────────────────────────────────────────────────────

  group('summon — ordinary invariance', () {
    test('the ordinary lexicon is the fixed table, and derives nothing', () {
      const lexicon = SummonLexicon.ordinary;
      expect(lexicon.isMutable, isFalse);
      expect(lexicon.abilitiesOf(_seq('AAAA')), {SummonAbility.flying});
      expect(lexicon.abilitiesOf(_seq('FFFF')), {SummonAbility.cleave});
      expect(lexicon.abilitiesOf(_seq('EEEE')), {SummonAbility.big});
      expect(lexicon.abilitiesOf(_seq('WWWW')), {SummonAbility.morphic});
      expect(lexicon.abilitiesOf(_seq('FAFA')), {SummonAbility.charger});
      expect(lexicon.abilitiesOf(_seq('AWAW')), {SummonAbility.stealthy});
      expect(lexicon.abilitiesOf(_seq('WEWE')), {SummonAbility.muddy});
      expect(lexicon.abilitiesOf(_seq('EFEF')), {SummonAbility.moltenCarapace});
    });

    test('an ordinary SEEDED leyline is still the fixed table', () {
      // No ordinary semantic reroll: the seed reaches nothing here.
      final seeded = SummonLexicon.of(LeylineConfig.ordinary('rivendell'));
      expect(seeded.isMutable, isFalse);
      for (final pattern in kSummonAbilityPattern.entries) {
        expect(seeded.abilitiesOf(_seq(pattern.value)), {pattern.key});
      }
    });

    test('CreatureSpec and the ordinary lexicon cannot drift', () {
      // One implementation, reached two ways.
      for (final codes in const ['AAAAFFFF', 'WEWEFAFA', 'EEEE', 'FWAE']) {
        expect(
          CreatureSpec.fromElements(_seq(codes))?.abilities ?? <SummonAbility>{},
          SummonLexicon.ordinary.abilitiesOf(_seq(codes)),
        );
      }
    });
  });

  group('summon — mutable rekeying', () {
    final lexicon = SummonLexicon.of(_rivendell());

    test('a keyed mutable pattern grants its ability', () {
      expect(lexicon.isMutable, isTrue);
      expect(lexicon.abilitiesOf(_seq('EWWE')), {SummonAbility.stealthy});
      expect(lexicon.abilitiesOf(_seq('WEWF')), {SummonAbility.flying});
    });

    test('a formerly meaningful ORDINARY pattern is inert', () {
      // The point of the whole feature: memorised recipes stop working.
      for (final entry in kSummonAbilityPattern.entries) {
        expect(lexicon.abilitiesOf(_seq(entry.value)), isEmpty,
            reason: '${entry.value} still grants ${entry.key.name} under '
                'rivendell 4 — the ordinary table leaked through');
      }
    });

    test('a formerly inert pattern is meaningful', () {
      // EWWE names nothing ordinarily and names Stealthy here.
      expect(SummonLexicon.ordinary.abilitiesOf(_seq('EWWE')), isEmpty);
      expect(lexicon.abilitiesOf(_seq('EWWE')), isNotEmpty);
    });

    test('a different tradition is a different dictionary', () {
      final other = SummonLexicon.of(_glassmountain);
      expect(other.abilitiesOf(_seq('EWWE')), isEmpty);
      expect(other.abilitiesOf(_seq('AFFW')), {SummonAbility.big});
    });

    test('the grammar length does not move the ability set', () {
      // rivendell 4/5/6 are three incantation grammars and one creature
      // tradition (R-8's config-field projection, at the seam a player sees).
      for (final length in [4, 5, 6]) {
        expect(
          SummonLexicon.of(_rivendell(length)).abilitiesOf(_seq('EWWE')),
          {SummonAbility.stealthy},
        );
      }
    });
  });

  group('summon — the recogniser survives rekeying', () {
    final lexicon = SummonLexicon.of(_rivendell());

    test('windows may overlap', () {
      // EWWEWF: [0..3] = EWWE (stealthy), [2..5] = WEWF (flying). They share
      // two elements, and both must be granted.
      expect(lexicon.abilitiesOf(_seq('EWWEWF')),
          {SummonAbility.stealthy, SummonAbility.flying});
      // The ordinary counterpart, for the same property under the fixed table:
      // AAAAW... AAAA at [0..3] and AWAW at [3..6].
      expect(SummonLexicon.ordinary.abilitiesOf(_seq('AAAAWAW')),
          {SummonAbility.flying, SummonAbility.stealthy});
    });

    test('a repeated pattern grants its ability once', () {
      final once = lexicon.abilitiesOf(_seq('EWWE'));
      expect(lexicon.abilitiesOf(_seq('EWWEFFEWWE')), once);
      expect(lexicon.abilitiesOf(_seq('EWWEWWE')), once);
      expect(once, hasLength(1));
    });

    test('a sequence shorter than the window spells nothing', () {
      expect(lexicon.abilitiesOf(_seq('EWW')), isEmpty);
      expect(lexicon.abilitiesOf(const []), isEmpty);
    });

    test('the window is four elements under every grammar length', () {
      for (final length in [4, 5, 6]) {
        expect(SummonLexicon.of(_rivendell(length)).patternLength, 4);
      }
      expect(SummonLexicon.ordinary.patternLength, 4);
    });
  });

  group('summon — intrinsic identity is leyline-independent', () {
    test('affinity and stats are identical under every leyline', () {
      const sequences = ['EWWEWF', 'AAAAFFFFWWWWEEEE', 'FWAEFWAE', 'EEEEEE'];
      for (final codes in sequences) {
        final ordinary = CreatureSpec.fromElements(_seq(codes))!;
        for (final config in [_rivendell(), _rivendell(6), _glassmountain]) {
          final mutable = SummonLexicon.of(config).specOf(_seq(codes))!;
          expect(mutable.affinity, ordinary.affinity, reason: codes);
          expect(mutable.stats.maxHp, ordinary.stats.maxHp, reason: codes);
          expect(mutable.stats.damage, ordinary.stats.damage, reason: codes);
          expect(mutable.stats.moveSpeed, ordinary.stats.moveSpeed,
              reason: codes);
          expect(mutable.stats.attackRange, ordinary.stats.attackRange,
              reason: codes);
        }
      }
    });

    test('only the ability set differs', () {
      final ordinary = CreatureSpec.fromElements(_seq('AAAAEWWE'))!;
      final mutable = SummonLexicon.of(_rivendell()).specOf(_seq('AAAAEWWE'))!;
      expect(ordinary.abilities, {SummonAbility.flying});
      expect(mutable.abilities, {SummonAbility.stealthy});
      expect(mutable.stats, ordinary.stats);
      expect(mutable.affinity, ordinary.affinity);
    });

    test('a void sequence is void under every leyline', () {
      expect(SummonLexicon.of(_rivendell()).specOf(const []), isNull);
      expect(CreatureSpec.fromElements(const []), isNull);
    });
  });

  // ── ARMOR ──────────────────────────────────────────────────────────────────

  group('armor — ordinary invariance', () {
    test('the ordinary lexicon is the fixed table, and derives nothing', () {
      const lexicon = ArmorLexicon.ordinary;
      expect(lexicon.isMutable, isFalse);
      for (final entry in armorKeywordPatterns.entries) {
        expect(lexicon.keywordsOf(entry.value), {entry.key});
      }
    });

    test('an ordinary SEEDED leyline is still the fixed table', () {
      final seeded = ArmorLexicon.of(LeylineConfig.ordinary('rivendell'));
      expect(seeded.isMutable, isFalse);
      for (final entry in armorKeywordPatterns.entries) {
        expect(seeded.keywordsOf(entry.value), {entry.key});
      }
    });

    test('CertifiedArmor defaults to the ordinary reading', () {
      // Every existing caller that passes no lexicon must read exactly as it
      // always has.
      expect(CertifiedArmor.fromOutputs(_outputs('AAAA')).keywords,
          {ArmorKeyword.flying});
      expect(CertifiedArmor.fromOutputs(_outputs('WWWW')).keywords, isEmpty,
          reason: 'Morphic is designed but unimplemented for armor');
    });
  });

  group('armor — mutable rekeying', () {
    final lexicon = ArmorLexicon.of(_rivendell());

    test('a keyed mutable run grants its keyword', () {
      expect(lexicon.isMutable, isTrue);
      expect(lexicon.keywordsOf(_seq('EFWA')), {ArmorKeyword.muddy});
      expect(lexicon.keywordsOf(_seq('AEEF')), {ArmorKeyword.cleave});
    });

    test('a formerly meaningful ORDINARY run is inert', () {
      for (final entry in armorKeywordPatterns.entries) {
        expect(lexicon.keywordsOf(entry.value), isEmpty,
            reason: '${entry.key.name}\'s ordinary run still keys under '
                'rivendell 4');
      }
    });

    test('a formerly inert run is meaningful', () {
      expect(ArmorLexicon.ordinary.keywordsOf(_seq('EFWA')), isEmpty);
      expect(lexicon.keywordsOf(_seq('EFWA')), isNotEmpty);
    });

    test('the armor and summon dictionaries are independent', () {
      // One seed, two domains. EWWE is a summon word and not an armor word;
      // EFWA is an armor word and not a summon word.
      expect(lexicon.keywordsOf(_seq('EWWE')), isEmpty);
      expect(SummonLexicon.of(_rivendell()).abilitiesOf(_seq('EFWA')), isEmpty);
    });

    test('runs may overlap, and a repeat grants once', () {
      // EFWAEEF: [0..3] = EFWA (muddy), [3..6] = AEEF (cleave) — one shared
      // element.
      expect(lexicon.keywordsOf(_seq('EFWAEEF')),
          {ArmorKeyword.muddy, ArmorKeyword.cleave});
      expect(lexicon.keywordsOf(_seq('EFWAFFEFWA')), {ArmorKeyword.muddy});
      // And ordinarily, for the same property under the fixed table.
      expect(ArmorLexicon.ordinary.keywordsOf(_seq('AAAAWAW')),
          {ArmorKeyword.flying, ArmorKeyword.stealthy});
    });

    test('the window is four elements under every grammar length', () {
      for (final length in [4, 5, 6]) {
        expect(ArmorLexicon.of(_rivendell(length)).patternLength, 4);
        expect(ArmorLexicon.of(_rivendell(length)).keywordsOf(_seq('EFWA')),
            {ArmorKeyword.muddy});
      }
    });
  });

  group('armor — everything intrinsic is leyline-independent', () {
    // A trajectory long enough to reach real ladder rungs, and containing both
    // an ordinary run (AAAA -> Flying) and a mutable one (EFWA -> Muddy).
    const codes = 'AAAAFFFFFFFFFFWWWWEEEEEEEEEEEEEEEFWA';

    test('T, slot cost, element counts and every stat bonus are identical', () {
      final ordinary = CertifiedArmor.fromOutputs(_outputs(codes));
      for (final config in [_rivendell(), _rivendell(6), _glassmountain]) {
        final mutable = CertifiedArmor.fromOutputs(
          _outputs(codes),
          lexicon: ArmorLexicon.of(config),
        );
        expect(mutable.t, ordinary.t);
        expect(mutable.slotCost, ordinary.slotCost);
        expect(mutable.fireCount, ordinary.fireCount);
        expect(mutable.airCount, ordinary.airCount);
        expect(mutable.waterCount, ordinary.waterCount);
        expect(mutable.earthCount, ordinary.earthCount);
        expect(mutable.meleeBonus, ordinary.meleeBonus);
        expect(mutable.moveSpeedBonus, ordinary.moveSpeedBonus);
        expect(mutable.spellRangeBonus, ordinary.spellRangeBonus);
        expect(mutable.armorHpBonus, ordinary.armorHpBonus);
        expect(mutable.elementSequence, ordinary.elementSequence);
      }
    });

    test('the stat bonuses are real, so the check above is not vacuous', () {
      final armor = CertifiedArmor.fromOutputs(_outputs(codes));
      expect(armor.meleeBonus, greaterThan(0));
      expect(armor.moveSpeedBonus, greaterThan(0));
      expect(armor.armorHpBonus, greaterThan(0));
    });

    test('ONLY the keyword set changes', () {
      final ordinary = CertifiedArmor.fromOutputs(_outputs(codes));
      final mutable = CertifiedArmor.fromOutputs(
        _outputs(codes),
        lexicon: ArmorLexicon.of(_rivendell()),
      );
      expect(ordinary.keywords, contains(ArmorKeyword.flying));
      expect(mutable.keywords, {ArmorKeyword.muddy});
      expect(mutable.hasKeyword(ArmorKeyword.flying), isFalse);
    });

    test('an armor with no keyed keyword keeps all of its bonuses', () {
      // The UX claim, made mechanically true: "stat-only armor remains useful".
      final mutable = CertifiedArmor.fromOutputs(
        _outputs('FFFFFFFFFFEEEEEEEEEEEE'),
        lexicon: ArmorLexicon.of(_rivendell()),
      );
      expect(mutable.keywords, isEmpty);
      expect(mutable.meleeBonus, greaterThan(0));
      expect(mutable.armorHpBonus, greaterThan(0));
      expect(mutable.slotCost, greaterThan(0));
    });
  });

  // ── Cross-peer agreement ───────────────────────────────────────────────────

  group('two devices, one reading', () {
    test('equal configs build equal-answering lexicons', () {
      // Two lexicons built independently — as the two devices do — must answer
      // identically. Passing one down is an optimisation, never a requirement.
      final mine = SummonLexicon.of(_rivendell());
      final theirs = SummonLexicon.of(
        LeylineConfig.mutable(communitySeed: 'Rivendell!', formulaLength: 4),
      );
      for (var i = 0; i < 256; i++) {
        final pattern = [
          for (final e in [i >> 6 & 3, i >> 4 & 3, i >> 2 & 3, i & 3])
            const [
              BorderZone.fire,
              BorderZone.air,
              BorderZone.water,
              BorderZone.earth,
            ][e],
        ];
        expect(theirs.abilitiesOf(pattern), mine.abilitiesOf(pattern));
      }

      final myArmor = ArmorLexicon.of(_rivendell());
      final theirArmor = ArmorLexicon.of(
        LeylineConfig.mutable(communitySeed: '  RIVENDELL  ', formulaLength: 4),
      );
      expect(theirArmor.keywordsOf(_seq('EFWAEEF')),
          myArmor.keywordsOf(_seq('EFWAEEF')));
    });

    test('one proof plus one config is one armor', () {
      // The local (`parseOwn`) and peer (`verifyAndParse`) paths differ only in
      // whether the bytes were verified first; both then run this derivation.
      final outputs = _outputs('AAAAEFWAEEEE');
      final local = CertifiedArmor.fromOutputs(
        outputs,
        lexicon: ArmorLexicon.of(_rivendell()),
      );
      final peer = CertifiedArmor.fromOutputs(
        outputs,
        lexicon: ArmorLexicon.of(_rivendell()),
      );
      expect(peer.keywords, local.keywords);
      expect(peer.t, local.t);
      expect(peer.slotCost, local.slotCost);
    });
  });

  // ── Display ────────────────────────────────────────────────────────────────

  group('summon summary labels', () {
    test('the ordinary label is unchanged', () {
      final label = summonSummaryFromFormula(
        const ['air', 'air', 'air', 'air'],
      );
      expect(label, contains('Flying'));
      expect(label, isNot(contains('under')));
    });

    test('a mutable label names the abilities the duel will grant', () {
      final label = summonSummaryFromFormula(
        const ['earth', 'water', 'water', 'earth'],
        lexicon: SummonLexicon.of(_rivendell()),
      );
      expect(label, contains('Stealthy'));
    });

    test('no keyed ability is stated, not implied by silence', () {
      final label = summonSummaryFromFormula(
        const ['air', 'air', 'air', 'air'],
        lexicon: SummonLexicon.of(_rivendell()),
      );
      expect(label, isNot(contains('Flying')));
      expect(label, contains('no keyed ability'));
      expect(label, contains('rivendell 4'));
      // …and the stats are still there.
      expect(label, contains('Move'));
    });
  });
}
