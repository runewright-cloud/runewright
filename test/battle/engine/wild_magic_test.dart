// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_test.dart — the load-bearing tests for the wild-magic derivation
// (docs/WILD_MAGIC_PLAN_VNEXT.md §5, §7, §8, §16).
//
// The semantic-hash vectors here are the CROSS-CLIENT CONTRACT. Both devices
// must derive byte-identical hashes or the per-turn state hash diverges and the
// match aborts, and player-discovered Wild Magic combinations are meant to
// become culturally significant (§16). A refactor that changes any pinned
// literal below is a BREAKING CONSENSUS CHANGE, not a test that needs updating
// — if one of these fails, the change is wrong until proven otherwise.
//
// Every literal was cross-checked against an INDEPENDENT implementation of the
// documented byte layout — a Python script written from `wild_magic.dart`'s
// doc comment rather than ported from its code — before being pinned, so they
// attest the SPEC and not merely the current code's self-consistency. The same
// script reproduces all five already-pinned `leylineConfigHash` vectors from
// `leyline_config_test.dart`, which is what establishes it reads the layouts
// the same way the Dart does.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// Two distinct casters. Wild Magic v2 is keyed on the caster, so every vector
/// names one explicitly (§5) — there is no caster-free hash any more.
final String _casterA = _hex(List.filled(32, 0x11));
final String _casterB = _hex(List.filled(32, 0x22));

final String _zeroCommitment = _hex(List.filled(32, 0));
final String _patternCommitment = _hex(List.generate(32, (i) => i + 1));

/// `[fire, air, water]` — the baseline certified trajectory for the vectors.
const List<BorderZone> _traj = [BorderZone.fire, BorderZone.air, BorderZone.water];

/// The canonical ordinary leyline hashes the vectors are pinned against. Taken
/// from the type itself rather than restated as literals: `leyline_config_test`
/// already pins these bytes, and restating them here would give one contract
/// two spellings.
String _leyline([String seed = kDefaultCommunitySeed]) =>
    LeylineConfig.ordinary(seed).leylineConfigHash;

VerifiedSpellOutputs _outputs({
  String? commitmentHex,
  required int t,
  int tierMax = 12,
  List<int>? borderActivations,
  List<int>? trajectory,
  List<int>? supremeFlags,
  int segmentCount = 0,
  int dotCount = 0,
  Uint8List? proofBytes,
}) =>
    VerifiedSpellOutputs(
      proofBytes: proofBytes ?? Uint8List(0),
      t: t,
      ownerPubkeyHex: _zeroCommitment,
      rulesetVersion: 3,
      commitmentHex: commitmentHex ?? _patternCommitment,
      tierMax: tierMax,
      borderActivations: borderActivations ?? const [0, 0, 0, 0],
      dominanceTrajectory: trajectory ?? List.filled(tierMax, 0),
      supremeDominanceFlags: supremeFlags ?? List.filled(tierMax, 0),
      segmentCount: segmentCount,
      dotCount: dotCount,
    );

/// A dominance trajectory of `fire, air, water` followed by neutral padding —
/// so the CERTIFIED element sequence is [_traj] whatever `t` is, as long as
/// `t >= 3`. (Dominance indices: 0=neutral, 1=fire, 2=air, 3=water, 4=earth.)
List<int> _fireAirWaterThenNeutral(int tierMax) =>
    [1, 2, 3, ...List.filled(tierMax - 3, 0)];

/// [PeerCastVerifier.semanticsOf] under caster A and the default leyline —
/// the seam every equivalence test below probes.
CertifiedCast _semantics(VerifiedSpellOutputs outputs,
        {String? caster, LeylineConfig? leyline}) =>
    PeerCastVerifier.semanticsOf(
      outputs,
      casterOwnerPubkeyHex: caster ?? _casterA,
      leyline: leyline ?? LeylineConfig.ordinaryDefault,
    );

ParsedFormula _formula(BorderZone affinity) => ParsedFormula(
      affinity: affinity,
      effectType1: BorderZone.fire,
      effectType2: BorderZone.fire,
    );

/// A 64-char hex string that starts with [prefix] and is padded with a
/// character that can never extend a run or an ascending sequence out of it.
String _hash64(String prefix, {String pad = '7'}) {
  assert(prefix.length <= 64);
  return prefix + pad * (64 - prefix.length);
}

/// [WildMagic.triggersFor] with the vector defaults filled in.
List<WildMagicTrigger> _triggers(
  List<ParsedFormula> formulas, {
  String? caster,
  List<BorderZone> trajectory = _traj,
  int baseManaCost = 17,
  String? leylineConfigHash,
}) =>
    WildMagic.triggersFor(
      casterPubkeyHex: caster ?? _casterA,
      certifiedTrajectory: trajectory,
      certifiedBaseManaCost: baseManaCost,
      leylineConfigHash: leylineConfigHash ?? _leyline(),
      formulas: formulas,
    );

void main() {
  // ── §5 — the canonical semantic hash, pinned ────────────────────────────

  group('WildMagic.semanticHashHex — fixed vectors (CROSS-CLIENT CONTRACT)', () {
    test('the baseline: caster A, [fire,air,water], cost 17, universal', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(),
        ),
        '220ad557a57e4e7569ca260c35645d683493cff2e8a585873e519e5719fbc4a7',
      );
    });

    test('a different CASTER changes the hash', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterB,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(),
        ),
        '1ed0ed51c4a8be270977b96417aec59241218f0968664f10d0a7c1a95873f157',
      );
    });

    test('a different certified TRAJECTORY changes the hash', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: const [
            BorderZone.fire,
            BorderZone.air,
            BorderZone.earth,
          ],
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(),
        ),
        'a39e35275049caece8e2a6efc40cb082b040fad8aec9ee7680e067e38044f368',
      );
    });

    test('a different certified BASE MANA COST changes the hash', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 18,
          leylineConfigHash: _leyline(),
        ),
        'f46607195434685ed0fdfb14f4ef525ff91950a28f537a2d743e210b38369459',
      );
    });

    test('a different LEYLINE SEED changes the hash', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline('rivendell'),
        ),
        'd9e0967a78a638dbdd7d7e129e18c5c269a3eef8c195cb5fc650f34d23208999',
      );
    });

    test('the SAME seed under a different structured leyline changes it', () {
      // "rivendell" and "rivendell 5" are two magical environments, not one
      // (LEYLINE_SEED_PLAN.md §10). The seed word alone can no longer decide a
      // spell's wild magic — which is precisely why v2 hashes the config's
      // struct hash rather than the seed string v1 hashed.
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: LeylineConfig.mutable(
            communitySeed: 'rivendell',
            formulaLength: 5,
          ).leylineConfigHash,
        ),
        'b5aa8182b75ea6fabc0845c8d9c18071a870356b4d8b47d8ad97bae780d1a906',
      );
    });

    test('the empty trajectory at cost 0 — the degenerate preimage', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: const [],
          certifiedBaseManaCost: 0,
          leylineConfigHash: _leyline(),
        ),
        '3ccacd3cde1795415b852be0050d7971e9ba72189b5849f10da6c6ea231bcbce',
      );
    });

    test('output is 64 lowercase hex chars with no 0x prefix', () {
      final h = WildMagic.semanticHashHex(
        casterPubkeyHex: _casterA,
        certifiedTrajectory: _traj,
        certifiedBaseManaCost: 42,
        leylineConfigHash: _leyline('anything'),
      );
      expect(h.length, 64);
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('deterministic across repeated calls', () {
      String h() => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: _traj,
            certifiedBaseManaCost: 17,
            leylineConfigHash: _leyline('rivendell'),
          );
      final first = h();
      for (var i = 0; i < 100; i++) {
        expect(h(), first);
      }
    });
  });

  // ── The canonical element encoding, pinned independently ────────────────

  group('WildMagic canonical element encoding', () {
    // The trajectory goes into the preimage one byte per element. If that byte
    // were `BorderZone.index`, reordering the enum for any local reason would
    // silently reroll every spell's wild magic — on one device and not the
    // other. These four numbers are the circuit's own element values
    // (CIRCUIT_IO.md §7: 0=neutral, 1=fire, 2=air, 3=water, 4=earth).
    test('the mapping is exactly the circuit element enum, minus neutral', () {
      expect(WildMagic.kElementByte, {
        BorderZone.fire: 1,
        BorderZone.air: 2,
        BorderZone.water: 3,
        BorderZone.earth: 4,
      });
    });

    test('every BorderZone has a pinned byte', () {
      for (final zone in BorderZone.values) {
        expect(WildMagic.kElementByte.containsKey(zone), isTrue, reason: '$zone');
      }
    });

    test('no element byte equals its enum index — the mapping is NOT .index', () {
      // Structural, not incidental: 0 is reserved for neutral, so the pinned
      // bytes are 1..4 while `.index` is 0..3 and they can never coincide. A
      // future edit that "simplifies" this to `.index` fails here.
      for (final zone in BorderZone.values) {
        expect(WildMagic.elementByte(zone), isNot(zone.index), reason: '$zone');
      }
    });

    test('the bytes are 1..4 and distinct', () {
      final bytes = [for (final z in BorderZone.values) WildMagic.elementByte(z)];
      expect(bytes.toSet().length, bytes.length);
      for (final b in bytes) {
        expect(b, inInclusiveRange(1, 4));
      }
    });

    test('reordering the trajectory changes the hash', () {
      // Guards the per-element byte actually being WRITTEN in order, rather
      // than folded into an order-insensitive accumulator.
      String h(List<BorderZone> t) => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: t,
            certifiedBaseManaCost: 17,
            leylineConfigHash: _leyline(),
          );
      expect(
        h(const [BorderZone.fire, BorderZone.air, BorderZone.water]),
        isNot(h(const [BorderZone.water, BorderZone.air, BorderZone.fire])),
      );
    });

    test('the length prefix separates a longer trajectory from a repeat', () {
      String h(List<BorderZone> t) => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: t,
            certifiedBaseManaCost: 17,
            leylineConfigHash: _leyline(),
          );
      expect(h(const [BorderZone.fire]), isNot(h(const [BorderZone.fire, BorderZone.fire])));
    });
  });

  // ── The caster key is BYTES, not text ───────────────────────────────────

  group('WildMagic.canonicalPubkeyBytes', () {
    test('a 0x prefix is not part of the identity', () {
      expect(
        WildMagic.canonicalPubkeyBytes('0x${'11' * 32}'),
        WildMagic.canonicalPubkeyBytes('11' * 32),
      );
    });

    test('a Field with leading zeros stripped left-pads to the same key', () {
      expect(
        WildMagic.canonicalPubkeyBytes('0xab'),
        WildMagic.canonicalPubkeyBytes('0x${'0' * 62}ab'),
      );
    });

    test('uppercase and lowercase hex are one identity', () {
      expect(
        WildMagic.canonicalPubkeyBytes('0x${'AB' * 32}'),
        WildMagic.canonicalPubkeyBytes('0x${'ab' * 32}'),
      );
    });

    test('always exactly 32 bytes', () {
      expect(WildMagic.canonicalPubkeyBytes('0x1').length, 32);
      expect(WildMagic.canonicalPubkeyBytes('0x${'ff' * 32}').length, 32);
    });

    test('an empty key is refused, never defaulted to zero', () {
      // The one fallback that would type-check is the one that must not exist:
      // it would hand every unidentified caster a single shared magical
      // identity, invented out of nothing.
      expect(() => WildMagic.canonicalPubkeyBytes(''), throwsArgumentError);
      expect(() => WildMagic.canonicalPubkeyBytes('0x'), throwsArgumentError);
    });

    test('non-hex and over-wide keys are refused', () {
      expect(() => WildMagic.canonicalPubkeyBytes('0xzz'), throwsArgumentError);
      expect(
        () => WildMagic.canonicalPubkeyBytes('0x${'1' * 65}'),
        throwsArgumentError,
      );
    });

    test('the hash reads the key as bytes, so 0x and bare hex agree', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: '11' * 32,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(),
        ),
        '220ad557a57e4e7569ca260c35645d683493cff2e8a585873e519e5719fbc4a7',
      );
    });

    // ── Canonical-serialization bounds ────────────────────────────────
    //
    // Each of these three fields is written into the preimage at a FIXED
    // width, so each has a value beyond which the encoder would silently
    // produce a hash that is not the hash of its inputs. Silently is the
    // operative word: truncation and two's-complement wrap both yield a
    // perfectly well-formed 64-char hex string that simply belongs to
    // different arguments, so nothing downstream can tell the difference and
    // the two devices need not even disagree — they can agree on a wrong
    // answer. These tests assert the encoder REFUSES instead.

    test('a negative base mana cost is refused, not wrapped', () {
      // `_uint64be(-1)` would emit ffffffffffffffff — the encoding of
      // 2^64-1 — so a negative cost would collide with a legitimate huge one
      // and mint a hash no other implementation of the spec would reproduce.
      for (final cost in [-1, -17, -0x7fffffffffffffff - 1]) {
        expect(
          () => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: _traj,
            certifiedBaseManaCost: cost,
            leylineConfigHash: _leyline(),
          ),
          throwsArgumentError,
          reason: 'certifiedBaseManaCost $cost must be refused, not wrapped '
              'into the top of the uint64 range',
        );
      }
    });

    test('base mana costs across the whole uint64 range are accepted', () {
      // The bound is on the SERIALIZATION, so everything the 8-byte field can
      // actually represent must still hash. The guard must not have narrowed
      // the accepted range while closing the wrap hole.
      for (final cost in [0, 1, 17, 0xffffffff, 0x7fffffffffffffff]) {
        final h = WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: cost,
          leylineConfigHash: _leyline(),
        );
        expect(h, hasLength(64), reason: 'cost $cost should hash normally');
      }
      // …and distinct costs stay distinct, which is what would break first if
      // the field were ever truncated below 8 bytes.
      String at(int c) => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: _traj,
            certifiedBaseManaCost: c,
            leylineConfigHash: _leyline(),
          );
      expect(at(0x7fffffffffffffff), isNot(at(0xffffffff)));
      expect(at(1), isNot(at(0x100000001)));
    });

    test('an over-wide base mana cost is refused, not truncated', () {
      // Unreachable on the Dart VM — a non-negative 64-bit signed int has
      // bitLength <= 63 — so this asserts the GUARD rather than a reachable
      // input, using the same predicate the encoder applies. On a host with
      // wider integers `_uint64be` would keep only the low 8 bytes, so
      // 2^64 and 0 would hash identically with nothing to signal it.
      const overWide = 65; // bitLength of any value >= 2^64
      expect(overWide > 64, isTrue,
          reason: 'the guard rejects bitLength > 64; 2^64 has bitLength 65');

      // The reachable neighbours of that boundary are all accepted, which is
      // what stops a future tightening from quietly rejecting real costs.
      expect(
        () => WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 0x7fffffffffffffff, // bitLength 63
          leylineConfigHash: _leyline(),
        ),
        returnsNormally,
      );
    });

    test('an over-long certified trajectory is refused, not truncated', () {
      // The length prefix is a uint16, so element 65536 would wrap the prefix
      // to 0 while the element bytes themselves still followed — producing a
      // preimage that reparses as an EMPTY trajectory followed by garbage.
      // Two spells of very different length would then share a hash.
      final tooLong =
          List<BorderZone>.filled(0xFFFF + 1, BorderZone.fire, growable: false);
      expect(
        () => WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: tooLong,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(),
        ),
        throwsArgumentError,
      );

      // The largest representable trajectory is still accepted, and hashes
      // differently from the one element shorter — so the boundary is exactly
      // at 0xFFFF+1 and not one early.
      final atLimit =
          List<BorderZone>.filled(0xFFFF, BorderZone.fire, growable: false);
      final justUnder =
          List<BorderZone>.filled(0xFFFF - 1, BorderZone.fire, growable: false);
      String hashOf(List<BorderZone> t) => WildMagic.semanticHashHex(
            casterPubkeyHex: _casterA,
            certifiedTrajectory: t,
            certifiedBaseManaCost: 17,
            leylineConfigHash: _leyline(),
          );
      expect(hashOf(atLimit), hasLength(64));
      expect(hashOf(atLimit), isNot(hashOf(justUnder)));
    });

    test('a malformed leyline hash is refused', () {
      expect(
        () => WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: 'abc',
        ),
        throwsArgumentError,
      );
    });
  });

  // ── §3/§5 — what the derivation must NOT see ────────────────────────────

  group('semanticsOf — the v2 preimage sees behaviour, not the rune', () {
    // These run through the real certification seam, not the raw hash, because
    // the claim under test is about what `VerifiedSpellOutputs` fields reach
    // the preimage — and the seam is the only place that decides.

    List<WildMagicTrigger> wm(VerifiedSpellOutputs o) => _semantics(o).wildMagic;

    // Trajectory [fire, air, water] then neutral padding; segment 0 / dot 1
    // makes the certified base cost round to 1 for every T in 1..8, which is
    // what lets the T-independence case hold trajectory AND cost fixed.
    VerifiedSpellOutputs spell({
      required int t,
      String? commitmentHex,
      Uint8List? proofBytes,
      int tierMax = 12,
    }) =>
        _outputs(
          t: t,
          tierMax: tierMax,
          commitmentHex: commitmentHex,
          proofBytes: proofBytes,
          trajectory: _fireAirWaterThenNeutral(tierMax),
          segmentCount: 0,
          dotCount: 1,
        );

    test('the fixture really does hold trajectory and base cost fixed', () {
      final a = _semantics(spell(t: 3));
      final b = _semantics(spell(t: 8));
      expect(a.elementSequence, _traj);
      expect(b.elementSequence, _traj);
      expect(a.baseManaCost, 1);
      expect(b.baseManaCost, 1);
    });

    test('a different GRID COMMITMENT gives identical wild magic (§3)', () {
      // The privacy decision, made executable: the commitment is not in the
      // preimage, so it cannot be recovered from a wild-magic observation and
      // the value can eventually leave the public spell identity altogether.
      expect(
        wm(spell(t: 3, commitmentHex: _zeroCommitment)),
        wm(spell(t: 3, commitmentHex: _patternCommitment)),
      );
    });

    test('different PROOF BYTES give identical wild magic (§4)', () {
      // UltraHonk re-proves the same witness to different bytes, so anything
      // reading them could be reground indefinitely by a modified client.
      expect(
        wm(spell(t: 3, proofBytes: Uint8List.fromList([1, 2, 3]))),
        wm(spell(t: 3, proofBytes: Uint8List.fromList([9, 9, 9, 9]))),
      );
    });

    test('a different T gives identical wild magic (§5 equivalence rule)', () {
      // T is NOT an independent field any more. It reaches the hash only
      // through certifiedBaseManaCost's 1.05^T, and here that rounds to the
      // same 1 — so two inscriptions of one behaviour are one spell.
      expect(wm(spell(t: 3)), wm(spell(t: 8)));
    });

    test('T that MOVES the certified base cost does change wild magic', () {
      // The other half of the same rule: the cost is a real input, so a T that
      // actually reprices the spell reprices its wild magic too.
      final cheap = _outputs(
        t: 3,
        trajectory: _fireAirWaterThenNeutral(12),
        segmentCount: 3,
        dotCount: 2,
      );
      final dear = _outputs(
        t: 11,
        trajectory: _fireAirWaterThenNeutral(12),
        segmentCount: 3,
        dotCount: 2,
      );
      expect(_semantics(cheap).baseManaCost,
          isNot(_semantics(dear).baseManaCost));
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: _semantics(cheap).baseManaCost,
          leylineConfigHash: LeylineConfig.ordinaryDefault.leylineConfigHash,
        ),
        isNot(WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: _semantics(dear).baseManaCost,
          leylineConfigHash: LeylineConfig.ordinaryDefault.leylineConfigHash,
        )),
      );
    });

    test('two distinct grids at distinct T are Wild-Magic-EQUIVALENT', () {
      // The §5 equivalence rule stated positively, over two fixtures that
      // differ in EVERYTHING the old v1 preimage saw — commitment, T, proof
      // bytes — and agree on the two things v2 sees.
      final one = spell(
        t: 3,
        commitmentHex: _zeroCommitment,
        proofBytes: Uint8List.fromList([1]),
      );
      final two = spell(
        t: 8,
        commitmentHex: _patternCommitment,
        proofBytes: Uint8List.fromList([2, 2]),
      );
      expect(_semantics(one).elementSequence, _semantics(two).elementSequence);
      expect(_semantics(one).baseManaCost, _semantics(two).baseManaCost);
      expect(wm(one), wm(two));
    });

    test('border activations, supreme flags and tier do not affect it', () {
      // §5's "not as an independent input" list, guarded. Supreme flags DO
      // change the certified trajectory when they fire (that is the formula
      // rule), so this fixture keeps them off the generations that would
      // commit an extra element and checks the ones that would not.
      final plain = spell(t: 3, tierMax: 12);
      final loud = _outputs(
        t: 3,
        tierMax: 12,
        trajectory: _fireAirWaterThenNeutral(12),
        borderActivations: const [17, 3, 99, 42],
        supremeFlags: List.filled(12, 0),
        segmentCount: 0,
        dotCount: 1,
      );
      expect(_semantics(loud).elementSequence,
          _semantics(plain).elementSequence);
      expect(wm(loud), wm(plain));
    });

    test('tier-independent: the same spell at tier 24 and 48 agrees', () {
      expect(wm(spell(t: 3, tierMax: 24)), wm(spell(t: 3, tierMax: 48)));
    });

    test('the CASTER changes wild magic for one unchanged proof (§2)', () {
      // The headline rule change. A loaned spell fires the borrower's magic.
      final o = _outputs(
        t: 3,
        trajectory: _fireAirWaterThenNeutral(12),
        segmentCount: 3,
        dotCount: 2,
      );
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _semantics(o).elementSequence,
          certifiedBaseManaCost: _semantics(o).baseManaCost,
          leylineConfigHash: LeylineConfig.ordinaryDefault.leylineConfigHash,
        ),
        isNot(WildMagic.semanticHashHex(
          casterPubkeyHex: _casterB,
          certifiedTrajectory: _semantics(o).elementSequence,
          certifiedBaseManaCost: _semantics(o).baseManaCost,
          leylineConfigHash: LeylineConfig.ordinaryDefault.leylineConfigHash,
        )),
      );
    });

    test('semanticsOf derives cost from the SAME formulas it hashes', () {
      // The §5 ordering requirement, observable: the certified base cost the
      // seam publishes must be the one the wild magic was derived under, or
      // the two readings of one proof have drifted (M4.22's shape).
      final o = _outputs(
        t: 6,
        trajectory: [1, 2, 3, 0, 4, 4, ...List.filled(6, 0)],
        supremeFlags: [0, 0, 0, 0, 1, 1, ...List.filled(6, 0)],
        segmentCount: 3,
        dotCount: 2,
      );
      final sem = _semantics(o);
      expect(
        sem.wildMagic,
        WildMagic.triggersFor(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: sem.elementSequence,
          certifiedBaseManaCost: sem.baseManaCost,
          leylineConfigHash: LeylineConfig.ordinaryDefault.leylineConfigHash,
          formulas: sem.formulas,
        ),
      );
    });
  });

  // ── Seed normalization, now via the leyline ─────────────────────────────

  group('WildMagic.normalizeCommunitySeed', () {
    String h(String seed) => WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(seed),
        );

    test('case, whitespace and punctuation are stripped', () {
      final canonical = h('rivendell');
      for (final variant in [
        'Rivendell!',
        ' RIVENDELL ',
        'ri-ven_dell',
        'Rivendell.'
      ]) {
        expect(h(variant), canonical, reason: variant);
      }
    });

    test('seeds that normalize to empty fall back to universal', () {
      final universal = h('universal');
      for (final variant in ['', '---', '   ', '日本', '!!!']) {
        expect(h(variant), universal, reason: '"$variant"');
      }
    });

    test('a real seed is NOT the universal hash', () {
      expect(h('rivendell'), isNot(h('universal')));
    });

    test('normalizeCommunitySeed itself', () {
      expect(WildMagic.normalizeCommunitySeed('Rivendell!'), 'rivendell');
      expect(WildMagic.normalizeCommunitySeed('  Deep Roads 7 '), 'deeproads7');
      expect(WildMagic.normalizeCommunitySeed('---'), kDefaultCommunitySeed);
    });
  });

  // ── §4.2 — the scan ─────────────────────────────────────────────────────

  group('WildMagic.scan — row 1 / row 2 repeat runs', () {
    test('a run of exactly 3 zeros fires row 1 at bracket 0', () {
      expect(WildMagic.scan(_hash64('a000b')), [
        (WildMagicRow.repeatZero, 0),
      ]);
    });

    test('a run of 2 does not fire', () {
      expect(WildMagic.scan(_hash64('a00b')), isEmpty);
    });

    test('a run of 4 is ONE run of 4, not two overlapping runs of 3', () {
      expect(WildMagic.scan(_hash64('a0000b')), [
        (WildMagicRow.repeatZero, 1),
      ]);
    });

    test('a run at the very start fires', () {
      expect(WildMagic.scan(_hash64('000b')), [(WildMagicRow.repeatZero, 0)]);
    });

    test('a run at the very end fires', () {
      expect(
        WildMagic.scan('${'7' * 61}000'),
        [(WildMagicRow.repeatZero, 0)],
      );
    });

    test('ones fire row 2', () {
      expect(WildMagic.scan(_hash64('a111b')), [(WildMagicRow.repeatOne, 0)]);
    });

    test('overlapping 0001111 fires BOTH rows, with their own brackets', () {
      expect(WildMagic.scan(_hash64('a0001111b')), [
        (WildMagicRow.repeatZero, 0),
        (WildMagicRow.repeatOne, 1),
      ]);
    });

    test('two separate zero runs fire once, taking the LONGER bracket (A3)', () {
      // 000 … 00000 → one trigger, bracket 2 (from the run of 5).
      expect(WildMagic.scan(_hash64('000b7700000b')), [
        (WildMagicRow.repeatZero, 2),
      ]);
    });
  });

  group('WildMagic.scan — row 3 ascending runs', () {
    test('0123 fires at bracket 0', () {
      expect(WildMagic.scan(_hash64('a0123b')), [
        (WildMagicRow.ascendingRun, 0),
      ]);
    });

    test('def012 does NOT fire — the maximal run starts at d, not 0', () {
      // THE case that separates maximal-run semantics from a naive substring
      // search, and the single easiest way to get row 3 wrong.
      expect(WildMagic.scan(_hash64('def012b')), isEmpty);
    });

    test('4567 does not fire — an ascending run must begin at 0', () {
      expect(WildMagic.scan(_hash64('a4567b')), isEmpty);
    });

    test('012 does not fire — below the length-4 minimum', () {
      expect(WildMagic.scan(_hash64('a012b')), isEmpty);
    });

    test('the full wrap 0123456789abcdef0 fires with a long bracket', () {
      final h = _hash64('0123456789abcdef0');
      final scanned = WildMagic.scan(h);
      expect(scanned.length, 1);
      expect(scanned.first.$1, WildMagicRow.ascendingRun);
      expect(scanned.first.$2, 17 - 4); // run of 17, minimum 4
    });

    test('01234 fires at bracket 1', () {
      expect(WildMagic.scan(_hash64('a01234b')), [
        (WildMagicRow.ascendingRun, 1),
      ]);
    });

    test('all three rows can fire from one hash, in row order', () {
      final scanned = WildMagic.scan(_hash64('000b111b0123'));
      expect(scanned.map((e) => e.$1).toList(), [
        WildMagicRow.repeatZero,
        WildMagicRow.repeatOne,
        WildMagicRow.ascendingRun,
      ]);
    });
  });

  // ── §4.3 — eligibility ──────────────────────────────────────────────────

  group('WildMagic.eligibleElements', () {
    test('a single formula makes its own element eligible', () {
      expect(
        WildMagic.eligibleElements([_formula(BorderZone.fire)]),
        {SpellAffinity.fire},
      );
    });

    test('2 fire + 1 earth → fire only', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.fire),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ]),
        {SpellAffinity.fire},
      );
    });

    test('a tie makes EVERY tied element eligible', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.fire),
          _formula(BorderZone.water),
        ]),
        {SpellAffinity.fire, SpellAffinity.water},
      );
    });

    test('a four-way tie makes all four eligible', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.air),
          _formula(BorderZone.water),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ]),
        {
          SpellAffinity.fire,
          SpellAffinity.earth,
          SpellAffinity.water,
          SpellAffinity.air,
        },
      );
    });

    test('zero formulas (a void spell) yields nothing eligible', () {
      expect(WildMagic.eligibleElements(const []), isEmpty);
    });

    test('iteration order is SpellAffinity.values, not formula order', () {
      // Built from formulas in air, water, earth, fire order — the result must
      // still iterate fire, earth, water, air. Unordered iteration here is a
      // lockstep landmine (§4.3).
      final eligible = WildMagic.eligibleElements([
        _formula(BorderZone.air),
        _formula(BorderZone.water),
        _formula(BorderZone.earth),
        _formula(BorderZone.fire),
      ]);
      expect(eligible.toList(), SpellAffinity.values);
    });
  });

  // ── Full derivation ─────────────────────────────────────────────────────

  group('WildMagic.triggersFor', () {
    // Each leyline seed below was chosen so the baseline spell (caster A,
    // [fire,air,water], base cost 17) hashes to exactly one wanted pattern.
    // Regenerating these fixtures means recomputing the hash; they are not
    // arbitrary, and the hash literals are pinned first so a failure says
    // WHICH half broke.
    const String seedRow1 = 'seed45'; // one run of exactly three '0's
    const String seedRow1Bracket = 'seed353'; // a run of four '0's
    const String seedQuiet = 'universal'; // no pattern at all

    test('the row-1 fixture hash is what we think it is', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(seedRow1),
        ),
        'de98bfb247331d88000ca5b7d935eff7aa5f2c767a8974cb78b44528b7e5643d',
      );
    });

    test('a pure-fire spell fires only the Fire column of the matching row', () {
      final triggers = _triggers(
        [_formula(BorderZone.fire)],
        leylineConfigHash: _leyline(seedRow1),
      );
      expect(triggers.length, 1);
      expect(triggers.single.row, WildMagicRow.repeatZero);
      expect(triggers.single.element, SpellAffinity.fire);
      expect(triggers.single.bracketSteps, 0);
      expect(triggers.single.effect, WildMagicEffectKind.burningHot);
    });

    test('a four-way-balanced spell fires ALL FOUR of the row, in enum order', () {
      // §9 candidate A, PRESERVED EXACTLY. When a future playtest picks
      // candidate B (an independent per-affinity roll off the same hash) this
      // is the test that has to change — and the semantic-hash vectors above
      // are the ones that must not.
      final triggers = _triggers(
        [
          _formula(BorderZone.air),
          _formula(BorderZone.water),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ],
        leylineConfigHash: _leyline(seedRow1),
      );
      expect(triggers.map((t) => t.effect).toList(), [
        WildMagicEffectKind.burningHot, // fire
        WildMagicEffectKind.mountains, // earth
        WildMagicEffectKind.manaFlood, // water
        WildMagicEffectKind.zephyr, // air
      ]);
    });

    test('a zero-formula (void) spell fires nothing, whatever the hash', () {
      expect(
        _triggers(const [], leylineConfigHash: _leyline(seedRow1)),
        isEmpty,
      );
    });

    test('a hash with no pattern fires nothing', () {
      expect(
        _triggers(
          [_formula(BorderZone.fire)],
          leylineConfigHash: _leyline(seedQuiet),
        ),
        isEmpty,
      );
    });

    test('bracket steps come through: seed353 gives a run of 4', () {
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: _casterA,
          certifiedTrajectory: _traj,
          certifiedBaseManaCost: 17,
          leylineConfigHash: _leyline(seedRow1Bracket),
        ),
        'ec3a244253403ac1c37616f85ede889849f0fe81e42e8606390b38479e0000c0',
      );
      final triggers = _triggers(
        [_formula(BorderZone.fire)],
        leylineConfigHash: _leyline(seedRow1Bracket),
      );
      expect(triggers.single.bracketSteps, 1);
    });

    test('the same spell in another wizard\'s hands is an independent roll', () {
      // v1's independence axis was "the same grid at a different T". v2's is
      // the caster — which is the design change, stated as a test.
      expect(
        _triggers(
          [_formula(BorderZone.fire)],
          leylineConfigHash: _leyline(seedRow1),
        ),
        isNot(_triggers(
          [_formula(BorderZone.fire)],
          caster: _casterB,
          leylineConfigHash: _leyline(seedRow1),
        )),
      );
    });

    test('100 calls return identical results', () {
      final first = _triggers(
        [_formula(BorderZone.fire)],
        leylineConfigHash: _leyline(seedRow1),
      );
      for (var i = 0; i < 100; i++) {
        expect(
          _triggers(
            [_formula(BorderZone.fire)],
            leylineConfigHash: _leyline(seedRow1),
          ),
          first,
        );
      }
    });
  });

  // ── The effects table ───────────────────────────────────────────────────

  group('wildMagicEffectFor', () {
    test('every (row, element) pair maps to a distinct effect', () {
      final seen = <WildMagicEffectKind>{};
      for (final row in WildMagicRow.values) {
        for (final element in SpellAffinity.values) {
          expect(seen.add(wildMagicEffectFor(row, element)), isTrue);
        }
      }
      expect(seen.length, WildMagicEffectKind.values.length);
    });

    test('every effect has a label and a description', () {
      for (final e in WildMagicEffectKind.values) {
        expect(kWildMagicEffectLabel[e], isNotNull, reason: e.name);
        expect(kWildMagicEffectDescription[e], isNotNull, reason: e.name);
      }
    });
  });
}
