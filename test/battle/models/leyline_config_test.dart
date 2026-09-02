// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_config_test.dart — the load-bearing tests for the canonical leyline
// representation and its hash (docs/LEYLINE_SEED_PLAN.md §2, §15).
//
// The hash vectors here are the CROSS-CLIENT CONTRACT, exactly like
// `wild_magic_test.dart`'s. Every peer must derive byte-identical codebooks and
// Wild Magic from the same configuration, and player-discovered combinations
// are meant to become culturally significant — so a refactor that changes any
// pinned literal below is a BREAKING CONSENSUS CHANGE, not a test that needs
// updating. If one of these fails, the change is wrong until proven otherwise.
//
// Every literal was cross-checked against an independent implementation of the
// documented byte layout before being pinned, so they attest the SPEC, not
// merely the current code's self-consistency.

import 'package:test/test.dart';

import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/match_config.dart';

void main() {
  // ── §15 — the hash, pinned ──────────────────────────────────────────────

  group('leylineConfigHash — fixed vectors (CROSS-CLIENT CONTRACT)', () {
    test('the canonical ordinary default', () {
      expect(
        LeylineConfig.ordinaryDefault.leylineConfigHash,
        '1f41e5d72808358a2132acf5f610a855c1e2093ed852168fc82100f63b47ac06',
      );
    });

    test("ordinary('rivendell')", () {
      expect(
        LeylineConfig.ordinary('rivendell').leylineConfigHash,
        'a5978b0625222f2bba3ece392ad5251c9b819e07af09588272cfa5f5bd5086b6',
      );
    });

    test("ordinary('glassmountain')", () {
      expect(
        LeylineConfig.ordinary('glassmountain').leylineConfigHash,
        'bdc45ebaa27cc2f701b2eb6f1d0f861590727bc72edb1d950c8aa0db9678a6e8',
      );
    });

    test("mutable('rivendell', length 4, 500‰)", () {
      expect(
        LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 4)
            .leylineConfigHash,
        '2b3f90cb9a5bc08b7c7e48457cae8c92c87c1b3616c11dd617b9f76df783a815',
      );
    });

    test("mutable('rivendell', length 5, 500‰)", () {
      expect(
        LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 5)
            .leylineConfigHash,
        'e7bad03c277f8a1c08cb0ef2e4ab355270ba371c42faa8d63d02fadf1879cbff',
      );
    });

    test("mutable('rivendell', length 6, 500‰)", () {
      expect(
        LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 6)
            .leylineConfigHash,
        'd2f85313ac7906a21d216c4a1b01b7cc1bfa54aca69787945158b631e902b18d',
      );
    });

    test("mutable('rivendell', length 5, 0‰) — noise density is in the hash", () {
      expect(
        LeylineConfig.mutable(
          communitySeed: 'rivendell',
          formulaLength: 5,
          noiseDensityPermille: 0,
        ).leylineConfigHash,
        '3c4661cad93cfc72682bd252225fbd8cad0471cd920ab09b4ce6714ed28fc6dc',
      );
    });

    test('output is 64 lowercase hex chars with no 0x prefix', () {
      final h = LeylineConfig.ordinary('anything').leylineConfigHash;
      expect(h.length, 64);
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('deterministic across repeated calls', () {
      final c = LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 5);
      final first = c.leylineConfigHash;
      for (var i = 0; i < 50; i++) {
        expect(c.leylineConfigHash, first);
      }
    });
  });

  // ── §10 — one seed, several magical environments ────────────────────────

  group('field separation', () {
    // LEYLINE_SEED_PLAN.md §10: `rivendell`, `rivendell 4` and `rivendell 5`
    // are three DIFFERENT Wild Magic environments. Nothing but the config
    // fields may collapse them together.
    test('ordinary and every mutable length over one seed are all distinct', () {
      final hashes = {
        LeylineConfig.ordinary('rivendell').leylineConfigHash,
        for (var len = 4; len <= 6; len++)
          LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: len)
              .leylineConfigHash,
      };
      expect(hashes.length, 4, reason: 'four configurations, four hashes');
    });

    test('noise density alone separates two otherwise identical configs', () {
      final a = LeylineConfig.mutable(
          communitySeed: 'rivendell', formulaLength: 5, noiseDensityPermille: 500);
      final b = LeylineConfig.mutable(
          communitySeed: 'rivendell', formulaLength: 5, noiseDensityPermille: 501);
      expect(a.leylineConfigHash, isNot(b.leylineConfigHash));
    });

    test('the seed alone separates two otherwise identical configs', () {
      final a = LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 5);
      final b = LeylineConfig.mutable(communitySeed: 'glassmountain', formulaLength: 5);
      expect(a.leylineConfigHash, isNot(b.leylineConfigHash));
    });

    test('the full matrix of supported configurations is collision-free', () {
      final seen = <String>{};
      var count = 0;
      for (final seed in ['rivendell', 'glassmountain', 'universal']) {
        seen.add(LeylineConfig.ordinary(seed).leylineConfigHash);
        count++;
        for (var len = 4; len <= 6; len++) {
          for (final noise in [0, 250, 500, 999]) {
            seen.add(LeylineConfig.mutable(
              communitySeed: seed,
              formulaLength: len,
              noiseDensityPermille: noise,
            ).leylineConfigHash);
            count++;
          }
        }
      }
      expect(seen.length, count);
    });

    test('the leyline NUMBER is never part of the seed', () {
      // "Rivendell 5" means seed 'rivendell' + formulaLength 5. A UI that
      // lazily passed the whole display string as the seed would silently
      // fork the tradition — normalization keeps the digit ('rivendell5').
      // This is the concrete reason LEYLINE_SEED_PLAN.md §2 forbids parsing
      // gameplay configuration out of the seed string.
      final correct =
          LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 5);
      final sloppy =
          LeylineConfig.mutable(communitySeed: 'Rivendell 5!', formulaLength: 5);
      expect(sloppy.normalizedSeed, 'rivendell5');
      expect(correct.leylineConfigHash, isNot(sloppy.leylineConfigHash));
      expect(
        sloppy.leylineConfigHash,
        '1baa74e8d29a66f17e8be64790f5c58cf5138c9c8522995cc1721d9d91081b68',
      );
    });
  });

  // ── Normalization equivalence ───────────────────────────────────────────

  group('seed normalization', () {
    test('case, whitespace and punctuation do not change the hash', () {
      final canonical = LeylineConfig.ordinary('rivendell').leylineConfigHash;
      for (final spelling in [
        'Rivendell',
        'RIVENDELL',
        'Rivendell!',
        '  riven dell  ',
        'r-i-v-e-n-d-e-l-l',
        'Rivendell.',
      ]) {
        expect(LeylineConfig.ordinary(spelling).leylineConfigHash, canonical,
            reason: 'spelling "$spelling" must be one tradition');
      }
    });

    test('seeds that normalize to empty fall back to the default tradition', () {
      for (final blank in ['', '   ', '---', '日本', '!!!']) {
        expect(
          LeylineConfig.ordinary(blank).leylineConfigHash,
          LeylineConfig.ordinaryDefault.leylineConfigHash,
          reason: '"$blank" must not become its own tradition',
        );
      }
    });

    test('the raw spelling survives for display, and carries the number', () {
      expect(LeylineConfig.ordinary('Rivendell!').communitySeed, 'Rivendell!');
      expect(LeylineConfig.ordinary('Rivendell').displayName, 'Rivendell');
      expect(
        LeylineConfig.mutable(communitySeed: 'Rivendell', formulaLength: 5)
            .displayName,
        'Rivendell 5',
      );
    });

    test('normalization is the SAME implementation the handshake compares on',
        () {
      // One regex, or two duelists can agree at the handshake while their
      // spells hash under different traditions. `wild_magic_effect.dart`
      // re-exports this function rather than owning a second copy.
      expect(normalizeCommunitySeed('Rivendell!'), 'rivendell');
      expect(normalizeCommunitySeed('---'), kDefaultCommunitySeed);
      expect(
        LeylineConfig.ordinary('Rivendell!').normalizedSeed,
        normalizeCommunitySeed('Rivendell!'),
      );
      // And the config's own equality agrees with the hash's verdict.
      expect(LeylineConfig.ordinary('Rivendell!'),
          LeylineConfig.ordinary('rivendell'));
    });
  });

  // ── Canonicality ────────────────────────────────────────────────────────

  group('canonicality — one hash per behaviour', () {
    test('an ordinary leyline cannot carry a mutable formula length', () {
      expect(
        () => LeylineConfig.fromJson({
          'communitySeed': 'rivendell',
          'mutableMagic': false,
          'formulaLength': 5,
          'noiseDensityPermille': 0,
          'lexiconVersion': 1,
        }),
        throwsA(isA<LeylineConfigException>()),
      );
    });

    test('an ordinary leyline cannot carry a noise density', () {
      expect(
        () => LeylineConfig.fromJson({
          'communitySeed': 'rivendell',
          'mutableMagic': false,
          'formulaLength': 3,
          'noiseDensityPermille': 500,
          'lexiconVersion': 1,
        }),
        throwsA(isA<LeylineConfigException>()),
      );
    });

    test('mutable formula lengths outside 4..6 are refused', () {
      for (final len in [0, 1, 2, 3, 7, 8, 64]) {
        expect(
          () => LeylineConfig.mutable(
              communitySeed: 'rivendell', formulaLength: len),
          throwsA(isA<LeylineConfigException>()),
          reason: 'length $len is outside the supported range',
        );
      }
    });

    test('noise densities outside 0..999 are refused', () {
      for (final n in [-1, 1000, 65535]) {
        expect(
          () => LeylineConfig.mutable(
              communitySeed: 'rivendell',
              formulaLength: 5,
              noiseDensityPermille: n),
          throwsA(isA<LeylineConfigException>()),
        );
      }
    });

    test('an undeliverable lexicon version is refused, not guessed at', () {
      expect(
        () => LeylineConfig.mutable(
            communitySeed: 'rivendell', formulaLength: 5, lexiconVersion: 2),
        throwsA(isA<LeylineConfigException>()),
      );
    });
  });

  // ── JSON ────────────────────────────────────────────────────────────────

  group('JSON round trips', () {
    test('an ordinary config survives a round trip, hash included', () {
      final original = LeylineConfig.ordinary('Rivendell!');
      final restored = LeylineConfig.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.communitySeed, 'Rivendell!', reason: 'raw spelling kept');
      expect(restored.leylineConfigHash, original.leylineConfigHash);
    });

    test('a mutable config survives a round trip, hash included', () {
      final original = LeylineConfig.mutable(
        communitySeed: 'Glass Mountain',
        formulaLength: 6,
        noiseDensityPermille: 250,
      );
      final restored = LeylineConfig.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.formulaLength, 6);
      expect(restored.noiseDensityPermille, 250);
      expect(restored.leylineConfigHash, original.leylineConfigHash);
    });

    test('a truncated object reads as ordinary play, never as a new grammar',
        () {
      final c = LeylineConfig.fromJson({'communitySeed': 'rivendell'});
      expect(c, LeylineConfig.ordinary('rivendell'));
    });
  });

  group('legacy MatchConfig JSON migration', () {
    test('a body with only the flat seed decodes to the ordinary config', () {
      final c = LeylineConfig.fromMatchConfigJson({'communitySeed': 'Rivendell!'});
      expect(c, LeylineConfig.ordinary('rivendell'));
      expect(c.mutableMagic, isFalse);
      expect(c.formulaLength, LeylineConfig.kOrdinaryFormulaLength);
      expect(c.noiseDensityPermille, 0);
      expect(c.lexiconVersion, LeylineConfig.kCurrentLexiconVersion);
      expect(c.leylineConfigHash,
          LeylineConfig.ordinary('rivendell').leylineConfigHash);
    });

    test('a body with neither key decodes to the canonical default', () {
      expect(LeylineConfig.fromMatchConfigJson(const {}),
          LeylineConfig.ordinaryDefault);
    });

    test('both keys present and agreeing is the normal case', () {
      final json = MatchConfig(leyline: LeylineConfig.ordinary('Rivendell!')).toJson();
      expect(json['communitySeed'], 'Rivendell!');
      expect(json['leyline'], isA<Map>());
      expect(LeylineConfig.fromMatchConfigJson(json),
          LeylineConfig.ordinary('rivendell'));
    });

    test('both keys present and DISAGREEING is refused, not resolved', () {
      expect(
        () => LeylineConfig.fromMatchConfigJson({
          'communitySeed': 'rivendell',
          'leyline': LeylineConfig.ordinary('glassmountain').toJson(),
        }),
        throwsA(isA<LeylineConfigException>()),
      );
    });

    test('agreement is judged on the NORMALIZED seed, not the raw spelling', () {
      final c = LeylineConfig.fromMatchConfigJson({
        'communitySeed': 'Rivendell!',
        'leyline': LeylineConfig.ordinary('  riven dell ').toJson(),
      });
      expect(c.normalizedSeed, 'rivendell');
    });

    test('a non-object leyline value is refused', () {
      expect(
        () => LeylineConfig.fromMatchConfigJson({'leyline': 'rivendell 5'}),
        throwsA(isA<LeylineConfigException>()),
      );
    });
  });

  // ── MatchConfig integration ─────────────────────────────────────────────

  group('MatchConfig', () {
    test('defaults to the canonical ordinary config', () {
      const config = MatchConfig();
      expect(config.leyline, LeylineConfig.ordinaryDefault);
      expect(config.communitySeed, kDefaultCommunitySeed);
    });

    test('communitySeed delegates to the leyline, raw spelling intact', () {
      final config = MatchConfig(leyline: LeylineConfig.ordinary('Rivendell!'));
      expect(config.communitySeed, 'Rivendell!');
    });

    test('matches() agrees across spellings of one tradition', () {
      final a = MatchConfig(leyline: LeylineConfig.ordinary('Rivendell!'));
      final b = MatchConfig(leyline: LeylineConfig.ordinary('  riven dell '));
      expect(a.matches(b), isTrue);
    });

    test('matches() refuses two different traditions', () {
      final a = MatchConfig(leyline: LeylineConfig.ordinary('rivendell'));
      final b = MatchConfig(leyline: LeylineConfig.ordinary('glassmountain'));
      expect(a.matches(b), isFalse);
    });

    test('matches() refuses two different grammars over one seed', () {
      final a = MatchConfig(leyline: LeylineConfig.ordinary('rivendell'));
      final b = MatchConfig(
        leyline:
            LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: 5),
      );
      expect(a.matches(b), isFalse);
    });

    test('a full MatchConfig JSON round trip preserves the leyline', () {
      final original = MatchConfig(
        playerHp: 30,
        leyline: LeylineConfig.mutable(
            communitySeed: 'Glass Mountain', formulaLength: 5),
      );
      final restored = MatchConfig.fromJson(original.toJson());
      expect(restored.matches(original), isTrue);
      expect(restored.leyline, original.leyline);
      expect(restored.leyline.leylineConfigHash,
          original.leyline.leylineConfigHash);
    });

    test('legacy JSON with no leyline object still agrees with a fresh build',
        () {
      // The compatibility guarantee that lets this ship without a protocol
      // bump: a peer predating LeylineConfig emits only `communitySeed`, and
      // both sides must still reach the same verdict at the handshake.
      final legacy = <String, dynamic>{
        'playerHp': 24,
        'gridRadius': 4,
        'tier': 24,
        'communitySeed': 'Rivendell!',
      };
      final decoded = MatchConfig.fromJson(legacy);
      expect(decoded.leyline, LeylineConfig.ordinary('rivendell'));
      expect(
        decoded.matches(MatchConfig(
          playerHp: 24,
          gridRadius: 4,
          tier: 24,
          leyline: LeylineConfig.ordinary('rivendell'),
          battleEngineVersion: decoded.battleEngineVersion,
        )),
        isTrue,
      );
    });

    test('our own JSON still carries the flat key an older peer reads', () {
      final json = MatchConfig(
        leyline: LeylineConfig.mutable(
            communitySeed: 'rivendell', formulaLength: 5),
      ).toJson();
      expect(json['communitySeed'], 'rivendell');
    });
  });
}
