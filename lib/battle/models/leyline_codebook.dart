// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_codebook.dart — deterministic derivation of a Mutable Leyline's
// incantation codebook (docs/LEYLINE_SEED_PLAN.md §4, §5, §15; audit Slice B).
//
// ## What this file is
//
// Under a Mutable Leyline the meaning of a formula tail is not the fixed
// `effectKindFromPair` table — it is *derived from the leyline*. This file is
// that derivation, and nothing else: given a canonical [LeylineConfig], it
// produces the complete, ordered, byte-identical assignment of every possible
// formula tail to either one of the sixteen [EffectKind]s or to **noise**.
//
// ## What this file is NOT (Slice B scope)
//
// **Nothing in production reads it.** Formula segmentation still passes
// `kIncantationFormulaLength`, `effectKindFromPair` is untouched, certification
// is untouched, and no battle, preview, or persisted spell consults a codebook.
// Slice C did not change that: it moved the meaning TYPES out to
// `incantation_meaning.dart` (re-exported below) precisely so that ordinary
// code can name a meaning without importing this file and thereby coming
// within reach of [IncantationCodebook.derive]. No production file imports
// this one; a test asserts it.
// This slice exists to pin the consensus bytes *before* they can affect a duel,
// exactly as `LeylineConfig` Slice 1 pinned the config hash before Wild Magic
// v2 consumed it. Wiring it in is the audit's Slice D and requires a
// `kBattleEngineVersion` bump.
//
// ## Why it is pinned by vectors from day one
//
// LEYLINE_SEED_PLAN.md §15: *"Every peer must derive byte-identical codebooks
// from the same configuration."* Two devices that disagree about what
// `fire-fire-fire` means under `rivendell 4` resolve different spells from the
// same certified trajectory — a silent fork, mid-duel. So every byte below is
// pinned by fixed vectors in `test/battle/models/leyline_codebook_test.dart`,
// independently recomputed by `scripts/gen_leyline_codebook_vectors.py`, and
// changing ANY of:
//
//   * a domain tag, its length prefix, or the stream tag bytes;
//   * the element alphabet, its codes, or the enumeration order;
//   * the scoring preimage's field order or widths;
//   * the sort or its tiebreak;
//   * the `noiseCount` arithmetic;
//   * the allocation rule or the effect ordering;
//   * `kIncantationEffectCode`;
//
// is a CONSENSUS CHANGE requiring a lexicon-version bump, not a refactor.
//
// ## The construction, in one paragraph
//
// Enumerate every tail in canonical lexicographic elemental order. Score each
// one with a domain-separated SHA-256 keyed on the leyline's config hash, and
// sort ascending by (score, canonical key bytes) — a *sort-by-hash*
// permutation, not a stateful shuffle, so the result cannot depend on
// iteration order, on a PRNG's algorithm, or on the order anything was
// inserted into a map. Take an exact count of leading entries as meaningful and
// the rest as noise. Deal the meaningful entries round-robin across the sixteen
// effects, in an effect order derived by the same sort-by-hash primitive under
// a different stream tag, so a non-divisible remainder cannot permanently
// favour low-numbered effects.
//
// ## Rulings this file settles (audit §5.2 / §14 R-1 … R-4)
//
//   * **R-1 — permutation:** candidate B, sort-by-hash. See [leylineStreamScore]
//     and [_orderedKeyIndices].
//   * **R-2 — permille → count:** round-half-up on the NOISE count. See
//     [leylineNoiseKeyCount].
//   * **R-3 — allocation:** round-robin over a derived effect order. See
//     [_deriveMeanings].
//   * **R-4 — remainder / domain tags:** the effect order is itself hash-sorted
//     under stream tag [kLeylineEffectOrderStream]; the tags are §4/§8/§9's
//     literal strings, uint8-length-prefixed like every other tag in the
//     codebase.
//
// ## Domain separation
//
// [leylineStreamScore] takes its domain tag as an argument and the three tags
// (§4, §8, §9) live in `leyline_stream.dart`, so the Summon and Armor
// derivations reuse the primitive without inheriting incantation *semantics*.
// **Summon and Armor key spaces are deliberately not defined here** — neither
// domain chunks, both do overlapping four-element window search, and both key
// on the leyline's TRADITION hash rather than its config hash (R-8). They live
// in `leyline_pattern_codebook.dart`. Do not generalise [IncantationCodebook]
// to try to serve them.
//
// The one asymmetry worth stating twice: this codebook's keys are `4^(L-1)`
// tails and its size, its noise share and its very existence all move with
// `formulaLength` and `noiseDensityPermille`. The pattern codebooks' keys are
// the 256 four-element windows under every grammar. That is why they bind
// different hashes.

import 'dart:typed_data';

import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/leyline_stream.dart';
import 'package:rune_duel/engine/border_zone.dart';

export 'package:rune_duel/battle/models/incantation_meaning.dart'
    show
        IncantationEffect,
        IncantationMeaning,
        IncantationNoise,
        kIncantationNoise;

// The primitives this derivation is built from moved to `leyline_stream.dart`
// in Slice F so Summon and Armor could reach them without importing this file
// (the posture test forbids that import, and a shared hash function is not a
// shared dictionary). Re-exported so every existing importer of this file — and
// every Slice B vector — sees exactly the names it always did.
export 'package:rune_duel/battle/models/leyline_stream.dart'
    show
        compareLeylineScores,
        kLeylineArmorDomain,
        kLeylineIncantationDomain,
        kLeylineKeyAlphabet,
        kLeylineSummonDomain,
        leylineKeyElementCode,
        leylineStreamScore;

// ── Stream tags ───────────────────────────────────────────────────────────────

/// The scoring stream that orders formula KEYS.
const int kLeylineKeyOrderStream = 0x01;

/// The scoring stream that orders the sixteen EFFECTS for round-robin dealing.
///
/// A separate stream, not a separate domain: both streams describe the same
/// dictionary under the same tag, and an explicit tag byte is what stops a
/// one-byte effect-code payload from ever sharing a preimage with a one-byte
/// key payload. (It could not today — the shortest legal key is 3 elements —
/// but relying on that would make a future length bound silently
/// consensus-critical.)
const int kLeylineEffectOrderStream = 0x02;

// ── Canonical effect codes ────────────────────────────────────────────────────

/// The consensus code of each of the sixteen incantation effects.
///
/// Explicit codes, not `EffectKind.index`, for the same reason
/// `kWildMagicEffectCode` is explicit (`wild_magic_phase.dart`): these bytes
/// enter a hash preimage, so reordering the enum — a legitimate, purely
/// cosmetic edit today — must not be able to reroll every mutable leyline's
/// dictionary. The values match today's declaration order, which is the point:
/// adopting them changes nothing and freezes it.
const Map<EffectKind, int> kIncantationEffectCode = {
  EffectKind.damage: 0,
  EffectKind.barrier: 1,
  EffectKind.reflections: 2,
  EffectKind.speedManipulation: 3,
  EffectKind.statusEffectInteraction: 4,
  EffectKind.chainInteraction: 5,
  EffectKind.spellInteraction: 6,
  EffectKind.fuelTransmutation: 7,
  EffectKind.tileModification: 8,
  EffectKind.rangeModification: 9,
  EffectKind.clouds: 10,
  EffectKind.artifactsInteraction: 11,
  EffectKind.illusions: 12,
  EffectKind.multiplierCycles: 13,
  EffectKind.haymakerInteraction: 14,
  EffectKind.divination: 15,
};

/// [kIncantationEffectCode] as a total function. Throws rather than defaulting:
/// an effect with no pinned code is a consensus hole, and a silent 0 would
/// collide with Blast.
int incantationEffectCode(EffectKind kind) {
  final code = kIncantationEffectCode[kind];
  if (code == null) {
    throw ArgumentError('no canonical incantation effect code pinned for $kind');
  }
  return code;
}

// ── What a key means ──────────────────────────────────────────────────────────
//
// [IncantationMeaning], [IncantationEffect] and [IncantationNoise] now live in
// `incantation_meaning.dart` and are re-exported here, so every existing
// importer of this file — and these vectors — see exactly the types they
// always did. The move is a dependency boundary, not a semantic one: ordinary
// production code needs to *name* a meaning long before anything may derive a
// codebook, and it must not reach [IncantationCodebook.derive] to do so. The
// rationale for the sealed hierarchy (over `EffectKind?`, a seventeenth enum
// member, or a `bool isNoise`) travelled with the types; see that file.

// ── The noise count (R-2) ─────────────────────────────────────────────────────

/// How many of [totalKeyCount] keys decode to noise, at [noiseDensityPermille].
///
/// ```
/// noiseCount = (totalKeyCount * noiseDensityPermille + 500) ~/ 1000
/// ```
///
/// **Round-half-up, applied to the NOISE count**, with meaningful taken as the
/// remainder. Three things settled there:
///
///   * *Which quantity is rounded* matters: noise density is the tunable
///     ruleset parameter (§5), so it is the one the arithmetic is faithful to,
///     and `meaningful = total − noise` then cannot drift from it.
///   * *Round rather than floor or ceil* because it reproduces §5's ratified
///     table exactly at every supported length — 64/32, 256/128, 1024/512 — and
///     because floor and ceil each bias one way at every density, which over a
///     tunable parameter is a systematic error rather than a rounding one.
///   * *Integer arithmetic throughout*, never `(total * permille / 1000).round()`
///     — a double's rounding mode at an exact `.5` is a platform property, and
///     `x.5` is exactly what 500‰ produces at every odd total. This is the kind
///     of thing that agrees on two devices for a year and then does not.
///
/// The largest intermediate is `1024 × 999 = 1_022_976`, so this is exact in a
/// 32-bit int and needs no widening on any platform including the web's
/// doubles.
///
/// **A degenerate case is reachable and deliberately not clamped:** at 999‰ and
/// `L = 4`, `(64 × 999 + 500) ~/ 1000 = 64` — every key is noise and no formula
/// means anything. `LeylineConfig` rejects 1000‰ for exactly that reason but
/// permits 999‰, and rounding closes the gap. A floor of one key per effect
/// would be a new consensus rule that no plan states, so it is NOT invented
/// here; see this slice's report.
int leylineNoiseKeyCount({
  required int totalKeyCount,
  required int noiseDensityPermille,
}) {
  if (totalKeyCount < 0) {
    throw ArgumentError.value(totalKeyCount, 'totalKeyCount', 'must be >= 0');
  }
  if (noiseDensityPermille < 0 || noiseDensityPermille > 1000) {
    throw ArgumentError.value(
      noiseDensityPermille,
      'noiseDensityPermille',
      'must be within 0..1000',
    );
  }
  return (totalKeyCount * noiseDensityPermille + 500) ~/ 1000;
}

// ── The codebook ──────────────────────────────────────────────────────────────

/// A Mutable Leyline's complete incantation dictionary: every formula tail's
/// meaning, derived deterministically from one [LeylineConfig].
///
/// Derivation is pure, total and cheap (at most 1024 + 16 SHA-256s and one
/// sort), so this is deliberately NOT cached or memoised anywhere — a cache is
/// shared mutable state on a consensus value, and there is nothing here worth
/// the risk until a profile says otherwise.
class IncantationCodebook {
  IncantationCodebook._({
    required this.config,
    required List<List<BorderZone>> orderedKeys,
    required List<IncantationMeaning> meaningByKeyIndex,
    required List<EffectKind> effectOrder,
    required this.meaningfulKeyCount,
  })  : _orderedKeys = orderedKeys,
        _meaningByKeyIndex = meaningByKeyIndex,
        _effectOrder = effectOrder;

  /// Derives the codebook for [config].
  ///
  /// **Throws on an ordinary leyline.** Ordinary magic has no codebook — its
  /// sixteen tails map onto the sixteen effects through the fixed
  /// `effectKindFromPair` table (§3), and that table is the game's accumulated
  /// scholarship. A derivation here would produce a *permutation* of it, so a
  /// caller that forgot to check `mutableMagic` would silently rekey ordinary
  /// play. Refusing at the door is the guard rail; there is no legitimate
  /// reason to want an ordinary codebook, so there is no flag to force one.
  factory IncantationCodebook.derive(LeylineConfig config) {
    if (!config.mutableMagic) {
      throw LeylineConfigException(
        'ordinary leylines have no derived codebook — their sixteen tails are '
        'the fixed effectKindFromPair table (LEYLINE_SEED_PLAN.md §3)',
      );
    }

    final keyLength = config.formulaLength - 1;
    final totalKeyCount = _pow4(keyLength);

    // 1. Canonical enumeration, then the sort-by-hash permutation (R-1).
    final orderedIndices = _orderedKeyIndices(config, keyLength, totalKeyCount);

    // 2. The exact partition (R-2).
    final noiseCount = leylineNoiseKeyCount(
      totalKeyCount: totalKeyCount,
      noiseDensityPermille: config.noiseDensityPermille,
    );
    final meaningfulCount = totalKeyCount - noiseCount;

    // 3. Round-robin over the derived effect order (R-3, R-4).
    final effectOrder = deriveEffectOrder(config);
    final meanings = _deriveMeanings(
      orderedIndices: orderedIndices,
      meaningfulCount: meaningfulCount,
      effectOrder: effectOrder,
      totalKeyCount: totalKeyCount,
    );

    return IncantationCodebook._(
      config: config,
      orderedKeys: [
        for (final i in orderedIndices)
          List<BorderZone>.unmodifiable(_keyForIndex(i, keyLength)),
      ],
      meaningByKeyIndex: meanings,
      effectOrder: effectOrder,
      meaningfulKeyCount: meaningfulCount,
    );
  }

  /// The leyline this codebook belongs to.
  final LeylineConfig config;

  /// How many keys decode to an effect. The rest are noise.
  final int meaningfulKeyCount;

  final List<List<BorderZone>> _orderedKeys;
  final List<IncantationMeaning> _meaningByKeyIndex;
  final List<EffectKind> _effectOrder;

  /// Elements in a formula KEY — the tail, i.e. `formulaLength - 1`. The
  /// affinity element (`chunk[0]`) is not part of the key: §3's protected
  /// invariant is that a leyline changes the grammar, never what affinity
  /// means.
  int get keyLength => config.formulaLength - 1;

  /// The size of the key space, `4^keyLength` (§3: 64 / 256 / 1024).
  int get totalKeyCount => _orderedKeys.length;

  /// How many keys decode to noise.
  int get noiseKeyCount => totalKeyCount - meaningfulKeyCount;

  /// Every key, in DERIVED order: meaningful keys first (dealt round-robin
  /// across [effectOrder]), then the noise keys. This is the permutation
  /// itself, and the vectors pin its prefix.
  List<List<BorderZone>> get orderedKeys => List.unmodifiable(_orderedKeys);

  /// The sixteen effects in the derived order the round-robin deals them in.
  /// Its first `meaningfulKeyCount % 16` entries are the effects that receive
  /// one extra key (R-4).
  List<EffectKind> get effectOrder => List.unmodifiable(_effectOrder);

  /// What [key] means under this leyline.
  ///
  /// [key] must be exactly [keyLength] elements. A wrong-length key is an error,
  /// not noise: noise is a *decoded* meaning, and conflating "this leyline says
  /// nothing" with "you asked the wrong question" is how a segmentation bug
  /// becomes an inert spell instead of a crash.
  IncantationMeaning lookup(List<BorderZone> key) =>
      _meaningByKeyIndex[canonicalKeyIndex(key)];

  /// Every key that decodes to [kind], in derived order. A SET, not a value:
  /// §5 makes the codebook many-to-one by design (32 keys per effect at L=6).
  List<List<BorderZone>> keysFor(EffectKind kind) => [
        for (final key in _orderedKeys)
          if (lookup(key) case IncantationEffect(kind: final k) when k == kind)
            key,
      ];

  /// How many keys each of the sixteen effects owns. §5's "every effect remains
  /// equally available", made checkable: under round-robin these differ by at
  /// most one, always.
  Map<EffectKind, int> get perEffectKeyCounts {
    final counts = <EffectKind, int>{
      for (final kind in EffectKind.values) kind: 0,
    };
    for (final meaning in _meaningByKeyIndex) {
      if (meaning case IncantationEffect(kind: final kind)) {
        counts[kind] = counts[kind]! + 1;
      }
    }
    return counts;
  }

  /// The canonical enumeration index of [key]: base-4 over
  /// [kLeylineKeyAlphabet], most significant element first.
  int canonicalKeyIndex(List<BorderZone> key) {
    if (key.length != keyLength) {
      throw ArgumentError(
        'key has ${key.length} elements, expected $keyLength for a '
        'formulaLength-${config.formulaLength} leyline',
      );
    }
    var index = 0;
    for (final element in key) {
      // Positioned through the alphabet, never through `BorderZone.index`:
      // the enumeration order is a pinned property of
      // [kLeylineKeyAlphabet], and reading it off the enum would make it an
      // unpinned property of a declaration order instead.
      index = index * 4 + kLeylineKeyAlphabet.indexOf(element);
    }
    return index;
  }

  /// The key at canonical enumeration index [index] — the inverse of
  /// [canonicalKeyIndex], exposed so a vector can name a key by its position in
  /// the *unpermuted* space.
  List<BorderZone> canonicalKeyAt(int index) {
    if (index < 0 || index >= totalKeyCount) {
      throw RangeError.range(index, 0, totalKeyCount - 1, 'index');
    }
    return List<BorderZone>.unmodifiable(_keyForIndex(index, keyLength));
  }

  @override
  String toString() => 'IncantationCodebook(${config.displayName}, '
      'keyLength: $keyLength, $meaningfulKeyCount meaningful / '
      '$noiseKeyCount noise of $totalKeyCount)';
}

// ── Derivation internals ──────────────────────────────────────────────────────

/// The sixteen effects, ordered by the same sort-by-hash primitive the keys use
/// (R-4).
///
/// This is what stops the round-robin's remainder from being a permanent tax on
/// high-numbered effect codes. With a fixed order, `meaningfulCount % 16`
/// non-zero would mean Blast and Barrier owned an extra key under *every*
/// leyline at *every* non-divisible density — a real, discoverable,
/// leyline-independent bias in a system whose entire premise is that nothing
/// carries over between leylines.
///
/// Hash-sorted rather than rotated by a derived offset: a rotation preserves
/// the fixed cyclic adjacency of the effect codes, so learning where one
/// leyline's order starts tells you the whole order. A full permutation tells
/// you nothing. It also costs nothing extra — it is the same primitive, under
/// [kLeylineEffectOrderStream].
///
/// ── The identity of an effect here is [kIncantationEffectCode], never
/// `EffectKind.index` ────────────────────────────────────────────────────────
///
/// Ratified, and load-bearing in BOTH places an effect's identity is consulted:
///
///   * the scoring **payload** is `[incantationEffectCode(kind)]`;
///   * the sort's **tiebreak** compares `incantationEffectCode`.
///
/// `EffectKind.values` appears below only as the *enumeration source*, and its
/// order cannot reach the result: the tiebreak is total (the sixteen pinned
/// codes are distinct), so every entry's position is fully determined by its
/// own score and its own pinned code. `List.sort` being unstable is therefore
/// harmless here, and feeding the same sixteen effects in any order yields the
/// same permutation — pinned by test.
///
/// **The hazard this guards against is currently invisible**, which is exactly
/// why it is written down: today `incantationEffectCode(kind) == kind.index`
/// for all sixteen effects, so a regression that swapped one for the other
/// would change nothing and no vector would move. The moment `EffectKind` is
/// reordered — a legitimate cosmetic edit — the two diverge, and a `.index`
/// here would silently reroll every mutable leyline's dictionary. A test
/// asserts the coincidence explicitly so that whoever reorders the enum is
/// stopped and sent to read this paragraph.
List<EffectKind> deriveEffectOrder(LeylineConfig config) {
  final scored = <(Uint8List, int, EffectKind)>[
    for (final kind in EffectKind.values)
      (
        leylineStreamScore(
          domainTag: kLeylineIncantationDomain,
          config: config,
          streamTag: kLeylineEffectOrderStream,
          payload: [incantationEffectCode(kind)],
        ),
        incantationEffectCode(kind),
        kind,
      ),
  ]..sort((a, b) {
      final byScore = compareLeylineScores(a.$1, b.$1);
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
  return [for (final entry in scored) entry.$3];
}

/// The canonical key enumeration, permuted by ascending (score, canonical key
/// bytes).
///
/// The tiebreak on the canonical key is what makes the sort TOTAL. A SHA-256
/// collision between two keys of one leyline is not a thing that happens, but
/// "sorted by a key that might repeat" is a specification hole regardless of
/// probability, and a hole in a consensus sort is a fork. `List.sort` is not
/// stable, so without the tiebreak two colliding entries could order
/// differently on two runtimes.
List<int> _orderedKeyIndices(
  LeylineConfig config,
  int keyLength,
  int totalKeyCount,
) {
  final scored = <(Uint8List, List<int>, int)>[];
  for (var i = 0; i < totalKeyCount; i++) {
    final payload = [
      for (final element in _keyForIndex(i, keyLength))
        leylineKeyElementCode(element),
    ];
    scored.add((
      leylineStreamScore(
        domainTag: kLeylineIncantationDomain,
        config: config,
        streamTag: kLeylineKeyOrderStream,
        payload: payload,
      ),
      payload,
      i,
    ));
  }
  scored.sort((a, b) {
    final byScore = compareLeylineScores(a.$1, b.$1);
    return byScore != 0 ? byScore : compareLeylineScores(a.$2, b.$2);
  });
  return [for (final entry in scored) entry.$3];
}

/// Deals the meaningful prefix of [orderedIndices] round-robin across
/// [effectOrder]; everything after it is noise (R-3).
///
/// Round-robin rather than contiguous blocks, for three reasons:
///
///   * **It is self-balancing at every count.** Blocked allocation needs a
///     block size, a remainder policy, and a rule for which block a straggler
///     joins — three places to disagree. Round-robin's per-effect counts differ
///     by at most one for any `meaningfulCount`, including counts below 16, by
///     construction and with no special case.
///   * **It degrades correctly.** At `meaningfulCount = 3` exactly the first
///     three effects of the derived order get one key each, which is the only
///     sensible reading of "distributed evenly"; blocked allocation would
///     divide by zero or hand all three to one effect.
///   * **It exposes no structure.** The adjacency it creates is adjacency in
///     the *permuted* key order, which is already pseudorandom — two keys that
///     are neighbours in the derived order are unrelated in the canonical one,
///     so "consecutive keys get consecutive effects" is not an observation a
///     player can make about anything they can see.
List<IncantationMeaning> _deriveMeanings({
  required List<int> orderedIndices,
  required int meaningfulCount,
  required List<EffectKind> effectOrder,
  required int totalKeyCount,
}) {
  final meanings = List<IncantationMeaning>.filled(
    totalKeyCount,
    kIncantationNoise,
  );
  for (var rank = 0; rank < meaningfulCount; rank++) {
    meanings[orderedIndices[rank]] =
        IncantationEffect(effectOrder[rank % effectOrder.length]);
  }
  return meanings;
}

/// The key at canonical index [index]: base-4 over [kLeylineKeyAlphabet], most
/// significant element first, so enumeration order is lexicographic in the
/// alphabet's order (§4 "canonical lexicographic elemental order").
List<BorderZone> _keyForIndex(int index, int keyLength) {
  final key = List<BorderZone>.filled(keyLength, BorderZone.fire);
  var remaining = index;
  for (var position = keyLength - 1; position >= 0; position--) {
    key[position] = kLeylineKeyAlphabet[remaining % 4];
    remaining ~/= 4;
  }
  return key;
}

int _pow4(int exponent) {
  var value = 1;
  for (var i = 0; i < exponent; i++) {
    value *= 4;
  }
  return value;
}
