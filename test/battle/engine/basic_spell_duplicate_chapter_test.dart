// SPDX-License-Identifier: GPL-3.0-or-later
//
// basic_spell_duplicate_chapter_test.dart — docs/BASIC_SPELLS_PLAN.md §7:
// a chapter may hold several copies of the same Basic spell's grid
// (identical commitmentHex). This exercises the exact bug that made
// unlimited copies unsafe before the fix: BookCommitment.proveMembership
// resolves a leafHex by STRING SEARCH, which always returns the FIRST
// matching sorted position — so with N copies of one commitment, every cast
// (regardless of which physical copy/hand slot was tapped) would resolve to
// the SAME chapter position. TurnLoop._advanceDrawState then calls
// DrawSchedule.useSlotAtPosition on that position a second time once it's
// already been removed from hand, which trips
// `assert(hand.contains(position))` — i.e. this bug doesn't silently
// misbehave, it crashes the second cast of a duplicate.
//
// The fix (TurnLoop._localCastPosition + BookCommitment.proveMembershipAt)
// resolves a LOCAL cast's chapter position from the caster's own known hand
// SLOT (SpellCastAction.handIndex) rather than searching by commitment —
// DrawSchedule.hand and SpellDraw.hand are index-parallel by construction
// (see spell_draw.dart / draw_schedule.dart headers), so slot i always names
// a distinct real chapter position even when its commitment is duplicated.
//
// Uses the same synthetic-proof + in-memory-transport harness as
// spell_draw_wiring_test.dart (see that file's header for why a stub
// verifier is what lets _verifyPeerSpellCast run at all in a unit test).

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
import 'package:rune_duel/spells/basic_spells.dart' show kBasicSpells;
import 'package:rune_duel/spells/spell_asset.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Hand size == bookmarkCount + 1 (see WizardAvatar.bookmarkCount); this
  // file's tests were written against a hand size of 3, so each fixture
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
  /// input — mirrors spell_draw_wiring_test.dart's helper of the same shape.
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

  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  ({
    TurnLoop caster,
    TurnLoop verifier,
    Transport transportCaster,
    Transport transportVerifier,
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
    );
  }

  Future<void> runTurnExpectingSuccess(
    ({TurnLoop caster, TurnLoop verifier}) pair,
    TurnAction casterAction,
  ) async {
    await Future.wait([
      pair.caster.runTurn(TurnInput(action: casterAction)),
      pair.verifier.runTurn(TurnInput(action: PassAction())),
    ]);
  }

  int fillCounter = 100;

  SpellAsset fixtureSpell(String name) {
    fillCounter++;
    final commitmentBytes = Uint8List.fromList(List.filled(32, fillCounter));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return SpellAsset(
      id: 'fixture-$name-$fillCounter',
      createdAt: DateTime.utc(2026, 7, 27),
      tier: 12,
      t: 1,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProofFor(tier: 12, t: 1, commitmentBytes: commitmentBytes),
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: '',
    );
  }

  test(
    'casting three copies of the SAME Basic spell (real registered commitment/T) '
    'across three turns advances three DISTINCT chapter positions, never crashing on '
    'reuse and never tripping the Kin-stacking (duplicate-grid) forfeit '
    '(pre-fix: BookCommitment.proveMembership always resolved to the FIRST '
    'duplicate occurrence, so the second cast hit '
    'DrawSchedule.useSlotAtPosition\'s assert(hand.contains(position)) once that '
    'position had already been removed from hand; separately, TurnLoop\'s '
    'Kin-stacking guard would forfeit ANY second same-commitment cast without '
    'the isBasicGridAndT exemption)',
    () async {
      // A real registered Basic spell (docs/BASIC_SPELLS_PLAN.md) — this
      // exercises the isBasicGridAndT exemption in _verifyPeerSpellCast's
      // duplicate-grid check (§2) at the same time as the positional fix,
      // since both must hold for unlimited copies to actually work.
      final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
      final commitmentBytes = _hexToBytes(firebolt.commitmentHex);

      // Three chapter entries sharing one commitment/proof — the "unlimited
      // copies of a Basic spell" case. The fixture avatar's hand size is 3
      // (2 bookmarks + 1), matching this chapter's size exactly, so the
      // opening deal puts ALL THREE positions in hand and leaves the deck
      // empty —
      // no refill happens, which is what forces each of the three casts
      // below to consume a genuinely distinct position (a refill-masked bug
      // would still eventually crash, but an empty deck makes the failure
      // immediate and unambiguous).
      SpellAsset dup(String id) => SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 7, 27),
        tier: 12,
        t: firebolt.t,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: syntheticProofFor(
          tier: 12,
          t: firebolt.t,
          commitmentBytes: commitmentBytes,
        ),
        name: 'Basic Firebolt',
        commitmentHex: firebolt.commitmentHex,
        spellHashHex: firebolt.spellHashHex,
      );
      final chapter = [dup('dup-a'), dup('dup-b'), dup('dup-c')];
      final pair = buildLoopPair(
        casterChapter: chapter,
        verifierChapter: [fixtureSpell('v')],
      );

      await Future.wait([pair.caster.startBattle(), pair.verifier.startBattle()]);
      expect(pair.caster.localSpellDraw!.hand, hasLength(3));
      expect(pair.caster.localSpellDraw!.remaining, isEmpty);

      for (var i = 0; i < 3; i++) {
        final handBefore = pair.caster.localSpellDraw!.hand.length;
        // Always cast the card currently at hand slot 0 — as the hand
        // shrinks (no cards left to refill from), slot 0 is a DIFFERENT
        // chapter position each time despite every card sharing the same
        // commitmentHex, name, and proof bytes.
        await runTurnExpectingSuccess(
          (caster: pair.caster, verifier: pair.verifier),
          SpellCastAction(
            spell: pair.caster.localSpellDraw!.hand[0],
            targetHex: const HexCoord(1, 0),
            handIndex: 0,
          ),
        );
        expect(
          pair.caster.localSpellDraw!.hand.length,
          handBefore - 1,
          reason: 'turn $i: empty deck — hand shrinks by exactly one per cast',
        );
      }
      expect(pair.caster.localSpellDraw!.hand, isEmpty);

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    },
  );

  test(
    'casting a SECOND copy of a non-Basic, non-Cantrip duplicate-commitment '
    'spell still triggers the duplicate-grid forfeit — the exemption in '
    '_verifyPeerSpellCast is scoped to registered Basic spells and short '
    '(Cantrip) trajectories, not a general relaxation of the anti-replay rule',
    () async {
      final commitmentBytes = Uint8List.fromList(List.filled(32, 7));
      final commitmentHex =
          '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      // 9 generations alternating fire/air: a lead change every generation,
      // so FormulaTracker commits all 9 -- kKinshipMinElements exactly, i.e.
      // NOT a Cantrip. Needed so this spell falls through both exemptions
      // (isBasicGridAndT and isCantripElementCount) and still forfeits.
      const nineElementTrajectory = [1, 2, 1, 2, 1, 2, 1, 2, 1];
      // Wire formula matching the certified trajectory 1:1 (fire=1, air=2 --
      // see ca_run.dart's ruleFromIndex/activeZoneFor), so the caster's own
      // local effect resolution (spell.formula) agrees with what the
      // verifier derives from certified proof outputs. A mismatch here is
      // orthogonal to this test's point and would desync the state hash for
      // an unrelated reason.
      const nineElementFormula = [
        'fire', 'air', 'fire', 'air', 'fire', 'air', 'fire', 'air', 'fire',
      ];
      SpellAsset dup(String id) => SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 7, 27),
        tier: 12,
        t: 9,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: syntheticProofFor(
          tier: 12,
          t: 9,
          commitmentBytes: commitmentBytes,
          trajectory: nineElementTrajectory,
        ),
        name: 'Not A Basic Spell',
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: nineElementFormula,
      );
      final chapter = [dup('dup-a'), dup('dup-b')];
      final pair = buildLoopPair(
        casterChapter: chapter,
        verifierChapter: [fixtureSpell('v')],
      );

      await Future.wait([pair.caster.startBattle(), pair.verifier.startBattle()]);
      expect(pair.caster.localSpellDraw!.hand, hasLength(2));

      // First cast succeeds.
      await runTurnExpectingSuccess(
        (caster: pair.caster, verifier: pair.verifier),
        SpellCastAction(
          spell: pair.caster.localSpellDraw!.hand[0],
          targetHex: const HexCoord(1, 0),
          handIndex: 0,
        ),
      );

      // Second cast of the SAME (non-Basic) commitment: the verifier side
      // must forfeit. The caster's own runTurn is left un-awaited here (and
      // its eventual error/non-completion ignored) — once the verifier
      // rejects mid-protocol, the caster's side of the exchange never gets
      // its matching reply and would otherwise hang this test forever
      // (Future.wait waits for BOTH sides by default). Only the verifier's
      // rejection is the thing under test.
      unawaited(
        pair.caster
            .runTurn(
              TurnInput(
                action: SpellCastAction(
                  spell: pair.caster.localSpellDraw!.hand[0],
                  targetHex: const HexCoord(1, 0),
                  handIndex: 0,
                ),
              ),
            )
            .catchError((_) => null),
      );
      await expectLater(
        pair.verifier.runTurn(TurnInput(action: PassAction())),
        throwsA(isA<StateError>()),
      );

      await pair.transportCaster.disconnect();
      await pair.transportVerifier.disconnect();
    },
  );
}

Uint8List _hexToBytes(String hex) {
  final s = hex.startsWith('0x') ? hex.substring(2) : hex;
  final out = Uint8List(32);
  for (var i = 0; i < 32 && i * 2 + 1 < s.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
