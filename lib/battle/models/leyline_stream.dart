// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_stream.dart — the deterministic ranking primitives every Mutable
// Leyline dictionary is built from (docs/LEYLINE_SEED_PLAN.md §4, §8, §9, §15;
// audit Slice B R-1/R-4, Slice F R-8).
//
// ## What this file is
//
// The *machinery*, and none of the semantics: the elemental alphabet and its
// canonical codes, the three domain tags, the domain-separated scoring hash,
// and a total big-endian digest comparison. Three dictionaries are built on it
// — Incantation (`leyline_codebook.dart`), Summon and Armor
// (`leyline_pattern_codebook.dart`) — and each keeps its own key space,
// matching rule and output vocabulary. Audit §3.2 is explicit that this, and
// only this, is what the three domains may share: there is **no** generic
// `lookupFormula(domain, leyline, chunk)` and there must not be one.
//
// It was extracted from `leyline_codebook.dart` in Slice F, verbatim, so that
// Summon and Armor could reach the primitive without importing the Incantation
// codebook — the posture test forbids exactly that import, and rightly: sharing
// a hash function is not the same as sharing a dictionary. **Every byte of the
// Incantation derivation is unchanged by the move**, which the unmoved Slice B
// vectors attest.
//
// ## Two binding hashes, and why there are two
//
// A score is keyed on a 32-byte value that identifies *which leyline* is being
// asked, and there are two legitimate answers:
//
//   * [leylineStreamScore] binds [LeylineConfig.leylineConfigHash] — the FULL
//     configuration, `formulaLength` and `noiseDensityPermille` included. That
//     is what an Incantation dictionary must key on: those two fields *are* its
//     grammar, and `rivendell 4` and `rivendell 5` are two incantation
//     languages.
//   * [leylineTraditionStreamScore] binds [LeylineConfig.leylineTraditionHash]
//     — the leyline's tradition identity, which those two fields are
//     deliberately absent from. That is what the Summon and Armor dictionaries
//     key on (R-8): their pattern language is four elements wide under every
//     grammar, so a host who moves from `rivendell 4` to `rivendell 6` changes
//     how their duellists *speak* without also rerolling what their creatures
//     and their armor are.
//
// Choosing the wrong one is a silent consensus fork, so the two functions are
// named for what they bind rather than taking a flag.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Domain tags (LEYLINE_SEED_PLAN.md §4, §8, §9) ─────────────────────────────

/// The incantation codebook's domain tag, transcribed from §4.
///
/// `v1` versions THIS BYTE LAYOUT, not the codebook generation — that is
/// [LeylineConfig.lexiconVersion], which moves independently. Conflating them
/// would mean a new dictionary generation silently rewrote every old layout.
const String kLeylineIncantationDomain = 'Runewright/Leyline/v1/Incantation';

/// §8's summon domain tag — the Summon ability dictionary's separation
/// (Slice F).
const String kLeylineSummonDomain = 'Runewright/Leyline/v1/Summon';

/// §9's Aetherial Armor domain tag — the Armor keyword dictionary's separation
/// (Slice F).
const String kLeylineArmorDomain = 'Runewright/Leyline/v1/Armor';

// ── The element alphabet (§3, §15 "element encoding") ─────────────────────────

/// The dictionary-key alphabet, in canonical enumeration order.
///
/// **Neutral is deliberately absent.** A formula element is an entry that
/// `FormulaTracker.step` committed, and every one of its three rules is guarded
/// by `zone != null` — a neutral or tied generation commits nothing. So a
/// neutral can never appear in a trajectory chunk, and admitting it into the
/// key space would enumerate 5^n keys of which most are unreachable. §3 is
/// explicit that the tail space is `4^(L-1)`; §8/§9's pattern space is `4^4`
/// for the same reason.
///
/// The order is the circuit's element order minus neutral
/// (`circuits/GRID_ORDERING_v2.md` §Rule indices: 1 Fire, 2 Air, 3 Water,
/// 4 Earth), which is also `BorderZone`'s declaration order and also
/// `ca_run.dart`'s `zoneIndex` order. All three already agree; this constant
/// asserts that agreement rather than adding a fourth opinion.
const List<BorderZone> kLeylineKeyAlphabet = [
  BorderZone.fire,
  BorderZone.air,
  BorderZone.water,
  BorderZone.earth,
];

/// The canonical wire code of a key element: the circuit's rule index, so
/// `fire` is 1 and neutral's 0 is never emitted.
///
/// Deliberately NOT `BorderZone.index` — a byte layout must not move because
/// someone reorders an enum, and the two happen to differ by exactly the
/// neutral offset, which is the kind of coincidence that reads as intentional
/// three years later.
int leylineKeyElementCode(BorderZone zone) => switch (zone) {
      BorderZone.fire => 1,
      BorderZone.air => 2,
      BorderZone.water => 3,
      BorderZone.earth => 4,
    };

// ── The scoring primitive (R-1, R-4) ──────────────────────────────────────────

/// One entry's sort key in a leyline-derived ordering, bound to the FULL
/// configuration.
///
/// ```
/// preimage = uint8(len(domainTag)) ‖ ascii(domainTag)
///          ‖ uint8(lexiconVersion)
///          ‖ leylineConfigHash[32]          // RAW bytes, not the hex text
///          ‖ uint8(streamTag)
///          ‖ uint8(len(payload))
///          ‖ payload                        // key element codes, or [effectCode]
/// score    = SHA-256(preimage)              // all 32 bytes, compared big-endian
/// ```
///
/// Five encoding decisions, and why each is what it is:
///
///   1. **Sort-by-hash, not a seeded shuffle** (R-1, audit §5.2 candidate B).
///      A Fisher-Yates over a `HashRng` would be equally deterministic *given
///      an identical shuffle implementation* — and that is precisely the
///      dependency to refuse. `List.shuffle`'s algorithm is a Dart SDK detail,
///      not a specification; a second implementation in Python, Rust or Noir
///      would have to reproduce it exactly, including its draw order and its
///      rejection sampling. A per-entry score has no such coupling: each
///      entry's rank is independently computable and independently verifiable,
///      the construction is order-independent by definition, and porting it is
///      one hash and one sort.
///   2. **Keyed on `leylineConfigHash`, not on a re-serialisation of the
///      config.** That value is already pinned by vectors, already binds all
///      five fields including the normalized seed, and is already what Wild
///      Magic v2 consumes — so a codebook and the Wild Magic under it can never
///      disagree about which leyline they are in. Re-serialising the fields
///      here would be a second spelling of a consensus preimage, i.e. the exact
///      drift `LeylineConfig`'s header warns about. It is hashed as the RAW 32
///      bytes rather than the 64-char hex string: fixed-width, no case or
///      encoding question to get wrong.
///   3. **`lexiconVersion` is emitted even though `leylineConfigHash` already
///      binds it.** Redundant on purpose. It sits immediately after the domain
///      tag, mirroring `LeylineConfig`'s layout exactly, so the two preimages
///      read as siblings; and it is the field that versions *this derivation*,
///      which makes it worth being visible in the derivation's own bytes.
///   4. **Every field is fixed-width or length-delimited**, tags included —
///      `LeylineConfig`'s rule 1, for the same reason: it is what makes
///      `("ab", …)` and `("a", …)` structurally unable to collide.
///   5. **Nothing else is in scope.** No player, no caster, no proof bytes, no
///      grid, no turn, no wall clock, no map or set iteration. A codebook is a
///      property of a leyline and of nothing else.
Uint8List leylineStreamScore({
  required String domainTag,
  required LeylineConfig config,
  required int streamTag,
  required List<int> payload,
}) =>
    _score(
      domainTag: domainTag,
      lexiconVersion: config.lexiconVersion,
      bindingHashHex: config.leylineConfigHash,
      streamTag: streamTag,
      payload: payload,
    );

/// One entry's sort key in a leyline-derived ordering, bound to the leyline's
/// TRADITION rather than to its full configuration (R-8).
///
/// Byte-for-byte [leylineStreamScore]'s layout with [LeylineConfig
/// .leylineTraditionHash] in place of `leylineConfigHash`, so everything the
/// five decisions above say still applies. The one substantive difference is
/// what the 32 bound bytes commit to: the domain, the lexicon generation and
/// the normalized seed, but **not** `formulaLength` and **not**
/// `noiseDensityPermille`.
///
/// That projection is the Summon/Armor ruling, not an optimisation. Those two
/// fields are the Incantation grammar's own controls: `formulaLength` is how
/// many elements make one spoken formula, and `noiseDensityPermille` is what
/// share of formula tails a leyline leaves inert. Neither describes a
/// four-element creature or armor pattern, and letting them reroll those
/// dictionaries would mean a host who changed their grammar length silently
/// changed what every creature in the match could do.
Uint8List leylineTraditionStreamScore({
  required String domainTag,
  required LeylineConfig config,
  required int streamTag,
  required List<int> payload,
}) =>
    _score(
      domainTag: domainTag,
      lexiconVersion: config.lexiconVersion,
      bindingHashHex: config.leylineTraditionHash,
      streamTag: streamTag,
      payload: payload,
    );

/// The one implementation of the preimage both public scorers document. Private
/// so a third binding hash cannot be introduced by passing bytes in from
/// outside: a caller must name which leyline identity it means.
Uint8List _score({
  required String domainTag,
  required int lexiconVersion,
  required String bindingHashHex,
  required int streamTag,
  required List<int> payload,
}) {
  final domain = utf8.encode(domainTag);
  if (domain.length > 0xFF) {
    throw ArgumentError('domain tag must fit a uint8 length prefix');
  }
  if (streamTag < 0 || streamTag > 0xFF) {
    throw ArgumentError('streamTag $streamTag does not fit a uint8');
  }
  if (payload.length > 0xFF) {
    throw ArgumentError('payload must fit a uint8 length prefix');
  }
  for (final b in payload) {
    if (b < 0 || b > 0xFF) {
      throw ArgumentError('payload byte $b does not fit a uint8');
    }
  }

  final buf = BytesBuilder(copy: false)
    ..addByte(domain.length)
    ..add(domain)
    ..addByte(lexiconVersion)
    ..add(leylineHexToBytes(bindingHashHex))
    ..addByte(streamTag)
    ..addByte(payload.length)
    ..add(payload);

  return Uint8List.fromList(sha256.convert(buf.takeBytes()).bytes);
}

/// Big-endian unsigned comparison of two equal-length digests.
int compareLeylineScores(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}

/// Decodes a lowercase or uppercase hex string to its raw bytes.
Uint8List leylineHexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError('hex string must have an even length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
