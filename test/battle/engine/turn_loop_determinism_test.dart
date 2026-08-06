// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_determinism_test.dart — Verifies B-5: resolution RNG is
// platform-independent and identical on both clients given the same inputs.
//
// Two independent TurnLoop instances run concurrently using a TurnSessionPair (turn_session_pair.dart)
// that coordinates commit-reveal exchanges via Completers — the same protocol
// structure as a real two-client duel, not the SoloBattleSession stub which
// hides divergence by echoing state hashes back.
//
// The key invariant: after each turn both clients must produce byte-identical
// canonical state. If any resolution RNG call diverges between clients (wrong
// seed, platform-specific PRNG, or non-deterministic consumption order), the
// state hash will mismatch and the test fails.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/illusion.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

void main() {
  // ── HashRng unit tests ────────────────────────────────────────────────────

  group('HashRng', () {
    test('identical seeds produce identical nextInt sequences', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x42);
      final r1 = HashRng(Uint8List.fromList(seed));
      final r2 = HashRng(Uint8List.fromList(seed));
      for (var i = 0; i < 200; i++) {
        expect(r1.nextInt(1000), equals(r2.nextInt(1000)),
            reason: 'diverged at index $i');
      }
    });

    test('different seeds produce different sequences', () {
      final s1 = Uint8List(32)..fillRange(0, 32, 0xAA);
      final s2 = Uint8List(32)..fillRange(0, 32, 0x55);
      final r1 = HashRng(s1);
      final r2 = HashRng(s2);
      final out1 = List.generate(20, (_) => r1.nextInt(1 << 30));
      final out2 = List.generate(20, (_) => r2.nextInt(1 << 30));
      expect(out1, isNot(equals(out2)));
    });

    test('nextInt has no modulo bias for small max', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x11);
      final rng = HashRng(seed);
      final counts = List.filled(3, 0);
      const n = 3000;
      for (var i = 0; i < n; i++) {
        counts[rng.nextInt(3)]++;
      }
      // Each bucket should be ~1000 ± 10%. Accept ±15% for CI flakiness margin.
      for (final c in counts) {
        expect(c, greaterThan(n ~/ 3 * 85 ~/ 100));
        expect(c, lessThan(n ~/ 3 * 115 ~/ 100));
      }
    });

    test('nextDouble is in [0, 1)', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x7F);
      final rng = HashRng(seed);
      for (var i = 0; i < 100; i++) {
        final v = rng.nextDouble();
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThan(1.0));
      }
    });

    test('List.shuffle produces identical result with same seed', () {
      final seed = Uint8List(32)..fillRange(0, 32, 0x33);
      final list1 = [1, 2, 3, 4, 5, 6, 7, 8];
      final list2 = List<int>.from(list1);
      list1.shuffle(HashRng(Uint8List.fromList(seed)));
      list2.shuffle(HashRng(Uint8List.fromList(seed)));
      expect(list1, equals(list2));
    });
  });

  // ── TurnLoop two-client determinism (B-5) ────────────────────────────────

  group('TurnLoop two-client determinism (B-5)', () {
    test(
        'two independent loops produce identical canonical state after each turn',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();

      final pair = TurnSessionPair();
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
      );

      final input = TurnInput(action: PassAction());

      // Both loops run concurrently. The paired sessions coordinate all
      // commit-reveal exchanges via Completers so the exchange structure
      // is identical to a real two-client duel.
      //
      // The key observable: if both loops derive identical joint entropy and
      // use HashRng(phaseSeed) for all resolution randomness, canonical state
      // must match. The TurnLoop's own _exchangeStateHash already asserts this
      // internally; we also assert it here explicitly so a failure shows as a
      // test failure rather than an unhandled StateError.
      await Future.wait([
        loop1.runTurn(input),
        loop2.runTurn(input),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Turn 1: canonical state diverged between the two loops. '
            'Check phase-seed construction and HashRng wiring.',
      );

      // Second turn — verifies the invariant holds across turns and that
      // state.turnNumber increments identically on both sides.
      pair.reset();
      await Future.wait([
        loop1.runTurn(input),
        loop2.runTurn(input),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Turn 2: canonical state diverged.',
      );
    });

    test(
        'Dash + Meditate + Melee stay in lockstep across two independent loops',
        () async {
      final state1 = _makeAdjacentState();
      final state2 = _makeAdjacentState();

      final pair = TurnSessionPair();
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (candidates) async => candidates.first,
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        meleeTargetPicker: (candidates) async => candidates.first,
      );

      // player_a dashes; player_b meditates. Both melee their adjacent foe
      // — exercising the new isDashing/meditateInMove move-payload bits and
      // the melee commit-reveal round together, on two independently-driven
      // clients, the same way a real duel would.
      await Future.wait([
        loop1.runTurn(TurnInput(action: DashAction())),
        loop2.runTurn(TurnInput(action: MeditateAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Dash/Meditate/Melee turn diverged between the two loops. '
            'Check the move-payload isDashing/meditateInMove bits and the '
            'melee commit-reveal wiring.',
      );

      // Sanity: the melee round actually fired on both sides.
      final a = state1.avatars.firstWhere((av) => av.playerId == 'player_a');
      final b = state1.avatars.firstWhere((av) => av.playerId == 'player_b');
      expect(a.hp, 23);
      expect(b.hp, 23);
      expect(b.mana, 75); // player_b: Meditate (main), starting 50 + 25.
    });

    // Regression: docs/ARTIFACT_SYSTEM_PLAN.md §6.1. The melee round used to
    // apply haymakers local-first — device A ran A-then-B while device B ran
    // B-then-A — and both draw from the SAME shared meleeRng. That only bites
    // when a melee actually consumes the stream, which today means
    // _redirectIfIllusion: both players must melee AND the victims must hold
    // illusions. Fixed by sorting the applications by playerId, the same
    // convention _findCounteringCharm uses.
    test(
        'two melees into illusions stay in lockstep regardless of local '
        'perspective', () async {
      final state1 = _makeAdjacentIllusionState();
      final state2 = _makeAdjacentIllusionState();

      final pair = TurnSessionPair();
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (candidates) async => candidates.first,
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        meleeTargetPicker: (candidates) async => candidates.first,
      );

      await Future.wait([
        loop1.runTurn(TurnInput(action: PassAction())),
        loop2.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Double-melee-into-illusions turn diverged. The melee round '
            'must apply haymakers in sorted-playerId order, not local-first — '
            'they share one meleeRng stream.',
      );
    });
  });

  // ── Spell-cast wire round trip (SIGHTINGS_PLAN.md §2 wire change) ────────

  group('SpellCastAction wire round trip', () {
    test(
        "receiving loop decodes the caster's spell name off the 0x01 wire "
        'action unchanged', () async {
      final state1 = _makeAdjacentState();
      final state2 = _makeAdjacentState();

      final pair = TurnSessionPair();
      // Both loops verify (rather than skip verification, as the other
      // tests in this file do) so the receiving loop actually decodes and
      // certifies the peer's proof outputs instead of short-circuiting at
      // TurnLoop._verifyPeerSpellCast's "verify == null" bail-out — that
      // path would leave the caster's mana deducted on one side only and
      // diverge canonical state for reasons unrelated to the wire format
      // under test here.
      Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      // Empty formula + segmentCount/dotCount == 0 keeps this a "whiff"
      // cast on both the wire-trust side (spell.formula, read directly by
      // the caster's own loop) and the certified side (TrajectoryParser
      // output from the all-zero synthetic trajectory below, read by the
      // receiving loop) — zero effect, zero certified base cost, so the
      // two independently-computed mana/effect paths can't diverge for
      // reasons unrelated to the thing this test actually checks: does the
      // name survive the wire round trip.
      final commitmentBytes = Uint8List.fromList(List.filled(32, 0xab));
      final commitmentHex =
          '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final spell = SpellAsset(
        id: 'test-spell',
        createdAt: DateTime.utc(2026, 7, 19),
        tier: 24,
        t: 1,
        ownerPubkeyHex: '0x${'00' * 32}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: _syntheticProofFor(
          tier: 24,
          t: 1,
          commitmentBytes: commitmentBytes,
          segmentCount: 0,
          dotCount: 0,
        ),
        name: 'Ember Wake',
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: const [],
      );
      // _encodeAction only appends the [proof_len][proof_bytes]... tail
      // (which the receiving loop needs — verifyProof != null means it
      // decodes withProof: true and forfeits on an empty proof) when the
      // caster has a local chapter to prove membership against. A
      // single-spell "chapter" is enough (depth-0 membership proof).
      loop1.localChapterCommitments = [spell.commitmentHex];

      // player_a casts at the adjacent player_b; player_b passes. Both
      // loops independently decode/resolve BOTH actions to reach identical
      // canonical state, so loop2's lastResolvedSpells reflects what it
      // decoded off the wire from loop1's encoded action — the real
      // encode -> wire bytes -> decode round trip, not a direct call into
      // the private _encodeAction/_decodeAction methods.
      await Future.wait([
        loop1.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
        )),
        loop2.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Spell-cast turn diverged between the two loops.',
      );

      expect(loop2.lastResolvedSpells, hasLength(1));
      final resolved = loop2.lastResolvedSpells.single;
      expect(resolved.spell.name, equals('Ember Wake'),
          reason: 'name must survive the 0x01 wire encode/decode round trip');
      expect(resolved.spell.commitmentHex, equals(spell.commitmentHex));
      expect(resolved.spell.formula, equals(spell.formula));
      expect(resolved.casterId, equals('player_a'));
    });
  });

  // ── Watery Inertia rolls the same destination on both devices ────────────

  group('turbulent range lockstep', () {
    test('both loops roll the SAME landing hex for a turbulent cast', () async {
      // StatusEffectId.turbulent re-rolls a cast's distance at resolution
      // time, on both devices independently — a locally-seeded roll would put
      // the spell on two different tiles and desync at the very next state
      // hash. The design doc names "turbulent range" in its
      // jointly-generated-randomness list for exactly this reason (v4.0 §418).
      final state1 = _makeAdjacentState();
      final state2 = _makeAdjacentState();
      for (final s in [state1, state2]) {
        s.avatars
            .firstWhere((av) => av.playerId == 'player_a')
            .activeStatusEffects
            .add(StatusEffect(
              effectTypeId: StatusEffectId.turbulent,
              remainingTurns: 5,
            ));
      }

      final pair = TurnSessionPair();
      Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;
      final loop1 = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final loop2 = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      final commitmentBytes = Uint8List.fromList(List.filled(32, 0xcd));
      final commitmentHex =
          '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final spell = SpellAsset(
        id: 'turbulent-spell',
        createdAt: DateTime.utc(2026, 8, 6),
        tier: 24,
        t: 1,
        ownerPubkeyHex: '0x${'00' * 32}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: _syntheticProofFor(
          tier: 24,
          t: 1,
          commitmentBytes: commitmentBytes,
          segmentCount: 0,
          dotCount: 0,
        ),
        name: 'Squall',
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: const [],
      );
      loop1.localChapterCommitments = [spell.commitmentHex];

      await Future.wait([
        loop1.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: const HexCoord(3, 0)),
        )),
        loop2.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(
        state1.toCanonicalBytes(),
        equals(state2.toCanonicalBytes()),
        reason: 'Turbulent cast diverged between the two loops — check the '
            '0x0B phase seed and the _turbulentNonce reset.',
      );

      final castersLanding = loop1.lastResolvedSpells.single.targetHex;
      final peersLanding = loop2.lastResolvedSpells.single.targetHex;
      expect(peersLanding, equals(castersLanding),
          reason: 'the caster resolved on $castersLanding and the peer on '
              '$peersLanding — a turbulent roll must be derived from joint '
              'entropy, never a local Random');

      // Golden: fixedJointEntropy (0x5A×32) ‖ turn 1 ‖ 0x0B ‖ 'player_a' ‖
      // nonce 0 rolls a distance of 1, so a cast declared three tiles out
      // lands one tile out. Pinned because the seed's preimage is
      // consensus-visible — changing its shape silently would desync two
      // devices running different builds, and this is the cheapest place to
      // notice. Regenerate deliberately if the preimage ever changes.
      expect(castersLanding, equals(const HexCoord(1, 0)),
          reason: 'turbulent roll changed; if this was intentional, re-pin it');
      expect(castersLanding, isNot(const HexCoord(3, 0)),
          reason: 'the spell must not have simply landed where it was aimed — '
              'this test would pass vacuously if turbulent were unwired');
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Build synthetic proof bytes in the canonical wire format ProofIntake
/// parses: `[4 BE bytes: field count N][N × 32-byte fields][proof body]`
/// (mirrors test/battle/engine/proof_intake_test.dart's `_syntheticProof`,
/// extended to stamp the commitment/segmentCount/dotCount fields a real
/// `_verifyPeerSpellCast` call reads). All other fields (owner_pubkey,
/// border_activations, dominance_trajectory, supreme_dominance_flags) stay
/// zero, which TrajectoryParser reads as "no certified effect zones" —
/// paired with an empty wire `formula` on the caster's [SpellAsset] so both
/// the wire-trust and certified resolution paths agree on a no-op cast.
Uint8List _syntheticProofFor({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
  required int segmentCount,
  required int dotCount,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);

  data.setUint32(0, count, Endian.big);
  data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
  data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3: commitment
  data.setUint32(4 + (8 + 2 * tier) * 32 + 28, segmentCount, Endian.big);
  data.setUint32(4 + (8 + 2 * tier + 1) * 32 + 28, dotCount, Endian.big);
  return bytes;
}

/// Like [_makeState] but with adjacent avatars (so both have a melee target)
/// and headroom below maxMana (so a Meditate gain is observable rather than
/// clamped away).
BattleState _makeAdjacentState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        maxMana: 100,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        maxMana: 100,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}

/// [_makeAdjacentState] plus a decoy set for each wizard, so a melee punch
/// actually draws from the shared melee RNG (via
/// TurnLoop._redirectIfIllusion) instead of early-returning without touching
/// it. Three decoys each: enough draws that a swapped application order
/// resolves the two redirects differently.
BattleState _makeAdjacentIllusionState() {
  final state = _makeAdjacentState();
  state.wizardIllusions.addAll([
    WizardIllusionSet(
      ownerId: 'player_a',
      decoyPositions: [
        const HexCoord(0, 1),
        const HexCoord(-1, 1),
        const HexCoord(-1, 0),
      ],
    ),
    WizardIllusionSet(
      ownerId: 'player_b',
      decoyPositions: [
        const HexCoord(2, 0),
        const HexCoord(2, -1),
        const HexCoord(1, 1),
      ],
    ),
  ]);
  return state;
}

BattleState _makeState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(2, -2);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
