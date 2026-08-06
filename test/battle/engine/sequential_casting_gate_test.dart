// SPDX-License-Identifier: GPL-3.0-or-later
//
// sequential_casting_gate_test.dart — TurnLoop's half of the sequential
// casting order (docs/SPELL_COMPONENTS_PLAN.md §5.2/§5.3).
//
// Two properties matter, and both are about what happens when the two devices
// disagree about time rather than about state:
//
//   1. The trailing player's gate stays shut until the leader announces, and
//      opens the moment they do. A gate that never opens is a hung match.
//   2. The announcement is LATCHED. If the leader finishes before the trailing
//      player's screen gets around to waiting, the wait must be satisfied
//      immediately by the signal already received. A live stream would drop it
//      and lock that player out for the rest of the turn — the single most
//      likely real-world failure, since the leader is by definition acting
//      first.
//
// Nothing here touches the mana ledger or the state hash: this is pacing, and
// a client that ignores it stalls its opponent without desyncing anything.

import 'dart:async';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';

import 'turn_session_pair.dart';

void main() {
  const leadId = 'lead';
  const trailId = 'trail';

  /// Two loops over one seating, sharing a [TurnSessionPair]. `lead` is
  /// seat 0, so with no battle-start entropy drawn (start seat falls back to
  /// 0) it leads turn 1 — deterministic without running the entropy exchange.
  ({TurnLoop lead, TurnLoop trail}) pair({
    bool vocalComponents = true,
    bool simultaneousCasting = false,
  }) {
    final sessions = TurnSessionPair();
    TurnLoop loopFor(String id, dynamic session) {
      final field = Battlefield(radius: 4);
      final avatars = [
        for (final playerId in [leadId, trailId])
          WizardAvatar(
            playerId: playerId,
            ownerPubkeyHex: '0x${'0' * 64}',
            hp: 24,
            mana: 100,
            maxMana: 100,
            position: field.spawnPositions(2)[playerId == leadId ? 0 : 1],
            teamId: playerId,
            baseSpellRange: 3,
          ),
      ];
      for (final a in avatars) {
        field.occupancy[a.playerId] = a.position;
      }
      final state = BattleState(
        config: MatchConfig(
          maxPlayers: 2,
          vocalComponents: vocalComponents,
          simultaneousCasting: simultaneousCasting,
        ),
        avatars: avatars,
        teams: [
          for (final a in avatars) Team(id: a.teamId, playerIds: [a.playerId]),
        ],
        battlefield: field,
        componentSeating: const [leadId, trailId],
      );
      return TurnLoop(state: state, session: session, localPlayerId: id);
    }

    return (
      lead: loopFor(leadId, sessions.sessionA),
      trail: loopFor(trailId, sessions.sessionB),
    );
  }

  /// Whether [future] has completed by the time the event loop settles.
  /// `await Future.delayed(Duration.zero)` twice drains microtasks so a gate
  /// that was going to open immediately has had every chance to.
  Future<bool> settled(Future<void> future) async {
    var done = false;
    unawaited(future.then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    return done;
  }

  test('the leader never waits', () async {
    final p = pair();
    expect(p.lead.localComponentSlot(1), 0);
    expect(await settled(p.lead.awaitComponentSlot()), isTrue);
  });

  test('the trailing player waits until the leader announces', () async {
    final p = pair();
    expect(p.trail.localComponentSlot(1), 1);

    final gate = p.trail.awaitComponentSlot();
    expect(
      await settled(gate),
      isFalse,
      reason: 'the trailing player must not be able to lock in first',
    );

    p.lead.signalComponentsDone();
    expect(await settled(gate), isTrue);
  });

  test('an announcement that arrives first is latched, not dropped', () async {
    // The leader acts before the trailing player's screen asks. This is the
    // ordinary case, not the exotic one — the leader goes first by definition.
    final p = pair();
    p.lead.signalComponentsDone();
    expect(await settled(p.trail.awaitComponentSlot()), isTrue);
  });

  test('a signal for another turn does not open this turn\'s gate', () async {
    final p = pair();
    // The leader is on turn 1; state.turnNumber is 0 until runTurn bumps it.
    expect(p.lead.componentTurnNumber, 1);
    p.lead.state.turnNumber = 5;
    p.lead.signalComponentsDone(); // announces turn 6

    expect(await settled(p.trail.awaitComponentSlot()), isFalse);
  });

  test('simultaneous casting opens both gates at once', () async {
    final p = pair(simultaneousCasting: true);
    expect(await settled(p.lead.awaitComponentSlot()), isTrue);
    expect(
      await settled(p.trail.awaitComponentSlot()),
      isTrue,
      reason: 'nobody takes turns when everyone performs together',
    );
  });

  test('with no components enabled there is nothing to order', () async {
    final p = pair(vocalComponents: false);
    expect(await settled(p.trail.awaitComponentSlot()), isTrue);
  });

  test('the lead rotates by one seat each turn', () {
    final p = pair();
    expect(p.lead.componentOrder(1), [leadId, trailId]);
    expect(p.lead.componentOrder(2), [trailId, leadId]);
    expect(p.lead.componentOrder(3), [leadId, trailId]);
    // Both devices derive the same order from the same seating.
    expect(p.trail.componentOrder(2), p.lead.componentOrder(2));
  });

  test('seating falls back to avatar order when a state has none', () {
    final p = pair();
    final state = p.lead.state;
    final bare = BattleState(
      config: state.config,
      avatars: state.avatars,
      teams: state.teams,
      battlefield: state.battlefield,
    );
    final loop = TurnLoop(
      state: bare,
      session: p.lead.session,
      localPlayerId: leadId,
    );
    expect(loop.componentSeating, [leadId, trailId]);
  });
}
