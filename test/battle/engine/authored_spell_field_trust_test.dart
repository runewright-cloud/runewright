// SPDX-License-Identifier: GPL-3.0-or-later
//
// authored_spell_field_trust_test.dart — characterization of the three
// peer-AUTHORED SpellAsset fields that survive `ActionWire.decodeAction`
// without a proof binding them: `t`, `name`, and `formula`.
//
// The decoder reconstructs a peer's SpellAsset from wire bytes. Five of its
// fields are written freely by the sender: `name`, `formula`, `t`, `isSummon`
// and `summonPersonality`. The last two are already characterized as M4.19
// (summon_declaration_trust_test.dart) and are not re-tested here. This file
// answers the other three:
//
//   t        — bound. `PeerCastVerifier.certifyPeerCast` compares the wire
//              value against the proof's certified T and forfeits on any
//              difference (`t_mismatch`). The sweep below drives the wire
//              value across the whole legal codec range against a fixed proof
//              and shows every variant is rejected before resolution.
//
//   name     — presentation-only. Identical casts differing ONLY in name
//              produce byte-identical canonical state.
//
//   formula  — superseded by the proof-derived element sequence on every
//              gameplay path, on BOTH devices.
//
//              Three fixes got it there. B-1 made the RECEIVING device resolve
//              a peer's cast from the verified outputs. M4.20 closed the
//              forced-cast path, where `TurnLoop.resolveForcedCast` called
//              `applySpell` with no certified arguments and a Spontaneous
//              Combustion reveal resolved the sender's authored formula.
//              M4.22 closed the last one: the CASTER's own immediate cast,
//              which is never in `certifiedPeerCasts` and so fell through to
//              `elementSequence(spell)` / `wireBaseManaCost(spell)` while the
//              peer resolved the certified trajectory. That was not merely a
//              trust hole — it was a live desync, because the two devices
//              resolved one cast from two different lists whenever an asset's
//              authored fields had drifted from its proof, which the shipped
//              Basic Windhound had (docs/M4_findings.md §M4.22).
//
// Sections 1 and 2 are characterization — they assert what the code does, so
// the boundary is pinned rather than assumed. Section 3 is a regression suite:
// it keeps ONE historical pin of the pre-fix shape (a pick with no certified
// semantics falls back to the wire, which is what M4.20 was) and then proves
// neither the ordinary nor the forced-cast path can produce one. Section 3's
// ordinary-cast tests are also M4.22's NON-SUMMON adversarial regression: a
// proof certifying one sequence against an authored formula deliberately
// claiming another, proving the repair is about the authority boundary and not
// about Windhound.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/forced_cast.dart'
    show ForcedCast, ForcedCastPick, ForcedCastRequest;
import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart' show BattleState;
import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;
import 'package:rune_duel/spells/spell_asset.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

String _hexOf(Uint8List b) =>
    '0x${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';

/// A spell whose PROOF attests [certifiedElements] while its WIRE fields say
/// whatever the test wants. Every field the trust boundary does not bind is a
/// parameter, so one fixture covers all three audits.
SpellAsset authoredFixture({
  required String id,
  int wireT = 3,
  int? proofT,
  int proofTier = 12,
  String name = 'Authored',
  List<String>? wireFormula,
  List<BorderZone>? certifiedElements,
  int commitmentByte = 0x60,
}) {
  final elements =
      certifiedElements ?? List.filled(kActivations, BorderZone.earth);
  final commitBytes = Uint8List.fromList(List.filled(32, commitmentByte));
  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 19),
    tier: proofTier,
    t: wireT,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: 0,
    segmentCount: kSegmentCount,
    dotCount: kDotCount,
    initialGrid: const [],
    proofBytes: syntheticProof(
      tier: proofTier,
      t: proofT ?? wireT,
      commitmentBytes: commitBytes,
      rulesetVersion: kRulesetVersion,
      elements: elements,
    ),
    name: name,
    commitmentHex: _hexOf(commitBytes),
    spellHashHex: '',
    formula: wireFormula ?? [for (final e in elements) e.name],
  );
}

void main() {
  // ── 1. `t`: authored, but bound to the proof ──────────────────────────────
  //
  // The proof is held byte-for-byte constant across the sweep (T=3, tier 12,
  // one commitment, one element sequence); only the wire `t` moves. Any
  // variant that reached resolution would be a trust defect.

  /// Runs one turn in which `player_a` casts [spell] and `player_b` — the
  /// device under test — rejects it, returning the forfeit tag `player_a`
  /// receives. Same shape as peer_cast_rejection_test.dart's harness: the
  /// caster is unawaited because the verifier aborts partway through the
  /// exchange sequence and no reply ever comes.
  Future<String> rejectionTagFor(SpellAsset spell) async {
    final pair = TurnSessionPair();
    final loopCaster = TurnLoop(
      state: makeDuelState(),
      session: pair.sessionA,
      localPlayerId: 'player_a',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    )..localChapterCommitments = [spell.commitmentHex];
    final loopPeer = TurnLoop(
      state: makeDuelState(),
      session: pair.sessionB,
      localPlayerId: 'player_b',
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
    );

    unawaited(loopCaster
        .runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        ))
        .catchError((Object _) => null));

    await expectLater(
      loopPeer.runTurn(TurnInput(action: PassAction())),
      throwsA(isA<StateError>()),
    );
    return pair.sessionA.peerForfeit.timeout(const Duration(seconds: 5));
  }

  group('authored SpellAsset.t is checked against the certified proof T', () {
    // The tightest form of the reproduction: encode ONE action from ONE spell,
    // then patch only the two `t` bytes in the resulting frame. Proof bytes,
    // commitment, formula, name, target and every flag byte are identical
    // across the whole sweep — the frame differs by exactly two bytes.
    //
    // `t` sits at offset 1 (type) + 32 (commitment) in the 0x01 layout; the
    // assertion below pins that so a codec reshuffle fails loudly here rather
    // than silently patching some other field.
    const tOffset = 33;

    final certified = authoredFixture(id: 't-wire', wireT: 3, proofT: 3);
    final baseFrame = ActionWire.encodeAction(
      SpellCastAction(spell: certified, targetHex: const HexCoord(1, 0)),
      isVocalComponents: false,
      // Non-null so the proof tail is emitted at all; a null membership proof
      // writes depth 0, the single-spell-chapter shape.
      membershipProofFor: (_, _) => null,
    );

    Uint8List frameWithT(int t) {
      final patched = Uint8List.fromList(baseFrame);
      patched[tOffset] = (t >> 8) & 0xFF;
      patched[tOffset + 1] = t & 0xFF;
      return patched;
    }

    /// Decodes [frame] and asks the verifier about it, exactly as
    /// `TurnLoop._verifyPeerSpellCast` does. Returns the decoded wire `t` and
    /// the verdict, so a test can assert on both the claim and its fate.
    Future<(int, PeerCastVerdict)> verdictFor(Uint8List frame) async {
      final (:action, :merkleProof) =
          ActionWire.decodeAction(frame, withProof: true);
      final decodedT = switch (action) {
        SpellCastAction(:final spell) => spell.t,
        _ => -1,
      };
      final verdict = await PeerCastVerifier(
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
        vkBytesForTier: null,
        peerBookRoot: null,
        peerOwnerPubkeyHex: null,
        peerPermissions: const [],
        allowProoflessSpells: false,
      ).certifyPeerCast(
        action,
        merkleProof,
        rulesetVersion: kRulesetVersion,
        leyline: LeylineConfig.ordinaryDefault,
        casterOwnerPubkeyHex: '0x${'22' * 32}',
        peerDrawSchedule: null,
      );
      return (decodedT, verdict);
    }

    test('the patched offset really is the `t` field', () {
      expect(baseFrame[0], equals(0x01));
      expect((baseFrame[tOffset] << 8) | baseFrame[tOffset + 1], equals(3));
    });

    // (label, wire t, expected forfeit tag). The proof always certifies T=3.
    const sweep = <(String, int, String)>[
      ('T - 1', 2, 't_mismatch'),
      ('T + 1', 4, 't_mismatch'),
      // Still inside tier 12, so VK selection and the parse layout both
      // succeed and the binding check is genuinely what rejects.
      ('a substantially different in-tier value', 11, 't_mismatch'),
      // Outside tier 12: the wire value selects a DIFFERENT tier, the proof is
      // read at the wrong offsets and fails to parse at all. Fail-closed — the
      // rejection arrives one check earlier, under a different tag.
      ('a value in a higher tier', 24, 'invalid_spell_proof'),
      // Below and above the circuit's 1..48 range. `t` is an unsigned 16-bit
      // field, so both are encodable; neither maps to a tier.
      ('the codec floor', 0, 'invalid_spell_tier'),
      ('one past the circuit ceiling', 49, 'invalid_spell_tier'),
      ('the codec ceiling', 0xFFFF, 'invalid_spell_tier'),
    ];

    for (final (label, wireT, expectedTag) in sweep) {
      test('$label (wire T=$wireT vs certified T=3) is rejected: $expectedTag',
          () async {
        final (decodedT, verdict) = await verdictFor(frameWithT(wireT));
        // The decoder does NOT sanitize: the lie survives to the verifier,
        // which is the layering the codec header describes.
        expect(decodedT, equals(wireT));
        expect(verdict, isA<PeerCastRejected>());
        expect((verdict as PeerCastRejected).forfeitReason, equals(expectedTag));
      });
    }

    test('the matching value certifies, and certifies T=3', () async {
      final (decodedT, verdict) = await verdictFor(frameWithT(3));
      expect(decodedT, equals(3));
      expect(verdict, isA<PeerCastCertified>());
      // Nothing downstream can observe a wire `t` at all: `CertifiedPeerCast`
      // deliberately does not carry one (see its doc comment).
      expect((verdict as PeerCastCertified).cast.commitmentHex,
          equals(certified.commitmentHex));
    });

    test('end to end, a mismatched T forfeits the match', () async {
      final tag = await rejectionTagFor(
        authoredFixture(id: 't-e2e', wireT: 2, proofT: 3, commitmentByte: 0x62),
      );
      expect(tag, equals('t_mismatch'));
    });

    test('end to end, the matching value resolves identically on both devices',
        () async {
      final stateCaster = makeDuelState();
      final statePeer = makeDuelState();
      final pair = TurnSessionPair();
      final spell = authoredFixture(id: 't-match', wireT: 3, proofT: 3);
      final loopCaster = TurnLoop(
        state: stateCaster,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      )..localChapterCommitments = [spell.commitmentHex];
      final loopPeer = TurnLoop(
        state: statePeer,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      await Future.wait([
        loopCaster.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        )),
        loopPeer.runTurn(TurnInput(action: PassAction())),
      ], eagerError: true).timeout(const Duration(seconds: 20));

      expect(
        bytesEqual(stateCaster.toCanonicalBytes(), statePeer.toCanonicalBytes()),
        isTrue,
      );
    });
  });

  // ── 2. `name`: presentation-only ──────────────────────────────────────────

  test('authored SpellAsset.name cannot reach canonical state', () async {
    /// One honest cast, parameterized only by the name the caster declares.
    /// Returns the RECEIVING device's canonical state — the side that read the
    /// name off the wire.
    Future<Uint8List> canonicalAfterCastNamed(String name) async {
      final statePeer = makeDuelState();
      final pair = TurnSessionPair();
      final spell = authoredFixture(id: 'named', name: name);
      final loopCaster = TurnLoop(
        state: makeDuelState(),
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      )..localChapterCommitments = [spell.commitmentHex];
      final loopPeer = TurnLoop(
        state: statePeer,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      await Future.wait([
        loopCaster.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        )),
        loopPeer.runTurn(TurnInput(action: PassAction())),
      ], eagerError: true).timeout(const Duration(seconds: 20));
      return statePeer.toCanonicalBytes();
    }

    // A long multi-byte name, to rule out a length- or encoding-sensitive read
    // as well as a value-sensitive one.
    final plain = await canonicalAfterCastNamed('A');
    final exotic = await canonicalAfterCastNamed('Ω' * 64);

    expect(bytesEqual(plain, exotic), isTrue,
        reason: 'the declared name reached consensus state');
  });

  // ── 3. `formula`: the trust-boundary control, and the M4.20 fix ───────────
  //
  // Certified trajectory: three EARTH activations → an Earth Barrier. Authored
  // wire formula: water/water/fire → Water Clouds, which appends to
  // `state.clouds` at the target tile no matter who is standing on it. So
  // `state.clouds` answers "which formula did this device resolve?" without
  // depending on where a random target landed — a dramatic canonical
  // difference (a persistent battlefield hazard that exists or does not),
  // not a presentation one.

  SpellAsset forgedCloudSpell() => authoredFixture(
        id: 'forged-cloud',
        wireFormula: const ['water', 'water', 'fire'],
        certifiedElements: List.filled(kActivations, BorderZone.earth),
        commitmentByte: 0x61,
      );

  /// The SAME spell — same grid, same commitment, byte-identical proof — told
  /// honestly. The only difference from [forgedCloudSpell] is the authored
  /// `formula` field, which is exactly the variable under test: identical
  /// proofs must imply identical gameplay.
  SpellAsset honestEarthTwin() => authoredFixture(
        id: 'honest-twin',
        wireFormula: const ['earth', 'earth', 'earth'],
        certifiedElements: List.filled(kActivations, BorderZone.earth),
        commitmentByte: 0x61,
      );

  TurnLoop loopFor(BattleState state, PairedSession session, String localId) =>
      TurnLoop(
        state: state,
        session: session,
        localPlayerId: localId,
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

  test(
    'M4.22: an ordinary NON-SUMMON cast whose authored formula contradicts its '
    'own proof stays in lockstep, and resolves the certified trajectory on '
    'BOTH devices',
    () async {
      // The general form of the M4.22 defect, with no summon anywhere in
      // sight. `forgedCloudSpell` proves an all-earth trajectory and authors
      // `water, water, fire` — a Water-Fire Clouds formula. Before the fix the
      // caster resolved the AUTHORED list and dropped a persistent cloud on the
      // battlefield while the receiver resolved the CERTIFIED earth trajectory
      // and dropped none, and the pair forfeited on the state hash. That is the
      // same authority split that made the shipped Basic Windhound desync; the
      // Windhound simply reached it through stale content rather than through a
      // deliberate forgery.
      //
      // A cloud is the right observable because `state.clouds` is canonical,
      // persistent, and independent of where a target landed: it answers "which
      // formula did THIS device resolve?" with a battlefield hazard that either
      // exists or does not.
      final stateCaster = makeDuelState();
      final statePeer = makeDuelState();
      final pair = TurnSessionPair();
      final spell = forgedCloudSpell();
      final loopCaster = loopFor(stateCaster, pair.sessionA, 'player_a')
        ..localChapterCommitments = [spell.commitmentHex];
      final loopPeer = loopFor(statePeer, pair.sessionB, 'player_b');

      final errors = <Object>[];
      await Future.wait([
        loopCaster
            .runTurn(TurnInput(
              action: SpellCastAction(
                  spell: spell, targetHex: const HexCoord(1, 0)),
            ))
            .catchError(collectError(errors)),
        loopPeer
            .runTurn(TurnInput(action: PassAction()))
            .catchError(collectError(errors)),
      ]).timeout(const Duration(seconds: 20));

      expect(errors, isEmpty,
          reason: 'no state-hash mismatch: the authored formula no longer '
              'steers the caster\'s own resolution');

      // Neither device creates the forged cloud — the proof says earth.
      expect(stateCaster.clouds, isEmpty,
          reason: 'the CASTER must resolve the certified earth trajectory too, '
              'not the water/fire formula it authored');
      expect(statePeer.clouds, isEmpty,
          reason: 'the receiver resolves the CERTIFIED earth trajectory');

      // The exact comparison `_exchangeStateHash` performs.
      expect(stateCaster.toCanonicalBytes(),
          equals(statePeer.toCanonicalBytes()),
          reason: 'full canonical state must agree across the pair');
    },
  );

  test(
    'M4.22: the same proof implies the same canonical state whatever the '
    'authored formula says (ordinary immediate cast)',
    () async {
      // The forgery and its honest twin share a grid, a commitment and
      // byte-identical proof bytes; only `SpellAsset.formula` differs. If the
      // authored field still reached resolution anywhere on the local path,
      // these two runs would diverge. This is the property M4.22 buys, stated
      // directly rather than through a symptom.
      Future<List<int>> canonicalAfterCasting(SpellAsset spell) async {
        final stateCaster = makeDuelState();
        final statePeer = makeDuelState();
        final pair = TurnSessionPair();
        final loopCaster = loopFor(stateCaster, pair.sessionA, 'player_a')
          ..localChapterCommitments = [spell.commitmentHex];
        final loopPeer = loopFor(statePeer, pair.sessionB, 'player_b');

        final errors = <Object>[];
        await Future.wait([
          loopCaster
              .runTurn(TurnInput(
                action: SpellCastAction(
                    spell: spell, targetHex: const HexCoord(1, 0)),
              ))
              .catchError(collectError(errors)),
          loopPeer
              .runTurn(TurnInput(action: PassAction()))
              .catchError(collectError(errors)),
        ]).timeout(const Duration(seconds: 20));
        expect(errors, isEmpty);
        expect(stateCaster.toCanonicalBytes(),
            equals(statePeer.toCanonicalBytes()));
        return stateCaster.toCanonicalBytes();
      }

      expect(
        await canonicalAfterCasting(forgedCloudSpell()),
        equals(await canonicalAfterCasting(honestEarthTwin())),
        reason: 'identical proofs must imply identical gameplay — the authored '
            'formula is presentation, not semantics',
      );
    },
  );

  // ── 3b. The forced-cast path (M4.20) ──────────────────────────────────────

  group('forced cast resolves certified semantics, not the authored formula',
      () {
    /// A device whose own player is [localId], with no turn run on it — every
    /// test below drives the ForcedCastHost seam directly, which is what
    /// `ForcedCast.run` step 3/4 does.
    (BattleState, TurnLoop) device(String localId) {
      final state = makeDuelState();
      final pair = TurnSessionPair();
      final session = localId == 'player_a' ? pair.sessionA : pair.sessionB;
      return (state, loopFor(state, session, localId));
    }

    /// One forced pick resolved on [loop] with a fixed RNG, so the random
    /// in-range target tile is the same in every scenario and canonical states
    /// are comparable byte-for-byte.
    Future<void> resolve(
      TurnLoop loop,
      SpellAsset spell,
      CertifiedCast? certified,
    ) =>
        loop.resolveForcedCast(
          ForcedCastPick(
            playerId: 'player_a',
            position: 0,
            spell: spell,
            certified: certified,
          ),
          HashRng(Uint8List(32)),
        );

    // ── The historical pin ────────────────────────────────────────────────
    //
    // Kept verbatim in behaviour, retitled in intent: this is the shape the
    // bug had. `applySpell` with no certified arguments falls back to
    // `parsedFormulas(spell)` — a documented, desync-safe fallback everywhere
    // it is reachable, and a trust hole on this path specifically, because
    // before the fix `resolveForcedCast` produced exactly this call for a
    // reveal whose certification had just been computed and discarded.
    test('HISTORICAL PIN: a pick carrying no certified semantics still falls '
        'back to the authored formula — the pre-fix shape of M4.20', () async {
      final (state, loop) = device('player_b');
      await resolve(loop, forgedCloudSpell(), null);
      expect(state.clouds, isNotEmpty,
          reason: 'the wire fallback is what M4.20 was: a cloud can only come '
              'from the AUTHORED water/water/fire formula, since the proof '
              'certifies three earth activations');
    });

    test('verifyForcedReveal returns the CertifiedCast it derives', () async {
      final (_, loop) = device('player_b');
      final certified =
          await loop.verifyForcedReveal('player_a', 0, forgedCloudSpell(), null);
      expect(certified, isNotNull,
          reason: 'the return type used to be void and the value was dropped');
      expect(certified!.elementSequence,
          equals(List.filled(kActivations, BorderZone.earth)),
          reason: 'the proof certifies earth/earth/earth');
      expect(
        certified.formulas.single.affinity,
        BorderZone.earth,
        reason: 'and the authored water/water/fire never appears in it',
      );
    });

    test('a PEER forced pick resolves the certified earth trajectory — the '
        'forged water/fire cloud can no longer be created', () async {
      final (state, loop) = device('player_b');
      final spell = forgedCloudSpell();
      final certified =
          await loop.verifyForcedReveal('player_a', 0, spell, null);
      await resolve(loop, spell, certified);
      expect(state.clouds, isEmpty,
          reason: 'the exploit is dead: no cloud can come from a proof that '
              'certifies three earth activations');
    });

    test('a LOCAL forced pick resolves the same certified trajectory', () async {
      final (state, loop) = device('player_a');
      final spell = forgedCloudSpell();
      // The route ForcedCast.run takes for our own picks: nobody sends
      // themselves a reveal, so the semantics come off our own proof bytes.
      final certified =
          loop.certifiedFromProofBytes(spell, casterPlayerId: 'player_a');
      expect(certified, isNotNull);
      await resolve(loop, spell, certified);
      expect(state.clouds, isEmpty);
    });

    test('local and peer forced picks produce byte-identical canonical state',
        () async {
      final (localState, localLoop) = device('player_a');
      final (peerState, peerLoop) = device('player_b');
      final spell = forgedCloudSpell();

      await resolve(
        localLoop,
        spell,
        localLoop.certifiedFromProofBytes(spell, casterPlayerId: 'player_a'),
      );
      await resolve(peerLoop, spell,
          await peerLoop.verifyForcedReveal('player_a', 0, spell, null));

      expect(
        bytesEqual(localState.toCanonicalBytes(), peerState.toCanonicalBytes()),
        isTrue,
        reason: 'the revealing device and the receiving device must resolve a '
            'forced cast identically, or the state hash forfeits the match',
      );
    });

    test('the same proof implies the same gameplay whatever the authored '
        'formula says', () async {
      /// Resolves [spell] the way the real path does and returns the canonical
      /// state. Both spells below carry the SAME proof bytes and the SAME
      /// commitment; only the authored `formula` differs.
      Future<Uint8List> canonicalAfter(SpellAsset spell) async {
        final (state, loop) = device('player_b');
        await resolve(
          loop,
          spell,
          await loop.verifyForcedReveal('player_a', 0, spell, null),
        );
        return state.toCanonicalBytes();
      }

      expect(
        bytesEqual(
          await canonicalAfter(forgedCloudSpell()),
          await canonicalAfter(honestEarthTwin()),
        ),
        isTrue,
        reason: 'a contradictory authored formula is superseded, so it can no '
            'longer change a single byte of consensus state',
      );
    });

    test('an HONEST forced cast is unchanged by the fix', () async {
      /// The honest spell resolved with and without certified semantics. An
      /// honest client writes `formula` from the same FormulaTracker output
      /// the proof certifies, so the two paths must agree exactly — this is
      /// the regression that says the fix costs honest play nothing.
      final (beforeState, beforeLoop) = device('player_b');
      await resolve(beforeLoop, honestEarthTwin(), null);

      final (afterState, afterLoop) = device('player_b');
      final spell = honestEarthTwin();
      await resolve(afterLoop, spell,
          await afterLoop.verifyForcedReveal('player_a', 0, spell, null));

      expect(
        bytesEqual(
          beforeState.toCanonicalBytes(),
          afterState.toCanonicalBytes(),
        ),
        isTrue,
        reason: 'certified and authored agree for an honest spell, so the '
            'resolved state must be identical to the pre-fix one',
      );
    });

    test('a forced cast is still FREE (A8) — no mana moves', () async {
      final (state, loop) = device('player_b');
      final before = [for (final a in state.avatars) a.mana];
      final spell = forgedCloudSpell();
      await resolve(
        loop,
        spell,
        await loop.verifyForcedReveal('player_a', 0, spell, null),
      );
      expect([for (final a in state.avatars) a.mana], equals(before),
          reason: 'A8 exempts a forced cast from mana entirely, on both the '
              'verification side and the resolution side');
    });

    test('proof verification is still mandatory — a bad proof forfeits',
        () async {
      final state = makeDuelState();
      final pair = TurnSessionPair();
      final loop = TurnLoop(
        state: state,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: (_, _) async => false,
        vkBytes: Uint8List(0),
      );
      await expectLater(
        loop.verifyForcedReveal('player_a', 0, forgedCloudSpell(), null),
        throwsA(isA<StateError>()),
      );
      expect(
        await pair.sessionA.peerForfeit.timeout(const Duration(seconds: 5)),
        equals('invalid_spell_proof'),
      );
    });

    test('a reveal with no proof bytes at all is refused', () async {
      final (_, loop) = device('player_b');
      final proofless = SpellAsset(
        id: 'proofless',
        createdAt: DateTime.utc(2026, 8, 19),
        tier: 12,
        t: 3,
        ownerPubkeyHex: '0x${'00' * 32}',
        manaCost: 0,
        segmentCount: kSegmentCount,
        dotCount: kDotCount,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: 'Proofless',
        commitmentHex: '0x${'63' * 32}',
        spellHashHex: '',
        formula: const ['water', 'water', 'fire'],
      );
      await expectLater(
        loop.verifyForcedReveal('player_a', 0, proofless, null),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── 3c. The whole sequence, over a simulated pair of devices ──────────────

  group('end to end, over a simulated pair of devices', () {
    /// Runs the whole sequence — public slot selection, reveal, verify,
    /// resolve — on two real TurnLoops talking to each other, with
    /// [revealedSpell] as player_a's only chapter entry (so it is the slot
    /// that gets picked). Returns both devices' states.
    Future<(BattleState, BattleState)> runForcedCast(
      SpellAsset revealedSpell,
    ) async {
      final pair = TurnSessionPair();
      final stateA = makeDuelState();
      final stateB = makeDuelState();
      // player_b's own chapter: needed only so its hands deal; player_b is
      // never the affected player.
      final theirs = authoredFixture(id: 'theirs', commitmentByte: 0x64);

      TurnLoop deviceLoop(
        BattleState state,
        PairedSession session,
        String localId,
        SpellAsset chapterSpell,
      ) =>
          TurnLoop(
            state: state,
            session: session,
            localPlayerId: localId,
            verifyProof: alwaysOk,
            vkBytes: Uint8List(0),
            peerBookLeafCount: 1,
          )
            ..localChapterSpells = [chapterSpell]
            ..localChapterCommitments = [chapterSpell.commitmentHex];

      final loopA = deviceLoop(stateA, pair.sessionA, 'player_a', revealedSpell);
      final loopB = deviceLoop(stateB, pair.sessionB, 'player_b', theirs);

      // One quiet turn, purely to deal the opening hands on both devices so
      // the public slot selection has positions to choose from.
      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ], eagerError: true).timeout(const Duration(seconds: 20));
      expect(bytesEqual(stateA.toCanonicalBytes(), stateB.toCanonicalBytes()),
          isTrue,
          reason: 'the pair must start the forced cast already agreed');

      const request = ForcedCastRequest(
        affectedPlayerIds: {'player_a'},
        countPerPlayer: 1,
        reasonTag: 'spontaneousCombustion',
      );
      HashRng fixedRng(String _) => HashRng(Uint8List(32));
      await Future.wait([
        ForcedCast.run(request, loopA, fixedRng),
        ForcedCast.run(request, loopB, fixedRng),
      ], eagerError: true).timeout(const Duration(seconds: 20));

      return (stateA, stateB);
    }

    // The POSITIVE CONTROL, and the reason the forged case's assertion means
    // anything: an honest spell whose PROOF certifies water/water/fire really
    // does produce clouds through this exact sequence. Without this, "no
    // clouds" could equally mean "the forced cast never resolved at all".
    test('a certified water/water/fire reveal really does create the cloud',
        () async {
      final (stateA, stateB) = await runForcedCast(authoredFixture(
        id: 'honest-cloud',
        certifiedElements: const [
          BorderZone.water,
          BorderZone.water,
          BorderZone.fire,
        ],
        commitmentByte: 0x65,
      ));
      expect(stateA.clouds, isNotEmpty);
      expect(stateB.clouds, isNotEmpty);
      expect(bytesEqual(stateA.toCanonicalBytes(), stateB.toCanonicalBytes()),
          isTrue);
    });

    test('a forged reveal resolves the CERTIFIED trajectory on both devices',
        () async {
      final (stateA, stateB) = await runForcedCast(forgedCloudSpell());

      expect(stateA.clouds, isEmpty,
          reason: 'the REVEALING device must resolve its own certified proof, '
              'not the formula it authored — this is the half that was never '
              'caught by the state hash, because before the fix BOTH devices '
              'agreed on the lie');
      expect(stateB.clouds, isEmpty,
          reason: 'and the receiving device must too');
      expect(bytesEqual(stateA.toCanonicalBytes(), stateB.toCanonicalBytes()),
          isTrue,
          reason: 'both devices resolve the forced cast identically');
    });

    test('an honest reveal is byte-identical to the forged one, since only '
        'the authored formula differs', () async {
      final (forgedA, _) = await runForcedCast(forgedCloudSpell());
      final (honestA, _) = await runForcedCast(honestEarthTwin());
      expect(
        bytesEqual(forgedA.toCanonicalBytes(), honestA.toCanonicalBytes()),
        isTrue,
        reason: 'same proof, same gameplay — the authored formula is inert',
      );
    });
  });
}
