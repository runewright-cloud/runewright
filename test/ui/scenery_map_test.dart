// SPDX-License-Identifier: GPL-3.0-or-later
//
// scenery_map_test.dart — invariants for the cosmetic battle backdrop.
//
// The load-bearing test here is "every adjacency is legal". The generator's
// whole claim is that terrain transitions read logically, and that claim rests
// on the Lipschitz-1 clamp holding for every cell of every map. A regression
// there is invisible in a unit test of any single function and glaring on
// screen, so it is checked exhaustively over every region and many seeds.

import 'dart:typed_data';

import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show hexDistance, hexNeighbors;
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/ui/scenery/scenery_map.dart';
import 'package:rune_duel/ui/scenery/scenery_painter.dart'
    show sceneryRadiusForPanel;
import 'package:rune_duel/ui/scenery/scenery_tile.dart';

/// Seeds used by the sweeping invariant tests. Arbitrary but fixed, so a
/// failure is reproducible.
const List<int> _seeds = [
  0,
  1,
  2,
  7,
  42,
  99,
  1234,
  65535,
  1048576,
  99991,
  31337,
  2026072800,
];

void main() {
  group('generateSceneryMap — structure', () {
    test('covers exactly the hex disc of the requested radius', () {
      const radius = 9;
      final map = generateSceneryMap(seed: 5, radius: radius);

      var expected = 0;
      for (var q = -radius; q <= radius; q++) {
        for (var r = -radius; r <= radius; r++) {
          if (hexDistance(const HexCoord(0, 0), HexCoord(q, r)) <= radius) {
            expected++;
          }
        }
      }

      expect(map.tiles.length, expected);
      expect(map.tiles.length, 1 + 3 * radius * (radius + 1));
      for (final hex in map.tiles.keys) {
        expect(
          hexDistance(const HexCoord(0, 0), hex),
          lessThanOrEqualTo(radius),
        );
      }
    });

    test('radius 0 yields the single origin tile', () {
      final map = generateSceneryMap(seed: 3, radius: 0);
      expect(map.tiles.keys.toList(), [const HexCoord(0, 0)]);
    });

    test('paintOrder covers every tile, back to front', () {
      final map = generateSceneryMap(seed: 11, radius: 6);
      expect(map.paintOrder.toSet(), map.tiles.keys.toSet());
      expect(map.paintOrder.length, map.tiles.length);

      // Screen y is monotone in (q + 2r) for this grid; a tile must never be
      // drawn after something behind it, or its extrusion lands wrong.
      var previous = -1 << 30;
      for (final hex in map.paintOrder) {
        final depth = hex.q + 2 * hex.r;
        expect(depth, greaterThanOrEqualTo(previous));
        previous = depth;
      }
    });
  });

  group('generateSceneryMap — determinism', () {
    test('same seed and radius reproduce an identical map', () {
      for (final seed in _seeds) {
        final a = generateSceneryMap(seed: seed, radius: 8);
        final b = generateSceneryMap(seed: seed, radius: 8);
        expect(
          b.region,
          a.region,
          reason: 'seed $seed picked a different region',
        );
        expect(b.tiles, a.tiles, reason: 'seed $seed produced a different map');
      }
    });

    test('different seeds produce different maps', () {
      final maps = {
        for (final seed in _seeds)
          seed: generateSceneryMap(seed: seed, radius: 8).tiles,
      };
      final distinct = maps.values.map((m) => m.toString()).toSet();
      expect(distinct.length, maps.length);
    });

    test('scenerySeedFromBytes is stable and byte-sensitive', () {
      final a = Uint8List.fromList(List.generate(32, (i) => i));
      final b = Uint8List.fromList(List.generate(32, (i) => i));
      final c = Uint8List.fromList(List.generate(32, (i) => i))..[31] = 0xFF;

      expect(scenerySeedFromBytes(b), scenerySeedFromBytes(a));
      expect(scenerySeedFromBytes(c), isNot(scenerySeedFromBytes(a)));
      expect(scenerySeedFromBytes(a), isNonNegative);
    });

    test('two devices seeding from a shared matchId agree', () {
      // The LAN case: neither device sends terrain, they just both hash the
      // matchId they already agreed on.
      final matchId = Uint8List.fromList(
        List.generate(16, (i) => (i * 37 + 11) & 0xFF),
      );
      final host = generateSceneryMap(
        seed: scenerySeedFromBytes(matchId),
        radius: 10,
      );
      final guest = generateSceneryMap(
        seed: scenerySeedFromBytes(matchId),
        radius: 10,
      );
      expect(guest.region, host.region);
      expect(guest.tiles, host.tiles);
    });
  });

  group('generateSceneryMap — terrain legality', () {
    test('every adjacency is a legal transition, all regions and seeds', () {
      for (final region in SceneryRegion.values) {
        for (final seed in _seeds) {
          final map = generateSceneryMap(
            seed: seed,
            radius: 10,
            region: region,
          );
          for (final entry in map.tiles.entries) {
            for (final neighbour in hexNeighbors(entry.key)) {
              final other = map.tiles[neighbour];
              if (other == null) continue;
              expect(
                sceneryAdjacencyIsLegal(entry.value, other),
                isTrue,
                reason:
                    '${region.name} seed $seed: ${entry.value.name} at '
                    '${entry.key} borders ${other.name} at $neighbour',
              );
            }
          }
        }
      }
    });

    test('only walkable ground is drawn — no lava, water, snow or ice', () {
      for (final region in SceneryRegion.values) {
        for (final seed in _seeds) {
          final map = generateSceneryMap(
            seed: seed,
            radius: 10,
            region: region,
          );
          for (final tile in map.tiles.values) {
            expect(
              tile.isWalkable,
              isTrue,
              reason: '${region.name} seed $seed drew ${tile.name}',
            );
          }
        }
      }
    });

    test('sceneryAdjacencyIsLegal rejects an implausible pair', () {
      // The relation is derived from the ladder, so this guards against it
      // silently degenerating into "everything is legal".
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.sand, SceneryTile.mossSoil),
        isFalse,
        reason: 'desert sand cannot border a bog',
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.redClay, SceneryTile.forest),
        isFalse,
        reason: 'arid clay cannot border pinewood',
      );
      // The removed tiles are not in the ladder at all, so nothing can legally
      // border them — a cheap tripwire if one is ever re-added by accident.
      // Chalk joined them on 2026-08-07, when it was reserved for raised walls.
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.chalk, SceneryTile.sand),
        isFalse,
        reason: 'chalk is wall terrain now, not ground',
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.chalk, SceneryTile.snow),
        isFalse,
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.grass, SceneryTile.water),
        isFalse,
      );

      // ...and it still accepts the ones the ladder authorises.
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.grass, SceneryTile.forest),
        isTrue,
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.sand, SceneryTile.dryGrass),
        isTrue,
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.dryGrass, SceneryTile.forest),
        isTrue,
        reason: 'the treeline: dry grass thinning into pinewood',
      );
      expect(
        sceneryAdjacencyIsLegal(SceneryTile.sand, SceneryTile.sand),
        isTrue,
      );
    });

    test('paving and burn scars never touch the mire', () {
      // You do not pave a bog, and waterlogged ground does not carry a fire.
      const features = {SceneryTile.cobble, SceneryTile.charcoal};
      for (final region in SceneryRegion.values) {
        for (final seed in _seeds) {
          final map = generateSceneryMap(
            seed: seed,
            radius: 10,
            region: region,
          );
          for (final entry in map.tiles.entries) {
            if (!features.contains(entry.value)) continue;
            for (final neighbour in hexNeighbors(entry.key)) {
              expect(
                map.tiles[neighbour],
                isNot(SceneryTile.mossSoil),
                reason:
                    '${region.name} seed $seed: ${entry.value.name} at '
                    '${entry.key} touches mire',
              );
            }
          }
        }
      }
    });

    test('the excluded tiles never appear on any map', () {
      // Lava/water were never drawable; snow, rime and ice were removed on
      // 2026-07-28 for reading as out of place. This is the direct check --
      // the walkable-set test above would also pass if `walkable` itself were
      // widened again by accident.
      const excluded = {
        SceneryTile.lava,
        SceneryTile.magma,
        SceneryTile.water,
        SceneryTile.shallows,
        SceneryTile.snow,
        SceneryTile.frost,
        SceneryTile.ice,
      };
      for (final tile in excluded) {
        expect(
          SceneryTile.walkable,
          isNot(contains(tile)),
          reason: '${tile.name} was re-added to the drawable set',
        );
      }
      for (final region in SceneryRegion.values) {
        for (final seed in _seeds) {
          final map = generateSceneryMap(
            seed: seed,
            radius: 10,
            region: region,
          );
          for (final tile in map.tiles.values) {
            expect(
              excluded,
              isNot(contains(tile)),
              reason: '${region.name} seed $seed drew ${tile.name}',
            );
          }
        }
      }
    });
  });

  group('SceneryRegion — the presets actually differ', () {
    /// Terrains each region should produce at least some of. A region whose
    /// weights stop reaching its characteristic terrain has silently become a
    /// duplicate of another.
    ///
    /// NOTE (2026-08-07): the two ex-rock regions lost their old signature when
    /// chalk moved to the raised walls. Pine Crest (was Stonecrest) now shares
    /// `forest` with Pinewood, and Dry Downs (was Chalk Hills) shares
    /// `dryGrass` with Ashen Steppe — so this test no longer proves those four
    /// are visually distinct, only that each still reaches its terrain. They
    /// are separated in practice by elevation band and ruin/burn density, which
    /// this test cannot see. Worth a design pass.
    const signatures = {
      SceneryRegion.pineCrest: {SceneryTile.forest},
      SceneryRegion.sunscorchedFlats: {SceneryTile.sand, SceneryTile.dryGrass},
      SceneryRegion.pinewood: {SceneryTile.forest},
      SceneryRegion.bogHollow: {SceneryTile.mossSoil},
      SceneryRegion.dryDowns: {SceneryTile.dryGrass},
      SceneryRegion.verdantDowns: {SceneryTile.grass},
      SceneryRegion.ashenSteppe: {SceneryTile.dryGrass},
    };

    test('every region reaches its signature terrain', () {
      for (final entry in signatures.entries) {
        final produced = <SceneryTile>{};
        for (final seed in _seeds) {
          produced.addAll(
            generateSceneryMap(
              seed: seed,
              radius: 10,
              region: entry.key,
            ).tiles.values,
          );
        }
        expect(
          produced.intersection(entry.value),
          isNotEmpty,
          reason: '${entry.key.name} never produced any of ${entry.value}',
        );
      }
    });

    test(
      'a region override pins the region; omitting it picks from the seed',
      () {
        final pinned = generateSceneryMap(
          seed: 4,
          radius: 4,
          region: SceneryRegion.bogHollow,
        );
        expect(pinned.region, SceneryRegion.bogHollow);

        final chosen = {
          for (var seed = 0; seed < 200; seed++)
            generateSceneryMap(seed: seed, radius: 2).region,
        };
        expect(
          chosen.length,
          greaterThan(1),
          reason: 'seed-derived region selection collapsed to one region',
        );
      },
    );

    test('region weights are normalised', () {
      for (final region in SceneryRegion.values) {
        for (final weights in [
          region.elevationWeights,
          region.moistureWeights,
        ]) {
          expect(weights.length, 5, reason: region.name);
          expect(
            weights.reduce((a, b) => a + b),
            closeTo(1.0, 1e-9),
            reason: region.name,
          );
        }
      }
    });
  });

  group('sceneryRadiusForPanel', () {
    test('covers every corner of the panel it was sized for', () {
      const panels = [
        Size(360, 640),
        Size(640, 360),
        Size(1280, 800),
        Size(200, 200),
      ];
      for (final panel in panels) {
        for (final hexSize in [8.0, 20.0, 36.0]) {
          final radius = sceneryRadiusForPanel(panel, hexSize);
          final map = generateSceneryMap(seed: 1, radius: radius);
          // Every hex whose centre falls inside the panel must have terrain.
          final centre = Size(panel.width / 2, panel.height / 2);
          for (var q = -radius; q <= radius; q++) {
            for (var r = -radius; r <= radius; r++) {
              final hex = HexCoord(q, r);
              final x = centre.width + hexSize * 1.5 * q;
              final y =
                  centre.height +
                  hexSize * (0.8660254037844386 * q + 1.7320508075688772 * r);
              if (x < 0 || y < 0 || x > panel.width || y > panel.height) {
                continue;
              }
              expect(
                map.tiles.containsKey(hex),
                isTrue,
                reason: 'panel $panel hexSize $hexSize missed $hex',
              );
            }
          }
        }
      }
    });

    test('degenerate inputs fall back to the margin rather than throwing', () {
      expect(sceneryRadiusForPanel(Size.zero, 20), 2);
      expect(sceneryRadiusForPanel(const Size(100, 100), 0), 2);
    });
  });
}
