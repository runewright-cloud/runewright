// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic.dart — the wild-magic derivation: seed hash → scan → eligibility
// → triggers. Pure functions, no BattleState dependency (docs/WILD_MAGIC_PLAN.md
// §4, §7.2).
//
// THIS IS CONSENSUS-CRITICAL. Both clients must derive byte-identical results
// or the per-turn state hash diverges and the match aborts. There must be
// EXACTLY ONE derivation path in the codebase (§10 invariant 2) — if you find
// yourself computing a seed hash anywhere else, delete it and call in here.
//
// ── Naming trap ───────────────────────────────────────────────────────────────
// `SpellAsset.spellHashHex` already exists and is Poseidon2(commitment, T) — a
// completely different value, used for duplicate detection at save time. Do NOT
// reuse that name, field, or value. The wild-magic one is `wildMagicSeedHex`.
//
// ── Why the hash is over the PUBLIC INPUTS, not the proof bytes ───────────────
// Evaluated and rejected on 2026-07-30 (WILD_MAGIC_PLAN.md §2.6, measurements in
// docs/M4_findings.md). bb's UltraHonk prover is not byte-deterministic (ZK
// blinding, not disableable through noir_rs's poseidon2 entry point), so hashing
// proof bytes would let a player re-inscribe one grid ~1,150 times to land any
// Row-3 effect on an already-perfect spell — undetectably. Hashing the statement
// welds the wild magic to the GRID: a grinder can find a trigger quickly, but
// the grid they find is essentially random, and finding a good spell that ALSO
// carries a trigger means searching the intersection. That coupling is the real
// defence; the ratified mitigation against grinders is the rotatable community
// seed word (MatchConfig.communitySeed), not a costlier hash. Keep SHA-256.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:rune_duel/battle/models/effect_kind.dart'
    show SpellAffinity, spellAffinityFromZone;
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart' as models
    show normalizeCommunitySeed;

import 'proof_intake.dart' show VerifiedSpellOutputs;
import 'trajectory_parser.dart' show ParsedFormula;

class WildMagic {
  // ── §4.1 The seed hash ──────────────────────────────────────────────────

  /// Design: *"case-insensitive, stripped of whitespace and punctuation"*.
  ///
  /// Delegates to the models-layer [normalizeCommunitySeed] so `MatchConfig`'s
  /// handshake agreement check and this hash can never drift apart — see that
  /// function for the empty-result fallback and why there is only one copy.
  static String normalizeCommunitySeed(String raw) =>
      models.normalizeCommunitySeed(raw);

  /// The 64-char lowercase hex seed hash (no `0x` prefix).
  ///
  /// ```
  /// preimage = commitment            // 32 bytes big-endian, raw Field bytes
  ///                                  //   (public-input field index 3)
  ///          ‖ uint8(T)              // 1 byte, 1..48
  ///          ‖ utf8(normalizedSeed)  // variable length, LAST so it needs no
  ///                                  //   length prefix
  /// wildMagicSeedHex = lowercase hex of SHA-256(preimage)
  /// ```
  ///
  /// Three encoding decisions you must not quietly change:
  ///
  ///   1. **`T` is an explicit field**, never inferred from trajectory length
  ///      or from border activations. This is what guarantees kin-spell
  ///      disambiguation — two inscriptions of the same grid at different T
  ///      get independent rolls — even where the CA's border activity has
  ///      saturated and produces identical output for two T values.
  ///   2. **The community seed is last**, so it needs no length prefix.
  ///   3. `border_activations` and `dominance_trajectory` are deliberately NOT
  ///      hashed (§4.1 `[SIMPLIFIED — 2026-07-30]`). Both are pure,
  ///      deterministic functions of `(grid, T)` — exactly like `commitment`
  ///      already is — so they add preimage bytes, not entropy: they cannot
  ///      distinguish two things `commitment` and `T` don't already
  ///      distinguish. Dropping them also makes the preimage trivially
  ///      tier-independent (nothing in it is a function of tierMax), so §10
  ///      invariant 11 holds by construction rather than by a padding rule.
  ///      `wild_magic_test.dart`'s preimage-independence test is the guard
  ///      against a future edit quietly reading them back in.
  static String seedHex(VerifiedSpellOutputs outputs, String communitySeed) {
    final commitment = _hexToBytes(outputs.commitmentHex);
    assert(commitment.length == 32, 'commitment must be a 32-byte Field');
    final seed = utf8.encode(normalizeCommunitySeed(communitySeed));

    final preimage = Uint8List(commitment.length + 1 + seed.length)
      ..setRange(0, commitment.length, commitment)
      ..[commitment.length] = outputs.t & 0xFF;
    preimage.setRange(commitment.length + 1, preimage.length, seed);

    return _toHex(sha256.convert(preimage).bytes);
  }

  // ── §4.2 The scan ───────────────────────────────────────────────────────

  /// Scans a 64-char lowercase hex string for the three trigger patterns.
  ///
  /// Returns `(row, bracketSteps)` for each row that fired, in row order. Each
  /// row fires **at most once**, taking the **longest** qualifying occurrence
  /// (WILD_MAGIC_PLAN.md A3) — a hash with `000` twice does not double a global
  /// effect, because bracket scaling is meant to be the only power axis.
  ///
  /// Runs are **maximal**, which is load-bearing for row 3: in `def012` the
  /// maximal ascending run starts at `d`, not at `0`, so it does NOT qualify
  /// even though `012` appears inside it. Find maximal runs first, then filter
  /// on the start character — never the other way round. (A naive substring
  /// search is the single easiest way to get row 3 wrong; `def012` is the test
  /// case that catches it.)
  static List<(WildMagicRow, int)> scan(String seedHex) {
    final out = <(WildMagicRow, int)>[];

    final zeros = _longestRepeatRun(seedHex, '0');
    if (zeros >= 3) out.add((WildMagicRow.repeatZero, zeros - 3));

    final ones = _longestRepeatRun(seedHex, '1');
    if (ones >= 3) out.add((WildMagicRow.repeatOne, ones - 3));

    final ascending = _longestAscendingRunFromZero(seedHex);
    if (ascending >= 4) out.add((WildMagicRow.ascendingRun, ascending - 4));

    return out;
  }

  /// Length of the longest maximal run of [ch] in [s]. `0000` is one run of 4,
  /// not two overlapping runs of 3.
  static int _longestRepeatRun(String s, String ch) {
    final target = ch.codeUnitAt(0);
    var best = 0;
    var current = 0;
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == target) {
        current++;
        if (current > best) best = current;
      } else {
        current = 0;
      }
    }
    return best;
  }

  /// Length of the longest **maximal** ascending run that **starts** at `'0'`.
  ///
  /// An ascending run is a maximal sequence where each character equals the
  /// previous plus one **mod 16** — so `f` wraps to `0`, and
  /// `0123456789abcdef0` is a single valid run of length 17. Returns 0 when no
  /// maximal run begins with `'0'`.
  static int _longestAscendingRunFromZero(String s) {
    var best = 0;
    var i = 0;
    while (i < s.length) {
      var j = i + 1;
      while (j < s.length &&
          _hexDigit(s.codeUnitAt(j)) == (_hexDigit(s.codeUnitAt(j - 1)) + 1) % 16) {
        j++;
      }
      // [i, j) is a maximal ascending run. Only runs that BEGIN at '0' count.
      if (_hexDigit(s.codeUnitAt(i)) == 0 && (j - i) > best) best = j - i;
      i = j;
    }
    return best;
  }

  // ── §4.3 Eligibility ────────────────────────────────────────────────────

  /// The elements whose column(s) of the effects table this spell reads.
  ///
  /// Tally the first-entry element of every **completed** formula; the most
  /// frequent element wins, and on a tie **every** tied element is eligible
  /// (the "wild magic specialist" archetype). Not `border_activations`, not
  /// generations-dominant — design §Eligibility says "cumulative across all
  /// **formulas**", and this reading reuses the certified [ParsedFormula] list
  /// [TrajectoryParser.parse] already produces, adding no new certified surface.
  ///
  /// A zero-formula spell yields an empty set and therefore fires no wild
  /// magic — which is the design's "void effects entirely removed for now",
  /// for free and with no special case.
  ///
  /// The returned set iterates in `SpellAffinity.values` order
  /// (`fire, earth, water, air`), **not** map-insertion order. That is a
  /// lockstep landmine: both clients see the same formulas in the same order
  /// today, but the moment they don't, unordered iteration turns a cosmetic
  /// difference into a state-hash divergence.
  static Set<SpellAffinity> eligibleElements(List<ParsedFormula> formulas) {
    if (formulas.isEmpty) return const {};
    final counts = <SpellAffinity, int>{};
    for (final f in formulas) {
      final e = spellAffinityFromZone(f.affinity);
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final maxCount = counts.values.reduce((a, b) => a > b ? a : b);
    // Built by iterating the enum, so the LinkedHashSet's order is the enum's.
    return {
      for (final e in SpellAffinity.values)
        if (counts[e] == maxCount) e,
    };
  }

  // ── Full derivation ─────────────────────────────────────────────────────

  /// hash → scan → eligibility → triggers, in deterministic row-then-element
  /// order (row 1 → 2 → 3; within a row `fire, earth, water, air`).
  ///
  /// An empty list means this spell has no wild magic. A perfectly balanced
  /// four-element spell whose hash contains `000` returns all four Row-1
  /// triggers — intended (§2.1).
  ///
  /// [outputs] must come from **certified** proof public outputs, never from a
  /// wire `SpellAsset` (§4.6 / §10 invariant 6).
  static List<WildMagicTrigger> triggersFor(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certifiedFormulas,
    String communitySeed,
  ) {
    final eligible = eligibleElements(certifiedFormulas);
    if (eligible.isEmpty) return const [];

    final rows = scan(seedHex(outputs, communitySeed));
    if (rows.isEmpty) return const [];

    return [
      for (final (row, bracketSteps) in rows)
        for (final element in SpellAffinity.values)
          if (eligible.contains(element))
            WildMagicTrigger(
              row: row,
              element: element,
              bracketSteps: bracketSteps,
            ),
    ];
  }

  // ── Hex helpers ─────────────────────────────────────────────────────────

  static int _hexDigit(int codeUnit) {
    // '0'..'9' → 0..9, 'a'..'f' → 10..15. Input is always our own lowercase
    // SHA-256 hex, so no uppercase / non-hex path is needed.
    return codeUnit <= 0x39 ? codeUnit - 0x30 : codeUnit - 0x57;
  }

  static Uint8List _hexToBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
