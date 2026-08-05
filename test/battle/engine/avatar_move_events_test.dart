// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_move_events_test.dart — TurnLoop.lastAvatarMoveEvents, the UI-only
// record that lets the battlefield walk a wizard along their route instead of
// teleporting them to the destination.
//
// Cosmetic output, but derived from real resolution, so it can go wrong in the
// two ways any derived record can: it can disagree with where the wizard
// actually went, or it can describe a collision that didn't visibly happen.
// Both are covered here. The arbitration itself is tested in
// test/battle/models/movement_collision_test.dart.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

({BattleState state, TurnLoop loop, WizardAvatar local})
_setup({
  Map<HexCoord, TileEffect> tileEffects = const {},
  HexCoord dummyPos = const HexCoord(0, 5),
  int radius = 6,
  MovementPlayback? onMovementResolved,
  void Function(TurnPhase)? onPhase,
}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const localPos = HexCoord(0, 0);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: localPos,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 3,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
    tileEffects: tileEffects,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    onMovementResolved: onMovementResolved,
    onPhase: onPhase,
  );
  return (state: state, loop: loop, local: local);
}

AvatarMoveEvent _eventFor(TurnLoop loop, String playerId) =>
    loop.lastAvatarMoveEvents.firstWhere((e) => e.playerId == playerId);

void main() {
  group('lastAvatarMoveEvents', () {
    test('records the route actually walked, origin first', () async {
      final ctx = _setup();

      await ctx.loop.runTurn(
        TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
        ),
      );

      final event = _eventFor(ctx.loop, 'local');
      expect(event.path, [
        const HexCoord(0, 0),
        const HexCoord(1, 0),
        const HexCoord(2, 0),
      ]);
      // The record must agree with the engine, or the token walks somewhere
      // the wizard isn't.
      expect(event.path.last, ctx.local.position);
      expect(event.lungeTile, isNull);
      expect(event.wonContestAt, isNull);
    });

    test('a wizard who stayed put gets an origin-only path', () async {
      final ctx = _setup();

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Both avatars are recorded, including the one that never moved — the UI
      // filters those out itself.
      expect(ctx.loop.lastAvatarMoveEvents, hasLength(2));
      expect(_eventFor(ctx.loop, 'local').path, [const HexCoord(0, 0)]);
      expect(_eventFor(ctx.loop, 'dummy').path, [const HexCoord(0, 5)]);
    });

    test('every turn starts from a clean record', () async {
      final ctx = _setup();

      await ctx.loop.runTurn(
        TurnInput(action: PassAction(), movePath: const [HexCoord(1, 0)]),
      );
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.loop.lastAvatarMoveEvents, hasLength(2));
      expect(_eventFor(ctx.loop, 'local').path, [const HexCoord(1, 0)]);
    });

    test('a free conveyor push is part of the walked route', () async {
      // The token should ride the belt as one continuous move, not teleport to
      // the far end of the push.
      final ctx = _setup(
        tileEffects: {
          const HexCoord(1, 0): const ConveyorTile(direction: HexCoord(1, 0)),
        },
      );

      await ctx.loop.runTurn(
        TurnInput(action: PassAction(), movePath: const [HexCoord(1, 0)]),
      );

      final event = _eventFor(ctx.loop, 'local');
      expect(event.path.first, const HexCoord(0, 0));
      expect(event.path, contains(const HexCoord(1, 0)));
      expect(event.path.last, ctx.local.position);
      expect(event.path.last, isNot(const HexCoord(1, 0)));
    });

    test('walking into another body stops short and records the lunge',
        () async {
      // Bodies are exclusive: the dummy is simply standing at (2,0), so the
      // local wizard walks into it and rebounds. This is NOT arbitration —
      // nobody contested anything — but it has to *look* like a collision, or
      // the walk ends one tile early for no visible reason.
      final ctx = _setup(dummyPos: const HexCoord(2, 0));

      await ctx.loop.runTurn(
        TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
        ),
      );

      final local = _eventFor(ctx.loop, 'local');
      expect(local.path.last, const HexCoord(1, 0));
      expect(ctx.local.position, const HexCoord(1, 0));
      expect(local.lungeTile, const HexCoord(2, 0));
      expect(local.wonContestAt, isNull);

      // The wizard who was stood on it never moved and never contested: it
      // held the tile by being there, not by winning a speed check.
      final dummy = _eventFor(ctx.loop, 'dummy');
      expect(dummy.path, [const HexCoord(2, 0)]);
      expect(dummy.wonContestAt, isNull);
      expect(dummy.lungeTile, isNull);
    });

    test('a lunge the wizard could not have made is dropped', () async {
      // Same collision, but a conveyor on the consolation tile shoves the
      // loser two tiles away from the contested tile. Recoiling onto a tile
      // they are nowhere near would read as a rendering bug, so the lunge is
      // dropped rather than drawn from the wrong place.
      final ctx = _setup(
        dummyPos: const HexCoord(2, 0),
        tileEffects: {
          const HexCoord(1, 0): const ConveyorTile(direction: HexCoord(0, -1)),
        },
      );

      await ctx.loop.runTurn(
        TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
        ),
      );

      final local = _eventFor(ctx.loop, 'local');
      expect(hexDistance(local.path.last, const HexCoord(2, 0)), greaterThan(1));
      expect(local.lungeTile, isNull);
      expect(local.path.last, ctx.local.position);
    });
  });

  // ── Playback timing (onMovementResolved) ──────────────────────────────────
  //
  // The record above is only half the fix for teleporting tokens. The other
  // half is *when* the UI gets it: the engine mutates BattleState in place and
  // then keeps awaiting network exchanges, while the battlefield painter
  // redraws every frame off a free-running controller. Hand the walk over after
  // runTurn returns and the token has already been drawn at its destination for
  // however long the rest of the turn took — the walk then reads as a snap-back
  // and a replay. These tests pin the handover point.

  group('onMovementResolved', () {
    test('fires with positions already applied', () async {
      // The callback is what installs the animation, and the animation is what
      // holds the token at its origin — so the engine must have finished moving
      // before it fires, or the UI has nothing to animate *from*.
      List<AvatarMoveEvent>? delivered;
      HexCoord? positionAtPlayback;
      WizardAvatar? localAvatar;
      final ctx = _setup(
        onMovementResolved: (moves) async {
          delivered = moves;
          positionAtPlayback = localAvatar!.position;
        },
      );
      localAvatar = ctx.local;

      await ctx.loop.runTurn(
        TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
        ),
      );

      expect(delivered, isNotNull);
      expect(
        delivered!.firstWhere((e) => e.playerId == 'local').path,
        const [HexCoord(0, 0), HexCoord(1, 0), HexCoord(2, 0)],
      );
      expect(positionAtPlayback, const HexCoord(2, 0));
    });

    test('the turn waits for playback before resolving anything else',
        () async {
      // The await is the whole point. If the turn ran on past the callback, the
      // melee prompt (and every later phase) would be reading — and asking the
      // player about — a board whose walk hasn't been shown yet.
      final order = <String>[];
      final ctx = _setup(
        onMovementResolved: (moves) async {
          order.add('playback-start');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('playback-end');
        },
        onPhase: (phase) => order.add('phase-${phase.name}'),
      );

      await ctx.loop.runTurn(
        TurnInput(action: PassAction(), movePath: const [HexCoord(1, 0)]),
      );

      expect(order.take(2), ['playback-start', 'playback-end']);
      // Phase 4 (cloud drift) onward all happen after the walk has been shown.
      expect(order, contains('phase-${TurnPhase.summons.name}'));
      expect(
        order.indexOf('playback-end'),
        lessThan(order.indexOf('phase-${TurnPhase.summons.name}')),
      );
    });

    test('still fires on a turn where nobody moved', () async {
      // The filtering ("did this wizard actually go anywhere?") is the UI's
      // call, not the engine's — same contract as lastAvatarMoveEvents itself.
      var calls = 0;
      final ctx = _setup(onMovementResolved: (moves) async {
        calls++;
        expect(moves.every((e) => e.path.length == 1), isTrue);
      });

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(calls, 1);
    });
  });
}
