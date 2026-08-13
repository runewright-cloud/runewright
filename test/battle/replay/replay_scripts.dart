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
import 'package:rune_duel/engine/border_zone.dart';
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
      _fireDamageExchange(),
      _terrainAndClouds(),
      _drawAndRefill(),
      // A summon script belongs here and is written and ready — it is held
      // back because peer summons do not replicate to the opponent's device
      // at all (docs/M4_findings.md M4.16). Recording a golden now would
      // enshrine a desync as expected behaviour. Restore it with the fix; the
      // regression test is peer_summon_replication_test.dart.
    ];


/// Casting from a real hand, turn after turn, so the deck actually drains.
///
/// The largest gap the corpus had. `_drawSchedules` and `_drawSeedNonce` are
/// cross-turn state that is **deliberately excluded from the canonical hash**
/// — draw positions are publicly recomputable by both clients rather than
/// transmitted — so the state hash is blind to them and every other script
/// leaves them untouched. They still steer later turns: which card a refill
/// hands you decides what you can cast next.
///
/// That makes this the sharpest instance of the architecture review's §7
/// concern in the codebase: two clients can agree on every canonical byte
/// while disagreeing about what each player is holding. The harness records
/// both devices' view and flags a mismatch, so this script is the one that
/// would catch it.
///
/// Both sides carry a chapter, so book-membership proving is live too and the
/// peer's schedule advances off the Merkle leaf index rather than off trust.
MatchScript _drawAndRefill() {
  // Five each. Enough that a three-card hand leaves a deck to refill from for
  // several turns without decking out, which is a different code path.
  final aChapter = [
    for (var i = 0; i < 5; i++)
      spellFromElements(
        elements: List.filled(3, BorderZone.fire),
        variant: 30 + i,
        name: 'A Card $i',
      ),
  ];
  final bChapter = [
    for (var i = 0; i < 5; i++)
      spellFromElements(
        elements: List.filled(3, BorderZone.fire),
        variant: 40 + i,
        name: 'B Card $i',
      ),
  ];

  // Cast whatever is in hand slot 0, whatever that turns out to be. The slot
  // index is stable; the CARD in it changes as refills land, which is the
  // behaviour being pinned. Naming a spell explicitly would pin the deal
  // instead of the refill, and would break the moment the deal changed.
  //
  // Falls back to passing if the hand is empty (decked out), so the script
  // degrades into a legal move rather than throwing.
  TurnInput castHandSlotZero(TurnLoop loop, HexCoord target) {
    final draw = loop.localSpellDraw;
    if (draw == null || draw.hand.isEmpty) {
      return TurnInput(action: PassAction());
    }
    return TurnInput(
      action: SpellCastAction(
        spell: draw.hand.first,
        targetHex: target,
        handIndex: 0,
      ),
    );
  }

  return MatchScript(
    name: 'draw_and_refill',
    description:
        'Both players cast from a real dealt hand over four turns, draining '
        'five-card chapters. Covers the opening deal, hand refill on cast, '
        'the per-player DrawSchedule both devices maintain, and _drawSeedNonce '
        'advancing — none of which the canonical state hash can see.',
    localChapter: aChapter,
    peerChapter: bChapter,
    bookmarks: 2, // handSize == bookmarkCount + 1 == 3
    startBattle: true, // deal before turn 1, as production does
    turns: [
      ScriptedTurn(
        note: 'hands were dealt by startBattle, so turn 1 casts from slot 0 '
            'and takes the first refill',
        local: (loop) => castHandSlotZero(loop, const HexCoord(1, 0)),
        peer: (loop) => castHandSlotZero(loop, const HexCoord(0, 0)),
      ),
      ScriptedTurn(
        note: 'slot 0 now holds a different card; casting it again drains the '
            'deck a second time',
        local: (loop) => castHandSlotZero(loop, const HexCoord(1, 0)),
        peer: (loop) => castHandSlotZero(loop, const HexCoord(0, 0)),
      ),
      ScriptedTurn.fixed(
        note: 'a quiet turn — draw state must NOT advance when nobody casts',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn(
        note: 'cast again after the pause; the nonce must pick up where it '
            'left off rather than replaying an earlier draw',
        local: (loop) => castHandSlotZero(loop, const HexCoord(1, 0)),
        peer: (loop) => castHandSlotZero(loop, const HexCoord(0, 0)),
      ),
    ],
  );
}

/// Two wizards trading Fire Damage until HP actually moves.
///
/// The first script's Earth Barriers resolve but change nothing on an empty
/// battlefield, so board mutation was entirely uncovered by the corpus. This
/// is the most basic thing a spell can do — take HP off an opponent — and
/// until now nothing in the corpus would have noticed if it stopped happening.
///
/// `[fire, fire, fire]` is affinity fire with effect pair (fire, fire), which
/// `effectKindFromPair` resolves to `EffectKind.damage`.
MatchScript _fireDamageExchange() {
  final aFirst = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 10,
    name: 'Ember Lance',
  );
  final bReply = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 11,
    name: 'Answering Flame',
  );
  final aSecond = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 12,
    name: 'Second Lance',
  );

  return MatchScript(
    name: 'fire_damage_exchange',
    description:
        'Both wizards cast Fire Damage at each other across three turns. '
        'Covers HP mutation, simultaneous casts resolving in one turn, chain '
        'accumulation on repeated same-affinity casts, and the duplicate-grid '
        'set accepting three distinct grids.',
    localChapterCommitments: [aFirst.commitmentHex, aSecond.commitmentHex],
    peerChapterCommitments: [bReply.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a opens; player_b passes — one-sided damage',
        local: TurnInput(
          action: SpellCastAction(spell: aFirst, targetHex: const HexCoord(1, 0)),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'both cast at once — resolution order decides who lands first',
        local: TurnInput(
          action: SpellCastAction(spell: aSecond, targetHex: const HexCoord(1, 0)),
        ),
        peer: TurnInput(
          action: SpellCastAction(spell: bReply, targetHex: const HexCoord(0, 0)),
        ),
      ),
      ScriptedTurn.fixed(
        note: 'both idle, so both chains regress',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}

/// Terrain and clouds — board objects that persist across turns.
///
/// Damage is instantaneous; these are not. A tile effect or a cloud created on
/// one turn is still there on the next, ticking down, which is the kind of
/// carried state a single-turn test cannot see decay incorrectly.
///
/// `[earth, earth, water]` → `EffectKind.tileModification`;
/// `[water, water, fire]` → `EffectKind.clouds`.
MatchScript _terrainAndClouds() {
  final tileSpell = spellFromElements(
    elements: const [BorderZone.earth, BorderZone.earth, BorderZone.water],
    variant: 20,
    name: 'Shifting Ground',
  );
  final cloudSpell = spellFromElements(
    elements: const [BorderZone.water, BorderZone.water, BorderZone.fire],
    variant: 21,
    name: 'Gathering Fog',
  );

  return MatchScript(
    name: 'terrain_and_clouds',
    description:
        'A tile modification and a cloud, then two quiet turns. Covers board '
        'objects that persist and decay across turn boundaries, which '
        'instantaneous damage does not reach.',
    localChapterCommitments: [tileSpell.commitmentHex],
    peerChapterCommitments: [cloudSpell.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a reshapes a tile; player_b raises a cloud',
        local: TurnInput(
          action: SpellCastAction(spell: tileSpell, targetHex: const HexCoord(1, 0)),
        ),
        peer: TurnInput(
          action: SpellCastAction(spell: cloudSpell, targetHex: const HexCoord(0, 0)),
        ),
      ),
      ScriptedTurn.fixed(
        note: 'quiet turn — whatever was created must persist or decay by rule',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'second quiet turn, to catch a decay that is off by one',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}

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
      ScriptedTurn.fixed(
        note: 'player_a declares a Mystery (delay 1); player_b passes',
        local: TurnInput(
          action: MysterySpellCastAction(
            spell: mystery,
            mysteryCommitment: commitment,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
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
      ScriptedTurn.fixed(
        note: 'both move; chain state should regress on the non-casting turn',
        local: TurnInput(action: PassAction(), movePath: const [HexCoord(0, 1)]),
        peer: TurnInput(action: PassAction(), movePath: const [HexCoord(2, 0)]),
      ),
      ScriptedTurn.fixed(
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
