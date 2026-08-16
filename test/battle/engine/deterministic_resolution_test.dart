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
import 'package:rune_duel/battle/models/reflection_link.dart';
import 'package:rune_duel/battle/models/terrain.dart';
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
}
