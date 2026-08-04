// SPDX-License-Identifier: GPL-3.0-or-later
//
// wizard_movement_animation_test.dart — the walk timeline
// (entityWalkStateAt) and the painter passes that draw it, for both wizards
// and summons.
//
// This is cosmetic code, so "correct" means "reads as the thing that happened":
//   - a wizard starts on the tile they left and ends on the tile they reached;
//   - everyone's walk takes the same wall-clock time regardless of distance,
//     which is what puts two colliding wizards on the contested tile at the
//     same instant;
//   - a collision loser visibly reaches ONTO the tile they lost and is pushed
//     back off it, rather than stopping short of their own accord.
//
// The last one is the point of the whole feature: without the lunge, a lost
// speed contest is indistinguishable from choosing not to move.

import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/minion.dart'
    show Minion, MinionStats, SummonAbility;
import 'package:rune_duel/engine/border_zone.dart' show BorderZone;
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/ui/avatars/avatar_sprites.dart';
import 'package:rune_duel/ui/battlefield_painter.dart';

void main() {
  const center = Offset(200, 200);
  const hexSize = 24.0;
  Offset px(HexCoord h) => hexToPixel(h, center, hexSize);

  // A straight run along the +q axis, the same geometry the collision engine
  // tests use.
  HexCoord q(int i) => HexCoord(i, 0);

  WizardWalkState at(EntityMoveAnimation anim, double t) =>
      entityWalkStateAt(anim, t, center, hexSize);

  group('entityWalkStateAt — plain walk', () {
    const walk = AvatarMoveAnimation(
      playerId: 'a',
      path: [HexCoord(-2, 0), HexCoord(-1, 0), HexCoord(0, 0)],
    );

    test('starts on the origin tile and ends on the destination tile', () {
      expect(at(walk, 0).pos, px(q(-2)));
      expect(at(walk, 1).pos, px(q(0)));
    });

    test('passes through the intermediate tile, not straight to the end', () {
      // Half of the travel window covers half the route: the middle tile.
      final mid = at(walk, 0.36).pos;
      expect((mid - px(q(-1))).distance, lessThan(0.001));
    });

    test('is already home before playback ends, and holds there', () {
      // The tail of the timeline is the collision recoil window; a wizard with
      // nothing to recoil from must simply stand still through it rather than
      // drifting.
      expect(at(walk, 0.8).pos, px(q(0)));
      expect(at(walk, 0.95).pos, px(q(0)));
    });

    test('a wizard who stayed put never leaves their tile', () {
      const still = AvatarMoveAnimation(playerId: 'a', path: [HexCoord(1, 0)]);
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(at(still, t).pos, px(q(1)));
      }
    });

    test('walks face the way they are travelling', () {
      expect(at(walk, 0.2).facing, AvatarFacing.right);
      const west = AvatarMoveAnimation(
        playerId: 'b',
        path: [HexCoord(0, 0), HexCoord(-1, 0)],
      );
      expect(at(west, 0.2).facing, AvatarFacing.left);
      // Having stopped, they keep looking where they were headed rather than
      // snapping back to face the viewer.
      expect(at(west, 1.0).facing, AvatarFacing.left);
    });

    test('a long walk and a short one finish together', () {
      const short = AvatarMoveAnimation(
        playerId: 'short',
        path: [HexCoord(3, 0), HexCoord(2, 0)],
      );
      // Same timeline fraction, both already arrived — this simultaneity is
      // what makes the collision frames line up.
      expect(at(walk, 0.72).pos, px(q(0)));
      expect(at(short, 0.72).pos, px(q(2)));
    });
  });

  group('entityWalkStateAt — contested tile', () {
    // Lost the tile at (0,0); consolation tile is (-1,0).
    const loser = AvatarMoveAnimation(
      playerId: 'loser',
      path: [HexCoord(-2, 0), HexCoord(-1, 0)],
      lungeTile: HexCoord(0, 0),
    );

    test('reaches PAST its final tile, toward the tile it lost', () {
      final reach = at(loser, 0.72).pos;
      final home = px(q(-1));
      final contested = px(q(0));
      // Strictly beyond home, and strictly short of fully occupying the
      // contested tile — two tokens dead-centre on one hex reads as a glitch.
      expect(reach.dx, greaterThan(home.dx));
      expect(reach.dx, lessThan(contested.dx));
    });

    test('is back on its own tile by the end', () {
      final end = at(loser, 1.0).pos;
      expect((end - px(q(-1))).distance, lessThan(0.001));
    });

    test('keeps facing the tile it lost while being pushed off it', () {
      expect(at(loser, 0.7).facing, AvatarFacing.right);
      expect(at(loser, 0.85).facing, AvatarFacing.right);
      expect(at(loser, 1.0).facing, AvatarFacing.right);
    });

    test('a wizard bounced all the way home still lunges', () {
      // Declared one tile, lost it, so their walked path is just their origin —
      // the ONLY thing that distinguishes this from "chose not to move".
      const pinned = AvatarMoveAnimation(
        playerId: 'pinned',
        path: [HexCoord(-1, 0)],
        lungeTile: HexCoord(0, 0),
      );
      expect(at(pinned, 0.72).pos.dx, greaterThan(px(q(-1)).dx));
      expect((at(pinned, 1.0).pos - px(q(-1))).distance, lessThan(0.001));
    });

    test('the winner walks in and stays; only the loser recoils', () {
      const winner = AvatarMoveAnimation(
        playerId: 'winner',
        path: [HexCoord(2, 0), HexCoord(1, 0), HexCoord(0, 0)],
        wonContestAt: HexCoord(0, 0),
      );
      expect(at(winner, 0.72).pos, px(q(0)));
      expect(at(winner, 1.0).pos, px(q(0)));
      // And at the moment of impact the two are on opposite sides of the tile.
      expect(at(loser, 0.72).pos.dx, lessThan(at(winner, 0.72).pos.dx));
    });

    test('both sides of a tie recoil off the same tile', () {
      const west = AvatarMoveAnimation(
        playerId: 'w',
        path: [HexCoord(-2, 0), HexCoord(-1, 0)],
        lungeTile: HexCoord(0, 0),
      );
      const east = AvatarMoveAnimation(
        playerId: 'e',
        path: [HexCoord(2, 0), HexCoord(1, 0)],
        lungeTile: HexCoord(0, 0),
      );
      expect(west.contestedTile, q(0));
      expect(east.contestedTile, q(0));
      expect(at(west, 0.72).pos.dx, lessThan(at(east, 0.72).pos.dx));
      expect((at(west, 1.0).pos - px(q(-1))).distance, lessThan(0.001));
      expect((at(east, 1.0).pos - px(q(1))).distance, lessThan(0.001));
    });
  });

  group('entityWalkStateAt — summon walks', () {
    // The timeline is shared with wizards on purpose: a creature crossing the
    // board should read exactly like a wizard crossing it. These cover the one
    // thing that is summon-specific — the melee lunge, which is not a lost
    // collision but an attack, and must still reach on and be shoved back.
    test('a walking creature travels its route and holds at the end', () {
      const walk = MinionMoveAnimation(
        minionId: 'm1',
        path: [HexCoord(-2, 0), HexCoord(-1, 0), HexCoord(0, 0)],
      );
      expect(at(walk, 0).pos, px(q(-2)));
      expect((at(walk, 0.36).pos - px(q(-1))).distance, lessThan(0.001));
      expect(at(walk, 0.72).pos, px(q(0)));
      expect(at(walk, 1.0).pos, px(q(0)));
    });

    test('a melee lunge reaches onto the target tile and recoils home', () {
      // Stood still all turn and struck the neighbour: a one-tile path with a
      // lunge, which is the ONLY thing distinguishing "attacked" from "idle".
      const strike = MinionMoveAnimation(
        minionId: 'm1',
        path: [HexCoord(-1, 0)],
        lungeTile: HexCoord(0, 0),
      );
      final reach = at(strike, 0.72).pos;
      expect(reach.dx, greaterThan(px(q(-1)).dx));
      expect(reach.dx, lessThan(px(q(0)).dx));
      expect((at(strike, 1.0).pos - px(q(-1))).distance, lessThan(0.001));
      // Facing the thing it hit, throughout the blow and the recoil.
      expect(at(strike, 0.7).facing, AvatarFacing.right);
      expect(at(strike, 1.0).facing, AvatarFacing.right);
      // And the spark the painter flashes is on the tile it struck.
      expect(strike.contestedTile, q(0));
    });

    test('minionTokenPos falls back to the board tile when not walking', () {
      expect(
        BattlefieldPainter.minionTokenPos(null, q(1), 0.5, center, hexSize),
        px(q(1)),
      );
      const walk = MinionMoveAnimation(
        minionId: 'm1',
        path: [HexCoord(0, 0), HexCoord(1, 0)],
      );
      expect(
        BattlefieldPainter.minionTokenPos(walk, q(1), 1.0, center, hexSize),
        px(q(1)),
      );
      // Mid-walk it tracks the animation, not the (already-final) board tile.
      expect(
        BattlefieldPainter.minionTokenPos(walk, q(1), 0.0, center, hexSize),
        px(q(0)),
      );
    });
  });

  group('summon thumbnail geometry', () {
    test('the largest square that fits, and it fits', () {
      // Flat-top hex of circumradius 1: half-height √3/2 ≈ 0.866, and the
      // slanted edge √3·x + y = √3 is what actually binds.
      final half = kHexInscribedSquare / 2;
      expect(half, lessThan(sqrt(3) / 2));
      expect(sqrt(3) * half + half, closeTo(sqrt(3), 1e-12));
      // Adjacent tile centres are √3 apart, so neighbouring thumbnails still
      // clear each other rather than overlapping into mush.
      expect(kHexInscribedSquare, lessThan(sqrt(3)));
      // And it is genuinely bigger than the old stamp-sized 0.62.
      expect(kHexInscribedSquare, greaterThan(1.0));
    });
  });

  group('BattlefieldPainter — movement pass', () {
    // Same contract as battlefield_painter_test.dart: no pixel baseline, this
    // catches the paint()-time crash class.
    testWidgets('paints walks, a collision and the disc fallback without '
        'throwing', (tester) async {
      final controller = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 900),
      );
      addTearDown(controller.dispose);

      Widget board(double t) {
        controller.value = t;
        return MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              size: const Size(400, 400),
              painter: BattlefieldPainter(
                radius: 4,
                hexSize: hexSize,
                localPlayerId: 'me',
                occupancy: const {
                  'me': HexCoord(-1, 0),
                  'foe': HexCoord(0, 0),
                  'idle': HexCoord(0, 2),
                },
                barrierRings: {
                  const HexCoord(-1, 0): const [SpellAffinity.water],
                },
                // avatarAtlas is left null, so this also covers the
                // placeholder-disc path a device takes before the sprite sheet
                // decodes (or if it never does).
                avatarMoveAnimations: const [
                  AvatarMoveAnimation(
                    playerId: 'me',
                    path: [HexCoord(-2, 0), HexCoord(-1, 0)],
                    lungeTile: HexCoord(0, 0),
                  ),
                  AvatarMoveAnimation(
                    playerId: 'foe',
                    path: [HexCoord(2, 0), HexCoord(1, 0), HexCoord(0, 0)],
                    wonContestAt: HexCoord(0, 0),
                  ),
                ],
                moveAnimation: controller,
              ),
            ),
          ),
        );
      }

      // Sample the whole timeline: travel, impact, recoil, rest.
      for (final t in [0.0, 0.4, 0.72, 0.9, 1.0]) {
        await tester.pumpWidget(board(t));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'threw at t=$t');
      }
    });

    testWidgets('paints a walking creature and a lunging one without throwing',
        (tester) async {
      final controller = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 900),
      );
      addTearDown(controller.dispose);

      Minion creature(String id, HexCoord at, {bool big = false}) => Minion(
        id: id,
        ownerId: 'me',
        teamId: 'solo',
        position: at,
        affinity: SpellAffinity.fire,
        stats: const MinionStats(
          maxHp: 2,
          damage: 1,
          moveSpeed: 1,
          attackRange: 0,
        ),
        elementSequence: const [BorderZone.fire],
        abilities: big ? const {SummonAbility.big} : const {},
      );

      Widget board(double t) {
        controller.value = t;
        return MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              size: const Size(400, 400),
              painter: BattlefieldPainter(
                radius: 4,
                hexSize: hexSize,
                localPlayerId: 'me',
                localTeamId: 'solo',
                occupancy: const {'me': HexCoord(0, 3)},
                minions: [
                  creature('walker', const HexCoord(0, 0)),
                  creature('striker', const HexCoord(-1, 0)),
                  // A Big creature moves as one body; its outlying footprint
                  // tiles must ride along with the anchor.
                  creature('bulk', const HexCoord(2, 0), big: true),
                ],
                minionMoveAnimations: const [
                  MinionMoveAnimation(
                    minionId: 'walker',
                    path: [HexCoord(-2, 0), HexCoord(-1, 0), HexCoord(0, 0)],
                  ),
                  MinionMoveAnimation(
                    minionId: 'striker',
                    path: [HexCoord(-1, 0)],
                    lungeTile: HexCoord(0, 0),
                  ),
                  MinionMoveAnimation(
                    minionId: 'bulk',
                    path: [HexCoord(3, 0), HexCoord(2, 0)],
                  ),
                ],
                moveAnimation: controller,
              ),
            ),
          ),
        );
      }

      for (final t in [0.0, 0.4, 0.72, 0.9, 1.0]) {
        await tester.pumpWidget(board(t));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'threw at t=$t');
      }
    });
  });

  group('avatar sprite seam', () {
    test('every wizard resolves to a catalog entry', () {
      const assignment = AvatarAssignment();
      for (final id in ['alice', 'bob', '', 'a-very-long-player-id-0123']) {
        expect(kAvatarCatalog, contains(assignment.artFor(id)));
      }
    });

    test('assignment is a pure function of the playerId', () {
      // Both devices in a LAN duel must independently pick the same sprite for
      // the same wizard; nothing is exchanged over the wire to make that true.
      const a = AvatarAssignment();
      const b = AvatarAssignment();
      expect(a.artFor('wizard-1').id, b.artFor('wizard-1').id);
      expect(a.artFor('wizard-1').id, isNot(a.artFor('wizard-2').id));
    });

    test('an explicit choice wins, and an unknown one degrades quietly', () {
      final chosen = kAvatarCatalog.last;
      final explicit = AvatarAssignment(explicit: {'p': chosen.id});
      expect(explicit.artFor('p').id, chosen.id);

      // A save file naming a sprite a later pack dropped must still open.
      const stale = AvatarAssignment(explicit: {'p': 'no_such_avatar'});
      expect(kAvatarCatalog, contains(stale.artFor('p')));
    });

    test('frame rects stay inside the atlas', () {
      final bounds = Rect.fromLTWH(
        0,
        0,
        kAvatarAtlasWidth.toDouble(),
        kAvatarAtlasHeight.toDouble(),
      );
      for (final art in kAvatarCatalog) {
        for (final facing in AvatarFacing.values) {
          for (final pose in AvatarPose.values) {
            final rect = art.frameRect(facing, pose);
            expect(bounds.contains(rect.topLeft), isTrue, reason: art.id);
            expect(
              bounds.contains(rect.bottomRight - const Offset(1, 1)),
              isTrue,
              reason: art.id,
            );
          }
        }
      }
    });

    test('facing follows the on-screen direction of travel', () {
      expect(facingForDelta(const Offset(10, 0)), AvatarFacing.right);
      expect(facingForDelta(const Offset(-10, 0)), AvatarFacing.left);
      expect(facingForDelta(const Offset(0, 10)), AvatarFacing.down);
      expect(facingForDelta(const Offset(0, -10)), AvatarFacing.up);
      // A flat-top grid's diagonal steps (|dx| = 1.5·hexSize,
      // |dy| ≈ 0.87·hexSize) read as side-steps, not as walking up or down.
      expect(facingForDelta(const Offset(36, -20.8)), AvatarFacing.right);
      expect(facingForDelta(const Offset(-36, 20.8)), AvatarFacing.left);
      // A wizard who did not move keeps the fallback.
      expect(facingForDelta(Offset.zero), AvatarFacing.down);
    });
  });
}
