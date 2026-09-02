// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_preview_test.dart — the card preview must be the same fact the
// duel resolves.
//
// Wild Magic v2 is deterministic for `caster x certified spell behavior x
// leyline`, so a preview is only honest if it takes all three from the same
// places the engine does: the VIEWER's identity (never the spell's inscriber),
// the spell's PROOF (never its authored metadata), and the structured
// LeylineConfig in force (never a seed word reconstituted as ordinary play).
// These tests pin each of those, plus the fail-closed behaviour that keeps a
// missing input from silently becoming a wrong preview.

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
import 'package:rune_duel/spells/spell_identity.dart' show uniqueSpellId;
import 'package:rune_duel/spells/wild_magic_preview.dart';
import 'package:rune_duel/trade/trade_offer.dart';

import '../support/wild_magic_fixture.dart';

// ── Pinned casters ────────────────────────────────────────────────────────────
//
// Found by brute force over SHA-256 against the shared fire fixture
// (`fixtureSpell()`), which is why each is pinned to a specific spell as well
// as a specific leyline. They are CASTER keys: under v2 the wizard is half the
// preimage, and the same rune is a different spell in different hands.

/// Fires exactly one Row-1 fire trigger (Burning Hot, bracketSteps 0) under the
/// ordinary "universal" leyline, and nothing at all under ordinary "rivendell".
/// One key covering both cases is what makes the leyline-rotation test sharp.
const String _wildCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000013';

/// Fires nothing for the same fixture under either leyline — the ~97% case,
/// and the second wizard in the "two casters, one rune" test.
const String _quietCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000000';

/// Fires nothing under ORDINARY "rivendell" but does fire under MUTABLE
/// "rivendell 4" — the two configs share a seed word and differ only in their
/// `leylineConfigHash`, which is exactly the collision `LeylineConfig`'s
/// canonicality rules exist to prevent.
const String _mutableSensitiveCaster =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000002';

WildMagicPreviewContext _ctx(String? caster, [LeylineConfig? leyline]) =>
    WildMagicPreviewContext(
      casterPubkeyHex: caster,
      leyline: leyline ?? LeylineConfig.ordinary(kDefaultCommunitySeed),
    );

/// A preview taken with a cold cache.
///
/// The paint cache is keyed on every input the derivation reads — and on
/// nothing else, which is the point of several tests below. Clearing it first
/// means a test asserting "X does not change the preview" is comparing two real
/// derivations rather than one derivation and one cache hit.
List<WildMagicTrigger> _preview(SpellAsset spell, WildMagicPreviewContext ctx) {
  debugClearWildMagicPreviewCache();
  return wildMagicPreviewFor(spell, ctx);
}

void main() {
  group('preview agrees with the engine', () {
    test('same triggers as the engine derives from the same proof', () {
      final spell = fixtureSpell();

      // The engine's own entry point: TurnLoop.certifiedFromProofBytes calls
      // exactly this, with the caster resolved from the authenticated
      // WizardAvatar and the leyline from MatchConfig.
      final engine = PeerCastVerifier.certifyOwnProof(
        spell,
        casterOwnerPubkeyHex: _wildCaster,
        leyline: LeylineConfig.ordinary(kDefaultCommunitySeed),
      )!;

      expect(_preview(spell, _ctx(_wildCaster)), engine.wildMagic);
    });

    test('and matches an independent derivation from the proof primitives', () {
      // Recomputed from TrajectoryParser + WildMagic directly rather than
      // through certifyOwnProof, so this does not merely restate the previous
      // test through the same call.
      final spell = fixtureSpell();
      final outputs = ProofIntake.parseOwn(spell.proofBytes, spell.tier);
      final formulas = TrajectoryParser.parse(outputs).formulas;
      final sequence = TrajectoryParser.certifiedElementSequence(outputs);

      // Sanity: the fixture really does certify a complete formula, so the
      // agreement below is not vacuous agreement on two empty lists.
      expect(formulas, hasLength(1));
      expect(sequence, [BorderZone.fire, BorderZone.fire, BorderZone.fire]);

      expect(
        _preview(spell, _ctx(_wildCaster)),
        WildMagic.triggersFor(
          casterPubkeyHex: _wildCaster,
          certifiedTrajectory: sequence,
          certifiedBaseManaCost:
              PeerCastVerifier.certifiedBaseManaCost(outputs, formulas),
          leylineConfigHash:
              LeylineConfig.ordinary(kDefaultCommunitySeed).leylineConfigHash,
          formulas: formulas,
        ),
      );
    });

    test('fires the pinned Row-1 fire effect for the wild caster', () {
      final triggers = _preview(fixtureSpell(), _ctx(_wildCaster));
      expect(triggers, hasLength(1));
      expect(triggers.single.effect, WildMagicEffectKind.burningHot);
      expect(triggers.single.bracketSteps, 0);
    });
  });

  group('the caster is half the spell', () {
    test('one rune, two wizards, two different previews', () {
      final spell = fixtureSpell();
      expect(_preview(spell, _ctx(_wildCaster)), hasLength(1));
      expect(_preview(spell, _ctx(_quietCaster)), isEmpty);
    });

    test('a borrowed spell previews as the BORROWER, not the inscriber', () {
      // The trade/loan case: the rune was inscribed by the quiet wizard and now
      // sits in the wild wizard's library. Wild Magic follows the current
      // caster (WILD_MAGIC_PLAN_VNEXT.md §2), so it must preview — and later
      // fire — the borrower's effect.
      final borrowed = fixtureSpell(ownerPubkeyHex: _quietCaster);
      expect(borrowed.ownerPubkeyHex, _quietCaster);

      expect(_preview(borrowed, _ctx(_wildCaster)), hasLength(1));
      expect(
        _preview(borrowed, _ctx(_wildCaster)),
        _preview(fixtureSpell(ownerPubkeyHex: _wildCaster), _ctx(_wildCaster)),
        reason: 'the inscriber recorded on the asset must not move a trigger',
      );

      // And the mirror: the inscriber holding their own rune while a quiet
      // wizard views it sees nothing.
      final own = fixtureSpell(ownerPubkeyHex: _wildCaster);
      expect(_preview(own, _ctx(_quietCaster)), isEmpty);
    });
  });

  group('the leyline is the other half', () {
    test('rotating the leyline re-rolls the spell', () {
      final spell = fixtureSpell();
      expect(
        _preview(spell, _ctx(_wildCaster, LeylineConfig.ordinary('universal'))),
        hasLength(1),
      );
      expect(
        _preview(spell, _ctx(_wildCaster, LeylineConfig.ordinary('rivendell'))),
        isEmpty,
      );
    });

    test('seed normalization is shared with the handshake', () {
      final spell = fixtureSpell();
      expect(
        _preview(spell, _ctx(_wildCaster, LeylineConfig.ordinary('Rivendell!'))),
        _preview(spell, _ctx(_wildCaster, LeylineConfig.ordinary('rivendell'))),
      );
    });

    test('one seed word, two structured configs, two previews', () {
      // "rivendell" and "rivendell 4" are distinct magical environments
      // (LEYLINE_SEED_PLAN.md §10). A preview that rebuilt an ordinary config
      // from the seed word alone — which is what this slice replaced — would
      // show them as one.
      final spell = fixtureSpell();
      final ordinary = LeylineConfig.ordinary('rivendell');
      final mutable =
          LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 4);
      expect(ordinary.leylineConfigHash, isNot(mutable.leylineConfigHash));

      expect(
        _preview(spell, _ctx(_mutableSensitiveCaster, ordinary)),
        isEmpty,
      );
      expect(
        _preview(spell, _ctx(_mutableSensitiveCaster, mutable)),
        hasLength(1),
      );
    });
  });

  group('reads the proof, never the authored metadata', () {
    // Each of these varies a wire field M4.22 established resolution must not
    // read, holding the proof bytes fixed. `_preview` clears the cache first,
    // so both sides are genuinely re-derived.
    final proof = fixtureProofBytes();

    test('the grid commitment does not change a preview (§3)', () {
      expect(
        _preview(
          fixtureSpell(proofBytes: proof, commitmentHex: '0x${'ab' * 32}'),
          _ctx(_wildCaster),
        ),
        _preview(
          fixtureSpell(proofBytes: proof, commitmentHex: '0x${'cd' * 32}'),
          _ctx(_wildCaster),
        ),
      );
    });

    test('the authored formula does not change a preview', () {
      expect(
        _preview(
          fixtureSpell(proofBytes: proof, formula: const []),
          _ctx(_wildCaster),
        ),
        _preview(
          fixtureSpell(
            proofBytes: proof,
            formula: const ['water', 'water', 'water', 'earth'],
          ),
          _ctx(_wildCaster),
        ),
      );
    });

    test('authored segmentCount / dotCount do not change a preview', () {
      expect(
        _preview(
          fixtureSpell(proofBytes: proof, segmentCount: 99, dotCount: 99),
          _ctx(_wildCaster),
        ),
        _preview(
          fixtureSpell(proofBytes: proof, segmentCount: 1, dotCount: 1),
          _ctx(_wildCaster),
        ),
      );
    });

    test('a declared T that does not change the tier does not change a preview',
        () {
      // T enters the hash only through the certified base cost (1.05^T), and
      // that T is the PROOF's. The asset's own `t` selects nothing but the
      // parse tier, so moving it within one tier must be inert.
      final a = fixtureSpell(proofBytes: proof, t: 5);
      final b = fixtureSpell(proofBytes: proof, t: 7);
      expect(a.tier, b.tier, reason: 'both must parse at the same tier');
      expect(_preview(a, _ctx(_wildCaster)), _preview(b, _ctx(_wildCaster)));
    });
  });

  group('fails closed rather than guessing', () {
    test('no viewer identity yields no wild magic', () {
      expect(_preview(fixtureSpell(), _ctx(null)), isEmpty);
    });

    test('a caster key that is not a 32-byte Field yields no wild magic', () {
      for (final hex in ['', '0x', '0xaabbcc', 'not-hex', '0x${'zz' * 32}']) {
        expect(
          _preview(fixtureSpell(), _ctx(hex)),
          isEmpty,
          reason: 'caster key "$hex" should preview as no wild magic',
        );
      }
    });

    test('an all-zero caster key is not a shared magical identity', () {
      // The one substitution the derivation singles out as forbidden: it would
      // give every unidentified viewer one wizard's wild magic.
      expect(
        _preview(fixtureSpell(), _ctx(kFixtureInscriberPubkeyHex)),
        _preview(fixtureSpell(), _ctx(kFixtureInscriberPubkeyHex)),
      );
      expect(
        _preview(fixtureSpell(), _ctx(kFixtureInscriberPubkeyHex)),
        isNot(_preview(fixtureSpell(), _ctx(_wildCaster))),
      );
    });

    test('a spell with no proof bytes yields no wild magic', () {
      // Legacy saves predating the field, and anything grid-withheld.
      final legacy = fixtureSpell(proofBytes: Uint8List(0));
      expect(_preview(legacy, _ctx(_wildCaster)), isEmpty);
    });

    test('a malformed proof yields no wild magic', () {
      final garbage = fixtureSpell(
        proofBytes: Uint8List.fromList(const [1, 2, 3]),
      );
      expect(_preview(garbage, _ctx(_wildCaster)), isEmpty);
    });

    test('a trade-offer preview stub shows no wild magic', () {
      // It carries display metadata only — no grid and no proof exist locally
      // until the grant arrives — so there is nothing authoritative to derive
      // from, and inventing an approximation is what this slice removed.
      final stub = TradeItem.fromSpell(
        fixtureSpell(),
        mode: TradeMode.transfer,
      ).previewSpellAsset();
      expect(stub.proofBytes, isEmpty);
      expect(_preview(stub, _ctx(_wildCaster)), isEmpty);
    });

    test('a spell with no complete formula fires no wild magic', () {
      // Eligibility is empty, so the hash is never even consulted — the
      // design's "void effects entirely removed", for free.
      final short = fixtureSpell(trajectory: const [1, 0, 1]);
      expect(_preview(short, _ctx(_wildCaster)), isEmpty);
    });
  });

  group('the paint cache identifies a proof exactly', () {
    // Two REAL fixture proofs of the same tier that differ only in their
    // trajectory. Every byte the old length + first/last-8 fingerprint sampled
    // is identical between them: same length, same leading field count, same
    // trailing dotCount field. They aliased, and one card painted the other's
    // Wild Magic.
    final fire = fixtureProofBytes(trajectory: const [1, 0, 1, 0, 1]);
    final earth = fixtureProofBytes(trajectory: const [4, 0, 4, 0, 4]);

    test('the two fixtures really are old-fingerprint aliases', () {
      expect(fire.length, earth.length);
      expect(fire.sublist(0, 8), earth.sublist(0, 8));
      expect(fire.sublist(fire.length - 8), earth.sublist(earth.length - 8));
      expect(fire, isNot(earth), reason: 'but they are different proofs');
    });

    test('their cache keys differ', () {
      final leyline =
          LeylineConfig.ordinary(kDefaultCommunitySeed).leylineConfigHash;
      expect(
        wildMagicPreviewCacheKey(
            fixtureSpell(proofBytes: fire), _wildCaster, leyline),
        isNot(wildMagicPreviewCacheKey(
            fixtureSpell(proofBytes: earth), _wildCaster, leyline)),
      );
    });

    test('the digest is the canonical SHA-256 of the proof bytes', () {
      // Same value uniqueSpellId produces — this is a memo over that function,
      // not a second identity scheme. (Local paint-cache use only; see the
      // scope note on `proofIdentityForPreview`.)
      expect(proofIdentityForPreview(fire), uniqueSpellId(fire));
      expect(proofIdentityForPreview(fire), isNot(proofIdentityForPreview(earth)));
    });

    test('a second spell does not read the first one out of the cache', () {
      // No cache clear between these two, on purpose: this is the aliasing
      // failure itself, end to end through the painter's entry point.
      debugClearWildMagicPreviewCache();
      final ctx = _ctx(_wildCaster);
      final first = wildMagicPreviewFor(fixtureSpell(proofBytes: fire), ctx);
      final second = wildMagicPreviewFor(fixtureSpell(proofBytes: earth), ctx);

      expect(first, isNot(second));
      expect(
        second,
        _preview(fixtureSpell(proofBytes: earth), ctx),
        reason: 'the warm-cache answer must equal the cold-cache one',
      );
    });
  });

  group('the active context', () {
    tearDown(() {
      activeWildMagicContext.value = const WildMagicPreviewContext();
    });

    test('overrideWildMagicContext returns the value it displaced', () {
      final before = activeWildMagicContext.value;
      final duel = _ctx(_wildCaster, LeylineConfig.ordinary('duel-tradition'));
      expect(overrideWildMagicContext(duel), before);
      expect(activeWildMagicContext.value, duel);
      expect(activeLeylineConfig.normalizedSeed, 'dueltradition');
      expect(activeCasterPubkeyHex, _wildCaster);
    });

    test('defaults to no caster, i.e. no preview, under the default leyline',
        () {
      const fresh = WildMagicPreviewContext();
      expect(fresh.casterPubkeyHex, isNull);
      expect(fresh.leyline, LeylineConfig.ordinaryDefault);
      expect(wildMagicPreviewFor(fixtureSpell(), fresh), isEmpty);
    });

    test('compares by value so cards only rebuild on a real change', () {
      expect(_ctx(_wildCaster), _ctx(_wildCaster));
      expect(_ctx(_wildCaster), isNot(_ctx(_quietCaster)));
      expect(
        _ctx(_wildCaster, LeylineConfig.ordinary('rivendell')),
        isNot(_ctx(_wildCaster, LeylineConfig.ordinary('universal'))),
      );
    });
  });

  group('formula regrouping (display helpers)', () {
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
  });
}
