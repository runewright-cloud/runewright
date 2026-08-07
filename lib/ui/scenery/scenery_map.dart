// SPDX-License-Identifier: GPL-3.0-or-later
//
// scenery_map.dart — deterministic terrain generator for the battle backdrop.
//
// PURELY COSMETIC. Nothing here feeds gameplay, hashing, or the lockstep state
// hash; see scenery_tile.dart's header. It is nonetheless *deterministic* and
// platform-independent, so both devices in a LAN duel that seed from the shared
// matchId look at the same landscape — a duel should feel like one place, not
// two.
//
// ── How "logical transitions" are guaranteed ─────────────────────────────────
//
// Naive per-hex random tiles give a confetti of snow beside lava beside sand.
// Naive smoothing gives blobs that still butt incompatible biomes together. So
// terrain is not chosen per tile at all; it is *derived* from two continuous
// fields, in four steps:
//
//   1. **Two fBm value-noise fields** over the hex plane — elevation and
//      moisture. Continuous, so they change gradually across neighbours.
//   2. **Quantile banding** into 5x5 bands, with per-band weights taken from the
//      chosen [SceneryRegion]. Quantiles (rather than fixed cutoffs) mean a
//      region gets the terrain mix it asked for regardless of how the noise
//      happened to land.
//   3. **A Lipschitz-1 clamp** on each band field over the hex adjacency graph.
//      This is the load-bearing step: it computes the largest field <= the
//      banded one for which adjacent hexes never differ by more than one band.
//      Noise alone *nearly* satisfies this; the clamp makes it exact.
//   4. **A biome ladder** ([_kLadder]) mapping (elevation, moisture) band pairs
//      to tiles, authored so that any two cells within one step of each other
//      are a plausible pair. Combined with step 3, every adjacency in the output
//      is legal *by construction* — no post-hoc fixups.
//
// Feature passes (ruins, burn scars) run last and grow only within declared
// substrates, so their boundaries are legal too. [sceneryAdjacencyIsLegal]
// states the resulting invariant; scenery_map_test.dart enforces it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../../battle/models/hex_battlefield.dart'
    show hexDistance, hexNeighbors;
import '../../engine/hex_grid.dart' show HexCoord;
import 'scenery_tile.dart';

// ── Region presets ───────────────────────────────────────────────────────────

/// A named landscape preset: how the 5 elevation and 5 moisture bands are
/// weighted, plus how much man-made/burnt detail to scatter.
///
/// Each battle picks one. Without them every map converges on the same
/// everything-at-once noise soup; with them a duel reads as taking place
/// *somewhere*.
///
/// The lowland presets deliberately carry **zero weight in the top elevation
/// band** and very little in the one below: downs and bogs have no highland
/// pinewood, and a stray stand of crest forest in a meadow reads as a mistake.
/// Regions that should climb say so explicitly.
enum SceneryRegion {
  verdantDowns(
    'Verdant Downs',
    elevationWeights: [0.26, 0.40, 0.28, 0.06, 0.00],
    moistureWeights: [0.04, 0.14, 0.30, 0.32, 0.20],
    ruinClusters: 2,
    burnClusters: 1,
  ),
  pinewood(
    'Pinewood',
    elevationWeights: [0.18, 0.38, 0.38, 0.06, 0.00],
    moistureWeights: [0.02, 0.10, 0.24, 0.34, 0.30],
    ruinClusters: 1,
    burnClusters: 2,
  ),
  sunscorchedFlats(
    'Sunscorched Flats',
    elevationWeights: [0.30, 0.40, 0.24, 0.06, 0.00],
    moistureWeights: [0.38, 0.34, 0.20, 0.06, 0.02],
    ruinClusters: 3,
    burnClusters: 2,
  ),
  ashenSteppe(
    'Ashen Steppe',
    elevationWeights: [0.20, 0.34, 0.30, 0.14, 0.02],
    moistureWeights: [0.28, 0.34, 0.26, 0.10, 0.02],
    ruinClusters: 2,
    burnClusters: 3,
  ),
  // Dry upland: sand and dry grass on the heights, heavily ruined.
  //
  // Was 'Chalk Hills' until 2026-08-07, when chalk left the walkable palette
  // for the raised walls. Its weights are unchanged — what it produces on the
  // dry side is the same as it always was; only the bare crag it used to reach
  // above the treeline is gone. Its ruin density is now what distinguishes it
  // from Sunscorched Flats, which sits lower and drier.
  dryDowns(
    'Dry Downs',
    elevationWeights: [0.12, 0.26, 0.34, 0.24, 0.04],
    moistureWeights: [0.24, 0.32, 0.26, 0.14, 0.04],
    ruinClusters: 3,
    burnClusters: 1,
  ),
  // The high preset, and the only one weighted into the crest band at all.
  // Damper than Dry Downs, so it tops out in dense pinewood; with no ruins and
  // no burn scars it is the one region that reads as untouched.
  pineCrest(
    'Pine Crest',
    elevationWeights: [0.04, 0.14, 0.28, 0.34, 0.20],
    moistureWeights: [0.08, 0.18, 0.28, 0.28, 0.18],
    ruinClusters: 1,
    burnClusters: 0,
  ),
  bogHollow(
    'Bog Hollow',
    elevationWeights: [0.44, 0.34, 0.18, 0.04, 0.00],
    moistureWeights: [0.02, 0.08, 0.20, 0.30, 0.40],
    ruinClusters: 2,
    burnClusters: 1,
  );

  const SceneryRegion(
    this.label, {
    required this.elevationWeights,
    required this.moistureWeights,
    required this.ruinClusters,
    required this.burnClusters,
  });

  /// Human-readable locale name, e.g. shown in a battle HUD caption.
  final String label;

  /// Share of tiles landing in each elevation band, low → high. Sums to 1.
  final List<double> elevationWeights;

  /// Share of tiles landing in each moisture band, arid → wet. Sums to 1.
  final List<double> moistureWeights;

  /// Target count of paved-ruin clusters per map (scaled by map area).
  final int ruinClusters;

  /// Target count of burn-scar clusters per map (scaled by map area).
  final int burnClusters;
}

// ── The biome ladder ─────────────────────────────────────────────────────────

const int _kBands = 5;

/// (elevation band, moisture band) → terrain. Rows are elevation low → high;
/// columns are moisture arid → wet.
///
/// Authored so every pair of cells within one step of each other — including
/// diagonals, since a hex neighbour may differ by one band in *both* fields —
/// is a transition that reads naturally on the ground: bare crag meets sand,
/// scrub meets forest, forest thins to rock at the treeline, clay meets sand.
///
/// Lava, open water, snow, rime, ice and chalk are deliberately absent — see
/// [SceneryTile.walkable] for why. With both the alpine tier and (as of
/// 2026-08-07) bare rock gone, the elevation axis tops out at a **pine
/// treeline**: the climb ends in dense pinewood rather than crag, and the arid
/// column stays sand all the way up, since the one place nothing grows is the
/// dry side. The single abrupt neighbour that leaves — crest pine against
/// highland sand, on the diagonal — replaces the equally abrupt chalk-meets-sand
/// it used to have there, so the ladder is no rougher than before.
///
/// Kept hand-aligned (`dart format off`) because the grid layout *is* the
/// documentation: reading down a column shows a climb, reading across a row
/// shows a drying-out, and both must stay plausible step by step.
// Short aliases exist only to keep the table below legible as a grid.
const _clay = SceneryTile.redClay;
const _dirt = SceneryTile.dirt;
const _mire = SceneryTile.mossSoil;
const _sand = SceneryTile.sand;
const _dry = SceneryTile.dryGrass;
const _scrb = SceneryTile.patchGrass;
const _gras = SceneryTile.grass;
const _pine = SceneryTile.forest;

// dart format off
const List<List<SceneryTile>> _kLadder = [
  //  arid    dry     moderate  damp    wet
  [   _clay,  _dirt,  _scrb,    _gras,  _mire ],  // lowland
  [   _sand,  _dry,   _gras,    _gras,  _pine ],  // plains
  [   _sand,  _dry,   _scrb,    _pine,  _pine ],  // hills
  [   _sand,  _dry,   _pine,    _pine,  _pine ],  // highland
  [   _sand,  _pine,  _pine,    _pine,  _pine ],  // crest
];
// dart format on

// ── Feature passes ───────────────────────────────────────────────────────────

/// A scattered detail terrain grown in small clusters over the ladder output.
class _Feature {
  const _Feature({
    required this.tile,
    required this.substrates,
    required this.avoidNeighbours,
    required this.minSize,
    required this.maxSize,
  });

  final SceneryTile tile;

  /// Ladder tiles this feature may replace.
  final Set<SceneryTile> substrates;

  /// A cell may not join the cluster if any neighbour is one of these — you do
  /// not pave a bog, and waterlogged ground does not carry a fire.
  final Set<SceneryTile> avoidNeighbours;

  final int minSize;
  final int maxSize;
}

const _kRuins = _Feature(
  tile: SceneryTile.cobble,
  substrates: {
    SceneryTile.dirt,
    SceneryTile.redClay,
    SceneryTile.patchGrass,
    SceneryTile.grass,
    SceneryTile.dryGrass,
    SceneryTile.sand,
  },
  avoidNeighbours: {SceneryTile.mossSoil},
  minSize: 3,
  maxSize: 8,
);

const _kBurnScar = _Feature(
  tile: SceneryTile.charcoal,
  substrates: {
    SceneryTile.forest,
    SceneryTile.patchGrass,
    SceneryTile.dryGrass,
    SceneryTile.grass,
    SceneryTile.dirt,
  },
  avoidNeighbours: {SceneryTile.mossSoil},
  minSize: 2,
  maxSize: 6,
);

const List<_Feature> _kFeatures = [_kRuins, _kBurnScar];

// ── Noise tuning ─────────────────────────────────────────────────────────────

/// Base frequency in hex-plane units (one hex step is ~1.5–1.73 units), chosen
/// so a biome band spans roughly 5–8 hexes. Lower = broader, calmer landscapes;
/// raising it much past this makes the Lipschitz clamp do visible work.
const double _kBaseFrequency = 0.085;
const int _kOctaves = 4;
const double _kLacunarity = 2.0;
const double _kGain = 0.5;

// ── Public API ───────────────────────────────────────────────────────────────

/// A generated backdrop: one terrain tile per hex within [radius] of the origin.
class SceneryMap {
  SceneryMap({
    required this.tiles,
    required this.region,
    required this.radius,
    required this.seed,
  });

  /// Hex → terrain. Dense over the disc of [radius] around HexCoord(0, 0).
  final Map<HexCoord, SceneryTile> tiles;

  final SceneryRegion region;
  final int radius;
  final int seed;

  SceneryTile? tileAt(HexCoord hex) => tiles[hex];

  /// Draw order: back to front in screen space, so each tile's 16px extrusion
  /// lands on top of the tile behind it. Screen y is monotone in
  /// (q/2 + r), and x in q, which is all the ordering needs.
  late final List<HexCoord> paintOrder = () {
    final ordered = tiles.keys.toList();
    ordered.sort((a, b) {
      final ay = a.q + 2 * a.r;
      final by = b.q + 2 * b.r;
      if (ay != by) return ay.compareTo(by);
      return a.q.compareTo(b.q);
    });
    return ordered;
  }();
}

/// Folds arbitrary bytes (e.g. a duel's shared `matchId`) into a generator seed.
///
/// SHA-256 rather than [Object.hashCode] so two devices agree — hashCode is not
/// stable across runs or platforms.
int scenerySeedFromBytes(Uint8List bytes) {
  final digest = sha256.convert(bytes).bytes;
  var seed = 0;
  for (var i = 0; i < 4; i++) {
    seed = ((seed << 8) | digest[i]) & 0x7FFFFFFF;
  }
  return seed;
}

/// Default [generateSceneryMap.focusRadius] — roughly a battlefield's worth of
/// tiles, so a caller that does not care still gets arena-weighted banding.
const int kDefaultSceneryFocusRadius = 5;

/// Generates the backdrop for one battle.
///
/// [seed] fully determines the output: same seed, [radius] and [focusRadius]
/// always give the same map, on any platform. Pass [region] to pin the
/// landscape; otherwise one is chosen from the seed.
///
/// [focusRadius] is the part of the map the player actually looks at — normally
/// the battlefield radius. Band thresholds are computed from *those* cells
/// only, then applied everywhere. Without this the quantiles describe the whole
/// generated disc, and since the arena is a small fraction of it, a map billed
/// as Verdant Downs can quite legitimately drop a snowfield on the battlefield
/// and keep its meadows out beyond the horizon. Focusing the statistics makes
/// the arena representative and lets the outskirts run to extremes, which is
/// also the better picture: distant peaks, near meadow.
SceneryMap generateSceneryMap({
  required int seed,
  required int radius,
  SceneryRegion? region,
  int focusRadius = kDefaultSceneryFocusRadius,
}) {
  assert(radius >= 0);
  final chosen = region ?? _pickRegion(seed);

  // Deterministic cell order: the whole pipeline iterates this list, so map
  // insertion order (and therefore every downstream iteration) is fixed.
  final cells = <HexCoord>[];
  for (var q = -radius; q <= radius; q++) {
    for (var r = -radius; r <= radius; r++) {
      final hex = HexCoord(q, r);
      if (hexDistance(const HexCoord(0, 0), hex) <= radius) cells.add(hex);
    }
  }

  final focus = math.min(focusRadius, radius);
  final elevation = _bandField(
    cells,
    seed ^ 0x5eed0001,
    chosen.elevationWeights,
    focus,
  );
  final moisture = _bandField(
    cells,
    seed ^ 0x5eed0002,
    chosen.moistureWeights,
    focus,
  );

  final tiles = <HexCoord, SceneryTile>{};
  for (var i = 0; i < cells.length; i++) {
    tiles[cells[i]] = _kLadder[elevation[i]][moisture[i]];
  }

  _scatterFeatures(tiles, cells, chosen, seed);

  return SceneryMap(tiles: tiles, region: chosen, radius: radius, seed: seed);
}

/// True iff [a] and [b] are a transition the generator is allowed to produce.
///
/// Derived from [_kLadder] and the feature substrates rather than hand-listed,
/// so it cannot drift from the generator. This is the invariant
/// `scenery_map_test.dart` checks across every region and many seeds.
bool sceneryAdjacencyIsLegal(SceneryTile a, SceneryTile b) =>
    a == b || _legalPairs.contains(_pairKey(a, b));

int _pairKey(SceneryTile a, SceneryTile b) {
  final lo = a.index < b.index ? a.index : b.index;
  final hi = a.index < b.index ? b.index : a.index;
  return lo * SceneryTile.values.length + hi;
}

final Set<int> _legalPairs = _buildLegalPairs();

Set<int> _buildLegalPairs() {
  final pairs = <int>{};

  // 1. Every pair of ladder cells within one band step of each other, in both
  //    axes — exactly the pairs the Lipschitz clamp permits to become adjacent.
  final ladderNeighbours = <SceneryTile, Set<SceneryTile>>{};
  for (var e = 0; e < _kBands; e++) {
    for (var m = 0; m < _kBands; m++) {
      for (var de = -1; de <= 1; de++) {
        for (var dm = -1; dm <= 1; dm++) {
          final e2 = e + de, m2 = m + dm;
          if (e2 < 0 || e2 >= _kBands || m2 < 0 || m2 >= _kBands) continue;
          final a = _kLadder[e][m];
          final b = _kLadder[e2][m2];
          pairs.add(_pairKey(a, b));
          (ladderNeighbours[a] ??= {}).add(b);
          (ladderNeighbours[b] ??= {}).add(a);
        }
      }
    }
  }

  // 2. Feature tiles. A cluster only ever replaces one of its substrates, so
  //    its boundary neighbours are substrates or tiles ladder-adjacent to a
  //    substrate — minus anything the growth rule refuses to sit beside.
  for (final feature in _kFeatures) {
    final touching = <SceneryTile>{...feature.substrates};
    for (final s in feature.substrates) {
      touching.addAll(ladderNeighbours[s] ?? const {});
    }
    touching.removeAll(feature.avoidNeighbours);
    for (final t in touching) {
      pairs.add(_pairKey(feature.tile, t));
    }
    // Two clusters of different kinds may grow into contact.
    for (final other in _kFeatures) {
      pairs.add(_pairKey(feature.tile, other.tile));
    }
  }

  return pairs;
}

// ── Field construction ───────────────────────────────────────────────────────

SceneryRegion _pickRegion(int seed) =>
    SceneryRegion.values[_hash2(seed, 0x9e37, 0x5f1) %
        SceneryRegion.values.length];

/// Samples fBm over [cells], quantile-bands it by [weights] (thresholds taken
/// from the cells within [focusRadius] of the origin), then clamps the result to
/// Lipschitz-1 over the hex graph. Returns one band index per cell, parallel to
/// [cells].
List<int> _bandField(
  List<HexCoord> cells,
  int salt,
  List<double> weights,
  int focusRadius,
) {
  // fBm in hex-plane units. Using the flat-top pixel mapping (rather than raw
  // q/r) keeps the noise isotropic — otherwise features come out sheared.
  final values = <double>[
    for (final hex in cells)
      _fbm(
        1.5 * hex.q * _kBaseFrequency,
        (math.sqrt(3) / 2 * hex.q + math.sqrt(3) * hex.r) * _kBaseFrequency,
        salt,
      ),
  ];

  // Thresholds come from the focus area only (see generateSceneryMap), but are
  // applied to every cell — so terrain past the arena is free to run higher or
  // lower than the preset's nominal mix.
  const origin = HexCoord(0, 0);
  final focusValues = <double>[
    for (var i = 0; i < cells.length; i++)
      if (hexDistance(origin, cells[i]) <= focusRadius) values[i],
  ];

  final bands = _quantiseToBands(
    values,
    focusValues.isEmpty ? values : focusValues,
    weights,
  );
  return _lipschitzClamp(cells, bands);
}

/// Assigns each of [values] a band 0..4. Cutoffs are the quantiles of
/// [sample] at the cumulative [weights], so the share of *sample* cells in each
/// band matches the weights as closely as integer cutoffs allow.
List<int> _quantiseToBands(
  List<double> values,
  List<double> sample,
  List<double> weights,
) {
  final sorted = List<double>.from(sample)..sort();
  final n = sorted.length;

  // Upper cutoff value for bands 0..3; band 4 takes the remainder.
  final cutoffs = <double>[];
  var cumulative = 0.0;
  for (var k = 0; k < _kBands - 1; k++) {
    cumulative += weights[k];
    final idx = (cumulative * n).round().clamp(0, n - 1);
    cutoffs.add(sorted[idx]);
  }

  return [
    for (final v in values)
      () {
        var band = 0;
        while (band < cutoffs.length && v >= cutoffs[band]) {
          band++;
        }
        return band;
      }(),
  ];
}

/// Largest field <= [bands] in which adjacent hexes differ by at most one.
///
/// A grassfire relaxation: seed a worklist in increasing band order, and
/// whenever a neighbour exceeds `value + 1`, pull it down. Terminates because
/// every write strictly lowers a bounded non-negative integer.
///
/// It only ever lowers values, which biases very slightly toward the low end of
/// each field. That is deliberate — lowering is what makes the result provably
/// Lipschitz-1 in a single pass — and with [_kBaseFrequency] tuned as it is the
/// clamp touches only a handful of cells per map.
List<int> _lipschitzClamp(List<HexCoord> cells, List<int> bands) {
  final index = <HexCoord, int>{
    for (var i = 0; i < cells.length; i++) cells[i]: i,
  };
  final out = List<int>.from(bands);

  final order = List<int>.generate(cells.length, (i) => i)
    ..sort((a, b) {
      if (out[a] != out[b]) return out[a].compareTo(out[b]);
      return a.compareTo(b);
    });

  final work = List<int>.from(order);
  var head = 0;
  while (head < work.length) {
    final i = work[head++];
    final limit = out[i] + 1;
    for (final n in hexNeighbors(cells[i])) {
      final j = index[n];
      if (j == null) continue;
      if (out[j] > limit) {
        out[j] = limit;
        work.add(j);
      }
    }
  }

  return out;
}

// ── Feature scattering ───────────────────────────────────────────────────────

void _scatterFeatures(
  Map<HexCoord, SceneryTile> tiles,
  List<HexCoord> cells,
  SceneryRegion region,
  int seed,
) {
  // Cluster counts are authored for a mid-size map and scale with the *square
  // root* of area, not area itself: linear scaling put paving on 9-14% of a
  // large map, which reads as a plaza rather than as ruins.
  final areaScale = math.max(1.0, math.sqrt(cells.length / 130.0));
  final counts = [
    (region.ruinClusters * areaScale).round(),
    (region.burnClusters * areaScale).round(),
  ];

  for (var f = 0; f < _kFeatures.length; f++) {
    final feature = _kFeatures[f];
    // Clusters of the same kind keep their distance, so several small ruins
    // stay several small ruins instead of merging into one slab.
    final placed = <HexCoord>{};
    for (var c = 0; c < counts[f]; c++) {
      _growCluster(
        tiles,
        cells,
        feature,
        seed ^ (0xfea70000 + f * 0x100 + c),
        placed,
      );
    }
  }
}

/// Minimum gap, in hexes, between two clusters of the same feature.
const int _kFeatureSeparation = 4;

/// Flood-grows one cluster of [feature] from a seed cell, replacing only its
/// substrates and never stepping beside a tile it must avoid. Silently does
/// nothing if the map holds no eligible cell — a Bog Hollow map may
/// legitimately have nowhere to put paving.
void _growCluster(
  Map<HexCoord, SceneryTile> tiles,
  List<HexCoord> cells,
  _Feature feature,
  int salt,
  Set<HexCoord> placed,
) {
  bool eligible(HexCoord hex) {
    final base = tiles[hex];
    if (base == null || !feature.substrates.contains(base)) return false;
    for (final n in hexNeighbors(hex)) {
      final t = tiles[n];
      if (t != null && feature.avoidNeighbours.contains(t)) return false;
    }
    return true;
  }

  bool farFromOtherClusters(HexCoord hex) {
    for (final other in placed) {
      if (hexDistance(hex, other) < _kFeatureSeparation) return false;
    }
    return true;
  }

  final candidates = cells
      .where((h) => eligible(h) && farFromOtherClusters(h))
      .toList();
  if (candidates.isEmpty) return;

  final start = candidates[_hash2(salt, 0, 0x1) % candidates.length];
  final target =
      feature.minSize +
      _hash2(salt, 1, 0x2) % (feature.maxSize - feature.minSize + 1);

  final blob = <HexCoord>{start};
  final frontier = <HexCoord>[start];
  var step = 0;

  while (blob.length < target && frontier.isNotEmpty) {
    // Deterministic pick from the frontier, then a deterministic neighbour.
    final pick = _hash2(salt, 2 + step, 0x3) % frontier.length;
    final from = frontier[pick];
    final ring = hexNeighbors(from);
    var grew = false;
    final offset = _hash2(salt, 2 + step, 0x4) % ring.length;
    for (var k = 0; k < ring.length; k++) {
      final next = ring[(offset + k) % ring.length];
      if (blob.contains(next) || !eligible(next)) continue;
      blob.add(next);
      frontier.add(next);
      grew = true;
      break;
    }
    if (!grew) frontier.removeAt(pick);
    step++;
    if (step > 200) break; // belt and braces; growth is bounded by maxSize
  }

  for (final hex in blob) {
    tiles[hex] = feature.tile;
  }
  placed.addAll(blob);
}

// ── Deterministic value noise ────────────────────────────────────────────────
//
// 32-bit integer hashing throughout (every intermediate masked to 32 bits) so
// the output is identical on any Dart runtime, including one where int is not
// 64-bit. Double arithmetic below is IEEE-754 +,-,* only, which is likewise
// exactly reproducible.

int _hash2(int x, int y, int salt) {
  var h = (x * 0x27d4eb2d) & 0xFFFFFFFF;
  h = (h ^ ((y * 0x165667b1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  h = (h ^ ((salt * 0x9e3779b1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  h = (h ^ (h >>> 15)) & 0xFFFFFFFF;
  h = (h * 0x2545f491) & 0xFFFFFFFF;
  h = (h ^ (h >>> 13)) & 0xFFFFFFFF;
  h = (h * 0x3d4d51c3) & 0xFFFFFFFF;
  h = (h ^ (h >>> 16)) & 0xFFFFFFFF;
  return h;
}

double _latticeValue(int x, int y, int salt) =>
    _hash2(x, y, salt) / 4294967296.0;

double _smoothstep(double t) => t * t * (3.0 - 2.0 * t);

double _valueNoise(double x, double y, int salt) {
  final x0 = x.floor();
  final y0 = y.floor();
  final tx = _smoothstep(x - x0);
  final ty = _smoothstep(y - y0);

  final v00 = _latticeValue(x0, y0, salt);
  final v10 = _latticeValue(x0 + 1, y0, salt);
  final v01 = _latticeValue(x0, y0 + 1, salt);
  final v11 = _latticeValue(x0 + 1, y0 + 1, salt);

  final top = v00 + (v10 - v00) * tx;
  final bottom = v01 + (v11 - v01) * tx;
  return top + (bottom - top) * ty;
}

/// Fractal Brownian motion: octaves of value noise at doubling frequency and
/// halving amplitude, normalised to roughly [0, 1].
double _fbm(double x, double y, int salt) {
  var total = 0.0;
  var amplitude = 1.0;
  var frequency = 1.0;
  var norm = 0.0;
  for (var o = 0; o < _kOctaves; o++) {
    total +=
        _valueNoise(x * frequency, y * frequency, salt + o * 0x7f4a) *
        amplitude;
    norm += amplitude;
    amplitude *= _kGain;
    frequency *= _kLacunarity;
  }
  return total / norm;
}
