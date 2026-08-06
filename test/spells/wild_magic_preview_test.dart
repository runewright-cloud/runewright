// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_preview_test.dart — the card preview must agree with the engine.
//
// The preview reads a stored SpellAsset; the engine reads certified proof
// outputs. Those are two different sources for the same fact, and the whole
// value of printing wild magic on the card rests on them never disagreeing —
// a card that promises Burning Hot and a duel that delivers nothing is worse
// than a card that says nothing at all. The agreement test below is the one
// that matters; the rest guard the paths where a card must degrade quietly
// rather than throw out of `build`.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// A commitment whose hash under "universal" at T=7 contains a run of exactly
/// three '0's — one Row-1 trigger, bracketSteps 0 — and NO trigger at all
/// under "rivendell". Found by brute force over SHA-256; see the seed-rotation
/// test, which is the reason a single commitment covering both cases is worth
/// pinning.
const String _wildCommitment =
    '0xf9bce34e2b06068661f4537c136070f5b15e9a59ed3f302c3134f6084796d5af';

/// A commitment that fires nothing under "universal" at T=7 — the ~97% case.
const String _quietCommitment =
    '0x5a118d8d2ee3639ad4f4b729acd8eaeb2c08da393de9f3c265fadee25f28e93c';

SpellAsset _spell({
  required String commitmentHex,
  int t = 7,
  List<String> formula = const ['fire', 'fire', 'fire'],
}) => SpellAsset(
  id: 'preview-fixture',
  createdAt: DateTime.utc(2026, 8, 5),
  tier: 12,
  t: t,
  ownerPubkeyHex: '0x00',
  manaCost: 10,
  segmentCount: 1,
  dotCount: 0,
  initialGrid: List<int>.filled(469, 0)..[234] = 1,
  proofBytes: Uint8List.fromList(const [1, 2, 3]),
  name: 'Fixture',
  commitmentHex: commitmentHex,
  spellHashHex: '0xfeed',
  formula: formula,
);

/// Certified outputs whose trajectory alternates fire and water dominance for
/// [t] generations.
///
/// Alternating rather than constant on purpose: every generation is then a
/// lead change, so FormulaTracker commits one activation per generation
/// (lib/engine/formula.dart rule 1) and t=7 yields two complete formulas plus
/// a residual — the shape that actually exercises the preview's regrouping. A
/// constant trajectory commits only on lead change and pulse steps, and t=7
/// would produce no complete formula at all.
VerifiedSpellOutputs _alternatingOutputs({
  required String commitmentHex,
  required int t,
  int tierMax = 12,
}) => VerifiedSpellOutputs(
  proofBytes: Uint8List(0),
  t: t,
  ownerPubkeyHex: '0x00',
  rulesetVersion: 3,
  commitmentHex: commitmentHex,
  tierMax: tierMax,
  borderActivations: const [0, 0, 0, 0],
  // Element order is [0=neutral, 1=fire, 2=air, 3=water, 4=earth] — see
  // CLAUDE.md. Generations at or past t are masked to 0 by the circuit, so
  // only the first t count.
  dominanceTrajectory: [
    for (var g = 0; g < tierMax; g++)
      if (g >= t) 0 else if (g.isEven) 1 else 3,
  ],
  supremeDominanceFlags: List.filled(tierMax, 0),
  segmentCount: 1,
  dotCount: 0,
);

void main() {
  group('preview agrees with the engine', () {
    test('same triggers as WildMagic.triggersFor on equivalent inputs', () {
      const t = 7;
      final outputs = _alternatingOutputs(commitmentHex: _wildCommitment, t: t);
      final certified = TrajectoryParser.parse(outputs).formulas;

      // Sanity: the certified path really did produce complete formulas AND a
      // residual, so the regrouping below is doing real work rather than
      // agreeing vacuously on an empty list.
      expect(certified, hasLength(2));
      final committed = TrajectoryParser.certifiedElementSequence(outputs);
      expect(committed, hasLength(7));

      // Exactly how main.dart builds SpellAsset.formula at inscribe time.
      final asset = _spell(
        commitmentHex: _wildCommitment,
        t: t,
        formula: [for (final z in committed) z.name],
      );

      expect(
        wildMagicPreviewFor(asset, kDefaultCommunitySeed),
        WildMagic.triggersFor(outputs, certified, kDefaultCommunitySeed),
      );
    });

    test('fires the pinned Row-1 fire effect for the wild fixture', () {
      final triggers = wildMagicPreviewFor(
        _spell(commitmentHex: _wildCommitment),
        kDefaultCommunitySeed,
      );
      expect(triggers, hasLength(1));
      expect(triggers.single.effect, WildMagicEffectKind.burningHot);
      expect(triggers.single.bracketSteps, 0);
    });

    test('the quiet fixture fires nothing', () {
      expect(
        wildMagicPreviewFor(
          _spell(commitmentHex: _quietCommitment),
          kDefaultCommunitySeed,
        ),
        isEmpty,
      );
    });
  });

  group('formula regrouping', () {
    test('chunks the flat committed sequence into complete triplets', () {
      final formulas = completedFormulasFromNames([
        'fire', 'air', 'water', //
        'earth', 'earth', 'fire',
      ]);
      expect(formulas, hasLength(2));
      expect(formulas[0].affinity, BorderZone.fire);
      expect(formulas[0].effectType1, BorderZone.air);
      expect(formulas[0].effectType2, BorderZone.water);
      expect(formulas[1].affinity, BorderZone.earth);
    });

    test('drops the 0-2 element residual, matching TrajectoryParser.parse', () {
      expect(completedFormulasFromNames(['fire', 'fire']), isEmpty);
      expect(
        completedFormulasFromNames(['fire', 'fire', 'fire', 'water', 'water']),
        hasLength(1),
      );
    });

    test('a spell with no complete formula fires no wild magic', () {
      // Eligibility is empty, so the hash is never even consulted — the
      // design's "void effects entirely removed", for free.
      expect(
        wildMagicPreviewFor(
          _spell(commitmentHex: _wildCommitment, formula: const ['fire']),
          kDefaultCommunitySeed,
        ),
        isEmpty,
      );
    });
  });

  group('degrades quietly instead of throwing', () {
    test('a commitment that is not a 32-byte Field yields no wild magic', () {
      // Hand-built fixtures, legacy saves and trade-offer preview stubs all
      // carry short commitments; `build` must survive them.
      for (final hex in ['', '0x', '0xaabbcc', 'not-hex', '0x${'zz' * 32}']) {
        expect(
          wildMagicPreviewFor(_spell(commitmentHex: hex), kDefaultCommunitySeed),
          isEmpty,
          reason: 'commitment "$hex" should preview as no wild magic',
        );
      }
    });
  });

  group('leyline seed', () {
    test('rotating the seed word re-rolls the spell', () {
      final spell = _spell(commitmentHex: _wildCommitment);
      expect(wildMagicPreviewFor(spell, 'universal'), hasLength(1));
      expect(wildMagicPreviewFor(spell, 'rivendell'), isEmpty);
    });

    test('normalization is shared with the handshake', () {
      final spell = _spell(commitmentHex: _wildCommitment);
      expect(
        wildMagicPreviewFor(spell, 'Rivendell!'),
        wildMagicPreviewFor(spell, 'rivendell'),
      );
    });

    test('overrideLeylineSeed returns the value it displaced', () {
      final before = activeLeylineSeed.value;
      final displaced = overrideLeylineSeed('duel-tradition');
      expect(displaced, before);
      expect(activeLeylineSeed.value, 'duel-tradition');
      activeLeylineSeed.value = before;
    });
  });
}
