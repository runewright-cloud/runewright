// SPDX-License-Identifier: GPL-3.0-or-later
//
// mana_charge_window_characterization_test.dart — M4.10b: canonical Phase-5
// spell-cost settlement.
//
// ## The rule this file enforces
//
//   A committed spell does not reserve mana or cost modifiers. Both players'
//   ordinary committed casts are priced and settled from the replicated game
//   state that exists at the START OF PHASE 5, in ascending playerId order,
//   before _applyMoveMeditations and before any other Phase-5 resource
//   mutation.
//
// It replaces the asymmetric rule these tests were originally written to
// characterize: each device charged its OWN player's cast at Phase 1
// (`_deductManaForCommittedSpell`) and the peer's at Phase 5
// (`_verifyPeerSpellCast`), four phases apart. Everything Phases 2–4b did to a
// caster's mana, HP or cost-relevant statuses therefore landed on opposite
// sides of the deduction on the two devices.
//
// ## What changed in this file, and what did not
//
// The five divergence cases below are the SAME fixtures that reproduced the bug
// (see the M4.10b section of docs/M4_findings.md, and this file's history at
// the characterization commit). Their intermediate values are still pinned; the
// expectations were inverted, from "the two devices disagree, here is each
// number" to "the two devices agree, here is the one number". Reading them
// against the findings table shows exactly which side of each old divergence
// the new rule adopted — in every case, the LATE one:
//
//   | hazard                     | old caster device | old peer device | now  |
//   |----------------------------|-------------------|-----------------|------|
//   | nextSpellCostDouble drain  | 40 charged        | 20 charged      | 20   |
//   | chainSurcharge drain       | 23 charged        | 20 charged      | 20   |
//   | lethal shortfall vs melee  | punch missed      | punch landed    | lands|
//   | SlowTile drain             | resolved, mana 0  | fizzled, mana 15| 15   |
//   | gem destruction clamp      | mana 100          | mana 80         | 80   |
//
// The six controls are unchanged in purpose: each removes only the in-window
// mutation and shows the hazard goes with it. They passed before the fix and
// pass after, which is what makes them controls rather than regressions.

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
  group('M4.10b — canonical Phase-5 cast settlement', () {
    // ── 1. Water haymaker drains the cost-double ───────────────────────────
    group('water haymaker vs nextSpellCostDouble', () {
      test('both devices charge the post-haymaker live price', () async {
        final r = await _runPairedCastTurn(
          casterStatuses: [_costDouble(remainingTurns: 1)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerStatusDrain)],
          opponentMeleesCaster: true,
        );

        // The Phase-4b drain takes the 1-turn status to 0 and removes it
        // (applyHaymaker's hasHaymakerStatusDrain branch). Settlement runs at
        // Phase 5, after that, so there is nothing left to double — on BOTH
        // devices. Before the fix the caster's own device had already priced at
        // Phase 1 with the status present and charged 40.
        expect(r.a.casterMana, equals(_kStartMana - _kBaseCost),
            reason: 'single price: the curse was punched off before settlement');
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.a.casterStatusIds,
            isNot(contains(StatusEffectId.nextSpellCostDouble)));
        expect(r.canonicalMatches, isTrue);
        expect(r.error, isNull);
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
      });

      test('control: 2 turns left survives the drain, both charge double',
          () async {
        // The drain takes 2 → 1 rather than 2 → 0, so the entry is still there
        // when Phase 5 prices it. This is what makes the hazard specifically a
        // ONE-turn-remaining hazard: the status is applied with remainingTurns
        // 2 and only sits at 1 for a single turn.
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

    // ── 2. The same drain, applied to chainSurcharge ───────────────────────
    test('water haymaker vs chainSurcharge settles the same way', () async {
      // chainSurcharge is the other consumable the pricing path reads, applied
      // with the same remainingTurns=2 (EffectApplicator's
      // setAllChainsToNegative potent branch), so it reaches 1 on exactly the
      // same schedule.
      //
      //   surcharged (old caster device) : ceil(20 × 0.9⁻¹) = ceil(22.222…) = 23
      //   ordinary   (now, both devices) : chainCostMultiplier, no chain → 20
      final r = await _runPairedCastTurn(
        casterStatuses: [_surcharge(remainingTurns: 1)],
        opponentStatuses: [_haymaker(StatusEffectId.haymakerStatusDrain)],
        opponentMeleesCaster: true,
      );
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost),
          reason: 'the surcharge was drained away before settlement priced it');
      expect(r.b.casterMana, equals(r.a.casterMana));
      expect(r.a.casterStatusIds, isNot(contains(StatusEffectId.chainSurcharge)));
      expect(r.canonicalMatches, isTrue);
    });

    // ── 3. Lethal shortfall vs the Phase 4b melee round ────────────────────
    group('lethal mana shortfall', () {
      // The shortfall→HP conversion is reachable ONLY through
      // nextSpellCostDouble: `hpDamage` is computed inside that branch in both
      // pricing mirrors and is 0 everywhere else. M4.10b deliberately did not
      // broaden that; these tests pin it as-is.
      //
      //   mana 0, cost 20 × 2 = 40, shortfall 40
      //   hpDamage = ceil(40 / manaPerHp 10 × hpPerManaMissed 1) = 4
      //   hp 3 − 1 (the punch) − 4 → dead
      test('the melee round completes before the caster dies paying', () async {
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 3,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          // Earth haymaker: the punch leaves a `speedDown` on whoever it hits,
          // which is what makes "did this punch land" visible after HP has
          // clamped at 0. Chosen over the Fire flavour deliberately — for Fire
          // the attacker's marker id and the victim's damage id are the same
          // string (`haymakerDot`), so a Fire fixture burns its own holder and
          // muddies the arithmetic.
          opponentStatuses: [_haymaker(StatusEffectId.haymakerSlow)],
          opponentMeleesCaster: true,
        );

        // The caster is alive throughout Phase 4b on BOTH devices now, because
        // nothing has charged them yet. Before the fix their own device had
        // killed them at Phase 1, applyHaymaker's `_avatarsAt` (which filters
        // on isAlive) saw an empty tile, and one device threw a punch the other
        // did not.
        expect(r.a.casterStatusIds, contains(StatusEffectId.speedDown),
            reason: 'the punch landed: the caster was alive at the melee gate');
        expect(r.b.casterStatusIds, equals(r.a.casterStatusIds));
        expect(r.a.casterAlive, isFalse, reason: 'then the payment killed them');
        expect(r.b.casterAlive, isFalse);
        expect(r.canonicalMatches, isTrue);
        expect(r.error, isNull);
      });

      test('a caster killed by their own payment still does not land the cast',
          () async {
        // Cast-resolution semantics for a lethal shortfall are UNCHANGED by
        // M4.10b and are pinned here so they cannot drift accidentally. Under
        // the old rule this was already what both devices did — the charge
        // preceded `_resolveActions` on each of them, just at different phases
        // — so the fix moved when the caster dies, not what their death does to
        // the spell.
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 3,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerSlow)],
          opponentMeleesCaster: true,
        );
        expect(r.a.casterAlive, isFalse);
        expect(r.a.opponentHp, equals(_kStartHp),
            reason: 'the spell did not resolve');
        expect(r.a.casterChainLengths, isEmpty,
            reason: 'and it built no chain');
        expect(r.b.opponentHp, equals(r.a.opponentHp));
        expect(r.b.casterChainLengths, equals(r.a.casterChainLengths));
        expect(r.canonicalMatches, isTrue);
      });

      test('control: a survivable shortfall is order-independent', () async {
        // 24 − 4 (shortfall) − 1 (punch) = 19, and the two commute because
        // neither device clamps. This was the precise boundary before the fix:
        // the window was observable only when the shortfall was LETHAL. It
        // still passes, unchanged, which is what makes it a control.
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: _kStartHp,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          opponentStatuses: [_haymaker(StatusEffectId.haymakerSlow)],
          opponentMeleesCaster: true,
        );
        expect(r.a.casterHp, equals(_kStartHp - 4 - 1));
        expect(r.b.casterHp, equals(r.a.casterHp));
        expect(r.a.casterStatusIds, contains(StatusEffectId.speedDown));
        expect(r.a.opponentHp, equals(_kStartHp - 4),
            reason: 'a survivor lands their cast');
        expect(r.canonicalMatches, isTrue);
      });

      test("the caster's own melee choice is never device-relative", () async {
        // Kept from the characterization suite, where it ruled out a
        // false lead: `meleeCandidates` gates on isAlive too and looks like the
        // same bug. It is not — a wizard's melee target is commit-revealed from
        // their own device, so whatever they chose is what both devices read.
        //
        // Under the new rule it also demonstrates the ordering directly: the
        // caster is alive at Phase 4b, throws their punch, and only then dies
        // paying for the cast. Before the fix their own device had already
        // killed them and offered them no target at all.
        final r = await _runPairedCastTurn(
          casterMana: 0,
          casterHp: 3,
          casterStatuses: [_costDouble(remainingTurns: 2)],
          casterMeleesOpponent: true,
        );
        expect(r.a.opponentHp, equals(_kStartHp - 1),
            reason: 'the dying caster got their punch in first');
        expect(r.b.opponentHp, equals(r.a.opponentHp));
        expect(r.a.casterAlive, isFalse);
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── 4. SlowTile mana drain ─────────────────────────────────────────────
    group('SlowTile mana drain', () {
      test('both devices see the drained pool and both fizzle', () async {
        // The status-free demonstration of the whole rule. No rare combination:
        // a caster walks across a Slow tile on the turn they cast, with mana
        // near the price.
        //
        //   25 − 10 drain (Phase 3) = 15, then Phase 5 prices at 20 > 15
        //   → fizzlesForMana on both devices → NOT CHARGED
        //
        // Before the fix the caster's own device had charged at Phase 1
        // (25 − 20 = 5, then − 10 → clamped to 0) and RESOLVED the spell, while
        // the peer's fizzled it. The two devices played different turns.
        final r = await _runPairedCastTurn(
          casterMana: 25,
          slowTileOnPath: true,
        );

        expect(r.a.casterMana, equals(15),
            reason: 'drained, then unaffordable, so never charged');
        expect(r.b.casterMana, equals(r.a.casterMana));

        // The fizzle is total and identical: no effects, no chain, no damage.
        expect(r.a.opponentHp, equals(_kStartHp));
        expect(r.b.opponentHp, equals(_kStartHp));
        expect(r.a.casterChainLengths, isEmpty);
        expect(r.b.casterChainLengths, isEmpty);
        expect(r.canonicalMatches, isTrue);
        expect(r.error, isNull, reason: 'a fizzle is not a forfeit path');
      });

      test('control: the same walk with mana well clear of the price agrees',
          () async {
        // Both devices subtract the same two numbers; with no clamp reached and
        // no fizzle boundary crossed, subtraction commutes — which is why this
        // one passed before the fix too.
        final r = await _runPairedCastTurn(
          casterMana: 200,
          slowTileOnPath: true,
        );
        expect(r.a.casterMana, equals(200 - _kBaseCost - 10));
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.a.opponentHp, equals(_kStartHp - 4),
            reason: 'an affordable cast still resolves');
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── 5. Counter-charm gem destruction ───────────────────────────────────
    test('gem destruction clamps maxMana before either device charges',
        () async {
      // A mana gem destroyed by the Phase 4b counter-charm proc shrinks
      // maxMana, and `_syncMaxMana` clamps current mana down to it. That was
      // M4.10's original clamp-ordering bug arriving from the CEILING rather
      // than the floor, and it survived the meditate fix because the shrink
      // happens at Phase 4b, not Phase 2.
      //
      //   maxMana 200 (innate 100 + 1 gem × 100) → 100 once the gem dies
      //   both devices now: clamp 200 → 100, then − 20 = 80
      //   (the caster's own device used to charge first: 200 − 20 = 180 → 100)
      final r = await _runPairedCastTurn(
        casterMana: 200,
        casterMaxMana: 200,
        casterManaGems: 1,
        opponentCounterCharms: 20, // 20 × 5% ⇒ the proc is certain
        opponentMeleesCaster: true,
      );

      expect(r.a.casterMana, equals(100 - _kBaseCost),
          reason: 'clamped to the new ceiling first, then charged');
      expect(r.b.casterMana, equals(r.a.casterMana));
      expect(r.canonicalMatches, isTrue);
      expect(r.error, isNull);
    });

    // ── Move-phase Meditate stays behind settlement ────────────────────────
    group('move-phase Meditate cannot fund this turn\'s cast', () {
      test('a cast unaffordable at settlement fizzles despite meditating',
          () async {
        // M4.10 moved the meditate payout to Phase 5 to fix a clamp-ordering
        // desync, and ruled that a move-Meditate must not fund the same turn's
        // spell. M4.10b moves the charge into the same phase, so the two are now
        // adjacent and their ORDER is the whole ruling: settlement first,
        // meditation after.
        //
        //   mana 15 < price 20 → fizzle at settlement
        //   then +25 meditate  → 40, on both devices
        final r = await _runPairedCastTurn(
          casterMana: 15,
          casterMeditatesInMove: true,
        );
        expect(r.a.casterMana, equals(15 + 25),
            reason: 'meditation paid out, but after the cast had already failed');
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.a.opponentHp, equals(_kStartHp),
            reason: 'the cast fizzled: the meditation did not rescue it');
        expect(r.a.casterChainLengths, isEmpty);
        expect(r.canonicalMatches, isTrue);
      });

      test('a cast made unaffordable INSIDE the window is not rescued either',
          () async {
        // The sharper version, only reachable under the new rule: the caster
        // could afford the cast when they committed it and cannot by Phase 5,
        // because the Phase-4b counter-charm proc destroyed the gem holding up
        // their pool. Meditation still cannot save it.
        //
        //   innate pool 10, one gem ⇒ maxMana 110, mana 110
        //   gem destroyed at Phase 4b ⇒ maxMana 10, mana clamped 110 → 10
        //   settlement: 20 > 10 → fizzle
        //   meditation: +25, clamped back to maxMana 10
        final r = await _runPairedCastTurn(
          casterMana: 110,
          casterMaxMana: 110,
          casterManaGems: 1,
          innateManaPool: 10,
          opponentCounterCharms: 20,
          opponentMeleesCaster: true,
          casterMeditatesInMove: true,
        );
        expect(r.a.casterMana, equals(10),
            reason: 'clamped to the shrunken ceiling; the +25 has nowhere to go');
        expect(r.b.casterMana, equals(r.a.casterMana));
        expect(r.a.opponentHp, equals(_kStartHp), reason: 'fizzled');
        expect(r.a.casterChainLengths, isEmpty);
        expect(r.canonicalMatches, isTrue);
      });
    });

    // ── Both players cast: the sorted settlement path ──────────────────────
    test('two simultaneous casts settle in canonical playerId order', () async {
      // Exercises the branch where the settlement list holds TWO entries, on
      // both devices at once. Device A's list is built local-then-peer and
      // device B's peer-then-local; both sort to [player_a, player_b].
      //
      // The order is deliberately not observable in the resulting state, and
      // that is an audited property rather than an accident: each settlement
      // reads and writes only its own avatar's mana, statuses, chain and HP,
      // and the one cross-player mana link that exists (a Reflections
      // manaMirror) lives in applyManaGain, which is gain-only and not on this
      // path. So what this pins is that the two-cast path produces identical
      // canonical state on both devices and charges each caster once. See
      // TurnLoop._settleCommittedCasts on why the sort is fixed anyway.
      final r = await _runPairedCastTurn(opponentAlsoCasts: true);

      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      expect(r.a.opponentMana, equals(_kStartMana - _kBaseCost));
      expect(r.b.casterMana, equals(r.a.casterMana));
      expect(r.b.opponentMana, equals(r.a.opponentMana));
      // Both casts landed: each wizard took the other's spell.
      expect(r.a.casterHp, lessThan(_kStartHp));
      expect(r.a.opponentHp, lessThan(_kStartHp));
      expect(r.canonicalMatches, isTrue);
      expect(r.error, isNull);
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

StatusEffect _surcharge({required int remainingTurns}) => StatusEffect(
      effectTypeId: StatusEffectId.chainSurcharge,
      remainingTurns: remainingTurns,
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
  int opponentMana,
  int opponentHp,
});

typedef _PairedResult = ({
  _Side a, // player_a's own device
  _Side b, // player_b's device
  bool canonicalMatches,
  Object? error,
});

/// Runs ONE turn on two genuinely separate [TurnLoop]s wired to each other by
/// [TurnSessionPair], with `player_a` casting and `player_b` passing (or, with
/// [opponentAlsoCasts], casting back).
///
/// `player_a` is the caster throughout, so device A (`state1`) is the side that
/// used to charge at Phase 1 and device B (`state2`) the side that used to
/// charge at Phase 5. Every knob below places a mutation somewhere inside that
/// old window.
Future<_PairedResult> _runPairedCastTurn({
  int casterMana = _kStartMana,
  int casterHp = _kStartHp,
  int? casterMaxMana,
  int casterManaGems = 0,
  int? innateManaPool,
  int opponentCounterCharms = 0,
  List<StatusEffect> casterStatuses = const [],
  List<StatusEffect> opponentStatuses = const [],
  bool opponentMeleesCaster = false,
  bool casterMeleesOpponent = false,
  bool slowTileOnPath = false,
  bool casterMeditatesInMove = false,
  bool opponentAlsoCasts = false,
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
      innateManaPool: innateManaPool,
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

  final casterSpell = _fireSpell(id: 'window-ember-a', commitmentFill: 0xab);
  loop1.localChapterCommitments = [casterSpell.commitmentHex];

  // A DISTINCT commitment for the opponent's spell: certifiedPeerCasts is keyed
  // by commitmentHex, and the commitment is grid-only, so two casts of the same
  // grid in one turn would collide there.
  final opponentSpell = _fireSpell(id: 'window-ember-b', commitmentFill: 0xcd);
  if (opponentAlsoCasts) {
    loop2.localChapterCommitments = [opponentSpell.commitmentHex];
  }

  Object? error;
  try {
    await Future.wait([
      loop1.runTurn(TurnInput(
        action: SpellCastAction(spell: casterSpell, targetHex: _kOpponentHome),
        movePath: slowTileOnPath ? const [_kSlowTile] : const [],
        meditateInMove: casterMeditatesInMove,
      )),
      loop2.runTurn(TurnInput(
        action: opponentAlsoCasts
            ? SpellCastAction(spell: opponentSpell, targetHex: _kCasterHome)
            : PassAction(),
      )),
    ], eagerError: false).timeout(const Duration(seconds: 20));
  } catch (e) {
    error = e;
  }

  _Side sideOf(BattleState s) {
    final caster = _av(s, 'player_a');
    final opponent = _av(s, 'player_b');
    return (
      casterMana: caster.mana,
      casterHp: caster.hp,
      casterAlive: caster.isAlive,
      casterStatusIds:
          caster.activeStatusEffects.map((fx) => fx.effectTypeId).toList(),
      casterChainLengths: Map.of(caster.chainLengths),
      opponentMana: opponent.mana,
      opponentHp: opponent.hp,
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
SpellAsset _fireSpell({required String id, required int commitmentFill}) {
  const activations = 3;
  const t = activations;
  final tier = tierForSteps(t)!;
  final commitmentBytes = Uint8List.fromList(List.filled(32, commitmentFill));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 19),
    tier: tier,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: _kBaseCost,
    segmentCount: _kSegmentCount,
    dotCount: _kDotCount,
    initialGrid: const [],
    proofBytes:
        _syntheticProof(tier: tier, t: t, commitmentBytes: commitmentBytes),
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
  required int? innateManaPool,
  required int opponentCounterCharms,
}) {
  final battlefield = Battlefield();
  battlefield.occupancy['player_a'] = _kCasterHome;
  battlefield.occupancy['player_b'] = _kOpponentHome;

  return BattleState(
    // innateManaPool is only ever lowered, and only by the tests that need a
    // gem destruction to actually push a caster below a spell's price — the
    // default 100 pool swallows it otherwise.
    config: innateManaPool == null
        ? const MatchConfig()
        : MatchConfig(innateManaPool: innateManaPool),
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
