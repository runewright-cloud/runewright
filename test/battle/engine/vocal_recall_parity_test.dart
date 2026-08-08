// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_recall_parity_test.dart — do BOTH devices charge the same mana for the
// same recital?
//
// This is the desync shape the recall redesign could introduce, and the only
// one with no backstop left. The caster's device prices its own cast from the
// LOCAL element sequence (TurnLoop._spellCostBreakdown); the peer prices it
// from the CERTIFIED trajectory it derives itself (_certifiedManaCost). Those
// are two independently-written code paths reaching one number that lands in
// the canonical state hash.
//
// It matters more since the `insufficient_mana_for_spell` forfeit was removed
// (2026-08-05): there is no longer a gate that trips when the two disagree.
// A divergence would now surface as one device fizzling a cast while the other
// charges for it — quiet, and fatal to lockstep.
//
// Unlike vocal_recall_cost_test (one loop, direct assertions on the tally),
// this runs TWO TurnLoops through a real commit-reveal exchange, so the recall
// makes the full trip: encode -> wire bytes -> decode -> certify -> charge.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

/// Element indices as the stepper orders them (CLAUDE.md: 0=neutral, 1=fire,
/// 2=air, 3=water, 4=earth). Three lead changes in a row means three
/// activations, i.e. exactly one complete formula and no residuals — so the
/// wire and certified effect counts agree and the only thing left that can
/// move the mana is the recall.
const _fireIdx = 1;
const _airIdx = 2;
const _waterIdx = 3;

/// Synthetic proof in the wire format ProofIntake parses:
/// `[4 BE bytes: field count N][N × 32-byte fields][body]`.
///
/// Copied from turn_loop_determinism_test's helper and extended to stamp
/// [dominance] into the dominance_trajectory fields (8 .. 8+tier), which that
/// version leaves zero. Zeroes read as "neutral every generation" and certify
/// NO elements — and a spell with no certified elements has no recital, which
/// is exactly the case this test cannot use.
Uint8List _syntheticProof({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
  required int segmentCount,
  required int dotCount,
  required List<int> dominance,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);

  data.setUint32(0, count, Endian.big);
  data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
  data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3
  for (var i = 0; i < dominance.length; i++) {
    data.setUint32(4 + (8 + i) * 32 + 28, dominance[i], Endian.big);
  }
  data.setUint32(4 + (8 + 2 * tier) * 32 + 28, segmentCount, Endian.big);
  data.setUint32(4 + (8 + 2 * tier + 1) * 32 + 28, dotCount, Endian.big);
  return bytes;
}

BattleState _makeState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;
  return BattleState(
    config: const MatchConfig(vocalComponents: true),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 200,
        maxMana: 400,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 200,
        maxMana: 400,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: const [
      Team(id: 'team_a', playerIds: ['player_a']),
      Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}

SpellAsset _spell() {
  final commitmentBytes = Uint8List.fromList(List.filled(32, 0xab));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  return SpellAsset(
    id: 'recall-spell',
    createdAt: DateTime.utc(2026, 8, 5),
    tier: tierForSteps(3)!,
    t: 3,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: 0,
    segmentCount: 10,
    dotCount: 0,
    initialGrid: const [],
    proofBytes: _syntheticProof(
      tier: tierForSteps(3)!,
      t: 3,
      commitmentBytes: commitmentBytes,
      segmentCount: 10,
      dotCount: 0,
      dominance: const [_fireIdx, _airIdx, _waterIdx],
    ),
    name: 'Parity Probe',
    commitmentHex: commitmentHex,
    spellHashHex: '',
    // The wire formula must describe the SAME activations the certified
    // trajectory above derives, or the two cost paths diverge for a reason
    // that has nothing to do with recall.
    formula: const ['fire', 'air', 'water'],
  );
}

Future<bool> _alwaysOk(Uint8List vk, Uint8List proof) async => true;

/// Runs one sorcerer-mode turn where player_a casts with [recall] and player_b
/// passes, through a genuine two-client commit-reveal exchange.
///
/// Returns both loops' canonical state and both views of the caster's mana.
Future<({Uint8List a, Uint8List b, int manaA, int manaB})> _runCast(
  IncantationRecall? recall,
) async {
  final stateA = _makeState();
  final stateB = _makeState();
  final pair = TurnSessionPair();

  // Both loops VERIFY rather than skip: skipping short-circuits
  // _verifyPeerSpellCast at its "verify == null" bail-out, which never charges
  // the peer side at all — the mana would then match for the wrong reason.
  final loopA = TurnLoop(
    state: stateA,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    isVocalComponents: true,
    verifyProof: _alwaysOk,
    vkBytes: Uint8List(0),
  );
  final loopB = TurnLoop(
    state: stateB,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    isVocalComponents: true,
    verifyProof: _alwaysOk,
    vkBytes: Uint8List(0),
  );

  final spell = _spell();
  // Needed for _encodeAction to append the proof + membership tail the
  // receiving loop requires; a single-spell chapter is a depth-0 proof.
  loopA.localChapterCommitments = [spell.commitmentHex];

  await Future.wait([
    loopA.runTurn(TurnInput(
      action: SpellCastAction(
        spell: spell,
        targetHex: const HexCoord(1, 0),
        recall: recall,
      ),
    )),
    loopB.runTurn(TurnInput(action: PassAction())),
  ]);

  int manaOf(BattleState s) =>
      s.avatars.firstWhere((a) => a.playerId == 'player_a').mana;

  return (
    a: stateA.toCanonicalBytes(),
    b: stateB.toCanonicalBytes(),
    manaA: manaOf(stateA),
    manaB: manaOf(stateB),
  );
}

const _perfect = IncantationRecall(
  opener: VocalSlot.openerGeneral,
  elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
);

void main() {
  group('both devices charge the same mana for the same recital', () {
    test('a perfect recital', () async {
      final r = await _runCast(_perfect);
      expect(r.manaA, r.manaB,
          reason: 'caster and peer priced the same cast differently');
      expect(r.a, equals(r.b), reason: 'canonical state diverged');
    });

    test('a total blank', () async {
      final r = await _runCast(IncantationRecall.silent);
      expect(r.manaA, r.manaB);
      expect(r.a, equals(r.b));
    });

    test('a partial recital', () async {
      final r = await _runCast(const IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: [VocalSlot.fire, VocalSlot.earth, null],
      ));
      expect(r.manaA, r.manaB);
      expect(r.a, equals(r.b));
    });

    test('a wrong opener', () async {
      final r = await _runCast(const IncantationRecall(
        opener: VocalSlot.openerSummon, // the spell is not a summon
        elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
      ));
      expect(r.manaA, r.manaB);
      expect(r.a, equals(r.b));
    });

    test('no recall at all', () async {
      final r = await _runCast(null);
      expect(r.manaA, r.manaB);
      expect(r.a, equals(r.b));
    });
  });

  // Agreement is necessary but not sufficient: two paths that both ignored the
  // recall would agree perfectly. These prove it survived the wire and reached
  // the ledger on BOTH sides.
  group('the recall actually crossed the wire', () {
    test('a perfect recital costs less than a blank one, on both devices',
        () async {
      final perfect = await _runCast(_perfect);
      final blank = await _runCast(IncantationRecall.silent);

      final perfectSpent = 200 - perfect.manaA;
      final blankSpent = 200 - blank.manaA;
      expect(perfectSpent, lessThan(blankSpent),
          reason: 'the recall never reached the cost');

      // The peer independently derived the same difference from the certified
      // trajectory — it never saw the caster's multiplier, only their words.
      expect(200 - perfect.manaB, perfectSpent);
      expect(200 - blank.manaB, blankSpent);
    });

    test('a wrong opener costs more than a right one, on both devices',
        () async {
      final right = await _runCast(_perfect);
      final wrong = await _runCast(const IncantationRecall(
        opener: VocalSlot.openerSummon,
        elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
      ));
      expect(200 - wrong.manaA, greaterThan(200 - right.manaA));
      expect(200 - wrong.manaB, greaterThan(200 - right.manaB));
    });
  });
}
