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
      _summonActsOverTurns(),
      await _counterCharmInterceptsDelayedFire(),
    ];

/// A counter charm intercepting a Mystery (delayed) cast — twice, differently.
///
/// ## What the interaction actually is
///
/// A charm carries an elemental TRAJECTORY, not a bound spell. It fires on any
/// cast whose certified element sequence **opens with** that trajectory, and
/// cancels whole formulas for as long as the two sequences agree
/// (`counterCharmFormulaMatch`). The longest matching charm wins; at most one
/// fires per cast; it is consumed (`counterCharmRevealed`) and charges its
/// owner the full triangular cost whatever fraction it actually cancelled.
///
/// Two outcomes are behaviourally different and this script covers both:
///
///   * **Full counter** — the charm covers every formula. `_applySpell` never
///     runs. Nothing resolves, no wild magic fires (invariant A1), and the
///     caster's chain regresses as if they had passed.
///   * **Partial counter** — the charm covers a leading prefix. The cast DOES
///     resolve, with `suppressedFormulas` skipping the cancelled prefix, so the
///     later formulas still land.
///
/// ## Why the spell is shaped the way it is
///
/// Certified sequence `[fire, fire, fire, earth, water, fire]` — two formulas
/// that produce *visibly different* things:
///
///   * `(fire, fire, fire)` → affinity fire, pair (fire, fire) → **damage**
///   * `(earth, water, fire)` → affinity earth, pair (water, fire) → **clouds**
///
/// That split is what makes the counter load-bearing rather than decorative.
/// A full counter leaves HP untouched AND no cloud; a partial counter cancels
/// only the damage, so the cloud still appears. If both formulas produced the
/// same effect — or an effect with no board footprint, as an Earth Barrier has
/// on terrain-free ground — the two outcomes would be indistinguishable in the
/// transcript and the script would prove nothing.
///
/// The earth element is not decorative either: a Mystery cast must be backed
/// by certified supreme dominance in the **earth** zone
/// (`certifiedSupremeTags`), so a pure-fire spell cannot legally be delayed at
/// all and would forfeit at `unbacked_enhancement_claim`.
///
/// ## The charms are load-bearing, measured
///
/// Same script with `peerCharms: const []` and nothing else changed:
///
/// | | turn 2 | turn 4 |
/// |---|---|---|
/// | no charms | player_b 24 → 20 hp, cloud appears | 20 → 16 hp |
/// | with charms | 24 hp, **no cloud** (full counter) | 24 hp, **cloud lands** (partial) |
///
/// So the charms remove 8 damage across the match, and the full and partial
/// outcomes are distinguishable from each other by the cloud alone. This is
/// the check worth repeating for any future counter script: a green script in
/// which the intercepted effect would not have happened anyway proves nothing.
///
/// ## Why delayed rather than immediate
///
/// For a delayed fire, the sequence the charm matches against is the
/// [CertifiedCast] captured on the DECLARATION turn (M4.15) — not the wire
/// formula, and not anything recomputed at fire time. So this script also
/// pins the join between the B-1 fix and counter-charm matching: if a delayed
/// fire ever reverted to its wire formula, a charm attuned to the certified
/// trajectory would stop matching and this transcript would move.
Future<MatchScript> _counterCharmInterceptsDelayedFire() async {
  const damageThenCloud = [
    BorderZone.fire, BorderZone.fire, BorderZone.fire,
    BorderZone.earth, BorderZone.water, BorderZone.fire,
  ];
  // Two distinct grids: the duplicate-grid guard forfeits a second cast of the
  // same commitment, and both are cast in one match.
  final firstMystery = spellFromElements(
    elements: damageThenCloud,
    variant: 60,
    name: 'Emberfall I',
  );
  final secondMystery = spellFromElements(
    elements: damageThenCloud,
    variant: 61,
    name: 'Emberfall II',
  );

  const target = HexCoord(1, 0);
  const delay = 1;
  // Fixed nonces, distinct per cast: a replayable script cannot contain
  // entropy the golden does not also contain.
  final nonceOne = Uint8List.fromList(List.generate(16, (i) => i + 41));
  final nonceTwo = Uint8List.fromList(List.generate(16, (i) => i + 97));
  final commitOne = await PendingDelayedSpell.commitmentHash(
    target: target, delay: delay, nonce: nonceOne);
  final commitTwo = await PendingDelayedSpell.commitmentHash(
    target: target, delay: delay, nonce: nonceTwo);

  return MatchScript(
    name: 'counter_charm_intercepts_delayed_fire',
    description:
        'player_b holds two charms — a two-formula one covering the whole '
        'cast and a one-formula one covering only its damage. player_a casts '
        'two Mystery spells, each delayed a turn. The long charm fires first '
        '(longest match wins) and swallows the first cast whole; once spent, '
        'the short charm intercepts the second, cancelling the damage while '
        'the cloud still lands. Covers full vs partial counters, charm '
        'selection and consumption, and interception of a spell declared on '
        'an earlier turn.',
    localChapterCommitments: [
      firstMystery.commitmentHex,
      secondMystery.commitmentHex,
    ],
    // Deliberately given in short-then-long order: selection must pick by
    // MATCH LENGTH, not by scan order, so listing the weaker charm first is
    // the arrangement that would expose a selection bug.
    peerCharms: const [
      [BorderZone.fire, BorderZone.fire, BorderZone.fire],
      damageThenCloud,
    ],
    turns: [
      ScriptedTurn(
        note: 'player_a declares Mystery I (delay 1); no charm can fire yet — '
            'nothing has been cast to match against',
        local: (_) => TurnInput(
          action: MysterySpellCastAction(
            spell: firstMystery,
            mysteryCommitment: commitOne,
          ),
        ),
        peer: (_) => TurnInput(action: PassAction()),
      ),
      ScriptedTurn(
        note: 'Mystery I fires and the TWO-formula charm swallows it whole: '
            'no damage, no cloud, chain regresses as if player_a had passed',
        local: (_) => TurnInput(
          action: PassAction(),
          delayedSpellReveals: [
            DelayedSpellReveal(
              pendingSpellId: PendingDelayedSpell.idFromCommitment(commitOne),
              targetTile: target,
              delay: delay,
              nonce: nonceOne,
            ),
          ],
        ),
        peer: (_) => TurnInput(action: PassAction()),
      ),
      ScriptedTurn(
        note: 'player_a declares Mystery II — same trajectory, different grid',
        local: (_) => TurnInput(
          action: MysterySpellCastAction(
            spell: secondMystery,
            mysteryCommitment: commitTwo,
          ),
        ),
        peer: (_) => TurnInput(action: PassAction()),
      ),
      ScriptedTurn(
        note: 'Mystery II fires. The long charm is spent, so the ONE-formula '
            'charm takes it: the damage is cancelled but the cloud lands — '
            'the partial counter, visibly different from turn 2',
        local: (_) => TurnInput(
          action: PassAction(),
          delayedSpellReveals: [
            DelayedSpellReveal(
              pendingSpellId: PendingDelayedSpell.idFromCommitment(commitTwo),
              targetTile: target,
              delay: delay,
              nonce: nonceTwo,
            ),
          ],
        ),
        peer: (_) => TurnInput(action: PassAction()),
      ),
    ],
  );
}

/// A summoned creature that outlives the turn that made it.
///
/// Every other script's effects land and are done. A minion is the engine's
/// only long-lived autonomous actor: it is created on one turn and then, on
/// each turn after, decides where to move and whether to attack — entirely
/// without player input. That per-turn decision reads live board state and
/// draws from the seeded RNG, so it is exactly the kind of thing a resolver
/// refactor can reorder without any single-turn test noticing.
///
/// ## Choosing the element sequence
///
/// Creature stats come straight from element counts (`CreatureSpec._statsOf`):
/// `hp = nEarth`, `damage = nFire ~/ 2`, `moveSpeed = nAir ~/ 2`,
/// `attackRange = nWater ~/ 3`. Three earths — the obvious "plain creature"
/// choice, and what this script was first written with — produces
/// `MinionStats(hp: 3, dmg: 0, move: 0, range: 0)`: a creature that cannot
/// move or attack, so the script covered nothing but the spawn.
///
/// `EEFFAA` gives hp 2 / dmg 1 / move 1, which actually pursues and hits, and
/// dodges every ability pattern in `kSummonAbilityPattern` (AAAA, FFFF, EEEE,
/// WWWW, FAFA, AWAW, WEWE, EFEF) — an accidental ability would make this a
/// script about that ability instead.
///
/// This script is why M4.16 was found: writing it was the first time anything
/// had put a summon across a two-device boundary.
MatchScript _summonActsOverTurns() {
  final summon = spellFromElements(
    elements: const [
      BorderZone.earth, BorderZone.earth,
      BorderZone.fire, BorderZone.fire,
      BorderZone.air, BorderZone.air,
    ],
    variant: 50,
    name: 'Stone Sentinel',
    isSummon: true,
  );

  return MatchScript(
    name: 'summon_acts_over_turns',
    description:
        'player_a summons a creature on turn 1, then does nothing for three '
        'turns while it acts on its own. Covers minion spawn on BOTH devices '
        '(M4.16), per-turn minion movement and attack decisions, and the '
        'creature persisting across turn boundaries as an autonomous actor.',
    localChapterCommitments: [summon.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a summons; player_b retreats a tile',
        local: TurnInput(
          action: SpellCastAction(spell: summon, targetHex: const HexCoord(1, 1)),
        ),
        peer: TurnInput(action: PassAction(), movePath: const [HexCoord(2, 0)]),
      ),
      ScriptedTurn.fixed(
        note: 'nobody acts — the creature moves and fights on its own',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'player_b keeps retreating; the creature should keep pursuing',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction(), movePath: const [HexCoord(3, 0)]),
      ),
      ScriptedTurn.fixed(
        note: 'a fourth turn, to catch a pursuit or attack cadence that is '
            'off by one',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}


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
