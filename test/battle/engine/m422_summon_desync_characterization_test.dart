// SPDX-License-Identifier: GPL-3.0-or-later
//
// m422_summon_desync_characterization_test.dart — the M4.22 REGRESSION.
//
// ## What broke
//
// Observed on real hardware 2026-08-23 (Pixel 6 host + Linux desktop join,
// commit 8ee51fc, engine v4): casting Basic Windhound produced
// "state hash mismatch on turn 3" on both devices, in two independent
// matches, with one summoner and with two. Ordinary casts were fine.
// See M4_engine_v4_two_device_gate_REPORT.md.
//
// ## Root cause: one cast, two semantic authorities
//
// Resolution read a cast's element sequence from a different place depending
// on WHICH DEVICE was running it:
//
//   * the CASTER's own immediate cast has no entry in `certifiedPeerCasts`
//     (only `TurnLoop._verifyPeerSpellCast` writes it), so `resolveActions`
//     found no `CertifiedCast` and every consumer fell through to
//     `elementSequence(spell)` / `wireBaseManaCost(spell)` — the AUTHORED
//     `SpellAsset.formula`, a wire field no proof attests;
//   * the VERIFIER resolved the same cast from `PeerCastVerifier.semanticsOf`,
//     i.e. the certified trajectory over VERIFIED public outputs.
//
// Between honest clients those two are supposed to be the same list. That
// assumption was load-bearing and unenforced, and the shipped
// `assets/basic_spells/basic_windhound.json` violated it:
//
//     authored  (12): air water earth air water fire air earth water fire air earth
//     certified  (3): fire water water
//
// The certified one is right. `stepper.dart` (the canonical oracle, CLAUDE.md
// §Canonical sources) replayed over the asset's own `initialGrid` reproduces
// the proof's dominance trajectory and supreme flags exactly, and commits
// [fire, water, water]. `inscribeSpell` took `formula`, `supremeTags` and
// `manaCost` as CALLER-SUPPLIED arguments and never checked them against the
// proof it just generated, so a stale UI FormulaTracker was persisted verbatim
// and shipped.
//
// ## The two fixes this file now pins
//
//   1. **Content.** The shipped asset was regenerated from its own proof
//      (`scripts/audit_spell_assets.dart`), and
//      `scripts/export_basic_spells.dart` now refuses to export an asset whose
//      authored metadata contradicts its proof. Section 1 below.
//
//   2. **Engine (kBattleEngineVersion 4 → 5).** A caster's own proof-backed
//      immediate cast now resolves and is priced from
//      `certifiedFromProofBytes(spell)` — the same proof bytes the peer
//      verifies. Section 2 below. The general, non-summon form of this is in
//      `authored_spell_field_trust_test.dart`, which proves the repair is
//      about the authority boundary rather than about Windhound.
//
// Fix 2 is what makes fix 1 unnecessary for correctness; fix 1 is still
// required because the asset's 83-mana price and its air-hound artwork are
// player-visible. Each is tested on its own so neither can silently regress
// behind the other.
//
// ## What diverged FIRST — not the minion
//
// `wireBaseManaCost` counted effects from the authored formula (4 formulas →
// x1.5^3) and `certifiedBaseManaCost` from the certified one (1 formula →
// x1.5^0), so the caster charged itself 83 and the verifier charged it 25.
// That landed in `WizardAvatar.mana`, which `toCanonicalBytes` writes in the
// AVATAR block, long before the minion block. Minion.id was drawn at the same
// RNG position on both devices and was IDENTICAL; it was never the cause, and
// nothing about `Minion.id` or `HashRng` was touched by the fix.

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
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/ca_run.dart' show advanceDominance;
import 'package:rune_duel/engine/formula.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/stepper.dart' show CAStep;
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_asset_integrity.dart';

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

  test('every shipped basic agrees with its own proof', () {
    for (final e in kBasicSpells) {
      final s = _basic(e.slug);
      expect(_authored(s), equals(_certified(s)),
          reason: '${e.slug}: authored wire formula vs certified trajectory');
      expect(_stepperReplay(s), equals(_certified(s)),
          reason: '${e.slug}: stepper replay vs certified trajectory');
    }
  });

  test(
    'basic_windhound now agrees with its own proof (the corrected asset)',
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

      // THE INVERSION. Before the content fix this asset authored 12 elements
      // over a proof attesting three, and this assertion was
      // `isNot(equals(...))`. No T in 1..48 on that grid produces the authored
      // sequence, so it came from a different grid or a pre-ink-substrate
      // replay — it was never regenerable, only replaceable.
      expect(_authored(s), equals(_certified(s)),
          reason: 'the shipped asset must be derivable from its own proof');
      expect(_authored(s), hasLength(3));

      // One creature now, not two. The old authored sequence built a 3 HP air
      // hound and the certified one a 0 HP water hound that is reaped the
      // instant it spawns — which is why the verifier used to end the turn
      // with an empty minion list while the caster's hound fought on.
      final specAuthored = CreatureSpec.fromElements(
          DeterministicResolution.elementSequence(s));
      final specCertified = CreatureSpec.fromElements(
          TrajectoryParser.certifiedElementSequence(outs));
      expect(specAuthored!.affinity, equals(specCertified!.affinity));
      expect(specAuthored.stats.maxHp, equals(specCertified.stats.maxHp));

      // And they price the same, which is what used to diverge FIRST.
      // 5*0 + 8, grown by 1.05^23 with effectCount 0 → 25. Was 83.
      expect(s.manaCost, equals(25), reason: 'the corrected authored price');
      expect(PeerCastVerifierBaseCost.of(outs), equals(25),
          reason: 'the certified price the peer charges');
    },
  );

  test('the asset-integrity audit finds ZERO mismatches in the shipped bundle',
      () {
    // The same audit `scripts/export_basic_spells.dart` now runs as an export
    // gate and `scripts/audit_spell_assets.dart` runs over a library. Pinned
    // here so a regenerated bundle cannot reintroduce a mismatch without a red
    // test, whatever route it took to disk.
    for (final e in kBasicSpells) {
      final s = _basic(e.slug);
      expect(
        auditSpellSemantics(
          proofBytes: s.proofBytes,
          t: s.t,
          declaredTier: s.tier,
          commitmentHex: s.commitmentHex,
          segmentCount: s.segmentCount,
          dotCount: s.dotCount,
          formula: s.formula,
          supremeTags: s.supremeTags,
          manaCost: s.manaCost,
        ),
        isEmpty,
        reason: '${e.slug}: authored metadata must agree with its own proof',
      );
    }
  });

  // ── 2. The two-device defect, reproduced offline from the exact
  //       hardware input, and now held in lockstep ────────────────────────

  test(
    'one real Windhound cast keeps the pair in lockstep',
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
            .catchError(collectError(errors)),
        verifier
            .runTurn(TurnInput(action: PassAction()))
            .catchError(collectError(errors)),
      ]);

      // THE INVERSION. This used to be `hasLength(2)` with
      // `contains('state hash mismatch')` — the exact hardware symptom,
      // reproduced offline with no fuzzing and no new harness machinery.
      expect(errors, isEmpty,
          reason: 'no state-hash mismatch: both devices now resolve this cast '
              'from the same proof bytes');

      // The first canonical field that used to differ. Both devices charge the
      // certified 25 now; the caster used to charge itself the authored 83 and
      // sit on 17 mana while the verifier had it on 75.
      expect(_manaOf(casterState, 'player_a'), equals(75),
          reason: 'caster charges the certified price');
      expect(_manaOf(verifierState, 'player_a'), equals(75),
          reason: 'verifier charges the same certified price');

      // Both devices resolve [fire, water, water] — a 0 HP water hound, reaped
      // the instant it spawns. The caster used to keep a 3 HP air hound from
      // the authored sequence while the verifier's list stayed empty; that is
      // precisely the case peer_summon_replication_test.dart's old
      // `hasLength(1)` assertion could not see.
      expect(_certified(spell), equals(['fire', 'water', 'water']));
      expect(casterState.minions, isEmpty,
          reason: 'the certified water hound has 0 HP and is reaped on spawn');
      expect(verifierState.minions, isEmpty);

      // Every canonically-hashed Minion field agrees — vacuously here, since
      // both lists are empty, but asserted structurally so this keeps its
      // meaning if the creature ever survives.
      expect(casterState.minions.map(_minionFingerprint).toList(),
          equals(verifierState.minions.map(_minionFingerprint).toList()));

      // The exact comparison `_exchangeStateHash` performs.
      expect(casterState.toCanonicalBytes(),
          equals(verifierState.toCanonicalBytes()),
          reason: 'full canonical state must agree across the pair');
    },
  );

  test(
    'two real Windhound casts on one turn also stay in lockstep',
    () async {
      // The gate report hypothesised that a double summon would CANCEL the
      // local-vs-peer asymmetry, because each device runs one of each. It never
      // could: `toCanonicalBytes` writes mana PER PLAYER, so device A ended up
      // with (a=17, b=75) and device B with (a=75, b=17) — mirrored, never
      // equal, which is exactly the mirrored hashes the hardware showed. Now
      // every entry is the certified 75 and the two agree outright.
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
            .catchError(collectError(errors)),
        loopB
            .runTurn(TurnInput(
                action: SpellCastAction(
                    spell: spell, targetHex: const HexCoord(2, 0))))
            .catchError(collectError(errors)),
      ]);

      // THE INVERSION: was `hasLength(2)` with the crossed 17/75 table.
      expect(errors, isEmpty);
      expect(_manaOf(stateA, 'player_a'), equals(75));
      expect(_manaOf(stateA, 'player_b'), equals(75));
      expect(_manaOf(stateB, 'player_a'), equals(75));
      expect(_manaOf(stateB, 'player_b'), equals(75));
      expect(stateA.toCanonicalBytes(), equals(stateB.toCanonicalBytes()));
    },
  );
}

/// Every [Minion] field `BattleState.toCanonicalBytes` hashes, as one
/// comparable value. Mirrors peer_summon_replication_test.dart's field-by-field
/// comparison — a creature that replicates with a divergent id, position, HP,
/// affinity, stat block, abilities, personality or size must not be able to
/// pass as identical.
Map<String, Object?> _minionFingerprint(Minion m) => {
      'id': m.id,
      'ownerId': m.ownerId,
      'teamId': m.teamId,
      'position.q': m.position.q,
      'position.r': m.position.r,
      'hp': m.hp,
      'affinity': m.affinity.name,
      'stats.maxHp': m.stats.maxHp,
      'stats.damage': m.stats.damage,
      'stats.moveSpeed': m.stats.moveSpeed,
      'stats.attackRange': m.stats.attackRange,
      'abilities': (m.abilities.map((a) => a.name).toList()..sort()).join(','),
      'personality': m.personality.name,
      'sizeBonus': m.sizeBonus,
      'isIllusion': m.isIllusion,
    };

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
