// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_draw_wiring_test.dart — SPELL_DRAW_WIRING_PLAN.md §10 items 2-6:
// the live hand/deck wiring, on top of SpellDraw/DrawSchedule's own
// (already-tested) mechanics. Item 1 (canonical-order reconciliation) is
// covered by draw_schedule_test.dart's SpellDraw/DrawSchedule cross-check;
// item 7 (Divination reveal) by spell_reveal_test.dart; item 8 (sortedness
// circuit) is deferred — the circuit hasn't landed yet (§11).
//
// Uses the same synthetic-proof + stub-verifier pattern as
// turn_loop_cast_authorization_test.dart (`alwaysOk`): these tests are
// about the DRAW-STATE wiring, not cryptographic proof soundness (which
// turn_loop_proof_verification_test.dart separately covers with a real
// FFI proof) — a stub verifier is what lets `_verifyPeerSpellCast` run at
// all (it early-returns when verifyProof/vkBytes are null), which is what
// exercises the in-hand check (§6) and lets the verifier build its own
// mirror of the caster's DrawSchedule.

import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/transport.dart';
import 'package:rune_duel/spells/spell_asset.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Hand size == bookmarkCount + 1 (see WizardAvatar.bookmarkCount); every
  // test in this file was written against a hand size of 3, so each fixture
  // avatar carries 2 bookmarks.
  List<Accoutrement> twoBookmarks(String idPrefix) => [
        Accoutrement(id: '${idPrefix}_bm0', kind: AccoutrementKind.bookmark),
        Accoutrement(id: '${idPrefix}_bm1', kind: AccoutrementKind.bookmark),
      ];

  BattleState makeAdjacentState() {
    final battlefield = Battlefield();
    const posCaster = HexCoord(0, 0);
    const posVerifier = HexCoord(1, 0);
    battlefield.occupancy['caster'] = posCaster;
    battlefield.occupancy['verifier'] = posVerifier;
    return BattleState(
      config: const MatchConfig(),
      avatars: [
        WizardAvatar(
          playerId: 'caster',
          ownerPubkeyHex: '0x${'0' * 64}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posCaster,
          teamId: 'team_caster',
          baseSpellRange: 3,
          accoutrements: twoBookmarks('caster'),
        ),
        WizardAvatar(
          playerId: 'verifier',
          ownerPubkeyHex: '0x${'0' * 64}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posVerifier,
          teamId: 'team_verifier',
          baseSpellRange: 3,
          accoutrements: twoBookmarks('verifier'),
        ),
      ],
      teams: [
        const Team(id: 'team_caster', playerIds: ['caster']),
        const Team(id: 'team_verifier', playerIds: ['verifier']),
      ],
      battlefield: battlefield,
    );
  }

  /// A synthetic proof declaring [commitmentBytes] as the commitment public
  /// input — mirrors turn_loop_cast_authorization_test.dart's helper of the
  /// same shape. Owner is left all-zero (irrelevant here: these tests never
  /// set peerOwnerPubkeyHex, so 3b authorization is skipped).
  ///
  /// [trajectory] optionally encodes `dominanceTrajectory` (proof_intake.dart
  /// field indices 8..8+tierMax-1) — the per-generation dominant-zone index
  /// (`ca_run.dart`'s `ruleIndex`: 0=neutral, 1=fire, 2=air, 3=water,
  /// 4=earth) TrajectoryParser drives FormulaTracker with to derive the
  /// PEER's certified formula. A "whiff" proof (empty trajectory, the
  /// default) certifies to zero formulas — fine for tests that only need a
  /// valid proof shape (item 4's in-hand checks only read commitmentHex/T,
  /// never the trajectory) but NOT for tests that need the verifier's own
  /// mirrored resolution to actually apply an effect (FuelTransmutation
  /// wither/reactivate, items 5-6) — those must set a real trajectory so
  /// both the caster's local (untrusted-wire-formula) resolution and the
  /// verifier's SNARK-certified resolution agree.
  Uint8List syntheticProofFor({
    required int tier,
    required int t,
    required Uint8List commitmentBytes,
    List<int> trajectory = const [],
  }) {
    final count = 10 + 2 * tier;
    final bytes = Uint8List(4 + count * 32 + 1);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, count, Endian.big);
    data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
    data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
    bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3: commitment
    for (var gen = 0; gen < trajectory.length; gen++) {
      final fieldIdx = 8 + gen; // dominanceTrajectory[gen]
      bytes[4 + fieldIdx * 32 + 31] = trajectory[gen];
    }
    return bytes;
  }

  int fillCounter = 0;

  /// Builds a fixture [SpellAsset] with a distinct commitmentHex, a valid
  /// synthetic proof, and [formula] (BorderZone name triplets — e.g.
  /// `['fire', 'earth', 'fire']` for a Fire-affinity FuelTransmutation, per
  /// effect_kind.dart's effectKindFromPair(earth, fire) mapping). An empty
  /// formula is the "wild-magic stub" no-op cast (effect_applicator.dart).
  /// [t]/[trajectory] let the SNARK-side certified formula match [formula]
  /// too — see [syntheticProofFor]'s doc comment for when that matters.
  SpellAsset fixtureSpell(
    String name, {
    List<String> formula = const [],
    int t = 1,
    List<int> trajectory = const [],
  }) {
    fillCounter++;
    final commitmentBytes = Uint8List.fromList(List.filled(32, fillCounter));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return SpellAsset(
      id: 'fixture-$name-$fillCounter',
      createdAt: DateTime.utc(2026, 7, 23),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProofFor(
        tier: 12,
        t: t,
        commitmentBytes: commitmentBytes,
        trajectory: trajectory,
      ),
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: '',
      formula: formula,
    );
  }

  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  /// Builds a connected caster/verifier TurnLoop pair. [casterChapter] is
  /// the caster's real chapter (sorted by commitmentHex — canonical order,
  /// §2 consequence 3); [verifierChapter] is a throwaway chapter so the
  /// verifier's own [_dealOpeningHandsIfNeeded] proceeds past its
  /// chapter-load gate and deals its mirror of the caster's DrawSchedule
  /// (a real client always has its own chapter — this only matters for the
  /// artificial "verifier never casts" shape of these tests).
  ({
    TurnLoop caster,
    TurnLoop verifier,
    Transport transportCaster,
    Transport transportVerifier,
    List<String> casterCommitments,
  })
  buildLoopPair({
    required List<SpellAsset> casterChapter,
    required List<SpellAsset> verifierChapter,
  }) {
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportCaster, transportVerifier) = InMemoryTransport.pair();
    final sessionCaster = BattleSession(transportCaster, matchId);
    final sessionVerifier = BattleSession(transportVerifier, matchId);

    final sortedCasterChapter = List<SpellAsset>.from(casterChapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    final casterCommitments = sortedCasterChapter.map((s) => s.commitmentHex).toList();
    final casterRoot = BookCommitment.computeRoot(casterCommitments);

    final sortedVerifierChapter = List<SpellAsset>.from(verifierChapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    final verifierCommitments = sortedVerifierChapter.map((s) => s.commitmentHex).toList();

    final loopCaster = TurnLoop(
      state: makeAdjacentState(),
      session: sessionCaster,
      localPlayerId: 'caster',
      matchId: matchId,
      tier: 12,
    )
      ..localChapterCommitments = casterCommitments
      ..localChapterSpells = sortedCasterChapter;
    final loopVerifier = TurnLoop(
      state: makeAdjacentState(),
      session: sessionVerifier,
      localPlayerId: 'verifier',
      matchId: matchId,
      tier: 12,
      verifyProof: alwaysOk,
      vkBytes: Uint8List(0),
      peerBookRoot: casterRoot,
      peerBookLeafCount: casterCommitments.length,
    )
      ..localChapterCommitments = verifierCommitments
      ..localChapterSpells = sortedVerifierChapter;

    return (
      caster: loopCaster,
      verifier: loopVerifier,
      transportCaster: transportCaster,
      transportVerifier: transportVerifier,
      casterCommitments: casterCommitments,
    );
  }

  /// Runs one turn: [casterAction] for the caster, Pass for the verifier.
  /// Both sides expected to complete normally.
  Future<void> runTurnExpectingSuccess(
    ({TurnLoop caster, TurnLoop verifier}) pair,
    TurnAction casterAction,
  ) async {
    await Future.wait([
      pair.caster.runTurn(TurnInput(action: casterAction)),
      pair.verifier.runTurn(TurnInput(action: PassAction())),
    ]);
  }

  group('Opening deal + refill through a real turn (item 2)', () {
    test('startBattle deals the opening hand before turn 1 — turn 1 is castable', () async {
      // Regression for the turn-1-no-cast gap: the opening hand must exist
      // before any runTurn, dealt from the battle-start exchangeNonce, so the
      // player can cast on turn 1 like any other turn.
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      // No hand yet — before startBattle.
      expect(pair.caster.localSpellDraw, isNull);

      // Both sides run the battle-start exchange concurrently (it's a paired
      // commit-reveal, same as a turn's).
      await Future.wait([pair.caster.startBattle(), pair.verifier.startBattle()]);

      // Hand is dealt and full — WITHOUT any runTurn having happened.
      expect(pair.caster.localSpellDraw, isNotNull);
      expect(pair.caster.localSpellDraw!.hand, hasLength(3));
      expect(pair.caster.localSpellDraw!.remaining, hasLength(2));

      // A second call is a no-op (idempotent).
      await pair.caster.startBattle();
      expect(pair.caster.localSpellDraw!.hand, hasLength(3));
    });

    test('hand refills from the deck on cast; deck shrinks; hand size holds '
        'until the deck empties', () async {
      // 5 spells, fixture hand size 3 (2 bookmarks + 1) — 3 in hand, 2 in
      // the deck after the opening deal. All inert (empty formula) — this
      // test is about draw-state bookkeeping, not effect resolution.
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      expect(pair.caster.localSpellDraw!.hand, hasLength(3));
      expect(pair.caster.localSpellDraw!.remaining, hasLength(2));

      // Cast twice more (from the hand, whatever landed there) — deck
      // shrinks by 1 each time, hand stays at 3 (still has cards to refill
      // from).
      for (var i = 0; i < 2; i++) {
        final toCast = pair.caster.localSpellDraw!.hand.first;
        await runTurnExpectingSuccess(
          (caster: pair.caster, verifier: pair.verifier),
          SpellCastAction(spell: toCast, targetHex: const HexCoord(1, 0)),
        );
        expect(pair.caster.localSpellDraw!.hand, hasLength(3),
            reason: 'deck still had cards to refill from');
        expect(pair.caster.localSpellDraw!.remaining, hasLength(2 - 1 - i));
      }
      expect(pair.caster.localSpellDraw!.remaining, isEmpty);

      // One more cast: deck is now empty, so the hand shrinks instead of
      // refilling.
      final lastCast = pair.caster.localSpellDraw!.hand.first;
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: lastCast, targetHex: const HexCoord(1, 0)),
      );
      expect(pair.caster.localSpellDraw!.hand, hasLength(2),
          reason: 'deck was empty — hand shrinks instead of refilling');
      expect(pair.caster.localSpellDraw!.remaining, isEmpty);

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });
  });

  group('Lockstep unaffected (item 3)', () {
    test('a turn with a cast produces identical canonical state on both '
        'sides — hand contents never enter the state hash', () async {
      final chapter = List.generate(4, (i) => fixtureSpell('inert$i'));
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      final toCast = pair.caster.localSpellDraw!.hand.first;
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: toCast, targetHex: const HexCoord(1, 0)),
      );

      expect(
        pair.caster.state.toCanonicalBytes(),
        equals(pair.verifier.state.toCanonicalBytes()),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });
  });

  group('In-hand enforcement (item 4, §6)', () {
    test('a cast from the deck (not the hand) is rejected: cast_out_of_hand',
        () async {
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      final deckSpell = pair.caster.localSpellDraw!.remaining.first;
      expect(pair.caster.localSpellDraw!.hand.map((s) => s.commitmentHex),
          isNot(contains(deckSpell.commitmentHex)));

      // Deliberately bypass hand selection — simulates a malicious/buggy
      // client casting a spell it never drew.
      unawaited(pair.caster.runTurn(TurnInput(
        action: SpellCastAction(spell: deckSpell, targetHex: const HexCoord(1, 0)),
      )).catchError((Object _) => null));

      await expectLater(
        pair.verifier.runTurn(TurnInput(action: PassAction())),
        throwsA(isA<StateError>().having(
          (e) => e.toString(),
          'message',
          contains('not in their castable hand'),
        )),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });

    test('a cast from the hand is accepted', () async {
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      final handSpell = pair.caster.localSpellDraw!.hand.first;
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: handSpell, targetHex: const HexCoord(1, 0)),
      );

      expect(pair.verifier.lastResolvedSpells, hasLength(1));
      expect(
        pair.verifier.lastResolvedSpells.single.spell.commitmentHex,
        equals(handSpell.commitmentHex),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });
  });

  group('FuelTransmutation wither/reactivate (items 5-6, §9)', () {
    // Trajectories (domIdx: 0=neutral 1=fire 2=air 3=water 4=earth) chosen so
    // the SNARK-certified formula (FormulaTracker, via TrajectoryParser)
    // matches the wire `formula` used for the caster's own local resolution
    // — both clients must agree which effect this is, or their BattleStates
    // diverge (state-hash mismatch). [1,4,1] is 3 lead changes in a row
    // (Fire→Earth→Fire), each one committing. [earth,earth,fire] needs a
    // neutral generation between the two Earth activations (4,0,4,1) —
    // FormulaTracker only re-commits the SAME zone on a lead change (i.e.
    // after an interruption), a pulse step, or supreme dominance; two Earth
    // generations in a row with neither would only commit once.
    SpellAsset fireWitherSpell(String name) => fixtureSpell(
      name,
      formula: const ['fire', 'earth', 'fire'],
      t: 3,
      trajectory: const [1, 4, 1],
    );
    SpellAsset earthReactivateSpell(String name) => fixtureSpell(
      name,
      formula: const ['earth', 'earth', 'fire'],
      t: 4,
      trajectory: const [4, 0, 4, 1],
    );

    test('casting Fire withers a hand position, agreed on both clients; '
        'Earth reactivates it, restoring castability', () async {
      // earthA/earthB are two identical Earth-reactivate spells so
      // whichever one the wither effect doesn't pick stays available to
      // cast the reactivate — the wither *target* among {earthA, earthB} is
      // legitimately RNG-chosen (witherRng), so the test discovers which
      // one it was rather than assuming. This flow never gets a cast
      // rejected (see the separate "refusal" test below for that, using a
      // fresh pair) — a rejected/aborted turn leaves the session unusable
      // for further exchanges, so a pair that needs more turns afterward
      // must never hit that path.
      final fireSpell = fireWitherSpell('fire-wither');
      final earthA = earthReactivateSpell('earth-a');
      final earthB = earthReactivateSpell('earth-b');
      final chapter = [fireSpell, earthA, earthB]; // == fixture hand size: all 3 always in hand
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      expect(
        pair.caster.localSpellDraw!.hand.map((s) => s.commitmentHex).toSet(),
        {fireSpell.commitmentHex, earthA.commitmentHex, earthB.commitmentHex},
      );

      // Cast fireSpell: deck is empty (3 spells, hand size 3), so the
      // hand shrinks to {earthA, earthB} and wither(1) picks one of them.
      // Self-targeted: FuelTransmutation lands on whoever occupies the
      // target tile (2026-07-27), not automatically the caster.
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: fireSpell, targetHex: const HexCoord(0, 0)),
      );

      final aWithered = pair.caster.isHandSpellWithered(earthA);
      final bWithered = pair.caster.isHandSpellWithered(earthB);
      expect(aWithered ^ bWithered, isTrue,
          reason: 'exactly one of earthA/earthB should be withered');
      final withered = aWithered ? earthA : earthB;
      final safe = aWithered ? earthB : earthA;

      // Cross-client agreement (item 5): the verifier's own mirror of the
      // caster's DrawSchedule agrees on exactly which position is withered.
      final witheredProof = BookCommitment.proveMembership(
        pair.casterCommitments,
        withered.commitmentHex,
      )!;
      final safeProof = BookCommitment.proveMembership(
        pair.casterCommitments,
        safe.commitmentHex,
      )!;
      expect(pair.verifier.isPositionWithered('caster', witheredProof.leafIndex), isTrue);
      expect(pair.verifier.isPositionWithered('caster', safeProof.leafIndex), isFalse);

      // Lockstep unaffected by the dedicated wither RNG stream.
      expect(
        pair.caster.state.toCanonicalBytes(),
        equals(pair.verifier.state.toCanonicalBytes()),
      );

      // Reactivate: cast the safe Earth spell. Deck is empty, so this
      // shrinks the hand to just the (now-reactivating) withered position.
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: safe, targetHex: const HexCoord(0, 0)),
      );
      expect(pair.caster.isHandSpellWithered(withered), isFalse,
          reason: 'reactivate should have cleared the withered flag');
      expect(pair.verifier.isPositionWithered('caster', witheredProof.leafIndex), isFalse,
          reason: 'both clients should agree the position is reactivated');

      // Castable again: the verifier now accepts a cast of the
      // previously-withered position.
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: withered, targetHex: const HexCoord(0, 0)),
      );
      expect(pair.verifier.lastResolvedSpells, hasLength(1));
      expect(
        pair.verifier.lastResolvedSpells.single.spell.commitmentHex,
        equals(withered.commitmentHex),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });

    test('a cast of a withered position is rejected (item 6)', () async {
      // Only 2 spells (fixture hand size is 3, so use a 2-card chapter to
      // undersize it): after casting fireSpell, exactly one card (filler)
      // remains in hand, so wither(1)'s pool has a single candidate — fully
      // deterministic, unlike the 3-card scenario above.
      final fireSpell = fireWitherSpell('fire-wither');
      final filler = fixtureSpell('filler');
      final chapter = [fireSpell, filler];
      final pair = buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      // Self-targeted: FuelTransmutation lands on whoever occupies the
      // target tile (2026-07-27), not automatically the caster.
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: fireSpell, targetHex: const HexCoord(0, 0)),
      );
      expect(pair.caster.isHandSpellWithered(filler), isTrue);

      unawaited(pair.caster.runTurn(TurnInput(
        action: SpellCastAction(spell: filler, targetHex: const HexCoord(1, 0)),
      )).catchError((Object _) => null));
      await expectLater(
        pair.verifier.runTurn(TurnInput(action: PassAction())),
        throwsA(isA<StateError>().having(
          (e) => e.toString(),
          'message',
          contains('not in their castable hand'),
        )),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });
  });

  group('Graveyard accessors — usedChapterPositions/spellAt', () {
    // These back the new graveyard UI (battle_screen.dart's
    // _GraveyardDialog): usedChapterPositions is a DERIVED set (the
    // complement of hand ∪ remaining, no new synced state), spellAt covers
    // content lookup, and drawScheduleFor(...).withered is the exact live
    // set the dialog polls so a reactivation vanishes from an open dialog.

    test('a resolved cast appears in usedChapterPositions for both clients, '
        'and leaves both hand and remaining on both', () async {
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair =
          buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      final handSpell = pair.caster.localSpellDraw!.hand.first;
      final position = BookCommitment.proveMembership(
        pair.casterCommitments,
        handSpell.commitmentHex,
      )!.leafIndex;

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: handSpell, targetHex: const HexCoord(1, 0)),
      );

      expect(pair.caster.usedChapterPositions('caster'), contains(position));
      expect(pair.verifier.usedChapterPositions('caster'), contains(position));
      expect(pair.caster.drawScheduleFor('caster')!.hand, isNot(contains(position)));
      expect(pair.caster.drawScheduleFor('caster')!.remaining, isNot(contains(position)));

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });

    test('opponent content is unknown until their first cast reveals it', () async {
      final chapter = List.generate(5, (i) => fixtureSpell('inert$i'));
      final pair =
          buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      final handSpell = pair.caster.localSpellDraw!.hand.first;
      final position = BookCommitment.proveMembership(
        pair.casterCommitments,
        handSpell.commitmentHex,
      )!.leafIndex;

      expect(pair.verifier.spellAt('caster', position), isNull);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: handSpell, targetHex: const HexCoord(1, 0)),
      );

      final revealed = pair.verifier.spellAt('caster', position);
      expect(revealed, isNotNull);
      expect(revealed!.commitmentHex, equals(handSpell.commitmentHex));
      expect(revealed.name, equals(handSpell.name));
      expect(revealed.formula, equals(handSpell.formula));
      // The ZK model never transmits grid/segment data — only a Merkle
      // proof of which position was cast (_decodeAction's reconstruction).
      expect(revealed.initialGrid, isEmpty);

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });

    test('withered/reactivated position set — the exact live view the '
        'graveyard UI polls — updates on both clients and clears on '
        'reactivate', () async {
      SpellAsset fireWitherSpell(String name) => fixtureSpell(
        name,
        formula: const ['fire', 'earth', 'fire'],
        t: 3,
        trajectory: const [1, 4, 1],
      );
      SpellAsset earthReactivateSpell(String name) => fixtureSpell(
        name,
        formula: const ['earth', 'earth', 'fire'],
        t: 4,
        trajectory: const [4, 0, 4, 1],
      );

      final fireSpell = fireWitherSpell('fire-wither-gy');
      final earthA = earthReactivateSpell('earth-a-gy');
      final earthB = earthReactivateSpell('earth-b-gy');
      final chapter = [fireSpell, earthA, earthB];
      final pair =
          buildLoopPair(casterChapter: chapter, verifierChapter: [fixtureSpell('v')]);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        PassAction(),
      );
      expect(pair.caster.drawScheduleFor('caster')!.withered, isEmpty);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: fireSpell, targetHex: const HexCoord(0, 0)),
      );
      final aWithered = pair.caster.isHandSpellWithered(earthA);
      final withered = aWithered ? earthA : earthB;
      final safe = aWithered ? earthB : earthA;
      final witheredPosition = BookCommitment.proveMembership(
        pair.casterCommitments,
        withered.commitmentHex,
      )!.leafIndex;

      expect(pair.caster.drawScheduleFor('caster')!.withered, {witheredPosition});
      expect(pair.verifier.drawScheduleFor('caster')!.withered, {witheredPosition});
      // A currently-withered opponent position was, by construction, never
      // cast, so its content is permanently unknown to the other client —
      // the graveyard UI renders this as a face-down placeholder.
      expect(pair.verifier.spellAt('caster', witheredPosition), isNull);

      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(spell: safe, targetHex: const HexCoord(0, 0)),
      );
      expect(pair.caster.drawScheduleFor('caster')!.withered, isEmpty,
          reason: 'reactivate must clear the set the graveyard UI polls live');
      expect(pair.verifier.drawScheduleFor('caster')!.withered, isEmpty);

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    });
  });
}
