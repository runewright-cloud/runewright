// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_reveal_test.dart — Divination (Water flavor / Watery Scrying Pool)
// spell-list reveal (TurnLoop._exchangeSpellRevealOpenings). Reveals the
// target's current HAND, not their whole chapter (SPELL_DRAW_WIRING_PLAN.md
// §8) — each card individually verified against the peer's already-
// exchanged bookCommit root (peerBookRoot) via its own Merkle proof (a
// single batch root over just the hand can't work — see that method's
// header comment). Covers:
//   1. An active outgoing Water DivinationLink reveals the peer's real
//      hand, each entry verifying as a chapter member.
//   2. A revealed entry that doesn't verify against the peer's committed
//      root forfeits and throws (`bad_spell_reveal`), same fail-closed
//      pattern as the Air flavor's `bad_scry_opening`.

import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/divination_link.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  SpellAsset fixtureSpell(String id, int fill) {
    final commitmentBytes = Uint8List.fromList(List.filled(32, fill));
    final commitmentHex =
        '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 7, 21),
      tier: 12,
      t: 1,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: Uint8List(0),
      name: 'Fixture Spell $id',
      commitmentHex: commitmentHex,
      spellHashHex: '',
      formula: const [],
    );
  }

  // Each call must build fresh DivinationLink instances — sharing one list
  // (and its mutable objects) between the two independently-simulated
  // BattleStates would let one loop's per-turn tick corrupt the other's
  // view, diverging the state hash for reasons unrelated to what these
  // tests check (found the hard way: a shared list caused a spurious state
  // hash mismatch).
  List<DivinationLink> makeSpellListLink() => [
    DivinationLink(
      id: 'link_1',
      casterId: 'revealer',
      targetId: 'victim',
      remainingTurns: 2,
      flavor: DivinationFlavor.spellList,
    ),
  ];

  BattleState makeState({required List<DivinationLink> divinationLinks}) {
    final battlefield = Battlefield();
    const posRevealer = HexCoord(0, 0);
    const posVictim = HexCoord(2, -2);
    battlefield.occupancy['revealer'] = posRevealer;
    battlefield.occupancy['victim'] = posVictim;
    return BattleState(
      config: const MatchConfig(),
      avatars: [
        WizardAvatar(
          playerId: 'revealer',
          ownerPubkeyHex: '0x${'0' * 64}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posRevealer,
          teamId: 'team_revealer',
          baseSpellRange: 3,
          // 1 bookmark -> hand size 2, matching the 2-spell test chapters
          // below exactly, so the whole chapter always fits in hand.
          accoutrements: [
            Accoutrement(id: 'revealer_bm0', kind: AccoutrementKind.bookmark),
          ],
        ),
        WizardAvatar(
          playerId: 'victim',
          ownerPubkeyHex: '0x${'0' * 64}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posVictim,
          teamId: 'team_victim',
          baseSpellRange: 3,
          accoutrements: [
            Accoutrement(id: 'victim_bm0', kind: AccoutrementKind.bookmark),
          ],
        ),
      ],
      teams: [
        const Team(id: 'team_revealer', playerIds: ['revealer']),
        const Team(id: 'team_victim', playerIds: ['victim']),
      ],
      battlefield: battlefield,
      divinationLinks: divinationLinks,
    );
  }

  test('an active outgoing Water DivinationLink reveals the peer\'s real '
      'hand, each entry verified against their book root', () async {
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportRevealer, transportVictim) = InMemoryTransport.pair();
    final sessionRevealer = BattleSession(transportRevealer, matchId);
    final sessionVictim = BattleSession(transportVictim, matchId);

    // 2 spells, fixture hand size 2 (1 bookmark + 1) — the whole chapter
    // fits in the opening hand, so the deal is deterministic (no
    // draw-order dependence) and the revealed hand is exactly victimHexes.
    final victimSpells = [fixtureSpell('a', 0xAA), fixtureSpell('b', 0xBB)];
    final victimHexes = victimSpells.map((s) => s.commitmentHex).toList()..sort();
    final victimRoot = BookCommitment.computeRoot(victimHexes);

    final loopRevealer = TurnLoop(
      state: makeState(divinationLinks: makeSpellListLink()),
      session: sessionRevealer,
      localPlayerId: 'revealer',
      matchId: matchId,
      peerBookRoot: victimRoot,
      peerBookLeafCount: victimSpells.length,
    );
    final loopVictim = TurnLoop(
      state: makeState(divinationLinks: makeSpellListLink()),
      session: sessionVictim,
      localPlayerId: 'victim',
      matchId: matchId,
    )
      ..localChapterSpells = victimSpells
      ..localChapterCommitments = victimHexes;

    // Two turns: the Water reveal exchange runs in Phase 1 (beginTurn),
    // before the opening hand deal (Phase 3) has happened yet on turn 1 —
    // mirrors real play, where a Divination link can't be active before an
    // earlier turn's cast created it, by which point dealing already
    // happened. Turn 2 is the first turn the reveal can actually succeed.
    await Future.wait([
      loopRevealer.runTurn(TurnInput(action: PassAction())),
      loopVictim.runTurn(TurnInput(action: PassAction())),
    ]);
    await Future.wait([
      loopRevealer.runTurn(TurnInput(action: PassAction())),
      loopVictim.runTurn(TurnInput(action: PassAction())),
    ]);
    await transportRevealer.disconnect();
    await transportVictim.disconnect();

    expect(
      loopRevealer.revealedEnemyHand?.map((s) => s.commitmentHex).toSet(),
      victimHexes.toSet(),
      reason: 'the scryer should see the victim\'s real hand, matching '
          'what a real cast-verification pass would already trust',
    );
  });

  test('a revealed hand entry that does not verify against the peer\'s book '
      'root forfeits and throws', () async {
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportRevealer, transportVictim) = InMemoryTransport.pair();
    final sessionRevealer = BattleSession(transportRevealer, matchId);
    final sessionVictim = BattleSession(transportVictim, matchId);

    final victimSpells = [fixtureSpell('a', 0xAA), fixtureSpell('b', 0xBB)];
    final victimHexes = victimSpells.map((s) => s.commitmentHex).toList()..sort();
    // A root that does NOT match victimSpells — simulates a peer whose
    // reveal disagrees with what they committed to at handshake (whether
    // by lying or by wire corruption, the check can't and shouldn't tell
    // the difference; both must forfeit). Each revealed entry's own Merkle
    // proof (built against the victim's real commitments) fails to verify
    // against this wrong root.
    final wrongRoot = BookCommitment.computeRoot([fixtureSpell('z', 0xFF).commitmentHex]);

    final loopRevealer = TurnLoop(
      state: makeState(divinationLinks: makeSpellListLink()),
      session: sessionRevealer,
      localPlayerId: 'revealer',
      matchId: matchId,
      peerBookRoot: wrongRoot,
      peerBookLeafCount: victimSpells.length,
    );
    final loopVictim = TurnLoop(
      state: makeState(divinationLinks: makeSpellListLink()),
      session: sessionVictim,
      localPlayerId: 'victim',
      matchId: matchId,
    )
      ..localChapterSpells = victimSpells
      ..localChapterCommitments = victimHexes;

    // Turn 1: hands aren't dealt yet when the Phase-1 reveal exchange runs
    // (see the previous test's comment), so the mismatched root can't be
    // exercised until turn 2 — both sides complete turn 1 uneventfully.
    await Future.wait([
      loopRevealer.runTurn(TurnInput(action: PassAction())),
      loopVictim.runTurn(TurnInput(action: PassAction())),
    ]);

    // Turn 2: the victim's own runTurn proceeds honestly through its side of
    // this exchange, then hangs waiting for the revealer's next exchange
    // (which never arrives, since the revealer aborts here) — same shape as
    // turn_loop_cast_authorization_test.dart's expectVerifierRejects.
    unawaited(loopVictim.runTurn(TurnInput(action: PassAction())).catchError((Object _) => null));

    await expectLater(
      loopRevealer.runTurn(TurnInput(action: PassAction())),
      throwsA(isA<StateError>().having(
        (e) => e.toString(),
        'message',
        contains('failed membership verification'),
      )),
    );

    await transportRevealer.disconnect();
    await transportVictim.disconnect();
  });
}
