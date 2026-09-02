// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic.dart — the wild-magic derivation: semantic hash → scan →
// eligibility → triggers. Pure functions, no BattleState dependency
// (docs/WILD_MAGIC_PLAN_VNEXT.md §5, §7, §8).
//
// THIS IS CONSENSUS-CRITICAL. Both clients must derive byte-identical results
// or the per-turn state hash diverges and the match aborts. There must be
// EXACTLY ONE derivation path in the codebase (§10 invariant 2) — if you find
// yourself computing the semantic hash anywhere else, delete it and call in
// here.
//
// ── Naming trap ───────────────────────────────────────────────────────────────
// `SpellAsset.spellHashHex` already exists and is Poseidon2(commitment, T) — a
// completely different value, used for duplicate detection at save time. Do NOT
// reuse that name, field, or value. The wild-magic one is
// [WildMagic.semanticHashHex].
//
// ── What Wild Magic v2 keys off, and why ──────────────────────────────────────
//
// Ratified rule (WILD_MAGIC_PLAN_VNEXT.md §1, §2):
//
//     Wild Magic is deterministic for  caster × certified spell behavior × leyline.
//
// So the v2 preimage contains exactly four semantic inputs — the caster's
// canonical authenticated public identity, the certified elemental trajectory,
// the certified BASE mana cost, and the canonical leyline configuration hash —
// under an explicit domain tag and version.
//
// Four things v1 hashed (or could have hashed) are deliberately GONE:
//
//   1. **The grid commitment.** §3: practical hand-drawn runes occupy a small,
//      structured subset of grid space, so a public deterministic commitment
//      risks becoming an offline dictionary oracle — generate plausible grids,
//      hash them, match the commitment, recover the private rune. Wild Magic
//      must not require publishing such a fingerprint, and once the last
//      consumer is gone the commitment can leave the public spell identity
//      entirely.
//   2. **Proof bytes.** §4: bb's UltraHonk prover is not byte-deterministic
//      (ZK blinding), and no verifier can prove a peer used prescribed prover
//      randomness — so a modified client could reroll indefinitely.
//   3. **T, independently.** Two inscriptions of one grid at different T are
//      now Wild-Magic-EQUIVALENT whenever their certified trajectory and their
//      rounded certified base cost agree. This is intended (§5 equivalence
//      rule): Wild Magic keys off certified behaviour, not off how the rune
//      was drawn or how long it was simulated. T still influences the hash
//      *through* `certifiedBaseManaCost` (1.05^T), which is the only channel
//      §5 allows a lower-level certified value.
//   4. **Supreme flags / border activations / segment count / dot count**, each
//      independently. Same rule: they may matter through the certified base
//      cost, never as their own preimage fields.
//
// The equivalence this creates is the point, not a leak: two different secret
// grids with the same certified trajectory and the same certified base cost
// are the same *spell behaviour*, and behaviour is what the leyline reacts to.
//
// ── Grinding ──────────────────────────────────────────────────────────────────
// Caster keying (§6) makes rerolling book-wide rather than per-rune: a new
// identity rerolls every spell and every wizard-keyed relationship at once, so
// optimizing several spells is a multi-objective search rather than a cheap
// per-rune knob. The leyline hash is the second, rotatable axis.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:rune_duel/battle/models/effect_kind.dart'
    show SpellAffinity, spellAffinityFromZone;
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart' as models
    show normalizeCommunitySeed;
import 'package:rune_duel/engine/border_zone.dart';

import 'trajectory_parser.dart' show ParsedFormula;

class WildMagic {
  // ── §5 The canonical semantic key ───────────────────────────────────────

  /// The Wild Magic domain tag. Separate from the leyline's own
  /// (`Runewright/Leyline/v1/Config`) so the two hashes can never collide, and
  /// versioned by [kWildMagicVersion] as a field rather than inside the string
  /// — the tag names the *domain*, the uint16 names the *encoding epoch*.
  static const String kWildMagicDomain = 'Runewright/WildMagic';

  /// The encoding epoch of [semanticHashHex]'s preimage.
  ///
  /// v1 was `commitment ‖ uint8(T) ‖ utf8(seed)`. v2 replaces it wholesale —
  /// see this file's header. Bumping this rerolls every spell's Wild Magic in
  /// the world, so it is a consensus change requiring an engine-version bump
  /// (WILD_MAGIC_PLAN_VNEXT.md §16), never a refactor.
  static const int kWildMagicVersion = 2;

  /// The canonical `element → uint8` encoding for the certified trajectory.
  ///
  /// **Explicitly pinned, deliberately NOT `BorderZone.index`.** These are the
  /// circuit's own element values (CIRCUIT_IO.md §7 / CLAUDE.md: the dominance
  /// trajectory encodes `0=neutral, 1=fire, 2=air, 3=water, 4=earth`), so the
  /// consensus mapping the CA already commits to is the one the hash uses. 0
  /// stays reserved for neutral and never appears here: a certified element
  /// sequence contains only real activations.
  ///
  /// Writing this out rather than reaching for `.index` is the whole point —
  /// reordering the `BorderZone` enum for any local reason (alphabetizing it,
  /// inserting a value) would otherwise silently reroll every spell's Wild
  /// Magic on one device and not the other. `wild_magic_test.dart` pins these
  /// four numbers independently of the enum's declaration order.
  static const Map<BorderZone, int> kElementByte = {
    BorderZone.fire: 1,
    BorderZone.air: 2,
    BorderZone.water: 3,
    BorderZone.earth: 4,
  };

  /// [kElementByte] as a total function. Throws rather than defaulting: a
  /// `BorderZone` with no pinned byte is a consensus hole, and a silent 0
  /// would collide with the reserved neutral value.
  static int elementByte(BorderZone zone) {
    final b = kElementByte[zone];
    if (b == null) {
      throw ArgumentError('no canonical Wild Magic byte pinned for $zone');
    }
    return b;
  }

  /// Design: *"case-insensitive, stripped of whitespace and punctuation"*.
  ///
  /// Delegates to the models-layer [normalizeCommunitySeed] so `MatchConfig`'s
  /// handshake agreement check, `LeylineConfig`'s hash and this class can never
  /// drift apart. Kept here because callers already import it from here; the
  /// seed word itself no longer enters the Wild Magic preimage directly — it
  /// enters through [LeylineConfig.leylineConfigHash].
  static String normalizeCommunitySeed(String raw) =>
      models.normalizeCommunitySeed(raw);

  /// The 64-char lowercase hex semantic hash (no `0x` prefix).
  ///
  /// ```
  /// preimage = uint8(len(domain))            // 1 byte  = 20
  ///          ‖ utf8(domain)                  // 20 bytes "Runewright/WildMagic"
  ///          ‖ uint16be(wildMagicVersion)    // 2 bytes = 2
  ///          ‖ casterPubkeyBytes             // 32 bytes, canonical BE Field
  ///          ‖ uint16be(trajectoryLength)    // 2 bytes, element COUNT
  ///          ‖ trajectoryElementBytes        // trajectoryLength bytes
  ///          ‖ uint64be(certifiedBaseManaCost) // 8 bytes
  ///          ‖ leylineConfigHashBytes        // 32 bytes, decoded SHA-256
  /// semanticHashHex = lowercase hex of SHA-256(preimage)
  /// ```
  ///
  /// Six encoding decisions you must not quietly change:
  ///
  ///   1. **Every field is fixed-width or length-delimited**, the domain tag
  ///      and the trajectory included. Nothing here may rely on "it goes last
  ///      so it needs no prefix" — v1 did, and that trick does not survive a
  ///      field being appended after it.
  ///   2. **The caster key is 32 raw big-endian bytes, never its hex text.**
  ///      Hashing the string would make `0x00ab…` and `00ab…` two wizards.
  ///      [canonicalPubkeyBytes] is the one decoder.
  ///   3. **The leyline hash is 32 decoded bytes, not 64 hex characters**, for
  ///      the same reason.
  ///   4. **All multibyte integers are big-endian**, matching
  ///      `LeylineConfig.leylineConfigHash` and the proof wire format.
  ///   5. **The trajectory is the RAW certified element sequence** —
  ///      `TrajectoryParser.certifiedElementSequence`, residuals included —
  ///      encoded through [kElementByte]. Formula decoding and affinity
  ///      eligibility are a *separate* stage ([eligibleElements]), so a future
  ///      leyline codebook or a per-affinity trigger roll can change what
  ///      triggers *fire* without changing what the spell *is*.
  ///   6. **`certifiedBaseManaCost` is the intrinsic certified base**
  ///      (`PeerCastVerifier.certifiedBaseManaCost`), never the per-cast
  ///      chain/recall/Efficiency-adjusted price. The adjusted number changes
  ///      turn to turn; Wild Magic is a fixed property of the spell.
  static String semanticHashHex({
    required String casterPubkeyHex,
    required List<BorderZone> certifiedTrajectory,
    required int certifiedBaseManaCost,
    required String leylineConfigHash,
  }) {
    final domain = utf8.encode(kWildMagicDomain);
    assert(domain.length <= 0xFF, 'domain tag must fit a uint8 length prefix');
    final caster = canonicalPubkeyBytes(casterPubkeyHex);
    final leyline = _decodeHash32(leylineConfigHash, 'leylineConfigHash');

    if (certifiedTrajectory.length > 0xFFFF) {
      throw ArgumentError(
        'certified trajectory of ${certifiedTrajectory.length} elements '
        'exceeds the uint16 length prefix',
      );
    }
    // Both halves of the uint64 range are checked, and both matter for a
    // different reason.
    //
    // A NEGATIVE cost is a bug upstream, never a spell. `_uint64be` would
    // happily serialize its two's complement, minting a hash no other
    // implementation of this spec would reproduce from the same semantic
    // inputs — a silent consensus fork rather than a crash.
    //
    // An OVER-WIDE cost is unreachable on the Dart VM, where `int` is 64-bit
    // signed and a non-negative value therefore has `bitLength <= 63`. It is
    // checked anyway because the guard's job is to state the SERIALIZATION's
    // bound, not the current host's: `_uint64be` truncates silently to its low
    // 8 bytes, so on any host with wider integers (a web build's BigInt-backed
    // ints, or a future arbitrary-precision cost type) two distinct costs
    // would collide into one hash with nothing to signal it. A bound the
    // encoder relies on belongs next to the encoder.
    if (certifiedBaseManaCost < 0 || certifiedBaseManaCost.bitLength > 64) {
      throw ArgumentError(
        'certifiedBaseManaCost $certifiedBaseManaCost is outside the canonical '
        'unsigned 64-bit range',
      );
    }

    final out = BytesBuilder(copy: false)
      ..addByte(domain.length)
      ..add(domain)
      ..add(_uint16be(kWildMagicVersion))
      ..add(caster)
      ..add(_uint16be(certifiedTrajectory.length));
    for (final zone in certifiedTrajectory) {
      out.addByte(elementByte(zone));
    }
    out
      ..add(_uint64be(certifiedBaseManaCost))
      ..add(leyline);

    return _toHex(sha256.convert(out.takeBytes()).bytes);
  }

  /// The caster's canonical authenticated gameplay identity as 32 big-endian
  /// bytes — `WizardAvatar.ownerPubkeyHex`, i.e. `Poseidon2(key_hi, key_lo)`,
  /// the value the handshake's fresh-nonce Ed25519 challenge authenticated.
  ///
  /// Accepts an optional `0x` prefix and fewer than 64 hex digits (a Field
  /// element with leading zeros stripped), left-padding to the full width —
  /// so one Field value has exactly one byte encoding whatever spelling it
  /// arrived in. Everything else throws: an empty string, non-hex text, or a
  /// value too wide for a Field is a caller bug, and the only "safe" fallback
  /// available (a zero key) would quietly give every unidentified caster one
  /// shared magical identity.
  static Uint8List canonicalPubkeyBytes(String pubkeyHex) {
    final s = pubkeyHex.startsWith('0x') || pubkeyHex.startsWith('0X')
        ? pubkeyHex.substring(2)
        : pubkeyHex;
    if (s.isEmpty) {
      throw ArgumentError('caster pubkey hex is empty — no identity to key on');
    }
    if (s.length > 64) {
      throw ArgumentError(
        'caster pubkey hex is ${s.length} digits, wider than a 32-byte Field',
      );
    }
    final padded = s.padLeft(64, '0');
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final byte = _hexByte(padded, i * 2);
      if (byte < 0) {
        throw ArgumentError('caster pubkey hex is not hexadecimal: $pubkeyHex');
      }
      out[i] = byte;
    }
    return out;
  }

  /// A 64-char lowercase SHA-256 hex string as its 32 raw bytes.
  static Uint8List _decodeHash32(String hex, String what) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (s.length != 64) {
      throw ArgumentError('$what must be 64 hex chars, got ${s.length}');
    }
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final byte = _hexByte(s, i * 2);
      if (byte < 0) throw ArgumentError('$what is not hexadecimal: $hex');
      out[i] = byte;
    }
    return out;
  }

  static Uint8List _uint16be(int v) =>
      Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

  static Uint8List _uint64be(int v) {
    final out = Uint8List(8);
    for (var i = 7; i >= 0; i--) {
      out[i] = v & 0xFF;
      v >>= 8;
    }
    return out;
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

  // ── §7/§9 Full derivation ───────────────────────────────────────────────

  /// semantic hash → scan → eligibility → triggers, in deterministic
  /// row-then-element order (row 1 → 2 → 3; within a row `fire, earth, water,
  /// air`).
  ///
  /// An empty list means this spell has no wild magic for this caster under
  /// this leyline. A perfectly balanced four-element spell whose hash contains
  /// `000` returns all four Row-1 triggers — today's ratified behaviour
  /// (WILD_MAGIC_PLAN_VNEXT.md §9 candidate A), preserved exactly.
  ///
  /// ## Two stages, deliberately separable
  ///
  /// [semanticHashHex] answers *what is this spell, for this wizard, here*.
  /// [scan] + [eligibleElements] answer *what does that make happen*. §9 leaves
  /// the second question open — candidate B would give each eligible affinity
  /// its own domain-separated roll off the same hash — so the trigger producer
  /// below must stay swappable without touching the preimage above. Nothing
  /// here reads a raw preimage field; it reads the hash and the formulas.
  ///
  /// Every argument must come from **certified** proof outputs and the
  /// authenticated caster identity, never from a wire `SpellAsset`
  /// (§4.6 / §10 invariant 6). `PeerCastVerifier.semanticsOf` is the only
  /// consensus caller.
  static List<WildMagicTrigger> triggersFor({
    required String casterPubkeyHex,
    required List<BorderZone> certifiedTrajectory,
    required int certifiedBaseManaCost,
    required String leylineConfigHash,
    required List<ParsedFormula> formulas,
  }) {
    // Eligibility first: a spell with no completed formula fires nothing
    // whatever it hashes to, so there is no reason to hash it.
    final eligible = eligibleElements(formulas);
    if (eligible.isEmpty) return const [];

    final rows = scan(semanticHashHex(
      casterPubkeyHex: casterPubkeyHex,
      certifiedTrajectory: certifiedTrajectory,
      certifiedBaseManaCost: certifiedBaseManaCost,
      leylineConfigHash: leylineConfigHash,
    ));
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

  /// The byte at [i]..[i]+1 of [hex], or -1 if either character is not a hex
  /// digit. Case-insensitive, unlike [_hexDigit], because it also reads hex
  /// that came from outside this class.
  static int _hexByte(String hex, int i) {
    final hi = _nibble(hex.codeUnitAt(i));
    final lo = _nibble(hex.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) return -1;
    return (hi << 4) | lo;
  }

  static int _nibble(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // '0'..'9'
    if (c >= 0x61 && c <= 0x66) return c - 0x57; // 'a'..'f'
    if (c >= 0x41 && c <= 0x46) return c - 0x37; // 'A'..'F'
    return -1;
  }

  static String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
