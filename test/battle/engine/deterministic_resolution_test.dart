// SPDX-License-Identifier: GPL-3.0-or-later
//
// deterministic_resolution_test.dart — proves the resolution seam is real.
//
// The replay corpus already checks that end-of-turn behaviour did not change
// when it moved out of `TurnLoop`; it runs the phase through a full pair of
// loops, so it cannot tell whether the phase still secretly needs one. This
// file asserts the other half of the claim: that
// [DeterministicResolution] is callable with **nothing but a BattleState** —
// no `TurnLoop`, no `BattleSession`, no identity, no network, no async.
//
// That is the property worth guarding. If someone later reaches back across
// the seam — a session call, a local-player check, an `await` — the corpus
// stays green and only this file goes red.

import 'dart:typed_data';

import 'package:rune_duel/battle/engine/deterministic_resolution.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart';
import 'package:rune_duel/battle/engine/wild_magic_applicator.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart'
    show SpellAffinity;
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/reflection_link.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:test/test.dart';

import 'certified_cast_fixture.dart';

void main() {
  // Constructed per test, so nothing leaks between them.
  ({
    DeterministicResolution resolution,
    List<ConveyorChainEvent> conveyor,
    List<WildMagicEvent> wildMagic,
  })
  harness() {
    final state = makeDuelState();
    return (
      resolution: DeterministicResolution(state),
      conveyor: <ConveyorChainEvent>[],
      wildMagic: <WildMagicEvent>[],
    );
  }

  test('end of turn resolves with no TurnLoop and no session', () {
    final h = harness();
    final state = h.resolution.state;

    // Two rules with visible, independent outcomes: a lava tile under player_a
    // (damage) and a Reflections link on its last turn (expiry).
    state.tileEffects[state.avatars.first.position] =
        const FloorIsLava(damage: 3);
    state.reflectionLinks.add(
      ReflectionLink(
        id: 'link',
        casterId: 'player_a',
        targetId: 'player_b',
        activeTriggers: {},
        remainingTurns: 1,
      ),
    );
    final hpBefore = state.avatars.first.hp;

    // Synchronous by construction — no `await`. A phase that needed the
    // network could not have this signature at all, which is the point.
    h.resolution.resolveEndOfTurn(
      preMovPos: {
        for (final av in state.avatars) av.playerId: av.position,
      },
      rng: HashRng(Uint8List(32)),
      conveyorChainEvents: h.conveyor,
      wildMagicEvents: h.wildMagic,
    );

    expect(state.avatars.first.hp, hpBefore - 3,
        reason: 'lava should burn the wizard standing in it');
    expect(state.reflectionLinks, isEmpty,
        reason: 'a link on its last turn expires at end of turn');
  });

  test('the same state and rng resolve identically twice — two devices agree',
      () {
    // The property lockstep actually rests on. Run the phase on two separately
    // built states with the same seed and require byte-identical canonical
    // output, which is exactly what the two devices hash at each other.
    Uint8List runOnce() {
      final h = harness();
      final state = h.resolution.state;
      state.tileEffects[state.avatars.last.position] =
          const FloorIsLava(damage: 2);
      h.resolution.resolveEndOfTurn(
        preMovPos: {
          for (final av in state.avatars) av.playerId: av.position,
        },
        rng: HashRng(Uint8List(32)..fillRange(0, 32, 0x5A)),
        conveyorChainEvents: h.conveyor,
        wildMagicEvents: h.wildMagic,
      );
      return state.toCanonicalBytes();
    }

    expect(bytesEqual(runOnce(), runOnce()), isTrue);
  });

  test('the event sinks are the caller\'s, and stay empty when nothing fires',
      () {
    // Sinks are parameters rather than fields so `TurnLoop` can keep appending
    // several phases into one per-turn list. A caller that passes fresh lists
    // must get back only what THIS call emitted — nothing retained, nothing
    // carried over.
    final h = harness();
    h.resolution.resolveEndOfTurn(
      preMovPos: const {},
      rng: HashRng(Uint8List(32)),
      conveyorChainEvents: h.conveyor,
      wildMagicEvents: h.wildMagic,
    );
    expect(h.conveyor, isEmpty);
    expect(h.wildMagic, isEmpty);
  });

  // ── Phase 5b: Summons ─────────────────────────────────────────────────────
  //
  // The Summons phase has a host playback callback in the middle of it. It is
  // behind the seam anyway because the callback separates nothing: the AI
  // sweep decides everything and the aftermath re-decides none of it. These
  // tests assert exactly that — that the outcome is complete before playback
  // could possibly have happened, since here there is no playback at all.

  /// A creature that can actually move and strike. A three-earth summon has
  /// `damage: 0, moveSpeed: 0` and would sit inert, asserting nothing — see
  /// M4.16's "second trap" in docs/M4_findings.md.
  Minion attacker(HexCoord at) => Minion(
    id: 'creature_a',
    ownerId: 'player_a',
    teamId: 'team_a',
    position: at,
    affinity: SpellAffinity.fire,
    stats: const MinionStats(maxHp: 4, damage: 2, moveSpeed: 2, attackRange: 1),
    elementSequence: const [BorderZone.earth, BorderZone.fire],
  );

  test('summon actions resolve with no TurnLoop, no session and no playback',
      () {
    final h = harness();
    final state = h.resolution.state;
    // Three tiles from player_b at (1,0): out of its reach-1 range, inside a
    // 2-tile move budget, so it must close before it can strike.
    state.minions.add(attacker(const HexCoord(4, 0)));
    final victim = state.avatars.firstWhere((a) => a.playerId == 'player_b');
    final hpBefore = victim.hp;

    // Synchronous by construction. A phase that needed the host's playback
    // could not have this signature, which is the whole point of the split.
    final outcome = h.resolution.resolveSummonActions(
      rng: HashRng(Uint8List(32)),
      conveyorChainEvents: h.conveyor,
    );

    expect(state.minions.single.position, isNot(const HexCoord(4, 0)),
        reason: 'the creature should have closed on its target');
    expect(victim.hp, lessThan(hpBefore),
        reason: 'and struck once it was in range');
    expect(outcome.moveEvents, hasLength(1));
    expect(outcome.attackEvents, hasLength(1));
    expect(outcome.moveEvents.single.path.first, const HexCoord(4, 0),
        reason: 'the walk starts at the pre-move tile');
    expect(outcome.moveEvents.single.path.last, state.minions.single.position,
        reason: 'and ends where the creature actually is');
  });

  test('the outcome is already final — playback cannot change it', () {
    // The load-bearing claim of the split. Everything the phase decides is
    // decided by resolveSummonActions; resolveSummonAftermath only reaps what
    // is already dead. Run the sweep, snapshot the canonical state, then run
    // the aftermath on a corpse-free field and require the state to be
    // untouched — no second decision, nothing recomputed.
    final h = harness();
    final state = h.resolution.state;
    state.minions.add(attacker(const HexCoord(3, 0)));

    h.resolution.resolveSummonActions(
      rng: HashRng(Uint8List(32)),
      conveyorChainEvents: h.conveyor,
    );
    final afterActions = state.toCanonicalBytes();

    h.resolution.resolveSummonAftermath(
      rng: HashRng(Uint8List(32)),
      wildMagicEvents: h.wildMagic,
    );

    expect(bytesEqual(afterActions, state.toCanonicalBytes()), isTrue,
        reason: 'nothing died, so the aftermath must be a no-op');
    expect(h.wildMagic, isEmpty);
  });

  test('the aftermath reaps what the sweep killed, and only then', () {
    // The one thing the aftermath genuinely does, and why it runs AFTER the
    // playback callback rather than before it: a creature killed during the
    // sweep must still be on the field while its walk is being animated.
    final h = harness();
    final state = h.resolution.state;
    final doomed = attacker(const HexCoord(3, 0))..hp = 0;
    state.minions.add(doomed);

    h.resolution.resolveSummonActions(
      rng: HashRng(Uint8List(32)),
      conveyorChainEvents: h.conveyor,
    );
    expect(state.minions, hasLength(1),
        reason: 'still present for playback — the sweep never reaps');

    h.resolution.resolveSummonAftermath(
      rng: HashRng(Uint8List(32)),
      wildMagicEvents: h.wildMagic,
    );
    expect(state.minions, isEmpty, reason: 'reaped only once playback is done');
  });

  test('the same state and rng resolve the summon sweep identically twice', () {
    // Lockstep again, for the phase whose RNG actually gets consumed (target
    // tie-breaks). Two separately built states, one seed, identical bytes.
    Uint8List runOnce() {
      final h = harness();
      final state = h.resolution.state;
      state.minions.add(attacker(const HexCoord(4, 0)));
      h.resolution.resolveSummonActions(
        rng: HashRng(Uint8List(32)..fillRange(0, 32, 0x5A)),
        conveyorChainEvents: h.conveyor,
      );
      h.resolution.resolveSummonAftermath(
        rng: HashRng(Uint8List(32)..fillRange(0, 32, 0x5A)),
        wildMagicEvents: h.wildMagic,
      );
      return state.toCanonicalBytes();
    }

    expect(bytesEqual(runOnce(), runOnce()), isTrue);
  });
}
