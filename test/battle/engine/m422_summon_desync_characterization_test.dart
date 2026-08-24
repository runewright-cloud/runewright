// SPDX-License-Identifier: GPL-3.0-or-later
//
// m422_summon_desync_characterization_test.dart — CHARACTERIZATION, NOT A FIX.
//
// ## M4.22: a summon cast breaks lockstep on the turn it is cast
//
// Observed on real hardware 2026-08-23 (Pixel 6 host + Linux desktop join,
// commit 8ee51fc, engine v4): casting Basic Windhound produced
// "state hash mismatch on turn 3" on both devices, in two independent
// matches, with one summoner and with two. Ordinary casts were fine.
// See M4_engine_v4_two_device_gate_REPORT.md.
//
// ## Root cause, reproduced offline here
//
// Resolution reads a cast's element sequence from two different places
// depending on WHICH DEVICE is running it:
//
//   * the CASTER's own immediate cast has no entry in `certifiedPeerCasts`
//     (deterministic_resolution.dart, `resolveActions`), so `certElementSequence`
//     is null and `applySpell` falls back to `elementSequence(spell)` — the
//     AUTHORED `SpellAsset.formula`, a wire field no proof attests;
//   * the VERIFIER resolves the same cast from `PeerCastVerifier.semanticsOf`,
//     i.e. `TrajectoryParser.certifiedElementSequence` over the VERIFIED
//     public outputs.
//
// Between honest clients those two are supposed to be the same list. For the
// shipped `assets/basic_spells/basic_windhound.json` they are not:
//
//     authored  (12): air water earth air water fire air earth water fire air earth
//     certified  (3): fire water water
//
// The certified one is right. `stepper.dart` (the canonical oracle, CLAUDE.md
// §Canonical sources) replayed over the asset's own `initialGrid` reproduces
// the proof's dominance trajectory and supreme flags exactly, and commits
// [fire, water, water]. `inscribeSpell` takes `formula`, `supremeTags` and
// `manaCost` as CALLER-SUPPLIED arguments (lib/spells/inscribe.dart) and never
// checks them against the proof it just generated, so a stale UI FormulaTracker
// is persisted verbatim and ships.
//
// ## What actually diverges first — NOT the minion
//
// `wireBaseManaCost` counts effects from the authored formula (4 formulas →
// ×1.5³) and `certifiedBaseManaCost` from the certified one (1 formula → ×1.5⁰),
// so the caster charges itself 83 and the verifier charges it 25. That lands in
// `WizardAvatar.mana`, which `toCanonicalBytes` writes in the AVATAR block, long
// before the minion block. Minion.id is drawn at the same RNG position on both
// devices and is IDENTICAL; it is not the cause.
//
// ## Fixing this
//
// These tests assert the CURRENT (broken) behaviour so the defect cannot drift
// unnoticed. When M4.22 is fixed they must be INVERTED — see the notes on each.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/deterministic_resolution.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/creature_spec.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/ca_run.dart' show advanceDominance;
import 'package:rune_duel/engine/formula.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/stepper.dart' show CAStep;
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

SpellAsset _basic(String slug) => SpellAsset.fromJson(
      jsonDecode(File('assets/basic_spells/$slug.json').readAsStringSync())
          as Map<String, dynamic>,
    );

List<String> _authored(SpellAsset s) =>
    DeterministicResolution.elementSequence(s).map((z) => z.name).toList();

List<String> _certified(SpellAsset s) => TrajectoryParser.certifiedElementSequence(
      ProofIntake.parseOwn(s.proofBytes, s.tier),
    ).map((z) => z.name).toList();

/// The element sequence `stepper.dart` — the canonical oracle — commits when
/// replayed over [s]'s own recorded initial grid for its own T.
List<String> _stepperReplay(SpellAsset s) {
  var grid = HexGrid.fromPackedState(s.initialGrid, 12);
  var rule = CARules.neutral;
  final tracker = FormulaTracker();
  for (var gen = 0; gen < s.t; gen++) {
    final next = CAStep.step(grid, rule);
    final dom = advanceDominance(rule, next);
    tracker.step(FormulaTracker.zoneFor(dom.dominant),
        supremeDominant: dom.isSupreme);
    grid = next;
    rule = dom.rule;
  }
  return tracker.committed.map((z) => z.name).toList();
}

int _manaOf(BattleState s, String playerId) =>
    s.avatars.firstWhere((a) => a.playerId == playerId).mana;

void main() {
  // ── 1. The content defect ───────────────────────────────────────────────

  test('the four non-summon basics agree with their own proofs', () {
    for (final e in kBasicSpells.where((e) => e.slug != 'basic_windhound')) {
      final s = _basic(e.slug);
      expect(_authored(s), equals(_certified(s)),
          reason: '${e.slug}: authored wire formula vs certified trajectory');
      expect(_stepperReplay(s), equals(_certified(s)),
          reason: '${e.slug}: stepper replay vs certified trajectory');
    }
  });

  test(
    'CHARACTERIZATION: basic_windhound\'s authored formula contradicts its own proof',
    () {
      final s = _basic('basic_windhound');

      // The proof really is this grid's proof — commitment, T, segment and dot
      // counts all agree. Only the authored prose fields are wrong.
      final outs = ProofIntake.parseOwn(s.proofBytes, s.tier);
      expect(outs.commitmentHex.toLowerCase(),
          equals(s.commitmentHex.toLowerCase()));
      expect(outs.t, equals(s.t));
      expect(outs.segmentCount, equals(s.segmentCount));
      expect(outs.dotCount, equals(s.dotCount));

      // stepper.dart is canonical, and it sides with the proof.
      expect(_stepperReplay(s), equals(_certified(s)),
          reason: 'the canonical oracle reproduces the certified trajectory');
      expect(_certified(s), equals(['fire', 'water', 'water']));

      // WHEN FIXED: this becomes expect(_authored(s), equals(_certified(s))).
      expect(_authored(s), isNot(equals(_certified(s))),
          reason: 'M4.22: the shipped asset\'s wire formula is not derivable '
              'from its own grid at any T — regenerate it and this flips');
      expect(_authored(s), hasLength(12));

      // The two sequences build different creatures. The certified one has a
      // 0 HP stat block, so the verifier's creature is reaped the instant it
      // spawns while the caster's fights on.
      final specAuthored = CreatureSpec.fromElements(
          DeterministicResolution.elementSequence(s));
      final specCertified = CreatureSpec.fromElements(
          TrajectoryParser.certifiedElementSequence(outs));
      expect(specAuthored!.affinity, isNot(equals(specCertified!.affinity)));
      expect(specAuthored.stats.maxHp, equals(3));
      expect(specCertified.stats.maxHp, equals(0));

      // And they price differently, which is what diverges FIRST.
      expect(s.manaCost, equals(83), reason: 'authored price');
      // 5*0 + 8, grown by 1.05^23 with effectCount 0.
      expect(PeerCastVerifierBaseCost.of(outs), equals(25),
          reason: 'certified price the peer charges');
    },
  );

  // ── 2. The two-device defect, reproduced offline ────────────────────────

  test(
    'CHARACTERIZATION: one real Windhound cast desyncs the pair',
    () async {
      final casterState = makeDuelState(startingMana: 100);
      final verifierState = makeDuelState(startingMana: 100);
      final pair = TurnSessionPair();
      final spell = _basic('basic_windhound');

      final caster = TurnLoop(
        state: casterState,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final verifier = TurnLoop(
        state: verifierState,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      caster.localChapterCommitments = [spell.commitmentHex];

      final errors = <Object>[];
      await Future.wait([
        caster
            .runTurn(TurnInput(
                action: SpellCastAction(
                    spell: spell, targetHex: const HexCoord(0, 1))))
            .catchError(errors.add),
        verifier
            .runTurn(TurnInput(action: PassAction()))
            .catchError(errors.add),
      ]);

      // Both devices forfeit on the state hash — the hardware symptom.
      // WHEN FIXED: expect(errors, isEmpty).
      expect(errors, hasLength(2));
      expect(errors.first.toString(), contains('state hash mismatch'));

      // The FIRST canonical field to differ is the caster's mana, in the
      // avatar block. 100 − 83 (authored) vs 100 − 25 (certified).
      expect(_manaOf(casterState, 'player_a'), equals(17));
      expect(_manaOf(verifierState, 'player_a'), equals(75));

      // Downstream, the creatures differ too: the caster keeps a 3 HP air
      // hound, the verifier's 0 HP water hound is reaped on the spot. This is
      // precisely the case peer_summon_replication_test.dart's old
      // `hasLength(1)` assertion could not see.
      expect(casterState.minions, hasLength(1));
      expect(verifierState.minions, isEmpty);
    },
  );

  test(
    'CHARACTERIZATION: two real Windhound casts CROSS rather than cancel',
    () async {
      // The gate report hypothesised that a double summon would cancel any
      // local-vs-peer asymmetry, because each device runs one of each. It does
      // not: `toCanonicalBytes` writes mana PER PLAYER, so device A ends up
      // with (a=17, b=75) and device B with (a=75, b=17) — mirrored, never
      // equal. "One local + one peer cancels out" was never a valid
      // expectation for a per-player canonical encoding.
      final stateA = makeDuelState(startingMana: 100);
      final stateB = makeDuelState(startingMana: 100);
      final pair = TurnSessionPair();
      final spell = _basic('basic_windhound');

      final loopA = TurnLoop(
        state: stateA,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final loopB = TurnLoop(
        state: stateB,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      loopA.localChapterCommitments = [spell.commitmentHex];
      loopB.localChapterCommitments = [spell.commitmentHex];

      final errors = <Object>[];
      await Future.wait([
        loopA
            .runTurn(TurnInput(
                action: SpellCastAction(
                    spell: spell, targetHex: const HexCoord(0, 1))))
            .catchError(errors.add),
        loopB
            .runTurn(TurnInput(
                action: SpellCastAction(
                    spell: spell, targetHex: const HexCoord(2, 0))))
            .catchError(errors.add),
      ]);

      // WHEN FIXED: expect(errors, isEmpty).
      expect(errors, hasLength(2));
      expect(_manaOf(stateA, 'player_a'), equals(17));
      expect(_manaOf(stateA, 'player_b'), equals(75));
      expect(_manaOf(stateB, 'player_a'), equals(75));
      expect(_manaOf(stateB, 'player_b'), equals(17));
    },
  );
}

/// Local shim so the test can name the certified base price without reaching
/// into [PeerCastVerifier]'s peer-only entry points.
class PeerCastVerifierBaseCost {
  static int of(VerifiedSpellOutputs outputs) => _base(outputs);
  static int _base(VerifiedSpellOutputs o) {
    final formulas = TrajectoryParser.parse(o).formulas;
    var v = (5 * o.segmentCount + o.dotCount).toDouble();
    for (var i = 0; i < o.t; i++) {
      v *= 1.05;
    }
    for (var i = 0; i < formulas.length - 1; i++) {
      v *= 1.5;
    }
    return v.round();
  }
}
