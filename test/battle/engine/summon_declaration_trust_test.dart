// SPDX-License-Identifier: GPL-3.0-or-later
//
// summon_declaration_trust_test.dart — CHARACTERIZATION of the `isSummon`
// trust gap. These tests assert TODAY'S behaviour, including the part of it
// that is wrong.
//
// ## The gap
//
// `SpellAsset.isSummon` is a plain wire field. It rides in the spell action's
// two summon bytes (`_appendSummonBytes`, protocol v5) and nothing certifies
// it:
//
//   * The proof's public outputs are T, owner_pubkey, ruleset_version,
//     commitment, border_activations, dominance_trajectory,
//     supreme_dominance_flags, segment_count, dot_count (proof_intake.dart).
//     There is no summon bit among them.
//   * `commitment = Poseidon2(packed_grid)` is grid-only (CLAUDE.md invariant
//     2), and summon-ness is not a property of the grid.
//   * The book Merkle tree's leaves are `commitmentHex` values
//     (book_commitment.dart), so membership binds the grid and nothing else.
//   * `spellHashHex = Poseidon2(commitment, T)` (inscribe.dart) — again no
//     summon bit.
//
// So summon-ness is the *author's chosen interpretation* of a certified
// trajectory, not a fact the trajectory determines. The same grid is a
// perfectly legal summon and a perfectly legal incantation.
//
// The action commit does bind it *for the turn* — `_encodeAction` includes the
// summon bytes and the commit hashes those bytes — so a caster cannot flip it
// after seeing the reveal. That is a temporal binding, not an authenticity
// one: they still pick freely at commit time, knowing the board.
//
// ## Why that is load-bearing rather than cosmetic
//
// `TurnLoop._certifiedManaCost` and `DeterministicResolution._updateChainState`
// both branch on it to choose the chain affinity:
//
//   summon      → CreatureSpec.fromElements(certElementSequence).affinity
//                 — the MAJORITY element; never null for a non-empty sequence,
//                   so "a summon is always pure"
//   non-summon  → pureAffinityOf(certFormulas)
//                 — null unless EVERY formula shares one affinity
//
// A hybrid spell is therefore supposed to break the chain and pay full price.
// Declaring it a summon launders it into a pure cast: it takes the 0.9^n chain
// discount and *advances* the chain instead of clearing it. Both devices agree
// on the lie, so no state hash catches it.
//
// `vocal_slot.dart`'s `openerFor` doc comment names the exact reasoning error:
// it justifies trusting the field because it is "already consensus-visible",
// which establishes that both devices read the same value — not that the value
// is true.
//
// When the fix lands, `expectedChainLaunderingIsLive` flips to false and these
// expectations invert. Nothing here should be deleted: the attack stays the
// regression.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

/// Flip to false with the fix. See the file header.
const expectedChainLaunderingIsLive = true;

/// A HYBRID trajectory: two complete formulas whose affinities differ, so
/// `pureAffinityOf` is null and an honest incantation must break the chain.
/// Read as a creature instead, the element tally is fire 3 / earth 3 and
/// `_affinityOf`'s first-to-reach-the-max tie-break hands it to FIRE — so the
/// same cast becomes a pure fire cast.
///
/// Element order within a triplet is (affinity, effectType1, effectType2), so
/// the two formula affinities here are fire and earth. The three earths also
/// give the creature `maxHp == nEarth == 3`: a summon with no earth at all
/// derives 0 HP and is reaped the instant it spawns, which would hide the
/// resolution difference this file needs to show. No 4-run and no alternating
/// pair, so `kSummonAbilityPattern` grants nothing.
const _hybridElements = [
  BorderZone.fire, BorderZone.fire, BorderZone.fire,
  BorderZone.earth, BorderZone.earth, BorderZone.earth,
];

/// Chain credits: `chainLength == chainLengths[el] ~/ 2`, so 8 credits is a
/// 4-cast chain and a 0.9^4 = 0.6561 discount — big enough that no rounding
/// argument can explain the difference away.
const _chainCredits = 8;

void main() {
  group('isSummon is an uncertified wire field on a trusted path', () {
    test('the SAME certified spell prices differently by wire declaration only',
        () async {
      final asIncantation = await _castHybrid(declareSummon: false);
      final asSummon = await _castHybrid(declareSummon: true);

      // Both runs are honest about everything a proof attests: same certified
      // element sequence, same synthetic proof bytes, same commitment, same
      // battle state, same chain state, same starting mana. The single
      // difference is the summon byte.
      expect(bytesEqual(asIncantation.proofBytes, asSummon.proofBytes), isTrue,
          reason: 'the fixtures must differ ONLY in the wire summon byte');
      expect(asIncantation.commitmentHex, equals(asSummon.commitmentHex));

      // (5*3 + 2) * 1.05^6 * 1.5^1 = 34, the certified base both runs share.
      expect(asIncantation.costOnPeerDevice, equals(34),
          reason: 'an honest hybrid takes no chain discount: 1.0x');

      if (expectedChainLaunderingIsLive) {
        // ceil(34 * 0.9^4) = 23. A third off, bought with one wire byte.
        expect(asSummon.costOnPeerDevice, equals(23),
            reason: 'the summon declaration bought a chain discount the '
                'certified trajectory does not justify');
      } else {
        expect(asSummon.costOnPeerDevice,
            equals(asIncantation.costOnPeerDevice),
            reason: 'cost must be a function of certified data alone');
      }
    });

    test('the wire declaration also steers the surviving chain', () async {
      final asIncantation = await _castHybrid(declareSummon: false);
      final asSummon = await _castHybrid(declareSummon: true);

      // An honest hybrid clears the chain outright (design doc R3 — purity is
      // the whole rule).
      expect(asIncantation.chainElementOnPeerDevice, isNull);
      expect(asIncantation.chainCreditsOnPeerDevice, equals(0));

      if (expectedChainLaunderingIsLive) {
        expect(asSummon.chainElementOnPeerDevice, equals(SpellAffinity.fire),
            reason: 'declared a summon, so CreatureSpec supplied a majority '
                'affinity where the formulas supply none');
        expect(asSummon.chainCreditsOnPeerDevice,
            greaterThan(_chainCredits),
            reason: 'and the chain ADVANCED rather than breaking');
      } else {
        expect(asSummon.chainElementOnPeerDevice, isNull);
        expect(asSummon.chainCreditsOnPeerDevice, equals(0));
      }
    });

    test('both devices still agree — this is a cheat, not a desync', () async {
      for (final declareSummon in [false, true]) {
        final r = await _castHybrid(declareSummon: declareSummon);
        expect(r.canonicalMatches, isTrue,
            reason: 'declareSummon=$declareSummon: both devices consume the '
                'same wire declaration, so no state hash can catch this');
        expect(r.costOnCasterDevice, equals(r.costOnPeerDevice));
      }
    });

    test('lying in either direction is reachable — nothing rejects a mismatch',
        () async {
      // A genuine summon declared an incantation: it resolves as formula
      // effects, and the chain reads the formulas instead of the creature.
      final realSummonToldTrue = await _castHybrid(declareSummon: true);
      final realSummonToldFalse = await _castHybrid(declareSummon: false);

      // Neither run forfeits, throws, or fizzles. Certification is blind to
      // the field: PeerCastVerifier never inspects it and CertifiedPeerCast
      // has no place to put it.
      expect(realSummonToldTrue.rejected, isFalse);
      expect(realSummonToldFalse.rejected, isFalse);
      expect(realSummonToldTrue.minionsOnPeerDevice, equals(1),
          reason: 'declared a summon → a creature exists on both devices');
      expect(realSummonToldFalse.minionsOnPeerDevice, equals(0),
          reason: 'declared an incantation → the same grid resolved as '
              'effects instead');
    });
  });

  group('recall scoring inherits the same uncertified input', () {
    // _certifiedManaCost passes `isSummon: spell.isSummon` straight into
    // tallyAgainst as `expectedIsSummon`, and that picks which opener word the
    // caster is scored against. The caster authors BOTH the spoken claim and
    // the declaration, in one committed payload — so the opener slot can never
    // be scored wrong, which is one free unit of recall on every cast.
    test('the expected opener is chosen by the caster, not by the proof', () {
      const spokeSummonOpener = IncantationRecall(
        opener: VocalSlot.openerSummon,
        elements: [],
      );

      final scoredAsSummon = spokeSummonOpener.tallyAgainst(
        expectedIsSummon: true,
        expectedElements: const [],
      );
      final scoredAsIncantation = spokeSummonOpener.tallyAgainst(
        expectedIsSummon: false,
        expectedElements: const [],
      );

      expect(scoredAsSummon.correct, equals(1));
      expect(scoredAsSummon.weightedWrong, equals(0));
      expect(scoredAsIncantation.correct, equals(0));
      expect(scoredAsIncantation.weightedWrong,
          equals(IncantationRecall.openerWrongWeight));
      // Same utterance, two scores. The caster picks which one applies.
      expect(scoredAsSummon.applyTo(100),
          lessThan(scoredAsIncantation.applyTo(100)));
    });
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

typedef _Result = ({
  Uint8List proofBytes,
  String commitmentHex,
  int costOnCasterDevice,
  int costOnPeerDevice,
  SpellAffinity? chainElementOnPeerDevice,
  int chainCreditsOnPeerDevice,
  int minionsOnPeerDevice,
  bool canonicalMatches,
  bool rejected,
});

/// player_a casts the hybrid spell with the given wire declaration; player_b
/// passes. Both wizards start with a 4-cast fire chain, so the discount and
/// the chain outcome are both observable.
Future<_Result> _castHybrid({required bool declareSummon}) async {
  final casterState = _stateWithFireChain();
  final peerState = _stateWithFireChain();

  final pair = TurnSessionPair();
  final casterLoop = TurnLoop(
    state: casterState,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
  );
  final peerLoop = TurnLoop(
    state: peerState,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
  );

  // Identical in every certified respect; `isSummon` is the only variable.
  final spell = spellFromElements(
    elements: _hybridElements,
    variant: 1,
    name: 'Hybrid Ember',
    isSummon: declareSummon,
  );
  casterLoop.localChapterCommitments = [spell.commitmentHex];

  var rejected = false;
  try {
    await Future.wait([
      casterLoop.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
      )),
      peerLoop.runTurn(TurnInput(action: PassAction())),
    ], eagerError: true).timeout(const Duration(seconds: 20));
  } catch (_) {
    rejected = true;
  }

  WizardAvatar casterIn(BattleState s) =>
      s.avatars.firstWhere((av) => av.playerId == 'player_a');

  final peerCaster = casterIn(peerState);
  return (
    proofBytes: spell.proofBytes,
    commitmentHex: spell.commitmentHex,
    costOnCasterDevice: kStartMana - casterIn(casterState).mana,
    costOnPeerDevice: kStartMana - peerCaster.mana,
    chainElementOnPeerDevice: peerCaster.activeChainElement,
    chainCreditsOnPeerDevice:
        peerCaster.chainLengths[peerCaster.activeChainElement] ?? 0,
    minionsOnPeerDevice: peerState.minions.length,
    canonicalMatches: bytesEqual(
        casterState.toCanonicalBytes(), peerState.toCanonicalBytes()),
    rejected: rejected,
  );
}

/// [makeDuelState] with a 4-cast fire chain already running on the caster.
BattleState _stateWithFireChain() {
  final state = makeDuelState();
  final caster = state.avatars.firstWhere((av) => av.playerId == 'player_a');
  caster.activeChainElement = SpellAffinity.fire;
  caster.chainLengths[SpellAffinity.fire] = _chainCredits;
  return state;
}
