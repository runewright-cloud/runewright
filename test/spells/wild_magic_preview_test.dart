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

import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// An OWNER key whose v2 semantic hash for the default fixture below contains a
/// run of exactly three '0's — one Row-1 trigger, bracketSteps 0 — under
/// "universal", and NO trigger at all under "rivendell". Found by brute force
/// over SHA-256; see the seed-rotation test, which is why one key covering both
/// cases is worth pinning.
///
/// It is the OWNER and no longer the commitment because Wild Magic v2 is keyed
/// on `caster x certified spell behavior x leyline` — the grid commitment left
/// the preimage entirely (WILD_MAGIC_PLAN_VNEXT.md §3).
const String _wildOwner =
    '0x419179f21ff142f1d784a5b3978f68b16c8aec4574303697527137e251565623';

/// An owner key that fires nothing for the same fixture — the ~97% case.
const String _quietOwner =
    '0x940e527f060f6f645e112f2faef63e3e73f948fbd5aea9a23ca845d057cee783';

/// A commitment. Kept on the fixture because `SpellAsset` requires one, and
/// deliberately shared by every spell here: it must not be able to change a
/// preview.
const String _someCommitment =
    '0xf9bce34e2b06068661f4537c136070f5b15e9a59ed3f302c3134f6084796d5af';

SpellAsset _spell({
  required String ownerPubkeyHex,
  String commitmentHex = _someCommitment,
  int t = 7,
  List<String> formula = const ['fire', 'fire', 'fire'],
}) => SpellAsset(
  id: 'preview-fixture',
  createdAt: DateTime.utc(2026, 8, 5),
  tier: 12,
  t: t,
  ownerPubkeyHex: ownerPubkeyHex,
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
      final outputs = _alternatingOutputs(commitmentHex: _someCommitment, t: t);
      final certified = TrajectoryParser.parse(outputs).formulas;

      // Sanity: the certified path really did produce complete formulas AND a
      // residual, so the regrouping below is doing real work rather than
      // agreeing vacuously on an empty list.
      expect(certified, hasLength(2));
      final committed = TrajectoryParser.certifiedElementSequence(outputs);
      expect(committed, hasLength(7));

      // Exactly how main.dart builds SpellAsset.formula at inscribe time.
      final asset = _spell(
        ownerPubkeyHex: _wildOwner,
        t: t,
        formula: [for (final z in committed) z.name],
      );

      // The preview's authored inputs and the engine's certified ones agree
      // for a well-formed asset, so the two must produce the same triggers.
      // (Where they can DISAGREE — a loaned spell, a drifted asset, a mutable
      // leyline — is documented on `wildMagicPreviewFor` and is Slice 3's
      // problem, not a property this test can assert.)
      expect(
        wildMagicPreviewFor(asset, kDefaultCommunitySeed),
        WildMagic.triggersFor(
          casterPubkeyHex: asset.ownerPubkeyHex,
          certifiedTrajectory: committed,
          certifiedBaseManaCost:
              PeerCastVerifier.certifiedBaseManaCost(outputs, certified),
          leylineConfigHash:
              LeylineConfig.ordinary(kDefaultCommunitySeed).leylineConfigHash,
          formulas: certified,
        ),
      );
    });

    test('fires the pinned Row-1 fire effect for the wild fixture', () {
      final triggers = wildMagicPreviewFor(
        _spell(ownerPubkeyHex: _wildOwner),
        kDefaultCommunitySeed,
      );
      expect(triggers, hasLength(1));
      expect(triggers.single.effect, WildMagicEffectKind.burningHot);
      expect(triggers.single.bracketSteps, 0);
    });

    test('the quiet fixture fires nothing', () {
      expect(
        wildMagicPreviewFor(
          _spell(ownerPubkeyHex: _quietOwner),
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
          _spell(ownerPubkeyHex: _wildOwner, formula: const ['fire']),
          kDefaultCommunitySeed,
        ),
        isEmpty,
      );
    });
  });

  group('degrades quietly instead of throwing', () {
    test('an owner key that is not a 32-byte Field yields no wild magic', () {
      // Hand-built fixtures, legacy saves and trade-offer preview stubs all
      // carry stub owner keys; `build` must survive them.
      for (final hex in ['', '0x', '0xaabbcc', 'not-hex', '0x${'zz' * 32}']) {
        expect(
          wildMagicPreviewFor(_spell(ownerPubkeyHex: hex), kDefaultCommunitySeed),
          isEmpty,
          reason: 'owner key "$hex" should preview as no wild magic',
        );
      }
    });

    test('a legacy asset with no certified geometry yields no wild magic', () {
      // segmentCount/dotCount are -1 on anything inscribed before
      // RULESET_VERSION 3, so there is no base cost to key on.
      final legacy = SpellAsset(
        id: 'legacy',
        createdAt: DateTime.utc(2026, 1, 1),
        tier: 12,
        t: 7,
        ownerPubkeyHex: _wildOwner,
        manaCost: 10,
        segmentCount: -1,
        dotCount: -1,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: 'Legacy',
        commitmentHex: _someCommitment,
        spellHashHex: '0xfeed',
        formula: const ['fire', 'fire', 'fire'],
      );
      expect(wildMagicPreviewFor(legacy, kDefaultCommunitySeed), isEmpty);
    });

    test('the grid commitment does not change a preview (§3)', () {
      expect(
        wildMagicPreviewFor(
          _spell(ownerPubkeyHex: _wildOwner, commitmentHex: '0x${'ab' * 32}'),
          kDefaultCommunitySeed,
        ),
        wildMagicPreviewFor(
          _spell(ownerPubkeyHex: _wildOwner, commitmentHex: '0x${'cd' * 32}'),
          kDefaultCommunitySeed,
        ),
      );
    });
  });

  group('leyline seed', () {
    test('rotating the seed word re-rolls the spell', () {
      final spell = _spell(ownerPubkeyHex: _wildOwner);
      expect(wildMagicPreviewFor(spell, 'universal'), hasLength(1));
      expect(wildMagicPreviewFor(spell, 'rivendell'), isEmpty);
    });

    test('normalization is shared with the handshake', () {
      final spell = _spell(ownerPubkeyHex: _wildOwner);
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
