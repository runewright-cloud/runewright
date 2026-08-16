// SPDX-License-Identifier: GPL-3.0-or-later
//
// free_move_ordering_test.dart — two-device lockstep regression for the
// free-move window's application order (Phase 5.5 / 6.5).
//
// The bug: `_runFreeMoveRound` used to apply the LOCAL wizard's run first and
// the peer's second. That is a device-relative order — device A ran A-then-B
// while device B ran B-then-A — and the two runs share one phase HashRng and
// resolve against live occupancy. Whenever both players moved in the same
// window, the two devices could bind different RNG draws to different wizards,
// or hand a contested tile to different players, and diverge.
//
// The fix: both devices apply the two runs in ascending canonical
// public-key-byte order, which is identical on both sides and independent of
// which device considers whom "local".
//
// These tests use TurnSessionPair (a genuine two-client commit-reveal
// fixture), NOT SoloBattleSession — the solo stub echoes state hashes back and
// would hide exactly this class of divergence.
//
// Note the deliberate inversion baked into the fixture: 'player_a' carries the
// HIGHER public key and 'player_b' the LOWER one. So canonical order is
// b-then-a, the reverse of both playerId order and of device A's local-first
// order. A regression that restored local-first — or that sorted by playerId,
// the convention the melee round uses — fails these tests.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'turn_session_pair.dart';

/// player_a's owner pubkey — deliberately the HIGHER of the two, so canonical
/// pubkey order disagrees with playerId order.
final kPubkeyA = '0x${'ff' * 32}';

/// player_b's owner pubkey — the LOWER one, so player_b applies FIRST.
final kPubkeyB = '0x${'11' * 32}';

const kPosA = HexCoord(0, 0);
const kPosB = HexCoord(2, 0);

BattleState _makeState({
  Map<HexCoord, TileEffect> tileEffects = const {},
  HexCoord posA = kPosA,
  HexCoord posB = kPosB,
  int radius = 6,
}) {
  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  final a = WizardAvatar(
    playerId: 'player_a',
    ownerPubkeyHex: kPubkeyA,
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: posA,
    teamId: 'team_a',
    baseSpellRange: 3,
  );
  final b = WizardAvatar(
    playerId: 'player_b',
    ownerPubkeyHex: kPubkeyB,
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: posB,
    teamId: 'team_b',
    baseSpellRange: 3,
  );
  // Both wizards earned an Airy Barrier burst this turn: a free one-tile
  // reactive step in Phase 5.5. Set directly rather than routed through a
  // real barrier collapse — this test is about application order, not about
  // how the grant is earned (airy_barrier_free_move_test.dart covers that).
  a.pendingFreeMoveBurst = true;
  b.pendingFreeMoveBurst = true;

  return BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [a, b],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
    tileEffects: Map.of(tileEffects),
  );
}

WizardAvatar _av(BattleState s, String id) =>
    s.avatars.firstWhere((a) => a.playerId == id);

/// Runs one turn on two independent loops wired to each other, with each side
/// declaring its own free-move path. Returns both states for comparison.
Future<({BattleState stateA, BattleState stateB, TurnLoop loopA, TurnLoop loopB})>
    _runBothDevices({
  required BattleState stateA,
  required BattleState stateB,
  required List<HexCoord> pathA,
  required List<HexCoord> pathB,
}) async {
  final pair = TurnSessionPair();
  // loopA is device A: it considers player_a local. loopB is device B: it
  // considers player_b local. Each side's picker is only ever asked about its
  // OWN wizard; the peer's path arrives over the commit-reveal exchange.
  final loopA = TurnLoop(
    state: stateA,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    freeMoveDirectionPicker: (grant) async => pathA,
  );
  final loopB = TurnLoop(
    state: stateB,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    freeMoveDirectionPicker: (grant) async => pathB,
  );

  await Future.wait([
    loopA.runTurn(TurnInput(action: PassAction())),
    loopB.runTurn(TurnInput(action: PassAction())),
  ]);
  return (stateA: stateA, stateB: stateB, loopA: loopA, loopB: loopB);
}

void main() {
  group('free-move window applies both runs in canonical pubkey order', () {
    // ── Control ─────────────────────────────────────────────────────────────
    //
    // Same fixture, same terrain, same grants — but only ONE wizard actually
    // moves, so there is only one application and order cannot matter. This
    // passed even while the three tests below were failing, which is what
    // establishes that the divergence came from two-sided application ORDER
    // and not from the paired-session fixture, the grant plumbing, or the
    // conveyor terrain. Keep it: if it ever fails alongside the others, the
    // cause is machinery, not ordering.

    test('control: one mover only — no ordering to get wrong', () async {
      final loopEffects = <HexCoord, TileEffect>{
        HexCoord(1, 0): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 0): ConveyorTile(direction: HexCoord(-1, 0)),
        HexCoord(1, 4): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 4): ConveyorTile(direction: HexCoord(-1, 0)),
      };
      final r = await _runBothDevices(
        stateA: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        stateB: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        pathA: const [HexCoord(1, 0)],
        pathB: const [], // player_b stands fast
      );

      expect(
        r.stateA.toCanonicalBytes(),
        equals(r.stateB.toCanonicalBytes()),
        reason: 'A single free-move run must stay in lockstep — if this fails, '
            'the problem is the fixture, not the application order.',
      );
      expect(
        r.loopA.lastConveyorChainEvents.map((e) => e.entityId),
        ['player_a'],
      );
    });

    // ── Contested occupancy ─────────────────────────────────────────────────
    //
    // No RNG involved at all: both wizards declare the SAME destination tile.
    // Whoever is applied first takes it; the second finds it occupied and is
    // truncated back to standing fast. Under local-first ordering device A
    // gave the tile to player_a and device B gave it to player_b.

    test('a contested tile goes to the lower public key on BOTH devices',
        () async {
      const contested = HexCoord(1, 0); // adjacent to both (0,0) and (2,0)
      final r = await _runBothDevices(
        stateA: _makeState(),
        stateB: _makeState(),
        pathA: const [contested],
        pathB: const [contested],
      );

      expect(
        r.stateA.toCanonicalBytes(),
        equals(r.stateB.toCanonicalBytes()),
        reason: 'Two wizards contesting one free-move tile diverged between '
            'the devices. The window must apply the two runs in ascending '
            'canonical pubkey order, not local-first.',
      );

      // And the winner is the LOWER public key (player_b), not the local
      // wizard, not the lower playerId. Asserted on both states so a fix that
      // merely converges on device-A's answer would still fail.
      for (final s in [r.stateA, r.stateB]) {
        expect(_av(s, 'player_b').position, contested,
            reason: 'player_b holds the lower pubkey and must be applied '
                'first, taking the contested tile');
        expect(_av(s, 'player_a').position, kPosA,
            reason: 'player_a is applied second and finds the tile taken');
      }
    });

    // ── Shared RNG stream ───────────────────────────────────────────────────
    //
    // Both wizards step into their own closed 2-tile conveyor loop. Resolving
    // a closed loop draws a random exit tile (tile_entry_resolver.dart's
    // _findLoopExit), so each run consumes exactly one nextInt from the SAME
    // phase HashRng. Application order therefore decides which wizard gets the
    // first draw — this is the RNG-binding half of the bug, independent of
    // occupancy.

    test('both wizards looping a conveyor bind the shared RNG identically',
        () async {
      // Two geometrically identical 2-tile loops, far apart: X pushes to Y,
      // Y pushes straight back to X.
      final loopEffects = <HexCoord, TileEffect>{
        HexCoord(1, 0): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 0): ConveyorTile(direction: HexCoord(-1, 0)),
        HexCoord(1, 4): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 4): ConveyorTile(direction: HexCoord(-1, 0)),
      };
      final r = await _runBothDevices(
        stateA: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        stateB: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        pathA: const [HexCoord(1, 0)],
        pathB: const [HexCoord(1, 4)],
      );

      expect(
        r.stateA.toCanonicalBytes(),
        equals(r.stateB.toCanonicalBytes()),
        reason: 'Two free-move runs sharing one phase HashRng diverged between '
            'the devices — the RNG stream must be bound to the two wizards in '
            'canonical pubkey order, identically on both sides.',
      );

      // Sanity: both runs actually reached the conveyor and consumed the
      // stream. Without this the equality above could pass vacuously.
      for (final loop in [r.loopA, r.loopB]) {
        expect(
          loop.lastConveyorChainEvents.map((e) => e.entityId),
          containsAll(<String>['player_a', 'player_b']),
          reason: 'both wizards must have ridden a conveyor loop for this '
              'test to exercise shared RNG consumption',
        );
      }
    });

    // ── Explicit order assertion ────────────────────────────────────────────
    //
    // The two tests above prove the devices agree. This one proves WHAT they
    // agree on: the lower public key is applied first, so it appends its
    // conveyor event first and takes the earlier RNG draw. A future change
    // that made both devices consistently apply local-LAST, or that sorted by
    // playerId, would pass the convergence tests and fail this one.

    test('the lower public key is applied first, from both perspectives',
        () async {
      final loopEffects = <HexCoord, TileEffect>{
        HexCoord(1, 0): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 0): ConveyorTile(direction: HexCoord(-1, 0)),
        HexCoord(1, 4): ConveyorTile(direction: HexCoord(1, 0)),
        HexCoord(2, 4): ConveyorTile(direction: HexCoord(-1, 0)),
      };
      final r = await _runBothDevices(
        stateA: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        stateB: _makeState(
          tileEffects: loopEffects,
          posA: const HexCoord(0, 0),
          posB: const HexCoord(0, 4),
        ),
        pathA: const [HexCoord(1, 0)],
        pathB: const [HexCoord(1, 4)],
      );

      // player_b holds 0x11..., player_a holds 0xff... — so player_b's run is
      // applied first and its conveyor event lands in the turn's shared sink
      // first, on the device that calls player_a local AND on the one that
      // calls player_b local.
      for (final loop in [r.loopA, r.loopB]) {
        final freeMoveRiders =
            loop.lastConveyorChainEvents.map((e) => e.entityId).toList();
        expect(freeMoveRiders.first, 'player_b',
            reason: 'the lower canonical pubkey (player_b, 0x11..) must be '
                'applied before the higher (player_a, 0xff..) — regardless of '
                'which wizard this device calls local, and regardless of '
                'playerId order, which is the opposite here');
      }
    });
  });
}
