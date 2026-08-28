// SPDX-License-Identifier: GPL-3.0-or-later
//
// deterministic_resolution.dart — battle resolution that depends on nothing
// but the battle state, its inputs, and a seeded RNG.
//
// ## Why this file exists
//
// `turn_loop.dart` is ~7.8k lines and mixes three unrelated jobs: network
// sequencing (commit-reveal exchanges, pacing, forfeits), trust validation
// (proof intake, certified-trajectory checks), and the actual rules of the
// game. Only the third is deterministic, and only the third is what the
// replay corpus in `test/battle/replay/` pins. Separating them is the highest-
// value refactor available (August 2026 architecture review §5).
//
// This is the first piece carved off, and the seam the rest is meant to grow
// into. The rule for what belongs here:
//
//   **No `session`. No `await`. No callbacks into the host.** A method here is
//   a function of `(state, arguments, rng)` and its effects are mutations to
//   `state` plus events appended to sinks the caller owns.
//
// End of turn was taken first precisely because it is the only phase that
// already met that bar with nothing shaved off: it has no network exchange in
// the middle of it and no UI playback hook, so moving it could not change
// ordering, scheduling, or the number of suspension points in a turn.
//
// ## Phases that suspend: split, don't smuggle
//
// The Summons phase (5b) came second, and it *does* suspend — there is a host
// playback callback in the middle of it, awaited so the tokens finish walking
// before anything is reaped. The obvious move would have been to hand that
// callback to this class. That was rejected: a callback parameter would make
// this file async, give it a host dependency, and — worst — put a suspension
// point *inside* a deterministic method, where a caller could interleave
// anything at all with a half-resolved phase.
//
// The alternative turned out to be available and is the pattern to reach for
// again: **look at what the callback actually separates.** In Phase 5b it
// separates nothing. The AI sweep decides everything — every step, every blow,
// every death — and the aftermath (reap, phoenix, dispel) reads only state the
// sweep already wrote. The callback sits between two runs of inert ground, and
// it only animates. So the phase splits into two synchronous calls,
// [DeterministicResolution.resolveSummonActions] and
// [DeterministicResolution.resolveSummonAftermath], with the await left in
// TurnLoop between them. Same single suspension point, same place, same RNG
// stream — and no decision is made on both sides of the callback, because the
// second call makes none.
//
// A phase where that is NOT true (the callback's *result* feeds a later
// decision, as in the free-move rounds, which ask the peer what it did) cannot
// be split this way and should not be forced. Action resolution (5) was
// described here as the hard one — "it suspends repeatedly, for peer
// verification, and the answers change what resolves". That turned out to be a
// misreading of where the verification sat: it all happens *before* resolution
// begins, and the only thing left suspending mid-resolution is one forced-cast
// exchange. See "The one await" below.
//
// ## Not every phase is a unit of extraction
//
// The free-move rounds (5.5/6.5) came fourth and are the case that settled the
// shape of this file. They are exactly the phase the paragraph above says
// cannot be split: prompt → commit → reveal → verify → apply, with the peer's
// answer deciding the second application. So the *phase* stayed in TurnLoop
// and the deterministic *operations* it drives came across on their own —
// [freeMoveGrantFor], [boostMoveCost], [freeMoveCandidates], [applyFreeMove].
// None of them is phase-shaped; each is a function of state that any caller
// can reach, and three of them already had callers outside the phase (the UI
// prices and highlights a grant it must agree with byte for byte).
//
// That is the rule going forward. This class is **not** a destination for
// TurnLoop phases; it is where reusable deterministic operations live —
// state-derived decisions, state mutations, seeded RNG behaviour, and the
// event records describing what happened. TurnLoop keeps protocol and
// orchestration: phase order, prompts, commit/reveal, trust checks,
// presentation callbacks, and every suspension point. Do not invent a
// `resolveFreeMoveRound` (or any other phase-shaped entry point) for symmetry
// with `resolveEndOfTurn` — end of turn is phase-shaped because that phase
// happens to be one operation, not because phases are the unit here.
//
// Avatar movement (Phase 3) came third and needed no split at all: its
// playback callback is the *last* thing in the phase, with nothing after it to
// decide, so the whole phase is one synchronous method and the await stays put
// in TurnLoop directly after it.
//
// ## Event sinks are parameters, not fields
//
// `TurnLoop` reassigns its `lastConveyorChainEvents` / `lastWildMagicEvents`
// lists at the top of every turn, and several phases append to the same list
// across the turn. Owning copies here would have changed either the ordering
// or the identity of those lists, so the sinks are passed in instead: the
// appends land in the same list, in the same order, at the same moment they
// always did. That also makes this genuinely callable on its own — a caller
// with no TurnLoop at all passes fresh lists and reads what came out.
//
// ## The one await, and why it does not break the rule
//
// Action resolution (Phase 5) came fifth, and it is the exception the header
// rule above is stated against: [DeterministicResolution.resolveActions] and
// [DeterministicResolution.applySpell] are `async`. That is not a softening of
// "no callbacks into the host" — it is one named callback, at one point, doing
// one thing this side of the seam cannot do.
//
// Spontaneous Combustion forces its victims to reveal and cast from a hand
// whose CONTENTS are private to the other device, so resolving it needs a
// network round trip (WILD_MAGIC_PLAN.md §9.5). No rearrangement removes that:
// unlike the Phase 5b playback callback, the exchange's *result* is the spell
// that then resolves, so the phase cannot be split around it. It was already
// abstracted behind `ForcedCastHost` before the move; here it is reached as
// [ActionResolutionHost.drainForcedCasts] and it is the only `await` in this
// file. Everything either side of it is the same synchronous sequencing it
// always was.
//
// The test for whether a future phase may do the same: the suspension must be
// an *effect's* protocol need, reached through a named host member, with no
// trust decision on this side of it. Phase 5 qualifies because every check that
// can reject — proof verification, book membership, the mystery commitment, the
// delayed-fire match — now runs before `resolveActions` is called and arrives
// as data.
//
// ## What is NOT here yet
//
// Phase 0 (artifact activation) came seventh and last of the deterministic
// islands, as operations again — see the "Phase 0" section below for the one
// interesting wrinkle: the bookmark burn's hand redraw is device-relative, so
// the operation *returns* the redraw it owes instead of calling back for it.
//
// What remains on the other side of the seam is not rules at all: trust
// (proof intake and verification, book membership, certified-cast derivation),
// wire codecs, and the protocol sequencing that drives them. Those are
// TurnLoop's own three jobs and the next thing to look at, but none of them is
// deterministic resolution and none of them belongs in this file.

import 'dart:math' show max, min, pow;
import 'dart:typed_data';

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/counter_charm.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../models/battle_state.dart';
import '../models/casting_enhancements.dart';
import '../models/certified_cast.dart';
import '../models/creature_spec.dart'
    show CreatureSpec, ResistanceTier, SummonAbility, resistanceTierOf;
import '../models/effect_descriptor.dart'; // exports SpellAffinity
import '../models/hex_battlefield.dart'
    show MovementContest, hexDistance, hexNeighbors;
import '../models/minion.dart';
import '../models/pending_delayed_spell.dart';
import '../models/reflection_link.dart';
import '../models/status_effect_ids.dart';
import '../models/terrain.dart'
    show
        CloudObject,
        ConveyorTile,
        DustCloud,
        FloorIsLava,
        IceTile,
        MobileCloud,
        SlowTile,
        ToxicCloud,
        WaterCloud,
        tileBlocksMovement;
import '../models/wild_magic_effect.dart'
    show WildMagicEffectKind, WildMagicTrigger;
import '../models/wizard_avatar.dart';
import 'battle_events.dart';
import 'draw_schedule.dart';
import 'effect_applicator.dart';
import 'effect_resolver.dart';
import 'hash_rng.dart';
import 'line_of_sight.dart';
import 'terrain_ops.dart';
import 'tile_entry_resolver.dart';
import 'peer_cast_verifier.dart' show PeerCastVerifier;
import 'trajectory_parser.dart' show ParsedFormula;
import 'turn_actions.dart';
import 'wild_magic_applicator.dart';

// ── Phase 0: Artifact activation ──────────────────────────────────────────────

/// The loadout artifacts a player may declare at Phase 0.
///
/// [AccoutrementKind.counterCharm] is deliberately absent — charms self-trigger
/// at Phase 5 and have no voluntary activation, which is exactly why an
/// all-charm "mage slayer" loadout is never off-guard (§2.3). The summon-only
/// kind ([AccoutrementKind.absorptionRod]) is absent because it has no
/// loadout presence at all and keeps its existing on-hit behaviour untouched.
const kActivatableArtifactKinds = <AccoutrementKind>[
  AccoutrementKind.manaGem,
  AccoutrementKind.bookmark,
  AccoutrementKind.rodOfSpreading,
];

/// Rod of Wind passive: percentage points, per carried rod, of ONE
/// roll for +1 movement (ARTIFACT_SYSTEM_PLAN.md §2.8/§3.2). Capped at 100, so
/// 10+ rods is a guaranteed extra tile every turn — an archetype-defining
/// passive parallel to the mage slayer's.
///
/// `[TODO — playtest]` — both the rate and whether that 100% cap is the
/// archetype it should be.
const _kRodMovementPctPerRod = 10;

// ── Free-move window ──────────────────────────────────────────────────────────

/// Maximum mana value — avatars are clamped to [0, _kMaxMana] after every
/// spend or gain. Mirrors `TurnLoop`'s constant of the same name so the
/// ceiling cannot diverge between the two sides of the seam.
const _kMaxMana = 9999;

/// Mana charged per chargeable tile-unit of a Watery Boost run, before the
/// `n(n+1)/2` triangular multiplier (design v3.0 §Effect Table, Air-Air).
/// One tile costs a whole innate mana pool ([MatchConfig.innateManaPool] is
/// 100) — the effect is meant to be an expensive escape, not a commute.
const kBoostManaPerTile = 100;

/// Hard ceiling on chargeable Boost tiles, independent of how deep the
/// wizard's pockets are. Triangular cost makes 5 paid tiles cost 1500 mana /
/// 15 HP already; the cap exists so
/// [DeterministicResolution.freeMoveGrantFor]'s search terminates in bounded
/// time no matter what a future mana pool looks like.
const _kMaxBoostPaidTiles = 8;

/// What the post-resolution free-move window is offering one wizard this turn:
/// an Airy Barrier's burst step, a Boost's paid run, or both at once.
///
/// Derived from state by [DeterministicResolution.freeMoveGrantFor] on *both*
/// devices — never sent over the wire. The wire carries only the path the
/// player chose, and the receiver re-derives this grant to price and validate
/// it (same trust-boundary rule as `_certifiedManaCost`: a peer's claim about
/// what it may do and what that costs is never taken at face value).
class FreeMoveGrant {
  const FreeMoveGrant({
    required this.burstStep,
    required this.boostResource,
    required this.boostFreeTiles,
    required this.maxTiles,
  });

  static const none = FreeMoveGrant(
    burstStep: false,
    boostResource: null,
    boostFreeTiles: 0,
    maxTiles: 0,
  );

  /// An Airy Barrier burst this turn: one adjacent step, free
  /// (see [WizardAvatar.pendingFreeMoveBurst]).
  final bool burstStep;

  /// A Boost resolved this turn ([WizardAvatar.pendingBoostMove]):
  /// [SpellAffinity.fire] charges HP, [SpellAffinity.water] charges mana.
  /// Null when no boost is pending.
  final SpellAffinity? boostResource;

  /// Boost tiles that cost nothing — 0 base, 1 under Potency. Stacks *after*
  /// [burstStep]'s free step.
  final int boostFreeTiles;

  /// Total movement budget on offer, already capped by what the wizard can
  /// actually pay for (see [DeterministicResolution.boostMoveCost]). 0 means
  /// nothing to offer and no prompt is shown.
  final int maxTiles;

  bool get isEmpty => maxTiles <= 0;

  /// Steps that cost nothing: the burst step plus the boost's free tiles.
  int get freeTiles => (burstStep ? 1 : 0) + (boostResource == null ? 0 : boostFreeTiles);
}

/// Counter Charm passive: percentage points, per unspent charm, that a
/// successful melee destroys one of the victim's mana gems or withers one of
/// their in-hand spells (ARTIFACT_SYSTEM_PLAN.md §2.3). Linear and capped at
/// 100, so a full 12-charm loadout procs 60% of the time.
///
/// `[TODO — playtest]` — 60% is only balanced if melee is hard to land against
/// a kiting mage, which is a play question, not a math one.
const _kCounterCharmProcPctPerCharm = 5;

// ── Action resolution seam ────────────────────────────────────────────────────

/// Mana a Meditate restores, main-phase or move-phase.
const kMeditateManaGain = 25;

/// Resolution groups for the Phase-5 ordering (quick / normal / sluggish).
enum _ResolutionGroup { quickSpell, normalSpell, sluggishSpell }

/// The narrow set of things action resolution needs that are **not** a function
/// of `(state, arguments, rng)`, implemented by `TurnLoop`.
///
/// This is deliberately the smallest interface that let Phase 5 cross the seam,
/// and every member is here for one of exactly three reasons:
///
///   1. **It needs to know which device this is.** [isLocalPlayer], and the
///      hand bookkeeping ([redrawHand], [reconcileHandSize]) which advances a
///      public position-only schedule for both players but real card CONTENTS
///      only for the local one.
///   2. **It reads a proof.** [certifiedFromProofBytes] parses a spell's own
///      SNARK outputs to re-derive what that proof actually certified. It only
///      *derives* — it accepts nothing and rejects nothing — but reading proof
///      bytes is the trust layer's job and it stays there. The verification
///      that can reject already ran before [DeterministicResolution.
///      resolveActions] was called, and arrives as the `certifiedPeer*` maps.
///   3. **It suspends.** [drainForcedCasts] is the single await in the whole
///      phase: Spontaneous Combustion forces its victims to reveal and cast
///      from a private hand, which is a network round trip
///      (WILD_MAGIC_PLAN.md §9.5). It is already abstracted behind
///      `ForcedCastHost`; this just names the entry point.
///
/// The seed methods are a fourth, milder case: the *domain tags* are rules and
/// live below, but the per-turn entropy, the match id and the monotonic nonce
/// counters are the host's bookkeeping. Each method here corresponds to one tag
/// and consumes one nonce, so a caller cannot accidentally share a stream.
///
/// Extends [WildMagicHooks] because the wild-magic applicator already takes one
/// and the implementer is the same object; folding it in avoids a second
/// accessor that would only ever return `this`.
abstract class ActionResolutionHost implements WildMagicHooks {
  /// True when [playerId] is this device's own player.
  bool isLocalPlayer(String playerId);

  /// Wizard or sorcerer, for [CastingEnhancements].
  GameMode get componentsGameMode;

  /// The full certified semantics of [spell], re-derived from proof bytes this
  /// device already holds. Null when there are no proof bytes (the
  /// `kAllowProoflessSpells` dev flag) or they are malformed — both devices see
  /// the same absence and fall back identically, so it is desync-safe.
  CertifiedCast? certifiedFromProofBytes(SpellAsset spell);

  /// Seed for a caster's FuelTransmutation wither/reactivate RNG (tag 0x06).
  Uint8List witherSeed(Uint8List entropy, String playerId);

  /// Seed for one Rippling Reflections coin flip (tag 0x0A).
  Uint8List ripplingSeed(Uint8List entropy, String playerId);

  /// Seed for one Watery Inertia distance roll (tag 0x0B).
  Uint8List turbulentSeed(Uint8List entropy, String playerId);

  /// Seed for one wild-magic trigger (tag 0x09).
  Uint8List wildMagicSeed(Uint8List entropy, String playerId);

  /// Scattered Gusts: re-deal [playerId]'s whole hand at its current size.
  void redrawHand(String playerId, Uint8List entropy);

  /// A bookmark gained or lost mid-resolution resized [playerId]'s hand.
  void reconcileHandSize(
    String playerId,
    int beforeCount,
    int afterCount,
    Uint8List entropy,
  );

  /// Runs every forced cast queued during the wild-magic sweep, each through
  /// its full public-slot-selection → reveal → verify → resolve sequence.
  Future<void> drainForcedCasts(Uint8List entropy);
}

/// The turn-scoped things a cast writes to, bundled so they do not have to be
/// threaded through a dozen parameters each.
///
/// Constructed fresh by the caller for each turn, which is what preserves the
/// "event sinks are parameters, not fields" rule this file's header states:
/// `TurnLoop` reassigns its `lastX` lists at the top of every turn, and this
/// object captures whichever lists are current, so appends land in the same
/// list, in the same order, at the same moment they always did.
class ActionResolutionContext {
  const ActionResolutionContext({
    required this.host,
    required this.entropy,
    required this.drawSchedules,
    required this.castEvents,
    required this.resolvedSpells,
    required this.conveyorChainEvents,
    required this.wildMagicEvents,
    required this.minionMoveEvents,
    required this.minionAttackEvents,
  });

  final ActionResolutionHost host;

  /// This turn's joint commit-reveal entropy, the root of every seed above.
  final Uint8List entropy;

  /// The public per-player hand bookkeeping. Mutated in place by
  /// [EffectApplicator] (FuelTransmutation wither/reactivate), so this must be
  /// the caller's live map, not a copy.
  final Map<String, DrawSchedule> drawSchedules;

  final List<SpellCastEvent> castEvents;
  final List<ResolvedSpellEvent> resolvedSpells;
  final List<ConveyorChainEvent> conveyorChainEvents;
  final List<WildMagicEvent> wildMagicEvents;

  /// A Potent summon's immediate bonus action appends to these during Phase 5;
  /// [resolveSummonActions] appends the ordinary sweep to the SAME two lists in
  /// Phase 5b. Both are the caller's live per-turn lists, never replaced
  /// mid-turn, so what the UI plays back is one chronological timeline —
  /// bonus action first, sweep after. See `TurnLoop.lastMinionMoveEvents`
  /// and docs/M4_findings.md M4.17 for the version of this that dropped the
  /// bonus action on the floor.
  final List<MinionMoveEvent> minionMoveEvents;
  final List<AttackEvent> minionAttackEvents;
}

// ── Summon AI target ──────────────────────────────────────────────────────────

/// One resolved AI target for a creature's turn: a position plus whichever
/// of avatar/minion is the actual entity there.
class _AiTarget {
  const _AiTarget({required this.position, this.avatar, this.minion});
  final HexCoord position;
  final WizardAvatar? avatar;
  final Minion? minion;
}

/// Battle resolution that runs identically on both devices, given the same
/// state and the same seeded RNG.
///
/// Holds [state] and nothing else — no session, no identity, no local-player
/// notion. Anything that needs to know *which device it is* is by definition
/// not deterministic resolution and belongs on the caller's side of the seam.
class DeterministicResolution {
  DeterministicResolution(this.state);

  final BattleState state;

  // ── Phase 0: Artifact activation ──────────────────────────────────────────
  //
  // Seventh across the seam, and the last phase-shaped deterministic island
  // TurnLoop held. Phase 0 is a commit-reveal round whose *result* decides what
  // is applied, so — like the free-move window and the melee round — the phase
  // itself cannot come across; only its operations do. What a wizard may
  // declare ([activatableKinds]), whether a declaration is really spendable
  // ([validateActivation], the Phase-0 trust boundary), what spending it does
  // ([applyArtifactActivation]), and the Rod of Wind's per-turn movement roll
  // ([applyRodMobilityRoll]) are all functions of state. TurnLoop keeps the
  // picker, both exchanges, the reveal verification, and the sorted order the
  // two applications run in.
  //
  // The bookmark burn is the one effect that does not finish here: re-dealing a
  // hand touches TurnLoop's draw schedules *and* `localSpellDraw` — the
  // contents of a hand that are private to one device, i.e. exactly the "which
  // device is this" knowledge this class refuses to have. Rather than take a
  // host callback for it, [applyArtifactActivation] returns the hand size the
  // burner must be re-dealt at and TurnLoop performs the redraw immediately
  // after. That is the Phase-5b split applied to a host call instead of a
  // playback callback: nothing after the redraw decides anything, so cutting
  // there costs no ordering.

  /// The artifact kinds [av] could legally declare right now: the
  /// [kActivatableArtifactKinds] they actually carry at least one of.
  List<AccoutrementKind> activatableKinds(WizardAvatar av) => [
    for (final kind in kActivatableArtifactKinds)
      if (av.accoutrements.any((a) => a.kind == kind)) kind,
  ];

  /// **The Phase-0 trust boundary** (ARTIFACT_SYSTEM_PLAN.md §5), and the only
  /// one — the local player's own declaration goes through this same call, so
  /// there is never a second, laxer path (the B-1/B-8 lesson).
  ///
  /// Returns [declared] if [av] may really spend it this turn, else null. A
  /// rejected declaration degrades to no-activation rather than forfeiting:
  /// both devices run this check against the same state and reach the same
  /// verdict, and a desync here would be indistinguishable from a stale
  /// client, so a silent discard is the honest outcome.
  AccoutrementKind? validateActivation(
    WizardAvatar av,
    AccoutrementKind? declared,
  ) {
    if (declared == null) return null;
    // A dead wizard spends nothing. Both devices agree on who is alive at
    // Phase 0 (nothing has resolved yet this turn), so this is safe to gate on.
    if (!av.isAlive) return null;
    // Never counterCharm (charms self-trigger), never a summon-only kind.
    if (!kActivatableArtifactKinds.contains(declared)) return null;
    // At most one activation per player per turn.
    if (av.declaredActivation != null) return null;
    // A peer cannot spend what it does not hold. No sub-filter for manaGem:
    // every gem is consumable now that the indestructible core gem is gone,
    // including the last one (§2 derived rulings).
    if (!av.accoutrements.any((a) => a.kind == declared)) return null;
    return declared;
  }

  /// Records [kind] as [av]'s activation for this turn and applies whatever
  /// takes effect immediately. Null is a no-op — [av] declared nothing, or
  /// their declaration failed [validateActivation].
  ///
  /// Returns the hand size [av] must be re-dealt at, or null when no redraw is
  /// owed: burning a bookmark re-deals its owner's hand one slot smaller, and
  /// that redraw is the caller's to run (see this section's header). Every
  /// other activation returns null.
  ///
  /// Not every activation resolves here: the Rod of Wind's *activation* is
  /// still realised at cast time by [_consumeRodOfSpreading] (single
  /// rod-consumption path; its movement *passive* is unrelated and rolled by
  /// [applyRodMobilityRoll]). Mana gem and bookmark both resolve instantly —
  /// amended 2026-07-31, ARTIFACT_SYSTEM_PLAN.md §2.7's original "resolves at
  /// Phase 6, new hand next turn" is superseded, see `TurnLoop
  /// .beginArtifactEntropy`'s doc comment for why.
  int? applyArtifactActivation(WizardAvatar av, AccoutrementKind? kind) {
    if (kind == null) return null;
    av.declaredActivation = kind;

    switch (kind) {
      case AccoutrementKind.manaGem:
        // Order is load-bearing (ARTIFACT_SYSTEM_PLAN.md §6.2): shrink the
        // pool FIRST, then grant. maxMana is stored state, not a live
        // derivation, so removing the gem alone would leave a stale pool and
        // desync the state hash — hence _syncMaxMana rather than an open-coded
        // `maxMana -= 100`. Granting after the shrink is what makes the burst
        // worthless at near-full mana: this is an emergency button, not free
        // value. Spending your LAST gem is legal and drops you to the innate
        // pool with zero passive regen — a real, self-inflicted cost, which is
        // exactly the trade this activation is meant to be.
        _consumeAccoutrement(av, AccoutrementKind.manaGem);
        _syncMaxMana(av);
        applyManaGain(av, state.config.manaGemPoolPerGem);
        return null;

      case AccoutrementKind.bookmark:
        // Burned AND redrawn immediately, both in this same Phase-0 step —
        // the new hand is available for THIS turn's own action choice, using
        // the dedicated artifact entropy rather than this turn's main
        // entropy (which doesn't exist yet this early in the turn). §2.7's
        // price is now just the permanent hand slot; the tempo cost is gone.
        // The count is read AFTER the burn, so the returned size is already
        // one slot smaller.
        _consumeAccoutrement(av, AccoutrementKind.bookmark);
        return av.bookmarkCount + 1;

      case AccoutrementKind.rodOfSpreading:
        // Not consumed here: _consumeRodOfSpreading remains the single
        // consumption path, and it runs at cast time so a declared rod that
        // never gets spent (no cast, a fizzle, a counter) is not destroyed —
        // only the activation budget is wasted.
        return null;

      case AccoutrementKind.counterCharm:
      case AccoutrementKind.absorptionRod:
        // Unreachable: validateActivation rejects these kinds. Listed
        // exhaustively so adding an AccoutrementKind is a compile error here
        // rather than a silent no-op.
        return null;
    }
  }

  /// Rolls [av]'s Rod of Wind movement passive for this turn: one roll at
  /// min(rods × [_kRodMovementPctPerRod], 100)%, not one roll per rod (§3.2).
  ///
  /// [rng] is seeded per-player by the caller from the turn's dedicated
  /// Phase-0 entropy, so each avatar's roll is an independent stream and the
  /// order this is called in cannot change any outcome. A dead or rodless
  /// avatar draws nothing at all.
  ///
  /// `remainingTurns: 1` is genuinely one-shot: the status is read by THIS
  /// turn's movement sizing and ticked away by this same turn's Phase 6 — it
  /// does not carry over. That is correct; a fresh roll happens every turn.
  void applyRodMobilityRoll(WizardAvatar av, HashRng rng) {
    if (!av.isAlive) return;
    final rods = av.rodOfSpreadingCount;
    if (rods == 0) return;
    final chancePct = min(rods * _kRodMovementPctPerRod, 100);
    if (rng.nextInt(100) < chancePct) {
      _addStatus(av, StatusEffectId.rodMobility, {'speedDelta': 1}, 1);
    }
  }

  // ── Phase 3: Avatar movement ──────────────────────────────────────────────
  //
  // Third across the seam, and the same shape as Phase 5b: TurnLoop resolves
  // the walk, awaits its playback callback, and continues. The difference is
  // that here there was nothing to split — every decision the phase makes is
  // made by [resolveAvatarMovement], and the callback is the last thing that
  // happens. So the whole phase moves as one method and the `await
  // onMovementResolved` stays exactly where it was, immediately after it.
  //
  // [_walkAvatar] is private again now that the free-move window (Phase
  // 5.5/6.5) has crossed the seam too — the movement phase and [applyFreeMove]
  // are its only callers and both live here. [_breakStatuesque] went private
  // with it once Phase 5 arrived: a *cast* also breaks the latch, which used to
  // mean a public entry point plus a one-line delegator in TurnLoop, and now
  // just means a second caller in this file.

  /// Resolves this turn's avatar movement: a deterministic (no-RNG)
  /// collision preview -- Battlefield.resolveMovement's naive walk +
  /// contested-tile arbitration, ignoring conveyor tiles, just to decide who
  /// wins a contested destination -- then a full terrain-aware walk
  /// ([_walkAvatar]) for each avatar from their real origin, along the
  /// arbitrated path the preview cleared them for. A collision loser walks
  /// their declared path minus the tile(s) they were pushed back off, so
  /// they stop one tile short rather than forfeiting the whole move.
  /// Returns each avatar's actually-walked path, for knockback's move-path
  /// bounce reference.
  ///
  /// One [AvatarMoveEvent] per avatar is appended to [moveEvents] (in
  /// `state.avatars` order) for the caller to play back, and conveyor pushes
  /// picked up mid-walk land in [conveyorChainEvents]; both sinks belong to the
  /// caller and are shared across the turn — see this file's header.
  Map<String, List<HexCoord>> resolveAvatarMovement({
    required Map<String, List<HexCoord>> movePaths,
    required Map<String, int> speeds,
    required HashRng rng,
    required List<AvatarMoveEvent> moveEvents,
    required List<ConveyorChainEvent> conveyorChainEvents,
  }) {
    // Snapshot of every body on the board before anyone moves. Movement is
    // simultaneous, so both the arbitration preview and each avatar's real
    // walk resolve against this one fixed set rather than against positions
    // that mutate as the loop below walks each avatar in turn -- otherwise the
    // first player in iteration order could walk through a tile the second
    // player is about to vacate, and the second could not. See [tileOccupied].
    final bodies = _occupiedTiles();
    final preview = state.battlefield.resolveMovement(
      movePaths,
      speeds,
      tileEffects: state.tileEffects,
      flyingPlayerIds: {
        for (final av in state.avatars)
          if (av.isFlying) av.playerId,
      },
      blockedTiles: bodies,
    );
    final walked = <String, List<HexCoord>>{};
    for (final av in state.avatars) {
      final origin = av.position;
      // Everyone else's body. Rebuilt per avatar so nobody blocks themselves.
      final blockers = bodies.difference({origin});
      final budget = max(0, speeds[av.playerId] ?? av.effectiveMoveSpeed);
      // Fall back to the declared path only for an avatar the battlefield
      // didn't know about (absent from occupancy, so absent from the preview).
      final clearedPath = preview.paths[av.playerId] ??
          movePaths[av.playerId] ??
          const <HexCoord>[];
      final path = _walkAvatar(
        av,
        origin,
        clearedPath,
        budget,
        rng,
        conveyorChainEvents: conveyorChainEvents,
        blocked: blockers.contains,
      ).path;
      // Statuesque (wild magic, row 3 Earth) breaks on a VOLUNTARY move. A
      // path longer than [origin] means at least one declared step was taken;
      // involuntary displacement (knockback, ice slide, Zephyr) happens
      // elsewhere and deliberately does not break the latch. A conveyor push
      // appended to a voluntary step is already a move they chose to make.
      if (path.length > 1) _breakStatuesque(av.playerId);
      av.position = path.last;
      state.battlefield.occupancy[av.playerId] = path.last;
      walked[av.playerId] = path;
      moveEvents.add(_moveEventFor(av.playerId, path, preview.contests));
    }
    return walked;
  }

  /// Builds one avatar's UI movement record from their real walked [path] and
  /// this turn's arbitration [contests]. Cosmetic only — see [AvatarMoveEvent].
  ///
  /// A player pushed back repeatedly appears in several contests; the FIRST one
  /// they lost is the one they visibly reached furthest for, so that's the tile
  /// the token lunges at. The lunge is dropped unless the walk actually ended
  /// next to that tile: a conveyor or ice slide can carry the avatar somewhere
  /// unrelated afterwards, and recoiling onto a tile they're nowhere near would
  /// read as a rendering bug rather than as a collision.
  AvatarMoveEvent _moveEventFor(
    String playerId,
    List<HexCoord> path,
    List<MovementContest> contests,
  ) {
    HexCoord? lunge;
    HexCoord? won;
    for (final contest in contests) {
      if (!contest.contestants.contains(playerId)) continue;
      if (contest.winnerId == playerId) {
        won ??= contest.tile;
      } else {
        lunge ??= contest.tile;
      }
    }
    if (lunge != null && hexDistance(path.last, lunge) != 1) lunge = null;
    // Likewise: a "win" the avatar didn't actually end up standing on (terrain
    // moved them on afterwards) has nothing to mark.
    if (won != null && path.last != won) won = null;
    return AvatarMoveEvent(
      playerId: playerId,
      path: List.unmodifiable(path),
      lungeTile: lunge,
      wonContestAt: won,
    );
  }

  /// Walks [declaredPath] from [origin] for [av], tile by tile, up to
  /// [budget] movement points: ImpassableTile blocks; SlowTile costs
  /// 1 + [SlowTile.extraMoveCost] and drains mana on entry; FloorIsLava
  /// damages per tile entered; and ConveyorTile pushes *immediately* --
  /// cascading, possibly into a closed loop (tile_entry_resolver.dart) --
  /// with [av] then continuing to walk the rest of [declaredPath] from
  /// wherever the push left it, using whatever budget remains (a push
  /// itself is free -- it doesn't consume budget). Returns every tile
  /// actually visited, in order, starting with [origin], alongside how much
  /// of [budget] the walk consumed -- the free-move window prices a Boost run
  /// off `spent`, so tiles a conveyor or ice slide handed over for free
  /// correctly cost nothing.
  ///
  /// [blocked] reports tiles held by another body (see [tileOccupied]); a step
  /// into one stops the walk, because bodies are exclusive. A flying wizard
  /// (Updraft) is the design's one exception: it walks *through* other
  /// entities and is only pulled back if it would come to rest on one, which
  /// is the truncation after the loop. The caller supplies the predicate
  /// rather than this reading live positions, so the simultaneous movement
  /// phase can resolve every avatar against one pre-move snapshot.
  ///
  /// Private: every caller — the movement phase and the free-move window —
  /// now lives on this side of the seam.
  ({List<HexCoord> path, int spent}) _walkAvatar(
    WizardAvatar av,
    HexCoord origin,
    List<HexCoord> declaredPath,
    int budget,
    HashRng rng, {
    required List<ConveyorChainEvent> conveyorChainEvents,
    bool Function(HexCoord)? blocked,
  }) {
    var current = origin;
    var remaining = budget;
    final path = <HexCoord>[origin];
    bool isBlocked(HexCoord hex) =>
        hex != origin && (blocked?.call(hex) ?? false);

    // Updraft (wild magic, row 2 Air): a flying wizard ignores terrain
    // entirely — chasms, walls, lava, slow tiles, ice sliding, and conveyor
    // pushes (A11). Same semantics SummonAbility.flying already gives spirit
    // minions, and the `flying:` flag resolveTileEntry already takes.
    final flying = av.isFlying;

    for (final step in declaredPath) {
      if (remaining <= 0 || !av.isAlive) break;
      if (!state.battlefield.isInBounds(step)) break;
      if (hexDistance(current, step) != 1) break; // path must be step-adjacent
      final effect = flying ? null : state.tileEffects[step];
      // ChasmTile blocks movement exactly like a wall — but NOT targeting;
      // that distinction is the entire reason it is its own class (A9).
      if (tileBlocksMovement(effect)) break;
      // So does another body, unless this wizard is flying over it.
      if (!flying && isBlocked(step)) break;
      final cost = 1 + (effect is SlowTile ? effect.extraMoveCost : 0);
      if (cost > remaining) break;
      remaining -= cost;
      current = step;
      path.add(current);

      if (effect is SlowTile) {
        av.mana = (av.mana - effect.manaDrainOnEntry).clamp(0, 9999).toInt();
      }
      if (effect is FloorIsLava) {
        av.absorbDamage(effect.damage);
      }
      if (effect is IceTile) {
        // Glacier: keep going in the entry direction, FREE of movement budget
        // (A12 — mirroring ConveyorTile's free cascading push, the closest
        // existing precedent), until the next tile is out of bounds, occupied,
        // or not ice.
        current = _slideOnIce(av, path, current, rng);
      }
      if (state.tileEffects[current] is ConveyorTile &&
          (state.tileEffects[current] as ConveyorTile).directionSet &&
          !flying) {
        final outcome = resolveTileEntry(
          state: state,
          rng: rng,
          enteredTile: current,
          flying: false,
          currentHp: av.hp,
          applyEntryLava: false, // already charged just above
          moverAvatarId: av.playerId,
        );
        current = outcome.finalPosition;
        path.addAll(outcome.animationPath.skip(1));
        if (outcome.totalDamage > 0) av.absorbDamage(outcome.totalDamage);
        if (outcome.animationPath.length > 1) {
          conveyorChainEvents.add(
            ConveyorChainEvent(
              entityId: av.playerId,
              path: outcome.animationPath,
              damage: outcome.totalDamage,
              killed: outcome.killed,
            ),
          );
        }
      }
    }

    // A flying wizard walked through whatever was in the way; it may not
    // *land* on it, though, so back it off along its own route to the last
    // tile nobody is standing on. The origin is always such a tile, so this
    // terminates. Budget already spent stays spent — bumping into a crowd
    // mid-flight costs you the move, which is the point of the restriction.
    while (path.length > 1 && isBlocked(path.last)) {
      path.removeLast();
    }
    return (path: path, spent: budget - remaining);
  }

  /// Glacier's slide (wild magic, row 2 Water). [av] has just entered an
  /// [IceTile] at [current], arriving from `path[path.length - 2]`; keep
  /// stepping in that same direction, free of movement budget, until the next
  /// tile is out of bounds, occupied, or not ice.
  ///
  /// Appends every slid-through tile to [path] — knockback's
  /// bounce-back-along-your-path reference reads that list, so a slide the
  /// path doesn't record would bounce the victim to the wrong tile. Returns
  /// the final position.
  ///
  /// The iteration bound is belt-and-braces: the loop already terminates on
  /// the board edge, but a coordinate-math slip becoming an infinite loop
  /// would hang a live match mid-turn, which is much worse than stopping a
  /// slide early.
  HexCoord _slideOnIce(
    WizardAvatar av,
    List<HexCoord> path,
    HexCoord current,
    HashRng rng,
  ) {
    if (path.length < 2) return current;
    final from = path[path.length - 2];
    final delta = HexCoord(current.q - from.q, current.r - from.r);
    if (delta.q == 0 && delta.r == 0) return current;

    var pos = current;
    final maxSteps = state.config.gridRadius * 4;
    for (var i = 0; i < maxSteps; i++) {
      final next = HexCoord(pos.q + delta.q, pos.r + delta.r);
      if (!state.battlefield.isInBounds(next)) break;
      if (state.tileEffects[next] is! IceTile) break;
      if (state.avatars.any((a) => a.isAlive && a.playerId != av.playerId && a.position == next)) {
        break;
      }
      if (state.minions.any((m) => m.isAlive && m.occupiedTiles.contains(next))) {
        break;
      }
      pos = next;
      path.add(pos);
    }
    // A slide that ends ON a conveyor hands off to the normal entry
    // resolution, exactly as the conveyor path in [_walkAvatar] does — the
    // caller checks `state.tileEffects[current]` after this returns, so
    // nothing extra is needed here. (rng is threaded for symmetry with that
    // path and for any future slide-time randomness.)
    return pos;
  }

  /// Every tile a living body stands on right now — each avatar's tile and
  /// each minion's whole footprint. The blocker set for movement; see
  /// [tileOccupied], which is the same rule stated one tile at a time.
  Set<HexCoord> _occupiedTiles() => {
    for (final av in state.avatars)
      if (av.isAlive) av.position,
    for (final m in state.minions)
      if (m.isAlive) ...m.occupiedTiles,
  };

  /// Statuesque (wild magic, row 3 Earth): the latch breaks the moment a
  /// player *chooses* to move or cast. Involuntary movement (knockback,
  /// conveyor, ice slide, Zephyr) does NOT break it — "if they move" reads as
  /// a choice.
  void _breakStatuesque(String playerId) {
    state.wildMagic.statuesquePlayerIds.remove(playerId);
    state.wildMagic.pendingStatuesquePlayerIds.remove(playerId);
  }

  // ── Phase 4: Cloud drift ──────────────────────────────────────────────────

  /// Air-flavor Clouds (Water-Fire) auto-seek: move 1 tile toward the nearest
  /// enemy of the cloud owner's team during the Summons step each turn.
  void moveClouds() {
    for (final cloud in state.clouds) {
      _moveCloud(cloud);
    }
  }

  /// Single-cloud step used both by [moveClouds] (every Mobile Cloud, each
  /// turn's Phase 4) and, once, by `TurnLoop._resolveActions` right after a
  /// spell creates a new cloud (Phase 5) — otherwise a cloud born this turn
  /// would sit dead-still until *next* turn's Phase 4, since Phase 4 already
  /// ran before this turn's spells resolved. Fully deterministic
  /// (distance-only, no RNG), so it's safe to call outside the phase-seeded
  /// RNG flow — which is why it takes no [HashRng] where every other phase
  /// here does.
  void _moveCloud(CloudObject cloud) {
    if (cloud.kind is! MobileCloud) return;
    final ownerTeamId = avatarById(cloud.ownerId)?.teamId;
    if (ownerTeamId == null) return;
    final nearestEnemy = _nearestEnemyTarget(ownerTeamId, cloud.position);
    if (nearestEnemy == null) return;
    final step = _greedyStep(cloud.position, nearestEnemy);
    if (step != null) cloud.position = step;
  }

  /// Move one step from [from] toward [to], avoiding impassable tiles.
  /// Returns null if no valid step found.
  HexCoord? _greedyStep(HexCoord from, HexCoord to) {
    HexCoord? best;
    var bestDist = hexDistance(from, to);
    for (final n in state.battlefield.neighbors(from)) {
      if (tileBlocksMovement(state.tileEffects[n])) continue;
      final d = hexDistance(n, to);
      if (d < bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  HexCoord? _nearestEnemyTarget(String minionTeamId, HexCoord from) {
    final candidates = <(int dist, HexCoord pos)>[];
    for (final av in state.avatars) {
      if (!av.isAlive || av.teamId == minionTeamId) continue;
      candidates.add((hexDistance(from, av.position), av.position));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    return candidates.first.$2;
  }

  // ── Phase 4b: The melee round ─────────────────────────────────────────────
  //
  // Sixth across the seam, and the free-move pattern again rather than the
  // phase-shaped one: the *round* is prompt → commit → reveal → verify →
  // apply, so it stays in TurnLoop with every await and the canonical
  // application order. What came across is the four deterministic operations
  // the round drives — which tiles may be punched, what a punch does, whether
  // an illusion eats it, and what an attacker's charms take from whoever it
  // hit. Each is a function of `(state, arguments, rng)` and any caller can
  // reach it; none of them knows what a session is.
  //
  // The counter-charm proc's two mutable sinks — the victims' draw schedules
  // and the UI's proc log — are parameters for the reason the header gives:
  // TurnLoop owns both, reassigns the log each turn, and keys the schedules
  // map for both players, so owning copies here would change either the
  // identity of those objects or the order things land in them.

  /// Adjacent tiles holding at least one living hostile entity (enemy avatar
  /// or minion) — the melee-round prompt candidates for [actor]. Empty means
  /// no prompt is shown (see `TurnLoop.meleeTargetPicker`).
  List<HexCoord> meleeCandidates(WizardAvatar actor) {
    if (!actor.isAlive) return const [];
    final candidates = <HexCoord>[];
    for (final tile in hexNeighbors(actor.position)) {
      final hasHostile =
          _avatarsAt(
            tile,
          ).any((av) => av.teamId != actor.teamId && av.isAlive) ||
          _minionsAt(tile).any((m) => m.teamId != actor.teamId && m.isAlive);
      if (hasHostile) candidates.add(tile);
    }
    return candidates;
  }

  List<WizardAvatar> _avatarsAt(HexCoord hex) =>
      state.avatars.where((av) => av.isAlive && av.position == hex).toList();

  List<Minion> _minionsAt(HexCoord hex) =>
      state.minions.where((m) => m.isAlive && m.position == hex).toList();

  /// Returns the avatars this punch actually damaged — i.e. the ones that did
  /// NOT dodge onto an illusion decoy. That list is what makes "a *successful*
  /// melee attack" precise for the counter-charm proc
  /// ([applyCounterCharmProc]), which is applied by the caller rather than
  /// here: this method is already doing four things.
  List<WizardAvatar> applyHaymaker(
    WizardAvatar actor,
    HexCoord targetTile,
    Map<String, List<HexCoord>> walked,
    HashRng rng,
  ) {
    if (!isAdjacent(actor.position, targetTile)) return const [];

    final hitAvatars = <WizardAvatar>[];
    // Every avatar redirected onto an illusion decoy this punch — a dodge is
    // a full absorb, not just a dodge of the base damage, so every later pass
    // over this same tile (the Fire DoT sweep below) must also skip them.
    // Without the melee redirect's old position-teleport (removed 2026-07-31,
    // see _redirectIfIllusion), the real wizard stays put at [targetTile], so
    // a naive re-query by position would otherwise apply the DoT to a wizard
    // whose punch never actually landed.
    final redirected = <String>{};
    // Fire armor's melee bonus (engine v6). Added ONCE, at the single wizard
    // melee path, so it reaches a punch thrown at a wizard and a punch thrown
    // at a minion alike and reaches nothing else — spell damage is priced
    // elsewhere, and a minion's own attack never runs through here. It sits
    // above the Air haymaker's distance bonus so the two compose additively.
    var damage = 1 + (actor.armor?.meleeBonus ?? 0);

    // Air haymaker: bonus damage = half the tiles actually traversed this
    // turn (path length, not net displacement), rounded down. Uses the
    // walked path from resolveAvatarMovement so conveyor detours and
    // winding routes count same as their tile length — rewards a longer
    // path (e.g. riding conveyors) over a straight-line approach.
    if (actor.hasHaymakerDistanceBonus) {
      final tilesMoved = (walked[actor.playerId]?.length ?? 1) - 1;
      damage += tilesMoved ~/ 2;
    }

    // Apply damage to entities on target tile.
    for (final av in _avatarsAt(targetTile)) {
      if (av.playerId != actor.playerId && _redirectIfIllusion(av, rng)) {
        redirected.add(av.playerId);
        continue;
      }
      av.absorbDamage(damage);
      hitAvatars.add(av);

      // Earth haymaker: slow target.
      if (actor.hasHaymakerSlow) {
        _addStatus(av, StatusEffectId.speedDown, {'speedDelta': -1}, 2);
      }

      // Water haymaker: strip 1 turn from all target status effects.
      if (actor.hasHaymakerStatusDrain) {
        for (final fx in av.activeStatusEffects) {
          fx.remainingTurns = (fx.remainingTurns - 1).clamp(0, 9999);
        }
        av.activeStatusEffects.removeWhere((fx) => fx.remainingTurns <= 0);
      }
    }
    for (final m in _minionsAt(targetTile)) {
      m.takeDamage(damage);
    }

    // Fire haymaker DoT: add stacks to each hit avatar — but skip anyone
    // redirected above; their punch never landed. This stacked by hand long
    // before durations stacked in general; it now just rides the shared rule
    // (see StatusEffect.applyTo), which adds the same 3 turns to an existing
    // DoT and starts a fresh one otherwise.
    if (actor.hasHaymakerDot) {
      for (final av in _avatarsAt(targetTile)) {
        if (redirected.contains(av.playerId)) continue;
        _addStatus(av, StatusEffectId.haymakerDot, {'damagePerTick': 1}, 3);
      }
    }

    return hitAvatars;
  }

  /// Water-Air Illusions (Water flavor), melee-punch path: if [target] has
  /// active wizard decoys, roll 1/remaining -- on a hit the real wizard takes
  /// it (returns false); otherwise a random decoy is destroyed and the punch
  /// is fully absorbed (returns true) — **nothing else happens**: no damage,
  /// no position change, no haymaker side effect (slow/DoT/status-drain).
  /// The decoy dies regardless; the real wizard is untouched, full stop.
  ///
  /// Diverged from [EffectApplicator]'s illusion redirect (2026-07-31): the
  /// formula-effect path still teleports the target onto the decoy's tile
  /// on a dodge (a spell "chasing" the illusion's last-seen position reads as
  /// intentional); a melee punch has no such framing, so a dodge is just a
  /// dodge — no free reposition. Mirrors it only in shape, not in that detail;
  /// duplicated here since the melee punch bypasses EffectApplicator either way.
  bool _redirectIfIllusion(WizardAvatar target, HashRng rng) {
    final set = state.wizardIllusions
        .where(
          (s) => s.ownerId == target.playerId && s.decoyPositions.isNotEmpty,
        )
        .firstOrNull;
    if (set == null) return false;
    final n = set.decoyPositions.length;
    if (rng.nextInt(n) == 0) return false; // chance 1/n: real wizard is hit
    final idx = rng.nextInt(n);
    set.decoyPositions.removeAt(idx); // the illusion dies; nothing else moves
    if (set.decoyPositions.isEmpty) state.wizardIllusions.remove(set);
    return true;
  }

  /// Counter Charm passive (ARTIFACT_SYSTEM_PLAN.md §2.3): each of [attacker]'s
  /// **unspent** charms gives 5% for a successful melee to destroy one of the
  /// victim's mana gems or wither one of their in-hand spells. Linear, so `n`
  /// charms is `n × 5%`, capped at 100.
  ///
  /// This is the passive that makes an Eldritch Knight / Mage Slayer archetype
  /// real: dump all 12 loadout slots into charms, run on the innate 100 mana
  /// pool with no gems at all, spend your limited casting on cheap self-buffs,
  /// and force mages into a kiting game. It replaced an earlier "1% chance to
  /// negate an incantation" proposal, which was swingy, invisible, and
  /// unlearnable.
  ///
  /// **Draws from the shared melee [rng], deliberately — do NOT give it its
  /// own stream.** That stream is already joint-entropy-seeded and sequenced at
  /// the right point in the turn. It is also what makes the melee round's
  /// sorted-playerId application order load-bearing rather than cosmetic: with
  /// this proc, *every* melee consumes the stream, so any turn with two melees
  /// would desync under the old local-first ordering (§6.1).
  ///
  /// Note this is NOT gated on [WizardAvatar.declaredActivation]: §2.2's gate
  /// suppresses charms *firing their counter*, not the passive they radiate
  /// while carried.
  ///
  /// Withers land in [drawSchedules] and the UI record in [procEvents]; both
  /// are the caller's turn-scoped state, see this file's header.
  void applyCounterCharmProc(
    WizardAvatar attacker,
    List<WizardAvatar> victims,
    HashRng rng, {
    required Map<String, DrawSchedule> drawSchedules,
    required List<CounterCharmProcEvent> procEvents,
  }) {
    // Only UNSPENT charms count (§2.4): a charm that has fired its counter is
    // used up and stops feeding the proc, so the 12-charm build self-limits
    // (60% → 55% → 50%) instead of getting full counter coverage AND a full
    // proc rate for free.
    final charms = attacker.activeCounterCharmCount;
    if (charms == 0) return;
    final chancePct = min(charms * _kCounterCharmProcPctPerCharm, 100);

    final sortedVictims = List<WizardAvatar>.from(victims)
      ..sort((a, b) => a.playerId.compareTo(b.playerId));
    for (final victim in sortedVictims) {
      if (victim.playerId == attacker.playerId) continue;
      // The roll is drawn whether or not the victim has anything to lose, so
      // both devices consume the stream identically — a victim with nothing
      // destructible fizzles AFTER the draw, never instead of it.
      if (rng.nextInt(100) >= chancePct) continue;

      final schedule = drawSchedules[victim.playerId];
      // "Wither a bookmarked spell" is implemented as "wither a uniformly
      // chosen in-hand, not-already-withered position": handSize is
      // bookmarkCount + 1 and DrawSchedule.hand is a flat position list — no
      // bookmark *owns* a slot, so there is no bookmark→position mapping to
      // consult and none is needed.
      final witherable = schedule == null
          ? const <int>[]
          : schedule.hand.where((p) => !schedule.withered.contains(p)).toList();

      final options = <CounterCharmProcKind>[
        if (victim.manaGemsEquipped > 0) CounterCharmProcKind.gemDestroyed,
        if (witherable.isNotEmpty) CounterCharmProcKind.spellWithered,
      ];
      if (options.isEmpty) continue; // nothing to take — fizzles cleanly

      final outcome = options[rng.nextInt(options.length)];
      switch (outcome) {
        case CounterCharmProcKind.gemDestroyed:
          // Gems die permanently, hand slots do not (§2.5). The asymmetry is
          // deliberate: gems are the engine, hand disruption is tempo.
          _consumeAccoutrement(victim, AccoutrementKind.manaGem);
          _syncMaxMana(victim);
        case CounterCharmProcKind.spellWithered:
          // Withering lasts until reactivated, identical to FuelTransmutation
          // Fire's existing behaviour (§2.6) — no duration bookkeeping, and
          // Earth's existing "reactivate 1 withered spell" already undoes it.
          final position = witherable[rng.nextInt(witherable.length)];
          drawSchedules[victim.playerId] = schedule!.witherPositions([position]);
      }
      procEvents.add(
        CounterCharmProcEvent(
          attackerId: attacker.playerId,
          victimId: victim.playerId,
          outcome: outcome,
        ),
      );
    }
  }

  // ── Phase 5b: Summons act ─────────────────────────────────────────────────
  //
  // Split in two around the one suspension point `TurnLoop._resolveSummons`
  // has — the walk-the-tokens playback callback. [resolveSummonActions] runs
  // the AI sweep and returns the finished outcome; the caller plays it back;
  // [resolveSummonAftermath] then reaps, saves and dispels. Nothing is decided
  // on the far side of the callback, so the callback cannot influence any of
  // it: the split is a seam through inert ground, not through a decision.

  /// Runs the creature AI for every living minion that has not yet acted, in
  /// `state.minions` creation order, mutating [state] as it goes (movement,
  /// terrain damage, conveyor pushes, attacks, cleave, carapace reflection).
  ///
  /// **Appends** its playback record to [moveEvents] / [attackEvents] rather
  /// than returning fresh lists. All three sinks are the caller's live per-turn
  /// lists, shared with the rest of the turn (see this file's header), and a
  /// Potent summon's Phase-5 bonus action has already appended its own walk and
  /// blow to the first two — so appending here keeps one chronological playback
  /// timeline instead of discarding the earlier half (M4.17).
  ///
  /// Does NOT reap the dead: a creature that lunged in and died to a Molten
  /// Carapace has to be seen making the lunge before it is removed, so the
  /// caller plays the events back first and calls [resolveSummonAftermath]
  /// second. Everything is already decided by the time this returns — playback
  /// cannot change the outcome, because there is nothing left to decide.
  void resolveSummonActions({
    required HashRng rng,
    required List<MinionMoveEvent> moveEvents,
    required List<AttackEvent> attackEvents,
    required List<ConveyorChainEvent> conveyorChainEvents,
  }) {
    // Both clients run the same deterministic AI for all minions (creation
    // order maintained by state.minions list). A summon cast this very turn
    // (Potent or not) starts with actedThisTurn=false, so it's included in
    // this sweep — its first action is always this same turn, here. A
    // Potent summon additionally got an immediate bonus action during Phase
    // 5 (see _castSummon), so it acts a second time right here — and its
    // bonus-action events are already at the head of [moveEvents] /
    // [attackEvents], which is why this appends rather than allocating.
    final living = state.minions
        .where((m) => m.isAlive && !m.actedThisTurn)
        .toList();
    for (final creature in living) {
      _creatureTurn(
        creature,
        rng,
        moveEvents: moveEvents,
        attackEvents: attackEvents,
        conveyorChainEvents: conveyorChainEvents,
      );
      creature.actedThisTurn = true;
    }
    state.resetMinionActions();
  }

  /// The other half of the Summons phase: what settles once the walk has been
  /// shown. Reaps creatures killed during the sweep, gives a wizard who died
  /// to one their Phoenix save, and unmakes any illusory clone whose own AI
  /// walked it into a scryer's arms.
  void resolveSummonAftermath({
    required HashRng rng,
    required List<WildMagicEvent> wildMagicEvents,
  }) {
    _reapDead(rng);
    applyPhoenixSaves(wildMagicEvents);
    // Creature AI moves illusory clones too — one that closes on a scryer
    // is unmade the moment it arrives.
    dispelIllusionsNearScryers();
  }

  // ── Personality AI (design doc "Personalities") ───────────────────────────

  /// One creature's whole turn: pick a target by personality, move, and strike
  /// if the blow is available. Public because a Potent summon takes an extra
  /// action the moment it is cast, from inside Phase 5 — see
  /// `TurnLoop._castSummon`.
  void _creatureTurn(
    Minion creature,
    HashRng rng, {
    required List<MinionMoveEvent> moveEvents,
    required List<AttackEvent> attackEvents,
    required List<ConveyorChainEvent> conveyorChainEvents,
  }) {
    // Illusions (Water-Air, Fire flavor) clones always close in and attack
    // rather than following their copied personality's normal positioning.
    // Obedient creatures fall through to aggressive AI this pass — see
    // SummonPersonality.obedient's doc comment: live manual control needs a
    // protocol change (Summons phase can't move ahead of the B-5 entropy
    // reveal without reopening the look-ahead hole) and is deliberately
    // deferred.
    final personality =
        (creature.forceCloseToAttack ||
            creature.personality == SummonPersonality.obedient)
        ? SummonPersonality.aggressive
        : creature.personality;

    final target = switch (personality) {
      SummonPersonality.tactical => _tacticalTarget(creature),
      SummonPersonality.protective => () {
        final owner = avatarById(creature.ownerId);
        final from = (owner != null && owner.isAlive)
            ? owner.position
            : creature.position;
        return _nearestEnemyEntity(from, creature.teamId, rng);
      }(),
      SummonPersonality.aggressive ||
      SummonPersonality.evasive ||
      // Unreachable: reassigned to aggressive above. Listed only to keep
      // this switch exhaustive over the full enum.
      SummonPersonality.obedient => _nearestEnemyEntity(
        creature.position,
        creature.teamId,
        rng,
      ),
    };
    if (target == null) return;

    final before = creature.position;
    // Tiles actually visited, for the UI to walk the token rather than
    // teleport it. See [MinionMoveEvent].
    final route = <HexCoord>[before];
    final int unspent;
    switch (personality) {
      case SummonPersonality.evasive:
        unspent = _evasiveMove(
          creature,
          target.position,
          rng,
          route,
          conveyorChainEvents,
        );
      case SummonPersonality.protective:
        final owner = avatarById(creature.ownerId);
        if (owner != null && owner.isAlive) {
          // Interpose: aim for the tile between the owner and the threat.
          final dir = _directionTowards(owner.position, target.position);
          final interpose = dir == null
              ? owner.position
              : HexCoord(owner.position.q + dir.q, owner.position.r + dir.r);
          unspent = _aggressiveMove(
            creature,
            interpose,
            rng,
            route,
            conveyorChainEvents,
          );
        } else {
          unspent = _aggressiveMove(
            creature,
            target.position,
            rng,
            route,
            conveyorChainEvents,
          );
        }
      case SummonPersonality.aggressive:
      case SummonPersonality.tactical:
      case SummonPersonality.obedient: // unreachable — see above
        unspent = _aggressiveMove(
          creature,
          target.position,
          rng,
          route,
          conveyorChainEvents,
        );
    }
    final movedTiles = hexDistance(before, creature.position);

    final range = creature.effectiveAttackRange;
    HexCoord? lunge;
    if (range == 0) {
      // A melee creature has no reach at all: to land a blow it has to stand
      // on its target, which costs it a movement point and which it cannot
      // keep (bodies are exclusive — see [tileOccupied]), so it is shoved
      // straight back out onto the tile it came from. Spent its whole budget
      // closing the distance? Then it arrives with nothing left to strike
      // with, and waits for next turn.
      if (creature.isAlive &&
          unspent > 0 &&
          creature.distanceTo(target.position) == 1) {
        lunge = target.position;
        _recordAttack(creature, target.position, range, attackEvents);
        // The lunge step is real movement, so Charger (FAFA) counts it.
        _creatureAttack(creature, target, rng, movedTiles: movedTiles + 1);
      }
    } else if (creature.distanceTo(target.position) <= range &&
        _creatureHasLineTo(creature, target.position)) {
      // A ranged summon used to be a bare distance test, so it would walk up
      // to a wall and shoot straight through it (WALL_LOS_PLAN.md §1). Losing
      // the line just costs it the shot — it has already moved this turn and
      // will keep closing next turn.
      _recordAttack(creature, target.position, range, attackEvents);
      _creatureAttack(creature, target, rng, movedTiles: movedTiles);
    }

    if (route.length > 1 || lunge != null) {
      moveEvents.add(
        MinionMoveEvent(
          minionId: creature.id,
          path: List.unmodifiable(route),
          lungeTile: lunge,
        ),
      );
    }
  }

  /// Whether [creature] can actually see [to] — from ANY of its tiles, since
  /// "its range, and the range of things affecting it, applies from any of its
  /// tiles" (design doc, Big). Its own footprint never blocks it, which
  /// [losBlockerTile] already handles.
  bool _creatureHasLineTo(Minion creature, HexCoord to) => creature.occupiedTiles
      .any((t) => losBlockerTile(state, t, to) == null);

  /// Nearest living enemy of [teamId] to [from]: enemy players first, then
  /// (if none) enemy minions — Stealthy (AWAW) ones excluded unless [from]
  /// is already within 1 tile. Ties broken by [rng] (design doc: "Targets
  /// that are both equally close and equal priority chosen at random").
  ///
  /// Targets in clear line of sight are preferred over walled-off ones at the
  /// same priority; if every candidate is blocked the whole set stays in play,
  /// so a creature keeps advancing on somebody rather than freezing in front
  /// of a wall (WALL_LOS_PLAN.md §5.2).
  _AiTarget? _nearestEnemyEntity(HexCoord from, String teamId, HashRng rng) {
    var avatars = state.avatars
        .where((av) => av.isAlive && av.teamId != teamId)
        .toList();
    final visibleAvatars = avatars
        .where((av) => losBlockerTile(state, from, av.position) == null)
        .toList();
    if (visibleAvatars.isNotEmpty) avatars = visibleAvatars;
    if (avatars.isNotEmpty) {
      final dists = [for (final av in avatars) hexDistance(av.position, from)];
      final bestDist = dists.reduce(min);
      final tied = [
        for (var i = 0; i < avatars.length; i++)
          if (dists[i] == bestDist) avatars[i],
      ];
      final chosen = tied[rng.nextInt(tied.length)];
      return _AiTarget(position: chosen.position, avatar: chosen);
    }
    var minions = state.minions
        .where(
          (m) =>
              m.isAlive &&
              m.teamId != teamId &&
              (!m.abilities.contains(SummonAbility.stealthy) ||
                  m.distanceTo(from) <= 1),
        )
        .toList();
    if (minions.isEmpty) return null;
    final visibleMinions = minions
        .where((m) => m.occupiedTiles
            .any((t) => losBlockerTile(state, from, t) == null))
        .toList();
    if (visibleMinions.isNotEmpty) minions = visibleMinions;
    final dists = [for (final m in minions) m.distanceTo(from)];
    final bestDist = dists.reduce(min);
    final tied = [
      for (var i = 0; i < minions.length; i++)
        if (dists[i] == bestDist) minions[i],
    ];
    final chosen = tied[rng.nextInt(tied.length)];
    return _AiTarget(position: chosen.position, minion: chosen);
  }

  /// Tactical personality: lowest effective HP wins, factoring the
  /// resistance wheel against [creature]'s own attack type (design doc:
  /// "slay targets with the fewest hitpoints... factoring in resistances").
  /// Compares avatars and minions on one uniform scale (no player-first
  /// priority — that tiebreak is specific to Evasive).
  _AiTarget? _tacticalTarget(Minion creature) {
    _AiTarget? best;
    var bestHp = double.infinity;
    for (final av in state.avatars.where(
      (a) => a.isAlive && a.teamId != creature.teamId,
    )) {
      if (av.hp < bestHp) {
        bestHp = av.hp.toDouble();
        best = _AiTarget(position: av.position, avatar: av);
      }
    }
    final minions = state.minions.where(
      (m) =>
          m.isAlive &&
          m.teamId != creature.teamId &&
          (!m.abilities.contains(SummonAbility.stealthy) ||
              m.distanceTo(creature.position) <= 1),
    );
    for (final m in minions) {
      final factor = switch (resistanceTierOf(creature.affinity, m.affinity)) {
        ResistanceTier.resistant => 2.0,
        ResistanceTier.vulnerable => 0.5,
        ResistanceTier.normal => 1.0,
      };
      final effHp = m.hp * factor;
      if (effHp < bestHp) {
        bestHp = effHp;
        best = _AiTarget(position: m.position, minion: m);
      }
    }
    return best;
  }

  // ── Personality movement ──────────────────────────────────────────────────

  /// Aggressive (and Tactical's approach, and Protective's interpose): move
  /// directly toward [target], one tile at a time, up to move speed. Entering
  /// a conveyor tile pushes immediately (see _resolveMinionConveyorPush) and
  /// the creature keeps walking with whatever budget remains.
  ///
  /// Appends every tile entered to [route] (which starts with the creature's
  /// pre-move tile) and returns the movement budget left unspent — a melee
  /// creature needs one more point to lunge onto its target, so "did it arrive
  /// with anything left?" is part of the answer, not just where it stopped.
  int _aggressiveMove(
    Minion creature,
    HexCoord target,
    HashRng rng,
    List<HexCoord> route,
    List<ConveyorChainEvent> conveyorChainEvents,
  ) {
    final flying = creature.abilities.contains(SummonAbility.flying);
    var steps = creature.effectiveMoveSpeed;
    while (steps > 0 && creature.isAlive && creature.distanceTo(target) > 0) {
      final step = _creatureGreedyStep(creature, target);
      if (step == null) break;
      creature.position = step;
      route.add(step);
      steps -= _terrainMoveCost(creature, step, flying);
      _resolveMinionConveyorPush(
        creature,
        flying,
        rng,
        route,
        conveyorChainEvents,
      );
    }
    return max(0, steps);
  }

  /// Evasive: back away while closer than attack range, approach while
  /// farther, stop once at ideal range — using the full move-speed budget.
  /// Same immediate-push-then-continue conveyor behavior, [route] recording
  /// and unspent-budget return as [_aggressiveMove].
  int _evasiveMove(
    Minion creature,
    HexCoord target,
    HashRng rng,
    List<HexCoord> route,
    List<ConveyorChainEvent> conveyorChainEvents,
  ) {
    final flying = creature.abilities.contains(SummonAbility.flying);
    final range = creature.effectiveAttackRange;
    var steps = creature.effectiveMoveSpeed;
    while (steps > 0 && creature.isAlive) {
      final dist = creature.distanceTo(target);
      final HexCoord? step;
      if (dist < range) {
        step = _creatureGreedyStep(creature, target, away: true);
      } else if (dist > range) {
        step = _creatureGreedyStep(creature, target);
      } else {
        break;
      }
      if (step == null) break;
      creature.position = step;
      route.add(step);
      steps -= _terrainMoveCost(creature, step, flying);
      _resolveMinionConveyorPush(
        creature,
        flying,
        rng,
        route,
        conveyorChainEvents,
      );
    }
    return max(0, steps);
  }

  /// Applies FloorIsLava damage (unless flying) for [step] just entered, and
  /// returns the movement-budget cost of entering it: a SlowTile costs
  /// [SlowTile.extraMoveCost] total (default 2 -- "costs two movement",
  /// replacing the usual 1, not additive to it); everything else costs 1.
  /// No mana-drain equivalent -- minions have no mana resource.
  int _terrainMoveCost(Minion creature, HexCoord step, bool flying) {
    final effect = state.tileEffects[step];
    if (flying) return 1;
    if (effect is FloorIsLava) creature.takeDamage(effect.damage);
    if (effect is SlowTile) return effect.extraMoveCost;
    return 1;
  }

  /// Called immediately after the creature enters a new tile mid-walk: if
  /// that tile is a conveyor, resolves the cascading/looping push
  /// (tile_entry_resolver.dart) right away. No-op if flying. Every tile the
  /// push carried the creature through is appended to [route], so the walk
  /// animation follows the real journey rather than the declared one.
  void _resolveMinionConveyorPush(
    Minion creature,
    bool flying,
    HashRng rng,
    List<HexCoord> route,
    List<ConveyorChainEvent> conveyorChainEvents,
  ) {
    if (flying) return;
    if (state.tileEffects[creature.position] is! ConveyorTile) return;
    final outcome = resolveTileEntry(
      state: state,
      rng: rng,
      enteredTile: creature.position,
      flying: false,
      currentHp: creature.hp,
      applyEntryLava: false, // already charged per-step above
      footprintValid: (t) => _footprintValid(t, creature),
    );
    creature.position = outcome.finalPosition;
    route.addAll(outcome.animationPath.skip(1));
    if (outcome.totalDamage > 0) creature.takeDamage(outcome.totalDamage);
    if (outcome.animationPath.length > 1) {
      conveyorChainEvents.add(
        ConveyorChainEvent(
          entityId: creature.id,
          path: outcome.animationPath,
          damage: outcome.totalDamage,
          killed: outcome.killed,
        ),
      );
    }
  }

  /// One greedy step of [creature]'s own footprint toward (or, if [away],
  /// away from) [toward]. Flying (AAAA) ignores ImpassableTile; Big (EEEE)
  /// requires the whole footprint to be valid at the candidate center.
  HexCoord? _creatureGreedyStep(
    Minion creature,
    HexCoord toward, {
    bool away = false,
  }) {
    HexCoord? best;
    var bestDist = creature.distanceTo(toward);
    for (final n in state.battlefield.neighbors(creature.position)) {
      if (!_footprintValid(n, creature)) continue;
      final candidateDist = footprintFor(
        n,
        creature.abilities,
      ).map((t) => hexDistance(t, toward)).reduce(min);
      final better = away ? candidateDist > bestDist : candidateDist < bestDist;
      if (better) {
        bestDist = candidateDist;
        best = n;
      }
    }
    return best;
  }

  /// The hex direction (of the 6) that points most directly from [from]
  /// toward [to]. Null if [from] == [to].
  HexCoord? _directionTowards(HexCoord from, HexCoord to) {
    const dirs = [
      HexCoord(1, 0),
      HexCoord(1, -1),
      HexCoord(0, -1),
      HexCoord(-1, 0),
      HexCoord(-1, 1),
      HexCoord(0, 1),
    ];
    final dq = to.q - from.q;
    final dr = to.r - from.r;
    if (dq == 0 && dr == 0) return null;
    var bestDot = -999999;
    HexCoord best = dirs[0];
    for (final d in dirs) {
      final dot = dq * d.q + dr * d.r;
      if (dot > bestDot) {
        bestDot = dot;
        best = d;
      }
    }
    return best;
  }

  // ── Attack resolution + abilities ─────────────────────────────────────────

  /// Notes one creature strike for the UI. Recorded *before* the damage is
  /// applied, from the attacker's pre-lunge tile: a melee creature ends the
  /// turn back where it started, and an attacker that dies to the blow it just
  /// landed (Molten Carapace) should still be seen throwing it.
  void _recordAttack(
    Minion attacker,
    HexCoord target,
    int range,
    List<AttackEvent> attackEvents,
  ) {
    attackEvents.add(
      AttackEvent(
        from: attacker.position,
        to: target,
        range: range,
        affinity: attacker.affinity,
      ),
    );
  }

  void _creatureAttack(
    Minion attacker,
    _AiTarget target,
    HashRng rng, {
    int movedTiles = 0,
  }) {
    var damage = attacker.stats.damage;
    // Charger (FAFA): bonus damage = half the distance moved before
    // attacking, rounded up.
    if (attacker.abilities.contains(SummonAbility.charger)) {
      damage += (movedTiles / 2).ceil();
    }
    final muddy = attacker.abilities.contains(SummonAbility.muddy);

    if (target.avatar != null) {
      final av = target.avatar!;
      av.absorbDamage(damage);
      if (muddy)
        _addStatus(av, StatusEffectId.speedDown, {'speedDelta': -1}, 1);
    } else if (target.minion != null) {
      final m = target.minion!;
      m.takeDamage(damage, attackType: attacker.affinity);
      // Molten Carapace (EFEF): a hit from within 1 range reflects 1 fire
      // damage back to the attacker.
      if (m.abilities.contains(SummonAbility.moltenCarapace) &&
          attacker.distanceTo(m.position) <= 1) {
        attacker.takeDamage(1, attackType: SpellAffinity.fire);
      }
      if (muddy) {
        StatusEffect.applyTo(m.activeStatusEffects, StatusEffectId.speedDown,
            const {'speedDelta': -1}, 1);
      }
    }

    // Cleave (FFFF): a second enemy adjacent to both the primary target and
    // this creature takes the same damage.
    if (attacker.abilities.contains(SummonAbility.cleave)) {
      final secondary = _cleaveTarget(attacker, target);
      if (secondary?.avatar != null) {
        secondary!.avatar!.absorbDamage(damage);
      } else if (secondary?.minion != null) {
        secondary!.minion!.takeDamage(damage, attackType: attacker.affinity);
      }
    }
  }

  _AiTarget? _cleaveTarget(Minion attacker, _AiTarget primary) {
    bool adjacentToBoth(HexCoord pos) =>
        hexDistance(pos, primary.position) == 1 &&
        attacker.distanceTo(pos) == 1;
    for (final av in state.avatars) {
      if (!av.isAlive || av.teamId == attacker.teamId) continue;
      if (av == primary.avatar) continue;
      if (adjacentToBoth(av.position))
        return _AiTarget(position: av.position, avatar: av);
    }
    for (final m in state.minions) {
      if (!m.isAlive || m.teamId == attacker.teamId) continue;
      if (m == primary.minion) continue;
      if (adjacentToBoth(m.position))
        return _AiTarget(position: m.position, minion: m);
    }
    return null;
  }

  // ── Phase 5.5 / 6.5: Free-move window ─────────────────────────────────────
  //
  // Fifth across the seam, and the first phase deliberately NOT moved whole.
  // The free-move rounds are a commit-reveal negotiation: prompt the local
  // player, exchange with the peer, verify the reveal, then apply both runs in
  // a fixed order. The exchange's *result* feeds the second application, so
  // the header's split-don't-smuggle rule says the phase itself cannot come
  // across — and it doesn't. What comes across is the set of deterministic
  // operations the round drives: what a wizard is being offered
  // ([freeMoveGrantFor]), what a run costs ([boostMoveCost]), where it may
  // step ([freeMoveCandidates]) and what actually happens when it walks
  // ([applyFreeMove]). `TurnLoop._runFreeMoveRound` keeps the prompt, the
  // exchange, the reveal verification, the local-then-peer ordering and the
  // end-of-round clearing.
  //
  // The trust rule is the reason [applyFreeMove] takes only a declared path:
  // the grant and the price are re-derived here from [state], never read off
  // the peer's message (same discipline as `_certifiedManaCost`, B-1/B-8). An
  // illegal or over-long path is truncated and priced on what it actually
  // walked, not rejected — both devices run this same truncation on the same
  // state and land on the same answer.

  /// [freeMoveCandidates] for the avatar with [playerId] — the legal first
  /// steps of a free-move run, for BattleScreen's prompt highlight. Empty for
  /// an unknown or dead player.
  List<HexCoord> freeMoveCandidatesFor(String playerId) {
    final av = avatarById(playerId);
    return av == null ? const [] : freeMoveCandidates(av);
  }

  /// Adjacent tiles a post-resolution free-move run may step onto: in
  /// bounds, not ImpassableTile, and unoccupied by any living avatar or
  /// minion. Mirrors the footprint check in `_findCreatureSpawnTile`.
  List<HexCoord> freeMoveCandidates(WizardAvatar actor) {
    if (!actor.isAlive) return const [];
    final candidates = <HexCoord>[];
    for (final tile in hexNeighbors(actor.position)) {
      if (!state.battlefield.isInBounds(tile)) continue;
      if (tileBlocksMovement(state.tileEffects[tile])) continue;
      if (tileOccupied(state, tile, ignoreAvatarId: actor.playerId)) continue;
      candidates.add(tile);
    }
    return candidates;
  }

  /// Price of a Boost run that spends [paidTiles] chargeable tiles (i.e. tiles
  /// beyond [FreeMoveGrant.freeTiles]), in the units of [resource]:
  /// `n(n+1)/2` HP for Fire, `n(n+1)/2 × 100` mana for Water (design v3.0
  /// §Effect Table, Air-Air).
  ///
  /// Static and total, so the engine's charge and the UI's preview are the
  /// same arithmetic in the same order — the `_certifiedManaCost` lesson
  /// (B-1/B-8): one price, one code path, never two that agree by inspection.
  static int boostMoveCost(SpellAffinity resource, int paidTiles) {
    if (paidTiles <= 0) return 0;
    final triangular = paidTiles * (paidTiles + 1) ~/ 2;
    return resource == SpellAffinity.water
        ? triangular * kBoostManaPerTile
        : triangular;
  }

  /// What the free-move window is offering [av] right now, priced against the
  /// resource they actually hold.
  ///
  /// Both devices call this on the same state and must agree — it reads only
  /// [WizardAvatar.pendingFreeMoveBurst], [WizardAvatar.pendingBoostMove],
  /// current HP/mana, and the board. Public because BattleScreen needs the
  /// identical grant to draw the prompt and the cost preview.
  ///
  /// A Fire boost can never be taken below 1 HP: paying your last life for a
  /// step is a suicide button, not a decision, and the design calls this a
  /// *cost* rather than damage.
  FreeMoveGrant freeMoveGrantFor(WizardAvatar av) {
    if (!av.isAlive) return FreeMoveGrant.none;
    final burst = av.pendingFreeMoveBurst;
    final resource = av.pendingBoostMove;
    if (!burst && resource == null) return FreeMoveGrant.none;

    final freeTiles =
        (burst ? 1 : 0) + (resource == null ? 0 : av.pendingBoostFreeTiles);
    var maxTiles = freeTiles;
    if (resource != null) {
      final budget = resource == SpellAffinity.water ? av.mana : av.hp - 1;
      // Triangular growth, so this terminates fast (4 paid tiles already cost
      // 1000 mana / 10 HP); the guard is belt-and-braces against a future
      // resource pool large enough to matter.
      var paid = 1;
      while (paid <= _kMaxBoostPaidTiles &&
          boostMoveCost(resource, paid) <= budget) {
        maxTiles = freeTiles + paid;
        paid++;
      }
    }
    return FreeMoveGrant(
      burstStep: burst,
      boostResource: resource,
      boostFreeTiles: resource == null ? 0 : av.pendingBoostFreeTiles,
      maxTiles: maxTiles,
    );
  }

  /// Applies a post-resolution free-move run for [av] along [declaredPath],
  /// charging the Boost resource for whatever the walk actually consumed.
  ///
  /// Re-validates independently of the wire claim (defense-in-depth, matching
  /// `_applyHaymaker`'s adjacency check): the grant is re-derived from state
  /// via [freeMoveGrantFor] rather than taken from the peer's message, so a
  /// peer can neither claim a burst it didn't earn nor walk further than it
  /// can pay for. An over-long or illegal path is walked as far as it is legal
  /// and priced on that, never rejected wholesale — the two devices run this
  /// same truncation on the same state and land on the same answer.
  ///
  /// [rng] resolves the terrain the walk crosses (ice slides, closed conveyor
  /// loops); it is phase-seeded by the caller so both devices roll alike.
  /// Conveyor pushes picked up mid-run land in [conveyorChainEvents], the
  /// caller's turn-scoped sink — see this file's header.
  void applyFreeMove(
    WizardAvatar av,
    List<HexCoord> declaredPath,
    HashRng rng, {
    required List<ConveyorChainEvent> conveyorChainEvents,
  }) {
    if (declaredPath.isEmpty) return;
    final grant = freeMoveGrantFor(av);
    if (grant.isEmpty) return;

    final origin = av.position;
    // Unlike the movement phase, this window is sequential — one avatar walks
    // at a time, with everyone else standing still — so live positions are the
    // right blocker set and no snapshot is needed.
    final walk = _walkAvatar(
      av,
      origin,
      declaredPath,
      grant.maxTiles,
      rng,
      conveyorChainEvents: conveyorChainEvents,
      blocked: (hex) => tileOccupied(state, hex, ignoreAvatarId: av.playerId),
    );
    if (walk.path.length <= 1) return; // blocked before the first step landed

    av.position = walk.path.last;
    state.battlefield.occupancy[av.playerId] = walk.path.last;
    // A free-move run is voluntary movement, exactly like a declared move
    // path — see resolveAvatarMovement's matching call.
    _breakStatuesque(av.playerId);

    final resource = grant.boostResource;
    if (resource == null) return;
    final paidTiles = max(0, walk.spent - grant.freeTiles);
    final cost = boostMoveCost(resource, paidTiles);
    if (cost <= 0) return;
    if (resource == SpellAffinity.water) {
      av.mana = (av.mana - cost).clamp(0, _kMaxMana).toInt();
    } else {
      // Deliberately NOT absorbDamage: this is a price the wizard pays, and
      // letting a barrier soak it would make the tiles free. Clamped to leave
      // 1 HP, matching the cap freeMoveGrantFor already applied.
      av.hp = max(1, av.hp - cost);
    }
  }

  // ── Phase 6: End of turn ──────────────────────────────────────────────────

  /// Runs the end-of-turn sweep: hazard damage, conveyor pushes, cloud ticks,
  /// mana regen, wild-magic latches, terrain expiry, status/barrier/cloud
  /// ticks, minion reaping, and link expiry.
  ///
  /// [preMovPos] is each avatar's position before this turn's movement phase,
  /// needed by the Dust Cloud rule that fires on *leaving* a radius.
  ///
  /// Appends to [conveyorChainEvents] and [wildMagicEvents]; see this file's
  /// header for why those are parameters.
  void resolveEndOfTurn({
    required Map<String, HexCoord> preMovPos,
    required HashRng rng,
    required List<ConveyorChainEvent> conveyorChainEvents,
    required List<WildMagicEvent> wildMagicEvents,
  }) {
    // Fire barrier aura: deal 1 damage to all adjacent entities per fire-barrier holder.
    for (final av in state.avatars) {
      final fb = av.barriers[SpellAffinity.fire];
      if (fb == null || !fb.isAlive || !fb.fireAura) continue;
      for (final other in state.avatars) {
        if (other.playerId == av.playerId) continue;
        if (isAdjacent(av.position, other.position)) other.absorbDamage(1);
      }
      for (final m in state.minions) {
        if (isAdjacent(av.position, m.position)) m.takeDamage(1);
      }
    }

    // FloorIsLava: damage entities standing on lava tiles (spirits exempt).
    for (final entry in state.tileEffects.entries) {
      if (entry.value is! FloorIsLava) continue;
      final lava = entry.value as FloorIsLava;
      final tile = entry.key;
      for (final av in state.avatars.where(
        (a) => a.isAlive && a.position == tile,
      )) {
        av.absorbDamage(lava.damage);
      }
      for (final m in state.minions.where(
        (m) => m.isAlive && m.occupiedTiles.contains(tile),
      )) {
        if (m.abilities.contains(SummonAbility.flying)) continue;
        m.takeDamage(lava.damage);
      }
    }

    // ConveyorTile: entities still standing on a conveyor at end of turn get
    // pushed again. Without this, a conveyor summoned directly under someone
    // (they never "entered" it -- it just appeared under their feet) or one
    // whose earlier push failed mid-cascade would sit there doing nothing.
    // applyEntryLava is irrelevant here (the tile they're already on is by
    // construction a ConveyorTile, never lava -- one effect per tile).
    for (final av in state.avatars) {
      if (!av.isAlive) continue;
      if (state.tileEffects[av.position] is! ConveyorTile) continue;
      final outcome = resolveTileEntry(
        state: state,
        rng: rng,
        enteredTile: av.position,
        flying: false,
        currentHp: av.hp,
        applyEntryLava: false,
      );
      av.position = outcome.finalPosition;
      state.battlefield.occupancy[av.playerId] = outcome.finalPosition;
      if (outcome.totalDamage > 0) av.absorbDamage(outcome.totalDamage);
      if (outcome.animationPath.length > 1) {
        conveyorChainEvents.add(
          ConveyorChainEvent(
            entityId: av.playerId,
            path: outcome.animationPath,
            damage: outcome.totalDamage,
            killed: outcome.killed,
          ),
        );
      }
    }
    for (final m in state.minions) {
      if (!m.isAlive) continue;
      if (m.abilities.contains(SummonAbility.flying)) continue;
      if (state.tileEffects[m.position] is! ConveyorTile) continue;
      final outcome = resolveTileEntry(
        state: state,
        rng: rng,
        enteredTile: m.position,
        flying: false,
        currentHp: m.hp,
        applyEntryLava: false,
        footprintValid: (t) => _footprintValid(t, m),
      );
      m.position = outcome.finalPosition;
      if (outcome.totalDamage > 0) m.takeDamage(outcome.totalDamage);
      if (outcome.animationPath.length > 1) {
        conveyorChainEvents.add(
          ConveyorChainEvent(
            entityId: m.id,
            path: outcome.animationPath,
            damage: outcome.totalDamage,
            killed: outcome.killed,
          ),
        );
      }
    }

    // Cloud effects. Base effect (all flavors): entities within cloud.radius
    // may only target/be targeted by adjacent entities -- enforced live by
    // position at cast-target-selection time (battle_screen.dart), not here.
    for (final cloud in state.clouds) {
      switch (cloud.kind) {
        case ToxicCloud(:final damagePerTurn):
          for (final av in state.avatars.where(
            (a) =>
                a.isAlive &&
                hexDistance(a.position, cloud.position) <= cloud.radius,
          )) {
            av.absorbDamage(damagePerTurn);
          }
          for (final m in state.minions.where(
            (m) =>
                m.isAlive &&
                hexDistance(m.position, cloud.position) <= cloud.radius,
          )) {
            m.takeDamage(damagePerTurn);
          }

        case DustCloud(:final restrictionTurnsAfterLeaving):
          // The adjacent-only targeting restriction lingers on avatars who
          // LEFT this cloud's radius this turn -- except an Earthen Scrying
          // Pool bearer, who is immune to it (the status is skipped rather
          // than added-and-ignored so the UI chip stays honest).
          for (final av in state.avatars) {
            if (av.activeStatusEffects.any(
              (fx) =>
                  !fx.isDormant &&
                  fx.effectTypeId == StatusEffectId.scryingSight,
            )) {
              continue;
            }
            final wasIn =
                hexDistance(
                  preMovPos[av.playerId] ?? av.position,
                  cloud.position,
                ) <=
                cloud.radius;
            final isOut =
                hexDistance(av.position, cloud.position) > cloud.radius;
            if (wasIn && isOut) {
              _addStatus(
                av,
                StatusEffectId.cloudBoundTargeting,
                {},
                restrictionTurnsAfterLeaving,
              );
            }
          }

        case WaterCloud():
          break; // no kind-specific tick behaviour -- just a bigger radius

        case MobileCloud():
          break; // movement handled by _moveClouds during the Summons step
      }
    }

    // Mana regeneration (gems + Water barrier bonus). There is no innate
    // regen: a gemless wizard regains mana only by meditating.
    for (final av in state.avatars) {
      if (!av.isAlive) continue;
      final regen =
          av.manaRegenFor(state.config) + av.barrierManaRegenFor(av.maxMana);
      applyManaGain(av, regen);
    }

    // Terrain-barrier riders (WALL_LOS_PLAN.md §2.6): a Firey barrier turns
    // its tile into a burning wall that scorches every adjacent tile, and a
    // Watery one pays mana to whoever is standing on the tile — live on lava,
    // slow, and conveyor tiles, inert on a wall nobody can stand in. Runs
    // alongside the avatar mana regen above so both use applyManaGain and
    // the same clamping.
    tickTerrainBarrierAuras(state, rng, applyManaGain);

    // Haymaker DoT tick: deal damage = remainingTurns per active haymakerDot.
    for (final av in state.avatars) {
      final dot = av.activeStatusEffects
          .where((fx) => fx.effectTypeId == StatusEffectId.haymakerDot)
          .firstOrNull;
      if (dot != null && !dot.isDormant) {
        av.absorbDamage(dot.remainingTurns); // damage = turns remaining
      }
    }

    // ── Wild magic, end of turn ─────────────────────────────────────────
    //
    // Statuesque (row 3, Earth). A6: the latch begins at the END of the turn
    // it fires, so the triggering cast cannot break its own effect — promote
    // the pending set here, then refill everyone still standing. Sorted, since
    // both sets are Sets and their iteration order is insertion order.
    if (state.wildMagic.pendingStatuesquePlayerIds.isNotEmpty) {
      final promoted = state.wildMagic.pendingStatuesquePlayerIds.toList()..sort();
      state.wildMagic.statuesquePlayerIds.addAll(promoted);
      state.wildMagic.pendingStatuesquePlayerIds.clear();
    }
    for (final id in state.wildMagic.statuesquePlayerIds.toList()..sort()) {
      final av = avatarById(id);
      if (av == null || !av.isAlive) continue;
      // "Full" means the pool this wizard actually started the match with,
      // armor included — restoring to the bare config value would silently
      // strip an Earth armor's contribution and make Statuesque a downgrade
      // for the wearer. Ordinary healing stays uncapped and untouched; this is
      // the one path that ASSIGNS an HP total rather than adding to one.
      av.hp = state.config.playerHp + (av.armor?.armorHpBonus ?? 0);
      applyManaGain(av, av.maxMana - av.mana);
    }
    // A dead player can never break the latch by moving or casting, so drop
    // them rather than leaving a permanent entry in the state hash.
    state.wildMagic.statuesquePlayerIds.removeWhere(
      (id) => !(avatarById(id)?.isAlive ?? false),
    );

    // Expiring terrain (Mountains, Chasm, Glacier). expiringTiles maps a coord
    // to the LAST turn its effect is active, so sweep once that turn ends.
    // Sorted so the two devices remove in one order (the map is keyed by
    // coord, so the result is order-independent — but the habit is cheap and
    // the next expiring effect may not be).
    if (state.expiringTiles.isNotEmpty) {
      final expired = state.expiringTiles.entries
          .where((e) => e.value <= state.turnNumber)
          .map((e) => e.key)
          .toList()
        ..sort((a, b) {
          final qc = a.q.compareTo(b.q);
          return qc != 0 ? qc : a.r.compareTo(b.r);
        });
      for (final tile in expired) {
        state.expiringTiles.remove(tile);
        // removeTerrain, not tileEffects.remove: a Mountains wall carries an
        // HP entry and possibly barriers, and leaving either behind would let
        // the next tile on that coord inherit ghosts (WALL_LOS_PLAN.md §5.0).
        state.removeTerrain(tile);
      }
    }

    // Tick all status effects, barriers, clouds, and illusions.
    for (final av in state.avatars) {
      final freeMove = av.tickBarriers();
      if (freeMove) {
        // Air barrier collapsed — grant free extra movement.
        // TODO(ui): signal free move grant to the UI so the player can use it.
      }
      av.tickStatusEffects();
    }
    // Terrain barriers age out the same way avatar barriers do; an Airy one
    // that runs out of TIME still collapses, and §2.6's knockback says "on
    // collapse", not "on burst".
    tickTerrainBarriers(state, rng);
    state.tickClouds();

    // Rod of Wind's movement passive and the bookmark burn's hand redraw
    // used to resolve here (ARTIFACT_SYSTEM_PLAN.md §§2.7-2.8's original
    // "Phase 6, effective next turn" timing). Amended 2026-07-31: both now
    // resolve at Phase 0, via [beginArtifactEntropy] / [_applyArtifactActivation],
    // so they're usable the same turn they're decided. See those for why.

    _reapDead(rng);
    applyPhoenixSaves(wildMagicEvents);

    // Expire mystery spells whose reveal window has passed (castTurn + 3).
    // Mana is already spent; caster chose not to reveal.
    state.pendingDelayedSpells.removeWhere(
      (p) => p.maxTurn <= state.turnNumber,
    );

    // Tick Reflections links; remove expired or dead-participant links.
    final alive = state.avatars
        .where((a) => a.isAlive)
        .map((a) => a.playerId)
        .toSet();
    for (final l in state.reflectionLinks) {
      l.remainingTurns--;
    }
    state.reflectionLinks.removeWhere(
      (l) =>
          l.remainingTurns <= 0 ||
          !alive.contains(l.casterId) ||
          !alive.contains(l.targetId),
    );

    // Tick Divination links (Air-Water); same expiry rule as Reflections.
    for (final l in state.divinationLinks) {
      l.remainingTurns--;
    }
    state.divinationLinks.removeWhere(
      (l) =>
          l.remainingTurns <= 0 ||
          !alive.contains(l.casterId) ||
          !alive.contains(l.targetId),
    );

    // Backstop sweep: end-of-turn damage, conveyor pushes and cloud drift all
    // rearrange the field after Phase 5.5's window has closed. Runs after the
    // status tick above, so a scrying that expired this turn no longer
    // dispels anything.
    dispelIllusionsNearScryers();
  }

  // ── Shared deterministic helpers ──────────────────────────────────────────
  //
  // These moved with end-of-turn because it calls them, but most have other
  // callers still in TurnLoop, which reaches them through one-line private
  // delegators. That is deliberate: forwarding leaves ~50 unrelated call sites
  // untouched, so the diff of this extraction is a move rather than a rewrite.

  /// Removes dead minions, first giving Morphic (WWWW) ones a chance to
  /// reform (design doc: "reform into new creature with half the number of
  /// elements... at random"). Must run after every point minions can die so
  /// reforms happen on both battle clients identically (uses [rng]).
  void _reapDead(HashRng rng) {
    final dead = state.minions.where((m) => !m.isAlive).toList();
    if (dead.isEmpty) return;
    state.minions.removeWhere((m) => !m.isAlive);
    var seq = 0;
    for (final m in dead) {
      state.minions.addAll(m.onDeath(rng.nextInt, '${m.id}_reform${seq++}'));
    }
  }

  /// Phoenix (wild magic, row 3 Fire): a player in the phoenix set who would
  /// die instead respawns at 1 HP, consuming their one-shot save.
  ///
  /// Called everywhere avatar HP can reach zero — beside every [_reapDead]
  /// (which only reaps minions) and immediately before the win check, so a
  /// save can never be missed by the match ending first.
  void applyPhoenixSaves(List<WildMagicEvent> wildMagicEvents) {
    if (state.wildMagic.phoenixPlayerIds.isEmpty) return;
    // Sorted so the (rare) case of two simultaneous saves consumes the set in
    // one order on both devices.
    final saved = <String>[];
    for (final av in List<WizardAvatar>.from(state.avatars)
      ..sort((a, b) => a.playerId.compareTo(b.playerId))) {
      if (av.isAlive) continue;
      if (!state.wildMagic.phoenixPlayerIds.remove(av.playerId)) continue;
      av.hp = 1;
      saved.add(av.playerId);
    }
    for (final id in saved) {
      wildMagicEvents.add(
        WildMagicEvent(
          effect: WildMagicEffectKind.phoenix,
          casterId: id,
          bracketSteps: 0,
          affectedPlayerIds: [id],
          note: 'risen from the ashes at 1 HP',
        ),
      );
    }
  }

  /// Whether [creature]'s whole footprint fits at [center].
  bool _footprintValid(HexCoord center, Minion creature) {
    final flying = creature.abilities.contains(SummonAbility.flying);
    for (final t in footprintFor(center, creature.abilities)) {
      if (!state.battlefield.isInBounds(t)) return false;
      if (!flying && tileBlocksMovement(state.tileEffects[t])) return false;
      // Bodies are exclusive (see [tileOccupied]). Flying gets no exemption
      // here the way a wizard's walk does: a creature's AI moves one tile at a
      // time and each of those tiles is somewhere it comes to rest, so there
      // is no "passing through" to distinguish from landing.
      if (tileOccupied(state, t, ignoreMinionId: creature.id)) return false;
    }
    return true;
  }

  /// Apply mana gain to [av] and fire the manaMirror trigger on any active
  /// Reflections links where [av] is the link's target.
  void applyManaGain(WizardAvatar av, int amount) {
    if (amount <= 0) return;
    av.mana = (av.mana + amount).clamp(0, av.maxMana);
    for (final link in state.reflectionLinks) {
      if (link.targetId != av.playerId) continue;
      if (!link.activeTriggers.contains(ReflectionTrigger.manaMirror)) continue;
      final mirror = state.avatars
          .where((a) => a.playerId == link.casterId && a.isAlive)
          .firstOrNull;
      if (mirror == null) continue;
      mirror.mana = (mirror.mana + amount).clamp(0, mirror.maxMana);
    }
  }

  void _addStatus(
    WizardAvatar av,
    String typeId,
    Map<String, int> mods,
    int turns,
  ) {
    StatusEffect.applyTo(av.activeStatusEffects, typeId, mods, turns);
  }

  WizardAvatar? avatarById(String id) =>
      state.avatars.where((av) => av.playerId == id).firstOrNull;

  /// Sweeps illusions standing next to a scryer. Kept as a named method rather
  /// than an inlined [EffectApplicator] call so the phase reads the same here
  /// as it did in TurnLoop, where the identical one-line forwarder still lives
  /// for the movement and free-move callers.
  void dispelIllusionsNearScryers() =>
      EffectApplicator.dispelIllusionsNearScryers(state);

  static bool isAdjacent(HexCoord a, HexCoord b) => hexDistance(a, b) == 1;

  // ── Phase 5: Action resolution ────────────────────────────────────────────
  //
  // Fifth across the seam, and the largest. Action resolution is the phase the
  // header above called "the hard one": it suspends, and until now it suspended
  // for reasons that genuinely belonged to TurnLoop. That is no longer true.
  // Every trust decision it depended on — peer proof verification, the Merkle
  // book check, the mystery-commitment check, the delayed-fire verification —
  // now happens BEFORE it is called, and arrives as data: verified `(actor,
  // action)` pairs plus the [CertifiedCast] the verification produced.
  //
  // What is left is a single suspension point, and it is not a protocol step
  // this phase takes — it is one an *effect* takes. Spontaneous Combustion
  // forces its victims to reveal and cast from a private hand, which needs a
  // network round trip (WILD_MAGIC_PLAN.md §9.5). That was already abstracted
  // behind [ForcedCastHost] before this move; here it is reached through
  // [ActionResolutionHost.drainForcedCasts] and nothing else in this file
  // awaits anything. So [resolveActions] is `async` in the same sense a method
  // calling a callback is: the suspension belongs to the host, at one named
  // seam, and the deterministic sequencing either side of it is unchanged.
  //
  // Four operations that were already here — [_moveCloud], [_reapDead],
  // [_breakStatuesque], [_creatureTurn] — existed as public entry points ONLY
  // because this phase still lived in TurnLoop and had to reach back across.
  // They are private again now (see the bottom of this section).

  /// Resolves every action declared this turn, in canonical order.
  ///
  /// [actions] is the caller's ordered pairing of actor to action: its own
  /// player first, then the peer, then any delayed fires. That order is
  /// *device-relative*, which is safe only because the sort below is a TOTAL
  /// order — the `playerId` fallback is what makes it one, and removing it
  /// would let the two devices stably sort equal-comparing entries differently.
  /// See the comment on the sort.
  ///
  /// Everything in [actions] is already trusted: a peer cast reached here only
  /// by passing proof verification and the book-membership check, and a delayed
  /// fire only by matching its commitment. This method makes no trust decision
  /// and can reject nothing — a cast that "fails" here fails on a *rule*
  /// (mana, range, a cloud, a counter charm), never on a claim.
  ///
  /// [delayedCertified] carries each delayed fire's [CertifiedCast], captured on
  /// the turn it was declared (TODO(B-1) closure — see
  /// [PendingDelayedSpell.certified]). Keyed by object IDENTITY, not by
  /// commitmentHex: each fire builds a fresh SpellCastAction, so identity is
  /// unique, while commitmentHex is grid-only and a same-grid current-turn cast
  /// would collide with it.
  ///
  /// [certifiedPeerCasts] is the same thing for the CURRENT turn's peer cast:
  /// the [CertifiedCast] `PeerCastVerifier` established moments ago, keyed by
  /// the certified commitmentHex. One map rather than the three parallel ones it
  /// replaced — they were always written together, read together and keyed
  /// identically, so splitting them only created the possibility of a partial
  /// set, which is the shape of a trust bug rather than a useful state.
  Future<void> resolveActions(
    ActionResolutionContext ctx, {
    required List<(WizardAvatar, TurnAction)> actions,
    required Map<TurnAction, CertifiedCast> delayedCertified,
    required Map<String, HexCoord> preMovPos,
    required Map<String, int> preMovRange,
    required HashRng rng,
    Map<String, List<HexCoord>> traversedPaths = const {},
    Map<String, CertifiedCast> certifiedPeerCasts = const {},
  }) async {
    // Extract the spell from any spell-like action for sort comparisons.
    SpellAsset? extractSpell(TurnAction a) => switch (a) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };

    // Quick and Sluggish are *relative* orderings among the spells actually
    // resolving this turn ("resolve first/last unless others are also
    // quick/sluggish" — design doc §Effect Table, Fire-Air row). So when
    // every such cast shares the modifier it cancels out and the group
    // collapses to normal — which also covers the single-caster case: the
    // lone caster is trivially "all of them", so a sluggish wizard casting
    // alone still resolves at the front rather than being demoted behind
    // the other player's Pass/Dash/Meditate.
    //
    // SpellCastAction only, deliberately: a MysterySpellCastAction still
    // standing at this point is the *delayed* variant (the immediate one was
    // rewritten by TurnLoop's mystery check upstream), so it stashes a
    // PendingDelayedSpell rather than resolving, and must not count as
    // "another cast" this turn. Delayed spells actually firing now arrive as
    // SpellCastActions in [actions] and do count.
    final casters = actions
        .where((p) => p.$2 is SpellCastAction)
        .map((p) => p.$1)
        .toList();
    final allCastsQuick = casters.every((av) => av.isQuick);
    final allCastsSluggish = casters.every((av) => av.isSluggish);

    // Assign resolution group per action.
    _ResolutionGroup group((WizardAvatar, TurnAction) pair) {
      final av = pair.$1;
      final action = pair.$2;
      return switch (action) {
        PassAction() ||
        DashAction() ||
        MeditateAction() => _ResolutionGroup.normalSpell,
        SpellCastAction() || MysterySpellCastAction() =>
          av.isQuick && !allCastsQuick
              ? _ResolutionGroup.quickSpell
              : av.isSluggish && !allCastsSluggish
              ? _ResolutionGroup.sluggishSpell
              : _ResolutionGroup.normalSpell,
      };
    }

    // Sort: group first, then T ascending, then commitmentHex within group.
    // The playerId fallback is what makes this a *total* order: without it,
    // a cast and a non-cast (or two non-casts) in the same group compare
    // equal, and since [actions] is built local-actor-first the two clients
    // would then stably sort them into different orders. Nothing a Pass/
    // Dash/Meditate does is order-sensitive today, so that never actually
    // diverged canonical state — but it's a lockstep landmine, and this
    // change makes ties strictly more likely by collapsing groups.
    final sorted = List.of(actions)
      ..sort((a, b) {
        final dc = group(a).index.compareTo(group(b).index);
        if (dc != 0) return dc;
        final sa = extractSpell(a.$2);
        final sb = extractSpell(b.$2);
        if (sa != null && sb != null) {
          final tc = sa.t.compareTo(sb.t);
          if (tc != 0) return tc;
          final cc = sa.commitmentHex.compareTo(sb.commitmentHex);
          if (cc != 0) return cc;
        }
        return a.$1.playerId.compareTo(b.$1.playerId);
      });

    for (final (actor, action) in sorted) {
      if (!actor.isAlive) continue;
      switch (action) {
        case PassAction():
          _regressChain(actor);

        case DashAction():
          // Speed doubling already applied during movement resolution (see
          // the isDashing flag folded into the move commit-reveal). Nothing
          // left to do at resolution time — treated like Pass for chain
          // purposes.
          _regressChain(actor);

        case MeditateAction():
          applyManaGain(actor, kMeditateManaGain);
          _regressChain(actor);

        case SpellCastAction(
          :final spell,
          :final targetHex,
          :final isPotent,
          :final isVelocity,
          :final isEfficiency,
          :final conveyorDirection,
        ):
          // Statuesque (wild magic, row 3 Earth) breaks on a cast — a choice,
          // unlike Pass / Dash / Meditate / melee, which leave it standing.
          // Broken here, before resolution, so it covers a fizzled or
          // countered cast too: the wizard still chose to cast.
          _breakStatuesque(actor.playerId);
          // The proof-attested semantics of THIS cast, resolved once for every
          // consumer below (counter-charm matching, applySpell, mana, chain
          // state) so they can never disagree about what the proof said.
          //
          // A delayed fire brings its own, captured on its declaration turn, and
          // is checked FIRST: its commitmentHex may well collide with a
          // same-grid cast this turn, and the pending record is the one that
          // belongs to this action.
          //
          // Otherwise this branches on WHICH DEVICE owns the cast, exactly as
          // the Mystery declaration path below does, and for the same reasons:
          //
          //   * Our OWN cast reconstructs its semantics from its own proof
          //     bytes. That is NOT verification — this device authored the
          //     spell and has nothing to prove to itself. It is how we
          //     guarantee we read our own proof the way the peer's verifier
          //     will. Before M4.22 this fell through to `elementSequence(spell)`
          //     / `wireBaseManaCost(spell)` — the AUTHORED `SpellAsset.formula`,
          //     which no proof attests — so the two devices resolved one cast
          //     from two different element sequences whenever an asset's
          //     authored metadata had drifted from its proof. The shipped
          //     Basic Windhound had drifted (12 authored elements against three
          //     certified), and the pair forfeited on the state hash the turn it
          //     was cast. See docs/M4_findings.md §M4.22.
          //   * A PEER's cast reads what [certifiedPeerCasts] holds — the
          //     semantics real `PeerCastVerifier` verification derived from
          //     VERIFIED outputs moments ago. That branch is untouched and must
          //     stay that way: a peer's proof is verified or the match forfeits.
          //     The parse behind it is only reached when verification never ran
          //     at all (solo, or no verifier/VK wired), which is the pre-existing
          //     `PeerCastUncertified` case — no weaker than the wire formula it
          //     replaces there, and identical on both devices.
          //
          // Branching on ownership rather than on map presence matters: the map
          // is keyed by commitmentHex, and the commitment is grid-only
          // (CLAUDE.md invariant 2), so a peer casting the same grid this turn
          // would otherwise hand the local caster the peer's certified entry.
          final cert = delayedCertified[action] ??
              (ctx.host.isLocalPlayer(actor.playerId)
                  ? ctx.host.certifiedFromProofBytes(spell)
                  : certifiedPeerCasts[spell.commitmentHex] ??
                      ctx.host.certifiedFromProofBytes(spell));
          final certFormulas = cert?.formulas;
          final certElementSequence = cert?.elementSequence;
          final certWildMagic = cert?.wildMagic;
          // Recall NEVER gates the loadout enhancement and never fizzles a
          // cast (VOCAL_RECALL_PLAN.md §4: getting words wrong costs mana,
          // full stop). The only fizzle left is a cast whose recall-inflated
          // cost outran the caster's pool, and that is decided at commit time
          // on both devices — see [SpellCastAction.fizzledForMana].
          final enhancements = CastingEnhancements(
            isPotent: isPotent,
            isVelocity: isVelocity,
            isEfficiency: isEfficiency,
            gameMode: ctx.host.componentsGameMode,
            fizzle: action.fizzledForMana,
          );
          // Clouds (Water-Fire) base effect: an entity standing in a cloud's
          // radius (or carrying the lingering Earth-flavor restriction) may
          // only target adjacent tiles, and a target tile inside a cloud's
          // radius is likewise only reachable from an adjacent tile. Cloud
          // position here reflects this turn's Summons-phase move (already
          // resolved by the time Action resolution runs), so the check uses
          // where the cloud actually is for the rest of the turn, not last
          // turn's stale position.
          final ignoredCloudRestriction =
              _cloudBoundToAdjacent(actor, targetHex) &&
              hexDistance(actor.position, targetHex) > 1;
          // Spell range, enforced by the trusted engine rather than trusted to
          // the caster's UI. battle_screen's `_maxCastRange` only decides what
          // a human player's own client lets them tap; a modified client — or
          // the Solo Practice dummy, which encodes its cast straight onto the
          // wire — never goes through it. Without this, `effectiveSpellRange`
          // (and with it Earthen Inertia's whole −1) was advisory against a
          // peer, and a peer could declare a target clean across the field.
          // Exactly the reasoning that gave `_cloudBoundToAdjacent` its
          // engine-side twin.
          //
          // **Targeting is valid so long as it was valid when the cast was
          // completed** (ruling 2026-08-06). So BOTH halves of the test are
          // read as of that moment, never as of resolution:
          //
          //   * the origin — where the caster stood when they declared, not
          //     where they ended up. Movement resolves in Phase 3, before
          //     this, and the UI gated the tap against their pre-move tile;
          //     `actor.position` would fizzle the legal cast of anyone who
          //     walked away from their target afterwards.
          //   * the reach — [preMovRange], snapshotted at Phase 2. Reading
          //     `actor.effectiveSpellRange` here would let an Earthen Inertia
          //     resolving EARLIER in the same action phase retroactively clip
          //     a cast that was legal when its caster chose it.
          //
          // A delayed (Mystery) fire carries both from the turn it was
          // declared on — see [PendingDelayedSpell.declaredRange]. Its target
          // was committed then and never revisited, so judging it against a
          // range it acquired while sitting pending would punish the player
          // for the passage of time.
          final castOrigin = action.delayedOriginHex ??
              preMovPos[actor.playerId] ??
              actor.position;
          // Velocity (Air loadout enhancement) adds to reach on top of
          // whichever base the three bullets above selected — it's a
          // per-cast choice, not an avatar stat, so it can't live inside
          // effectiveSpellRange/preMovRange like Earthen Inertia's rangeUp/
          // rangeDown do. A delayed (Mystery) cast never carries isVelocity
          // (Earth and Air are mutually-exclusive loadout picks — see
          // casting_enhancements.dart), so this only ever adds to an
          // immediate cast's own declared range.
          final castRange = (action.delayedRange ??
                  preMovRange[actor.playerId] ??
                  actor.effectiveSpellRange) +
              (isVelocity ? CastingEnhancements.velocityRangeBonus : 0);
          final outOfRange = hexDistance(castOrigin, targetHex) > castRange;
          if (enhancements.fizzle || ignoredCloudRestriction || outOfRange) {
            // Botched incantation, an illegal cast that ignored the cloud's
            // adjacent-only targeting restriction, or one aimed past the
            // caster's reach: spell fails entirely. Mana was already spent at
            // commit time. Treated like
            // a Pass for chain purposes.
            _regressChain(actor);
          } else {
            // Watery Inertia (Range Modification, Water): a turbulent caster
            // keeps their aim but not their reach — the real destination is
            // rolled here, ABOVE the orb event and everything downstream, so
            // the orb visibly flies to where the spell went and the card
            // reveal blooms there too. That placement is also why the cloud
            // legality check above reads the DECLARED hex: the roll is not
            // the player's choice, so it can't make their cast illegal.
            final resolvedTarget = _turbulentTarget(ctx, actor, targetHex);
            // The cast's element sequence, from the proof wherever there is a
            // proof to read (M4.22). Everything below reads THIS, so the orb
            // that flies, the charm that matches it and the effects that
            // resolve are all one reading of one cast.
            final castSequence = certElementSequence ?? elementSequence(spell);
            // The orb still flies for a countered cast (it visibly happened
            // and drew a counter, unlike a fizzle) — emitted once here for
            // both outcomes below, then the two diverge.
            //
            // Presentation only (the orb's colour), but sourced from the
            // certified sequence anyway: it costs nothing, and an orb whose
            // colour disagreed with the effects it delivered would be a tell
            // that the two devices were reading different data.
            final affinity = castSequence.isEmpty
                ? null
                : spellAffinityFromZone(castSequence.first);
            if (affinity != null) {
              ctx.castEvents.add(
                SpellCastEvent(
                  casterId: actor.playerId,
                  fromHex: action.delayedOriginHex ?? actor.position,
                  toHex: resolvedTarget,
                  affinity: affinity,
                ),
              );
            }
            // Counter charms match the cast's certified element sequence, so
            // the trigger test reads exactly what applySpell resolves. Since
            // M4.22 that is the certified sequence on BOTH devices for any
            // proof-backed cast — a charm that countered a peer's Windhound
            // used to slide off the caster's own copy of it, because the two
            // were matching different lists.
            final counterHit = _findCounteringCharm(castSequence);
            // Whether the charm swallowed the WHOLE cast. Measured in
            // formulas for an incantation and in elements for a summon,
            // because a summon reads residuals too (CreatureSpec.fromElements
            // counts every activation, parsedFormulas drops the trailing 1–2).
            final counteredFormulas = counterHit?.formulas ?? 0;
            final fullyCountered = counterHit != null &&
                (spell.isSummon
                    ? counteredFormulas * kElementsPerFormula >=
                        castSequence.length
                    : counteredFormulas >= castSequence.length ~/ kElementsPerFormula);
            if (counterHit != null) _triggerCounterCharm(counterHit);
            if (fullyCountered) {
              // Nothing of the cast survives: consume the charm, record a
              // countered ResolvedSpellEvent for the UI's card reveal
              // (battle_screen.dart shows it, then dissolves it — no bloom,
              // no thumbnail, since nothing was actually created), and skip
              // application entirely. Mana was already spent at commit time,
              // so this is otherwise treated like a Pass for chain purposes.
              //
              // Keeping this path byte-for-byte the old one is deliberate: it
              // is what preserves wild-magic invariant A1 ("no wild magic on a
              // countered cast") for free, since applySpell — the only place
              // wild magic fires — is never reached. A PARTIAL counter is a
              // cast that really happened, so it does resolve and its wild
              // magic does fire; see the else branch.
              ctx.resolvedSpells.add(
                ResolvedSpellEvent(
                  spell: spell,
                  casterId: actor.playerId,
                  targetHex: resolvedTarget,
                  isSummon: spell.isSummon,
                  wasCountered: true,
                  counteredFormulas: counteredFormulas,
                  counterCharmOwnerId: counterHit.owner.playerId,
                ),
              );
              _regressChain(actor);
            } else {
              // Snapshot the field so the UI's resolution reveal can tell which
              // clouds/terrain/minions THIS spell brought into being (diffed
              // right around its application), and animate them in per-card.
              final cloudsBefore = state.clouds.map((c) => c.id).toSet();
              final tilesBefore = state.tileEffects.keys.toSet();
              final minionsBefore = state.minions.map((m) => m.id).toSet();
              final bookmarksBefore = {
                for (final av in state.avatars) av.playerId: av.bookmarkCount,
              };
              // FuelTransmutation wither/reactivate (§9): a dedicated,
              // per-caster RNG, kept separate from the shared actionRng
              // stream so drawing from it can never desync that stream.
              final witherRng = HashRng(
                ctx.host.witherSeed(ctx.entropy, actor.playerId),
              );
              final summoned = await applySpell(
                ctx,
                actor,
                spell,
                resolvedTarget,
                enhancements,
                rng,
                traversedPaths: traversedPaths,
                certFormulas: certFormulas,
                certElementSequence: certElementSequence,
                certWildMagic: certWildMagic,
                conveyorDirection: conveyorDirection,
                witherRng: witherRng,
                // A charm matched a prefix of this cast but not all of it:
                // the leading formulas are cancelled and the rest resolves.
                suppressedFormulas: counteredFormulas,
                // The rod is declared at Phase 0 now, not folded into the
                // action commit — every other activation is declared on the
                // turn it takes effect, and this keeps a delayed Mystery cast
                // from reserving a rod for three turns while its owner spends
                // the activation budget elsewhere (§3.1).
                rodRequested: actor.declaredActivation ==
                    AccoutrementKind.rodOfSpreading,
              );
              // Scattered Gusts (wild magic, row 3 Air): once active, every
              // cast blows the caster's bookmarks loose and they find a new
              // set. Free casts are exempt (A8) — they never reach here.
              if (state.wildMagic.scatteredGusts) {
                ctx.host.redrawHand(actor.playerId, ctx.entropy);
              }
              // A cloud born this turn would otherwise sit dead-still until
              // *next* turn's Phase 4 (moveClouds already ran, ahead of this
              // spell resolution, before the cloud existed) — give it its
              // Summons-phase move right now, same turn it's summoned, so it's
              // never visibly stationary. See _moveCloud's doc comment.
              for (final c in state.clouds) {
                if (!cloudsBefore.contains(c.id)) _moveCloud(c);
              }
              // Bookmark accoutrements gained/lost this resolution (e.g.
              // ArtifactsInteractionEffect Air/Fire, FuelTransmutationEffect
              // Fire/Air) resize the affected avatar's hand immediately —
              // handSize == bookmarkCount + 1 (see TurnLoop._reconcileHandSize).
              for (final av in state.avatars) {
                final before = bookmarksBefore[av.playerId]!;
                if (av.bookmarkCount != before) {
                  ctx.host.reconcileHandSize(
                    av.playerId,
                    before,
                    av.bookmarkCount,
                    ctx.entropy,
                  );
                }
              }
              ctx.resolvedSpells.add(
                ResolvedSpellEvent(
                  spell: spell,
                  casterId: actor.playerId,
                  targetHex: resolvedTarget,
                  isSummon: spell.isSummon,
                  counteredFormulas: counteredFormulas,
                  counterCharmOwnerId: counterHit?.owner.playerId,
                  summonMinionId: summoned?.id,
                  summonPosition: summoned?.position,
                  createdCloudIds: [
                    for (final c in state.clouds)
                      if (!cloudsBefore.contains(c.id)) c.id,
                  ],
                  createdTileHexes: [
                    for (final k in state.tileEffects.keys)
                      if (!tilesBefore.contains(k)) k,
                  ],
                  createdMinionIds: [
                    for (final m in state.minions)
                      if (!minionsBefore.contains(m.id)) m.id,
                  ],
                ),
              );
            }
          }

        case MysterySpellCastAction(
          :final spell,
          :final mysteryCommitment,
          :final isPotent,
          :final isVelocity,
        ):
          // Immediate mystery spells were converted to SpellCastAction by the
          // caller's mystery check before reaching here. A
          // MysterySpellCastAction at this point is always the non-immediate
          // (delayed) variant.
          //
          // A declaration the caster could not pay for never enters the
          // pending state (M4.21). Settlement has already refunded the mana and
          // marked the action; queueing it anyway made an unaffordable spell
          // into a fully-effective free cast one turn later, because a delayed
          // fire is deliberately never re-priced — the affordability question
          // is asked once, at the declaration turn's Phase-5 settlement, and
          // this is where that answer has to bite. **Do not "fix" this by
          // re-pricing at fire time instead:** the caster's mana three turns
          // later has nothing to do with whether they could afford the cast
          // they committed to, and asking twice is how two devices come to
          // disagree.
          //
          // The turn is still spent, and it is spent the way every other mana
          // fizzle spends one — [_regressChain], the same call the ordinary
          // cast path's `enhancements.fizzle` branch makes. Nothing
          // Mystery-specific is invented here, and nothing is placed on the
          // battlefield: a fizzled declaration leaves no pending orb, because a
          // visible placeholder that can never fire is a tell about the
          // caster's mana that the Mystery mechanic exists to withhold.
          if (action.fizzledForMana) {
            _regressChain(actor);
            break;
          }
          // TODO(B-1) closure for delayed fires: capture the proof-attested
          // semantics NOW, while the verification that produced them is still
          // in scope. Up to three turns from now the turn-scoped certified maps
          // are long cleared, and resolving from `spell.formula` would mean
          // resolving from a wire value no proof attests — a peer could prove a
          // cheap grid, attach arbitrary formulas, and have them resolve.
          //
          // The two arms sit on opposite sides of the trust boundary but read
          // the same proof bytes at the same tier, so both devices store
          // identical values for the same pending spell: the owner parses its
          // own proof, the verifier reuses what the peer verification already
          // derived from the VERIFIED outputs. Branching on ownership rather
          // than on map presence matters — the map is keyed by commitmentHex,
          // and the commitment is grid-only (CLAUDE.md invariant 2), so a peer
          // casting the same grid at a different T this turn would otherwise
          // hand the local caster the peer's certified data.
          //
          // The ownership question and the proof PARSING are both the host's:
          // this class has no notion of which device it is, and reading a proof
          // blob is the trust layer's job even when — as here — it only derives
          // and never rejects.
          final certifiedDeclaration = ctx.host.isLocalPlayer(actor.playerId)
              ? ctx.host.certifiedFromProofBytes(spell)
              : certifiedPeerCasts[spell.commitmentHex] ??
                  // Verification not wired up (solo/dev): parse unverified, the
                  // same way the owner's device does. No weaker than the wire
                  // formula this replaces, and identical on both devices.
                  ctx.host.certifiedFromProofBytes(spell);
          state.pendingDelayedSpells.add(
            PendingDelayedSpell(
              id: PendingDelayedSpell.idFromCommitment(mysteryCommitment),
              ownerId: actor.playerId,
              spell: spell,
              commitment: mysteryCommitment,
              castTurn: state.turnNumber,
              origin: actor.position,
              declaredRange: actor.effectiveSpellRange,
              certified: certifiedDeclaration,
              isPotent: isPotent,
              isVelocity: isVelocity,
            ),
          );
      }
    }

    _reapDead(rng);
    applyPhoenixSaves(ctx.wildMagicEvents);
  }

  /// Returns the [Minion] just summoned, if [spell.isSummon] and the cast
  /// actually produced a creature (see [_castSummon]); null otherwise.
  ///
  /// Public because a forced free cast re-enters here from the other side of
  /// the [ActionResolutionHost] seam: TurnLoop's `resolveForcedCast` is what
  /// [ForcedCast] calls once a reveal has been verified, and its whole body is
  /// one call to this with the A8 flags set.
  ///
  /// [fireWildMagic] is **the recursion guard for the whole wild-magic
  /// system**. It is false for Spontaneous Combustion's free casts (A8) and
  /// for Rippling Reflections' doubled application (A7). Without it one
  /// Spontaneous Combustion can fan out into an unbounded cast cascade, and a
  /// doubled spell fires its global effect twice. Do not remove it, and do not
  /// add a caller that leaves it true for a cast the player did not choose.
  ///
  /// [suppressedFormulas] is a trajectory counter charm's partial counter
  /// (docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 2): that many LEADING formulas
  /// are cancelled and the remainder of the cast resolves normally. For a
  /// summon it cancels the corresponding leading stat contributors instead
  /// (3 per formula), which can shrink the creature or, at the limit, produce
  /// none. A cast whose formulas are ALL suppressed never gets here — the
  /// caller takes the full-counter path and skips this method entirely, which
  /// is what keeps wild-magic invariant A1 true without a flag.
  Future<Minion?> applySpell(
    ActionResolutionContext ctx,
    WizardAvatar actor,
    SpellAsset spell,
    HexCoord targetHex,
    CastingEnhancements enhancements,
    HashRng rng, {
    Map<String, List<HexCoord>> traversedPaths = const {},
    List<ParsedFormula>? certFormulas,
    List<BorderZone>? certElementSequence,
    List<WildMagicTrigger>? certWildMagic,
    HexCoord? conveyorDirection,
    HashRng? witherRng,
    bool rodRequested = false,
    bool fireWildMagic = true,
    bool subjectToRippling = true,
    bool skipChainUpdate = false,
    int suppressedFormulas = 0,
  }) async {
    // ── Wild magic (docs/WILD_MAGIC_PLAN.md §4.5) ─────────────────────────
    // Design doc L746: "Within a single player's spell: wild magic first, then
    // formula effects in the order the CA created them." So this runs BEFORE
    // the isSummon early return (A2 — a summon spell still has a certified
    // trajectory and formulas, and its wild magic fires) and before the
    // formula loop. Countered and fizzled casts never reach applySpell at
    // all, so A1 ("no wild magic on a countered or fizzled cast") holds for
    // free — do not add a hook upstream of the counter check.
    if (fireWildMagic) {
      await _fireWildMagic(ctx, actor, spell, certWildMagic);
    }

    // ── Rippling Reflections (row 3, Water) ───────────────────────────────
    // Once active there is no third outcome: every spell either fizzles or
    // resolves twice. Rolled after wild magic, before the formula loop.
    var repeatWholeSpell = 1;
    if (subjectToRippling && state.wildMagic.ripplingFizzlePct != null) {
      final pct = state.wildMagic.ripplingFizzlePct!;
      final coin =
          HashRng(ctx.host.ripplingSeed(ctx.entropy, actor.playerId))
              .nextInt(100);
      if (coin < pct) {
        // Fizzle: no formula effects at all, drift 10% toward doubling.
        // Treated as a fizzle for chain purposes, matching the existing
        // enhancements.fizzle branch in [resolveActions].
        state.wildMagic.ripplingFizzlePct = (pct - 10).clamp(0, 100);
        _regressChain(actor);
        return null;
      }
      // Double: apply the formula effects twice, drift 10% toward fizzling.
      state.wildMagic.ripplingFizzlePct = (pct + 10).clamp(0, 100);
      repeatWholeSpell = 2;
    }

    // ── Line of sight (docs/WALL_LOS_PLAN.md §2.1, §5.2) ──────────────────
    // An earthen wall or a Big creature standing between the caster and the
    // declared target does NOT reject the cast — the spell resolves on the
    // blocker instead. Computed once here, above the summon branch, because
    // both cast modes need it (they just land differently: see below).
    final penetration = _penetrationDamageFor(actor);
    final blocker = losBlockerTile(
      state,
      actor.position,
      targetHex,
      penetrating: penetration != null,
    );

    // design doc "Summons": a summon-mode spell's element sequence is read
    // as a creature instead of being resolved as incantation effects.
    // Bypasses EffectResolver/EffectApplicator entirely -- summoning is
    // "instead of creating spell effect incantations", not a 17th effect
    // kind. It still builds/spends the chain like any other spell (R4).
    if (spell.isSummon) {
      // A blocked summon is the one case that does NOT resolve on the blocker:
      // a creature needs a tile it can stand on, and a wall is exactly the tile
      // nothing can stand in. It arrives at the last clear hex BEFORE the
      // blocker instead — the summoning got as far as it could and the creature
      // stepped out there. (_castSummon's own spawn search then walks outward
      // from that anchor if it is occupied.)
      final sequence = certElementSequence ?? elementSequence(spell);
      // A counter charm cancels leading stat contributors, 3 per matched
      // formula — the creature arrives smaller, or (all contributors gone)
      // not at all. Chain state below still reads the FULL sequence: the
      // caster channelled the whole spell; the charm interfered with what it
      // produced, not with what they were building.
      final survivingSequence = suppressedFormulas <= 0
          ? sequence
          : sequence
              .skip(suppressedFormulas * kElementsPerFormula)
              .toList(growable: false);
      final minion = _castSummon(
        ctx,
        actor,
        blocker == null
            ? targetHex
            : tileBeforeBlocker(actor.position, targetHex, blocker),
        survivingSequence,
        spell.summonPersonality,
        enhancements,
        rng,
        rodRequested: rodRequested,
      );
      if (!skipChainUpdate) {
        _updateChainState(actor, spell, certElementSequence: sequence);
      }
      return minion;
    }

    // Null certFormulas now means a local spell (trusted wire formula) or a
    // proofless dev-flag spell. Peer delayed fires used to land here too —
    // they carry their declaration-turn [CertifiedCast] now, so a peer can no
    // longer launder an unattested formula list through a Mystery delay.
    // TODO(B-1): the last of it is kAllowProoflessSpells. Once that flag is
    //   deleted, a null entry for any peer spell must forfeit rather than
    //   fall through here.
    final allFormulas = certFormulas ?? parsedFormulas(spell);
    // Partial counter: the charm cancelled the leading formulas outright, so
    // they never reach EffectResolver. Chain state below still reads the full
    // [certFormulas] — see the summon branch's note.
    final formulas = suppressedFormulas <= 0
        ? allFormulas
        : allFormulas.skip(suppressedFormulas).toList(growable: false);
    if (formulas.isEmpty) {
      // Wild-magic stub (zero formulas = void spell). Nothing resolves, so a
      // requested Rod of Wind is NOT consumed here (don't burn a rod on a
      // no-op cast).
      return null;
    }

    // Incantation effects resolve ON the blocker (§2.1) — unlike a summon,
    // which needs somewhere to stand. Every formula below dispatches at
    // [resolveHex], not at [targetHex]; this is the authoritative path both
    // peers run, and it is what makes the per-effect terrain table (§6)
    // reachable at all.
    final resolveHex = blocker ?? targetHex;
    if (penetration != null && penetration > 0) {
      // Firey Inertia's other half, finally wired: "1 [2 potent] damage to
      // entities in hexes en route". Fires once per cast, not once per
      // formula — it is the spell's flight, not an effect.
      _applyPenetrationEnRoute(actor, targetHex, penetration);
    }

    // Rod of Wind: consume one now (if requested and owned) — a real cast
    // with at least one effect follows, so the rod does something. +1 radius
    // applies to every spatial effect of this spell (see EffectApplicator).
    final radiusBonus = _consumeRodOfSpreading(actor, rodRequested);

    // Absorption rod: tracked per-target for this whole spell.
    final rodConsumedFor = <String>{};

    // Conveyor-chain events (knockback landing on a conveyor mid-spell)
    // collected across every formula of this cast, then folded into the
    // per-turn list once for the UI's belt/loop animation.
    final conveyorEvents = <ConveyorChainEvent>[];

    // Rippling Reflections' "resolve twice" wraps the FORMULA LOOP, not the
    // whole method — structuring it here means a doubled spell physically
    // cannot reach the wild-magic seam or re-roll the coin (A7), rather than
    // relying on a flag to stop it.
    for (var pass = 0; pass < repeatWholeSpell; pass++) {
    for (final formula in formulas) {
      final descriptor = EffectResolver.resolve(formula, enhancements);

      // A pending Air-Fire multiplierCycle (Bellows) on this formula's
      // affinity re-resolves the formula's effect into extra copies inserted
      // immediately after the original in the resolution order -- 2 total
      // applications normally, 3 under potency. Consuming (removing) the
      // entry here means only the first formula of a matching affinity in
      // this spell is amplified, matching the design doc's singular "next
      // effect of [element]" wording.
      final formulaAffinity = spellAffinityFromZone(formula.affinity);
      final repeatCount =
          actor.pendingEffectMultipliers.remove(formulaAffinity)?.multiplier ?? 1;

      for (var i = 0; i < repeatCount; i++) {
        EffectApplicator.apply(
          ApplyContext(
            descriptor: descriptor,
            targetTile: resolveHex,
            caster: actor,
            state: state,
            rng: rng,
            rodConsumedFor: rodConsumedFor,
            movePaths: traversedPaths,
            chosenConveyorDirection: conveyorDirection,
            conveyorChainEvents: conveyorEvents,
            drawSchedules: ctx.drawSchedules,
            witherRng: witherRng,
            effectiveRadiusBonus: radiusBonus,
          ),
        );
      }
    }
    }
    ctx.conveyorChainEvents.addAll(conveyorEvents);

    // Update chain state after casting. A forced free cast (A8) skips this —
    // it neither builds nor breaks the chain.
    if (!skipChainUpdate) {
      _updateChainState(actor, spell, certFormulas: certFormulas);
    }
    return null;
  }

  // ── Line of sight (docs/WALL_LOS_PLAN.md) ─────────────────────────────────

  /// Where [actor]'s spell actually lands, given Watery Inertia
  /// (StatusEffectId.turbulent): the declared direction is kept, the distance
  /// is re-rolled 1..`effectiveSpellRange`. Returns [declared] unchanged when
  /// the caster isn't turbulent — every cast calls this, so the not-turbulent
  /// path must be free of side effects (it must not burn a nonce).
  ///
  /// Design v4.0 §303: *"next spell fires in intended direction but range
  /// randomized 1–max"*. Two rulings, 2026-08-06: the status is **not**
  /// consumed by the cast — it randomises every spell for its full 4[5] turns
  /// — and *max* is the caster's own range stat, so a roll higher than the
  /// declared distance sails **past** the target rather than being clamped to
  /// it. Falling short and overshooting are both real outcomes.
  ///
  /// Rolled from commit-reveal entropy (tag 0x0B), never `Random`: the design
  /// doc names turbulent range in its jointly-generated-randomness list, and a
  /// locally-rolled destination would desync the two devices on the very next
  /// state hash.
  HexCoord _turbulentTarget(
    ActionResolutionContext ctx,
    WizardAvatar actor,
    HexCoord declared,
  ) {
    if (!actor.hasTurbulent) return declared;
    final from = actor.position;
    final n = hexDistance(from, declared);
    // A cast on your own tile has no direction to be thrown off along.
    if (n == 0) return declared;

    final rng = HashRng(ctx.host.turbulentSeed(ctx.entropy, actor.playerId));
    var rolled = rng.nextInt(actor.effectiveSpellRange) + 1; // 1..max

    // Same axial lerp-and-round hexLinePath walks the line with, so a rolled
    // distance shorter than the declared one lands exactly on a tile the
    // spell would have flown through. t > 1 extrapolates past the target,
    // which is the overshoot case.
    while (rolled > 0) {
      final t = rolled / n;
      final hex = HexCoord(
        (from.q * (1 - t) + declared.q * t).round(),
        (from.r * (1 - t) + declared.r * t).round(),
      );
      // An overshoot can fly off the edge of the battlefield. Walk the roll
      // back rather than re-rolling: re-rolling would consume a second draw
      // from a stream the other device advances in lockstep.
      if (state.battlefield.isInBounds(hex)) return hex;
      rolled--;
    }
    return declared;
  }

  /// The `penetrationDamage` carried by [actor]'s active Firey Inertia
  /// (StatusEffectId.penetrating), or null when they don't have it.
  ///
  /// Non-null is the LOS exemption itself: a penetrating caster's spells
  /// ignore walls and Big creatures entirely. The value is the en-route tick
  /// ([_applyPenetrationEnRoute]) — it can legitimately be 0, which is why
  /// this returns a nullable int rather than using 0 as "absent".
  int? _penetrationDamageFor(WizardAvatar actor) {
    for (final fx in actor.activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId != StatusEffectId.penetrating) continue;
      return fx.modifiers['penetrationDamage'] ?? 0;
    }
    return null;
  }

  /// Deals [amount] damage to every entity in the hexes strictly between
  /// [actor] and [targetHex] — the flight path of a penetrating spell.
  ///
  /// Untyped: this is the spell physically passing through, not an elemental
  /// effect, so it runs no resistance wheel and leaves terrain alone (the
  /// whole point of penetrating is that terrain isn't in the way).
  void _applyPenetrationEnRoute(
    WizardAvatar actor,
    HexCoord targetHex,
    int amount,
  ) {
    for (final hex in hexLinePath(actor.position, targetHex)) {
      for (final av in state.avatars) {
        if (av.isAlive && av.position == hex) av.absorbDamage(amount);
      }
      for (final m in state.minions) {
        if (m.isAlive && m.occupiedTiles.contains(hex)) m.takeDamage(amount);
      }
    }
  }

  // ── Wild magic (docs/WILD_MAGIC_PLAN.md) ──────────────────────────────────

  /// Resolves every wild-magic trigger this cast carries, in row-then-element
  /// order, then drains any forced casts they queued.
  ///
  /// [certified] is the peer path: triggers derived by the caller's peer
  /// verification from the peer's VERIFIED proof public outputs, or — for a
  /// delayed fire — carried on the [PendingDelayedSpell] from the turn it was
  /// declared. Null means the local player's own cast (or the
  /// kAllowProoflessSpells dev flag), which the host re-derives from the proof
  /// bytes it already holds.
  ///
  /// **The one place this file suspends.** Spontaneous Combustion's reveal
  /// round trip is a protocol exchange for a private hand, so it can only
  /// happen on the host's side of the seam.
  Future<void> _fireWildMagic(
    ActionResolutionContext ctx,
    WizardAvatar actor,
    SpellAsset spell,
    List<WildMagicTrigger>? certified,
  ) async {
    final triggers = certified ??
        ctx.host.certifiedFromProofBytes(spell)?.wildMagic ??
        const [];
    if (triggers.isEmpty) return;

    for (final trigger in triggers) {
      final rng = HashRng(ctx.host.wildMagicSeed(ctx.entropy, actor.playerId));
      WildMagicApplicator.apply(
        WildMagicApplyContext(
          state: state,
          caster: actor,
          rng: rng,
          trigger: trigger,
          events: ctx.wildMagicEvents,
          hooks: ctx.host,
        ),
      );
    }

    // Spontaneous Combustion's reveal round trip sits HERE: after wild magic
    // has fired, before the triggering spell's own formula effects resolve
    // (WILD_MAGIC_PLAN.md §9.5). The applicator queues rather than resolving
    // because it is synchronous and this needs the network.
    await ctx.host.drainForcedCasts(ctx.entropy);
  }

  /// Rod of Wind (Air artifact): if [requested] and [actor] carries an
  /// unused rod, removes one from their loadout and returns +1 — the effective
  /// radius bonus for an incantation, or the size-rung bonus for a summon.
  /// Otherwise returns 0.
  ///
  /// [requested] comes from the caster's **Phase-0 declaration**
  /// (`declaredActivation == rodOfSpreading`) rather than a flag on the action
  /// commit, but this stays the single rod-consumption path — which is what
  /// keeps the trust boundary in one place. Reading the bonus from the actor's
  /// OWN accoutrements, not from the wire, is that boundary: a peer that
  /// declares a rod without actually owning one gets no bonus. This mirrors
  /// how TurnLoop's `_certifiedManaCost` recomputes cost from authoritative
  /// state rather than trusting the caster's word. Removing the accoutrement
  /// mutates the avatar, so it shows up in BattleState.toCanonicalBytes() and
  /// both devices stay in lockstep on the consumed rod.
  ///
  /// A rod declared but never spent (no cast, a fizzle, a countered cast)
  /// survives — the wasted resource is the once-per-turn activation budget,
  /// not the artifact.
  int _consumeRodOfSpreading(WizardAvatar actor, bool requested) {
    if (!requested) return 0;
    return _consumeAccoutrement(actor, AccoutrementKind.rodOfSpreading) ? 1 : 0;
  }

  // ── Summoning (design doc "Summons") ──────────────────────────────────────

  /// Derives a creature from [sequence] (CreatureSpec.fromElements) and
  /// spawns it near [targetHex] under [actor]'s control. Every summon —
  /// Potent or not — acts for the first time in Phase 5b, later this same
  /// turn. A Potent cast additionally lets the creature act immediately right
  /// here (design doc: "Summons may take an immediate turn the generation they
  /// are summoned if spell is made potent"), so it ends up acting twice in a
  /// row this turn: once here, once again in Phase 5b.
  ///
  /// The events that immediate action appends go into the turn's own
  /// [ActionResolutionContext.minionMoveEvents] /
  /// [ActionResolutionContext.minionAttackEvents], which
  /// [resolveSummonActions] then appends the Phase-5b sweep to — so the UI
  /// plays the bonus action first and the ordinary action after it, in the
  /// order they happened. Phase 5b used to replace both lists here, which
  /// discarded the bonus action's whole playback record (M4.17).
  Minion? _castSummon(
    ActionResolutionContext ctx,
    WizardAvatar actor,
    HexCoord targetHex,
    List<BorderZone> sequence,
    String personalityName,
    CastingEnhancements enhancements,
    HashRng rng, {
    bool rodRequested = false,
  }) {
    final spec = CreatureSpec.fromElements(sequence);
    if (spec == null) return null; // no activations -- nothing to summon (void)

    // Rod of Wind: a real creature will spawn, so consume the rod now (if
    // requested and owned) and bump the creature one size rung up the ladder.
    final sizeBonus = _consumeRodOfSpreading(actor, rodRequested);

    final personality = SummonPersonality.values.firstWhere(
      (p) => p.name == personalityName,
      orElse: () => SummonPersonality.aggressive,
    );
    final spawn = _findCreatureSpawnTile(targetHex, spec.abilities, sizeBonus);
    final creature = Minion(
      id: '${actor.playerId}_sm_${rng.nextInt(1 << 30).toRadixString(36)}',
      ownerId: actor.playerId,
      teamId: actor.teamId,
      position: spawn,
      affinity: spec.affinity,
      stats: spec.stats,
      elementSequence: sequence,
      abilities: spec.abilities,
      personality: personality,
      sizeBonus: sizeBonus,
    );
    state.minions.add(creature);
    if (enhancements.isPotent) {
      _creatureTurn(
        creature,
        rng,
        moveEvents: ctx.minionMoveEvents,
        attackEvents: ctx.minionAttackEvents,
        conveyorChainEvents: ctx.conveyorChainEvents,
      );
    }
    _fireSummonMirror(actor, creature, rng);
    return creature;
  }

  /// summonMirror (Reflections/Water-Water): when the Reflections link
  /// TARGET summons a creature, the link's CASTER receives an identical one
  /// near their own position.
  void _fireSummonMirror(WizardAvatar summoner, Minion summoned, HashRng rng) {
    for (final link in state.reflectionLinks) {
      if (link.targetId != summoner.playerId) continue;
      if (!link.activeTriggers.contains(ReflectionTrigger.summonMirror))
        continue;
      final mirrorOwner = avatarById(link.casterId);
      if (mirrorOwner == null || !mirrorOwner.isAlive) continue;
      final spawn = _findCreatureSpawnTile(
        mirrorOwner.position,
        summoned.abilities,
        summoned.sizeBonus,
      );
      state.minions.add(
        Minion(
          id: '${link.casterId}_ms_${rng.nextInt(1 << 30).toRadixString(36)}',
          ownerId: link.casterId,
          teamId: mirrorOwner.teamId,
          position: spawn,
          affinity: summoned.affinity,
          stats: summoned.stats,
          elementSequence: summoned.elementSequence,
          abilities: summoned.abilities,
          personality: summoned.personality,
          sizeBonus: summoned.sizeBonus,
          // Wears the original's card art, tinted (Minion.copiedFromMinionId).
          copiedFromMinionId: summoned.copiedFromMinionId ?? summoned.id,
        ),
      );
    }
  }

  /// Finds the nearest tile to [preferred] whose full footprint (see
  /// [footprintFor]) is in bounds, passable, and unoccupied.
  HexCoord _findCreatureSpawnTile(
    HexCoord preferred,
    Set<SummonAbility> abilities, [
    int sizeBonus = 0,
  ]) {
    bool footprintOpen(HexCoord center) {
      for (final t in footprintFor(center, abilities, sizeBonus)) {
        if (!state.battlefield.isInBounds(t)) return false;
        if (tileBlocksMovement(state.tileEffects[t])) return false;
        if (state.avatars.any((av) => av.isAlive && av.position == t))
          return false;
        if (state.minions.any((m) => m.isAlive && m.occupiedTiles.contains(t)))
          return false;
      }
      return true;
    }

    if (footprintOpen(preferred)) return preferred;
    for (final n in state.battlefield.neighbors(preferred)) {
      if (footprintOpen(n)) return n;
    }
    return preferred; // fallback: stack anyway
  }

  // ── Chain state ───────────────────────────────────────────────────────────

  /// Advances/breaks [actor]'s chain following this cast. [spell.isSummon]
  /// spells build the chain like any other spell (design doc R4), keyed on
  /// the creature's derived affinity ([CreatureSpec.fromElements] — always a
  /// single element, so a summon is always pure) rather than
  /// [certFormulas]/[parsedFormulas]; [certElementSequence] is the
  /// certified element sequence for a peer's summon (mirrors [_castSummon]'s
  /// own certified/wire split).
  void _updateChainState(
    WizardAvatar actor,
    SpellAsset spell, {
    List<ParsedFormula>? certFormulas,
    List<BorderZone>? certElementSequence,
  }) {
    final castAffinity = spell.isSummon
        ? CreatureSpec.fromElements(
            certElementSequence ?? elementSequence(spell),
          )?.affinity
        : pureAffinityOf(certFormulas ?? parsedFormulas(spell));

    if (castAffinity == null) {
      // Hybrid spell (2+ distinct formula affinities), or the degenerate
      // empty-sequence summon edge case: breaks the chain outright, same as
      // any off-alignment action (design doc R3 — purity is the whole
      // rule).
      actor.chainLengths.clear();
      actor.activeChainElement = null;
      return;
    }

    if (actor.activeChainElement == castAffinity) {
      // Continuing the chain — advance by one whole cast (2 half-credits),
      // scaled by chainFast/chainSlow (chainAccumulationMultiplier: 2.0/0.5).
      final multiplier = actor.chainAccumulationMultiplier;
      final credits = (2 * multiplier).round();
      actor.chainLengths[castAffinity] =
          (actor.chainLengths[castAffinity] ?? 0) + credits;
    } else {
      // Break the old chain; start a new one for this affinity.
      actor.chainLengths.clear();
      actor.activeChainElement = castAffinity;
      actor.chainLengths[castAffinity] = 2;
    }
  }

  /// Regresses [actor]'s active chain by 2 whole casts (4 half-credits),
  /// floored at 0 (design doc R7 — inaction is a gentler decay, never a
  /// penalty). Called for Pass/Dash/Meditate and any cast that resolves to
  /// nothing (fizzle, counter-charm).
  void _regressChain(WizardAvatar actor) {
    final el = actor.activeChainElement;
    if (el == null) return;
    final next = (actor.chainLengths[el] ?? 0) - 4;
    if (next <= 0) {
      actor.chainLengths.remove(el);
      actor.activeChainElement = null;
    } else {
      actor.chainLengths[el] = next;
    }
  }

  // ── Mana cost ─────────────────────────────────────────────────────────────
  //
  // Eighth across the seam, and operations again rather than a phase — pricing
  // a cast is not a phase, it is a calculation two different callers reach for
  // two different casts. Both reach it at the same MOMENT: TurnLoop settles
  // every committed cast at the start of Phase 5, in canonical playerId order
  // (M4.10b). What differs between the two mirrors below is whose spell they
  // price and how much of it they are allowed to trust, never when.
  //
  // The two mirrors below are deliberately NOT merged. They apply the same five
  // steps in the same order, but they start from different data on purpose:
  //
  //   [certifiedManaCost]   the price the PEER charges. Base, formulas and
  //                         element sequence all come from the verified public
  //                         outputs via `PeerCastVerifier` — the B-1/B-8
  //                         property.
  //   [spellCostBreakdown]  the price the CASTER charges itself, from its own
  //                         local `SpellAsset`. Trusting the wire here is
  //                         sound because it is the caster's own spell.
  //
  // Collapsing them into one function parameterised by "certified or not" would
  // read as tidier and would be the exact regression B-1 closed: one path is a
  // trust boundary and the other is not, and a shared body is one refactor away
  // from the untrusted caller reaching the trusted branch. They mirror each
  // other; they do not share.
  //
  // **What is uncertified here, deliberately (M4.19).** Both mirrors read
  // `isSummon` to choose the chain affinity, and it is an authored WIRE field
  // that no proof attests — see docs/M4_findings.md M4.19 and
  // test/battle/engine/summon_declaration_trust_test.dart. The extraction
  // preserved that read exactly and made it an explicit named parameter on
  // [certifiedManaCost] rather than hiding it; the fix is deferred to the
  // Phase-4 spell-identity migration. Do not "clean this up" by deriving it
  // from [certElementSequence] — that would be a silent rules change.
  //
  // TurnLoop keeps everything around these: which action is being priced,
  // whether the proofless dev-flag bypass applies, coalescing a null recall,
  // marking the action fizzled, and the UI's preview/affordability wrappers.
  // What crosses is the arithmetic and the caster mutations it implies.


  /// Apply the modifier chain to a peer cast's [certifiedBase] price.
  ///
  /// Every input is certified: [certifiedBase] and [certFormulas] come from
  /// [PeerCastVerifier], [certElementSequence] with them, and [isEfficiency] has
  /// already been checked against this spell's own certified supreme-dominance
  /// zones. Nothing on this path reads a wire field, which is the B-1/B-8
  /// property. (The one exception is [isSummon], read off `SpellAsset.isSummon`
  /// — see the note at the chain step.)
  ///
  /// **This is not verification and must not move behind the verifier**: it
  /// mutates [caster], consuming a chainSurcharge or a nextSpellCostDouble and
  /// converting a shortfall into HP damage. It is a deterministic game
  /// operation over certified inputs.
  ///
  /// Operation order mirrors [applySpellManaCost] exactly so both the local and
  /// verifier paths apply the same modifiers in the same sequence:
  ///   1. [certifiedBase] — 5×segmentCount + dotCount grown by
  ///      1.05^T × 1.5^effectCount, computed once at certification time by
  ///      [PeerCastVerifier.certifiedBaseManaCost].
  ///   2. Chain discount from [certFormulas] (trusted; replaces wire spell.formula).
  ///   3. Efficiency (Water) discount: −1/3, gated on [isEfficiency].
  ///   4. Recall multiplier from the transmitted [recall] (committed in the action
  ///      hash), scored against the EXPECTED recital both clients derive from the
  ///      certified trajectory. Exact integer arithmetic — see incantation_recall.dart.
  ///   5. nextSpellCostDouble: consume + double + HP shortfall. Both clients execute this
  ///      identically, keeping the status-effect list and state hash in sync.
  int certifiedManaCost(
    int certifiedBase,
    List<ParsedFormula> certFormulas,
    WizardAvatar caster, {
    IncantationRecall? recall,
    bool isEfficiency = false,
    bool isSummon = false,
    List<BorderZone>? certElementSequence,
    bool isVocalComponents = false,
  }) {
    // 1. Certified base + growth.
    var cost = certifiedBase;

    // 2. Chain: a pending chainSurcharge (potent Air-flavor Chain
    // Interaction) overrides the ordinary chain lookup entirely for this one
    // cast, regardless of affinity — consumed here so it doesn't also fire
    // in _updateChainState's normal advancement afterward.
    final surchargeIdx = caster.activeStatusEffects.indexWhere(
      (fx) => fx.effectTypeId == StatusEffectId.chainSurcharge,
    );
    if (surchargeIdx >= 0) {
      cost = (cost * pow(0.9, -1)).ceil();
      caster.activeStatusEffects.removeAt(surchargeIdx);
    } else {
      final pureAffinity = isSummon
          ? CreatureSpec.fromElements(
              certElementSequence ?? const [],
            )?.affinity
          : pureAffinityOf(certFormulas);
      cost = (cost * caster.chainCostMultiplier(pureAffinity)).ceil();
    }

    // 3. Efficiency (Water) loadout enhancement: −1/3 mana cost. [isEfficiency]
    // has already been verified against this spell's certified supreme-tags
    // by _verifyPeerSpellCast before reaching here — see
    // TrajectoryParser.certifiedSupremeTags. Mirrors applySpellManaCost's step,
    // same relative position (after chain discount, before sorcerer
    // multiplier).
    if (isEfficiency) {
      cost = (cost * 2 / 3).ceil();
    }

    // 4. Recall multiplier. The EXPECTED recital is derived HERE, from the
    // certified element sequence and the certified isSummon — never from
    // anything the caster transmitted. That is what makes a recall claim
    // checkable rather than self-reported, and it is the whole reason the
    // verbal component moved off pronunciation quality
    // (VOCAL_RECALL_PLAN.md §2).
    //
    // Exact integer arithmetic, rounded once — see incantation_recall.dart on
    // why no double may appear anywhere on this path.
    //
    // [recall] is never null here in sorcerer mode: the peer decodes it from
    // the wire (silent at worst), and the caster's own commit path coalesces
    // it — see TurnLoop._localCastSettlement. Null reaches this only from
    // TurnLoop.previewSpellCost, which must quote the honest base price because no
    // incantation has been spoken yet.
    if (isVocalComponents && recall != null) {
      cost = recall
          .tallyAgainst(
            expectedIsSummon: isSummon,
            expectedElements:
                expectedRecitalSlots(certElementSequence ?? const []),
          )
          .applyTo(cost);
    }

    // 5. nextSpellCostDouble: consume and double cost, convert excess to HP damage.
    // Both caster and verifier execute this path identically, keeping the status-effect
    // list and state hash in sync. Pre-existing desync when active (see M4_findings.md
    // "nextSpellCostDouble pre-existing desync"); this is the fix.
    final doubleIdx = caster.activeStatusEffects.indexWhere(
      (fx) => fx.effectTypeId == StatusEffectId.nextSpellCostDouble,
    );
    if (doubleIdx >= 0) {
      final fx = caster.activeStatusEffects[doubleIdx];
      final multiplier = fx.modifiers['costMultiplier'] ?? 2;
      cost = (cost * multiplier).ceil();
      final hpPerMana = fx.modifiers['hpPerManaMissed'] ?? 1;
      final manaPerHp = fx.modifiers['manaPerHp'] ?? 10;
      final shortfall = (cost - caster.mana).clamp(0, _kMaxMana);
      if (shortfall > 0) {
        final hpDamage = ((shortfall / manaPerHp) * hpPerMana).ceil();
        caster.absorbDamage(hpDamage);
        cost = caster.mana;
      }
      caster.activeStatusEffects.removeAt(doubleIdx);
    }

    return cost.clamp(0, _kMaxMana);
  }

  /// Step 1 of [applySpellManaCost] for a cast with NO proof to price from —
  /// the `kAllowProoflessSpells` dev-flag case, and nothing else.
  ///
  /// **Not the ordinary path any more (M4.22).** A proof-backed cast is priced
  /// from `CertifiedCast.baseManaCost`, derived from the same proof bytes the
  /// peer verifies, because this function's inputs (`spell.segmentCount`,
  /// `spell.dotCount`, `spell.t`, and the authored formula behind
  /// [parsedFormulas]) are all WIRE fields that nothing binds to the proof.
  /// When they drift, this and [PeerCastVerifier.certifiedBaseManaCost] return
  /// different numbers for one cast — 83 against 25 on the shipped Basic
  /// Windhound — and `WizardAvatar.mana` diverges at byte 56 of
  /// `toCanonicalBytes`. See docs/M4_findings.md §M4.22.
  ///
  /// Kept, rather than deleted, because a proofless spell has nothing to derive
  /// from and both devices fall back here identically. It is still written to
  /// be the exact local mirror of [PeerCastVerifier.certifiedBaseManaCost]:
  /// same inputs, same operations, same order.
  ///
  /// Deliberately recomputed rather than read off [SpellAsset.manaCost].
  /// That field is baked at inscribe time from the *activation* count —
  /// `max(0, (activations - 1) ~/ 3)` — while the certified path derives
  /// effectCount from the count of *complete formulas*, `max(0, formulas - 1)`.
  /// Those agree only when the activation count is an exact multiple of 3, so
  /// any spell with a residual activation charged its own caster ~1.5x what
  /// the opponent's device charged it, `avatar.mana` diverged, and
  /// [_exchangeStateHash] forfeited the match ("state hash mismatch on turn
  /// N"). The certified count is the one that must win — it's the trust
  /// boundary, and the wire count was exploitable by padding the formula
  /// list — so the local path adopts it here.
  ///
  /// [_parsedFormulas] and TrajectoryParser both group the same flat
  /// activation sequence into triplets and drop the residual, so
  /// `parsedFormulas(spell).length == certFormulas.length` for an honest
  /// spell; a dishonest one still loses, because the opponent charges the
  /// certified amount regardless and the state hash catches the difference.
  int wireBaseManaCost(SpellAsset spell) {
    final base = 5 * spell.segmentCount + spell.dotCount;
    final effectCount = max(0, parsedFormulas(spell).length - 1);
    return (base * pow(1.05, spell.t) * pow(1.5, effectCount)).round();
  }

  /// Charge [caster] for casting [spell]: the cost, *and* the state changes
  /// that pricing it implies (a consumed chainSurcharge, a consumed
  /// nextSpellCostDouble, the HP damage its shortfall converts to).
  ///
  /// The arithmetic lives in [spellCostBreakdown] so `TurnLoop.previewSpellCost` can
  /// ask "what would this cost?" without charging for it. Do not reintroduce a
  /// second copy of the formula here — the UI gate and the deduction must
  /// agree to the mana, or the player is offered casts that then fizzle for
  /// want of it (see [fizzlesForMana]).
  int applySpellManaCost(
    SpellAsset spell,
    WizardAvatar caster, {
    CertifiedCast? certified,
    CastingEnhancements? enhancements,
    IncantationRecall? recall,
    bool isVocalComponents = false,
  }) {
    final b = spellCostBreakdown(spell, caster,
        certified: certified,
        enhancements: enhancements,
        recall: recall,
        isVocalComponents: isVocalComponents);

    if (b.hpDamage > 0) caster.absorbDamage(b.hpDamage);

    // Both indices address the UNMUTATED list, so remove the higher first —
    // that is exactly equivalent to the original inline order (remove the
    // surcharge, then remove the double at its post-shift index), because
    // dropping a chainSurcharge never changes *which* nextSpellCostDouble is
    // first, only where it sits.
    final consumed = [b.surchargeIdx, b.doubleIdx].where((i) => i >= 0).toList()
      ..sort();
    for (final i in consumed.reversed) {
      caster.activeStatusEffects.removeAt(i);
    }

    return b.cost;
  }

  /// Price a cast of [spell] by [caster] without mutating either.
  ///
  /// Operation order is the same as [certifiedManaCost]'s — see its doc
  /// comment for the numbered steps and why the two must not drift. What this
  /// returns beyond the cost is everything the charging path has to *apply*:
  /// [hpDamage] to absorb, and the indices into [caster]'s current
  /// `activeStatusEffects` of the chainSurcharge / nextSpellCostDouble entries
  /// this cast consumes (-1 when absent).
  ({int cost, int hpDamage, int surchargeIdx, int doubleIdx})
  spellCostBreakdown(
    SpellAsset spell,
    WizardAvatar caster, {
    CertifiedCast? certified,
    CastingEnhancements? enhancements,
    IncantationRecall? recall,
    bool isVocalComponents = false,
  }) {
    // The proof-attested semantics of the caster's OWN cast (M4.22), when this
    // device holds proof bytes to reconstruct them from. Every read below
    // prefers them over the authored `SpellAsset` fields, because those are
    // what the OPPONENT will price this cast from — see [certifiedManaCost],
    // which is this method's mirror on the far side of the trust boundary and
    // reads exactly the same three things.
    //
    // Null means there is genuinely nothing to derive from — a
    // `kAllowProoflessSpells` Test Lab spell — and only then does the authored
    // fallback apply. Both devices see the same absence, so the fallback is
    // desync-safe even though it is not trust-safe; see [wireBaseManaCost].
    final certFormulas = certified?.formulas;
    final certElements = certified?.elementSequence;

    // 1. Base + growth — mirrors certifiedManaCost step 1.
    var cost = certified?.baseManaCost ?? wireBaseManaCost(spell);

    // Chain: a pending chainSurcharge (potent Air-flavor Chain Interaction)
    // overrides the ordinary chain lookup for this one cast, regardless of
    // affinity — mirrors certifiedManaCost's step 2, same relative
    // position. Reported back for [applySpellManaCost] to consume, so it doesn't
    // also fire in _updateChainState's normal advancement afterward.
    final surchargeIdx = caster.activeStatusEffects.indexWhere(
      (fx) => fx.effectTypeId == StatusEffectId.chainSurcharge,
    );
    if (surchargeIdx >= 0) {
      cost = (cost * pow(0.9, -1)).ceil();
    } else {
      // isSummon is read off the wire asset, deliberately and unchanged — that
      // is M4.19, a separate defect with its own fix. What M4.22 changes is the
      // SEQUENCE the creature's affinity is read from, which the proof does
      // attest. Mirrors certifiedManaCost's step 2 exactly.
      final pureAffinity = spell.isSummon
          ? CreatureSpec.fromElements(certElements ?? elementSequence(spell))
              ?.affinity
          : pureAffinityOf(certFormulas ?? parsedFormulas(spell));
      cost = (cost * caster.chainCostMultiplier(pureAffinity)).ceil();
    }

    // Efficiency (Water) loadout enhancement: −1/3 mana cost. Applied after
    // chain discount, before the sorcerer multiplier — see certifiedManaCost
    // for the mirrored step at the same relative position.
    if (enhancements?.isEfficiency ?? false) {
      cost = (cost * 2 / 3).ceil();
    }

    // Recall multiplier — the local mirror of certifiedManaCost step 4, at
    // the same relative position (after the chain and Efficiency discounts, so
    // a shaky recital inflates the already-discounted cost).
    //
    // The EXPECTED recital is derived from the same certified element sequence
    // the peer scores against (M4.22). It used to read the authored
    // `SpellAsset.formula` here while `certifiedManaCost` read the certified
    // one — so on an asset whose authored fields had drifted, the two devices
    // scored the same spoken incantation against two different expected
    // recitals and charged different multipliers for it.
    //
    // Null means "not spoken yet" here, and prices at base — that is
    // TurnLoop.previewSpellCost's path. The charging path never passes null; see
    // TurnLoop._localCastSettlement.
    if (isVocalComponents && recall != null) {
      cost = recall
          .tallyAgainst(
            expectedIsSummon: spell.isSummon,
            expectedElements: expectedRecitalSlots(
              certElements ?? elementSequence(spell),
            ),
          )
          .applyTo(cost);
    }

    // nextSpellCostDouble status effect: double the cost (and report the
    // effect back for [applySpellManaCost] to consume).
    var hpDamage = 0;
    final doubleIdx = caster.activeStatusEffects.indexWhere(
      (fx) => fx.effectTypeId == StatusEffectId.nextSpellCostDouble,
    );
    if (doubleIdx >= 0) {
      final fx = caster.activeStatusEffects[doubleIdx];
      final multiplier = fx.modifiers['costMultiplier'] ?? 2;
      cost = (cost * multiplier).ceil();
      final hpPerMana = fx.modifiers['hpPerManaMissed'] ?? 1;
      final manaPerHp = fx.modifiers['manaPerHp'] ?? 10;
      // HP shortfall conversion: if caster can't afford it, excess cost → HP damage.
      // This is the one route by which an "unaffordable" cast is still legal —
      // the caster pays what they have and bleeds for the rest — so the cost
      // returned here is never above `caster.mana`, and `TurnLoop.canAffordSpell`
      // correctly lets it through without needing a special case.
      final shortfall = (cost - caster.mana).clamp(0, 9999);
      if (shortfall > 0) {
        hpDamage = ((shortfall / manaPerHp) * hpPerMana).ceil();
        cost = caster.mana; // pay what they have
      }
    }

    return (
      cost: cost.clamp(0, _kMaxMana),
      hpDamage: hpDamage,
      surchargeIdx: surchargeIdx,
      doubleIdx: doubleIdx,
    );
  }

  /// The element slots a caster is expected to recite for [elementSequence].
  ///
  /// Truncated to COMPLETE TRIPLETS, matching PracticeFormula.fromSpellFormula:
  /// a spell's activation list carries 1–2 residuals that never filled a group
  /// of three, and those resolve to no effect (FormulaTracker.formulas drops
  /// them). Asking a caster to recite words their cast never uses would price
  /// mana against a recital the drill never taught.
  static List<VocalSlot> expectedRecitalSlots(
      List<BorderZone> elementSequence) {
    final complete = (elementSequence.length ~/ 3) * 3;
    return [
      for (var i = 0; i < complete; i++)
        if (VocalSlot.fromAffinityZone(elementSequence[i].name)
            case final slot?)
          slot,
    ];
  }

  /// Whether a cast priced at [cost] fizzles for want of mana.
  ///
  /// The deterministic half of the rule; TurnLoop owns what a fizzle then
  /// *means* to the protocol (marking the action so resolution skips its
  /// effects). Applies in BOTH modes, and on BOTH sides of the trust boundary
  /// — the caster evaluates it against its own breakdown, the peer against
  /// [certifiedManaCost] — which is what lets the two agree without
  /// transmitting anything.
  ///
  /// Sorcerer mode needs it because recall can INFLATE a cost after the player
  /// has already committed (VOCAL_RECALL_PLAN.md §4), but the response is right
  /// for wizard mode too, and it replaces what used to be a match forfeit
  /// there.
  ///
  /// Forfeiting was never really punishing a cheat — an unaffordable cast wins
  /// its caster nothing — it was avoiding a DESYNC. The caster's own deduction
  /// clamped at zero and played on while the peer stopped the match, and those
  /// two devices disagreeing is the actual failure. Fizzling fixes that at the
  /// source: both devices price the cast from the same certified inputs, so
  /// both reach the same verdict and stay in step.
  ///
  /// The UI still gates affordability (TurnLoop.canAffordSpell); this is the
  /// backstop behind it, not a replacement for it.
  ///
  /// Known narrow edge, accepted in §4: refund-on-shortfall is a take-back.
  /// Deliberately blanking a cast you regret returns the mana at the cost of
  /// the turn. Only reachable when a spell already costs most of the pool.
  bool fizzlesForMana(WizardAvatar caster, int cost) => cost > caster.mana;


  // ── Counter charms ────────────────────────────────────────────────────────

  /// The un-revealed counter charm that intercepts a cast whose certified
  /// element sequence is [sequence], and how many whole formulas it cancels.
  ///
  /// Charms are attuned to a TRAJECTORY, not to one spell's grid
  /// (docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 2): a charm fires against any
  /// cast opening with its element sequence, and cancels formulas for as long
  /// as the two sequences stay in lockstep ([counterCharmFormulaMatch]).
  /// Charms trigger on such a cast by ANY wizard, including the charm's own
  /// owner (design: counter-charm plan, "Trigger source" — deliberately not
  /// opponent-only).
  ///
  /// Selection is a pure function of state, so both devices pick the same
  /// charm: the LONGEST match wins — a player who paid for a longer charm
  /// should get the deeper counter — and ties break by the pre-existing fixed
  /// scan order, avatars by playerId then that avatar's accoutrements by id.
  /// At most one charm fires per cast; charms do not stack.
  ///
  /// Two gates on the charm's OWNER:
  ///
  ///   * A wizard who spent an artifact at Phase 0 has their charms down for
  ///     the turn (ARTIFACT_SYSTEM_PLAN.md §2.2) and is skipped entirely. The
  ///     tension is internal to the charm holder — *"do I want that 100 mana
  ///     badly enough to open a window this turn?"* — which is why the gate is
  ///     on the charm owner's own declaration and not the caster's. Because
  ///     this method deliberately searches every avatar including the caster,
  ///     that one guard correctly covers a wizard whose own activation opened
  ///     a window onto their own cast, with no second check needed.
  ///   * They must be able to pay [counterCharmManaCost] in full (§2.4). A
  ///     charm whose owner cannot afford it does not fire and is not consumed
  ///     — it stays charged for a turn they can pay. Skipping rather than
  ///     part-paying is what keeps "full cost on every trigger" a real cost
  ///     rather than a soft one, and it lets a shorter, cheaper charm on the
  ///     same wizard fire in its place.
  ({WizardAvatar owner, Accoutrement charm, int formulas})? _findCounteringCharm(
    List<BorderZone> sequence,
  ) {
    if (sequence.length < kElementsPerFormula) return null;
    final sortedAvatars = List<WizardAvatar>.from(state.avatars)
      ..sort((a, b) => a.playerId.compareTo(b.playerId));
    ({WizardAvatar owner, Accoutrement charm, int formulas})? best;
    for (final av in sortedAvatars) {
      if (av.declaredActivation != null) continue;
      final sortedAcc = List<Accoutrement>.from(av.accoutrements)
        ..sort((a, b) => a.id.compareTo(b.id));
      for (final acc in sortedAcc) {
        if (acc.kind != AccoutrementKind.counterCharm) continue;
        if (acc.counterCharmRevealed) continue;
        final trajectory = acc.charmTrajectory;
        if (trajectory == null) continue; // unattuned charm: never fires
        final formulas = counterCharmFormulaMatch(trajectory, sequence);
        if (formulas == 0) continue;
        if (av.mana < counterCharmManaCost(trajectory)) continue;
        // Strictly-greater keeps the scan order as the tiebreak.
        if (best == null || formulas > best.formulas) {
          best = (owner: av, charm: acc, formulas: formulas);
        }
      }
    }
    return best;
  }

  /// Consumes [hit]'s charm: marks it revealed (it never triggers again) and
  /// charges its owner the full [counterCharmManaCost], whatever fraction of
  /// the cast actually got cancelled (§2.4).
  ///
  /// Does not apply or suppress the spell and records no event — the caller
  /// (the sole call site, in [resolveActions]) decides between the
  /// full-counter path (skip [applySpell] entirely) and the partial-counter
  /// path (resolve with a suppressed prefix).
  void _triggerCounterCharm(
    ({WizardAvatar owner, Accoutrement charm, int formulas}) hit,
  ) {
    final owner = hit.owner;
    final idx = owner.accoutrements.indexWhere((a) => a.id == hit.charm.id);
    if (idx >= 0) {
      owner.accoutrements[idx] =
          owner.accoutrements[idx].copyWith(counterCharmRevealed: true);
    }
    final cost = counterCharmManaCost(hit.charm.charmTrajectory ?? const []);
    owner.mana = (owner.mana - cost).clamp(0, owner.maxMana);
  }

  // ── Cloud targeting restriction ───────────────────────────────────────────

  /// True if [caster] casting at [targetHex] is subject to a cloud's
  /// adjacent-only targeting restriction: either [caster] is standing inside
  /// any cloud's radius (or still carries the lingering Earth-flavor
  /// [StatusEffectId.cloudBoundTargeting] status), or [targetHex] itself
  /// falls inside any cloud's radius. Trusted-engine twin of
  /// battle_screen.dart's `_maxCastRange`, which only gates what the local
  /// UI lets a human player tap — this is what actually gets enforced during
  /// resolution, for every caster (peer casts, and the Solo Practice dummy,
  /// which encodes its scripted cast straight onto the wire and never goes
  /// through that UI).
  bool _cloudBoundToAdjacent(WizardAvatar caster, HexCoord targetHex) {
    // Earthen Scrying Pool (Divination, Earth): the bearer sees through the
    // murk, so no cloud blinds them — neither one they stand in, nor one
    // around the tile they're aiming at, nor a lingering dust restriction.
    // Gating here (rather than only stripping the status on cast) is what
    // makes the immunity hold when the cloud arrives AFTER the scrying.
    if (caster.activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.scryingSight,
    )) {
      return false;
    }
    final casterBound =
        caster.activeStatusEffects.any(
          (fx) => fx.effectTypeId == StatusEffectId.cloudBoundTargeting,
        ) ||
        state.clouds.any(
          (c) => hexDistance(caster.position, c.position) <= c.radius,
        );
    final hexBound = state.clouds.any(
      (c) => hexDistance(targetHex, c.position) <= c.radius,
    );
    return casterBound || hexBound;
  }

  // ── Formula helpers ───────────────────────────────────────────────────────
  //
  // Public because TurnLoop's mana costing still reads them — one derivation of
  // "what formulas does this spell have" for both the price and the effect, so
  // the two cannot drift (B-1/B-8). [_zoneFromName] is the exception: the two
  // helpers below are its only callers anywhere, so it is private.

  static List<ParsedFormula> parsedFormulas(SpellAsset spell) {
    final zones = spell.formula
        .map(_zoneFromName)
        .whereType<BorderZone>()
        .toList();
    final formulas = <ParsedFormula>[];
    for (var i = 0; i + 2 < zones.length; i += 3) {
      formulas.add(
        ParsedFormula(
          affinity: zones[i],
          effectType1: zones[i + 1],
          effectType2: zones[i + 2],
        ),
      );
    }
    return formulas;
  }

  /// The single affinity shared by every formula in [formulas], for chain
  /// discount/advancement purposes -- null if [formulas] is empty or spans
  /// more than one distinct first-element (a hybrid spell, discount-
  /// ineligible per design doc's Chain Discount System). Used identically
  /// by [_updateChainState] and TurnLoop's `_spellManaCost`/`_certifiedManaCost`
  /// so "pure" can't drift between the advancement and discount paths.
  static SpellAffinity? pureAffinityOf(List<ParsedFormula> formulas) {
    if (formulas.isEmpty) return null;
    final first = spellAffinityFromZone(formulas.first.affinity);
    for (final f in formulas.skip(1)) {
      if (spellAffinityFromZone(f.affinity) != first) return null;
    }
    return first;
  }

  static BorderZone? _zoneFromName(String name) => switch (name.toLowerCase()) {
    'fire' => BorderZone.fire,
    'earth' => BorderZone.earth,
    'water' => BorderZone.water,
    'air' => BorderZone.air,
    _ => null,
  };

  /// The full flat element sequence for a local (trusted-wire) summon-mode
  /// spell -- unlike [parsedFormulas], residuals are kept (see
  /// CreatureSpec.fromElements: every activation counts toward a creature).
  static List<BorderZone> elementSequence(SpellAsset spell) =>
      spell.formula.map(_zoneFromName).whereType<BorderZone>().toList();

  // ── Accoutrement bookkeeping ──────────────────────────────────────────────
  //
  // Private now that Phase-0 artifact activation has crossed the seam: the
  // melee counter-charm proc, the rod's cast-time consumption and the gem burn
  // are all in this file, so "remove one of this kind, deterministically" has
  // one copy and no external entry point that could grow a second.

  /// Removes one accoutrement of [kind] from [av], scanning the owner's
  /// accoutrements sorted by id and taking the first match — the same
  /// deterministic tie-break [_findCounteringCharm] uses, and the reason a wire
  /// declaration can name a kind instead of an id. Returns false if [av] holds
  /// none.
  bool _consumeAccoutrement(WizardAvatar av, AccoutrementKind kind) {
    final match = (List<Accoutrement>.from(av.accoutrements)
          ..sort((a, b) => a.id.compareTo(b.id)))
        .where((a) => a.kind == kind)
        .firstOrNull;
    if (match == null) return false;
    av.accoutrements.removeWhere((a) => a.id == match.id);
    return true;
  }

  /// Recomputes [av]'s stored [WizardAvatar.maxMana] from its current gem count
  /// and clamps current mana into the new pool. The engine-side twin of
  /// EffectApplicator._syncMaxMana — [WizardAvatar.maxMana] is hashed state,
  /// not a live derivation, so any gem gained or lost must resync it or the two
  /// devices' state hashes drift.
  void _syncMaxMana(WizardAvatar av) {
    av.maxMana = av.maxManaFor(state.config);
    if (av.mana > av.maxMana) av.mana = av.maxMana;
  }
}
