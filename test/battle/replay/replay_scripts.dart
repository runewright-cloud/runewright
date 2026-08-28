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
import '../models/certified_armor_fixture.dart';
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
      _potentSummonActsTwice(),
      await _counterCharmInterceptsDelayedFire(),
      await _unbackedMysteryClaimForfeits(),
      _slowTileDrainsACastIntoAFizzle(),
      await _mysteryFizzleIsNotAFreeCast(),
      _armoredWizardOutreachesAnUnarmoredOne(),
      _chargerAndMuddyResolveThroughTheHaymaker(),
    ];

/// Aetherial Armor's four numerical bonuses, across four turns of a real duel
/// (engine v6, docs/AETHERIAL_ARMOR.md §9).
///
/// ## Why this one is worth a script
///
/// Because armor is the first thing in the game whose effect is *ambient*: it
/// is not declared, not revealed, not consumed, and it moves four different
/// numbers at once from a single object seated at setup. The unit tests in
/// `test/battle/engine/armor_numerical_effects_test.dart` pin each bonus in
/// isolation; this pins the whole of it as **bytes**, on **both devices**,
/// turn after turn — which is the only form that can catch an armor that
/// applies on one device and not the other, or one that quietly stops applying
/// on turn 3.
///
/// player_a wears a T=21 armor certified as `F×7 A×4 W×4 E×6`:
/// melee +1, move +1, range +1, armor HP +5, keywords `{cleave, flying,
/// anchored}` — every one of which must stay inert. player_b wears nothing, so
/// every turn is a paired comparison rather than an absolute claim.
///
///   1. Both punch. a deals 2 (1 + armor), b deals 1 — visible in the golden
///      as b losing two HP to a's one. Turn 1 also records the asymmetric
///      OPENING HP, 29 against 24, which is Earth.
///   2. a walks a three-step path and arrives at `0,3`. Base speed is 2, so
///      the third tile is purely the Air bonus; an unarmored a would be
///      recorded at `0,2`.
///   3. a walks one more tile, to sit exactly 4 hexes from b.
///   4. a casts from there and b takes the damage. Base range is 3, so the
///      cast is legal only because of Water — an unarmored a would be refused
///      out of range, `resolvedSpells` would be 0, and b's HP would not move.
MatchScript _armoredWizardOutreachesAnUnarmoredOne() {
  // Certified from a proof attesting this dominance run; see
  // certified_armor_fixture.dart for why the fixture goes through
  // `fromOutputs` rather than the editor's preview path.
  final armor = armorOf('F' * 7 + 'A' * 4 + 'W' * 4 + 'E' * 6);
  assert(armor.meleeBonus == 1 && armor.moveSpeedBonus == 1);
  assert(armor.spellRangeBonus == 1 && armor.armorHpBonus == 5);

  final lance = spellFromElements(
    elements: const [BorderZone.fire, BorderZone.fire, BorderZone.fire],
    variant: 30,
    name: 'Armored Lance',
  );

  // player_a starts at (0,0), player_b at (1,0) — adjacent, so turn 1's
  // punches land. Walking down the +r axis takes a to (0,4), which is 4 hexes
  // from b: one past an unarmored caster's reach. b stands still from turn 2
  // on, so it is still standing on the tile a aims at.
  const walk = [HexCoord(0, 1), HexCoord(0, 2), HexCoord(0, 3)];

  return MatchScript(
    name: 'armor_bonuses_across_a_duel',
    description:
        'An armored wizard against an unarmored one: Earth in the opening HP, '
        'Fire in a punch, Air in a three-tile walk the unarmored wizard cannot '
        'match, and Water in a cast from one tile past base range. Every '
        'certified keyword (cleave, flying, anchored) must stay inert '
        'throughout.',
    localArmor: armor,
    localChapterCommitments: [lance.commitmentHex],
    // Both always punch when a target is adjacent; after turn 1 they separate
    // and no candidate exists, so this only fires on turn 1.
    localMeleePicker: (candidates) async => candidates.first,
    peerMeleePicker: (candidates) async => candidates.first,
    turns: [
      ScriptedTurn.fixed(
        note: 'both punch: armored 2, unarmored 1',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'a walks all 3 declared tiles: base 2 + Air 1',
        local: TurnInput(action: PassAction(), movePath: walk),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'a steps to (0,4) — exactly 4 hexes from b',
        local: TurnInput(action: PassAction(), movePath: [HexCoord(0, 4)]),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'a casts at range 4, legal only with Water',
        local: TurnInput(
          action: SpellCastAction(spell: lance, targetHex: const HexCoord(1, 0)),
        ),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}


/// Charger and Muddy, the two armor keywords that go live at engine v7
/// (docs/AETHERIAL_ARMOR.md §11), resolving through the haymaker mechanics
/// that already existed.
///
/// ## Why this one is worth a script
///
/// Because Muddy's whole point is a status that outlives the turn that applied
/// it. Turn 1 lands the slow; turn 2 is where it costs the victim a tile, and
/// a single-turn test structurally cannot see that. Charger rides along
/// because it is the other half of the same punch and because its input — how
/// far the attacker actually walked — is itself a cross-phase value (movement
/// resolves in Phase 2, the punch reads the walked path in Phase 4b).
///
/// The keyword source is also worth pinning as bytes: canonical state is
/// **identical** to v6 here, so a v6 device replaying this script would agree
/// on every field the summary prints and still compute a different HP. Only
/// the transcript catches that.
///
/// player_a wears a T=10 armor certified `F A F A F F W E W E`: fire 4 (melee
/// +1), earth 2 (HP +2, hence the 26 in the opening), and the two keyword
/// patterns `FAFA` (Charger) and `WEWE` (Muddy). Deliberately NOT four
/// consecutive fires, so Cleave is absent and cannot be confused for the
/// damage. player_b wears nothing.
///
///   1. a walks two tiles to `1,-1` — still adjacent to b — and punches. The
///      punch is 3: 1 base + 1 Fire + (2 tiles ~/ 2). Under v6 the same walk
///      and the same armor produce 2, which is the whole difference this
///      golden records. Muddy leaves b with one `speedDown` status.
///   2. b declares a two-tile walk and arrives at `2,0`, one tile short: the
///      slow from turn 1 is still on it, so its speed is 1. An unslowed b
///      would be recorded at `3,0`. a stands still and is no longer adjacent,
///      so nobody punches and the turn is purely the status's consequence.
MatchScript _chargerAndMuddyResolveThroughTheHaymaker() {
  final armor = armorOf('FAFAFFWEWE');
  assert(armor.meleeBonus == 1, 'four fires is the first melee rung');
  assert(armor.armorHpBonus == 2, 'the two earths in WEWE are a real rung');
  assert(armor.keywords.length == 2, 'Charger and Muddy, and nothing else');

  return MatchScript(
    name: 'charger_and_muddy_through_the_haymaker',
    description:
        'An armored wizard walks two tiles and punches: Fire and Charger stack '
        'on the one melee path (3 damage, not 2), and Muddy leaves the target '
        'slowed. The next turn the slowed wizard declares two tiles and walks '
        'one. Cleave, absent by construction, cannot account for any of it.',
    localArmor: armor,
    // Only a punches. b is unarmored, and leaving its picker null keeps every
    // point of damage in the transcript attributable to one wizard.
    localMeleePicker: (candidates) async => candidates.first,
    turns: [
      ScriptedTurn.fixed(
        note: 'a walks 2 and punches: 1 base + 1 Fire + 1 Charger, plus Muddy',
        local: TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(0, -1), HexCoord(1, -1)],
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'b is slowed: two tiles declared, one walked',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(2, 0), HexCoord(3, 0)],
        ),
      ),
    ],
  );
}

/// A caster who cannot pay gets nothing, whether or not they route it through
/// Mystery.
///
/// The corpus's record of **M4.21**: once canonical Phase-5 settlement marks a
/// cast `fizzledForMana`, neither the immediate-Mystery conversion nor the
/// delayed-declaration branch may resurrect it.
///
/// ## Why this one is worth a script
///
/// Because the half that matters spans a turn boundary, which is this corpus's
/// stated admission criterion. The old bug's delayed variant wrote a
/// `PendingDelayedSpell` on turn 1 and cashed it on turn 2 for free — a
/// two-turn transcript is the only place that is visible at all. Turn 2 here
/// exists solely to be the turn that fire would have landed on.
///
/// The unit regressions
/// (`test/battle/engine/mystery_fizzle_characterization_test.dart`) assert the
/// fields anyone thought to name. This asserts the **bytes**, which is the
/// stronger claim for a bug whose entire signature was that it produced no
/// symptom: both devices agreed, no state hash tripped, and the only evidence
/// was HP that should not have moved.
///
/// ## Reading the spell
///
/// `[fire, fire, fire, earth, earth, earth]` — two complete formulas, so
/// `spellFromElements`' whole-formula assertion holds. The fire triplet is
/// Fire Damage: if either repair regressed, this golden gains HP loss on
/// player_b and an Earth Barrier that should not exist. The earth triplet is
/// not decoration either — a Mystery claim must be backed by certified supreme
/// dominance in the **earth** zone, so without it the peer forfeits on
/// `unbacked_enhancement_claim` and the script tests nothing.
///
/// Cost is `(5×3 + 2) × 1.05^6 × 1.5^1` = 34, against a 10-mana pool. The
/// shortfall is deliberately wide: nothing about this script should turn on
/// rounding.
Future<MatchScript> _mysteryFizzleIsNotAFreeCast() async {
  const elements = [
    BorderZone.fire,
    BorderZone.fire,
    BorderZone.fire,
    BorderZone.earth,
    BorderZone.earth,
    BorderZone.earth,
  ];
  final delayed = spellFromElements(
    elements: elements,
    variant: 93,
    name: 'Patient Ruin',
  );
  final immediate = spellFromElements(
    elements: elements,
    variant: 94,
    name: 'Sudden Ruin',
  );

  const target = HexCoord(1, 0);
  const delay = 1;
  // Fixed, not random: a replayable script cannot contain entropy the golden
  // does not also contain.
  final delayedNonce = Uint8List.fromList(List.generate(16, (i) => i + 31));
  final delayedCommitment = await PendingDelayedSpell.commitmentHash(
    target: target,
    delay: delay,
    nonce: delayedNonce,
  );
  final immediateNonce = Uint8List.fromList(List.generate(16, (i) => i + 61));
  final immediateCommitment = await PendingDelayedSpell.commitmentHash(
    target: target,
    delay: 0,
    nonce: immediateNonce,
  );

  return MatchScript(
    name: 'mystery_fizzle_is_not_a_free_cast',
    description:
        'A 10-mana wizard commits two 34-mana Mystery casts, one delayed and '
        'one immediate. Both fizzle at Phase-5 settlement. Pins M4.21: the '
        'delayed one queues no PendingDelayedSpell and therefore never fires, '
        'and the immediate one is suppressed by the flag its conversion now '
        'carries. Nothing is charged and nothing lands.',
    // Well below the 34 either cast prices at. Both wizards get the same pool;
    // player_b never casts, so only player_a's matters.
    startingMana: 10,
    localChapterCommitments: [
      delayed.commitmentHex,
      immediate.commitmentHex,
    ],
    peerChapterCommitments: const [],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a declares a Mystery (delay 1) it cannot afford — the '
            'turn is spent, the chain regresses, and NO pending spell is '
            'written',
        local: TurnInput(
          action: MysterySpellCastAction(
            spell: delayed,
            mysteryCommitment: delayedCommitment,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'the turn the delay would have elapsed on. Nothing to reveal, '
            "because nothing was queued — if player_b's HP moves here, the "
            'declaration-side repair has regressed',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'player_a fires an immediate Mystery (delay 0) it still cannot '
            'afford — the conversion carries the fizzle flag, so no damage',
        local: TurnInput(
          action: MysterySpellCastAction(
            spell: immediate,
            mysteryCommitment: immediateCommitment,
            immediateTarget: target,
            immediateNonce: immediateNonce,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'quiet turn — a fizzled cast must leave nothing behind, on '
            'either device',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}

/// A Slow tile drains the caster below their own spell's price, mid-turn.
///
/// The corpus's record of M4.10b's temporal rule: **a committed spell reserves
/// nothing, and is priced from the state that exists at the start of Phase 5.**
///
/// ## Why this one is worth a script
///
/// It is the only demonstration of that rule that needs no status effects at
/// all — just terrain, a walk, and a pool close enough to a price that ten mana
/// decides it. Under the pre-M4.10b engine this exact transcript desynced: the
/// caster's own device had already charged the spell at Phase 1 (25 − 20 = 5,
/// then the drain clamped it to 0) and RESOLVED it, while the opponent's device
/// drained first (25 − 10 = 15), priced at 20 > 15, and fizzled it. Two devices,
/// one transcript, different turns — the state hash caught it and the duel
/// ended. Both now fizzle.
///
/// ## Why it takes three casts to set up
///
/// A wizard cannot walk onto a Slow tile at base speed. The tile a spell makes
/// costs `1 + extraMoveCost` = 3 movement, and [_kBaseMoveSpeed] is 2, so the
/// step is simply refused. Entering one voluntarily requires a haste — which is
/// why turn 1 spends player_a's action on `[air, air, air]` (+1 speed, 3 turns)
/// aimed at their own tile, and player_b's on the tile itself.
///
/// That is not scaffolding, it is the finding: the SlowTile race is only
/// reachable by a hasted caster, and it took building the script to notice.
MatchScript _slowTileDrainsACastIntoAFizzle() {
  // Flavour is the FIRST element of the triplet; the pair (2nd, 3rd) picks the
  // kind (effect_kind.dart's effectKindFromPair). So [air, air, air] is an
  // Air-flavoured Air-Air speed manipulation (+1 speed, 3 turns), and
  // [water, earth, water] a Water-flavoured Earth-Water tile modification,
  // which is the SlowTile (effect_resolver.dart).
  final haste = spellFromElements(
    elements: const [BorderZone.air, BorderZone.air, BorderZone.air],
    variant: 90,
    name: 'Quickening',
  );
  final slowTile = spellFromElements(
    elements: const [BorderZone.water, BorderZone.earth, BorderZone.water],
    variant: 91,
    name: 'Clinging Mire',
  );
  final marginal = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 92,
    name: 'Last Ember',
  );

  return MatchScript(
    name: 'slow_tile_drains_a_cast_into_a_fizzle',
    description:
        'A hasted caster walks through a Slow tile on the turn they cast, and '
        'the 10 mana it drains takes them below their own spell price. Pins '
        "M4.10b's rule that a committed cast is priced at Phase 5 from live "
        'state, not reserved at Phase 1 — the transcript that used to desync.',
    // Low enough that one Slow tile decides the second cast. 45 pays for turn
    // 1 (20) and leaves 25, which covers the turn-2 cast at commit time and
    // does not cover it after the drain.
    startingMana: 45,
    localChapterCommitments: [haste.commitmentHex, marginal.commitmentHex],
    peerChapterCommitments: [slowTile.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a hastes itself; player_b lays a Slow tile beside it',
        local: TurnInput(
          action: SpellCastAction(spell: haste, targetHex: const HexCoord(0, 0)),
        ),
        peer: TurnInput(
          action:
              SpellCastAction(spell: slowTile, targetHex: const HexCoord(0, 1)),
        ),
      ),
      ScriptedTurn.fixed(
        note: 'player_a walks through the mire and casts — the drain fizzles it',
        local: TurnInput(
          action:
              SpellCastAction(spell: marginal, targetHex: const HexCoord(1, 0)),
          movePath: const [HexCoord(0, 1)],
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'quiet turn — a fizzled cast must leave nothing behind either',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
    ],
  );
}

/// A Mystery claimed on a spell whose proof does not back it — the match ends.
///
/// ## Why the corpus needed a forfeit at all
///
/// Every other script asks "does the engine compute the right thing?". This one
/// asks the question the trust boundary actually turns on: **does the engine
/// refuse?** Those are different code paths and only one of them was covered.
/// A refactor that moved verification after resolution, or dropped a claim from
/// the check, or forfeited on the wrong device, would leave every existing
/// golden byte-identical — resolution is unchanged for honest play — while
/// silently opening the hole the check exists to close.
///
/// ## Why `unbacked_enhancement_claim` rather than a duplicate grid
///
/// The duplicate-grid guard is a *bookkeeping* check: it compares a commitment
/// against a set this device already built. `unbacked_enhancement_claim` is a
/// *semantic* one — it re-derives what the SNARK actually certified
/// (`TrajectoryParser.certifiedSupremeTags`) and confronts the peer's wire
/// claim with it. That makes it the same B-1 trust-boundary shape as the rest
/// of the corpus, and it is the check with real reach: Potency, Velocity,
/// Efficiency and Mystery are all gated by the one branch at
/// turn_loop.dart's step 2b, so pinning one of them pins the branch.
///
/// ## What makes the fixture illegal
///
/// `spellFromElements` marks every generation supreme-dominant, so the
/// certified tag set is exactly the set of elements in the trajectory. A
/// `[fire, fire, fire]` spell therefore certifies `{fire}` — enough to back a
/// Potency claim, and *not* enough to back a Mystery, which requires certified
/// supreme dominance in the **earth** zone because that is what buys the
/// delay. Casting it as a `MysterySpellCastAction` is exactly the modified
/// client the check is written against: nothing about the proof is forged, the
/// peer simply claims an enhancement it did not earn.
///
/// Note that only the RECEIVING device objects. `TurnLoop` has no check on the
/// local player's own enhancement claims — the UI declines to offer the button
/// (battle_screen.dart) but the engine does not second-guess itself, which is
/// the correct division: a client cannot be trusted to police itself, so the
/// enforcement that matters is the peer's.
///
/// ## The three things this pins that state hashes cannot
///
///   1. **The forfeit fires at all, with that tag, from player_b's device.**
///   2. **The turn aborts before resolving anything** —
///      `detectorStateUnchangedApartFromTurnCounter` is the assertion, and it
///      is a real one: verification sits at Phase 5, after movement has already
///      been applied, so a script that moved on this turn would legitimately
///      record `false`. Neither side moves, so any `false` here means
///      resolution leaked in ahead of the check.
///   3. **No later turn runs.** Turn 3 would take 4 HP off player_a if it ever
///      executed; `turnsNotRun: 1` and its absence from the golden are the
///      record that it did not.
Future<MatchScript> _unbackedMysteryClaimForfeits() async {
  // Turn 1: an ordinary, fully-backed cast. The match must be genuinely under
  // way before the violation, so the golden shows the forfeit interrupting a
  // live match rather than failing at the first thing the engine ever did.
  final opener = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 70,
    name: 'Opening Ember',
  );
  // Turn 2: certifies {fire}. Legal as an immediate cast; illegal as a Mystery.
  final unbacked = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 71,
    name: 'Borrowed Patience',
  );
  // Turn 3: never cast. Present so that "the match stopped" is distinguishable
  // from "the script ran out of turns" — this one would visibly damage
  // player_a, so its absence from the transcript is evidence rather than
  // assumption.
  final neverCast = spellFromElements(
    elements: List.filled(3, BorderZone.fire),
    variant: 72,
    name: 'Reply That Never Comes',
  );

  const target = HexCoord(1, 0);
  const delay = 1;
  final nonce = Uint8List.fromList(List.generate(16, (i) => i + 131));
  final commitment = await PendingDelayedSpell.commitmentHash(
    target: target,
    delay: delay,
    nonce: nonce,
  );

  return MatchScript(
    name: 'unbacked_mystery_claim_forfeits',
    description:
        'player_a casts an honest spell, then declares a Mystery on a spell '
        'whose proof certifies supreme dominance only in fire — no earth, so '
        'nothing backs the delay. player_b re-derives the certified tags, '
        'rejects the cast and forfeits with unbacked_enhancement_claim. Pins '
        'that the semantic enhancement check fires, that it fires on the '
        "receiving device, that the turn aborts before resolving anything, "
        'and that no later turn runs.',
    localChapterCommitments: [
      opener.commitmentHex,
      unbacked.commitmentHex,
    ],
    peerChapterCommitments: [neverCast.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'an ordinary backed cast — the match is live and in lockstep',
        local: TurnInput(
          action: SpellCastAction(spell: opener, targetHex: target),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'player_a claims Mystery on a fire-only proof; player_b rejects '
            'it and forfeits. Neither side moves, so nothing but the turn '
            'counter may change on the detecting device',
        local: TurnInput(
          action: MysterySpellCastAction(
            spell: unbacked,
            mysteryCommitment: commitment,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'MUST NOT RUN — player_b answering with damage. If this ever '
            "appears in the golden, the forfeit stopped nothing",
        local: TurnInput(action: PassAction()),
        peer: TurnInput(
          action: SpellCastAction(spell: neverCast, targetHex: const HexCoord(0, 0)),
        ),
      ),
    ],
  );
}

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



/// Potency's immediate bonus action, and its playback record (M4.17).
///
/// The corpus had a summon script and no *Potent* summon script, which is
/// precisely why M4.17 survived: `eventCounts` records `minionMoves` /
/// `minionAttacks` per turn, so a script that casts Potency is the one thing
/// that can pin "the bonus action is visible" as a number. Before the fix this
/// script's turn 1 would have shown one move event; it shows two.
///
/// What each turn is for:
///
///   turn 1  The Potent cast. Two creature actions in one turn — the immediate
///           bonus action from inside Phase 5, then the ordinary Phase-5b
///           sweep. The creature spawns two tiles from player_b with
///           `moveSpeed 1`, so the bonus action spends its whole budget closing
///           (a walk, no blow — see M4_findings: a creature that arrives with
///           nothing left cannot lunge) and the sweep lands the blow from
///           adjacent. `minionMoves: 2, minionAttacks: 1`.
///   turn 2  The same creature, no Potency in play: ONE action. The contrast
///           with turn 1 is the whole point — it is what distinguishes "Potent
///           grants an extra action" from "creatures act twice".
///   turn 3  A third turn, to catch an off-by-one in the cadence, exactly as
///           `_summonActsOverTurns` does.
///
/// Element sequence is `EEFFAA` — the same one `_summonActsOverTurns` uses, and
/// for the same reasons (hp 2 / dmg 1 / move 1, and it dodges every pattern in
/// `kSummonAbilityPattern`). Keeping it identical means the two goldens differ
/// only by Potency, which is what makes the diff between them readable. A
/// distinct `variant` is required regardless: the commitment is grid-only and
/// the duplicate-grid guard forfeits a peer that casts the same grid twice.
///
/// The Potency claim itself is certified — `PeerCastVerifier` forfeits an
/// `unbacked_enhancement_claim`, so the proof must attest supreme fire
/// dominance, which the fire generations in this sequence supply.
MatchScript _potentSummonActsTwice() {
  final summon = spellFromElements(
    elements: const [
      BorderZone.earth, BorderZone.earth,
      BorderZone.fire, BorderZone.fire,
      BorderZone.air, BorderZone.air,
    ],
    variant: 52,
    name: 'Quickened Sentinel',
    isSummon: true,
  );

  return MatchScript(
    name: 'potent_summon_acts_twice',
    description:
        'player_a casts a POTENT summon on turn 1, then does nothing. Covers '
        "Potency's immediate bonus action (design doc \"Summons\"): the "
        'creature acts twice on its cast turn and once per turn thereafter, '
        'and BOTH of the cast turn\'s actions appear in the Summons-phase '
        'playback stream (M4.17). Also pins the certified Potency claim across '
        'the peer boundary.',
    localChapterCommitments: [summon.commitmentHex],
    turns: [
      ScriptedTurn.fixed(
        note: 'player_a casts a Potent summon two tiles from player_b; the '
            'creature closes on its bonus action and strikes on the sweep',
        local: TurnInput(
          action: SpellCastAction(
            spell: summon,
            targetHex: const HexCoord(2, 1),
            isPotent: true,
          ),
        ),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'nobody acts — the creature takes its ONE ordinary action, which '
            'is the contrast that makes turn 1 mean something',
        local: TurnInput(action: PassAction()),
        peer: TurnInput(action: PassAction()),
      ),
      ScriptedTurn.fixed(
        note: 'a third turn, to catch a cadence that is off by one',
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
