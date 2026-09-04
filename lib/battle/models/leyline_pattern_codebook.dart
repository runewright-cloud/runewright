// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_pattern_codebook.dart — deterministic derivation of a Mutable
// Leyline's SUMMON and ARMOR pattern dictionaries
// (docs/LEYLINE_SEED_PLAN.md §8, §9, §15; audit R-8, Slice F).
//
// ## What this file is
//
// The low-level construction shared by the two *pattern* languages: enumerate
// every four-element pattern, permute the enumeration from the leyline, take
// the domain's meaningful count off the front, and deal those patterns across
// the domain's output vocabulary. It speaks in integer OUTPUT CODES and knows
// nothing about creatures, armor, keywords or abilities — the vocabularies and
// the structural matchers live with their domains, in `summon_lexicon.dart` and
// `armor_lexicon.dart`.
//
// ## What it is NOT, and must never become
//
// **Not a generic formula framework.** Audit §3.2 ratified that there is no
// `lookupFormula(domain, leyline, chunk)`: Incantation chunks disjointly at a
// leyline-chosen length and has a noise VALUE; Summon and Armor slide a
// fixed-width window, allow overlap, grant each output at most once, and have
// no noise value at all — an unmatched window is simply not a word. Those are
// three languages that happen to share a hash function. This file is that hash
// function's second consumer, not a unification of the three.
//
// Concretely, and each of these is a ruling rather than an accident:
//
//   * **The pattern length is 4, always** ([kLeylinePatternLength]) —
//     `LeylineConfig.formulaLength` is the Incantation grammar's length and is
//     not a generic window size. A `rivendell 5` armor still matches
//     four-element runs.
//   * **The meaningful count is the domain's ordinary cardinality**, passed in
//     by the caller as the size of its vocabulary — not a share of the key
//     space. Incantation's ~50% noise density exists because its keys are
//     consumed in disjoint chunks; giving half of all 256 sliding windows a
//     meaning would make every creature a menagerie of abilities.
//   * **The binding hash is the leyline's TRADITION**
//     ([leylineTraditionStreamScore]), so `rivendell 4`, `rivendell 5` and
//     `rivendell 6` share one summon dictionary and one armor dictionary while
//     speaking three different incantation grammars.
//
// ## Why it is pinned by vectors from day one
//
// LEYLINE_SEED_PLAN.md §15: *"Every peer must derive byte-identical codebooks
// from the same configuration."* Two devices that disagree about whether a
// creature flies resolve different battles from the same certified trajectory.
// So every byte below is pinned by fixed vectors in
// `test/battle/models/leyline_pattern_codebook_test.dart`, independently
// recomputed by `scripts/gen_leyline_pattern_vectors.py`, and changing ANY of:
//
//   * a domain tag, its length prefix, or the stream tag bytes;
//   * the element alphabet, its codes, or the enumeration order;
//   * the scoring preimage's field order or widths;
//   * the sort or its tiebreak;
//   * the pattern length or the meaningful count;
//   * the allocation rule or the output ordering;
//   * a domain's canonical output codes;
//
// is a CONSENSUS CHANGE requiring a lexicon-version bump, not a refactor.
//
// ## The construction, in one paragraph
//
// Enumerate all 4⁴ = 256 patterns in canonical lexicographic elemental order.
// Score each with a domain-separated SHA-256 keyed on the leyline's tradition
// hash and sort ascending by (score, canonical pattern bytes) — the same
// sort-by-hash primitive R-1 ratified, for the same reasons. Take the first
// `outputCodes.length` patterns as the meaningful ones and deal them
// round-robin across an output order derived by the same primitive under a
// second stream tag (R-3/R-4). Every remaining pattern is inert: absent from
// the dictionary, not mapped to a sentinel.

import 'dart:typed_data';

import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/leyline_stream.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Stream tags ───────────────────────────────────────────────────────────────

/// The scoring stream that orders PATTERNS.
///
/// Numbered apart from `leyline_codebook.dart`'s `0x01`/`0x02` even though the
/// domain tag and the binding hash already separate the two constructions.
/// Cheap, and it means a preimage dumped in a debugger says which of the two
/// codebook families it belongs to without cross-referencing a domain string.
const int kLeylinePatternOrderStream = 0x11;

/// The scoring stream that orders a domain's OUTPUTS for round-robin dealing.
const int kLeylineOutputOrderStream = 0x12;

// ── The pattern space ─────────────────────────────────────────────────────────

/// Elements in a Summon or Armor pattern.
///
/// **Four, under every leyline.** Both domains match a fixed-width sliding
/// window over a certified element sequence, and R-8 keeps that structure: a
/// Mutable Leyline rekeys *meaning*, never the recogniser. This is emphatically
/// not [LeylineConfig.formulaLength] — see this file's header.
const int kLeylinePatternLength = 4;

/// The size of the pattern space, `4^kLeylinePatternLength`.
const int kLeylinePatternSpaceSize = 256;

/// The pattern at canonical enumeration index [index]: base-4 over
/// [kLeylineKeyAlphabet], most significant element first, so the enumeration is
/// lexicographic in the alphabet's order (§4's rule, reused verbatim).
List<BorderZone> leylineCanonicalPatternAt(int index) {
  if (index < 0 || index >= kLeylinePatternSpaceSize) {
    throw RangeError.range(index, 0, kLeylinePatternSpaceSize - 1, 'index');
  }
  final pattern = List<BorderZone>.filled(kLeylinePatternLength, BorderZone.fire);
  var remaining = index;
  for (var position = kLeylinePatternLength - 1; position >= 0; position--) {
    pattern[position] = kLeylineKeyAlphabet[remaining % 4];
    remaining ~/= 4;
  }
  return pattern;
}

/// The canonical enumeration index of [pattern] — the inverse of
/// [leylineCanonicalPatternAt].
///
/// Positioned through [kLeylineKeyAlphabet], never through `BorderZone.index`:
/// the enumeration order is a pinned property of the alphabet, and reading it
/// off the enum would make it an unpinned property of a declaration order
/// instead.
int leylineCanonicalPatternIndex(List<BorderZone> pattern) {
  if (pattern.length != kLeylinePatternLength) {
    throw ArgumentError(
      'pattern has ${pattern.length} elements, expected $kLeylinePatternLength',
    );
  }
  var index = 0;
  for (final element in pattern) {
    index = index * 4 + kLeylineKeyAlphabet.indexOf(element);
  }
  return index;
}

// ── The codebook ──────────────────────────────────────────────────────────────

/// One domain's complete Mutable pattern dictionary: which of the 256
/// four-element patterns mean something under a leyline, and which output code
/// each of them names.
///
/// Derivation is pure, total and cheap (264 SHA-256s and two sorts), so this is
/// deliberately NOT cached or memoised anywhere — a cache is shared mutable
/// state on a consensus value, and there is nothing here worth the risk until a
/// profile says otherwise. Domain lexicons hold one for the life of a match.
class LeylinePatternCodebook {
  LeylinePatternCodebook._({
    required this.config,
    required this.domainTag,
    required List<List<BorderZone>> orderedPatterns,
    required List<int> outputOrder,
    required Map<int, int> codeByPatternIndex,
  })  : _orderedPatterns = orderedPatterns,
        _outputOrder = outputOrder,
        _codeByPatternIndex = codeByPatternIndex;

  /// Derives [domainTag]'s dictionary for [config] over [outputCodes].
  ///
  /// [outputCodes] is the domain's canonical output vocabulary, as its pinned
  /// consensus codes — never enum indices, and never a `.values` order (see
  /// each lexicon's code table for why). It must be non-empty, distinct, and no
  /// larger than the pattern space. Exactly `outputCodes.length` patterns come
  /// out meaningful, which is R-8's cardinality-preservation rule expressed as
  /// an argument rather than a policy this file gets to choose.
  ///
  /// **Throws on an ordinary leyline.** Ordinary magic has no derived
  /// dictionary — its patterns are the fixed tables in `creature_spec.dart` and
  /// `certified_armor.dart`, which are the game's accumulated scholarship. A
  /// derivation here would produce a *permutation* of them, so a caller that
  /// forgot to check `mutableMagic` would silently rekey ordinary play.
  /// Refusing at the door is the guard rail; there is no flag to force one.
  factory LeylinePatternCodebook.derive({
    required LeylineConfig config,
    required String domainTag,
    required List<int> outputCodes,
  }) {
    if (!config.mutableMagic) {
      throw LeylineConfigException(
        'ordinary leylines have no derived pattern dictionary — their patterns '
        'are the fixed Summon/Armor tables (LEYLINE_SEED_PLAN.md §8, §9)',
      );
    }
    if (outputCodes.isEmpty) {
      throw ArgumentError.value(outputCodes, 'outputCodes', 'must be non-empty');
    }
    if (outputCodes.length > kLeylinePatternSpaceSize) {
      throw ArgumentError.value(
        outputCodes,
        'outputCodes',
        'more outputs than the $kLeylinePatternSpaceSize-pattern key space',
      );
    }
    if (outputCodes.toSet().length != outputCodes.length) {
      throw ArgumentError.value(outputCodes, 'outputCodes', 'codes must be distinct');
    }

    final orderedIndices = _orderedPatternIndices(config, domainTag);
    final order = _deriveOutputOrder(config, domainTag, outputCodes);

    // Round-robin over the derived output order (R-3), which at equal
    // cardinality — the only case either live domain uses — is exactly a
    // bijection: each output owns one pattern. The general form is kept because
    // it degrades correctly if a vocabulary ever grows or shrinks, and because
    // it is the same rule the incantation codebook states.
    final codeByPatternIndex = <int, int>{};
    for (var rank = 0; rank < outputCodes.length; rank++) {
      codeByPatternIndex[orderedIndices[rank]] = order[rank % order.length];
    }

    return LeylinePatternCodebook._(
      config: config,
      domainTag: domainTag,
      orderedPatterns: [
        for (final i in orderedIndices)
          List<BorderZone>.unmodifiable(leylineCanonicalPatternAt(i)),
      ],
      outputOrder: List<int>.unmodifiable(order),
      codeByPatternIndex: Map<int, int>.unmodifiable(codeByPatternIndex),
    );
  }

  /// The leyline this dictionary belongs to.
  final LeylineConfig config;

  /// The domain tag it was derived under — `Runewright/Leyline/v1/Summon` or
  /// `.../Armor`.
  final String domainTag;

  final List<List<BorderZone>> _orderedPatterns;
  final List<int> _outputOrder;
  final Map<int, int> _codeByPatternIndex;

  /// How many patterns mean something: the domain's ordinary cardinality.
  int get meaningfulPatternCount => _codeByPatternIndex.length;

  /// All 256 patterns in DERIVED order — the meaningful ones first, in the
  /// order they were dealt, then the inert ones. This is the permutation
  /// itself, and the vectors pin its prefix.
  List<List<BorderZone>> get orderedPatterns => List.unmodifiable(_orderedPatterns);

  /// The output codes in the derived order the round-robin deals them in.
  List<int> get outputOrder => List.unmodifiable(_outputOrder);

  /// The output code [pattern] names under this leyline, or null when the
  /// pattern is inert.
  ///
  /// Null is "this leyline has no word for that", which for a sliding-window
  /// language is the ordinary case — 248 of 256 windows for Summon — and NOT a
  /// noise value. There is no `SummonAbility.noise`, deliberately: a sentinel
  /// would need a label, a description, a canonical code, and a row in every
  /// exhaustive switch, all to name the absence of a match.
  int? codeFor(List<BorderZone> pattern) =>
      _codeByPatternIndex[leylineCanonicalPatternIndex(pattern)];

  /// The single pattern that names [code], or null when [code] is not in this
  /// dictionary's vocabulary.
  ///
  /// The inverse of [codeFor] for the meaningful set. Single-valued because the
  /// allocation is a bijection at both live domains' cardinalities; it returns
  /// the FIRST in derived order if a future vocabulary is ever smaller than the
  /// meaningful count.
  List<BorderZone>? patternFor(int code) {
    for (final entry in _codeByPatternIndex.entries) {
      if (entry.value == code) return leylineCanonicalPatternAt(entry.key);
    }
    return null;
  }

  @override
  String toString() => 'LeylinePatternCodebook($domainTag, '
      '${config.displayName}, $meaningfulPatternCount of '
      '$kLeylinePatternSpaceSize meaningful)';
}

// ── Derivation internals ──────────────────────────────────────────────────────

/// The canonical pattern enumeration, permuted by ascending
/// (score, canonical pattern bytes).
///
/// The tiebreak on the canonical pattern is what makes the sort TOTAL. A
/// SHA-256 collision between two patterns of one leyline is not a thing that
/// happens, but "sorted by a key that might repeat" is a specification hole
/// regardless of probability, and a hole in a consensus sort is a fork.
/// `List.sort` is not stable, so without the tiebreak two colliding entries
/// could order differently on two runtimes.
List<int> _orderedPatternIndices(LeylineConfig config, String domainTag) {
  final scored = <(Uint8List, List<int>, int)>[];
  for (var i = 0; i < kLeylinePatternSpaceSize; i++) {
    final payload = [
      for (final element in leylineCanonicalPatternAt(i))
        leylineKeyElementCode(element),
    ];
    scored.add((
      leylineTraditionStreamScore(
        domainTag: domainTag,
        config: config,
        streamTag: kLeylinePatternOrderStream,
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

/// The domain's outputs, ordered by the same sort-by-hash primitive the
/// patterns use (R-4).
///
/// Hash-sorted rather than taken in code order for the reason R-4 gives: a
/// fixed order would make the *identity* of the extra-key holders (and, at
/// unequal cardinalities, of the outputs that get nothing) a permanent,
/// leyline-independent property, in a system whose whole premise is that
/// nothing carries over between leylines.
///
/// The tiebreak compares the pinned output code, which is total because the
/// codes are distinct — so `List.sort`'s instability cannot reach the result and
/// feeding the same codes in any order yields the same permutation.
List<int> _deriveOutputOrder(
  LeylineConfig config,
  String domainTag,
  List<int> outputCodes,
) {
  final scored = <(Uint8List, int)>[
    for (final code in outputCodes)
      (
        leylineTraditionStreamScore(
          domainTag: domainTag,
          config: config,
          streamTag: kLeylineOutputOrderStream,
          payload: [code],
        ),
        code,
      ),
  ]..sort((a, b) {
      final byScore = compareLeylineScores(a.$1, b.$1);
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
  return [for (final entry in scored) entry.$2];
}
