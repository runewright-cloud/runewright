// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_practice_identity_test.dart — who casts in a solo/practice session.
//
// Wild Magic v2 keys on the CASTER (docs/WILD_MAGIC_PLAN_VNEXT.md §2), so the
// identities `buildSoloBattleState` seats decide what a practice session
// teaches. Before Slice 3 both avatars carried the all-zero key, which meant
// practice rehearsed a spellbook nobody owned and the dummy was magically
// indistinguishable from the player. These pin the two rules that replaced it:
// the local wizard is the device's REAL wizard, and the dummy is an explicitly
// synthetic identity that is nobody's.

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/solo_battle_setup.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart';

import '../../support/wild_magic_fixture.dart';

/// Stands in for `Identity.ownerPubkeyHex()` — a real `Poseidon2(key_hi,
/// key_lo)` cannot be computed in a plain VM test (it goes through the Rust
/// bridge), so the test supplies the value the app resolves via
/// `resolveLocalCasterPubkeyHex`. What matters is that the SAME value reaches
/// the avatar and the library preview.
const String _realLocalPubkeyHex =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000013';

ChapterAsset _chapter() => ChapterAsset(
      id: 'ch_practice',
      name: 'Practice',
      createdAt: DateTime.utc(2026, 9, 2),
    );

const MatchConfig _config = MatchConfig();

void main() {
  group('the local wizard is the real local wizard', () {
    test('solo seats the caller-supplied canonical key', () {
      final setup = buildSoloBattleState(
        _chapter(),
        _config,
        localOwnerPubkeyHex: _realLocalPubkeyHex,
      );
      final local =
          setup.state.avatars.firstWhere((a) => a.playerId == 'local');
      expect(local.ownerPubkeyHex, _realLocalPubkeyHex);
    });

    test('and it is no longer the all-zero key', () {
      final setup = buildSoloBattleState(
        _chapter(),
        _config,
        localOwnerPubkeyHex: _realLocalPubkeyHex,
      );
      for (final avatar in setup.state.avatars) {
        expect(
          WildMagic.canonicalPubkeyBytes(avatar.ownerPubkeyHex),
          isNot(everyElement(0)),
          reason: 'a zero identity is the one value the derivation forbids',
        );
      }
    });

    test('solo Wild Magic agrees with the library preview for that wizard', () {
      // The property the whole slice exists for: a spell previewed in the
      // library and the same spell cast in practice are the same fact, because
      // both are `caster x proof x leyline` with the same caster.
      final setup = buildSoloBattleState(
        _chapter(),
        _config,
        localOwnerPubkeyHex: _realLocalPubkeyHex,
      );
      final local =
          setup.state.avatars.firstWhere((a) => a.playerId == 'local');
      final spell = fixtureSpell();

      // What TurnLoop derives for a local cast: certifyOwnProof, keyed on the
      // avatar's own ownerPubkeyHex and the match's leyline.
      final inBattle = PeerCastVerifier.certifyOwnProof(
        spell,
        casterOwnerPubkeyHex: local.ownerPubkeyHex,
        lexicon: IncantationLexicon.of(setup.state.config.leyline),
      )!;

      // What the library card shows, primed from the same identity and the
      // same leyline.
      debugClearWildMagicPreviewCache();
      final inLibrary = wildMagicPreviewFor(
        spell,
        WildMagicPreviewContext(
          casterPubkeyHex: _realLocalPubkeyHex,
          leyline: setup.state.config.leyline,
        ),
      );

      expect(inLibrary, inBattle.wildMagic);
      expect(inLibrary, isNotEmpty, reason: 'a vacuous agreement proves nothing');
    });
  });

  group('the practice opponent is explicitly synthetic', () {
    test('the dummy gets the synthetic key, not the player\'s and not zero',
        () {
      final setup = buildSoloBattleState(
        _chapter(),
        _config,
        localOwnerPubkeyHex: _realLocalPubkeyHex,
      );
      final dummy =
          setup.state.avatars.firstWhere((a) => a.playerId == 'dummy');
      expect(dummy.ownerPubkeyHex, kPracticeOpponentPubkeyHex);
      expect(dummy.ownerPubkeyHex, isNot(_realLocalPubkeyHex));
      expect(dummy.ownerPubkeyHex, isNot(kFixtureInscriberPubkeyHex));
    });

    test('it is deterministic across runs', () {
      final a = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _realLocalPubkeyHex);
      final b = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _realLocalPubkeyHex);
      expect(
        a.state.avatars.firstWhere((x) => x.playerId == 'dummy').ownerPubkeyHex,
        b.state.avatars.firstWhere((x) => x.playerId == 'dummy').ownerPubkeyHex,
      );
    });

    test('it is a canonical Field the derivation accepts', () {
      // Practice casts must resolve, so the synthetic key has to decode the
      // same way a real one does — 32 big-endian bytes, comfortably under the
      // BN254 modulus (its high bytes are zero).
      final bytes = WildMagic.canonicalPubkeyBytes(kPracticeOpponentPubkeyHex);
      expect(bytes, hasLength(32));
      expect(bytes[0], 0);
      expect(bytes[1], 0);

      expect(
        () => PeerCastVerifier.certifyOwnProof(
          fixtureSpell(),
          casterOwnerPubkeyHex: kPracticeOpponentPubkeyHex,
          lexicon: IncantationLexicon.ordinary,
        ),
        returnsNormally,
      );
    });

    test('its bytes spell out its own provenance', () {
      // Recognizable by construction: a reader of the bytes can see what it
      // is. No cryptographic claim about Poseidon2 outputs is intended.
      final bytes = WildMagic.canonicalPubkeyBytes(kPracticeOpponentPubkeyHex);
      expect(
        String.fromCharCodes(bytes.skip(2)),
        'Runewright/PracticeOpponent/v1',
      );
    });

    test('the two wizards find different Wild Magic in the same rune', () {
      final spell = fixtureSpell();
      final leyline = LeylineConfig.ordinary(kDefaultCommunitySeed);
      final mine = PeerCastVerifier.certifyOwnProof(
        spell,
        casterOwnerPubkeyHex: _realLocalPubkeyHex,
        lexicon: IncantationLexicon.of(leyline),
      )!;
      final theirs = PeerCastVerifier.certifyOwnProof(
        spell,
        casterOwnerPubkeyHex: kPracticeOpponentPubkeyHex,
        lexicon: IncantationLexicon.of(leyline),
      )!;
      expect(mine.wildMagic, isNot(theirs.wildMagic));
    });
  });
}
