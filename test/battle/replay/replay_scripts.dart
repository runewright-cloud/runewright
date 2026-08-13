// SPDX-License-Identifier: GPL-3.0-or-later
//
// replay_scripts.dart — the corpus of scripted matches.
//
// Each script is a fixed sequence of turns whose recorded transcript is
// checked into `golden/`. Adding a script means adding its golden; changing a
// script's turns changes its golden and must be justified in the same commit,
// exactly as with the circuit's vector corpus.
//
// ## What makes a good script here
//
// Not "one per feature" — that is what the engine unit tests are for. A script
// earns its place by exercising something that **spans turns**, because
// cross-turn state is what a single-turn test structurally cannot cover and
// what the TurnLoop refactor is most likely to break:
//
//   * state carried between turns outside the canonical hash (draw schedules,
//     draw-seed nonces, seen-commitment sets, the rippling nonce, the
//     component start seat)
//   * anything declared on one turn and resolved on a later one
//   * resolution ORDER across several actors

import 'dart:typed_data';

import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/pending_delayed_spell.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../engine/certified_cast_fixture.dart';
import 'match_replay.dart';

/// Every script in the corpus. The test iterates this list.
///
/// Async because a Mystery commitment is a SHA-256 the script has to compute
/// up front — the same value the caster's UI builds before the cast is ever
/// sent, so the script is doing exactly what a real client does.
Future<List<MatchScript>> allScripts() async => [
      await _delayedCastAndChain(),
    ];

/// A Mystery declared on turn 1, fired on turn 2, followed by ordinary casts.
///
/// Chosen as the first script because it puts the most cross-turn machinery in
/// one place: a `PendingDelayedSpell` (including the non-canonical `origin`,
/// `declaredRange` and `certified` fields) survives a turn boundary, the
/// duplicate-grid set accumulates across casts, chain state advances and
/// breaks, and both players act on the same turns so resolution order matters.
Future<MatchScript> _delayedCastAndChain() async {
  final mystery = honestSpellVariant(1);
  final peerCast = honestSpellVariant(2);
  final followUp = honestSpellVariant(3);

  const target = HexCoord(1, 0);
  const delay = 1;
  // Fixed, not random: a replayable script cannot contain entropy the golden
  // does not also contain.
  final nonce = Uint8List.fromList(List.generate(16, (i) => i + 7));
  final commitment = await PendingDelayedSpell.commitmentHash(
    target: target,
    delay: delay,
    nonce: nonce,
  );

  return MatchScript(
    name: 'delayed_cast_and_chain',
    description:
        'Mystery declared turn 1 and fired turn 2, with ordinary casts either '
        'side of it. Covers pending-delayed-spell carry across a turn '
        'boundary, the duplicate-grid set, chain advance/break, and two '
        'actors resolving on the same turn.',
    localChapterCommitments: [
      mystery.commitmentHex,
      followUp.commitmentHex,
    ],
    peerChapterCommitments: [peerCast.commitmentHex],
    turns: [
      ScriptedTurn(
        note: 'player_a declares a Mystery (delay 1); player_b passes',
        local: TurnInput(
          action: MysterySpellCastAction(
            spell: mystery,
            mysteryCommitment: commitment,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn(
        note: 'the delayed spell fires while player_b casts — both resolve '
            'this turn, so resolution order is under test',
        local: TurnInput(
          action: PassAction(),
          delayedSpellReveals: [
            DelayedSpellReveal(
              pendingSpellId: PendingDelayedSpell.idFromCommitment(commitment),
              targetTile: target,
              delay: delay,
              nonce: nonce,
            ),
          ],
        ),
        peer: TurnInput(
          action: SpellCastAction(spell: peerCast, targetHex: const HexCoord(0, 0)),
        ),
      ),
      ScriptedTurn(
        note: 'both move; chain state should regress on the non-casting turn',
        local: TurnInput(action: PassAction(), movePath: const [HexCoord(0, 1)]),
        peer: TurnInput(action: PassAction(), movePath: const [HexCoord(2, 0)]),
      ),
      ScriptedTurn(
        note: 'player_a casts a second, distinct grid — the duplicate-grid set '
            'must accept it while still remembering the first',
        local: TurnInput(
          action: SpellCastAction(spell: followUp, targetHex: const HexCoord(2, 0)),
        ),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}
