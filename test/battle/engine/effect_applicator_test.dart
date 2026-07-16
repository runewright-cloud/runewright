// SPDX-License-Identifier: GPL-3.0-or-later
//
// effect_applicator_test.dart — direct EffectApplicator.apply() tests for
// the conveyor-direction seam: a caster-chosen direction is applied verbatim;
// an absent one falls back to a real (deterministic, seeded) direction; an
// Illusions copy of a ConveyorTile defaults to a rotational loop; and a
// knockback that lands an avatar on a conveyor mid-spell pushes further and
// emits a ConveyorChainEvent for the UI.

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(String id, HexCoord pos, {String teamId = 'a'}) => WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 3,
    );

BattleState _state({
  List<WizardAvatar>? avatars,
  Map<HexCoord, TileEffect> tileEffects = const {},
  int radius = 6,
}) {
  final av = avatars ?? [_avatar('caster', const HexCoord(0, 0))];
  final battlefield = Battlefield(radius: radius);
  for (final a in av) {
    battlefield.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: av,
    teams: const [],
    battlefield: battlefield,
    tileEffects: Map.of(tileEffects),
  );
}

ApplyContext _ctx({
  required BattleState state,
  required WizardAvatar caster,
  required SpellEffect effect,
  required HexCoord targetTile,
  HexCoord? chosenConveyorDirection,
  Random? rng,
  Map<String, List<HexCoord>>? movePaths,
  List<ConveyorChainEvent>? conveyorChainEvents,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: SpellAffinity.air,
        effectKind: EffectKind.tileModification,
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: rng ?? Random(7),
      movePaths: movePaths,
      chosenConveyorDirection: chosenConveyorDirection,
      conveyorChainEvents: conveyorChainEvents,
    );

void main() {
  group('conveyor direction resolution', () {
    test('a caster-chosen direction is applied verbatim', () {
      final state = _state();
      final caster = state.avatars.first;
      const target = HexCoord(2, 0);
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: target,
        effect: const TileModificationEffect(
          affinity: SpellAffinity.air,
          tileEffect: ConveyorTile(), // sentinel, direction not yet set
        ),
        chosenConveyorDirection: const HexCoord(0, 1),
      ));

      final placed = state.tileEffects[target] as ConveyorTile;
      expect(placed.direction, const HexCoord(0, 1));
    });

    test('no chosen direction falls back to a real direction from the shared rng', () {
      final state = _state();
      final caster = state.avatars.first;
      const target = HexCoord(2, 0);
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: target,
        effect: const TileModificationEffect(
          affinity: SpellAffinity.air,
          tileEffect: ConveyorTile(),
        ),
        rng: Random(42),
      ));

      final placed = state.tileEffects[target] as ConveyorTile;
      expect(placed.directionSet, isTrue);
      expect(HexGrid.directions, contains(placed.direction));
    });

    test('an already-directed ConveyorTile is placed unchanged', () {
      final state = _state();
      final caster = state.avatars.first;
      const target = HexCoord(2, 0);
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: target,
        effect: const TileModificationEffect(
          affinity: SpellAffinity.air,
          tileEffect: ConveyorTile(direction: HexCoord(1, -1)),
        ),
        chosenConveyorDirection: const HexCoord(0, 1), // must be ignored
      ));

      final placed = state.tileEffects[target] as ConveyorTile;
      expect(placed.direction, const HexCoord(1, -1));
    });
  });

  group('illusion copy of a ConveyorTile', () {
    test('copies onto every open neighbor form a rotational loop (full ring)', () {
      const source = HexCoord(0, 0);
      final state = _state(radius: 8, tileEffects: {
        source: const ConveyorTile(direction: HexCoord(1, 0)),
      });
      final caster = state.avatars.first;

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: source,
        effect: const IllusionEffect(affinity: SpellAffinity.earth, copyTerrainExpand: true),
        rng: Random(3),
      ));

      final ring = HexGrid.clockwiseDirections
          .map((d) => HexCoord(source.q + d.q, source.r + d.r))
          .toList();
      // Every ring tile got a copy, each pointing to a ring-adjacent neighbor
      // (a valid single hex step), forming a closed loop among the 6 copies.
      for (final tile in ring) {
        final effect = state.tileEffects[tile];
        expect(effect, isA<ConveyorTile>(), reason: 'no copy placed at $tile');
        final dir = (effect as ConveyorTile).direction;
        expect(HexGrid.directions, contains(dir));
        final next = HexCoord(tile.q + dir.q, tile.r + dir.r);
        expect(ring, contains(next),
            reason: 'copy at $tile points to $next, not part of the ring');
        expect(state.illusionTerrainTiles, contains(tile));
      }
    });
  });

  group('knockback into a conveyor tile', () {
    test('lands on a conveyor and is pushed further, emitting a chain event', () {
      const casterPos = HexCoord(0, 0);
      const targetPos = HexCoord(1, 0); // adjacent to caster
      const conveyorTile = HexCoord(2, 0); // one further from caster, in push line
      const pushedTo = HexCoord(3, 0);
      final caster = _avatar('caster', casterPos);
      final target = _avatar('victim', targetPos, teamId: 'b');
      final state = _state(
        avatars: [caster, target],
        tileEffects: {
          conveyorTile: const ConveyorTile(direction: HexCoord(1, 0)),
        },
      );

      final events = <ConveyorChainEvent>[];
      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        targetTile: targetPos,
        effect: const DamageEffect(amount: 1, kind: DamageKind.knockback, knockback: 1),
        conveyorChainEvents: events,
      ));

      // _pushDir pushes straight away from the caster: victim at (1,0) with
      // caster at (0,0) bounces to (2,0) -- the conveyor tile -- which then
      // pushes it one further to (3,0).
      expect(target.position, pushedTo);
      expect(events, hasLength(1));
      expect(events.single.entityId, 'victim');
      expect(events.single.path, [conveyorTile, pushedTo]);
    });
  });
}
