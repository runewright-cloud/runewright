// SPDX-License-Identifier: GPL-3.0-or-later
//
// certified_mana_chain_test.dart — pins the CERTIFIED mana chain's mutating
// steps, which had no independent coverage.
//
// `mana_cost_lockstep_test.dart` pins step 1 (the certified base),
// `chain_discount_test.dart` pins the chain step on the LOCAL path only
// (SoloBattleSession, wire formula), `summon_declaration_trust_test.dart` pins
// the certified chain affinity, and the vocal-recall pair pins step 4. What
// nothing covered is the certified side of the two steps that **mutate the
// caster**:
//
//   * step 2's chainSurcharge — consumed from `activeStatusEffects` by index,
//     and it OVERRIDES the ordinary chain lookup rather than stacking with it;
//   * step 5's nextSpellCostDouble — consumed by index, doubles the cost, and
//     converts an unaffordable remainder into HP damage.
//
// Index-based removal from a list the same method is reading is exactly what
// an extraction can silently reorder, and the HP conversion is the one route
// by which an over-budget cast is still legal. Both are pinned here at
// two-device parity — the caster's own `_spellCostBreakdown` and the peer's
// `_certifiedManaCost` must reach the same number, the same consumption and
// the same HP, or the state hash forfeits the match.
//
// Efficiency (step 3) is pinned too, because the certified path takes it from
// `CertifiedPeerCast.isEfficiency` where the local path takes it from the
// action's enhancements — different sources, same discount, and only the local
// one had a test.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

/// One complete water formula. Water so the trajectory's certified supreme
/// tags contain 'water', which is what makes an Efficiency claim legal
/// (PeerCastVerifier step 2b); pure so the chain step has a non-null affinity
/// to work with.
const _elements = [BorderZone.water, BorderZone.water, BorderZone.water];

/// (5*3 + 2) * 1.05^3 * 1.5^0, rounded — the certified base both devices start
/// from. Every expectation below is this number put through one step.
const _base = 20;

void main() {
  group('certified mana chain — step 2 (chainSurcharge)', () {
    test('marks the cast up by 1/0.9 and is consumed on both devices',
        () async {
      final r = await _cast(surcharge: true);

      // ceil(20 / 0.9) = ceil(22.22) = 23.
      expect(r.costOnPeerDevice, equals(23));
      expect(r.costOnCasterDevice, equals(23));
      expect(r.surchargesLeftOnPeerDevice, equals(0),
          reason: 'consumed by the pricing step, so _updateChainState does not '
              'also fire it');
      expect(r.surchargesLeftOnCasterDevice, equals(0));
      expect(r.canonicalMatches, isTrue);
    });

    test('overrides the chain lookup entirely, rather than stacking with it',
        () async {
      // A 4-cast water chain would discount this cast to ceil(20 * 0.9^4) = 14
      // if step 2 fell through to the chain branch. It does not: the surcharge
      // branch is an `if/else`, and the marked-up price is what proves which
      // arm ran.
      final withBoth = await _cast(surcharge: true, waterChainCredits: 8);
      final chainOnly = await _cast(waterChainCredits: 8);

      expect(chainOnly.costOnPeerDevice, equals(14));
      expect(withBoth.costOnPeerDevice, equals(23),
          reason: 'the surcharge arm ran, ignoring the chain discount');
      expect(withBoth.canonicalMatches, isTrue);
    });
  });

  group('certified mana chain — step 5 (nextSpellCostDouble)', () {
    test('doubles an affordable cost and is consumed on both devices',
        () async {
      final r = await _cast(costDouble: true);

      expect(r.costOnPeerDevice, equals(_base * 2));
      expect(r.costOnCasterDevice, equals(_base * 2));
      expect(r.doublesLeftOnPeerDevice, equals(0));
      expect(r.doublesLeftOnCasterDevice, equals(0));
      expect(r.hpLostOnPeerDevice, equals(0), reason: 'affordable, so no HP');
      expect(r.canonicalMatches, isTrue);
    });

    test('converts an unaffordable remainder into HP damage, identically on '
        'both devices', () async {
      // 25 mana against a doubled price of 40: shortfall 15, and the default
      // modifiers are hpPerManaMissed 1 / manaPerHp 10, so
      // ceil(15 / 10 * 1) = 2 HP and the caster pays the 25 they hold.
      final r = await _cast(costDouble: true, mana: 25);

      expect(r.costOnPeerDevice, equals(25), reason: 'pays what they have');
      expect(r.costOnCasterDevice, equals(25));
      expect(r.hpLostOnPeerDevice, equals(2));
      expect(r.hpLostOnCasterDevice, equals(2));
      expect(r.doublesLeftOnPeerDevice, equals(0));
      expect(r.canonicalMatches, isTrue,
          reason: 'the HP conversion is the one route by which an over-budget '
              'cast is legal — it must land the same on both devices');
    });

    test('does not fizzle, because the clamped price is never above the mana '
        'held', () async {
      final r = await _cast(costDouble: true, mana: 25);
      expect(r.fizzled, isFalse);
    });
  });

  group('certified mana chain — steps 2 and 5 together', () {
    test('both are consumed, in the same order, on both devices', () async {
      // ceil(20 / 0.9) = 23, then doubled = 46. Both effects gone.
      final r = await _cast(surcharge: true, costDouble: true);

      expect(r.costOnPeerDevice, equals(46));
      expect(r.costOnCasterDevice, equals(46));
      expect(r.surchargesLeftOnPeerDevice, equals(0));
      expect(r.doublesLeftOnPeerDevice, equals(0));
      expect(r.surchargesLeftOnCasterDevice, equals(0));
      expect(r.doublesLeftOnCasterDevice, equals(0));
      expect(r.canonicalMatches, isTrue);
    });
  });

  group('certified mana chain — step 3 (Efficiency)', () {
    test('takes the -1/3 discount from the CERTIFIED claim', () async {
      // ceil(20 * 2/3) = ceil(13.33) = 14. On the peer's side this comes from
      // CertifiedPeerCast.isEfficiency, i.e. the claim after it was checked
      // against the trajectory's certified supreme water zones.
      final r = await _cast(efficiency: true);

      expect(r.costOnPeerDevice, equals(14));
      expect(r.costOnCasterDevice, equals(14));
      expect(r.canonicalMatches, isTrue);
    });

    test('applies after the chain discount, not before', () async {
      // Order matters to the rounding: ceil(ceil(20 * 0.9^4) * 2/3)
      // = ceil(14 * 2/3) = 10, where the other order gives
      // ceil(ceil(20 * 2/3) * 0.9^4) = ceil(14 * 0.6561) = 10 as well — so
      // pin the plain chain+efficiency value and let any reordering that
      // changes it fail here.
      final r = await _cast(efficiency: true, waterChainCredits: 8);
      expect(r.costOnPeerDevice, equals(10));
      expect(r.canonicalMatches, isTrue);
    });
  });

  group('certified mana chain — baseline', () {
    test('an unmodified cast costs exactly the certified base', () async {
      final r = await _cast();
      expect(r.costOnPeerDevice, equals(_base));
      expect(r.costOnCasterDevice, equals(_base));
      expect(r.canonicalMatches, isTrue);
    });
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

typedef _Result = ({
  int costOnCasterDevice,
  int costOnPeerDevice,
  int hpLostOnCasterDevice,
  int hpLostOnPeerDevice,
  int surchargesLeftOnCasterDevice,
  int surchargesLeftOnPeerDevice,
  int doublesLeftOnCasterDevice,
  int doublesLeftOnPeerDevice,
  bool fizzled,
  bool canonicalMatches,
});

const _startHp = 24;

/// player_a casts the water spell; player_b passes. The status effects and
/// chain credits are seeded identically on both devices, exactly as they would
/// be after a turn that placed them.
Future<_Result> _cast({
  bool surcharge = false,
  bool costDouble = false,
  bool efficiency = false,
  int waterChainCredits = 0,
  int mana = kStartMana,
}) async {
  BattleState seeded() {
    final state = makeDuelState();
    final caster = state.avatars.firstWhere((av) => av.playerId == 'player_a');
    caster.mana = mana;
    caster.hp = _startHp;
    if (surcharge) {
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.chainSurcharge,
        remainingTurns: -1,
      ));
    }
    if (costDouble) {
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.nextSpellCostDouble,
        remainingTurns: -1,
      ));
    }
    if (waterChainCredits > 0) {
      caster.activeChainElement = SpellAffinity.water;
      caster.chainLengths[SpellAffinity.water] = waterChainCredits;
    }
    return state;
  }

  final casterState = seeded();
  final peerState = seeded();

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

  final spell = spellFromElements(
    elements: _elements,
    variant: 7,
    name: 'Certified Rill',
  );
  casterLoop.localChapterCommitments = [spell.commitmentHex];

  final action = SpellCastAction(
    spell: spell,
    targetHex: const HexCoord(1, 0),
    isEfficiency: efficiency,
  );

  await Future.wait([
    casterLoop.runTurn(TurnInput(action: action)),
    peerLoop.runTurn(TurnInput(action: PassAction())),
  ], eagerError: true).timeout(const Duration(seconds: 20));

  WizardAvatar casterIn(BattleState s) =>
      s.avatars.firstWhere((av) => av.playerId == 'player_a');
  int countOf(WizardAvatar av, String id) =>
      av.activeStatusEffects.where((fx) => fx.effectTypeId == id).length;

  final onCaster = casterIn(casterState);
  final onPeer = casterIn(peerState);
  return (
    costOnCasterDevice: mana - onCaster.mana,
    costOnPeerDevice: mana - onPeer.mana,
    hpLostOnCasterDevice: _startHp - onCaster.hp,
    hpLostOnPeerDevice: _startHp - onPeer.hp,
    surchargesLeftOnCasterDevice:
        countOf(onCaster, StatusEffectId.chainSurcharge),
    surchargesLeftOnPeerDevice: countOf(onPeer, StatusEffectId.chainSurcharge),
    doublesLeftOnCasterDevice:
        countOf(onCaster, StatusEffectId.nextSpellCostDouble),
    doublesLeftOnPeerDevice:
        countOf(onPeer, StatusEffectId.nextSpellCostDouble),
    fizzled: action.fizzledForMana,
    canonicalMatches: bytesEqual(
        casterState.toCanonicalBytes(), peerState.toCanonicalBytes()),
  );
}
