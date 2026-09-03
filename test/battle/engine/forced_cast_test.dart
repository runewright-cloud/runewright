// SPDX-License-Identifier: GPL-3.0-or-later
//
// forced_cast_test.dart — the forced reveal-and-cast primitive
// (docs/WILD_MAGIC_PLAN.md §9.5).
//
// The property that makes this fair, and the one worth testing hardest: slots
// are selected PUBLICLY, from the position-only DrawSchedule both clients
// already hold, BEFORE anybody reveals anything. So the revealer cannot shop
// for a favourable spell, and the receiver can check that what arrived matches
// the slot that was actually chosen.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/book_commitment.dart'
    show MembershipProof;
import 'package:rune_duel/battle/engine/forced_cast.dart';
import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

SpellAsset _spell(String tag, {Uint8List? proof}) => SpellAsset(
      id: tag,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      tier: 24,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 6,
      segmentCount: 1,
      dotCount: 1,
      initialGrid: const [],
      proofBytes: proof ?? Uint8List.fromList([1, 2, 3, 4]),
      name: 'Spell $tag',
      commitmentHex: '0x${tag * 64}'.substring(0, 66),
      spellHashHex: '0x${'b' * 64}',
      formula: const ['fire', 'fire', 'fire'],
    );

class _FakeHost implements ForcedCastHost {
  _FakeHost({
    this.localId = 'me',
    Map<String, List<int>>? hands,
    Map<int, SpellAsset>? localSpells,
  })  : hands = hands ?? {'me': [0, 1, 2], 'you': [3, 4, 5]},
        localSpells = localSpells ??
            {0: _spell('a'), 1: _spell('b'), 2: _spell('c')};

  final String localId;
  final Map<String, List<int>> hands;
  final Map<int, SpellAsset> localSpells;

  /// What `exchangeForcedReveal` hands back. Null = solo (no peer).
  Uint8List? peerReply;

  Uint8List? sentPayload;
  final List<ForcedCastPick> resolved = [];
  final List<(String, int)> verified = [];
  final List<String> forfeits = [];

  /// Every host callback the sequencer makes, in order. The N-player rule this
  /// has to keep room for is "all selections and reveals are fixed before any
  /// forced cast resolves", and that is a statement about ORDER — nothing the
  /// per-callback assertions elsewhere in this file can see.
  final List<String> calls = [];

  @override
  List<int> publicHandPositions(String playerId) {
    calls.add('select:$playerId');
    return List<int>.from(hands[playerId] ?? const <int>[]);
  }

  @override
  Uint8List forcedCastSeed(String playerId, String reasonTag) =>
      Uint8List.fromList(
        List.generate(32, (i) => (playerId.hashCode + reasonTag.length + i) & 0xFF),
      );

  @override
  bool isLocalPlayer(String playerId) => playerId == localId;

  @override
  SpellAsset? localSpellAt(int position) => localSpells[position];

  @override
  MembershipProof? localMembershipProofAt(int position) => null;

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ours) async {
    calls.add('exchange');
    sentPayload = ours;
    return peerReply;
  }

  /// What [verifyForcedReveal] certifies. Null (the default) is the "nothing
  /// to certify" case — solo, or verification not wired up.
  CertifiedCast? certifies;

  /// What [certifiedFromProofBytes] derives, per spell id. The fake keeps the
  /// two sources separate so a test can tell which one a pick read.
  final Map<String, CertifiedCast> ownProofSemantics = {};

  @override
  Future<CertifiedCast?> verifyForcedReveal(
    String playerId,
    int position,
    SpellAsset spell,
    MembershipProof? merkleProof,
  ) async {
    calls.add('verify:$playerId:$position');
    verified.add((playerId, position));
    return certifies;
  }

  @override
  CertifiedCast? certifiedFromProofBytes(
    SpellAsset spell, {
    required String casterPlayerId,
  }) =>
      ownProofSemantics[spell.id];

  @override
  Future<void> resolveForcedCast(ForcedCastPick pick, HashRng rng) async {
    calls.add('resolve:${pick.playerId}:${pick.position}');
    resolved.add(pick);
  }

  @override
  void forfeitMatch(String reason) => forfeits.add(reason);
}

HashRng _rngFor(String _) => HashRng(Uint8List(32));

/// A one-element [CertifiedCast] marker. The tests below only need to tell two
/// certified values apart, so the element sequence carries the tag.
CertifiedCast _semantics(BorderZone tag) => CertifiedCast(
      formulas: const [],
      elementSequence: [tag],
      wildMagic: const [],
      // Irrelevant here: a forced cast is free (A8), so nothing on these paths
      // reads the base price. Zero rather than a real number so a test that
      // starts depending on it fails loudly instead of quietly agreeing.
      baseManaCost: 0,
    );

const _request = ForcedCastRequest(
  affectedPlayerIds: {'me', 'you'},
  countPerPlayer: 1,
  reasonTag: 'spontaneousCombustion',
);

void main() {
  // ── Codec ───────────────────────────────────────────────────────────────

  group('wire codec', () {
    test('round-trips a pick', () {
      final spell = _spell('a');
      final bytes = ForcedCast.encodeReveal([
        (position: 7, spell: spell, proof: null),
      ]);
      final decoded = ForcedCast.decodeReveal(bytes);

      expect(decoded, hasLength(1));
      expect(decoded.single.position, 7);
      expect(decoded.single.spell.commitmentHex, spell.commitmentHex);
      expect(decoded.single.spell.t, spell.t);
      expect(decoded.single.spell.name, spell.name);
      expect(decoded.single.spell.formula, spell.formula);
      expect(decoded.single.spell.proofBytes, spell.proofBytes);
    });

    test('round-trips several picks in order', () {
      final bytes = ForcedCast.encodeReveal([
        (position: 2, spell: _spell('a'), proof: null),
        (position: 9, spell: _spell('b'), proof: null),
      ]);
      final decoded = ForcedCast.decodeReveal(bytes);
      expect(decoded.map((d) => d.position), [2, 9]);
    });

    test('carries the Merkle path', () {
      final proof = MembershipProof(
        root: '',
        leafHex: '0x${'a' * 64}',
        siblings: ['0x${'1' * 64}', '0x${'2' * 64}'],
        directions: const [true, false],
      );
      final decoded = ForcedCast.decodeReveal(
        ForcedCast.encodeReveal([
          (position: 1, spell: _spell('a'), proof: proof),
        ]),
      );
      expect(decoded.single.proof!.siblings, proof.siblings);
      expect(decoded.single.proof!.directions, proof.directions);
    });

    test('a summon survives the round trip', () {
      final summon = SpellAsset(
        id: 's',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        tier: 24,
        t: 5,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 6,
        segmentCount: 1,
        dotCount: 1,
        initialGrid: const [],
        proofBytes: Uint8List.fromList([9]),
        name: 'Hound',
        commitmentHex: '0x${'e' * 64}',
        spellHashHex: '0x${'f' * 64}',
        formula: const ['earth', 'earth', 'earth'],
        isSummon: true,
        summonPersonality: 'defensive',
      );
      final decoded = ForcedCast.decodeReveal(
        ForcedCast.encodeReveal([(position: 0, spell: summon, proof: null)]),
      );
      expect(decoded.single.spell.isSummon, isTrue);
      expect(decoded.single.spell.summonPersonality, 'defensive');
    });

    test('an empty payload decodes to nothing', () {
      expect(ForcedCast.decodeReveal(Uint8List(0)), isEmpty);
    });

    test('a truncated payload throws rather than silently short-reading', () {
      final full = ForcedCast.encodeReveal([
        (position: 1, spell: _spell('a'), proof: null),
      ]);
      expect(
        () => ForcedCast.decodeReveal(full.sublist(0, full.length - 5)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ── Sequence ────────────────────────────────────────────────────────────

  group('ForcedCast.run', () {
    test('solo (no peer): resolves only the local pick, awaits nothing',
        () async {
      final host = _FakeHost();
      await ForcedCast.run(_request, host, _rngFor);

      expect(host.resolved, hasLength(1));
      expect(host.resolved.single.playerId, 'me');
      expect(host.resolved.single.position, isIn([0, 1, 2]));
      expect(host.forfeits, isEmpty);
    });

    test('sends exactly the local picks, and nobody else\'s', () async {
      final host = _FakeHost();
      await ForcedCast.run(_request, host, _rngFor);

      final sent = ForcedCast.decodeReveal(host.sentPayload!);
      expect(sent, hasLength(1));
      expect(sent.single.position, isIn([0, 1, 2]),
          reason: 'only our own hand positions are ours to reveal');
    });

    test('slot selection is deterministic for the same seed', () async {
      Future<int> pick() async {
        final host = _FakeHost();
        await ForcedCast.run(_request, host, _rngFor);
        return host.resolved.single.position;
      }

      expect(await pick(), await pick());
    });

    test('countPerPlayer > 1 picks distinct slots', () async {
      final host = _FakeHost();
      await ForcedCast.run(
        const ForcedCastRequest(
          affectedPlayerIds: {'me'},
          countPerPlayer: 3,
          reasonTag: 'x',
        ),
        host,
        _rngFor,
      );
      expect(host.resolved.map((p) => p.position).toSet(), hasLength(3));
    });

    test('a player with an empty hand is skipped, not crashed on', () async {
      final host = _FakeHost(hands: {'me': const [], 'you': const []});
      await ForcedCast.run(_request, host, _rngFor);
      expect(host.resolved, isEmpty);
      expect(host.forfeits, isEmpty);
    });

    test('a peer reveal is verified and resolved', () async {
      final host = _FakeHost();
      // The peer's slot is chosen from ITS hand [3,4,5] by the same public
      // rule, so re-derive it rather than hard-coding a number.
      final peerSlot = await _peerSelectedSlot();

      host.peerReply = ForcedCast.encodeReveal([
        (position: peerSlot, spell: _spell('d'), proof: null),
      ]);
      await ForcedCast.run(_request, host, _rngFor);

      expect(host.verified, [('you', peerSlot)]);
      expect(host.resolved.map((p) => p.playerId), containsAll(['me', 'you']));
      expect(host.forfeits, isEmpty);
    });

    // ── Certified semantics on the pick (M4.20) ──────────────────────────
    //
    // The sequencer's job is to put the PROOF's answer on every pick before
    // resolution sees it. Which side of the trust boundary a pick came from
    // decides where that answer comes from, and the fake host keeps the two
    // sources distinguishable so the branch is actually observable.

    test('a LOCAL pick carries the semantics derived from its own proof bytes',
        () async {
      final host = _FakeHost();
      // Every local slot maps to the same marker, so this passes whichever
      // slot the public selection lands on.
      for (final spell in host.localSpells.values) {
        host.ownProofSemantics[spell.id] = _semantics(BorderZone.earth);
      }
      // What a PEER reveal would have certified — must not be what a local
      // pick picks up.
      host.certifies = _semantics(BorderZone.water);

      await ForcedCast.run(_request, host, _rngFor);

      final pick = host.resolved.singleWhere((p) => p.playerId == 'me');
      expect(pick.certified, isNotNull,
          reason: 'our own pick never crosses verifyForcedReveal, so it must '
              'derive its semantics from its own proof');
      expect(pick.certified!.elementSequence, [BorderZone.earth]);
    });

    test('a PEER pick carries what verifyForcedReveal certified', () async {
      final host = _FakeHost();
      final peerSlot = await _peerSelectedSlot();
      host.certifies = _semantics(BorderZone.water);
      host.peerReply = ForcedCast.encodeReveal([
        (position: peerSlot, spell: _spell('d'), proof: null),
      ]);

      await ForcedCast.run(_request, host, _rngFor);

      final pick = host.resolved.singleWhere((p) => p.playerId == 'you');
      expect(pick.certified, isNotNull);
      expect(pick.certified!.elementSequence, [BorderZone.water],
          reason: 'the verification result is the only authority for a peer '
              'reveal — this is the value M4.20 used to discard');
    });

    test('a PEER pick falls back to parsing the revealed proof when nothing '
        'was certified (solo / verification not wired up)', () async {
      final host = _FakeHost();
      final peerSlot = await _peerSelectedSlot();
      host.certifies = null; // uncertified — not a verification FAILURE
      // decodeReveal reconstructs the spell with an empty id, which is the key
      // the fake's own-proof derivation is looking up.
      host.ownProofSemantics[''] = _semantics(BorderZone.air);
      host.peerReply = ForcedCast.encodeReveal([
        (position: peerSlot, spell: _spell('d'), proof: null),
      ]);

      await ForcedCast.run(_request, host, _rngFor);

      final pick = host.resolved.singleWhere((p) => p.playerId == 'you');
      expect(pick.certified!.elementSequence, [BorderZone.air],
          reason: 'parsing the revealed proof unverified is still strictly '
              'better than the authored formula, and is what the revealing '
              'device itself resolved from');
    });

    test('a pick carries no semantics when there is no proof to derive from',
        () async {
      final host = _FakeHost(); // no ownProofSemantics, no certifies
      await ForcedCast.run(_request, host, _rngFor);
      expect(host.resolved.single.certified, isNull,
          reason: 'both devices see the same absence, so the wire fallback '
              'stays desync-safe');
    });

    test('a reveal for the WRONG slot forfeits — no shopping for a spell',
        () async {
      final host = _FakeHost();
      final peerSlot = await _peerSelectedSlot();
      final wrongSlot = [3, 4, 5].firstWhere((p) => p != peerSlot);

      host.peerReply = ForcedCast.encodeReveal([
        (position: wrongSlot, spell: _spell('d'), proof: null),
      ]);

      await expectLater(
        ForcedCast.run(_request, host, _rngFor),
        throwsA(isA<StateError>()),
      );
      expect(host.forfeits, ['forced_reveal_slot_mismatch']);
    });

    test('a withheld reveal forfeits, like a withheld nonce', () async {
      final host = _FakeHost()..peerReply = ForcedCast.encodeReveal([]);
      await expectLater(
        ForcedCast.run(_request, host, _rngFor),
        throwsA(isA<StateError>()),
      );
      expect(host.forfeits, ['withheld_forced_reveal']);
    });

    test('a malformed reveal forfeits', () async {
      final host = _FakeHost()
        ..peerReply = Uint8List.fromList([1, 0, 0]); // claims 1 entry, truncated
      await expectLater(
        ForcedCast.run(_request, host, _rngFor),
        throwsA(isA<StateError>()),
      );
      expect(host.forfeits.single, startsWith('malformed_forced_reveal'));
    });

    test('every selection and reveal is fixed before anything resolves',
        () async {
      // select-all -> exchange -> verify-all -> resolve-all. The 2-player flow
      // already has this shape; pinning it keeps the N-player slice from
      // having to re-derive it, and would catch an "optimisation" that
      // resolved each pick as it was verified.
      final host = _FakeHost();
      host.peerReply = ForcedCast.encodeReveal([
        (position: await _peerSelectedSlot(), spell: _spell('d'), proof: null),
      ]);
      await ForcedCast.run(_request, host, _rngFor);

      final phaseOf = <String, int>{
        'select': 0,
        'exchange': 1,
        'verify': 2,
        'resolve': 3,
      };
      final phases = [
        for (final c in host.calls) phaseOf[c.split(':').first]!,
      ];
      expect(phases, isNotEmpty);
      for (var i = 1; i < phases.length; i++) {
        expect(phases[i], greaterThanOrEqualTo(phases[i - 1]),
            reason: 'phases ran out of order: ${host.calls}');
      }
      // And both halves really happened, so the ordering is not vacuous.
      expect(host.calls.where((c) => c.startsWith('resolve')), hasLength(2));
      expect(host.calls.where((c) => c.startsWith('verify')), hasLength(1));
    });

    test('resolution order is (playerId, position) sorted', () async {
      final host = _FakeHost();
      host.peerReply = ForcedCast.encodeReveal([
        (position: await _peerSelectedSlot(), spell: _spell('d'), proof: null),
      ]);
      await ForcedCast.run(_request, host, _rngFor);

      final order = host.resolved
          .map((p) => '${p.playerId}:${p.position}')
          .toList();
      final sorted = List<String>.from(order)..sort();
      expect(order, sorted);
    });
  });
}

/// Which slot the PUBLIC selector picks out of the peer's hand.
///
/// Re-derives it by running the same sequence with the roles flipped, so the
/// test never hard-codes a number the selector might legitimately change.
Future<int> _peerSelectedSlot() async {
  final flipped = _FakeHost(
    localId: 'you',
    localSpells: {3: _spell('d'), 4: _spell('e'), 5: _spell('f')},
  );
  await ForcedCast.run(_request, flipped, _rngFor);
  return flipped.resolved.firstWhere((p) => p.playerId == 'you').position;
}
