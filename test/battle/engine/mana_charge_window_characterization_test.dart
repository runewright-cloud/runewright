// SPDX-License-Identifier: GPL-3.0-or-later
//
// mana_charge_window_characterization_test.dart — M4.10b: the Phase 1 → Phase 5
// mana/HP charging window.
//
// A cast is charged in two different phases, and which one depends on WHOSE
// device is asking:
//
//   the caster's own device : TurnLoop._deductManaForCommittedSpell, Phase 1,
//                             the instant the action commit crosses the wire.
//   the opponent's device   : TurnLoop._verifyPeerSpellCast, Phase 5, once the
//                             reveal has been verified.
//
// Neither can move on its own (see M4.10), so for any single cast device A
// applies the deduction FOUR phases earlier than device B. Everything Phases
// 2–4b do to the caster's mana, HP or cost-relevant status effects therefore
// lands on opposite sides of that deduction on the two devices.
//
// M4.10 closed the one case that bit in ordinary play (move-phase Meditate,
// whose payout moved to Phase 5) and left the rest of the window open. These
// tests CHARACTERIZE what is still in it. They assert the divergence that
// exists today, with the intermediate numbers pinned, so a future fix inverts
// specific expectations rather than replacing the file:
//
//   1. Water haymaker status drain  → nextSpellCostDouble consumed on one
//      device, drained away on the other. (M4.10's hazard 1.)
//   2. Water haymaker status drain  → same, for chainSurcharge.
//   3. Lethal mana shortfall        → the caster is dead before Phase 4b's
//      isAlive gate on their own device and alive at it on the peer's, so one
//      device throws a punch the other does not. (M4.10's hazard 2.)
//   4. SlowTile mana drain          → NOT in M4.10's list. Ordinary terrain,
//      no status effects required, and it makes the two devices disagree about
//      whether the spell FIZZLED AT ALL.
//   5. Counter-charm gem destruction → maxMana shrinks mid-window and clamps
//      current mana, the same clamp-ordering shape as the original meditate
//      bug, arriving from the ceiling instead of the floor.
//
// Each hazard is paired with a control run that removes only the in-window
// mutation, to show the divergence is the window and not the fixture.
//
// See docs/M4_findings.md M4.10 ("Still open — the rest of the Phase 1 →
// Phase 5 window").

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

/// The cast used throughout: 3 supreme fire activations = 1 complete formula,
/// no residual, so `wireBaseManaCost` and `PeerCastVerifier.certifiedBaseManaCost`
/// agree exactly and nothing here is confounded by M4.9's effectCount gap.
///
///   base = 5×segmentCount + dotCount = 5×3 + 2 = 17
///   grown by 1.05^3 (effectCount 0)  = 19.68 → 20
const int _kBaseCost = 20;

void main() {
  group('M4.10b — Phase 1 → Phase 5 charging window', () {
    // ── Hazard 1: Water haymaker drains the cost-double ────────────────────
    group('water haymaker vs nextSpellCostDouble', () {
      test('the two devices charge different prices for the same cast',
          () async {
        final r = await _runPairedCastTurn(
          casterStatuses: [_costDouble(remainingTurns: 1)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerStatusDrain)],
          opponentMeleesCaster: true,
        );

        // The caster's own device priced at Phase 1, while the status was
        // still there: base × 2, and the entry consumed by the pricing.
        expect(r.a.casterMana, equals(_kStartMana - 2 * _kBaseCost),
            reason: 'caster device: charged the doubled price (40)');
        // The opponent's device drained the 1-turn status to 0 at Phase 4b —
        // applyHaymaker's hasHaymakerStatusDrain branch removes any effect that
        // hits zero — so certifiedManaCost at Phase 5 found nothing to double.
        expect(r.b.casterMana, equals(_kStartMana - _kBaseCost),
            reason: 'peer device: charged the single price (20)');

        expect(r.a.casterMana, isNot(equals(r.b.casterMana)));
        expect(r.canonicalMatches, isFalse);
        expect(r.error, _isStateHashMismatch);
      });

      test('control: no drain on the opponent, both devices charge double',
          () async {
        final r = await _runPairedCastTurn(
          casterStatuses: [_costDouble(remainingTurns: 1)],
          opponentStatuses: const [],
          opponentMeleesCaster: true,
        );
        expect(r.a.casterMana, equals(_kStartMana - 2 * _kBaseCost));
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.canonicalMatches, isTrue);
        expect(r.error, isNull);
      });

      test('control: 2 turns left survives the drain, both charge double',
          () async {
        // The drain takes 2 → 1 rather than 2 → 0, so the entry is still there
        // when Phase 5 prices it. This is what makes the hazard specifically a
        // ONE-turn-remaining hazard, and it is why it has never been seen in
        // play: the status is applied with remainingTurns 2 and only sits at 1
        // for a single turn.
        final r = await _runPairedCastTurn(
          casterStatuses: [_costDouble(remainingTurns: 2)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerStatusDrain)],
          opponentMeleesCaster: true,
        );
        expect(r.a.casterMana, equals(_kStartMana - 2 * _kBaseCost));
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── Hazard 1b: the same drain, applied to chainSurcharge ───────────────
    test('water haymaker vs chainSurcharge diverges the same way', () async {
      // chainSurcharge is the other consumable the pricing path reads, applied
      // with the same remainingTurns=2 (EffectApplicator, setAllChainsToNegative
      // potent branch), so it reaches 1 on exactly the same schedule.
      //
      //   surcharged : ceil(20 × 0.9^-1) = ceil(22.222…) = 23
      //   ordinary   : chainCostMultiplier with no chain = 1.0 → 20
      final r = await _runPairedCastTurn(
        casterStatuses: [
          StatusEffect(
              effectTypeId: StatusEffectId.chainSurcharge, remainingTurns: 1),
        ],
        opponentStatuses: [_haymaker(StatusEffectId.haymakerStatusDrain)],
        opponentMeleesCaster: true,
      );
      expect(r.a.casterMana, equals(_kStartMana - 23),
          reason: 'caster device: chain-surcharged price');
      expect(r.b.casterMana, equals(_kStartMana - _kBaseCost),
          reason: 'peer device: surcharge drained away before Phase 5');
      expect(r.canonicalMatches, isFalse);
    });

    // ── Hazard 2: lethal shortfall vs the melee isAlive gate ───────────────
    group('lethal mana shortfall vs the Phase 4b melee gate', () {
      // The shortfall→HP conversion is reachable ONLY through
      // nextSpellCostDouble: `hpDamage` is computed inside that branch in both
      // mirrors and is 0 everywhere else. Any other unaffordable cast fizzles.
      //
      //   mana 0, cost 20 × 2 = 40, shortfall 40
      //   hpDamage = ceil(40 / manaPerHp 10 × hpPerManaMissed 1) = 4
      //   hp 3 − 4 → dead
      test('one device throws a punch the other does not', () async {
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 3,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          // Earth haymaker: the punch leaves a `speedDown` on whoever it hits,
          // which is what makes "did this punch land" visible after HP has
          // clamped at 0. Chosen over the Fire flavour deliberately — the
          // marker id and the damage id are the same string for Fire
          // (`haymakerDot` is both "the attacker has the DoT haymaker" and
          // "the victim is burning"), so a Fire fixture burns its own holder
          // and muddies the arithmetic.
          opponentStatuses: [_haymaker(StatusEffectId.haymakerSlow)],
          opponentMeleesCaster: true,
        );

        // Caster's device: charged at Phase 1, died at Phase 1. By Phase 4b
        // applyHaymaker's `_avatarsAt` (which filters on isAlive) sees an empty
        // tile, so the punch lands on nobody.
        expect(r.a.casterAlive, isFalse);
        expect(r.a.casterStatusIds, isNot(contains(StatusEffectId.speedDown)),
            reason: 'caster device: dead before the gate, the punch missed');

        // Peer's device: the caster is still alive at Phase 4b (they are not
        // charged until Phase 5), so the punch lands and leaves its DoT.
        expect(r.b.casterAlive, isFalse, reason: 'dead by end of turn either way');
        expect(r.b.casterStatusIds, contains(StatusEffectId.speedDown),
            reason: 'peer device: alive at the gate, the punch landed');

        expect(r.canonicalMatches, isFalse);
        expect(r.error, _isStateHashMismatch);
      });

      test('control: a survivable shortfall is order-independent', () async {
        // hp 24 − 4 = 20, and the punch's 1 damage commutes with it because
        // neither device clamps and the isAlive gate never fires. This is the
        // precise boundary: the window is only observable when the shortfall
        // is LETHAL.
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 24,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerSlow)],
          opponentMeleesCaster: true,
        );
        expect(r.a.casterHp, equals(_kStartHp - 4 - 1));
        expect(r.b.casterHp, equals(r.a.casterHp));
        expect(r.a.casterStatusIds, contains(StatusEffectId.speedDown));
        expect(r.canonicalMatches, isTrue);
      });

      test(
          "the caster's OWN melee choice is not a divergence source", () async {
        // Worth pinning explicitly, because `meleeCandidates` gates on
        // isAlive too and looks like the same bug. It is not: a wizard's melee
        // target is commit-revealed from their own device, so a caster who is
        // dead at Phase 4b on their own device simply commits "no target" and
        // the peer reads that null off the wire. The asymmetry is entirely in
        // applyHaymaker's victim query, not in the prompt.
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 3,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          casterMeleesOpponent: true,
          opponentMeleesCaster: false,
        );
        expect(r.a.casterAlive, isFalse);
        expect(r.a.opponentHp, equals(_kStartHp),
            reason: 'caster device: dead, so meleeCandidates offered nothing');
        expect(r.b.opponentHp, equals(_kStartHp),
            reason: 'peer device: read the same "no target" off the wire');
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── Hazard 3 (NOT in M4.10's list): SlowTile mana drain ────────────────
    group('SlowTile mana drain', () {
      test('the two devices disagree about whether the cast fizzled at all',
          () async {
        // No status effects, no rare combination — just a caster who walks
        // across a Slow tile on the turn they cast, with mana near the price.
        //
        //   caster device : 25 − 20 (Phase 1) = 5, then − 10 drain → clamp 0
        //   peer device   : 25 − 10 drain (Phase 3) = 15, then Phase 5 prices
        //                   at 20 > 15 → fizzlesForMana → NOT CHARGED
        final r = await _runPairedCastTurn(
          casterMana: 25,
          slowTileOnPath: true,
        );

        expect(r.a.casterMana, equals(0),
            reason: 'caster device: charged, then drained into the floor clamp');
        expect(r.b.casterMana, equals(15),
            reason: 'peer device: drained, then the cast fizzled unpaid');

        // The mana totals are not the worst of it (M4.10's own words). The two
        // devices resolved COMPLETELY DIFFERENT TURNS.
        expect(r.a.opponentHp, equals(_kStartHp - 4),
            reason: 'caster device: the spell resolved and dealt damage');
        expect(r.b.opponentHp, equals(_kStartHp),
            reason: 'peer device: the spell fizzled, nothing resolved');
        expect(r.a.casterChainLengths, isNotEmpty,
            reason: 'caster device: the cast advanced the fire chain');
        expect(r.b.casterChainLengths, isEmpty,
            reason: 'peer device: a fizzled cast builds no chain');

        expect(r.canonicalMatches, isFalse);
        expect(r.error, _isStateHashMismatch);
      });

      test('control: the same walk with mana well clear of the price agrees',
          () async {
        // Both devices subtract the same two numbers; with no clamp and no
        // fizzle boundary crossed, subtraction commutes.
        final r = await _runPairedCastTurn(
          casterMana: 200,
          slowTileOnPath: true,
        );
        expect(r.a.casterMana, equals(200 - _kBaseCost - 10));
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── Hazard 4 (NOT in M4.10's list): counter-charm gem destruction ──────
    test('counter-charm gem destruction clamps mana on one side of the charge',
        () async {
      // A mana gem destroyed by the Phase 4b counter-charm proc shrinks
      // maxMana, and `_syncMaxMana` clamps current mana down to it. That is the
      // original M4.10 clamp-ordering bug arriving from the CEILING rather than
      // the floor, and it survives the meditate fix because the shrink happens
      // at Phase 4b, not Phase 2.
      //
      //   maxMana 200 (innate 100 + 1 gem × 100) → 100 once the gem dies
      //   caster device : 200 − 20 = 180, then clamp → 100
      //   peer device   : clamp 200 → 100, then − 20 = 80
      final r = await _runPairedCastTurn(
        casterMana: 200,
        casterMaxMana: 200,
        casterManaGems: 1,
        opponentCounterCharms: 20, // 20 × 5% ⇒ the proc is certain
        opponentMeleesCaster: true,
      );

      expect(r.a.casterMana, equals(100),
          reason: 'caster device: charged first, then clamped to the new ceiling');
      expect(r.b.casterMana, equals(80),
          reason: 'peer device: clamped first, then charged');
      expect(r.canonicalMatches, isFalse);
      expect(r.error, _isStateHashMismatch);
    });

    // ── The baseline the whole file is measured against ────────────────────
    test('control: an undisturbed window charges identically on both devices',
        () async {
      final r = await _runPairedCastTurn();
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      expect(r.b.casterMana, equals(r.a.casterMana));
      expect(r.canonicalMatches, isTrue);
      expect(r.error, isNull);
    });
  });
}

// ── Expectations ─────────────────────────────────────────────────────────────

final _isStateHashMismatch = isA<StateError>()
    .having((e) => e.message, 'message', contains('state hash mismatch'));

// ── Fixture ──────────────────────────────────────────────────────────────────

const _kSegmentCount = 3;
const _kDotCount = 2;
const _kStartMana = 500;
const _kStartHp = 24;

const _kCasterHome = HexCoord(0, 0);
const _kOpponentHome = HexCoord(1, 0);
/// Adjacent to both homes, so the caster can step onto it and still be punched.
const _kSlowTile = HexCoord(0, 1);

StatusEffect _costDouble({required int remainingTurns}) => StatusEffect(
      effectTypeId: StatusEffectId.nextSpellCostDouble,
      remainingTurns: remainingTurns,
      modifiers: const {
        'costMultiplier': 2,
        'hpPerManaMissed': 1,
        'manaPerHp': 10,
      },
    );

/// A haymaker-flavour status with a duration long enough that nothing in these
/// one-turn scenarios expires it.
StatusEffect _haymaker(String id) =>
    StatusEffect(effectTypeId: id, remainingTurns: 5);

/// What one device believes at the end of the turn.
typedef _Side = ({
  int casterMana,
  int casterHp,
  bool casterAlive,
  List<String> casterStatusIds,
  Map<SpellAffinity, int> casterChainLengths,
  int opponentHp,
});

typedef _PairedResult = ({
  _Side a, // the caster's own device: charges at Phase 1
  _Side b, // the opponent's device: charges at Phase 5
  bool canonicalMatches,
  Object? error,
});

/// Runs ONE turn on two genuinely separate [TurnLoop]s wired to each other by
/// [TurnSessionPair], with `player_a` casting and `player_b` passing.
///
/// `player_a` is the caster throughout, so device A (`state1`) is always the
/// side that charges at Phase 1 and device B (`state2`) the side that charges
/// at Phase 5. Every knob below places a mutation somewhere inside that window.
Future<_PairedResult> _runPairedCastTurn({
  int casterMana = _kStartMana,
  int casterHp = _kStartHp,
  int? casterMaxMana,
  int casterManaGems = 0,
  int opponentCounterCharms = 0,
  List<StatusEffect> casterStatuses = const [],
  List<StatusEffect> opponentStatuses = const [],
  bool opponentMeleesCaster = false,
  bool casterMeleesOpponent = false,
  bool slowTileOnPath = false,
}) async {
  // Two independently-constructed states, exactly as two phones would have.
  // The status effects are rebuilt per state rather than shared: StatusEffect
  // is mutable, and a shared instance would let one device's drain silently
  // edit the other's.
  BattleState build() {
    final s = _makeState(
      casterMana: casterMana,
      casterHp: casterHp,
      casterMaxMana: casterMaxMana ?? 999,
      casterManaGems: casterManaGems,
      opponentCounterCharms: opponentCounterCharms,
    );
    for (final fx in casterStatuses) {
      _av(s, 'player_a').activeStatusEffects.add(_copy(fx));
    }
    for (final fx in opponentStatuses) {
      _av(s, 'player_b').activeStatusEffects.add(_copy(fx));
    }
    if (slowTileOnPath) {
      // extraMoveCost 0 so the single step is affordable on the default speed;
      // the drain is the only thing under test.
      s.tileEffects[_kSlowTile] =
          const SlowTile(extraMoveCost: 0, manaDrainOnEntry: 10);
    }
    return s;
  }

  final state1 = build();
  final state2 = build();

  final pair = TurnSessionPair();
  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  final loop1 = TurnLoop(
    state: state1,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    meleeTargetPicker: (_) async =>
        casterMeleesOpponent ? _kOpponentHome : null,
  );
  final loop2 = TurnLoop(
    state: state2,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    // The caster's tile, wherever it ended up: the melee target is committed
    // after movement, so a caster who stepped onto the slow tile is punched
    // there.
    meleeTargetPicker: (candidates) async =>
        opponentMeleesCaster ? candidates.first : null,
  );

  final spell = _fireSpell();
  loop1.localChapterCommitments = [spell.commitmentHex];

  Object? error;
  try {
    await Future.wait([
      loop1.runTurn(TurnInput(
        action: SpellCastAction(spell: spell, targetHex: _kOpponentHome),
        movePath: slowTileOnPath ? const [_kSlowTile] : const [],
      )),
      loop2.runTurn(TurnInput(action: PassAction())),
    ], eagerError: false).timeout(const Duration(seconds: 20));
  } catch (e) {
    error = e;
  }

  _Side sideOf(BattleState s) {
    final caster = _av(s, 'player_a');
    return (
      casterMana: caster.mana,
      casterHp: caster.hp,
      casterAlive: caster.isAlive,
      casterStatusIds:
          caster.activeStatusEffects.map((fx) => fx.effectTypeId).toList(),
      casterChainLengths: Map.of(caster.chainLengths),
      opponentHp: _av(s, 'player_b').hp,
    );
  }

  return (
    a: sideOf(state1),
    b: sideOf(state2),
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
    error: error,
  );
}

StatusEffect _copy(StatusEffect fx) => StatusEffect(
      effectTypeId: fx.effectTypeId,
      remainingTurns: fx.remainingTurns,
      modifiers: Map.of(fx.modifiers),
      isDormant: fx.isDormant,
    );

WizardAvatar _av(BattleState s, String id) =>
    s.avatars.firstWhere((a) => a.playerId == id);

/// 3 supreme fire activations: 1 complete formula, no residual. See [_kBaseCost].
SpellAsset _fireSpell() {
  const activations = 3;
  const t = activations;
  final tier = tierForSteps(t)!;
  final commitmentBytes = Uint8List.fromList(List.filled(32, 0xab));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  return SpellAsset(
    id: 'window-ember',
    createdAt: DateTime.utc(2026, 8, 19),
    tier: tier,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: _kBaseCost,
    segmentCount: _kSegmentCount,
    dotCount: _kDotCount,
    initialGrid: const [],
    proofBytes: _syntheticProof(tier: tier, t: t, commitmentBytes: commitmentBytes),
    name: 'Window Ember',
    commitmentHex: commitmentHex,
    spellHashHex: '',
    formula: List.filled(activations, 'fire'),
  );
}

/// `[4 BE bytes: field count N][N × 32-byte fields][proof body]` — the wire
/// shape ProofIntake parses. Same layout the other paired-session fixtures use;
/// see mana_cost_lockstep_test.dart for the field map.
Uint8List _syntheticProof({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);
  void setField(int i, int v) => data.setUint32(4 + i * 32 + 28, v, Endian.big);

  data.setUint32(0, count, Endian.big);
  setField(0, t);
  setField(2, 3); // ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes);
  for (var gen = 0; gen < t; gen++) {
    setField(8 + gen, 1); // fire dominance
    setField(8 + tier + gen, 1); // supreme → one activation per generation
  }
  setField(8 + 2 * tier, _kSegmentCount);
  setField(8 + 2 * tier + 1, _kDotCount);
  return bytes;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

BattleState _makeState({
  required int casterMana,
  required int casterHp,
  required int casterMaxMana,
  required int casterManaGems,
  required int opponentCounterCharms,
}) {
  final battlefield = Battlefield();
  battlefield.occupancy['player_a'] = _kCasterHome;
  battlefield.occupancy['player_b'] = _kOpponentHome;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: casterHp,
        mana: casterMana,
        maxMana: casterMaxMana,
        position: _kCasterHome,
        teamId: 'team_a',
        baseSpellRange: 3,
        accoutrements: [
          for (var i = 0; i < casterManaGems; i++)
            Accoutrement(id: 'gem_$i', kind: AccoutrementKind.manaGem),
        ],
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'11' * 32}',
        hp: _kStartHp,
        mana: _kStartMana,
        maxMana: 999,
        position: _kOpponentHome,
        teamId: 'team_b',
        baseSpellRange: 3,
        accoutrements: [
          // Unattuned (charmTrajectory null): they can never fire a counter, so
          // they stay unspent and feed the melee proc at a flat 5% each.
          for (var i = 0; i < opponentCounterCharms; i++)
            Accoutrement(id: 'charm_$i', kind: AccoutrementKind.counterCharm),
        ],
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
