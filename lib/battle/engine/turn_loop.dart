// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop.dart — TurnLoop: drives one full turn through all phases.
//
// UI-facing phase labels vs. engine phase order: the player experiences
// Summons → Main → Move → Resolution (see battle_screen.dart's phase
// banner), but the *decisions* are locked in as Main → Move → (an implicit
// Melee prompt folded into submission) before any of it is revealed. The
// engine phase order below is what actually executes on the wire:
//
// Phase order (B-5: entropy reveal moved after all player decisions):
//   0. Artifact activation commit-reveal — each player declares which
//      loadout artifact (if any) they are spending this turn, BEFORE the
//      Phase 1 action commit (docs/ARTIFACT_SYSTEM_PLAN.md §4). That
//      ordering is the whole mechanic: spending an artifact drops your own
//      counter charms for the turn, and the opponent must learn it while
//      they can still change their cast. Commit-reveal rather than a plain
//      exchange so neither side can stall and read the other's declaration
//      first. Runs inside beginTurn() (see [beginArtifactPhase]), so the UI
//      can settle it and show the result before the player even picks an
//      action.
//   1. Action commit — each player commits their main-phase action
//      (spell / dash / meditate / pass) before entropy is known. Mana is
//      deducted at commit time (Cast cost, or Meditate's +25 gain).
//   2. Movement commit-reveal — simultaneous declaration and resolution.
//      The declared path bytes also carry the caster's own Dash/Meditate
//      flags (see below) so both clients can size movement budgets
//      identically without waiting for the later action reveal.
//   3. Entropy reveal — joint commit-reveal entropy derived once all
//      decisions are locked in. Seeds all resolution RNG in phases 4–6.
//   4. Cloud movement — Air-flavor Clouds auto-seek 1 tile toward the
//      nearest enemy (TurnLoop._moveClouds). Deliberately kept here, ahead
//      of Action resolution, so a cloud's position for the rest of the turn
//      (including the adjacent-only targeting restriction checked during
//      Phase 5) reflects this turn's move, not last turn's. A cloud a spell
//      *creates* during Phase 5 (below) has already missed this sweep, so
//      TurnLoop._resolveActions gives it one immediate _moveCloud step right
//      after it's summoned — same idea as a Potent summon's immediate
//      action, so a fresh cloud is never dead-still on the turn it's cast.
//   4b. Melee commit-reveal — after movement has resolved, each player with
//      an adjacent hostile target may commit an optional melee choice;
//      resolved at the start of phase 5, independent of the main action (a
//      player may cast AND melee the same turn). Candidates reflect
//      post-movement, post-cloud-move positions — NOT post-Summons (5b runs
//      later in the turn now; see below), so a minion that hasn't taken its
//      turn yet this round won't appear in the melee prompt.
//   5. Action resolution — reveal main-phase actions, sort spells
//      (quick→haymaker-tier→normal→sluggish, then by step count T ascending,
//      then commitmentHex, then playerId), apply each in order. Quick and
//      Sluggish rank a cast only against the *other casts* that turn: if
//      every cast this turn is quick (or every one sluggish — including the
//      degenerate "only one cast, and it's mine" case) the modifier cancels
//      and they all resolve as normal. A Potent summon-mode cast
//      spawns its creature and lets it act immediately as part of this same
//      step (TurnLoop._castSummon) — a one-time bonus, on top of (not
//      instead of) the normal action it gets in 5b below.
//   5b. Summons act — deterministic AI for all living minions (creation
//      order), run once, here, after every spell for the turn has resolved
//      (not before, as this used to run — moving it here means it can't
//      influence either player's Phase 1 action commit, so there's no
//      look-ahead concern; see B-5 below). This includes creatures summoned
//      by a spell that just resolved this same turn — a fresh summon's
//      first action is always this step, the same turn it's cast, whether
//      or not it was Potent. A creature that also got the Phase 5 immediate
//      bonus (Potent summon only) acts a *second* time here, giving it two
//      actions in a row on the turn it's cast; a non-Potent summon just gets
//      its one, same as it always has. ("obedient" summons are a stubbed
//      seam — see SummonPersonality.obedient in minion.dart — no live
//      manual control yet; that still needs Summons ahead of the B-5
//      entropy reveal, which 5b deliberately does not attempt.)
//   5c. Post-resolution free-move (barrier burst) — see the dedicated
//      comment at its call site.
//   6. End-of-turn — tile effects, clouds, barrier auras, mana regen, status
//      tick, state-hash exchange.
//
// TurnLoop is stateless across turns; per-turn scratch lives in locals.
// All network I/O goes through BattleSession; all game state lives in BattleState.
// Neither is owned here.
//
// For the caller to provide the local player's decision, pass a [TurnInput].
// Multi-player (3–6) would require a list of sessions; stub is 2-player only.
//
// Action wire encoding (commit-reveal payload):
//   Pass:     [0x00]
//   Spell:    [0x01][commit_hex:32][t:2][q:2][r:2][formula_len:2][formula_utf8:N]
//             formula_utf8 = comma-separated zone names ("fire,earth,water")
//             [isPotent:1][isVelocity:1][isEfficiency:1]
//             [optional proof tail when book proofs are enabled]
//             [sorcerer mode only: pronunciation_u8:1, volume_u8:1, somatic_u8:1]
//   Dash:     [0x04]  — doubles this turn's movement budget (see move-path
//             wire encoding below for how the flag actually reaches the peer
//             in time to affect movement resolution).
//   Meditate: [0x05]  — restores +25 mana (main phase). May stack with a
//             move-phase Meditate (see below) for +50 total.
//
// Commit:  SHA-256(action_bytes ‖ nonce)  32 bytes
// Reveal:  nonce(16) ‖ action_bytes       variable
//
// Move-path wire encoding: [isDashing:1][meditateInMove:1][count:1][q:2][r:2]…
// isDashing/meditateInMove are folded into the *movement* commit-reveal
// (not the action commit-reveal) specifically so both clients know each
// other's dash status before avatar movement resolves — the action
// reveal itself is deliberately deferred until after movement resolves (so
// a spell's target can't inform the opponent's move), which would otherwise
// make Dash's same-turn speed boost impossible to apply deterministically.
// meditateInMove forces the declared path to be treated as empty (stay put)
// regardless of what was sent, and grants +25 mana at reveal time.
//
// Melee wire encoding (separate commit-reveal, after movement resolves):
//   No melee: [0x00]   Melee: [0x01][q:2][r:2]
// Commit/reveal shape identical to movement's.
//
// Artifact-activation wire encoding (Phase 0 commit-reveal, before the action
// commit):
//   No activation: [0x00]   Activation: [0x01][kind:1]
// [kind] is the AccoutrementKind index. The declaration names a KIND, never a
// specific accoutrement id — the engine picks which instance is consumed by
// sorting the owner's accoutrements by id and taking the first match, the
// same fixed-order convention _findCounteringCharm uses. That removes a whole
// class of trust bug: a peer cannot name an id it does not own, because it
// never gets to name an id. Commit/reveal shape identical to movement's.

import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:math' show max, min, pow;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/basic_spells.dart' show isBasicGridAndT;
import 'package:rune_duel/spells/counter_charm.dart';
import 'package:rune_duel/spells/inscribe.dart'
    show kMaxInscribableSteps, tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/spells/spell_identity.dart' show isCantripElementCount;
import 'package:rune_duel/spells/spell_permission.dart';

import '../models/battle_state.dart';
import '../models/casting_enhancements.dart';
import '../models/certified_cast.dart';
import '../models/component_order.dart';
import '../models/creature_spec.dart' show CreatureSpec;
import '../models/pending_delayed_spell.dart';
import '../models/reflection_link.dart';
import '../models/divination_link.dart';
import '../models/effect_descriptor.dart'; // exports SpellAffinity, spellAffinityFromZone
import '../models/hex_battlefield.dart' show hexDistance, hexNeighbors;
import '../models/minion.dart';
import '../models/status_effect_ids.dart';
import '../models/terrain.dart'
    show ImpassableTile, CloudObject, tileBlocksMovement;
import '../models/wild_magic_effect.dart';
import '../models/wizard_avatar.dart';
import '../networking/battle_session.dart';
import '../../identity/identity.dart';
import '../../protocol/match_session.dart' show ProofVerifier;
import 'battle_events.dart';
import 'book_commitment.dart';
import 'commit_reveal.dart';
import 'deterministic_resolution.dart';
import 'draw_schedule.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'effect_resolver.dart';
import 'line_of_sight.dart';
import 'proof_intake.dart';
import 'spell_draw.dart';
import 'tile_entry_resolver.dart';
import 'trajectory_parser.dart';
import 'wild_magic.dart';
import 'wild_magic_applicator.dart';
import 'forced_cast.dart';
import '../../sorcerer/incantation_recall.dart';
import '../../sorcerer/vocal_slot.dart';

// AvatarMoveEvent, MinionMoveEvent and AttackEvent moved to battle_events.dart
// so the deterministic seam can emit them without importing this file.
// Re-exported so every existing `import '.../turn_loop.dart'` naming them
// keeps compiling.
export 'battle_events.dart';

// ── Turn input / action types ─────────────────────────────────────────────────

/// Private data for one pending delayed spell the local player is firing
/// this turn. Stored by the UI layer; never transmitted in plaintext.
class DelayedSpellReveal {
  const DelayedSpellReveal({
    required this.pendingSpellId,
    required this.targetTile,
    required this.delay,
    required this.nonce,
  });

  /// Matches [PendingDelayedSpell.id] in state.
  final String pendingSpellId;
  final HexCoord targetTile;

  /// 0–3. Must equal currentTurn - castTurn for the spell to fire.
  final int delay;

  /// 16 bytes. Must satisfy SHA-256(encodeCoord(targetTile) ‖ delay ‖ nonce)
  /// == [PendingDelayedSpell.commitment].
  final Uint8List nonce;
}

/// The local player's declared actions for this turn.
class TurnInput {
  const TurnInput({
    required this.action,
    this.movePath = const [],
    this.meditateInMove = false,
    this.delayedSpellReveals = const [],
  });

  /// What the player wants to do in the main phase: cast a spell, dash,
  /// meditate, or pass.
  final TurnAction action;

  /// Ordered list of tiles to enter this turn (not including current position).
  /// Empty means stay put. Each tile must be adjacent to the previous.
  /// Ignored (forced empty) when [meditateInMove] is true.
  final List<HexCoord> movePath;

  /// Move-phase Meditate: forgo movement this turn for +25 mana. Independent
  /// of (and stacks with) a main-phase [MeditateAction] — see turn_loop.dart's
  /// header comment on the move-path wire encoding.
  final bool meditateInMove;

  /// Private reveals for any pending delayed spells firing this turn.
  final List<DelayedSpellReveal> delayedSpellReveals;
}

/// One player's declared action for this turn.
sealed class TurnAction {}

class SpellCastAction extends TurnAction {
  SpellCastAction({
    required this.spell,
    required this.targetHex,
    this.isPotent = false,
    this.isVelocity = false,
    this.isEfficiency = false,
    this.recall,
    this.conveyorDirection,
    this.delayedOriginHex,
    this.delayedRange,
    this.handIndex,
  });

  final SpellAsset spell;
  final HexCoord targetHex;
  final bool isPotent;
  final bool isVelocity;
  final bool isEfficiency;

  /// The caster's own hand slot this cast came from, when known — the only
  /// duplicate-safe key for building this cast's chapter-membership Merkle
  /// proof (docs/BASIC_SPELLS_PLAN.md §7): a chapter may hold several copies
  /// of the same Basic spell, so `spell.commitmentHex` alone cannot tell
  /// [TurnLoop] WHICH copy's slot to prove. Null falls back to a
  /// commitment-based lookup (BookCommitment.proveMembership), which is only
  /// correct for a chapter with no duplicate of this spell — true for every
  /// non-Basic spell today, and for solo/test construction sites that never
  /// set this.
  final int? handIndex;

  /// What the caster's device heard them recite. Null in Wizard mode.
  ///
  /// Slot indices only, never words (VOCAL_RECALL_PLAN.md §8.10.1). Set by the
  /// caster's device and committed inside the action hash; populated on the
  /// receiving side by decoding the transmitted bytes. The peer scores it by
  /// recomputing the EXPECTED sequence from the certified trajectory, which is
  /// what makes recall verifiable where pronunciation quality never was.
  final IncantationRecall? recall;

  /// Set at commit time when the recall-inflated cost exceeded the caster's
  /// mana: the cast fizzles and the mana is refunded, but the turn is spent
  /// (§4). NOT transmitted — each device computes it from the same certified
  /// cost and the same avatar mana, so both arrive at the same answer.
  bool fizzledForMana = false;

  /// The caster's chosen push direction, if this cast will create a
  /// ConveyorTile (Air-flavor tileModification) and the caster picked one
  /// via the battle_screen.dart direction prompt. Null falls back to a
  /// random direction (EffectApplicator._randomDirection) -- always the case
  /// for Mystery/delayed-fire casts this pass (see turn_loop.dart handoff
  /// notes), and the seam for a future real-time choose-or-timeout mode.
  final HexCoord? conveyorDirection;

  /// Set only when this action is a delayed Mystery reveal firing this turn:
  /// the caster's board position at the original cast turn, used as the
  /// cast-animation launch origin instead of the caster's current position
  /// (which may have moved many turns since). Null for a same-turn cast.
  final HexCoord? delayedOriginHex;

  /// Companion to [delayedOriginHex]: the caster's spell range on the turn
  /// this Mystery cast was declared, carried through from
  /// [PendingDelayedSpell.declaredRange]. The range check reads this instead
  /// of the caster's range now, so a rangeDown landed while the spell was
  /// pending cannot retroactively invalidate it. Null for a same-turn cast,
  /// which uses the turn's pre-movement snapshot instead.
  ///
  /// Local-only, like [delayedOriginHex]: both peers rebuild this action from
  /// their own copy of `state.pendingDelayedSpells`, so it never crosses the
  /// wire.
  final int? delayedRange;
}

/// Main-phase Dash: doubles the caster's movement budget for this turn's
/// move phase. See turn_loop.dart's header comment for why the flag travels
/// inside the movement commit-reveal rather than the action reveal.
class DashAction extends TurnAction {}

/// Main-phase Meditate: forgo casting for +25 mana. Independent of (and
/// stacks with) a move-phase Meditate — see [TurnInput.meditateInMove].
class MeditateAction extends TurnAction {}

class PassAction extends TurnAction {}

/// One elemental spell cast resolved this turn — UI-only bookkeeping for the
/// cast animation (orb glows at the caster, flies to the target, bursts).
/// Carries no gameplay effect; [TurnLoop] never reads these back.
class SpellCastEvent {
  const SpellCastEvent({
    required this.casterId,
    required this.fromHex,
    required this.toHex,
    required this.affinity,
  });

  final String casterId;
  final HexCoord fromHex;
  final HexCoord toHex;
  final SpellAffinity affinity;
}

// AvatarMoveEvent, MinionMoveEvent and AttackEvent live in battle_events.dart
// (re-exported above) so the deterministic seam can emit them without
// importing this file.

/// One spell resolved this turn, in resolution order — drives the UI's
/// MtG-style card reveal sequence (battle_screen.dart): each entry is shown
/// full-card for 2s, then becomes a thumbnail (neutral tray for incantations,
/// on-grid for summons). [summonMinionId]/[summonPosition] are set only when
/// [isSummon] is true and the summon actually spawned (null for a void/no-op
/// summon cast — no thumbnail to place).
///
/// Counter charms are attuned to an elemental trajectory and cancel a cast
/// FORMULA BY FORMULA while the charm's sequence and the spell's stay in
/// lockstep (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2.2/§2.3), so a counter is no
/// longer all-or-nothing:
///
///   * [counteredFormulas] > 0 means a charm fired and cancelled that many
///     leading formulas. [counterCharmOwnerId] then names who owns the
///     triggered charm, which may equal [casterId] (a charm counters any
///     matching cast, including its own owner's).
///   * [wasCountered] is the FULL-counter case: the charm swallowed every
///     formula, so the cast never resolved at all and this event has empty
///     summon/created-effect fields.
///
/// A partially countered cast resolved for real — it has its created clouds,
/// tiles and minions, and its wild magic fired — it just did less than it
/// would have. UI that means "nothing happened" must test [wasCountered];
/// UI that means "a charm fired" must test [counteredFormulas].
class ResolvedSpellEvent {
  const ResolvedSpellEvent({
    required this.spell,
    required this.casterId,
    required this.targetHex,
    required this.isSummon,
    this.summonMinionId,
    this.summonPosition,
    this.createdCloudIds = const [],
    this.createdTileHexes = const [],
    this.createdMinionIds = const [],
    this.wasCountered = false,
    this.counteredFormulas = 0,
    this.counterCharmOwnerId,
  });

  final SpellAsset spell;
  final String casterId;
  final HexCoord targetHex;
  final bool isSummon;
  final String? summonMinionId;
  final HexCoord? summonPosition;
  final bool wasCountered;

  /// Leading formulas a counter charm cancelled — 0 when no charm fired.
  /// Equal to the spell's whole formula count exactly when [wasCountered].
  final int counteredFormulas;

  final String? counterCharmOwnerId;

  /// Battlefield effects this spell brought into being — purely for the UI's
  /// resolution reveal, which holds them off the field until the spell's card
  /// finishes, then blooms them out of [targetHex]. Computed by a before/after
  /// diff around the spell's application (see TurnLoop._resolveActions); not
  /// serialized, not gameplay-authoritative.
  final List<String> createdCloudIds;
  final List<HexCoord> createdTileHexes;
  final List<String> createdMinionIds;
}

/// A mystery-enhanced spell. Target tile and delay are hidden in
/// [mysteryCommitment] until revealed. If [delay] == 0 the player chose to
/// fire immediately: [immediateTarget] and [immediateNonce] are also set and
/// the spell resolves this turn. Otherwise the spell is held as a
/// [PendingDelayedSpell] and fired by a future [DelayedSpellReveal].
class MysterySpellCastAction extends TurnAction {
  MysterySpellCastAction({
    required this.spell,
    required this.mysteryCommitment,
    this.immediateTarget,
    this.immediateNonce,
    this.isPotent = false,
    this.isVelocity = false,
    this.recall,
    this.handIndex,
  });

  final SpellAsset spell;

  /// SHA-256(encodeCoord(target) ‖ delay_byte ‖ nonce_16). 32 bytes.
  final Uint8List mysteryCommitment;

  /// Non-null iff delay == 0 (fire this turn).
  final HexCoord? immediateTarget;
  final Uint8List? immediateNonce; // 16 bytes

  final bool isPotent;
  final bool isVelocity;

  /// See [SpellCastAction.recall].
  final IncantationRecall? recall;

  /// See [SpellCastAction.fizzledForMana].
  bool fizzledForMana = false;

  /// See [SpellCastAction.handIndex].
  final int? handIndex;

  bool get isImmediate => immediateTarget != null;
}

// ── Turn phase enum ───────────────────────────────────────────────────────────

enum TurnPhase {
  summons,
  actionCommit,
  movement,
  actionResolve,
  endOfTurn,
  winCheck,
}

// ── Resolution group (step 4 ordering) ───────────────────────────────────────

enum _ResolutionGroup { quickSpell, normalSpell, sluggishSpell }

// ── TurnLoop ──────────────────────────────────────────────────────────────────

// Wire spec: action/move reveal format is nonce(_kRevealNonceBytes) ‖ payload.
// All sites — nonce generation (.sublist(0, _kRevealNonceBytes)), reveal
// construction, skip-offset on receipt, and _verifyReveal — must use this
// constant; do not change one in isolation.
const _kRevealNonceBytes = 16;

// Maximum mana value — avatars are clamped to [0, _kMaxMana] after every
// spend or gain. Used in _spellManaCost and _certifiedManaCost so the ceiling
// cannot diverge between the local and verifier paths.
const _kMaxMana = 9999;

/// Mana charged per chargeable tile-unit of a Watery Boost run, before the
/// `n(n+1)/2` triangular multiplier (design v3.0 §Effect Table, Air-Air).
/// One tile costs a whole innate mana pool ([MatchConfig.innateManaPool] is
/// 100) — the effect is meant to be an expensive escape, not a commute.
const kBoostManaPerTile = 100;

/// Hard ceiling on chargeable Boost tiles, independent of how deep the
/// wizard's pockets are. Triangular cost makes 5 paid tiles cost 1500 mana /
/// 15 HP already; the cap exists so [TurnLoop.freeMoveGrantFor]'s search
/// terminates in bounded time no matter what a future mana pool looks like.
const _kMaxBoostPaidTiles = 8;

/// Mana restored by a single Meditate choice (main phase or move phase).
/// Taking both in the same turn grants 2 × this amount — see
/// [TurnInput.meditateInMove] and [MeditateAction].
const _kMeditateManaGain = 25;

/// Counter Charm passive: percentage points, per unspent charm, that a
/// successful melee destroys one of the victim's mana gems or withers one of
/// their in-hand spells (ARTIFACT_SYSTEM_PLAN.md §2.3). Linear and capped at
/// 100, so a full 12-charm loadout procs 60% of the time.
///
/// `[TODO — playtest]` — 60% is only balanced if melee is hard to land against
/// a kiting mage, which is a play question, not a math one.
const _kCounterCharmProcPctPerCharm = 5;

/// Rod of Wind passive: percentage points, per carried rod, of ONE
/// end-of-turn roll for +1 movement on the following turn
/// (ARTIFACT_SYSTEM_PLAN.md §2.8/§3.2). Capped at 100, so 10+ rods is a
/// guaranteed extra tile every turn — an archetype-defining passive parallel
/// to the mage slayer's.
///
/// `[TODO — playtest]` — both the rate and whether that 100% cap is the
/// archetype it should be.
const _kRodMovementPctPerRod = 10;

/// Domain-separation tag for the per-turn signed state-hash (Phase D,
/// BATTLE_AUTH_PLAN.md §6). Distinct from battle_session.dart's
/// `kIdentityAuthSignatureTag` so a state-hash signature can never be
/// replayed as an auth signature or vice-versa.
const kStateHashSignatureTag = 'RUNEWRIGHT_BATTLE_STATE_V1\x00';

/// Asks the local UI which adjacent tile (if any) to melee this turn, given
/// the list of adjacent tiles that hold at least one living hostile entity.
/// [candidates] is always non-empty when this is called — [TurnLoop] only
/// invokes it for a player who actually has a valid target (design: "pass
/// and make no melee attack" is the implicit choice for everyone else, with
/// no prompt shown at all). Return null to decline.
typedef MeleeTargetPicker =
    Future<HexCoord?> Function(List<HexCoord> candidates);

Future<HexCoord?> _defaultNoMelee(List<HexCoord> candidates) async => null;

/// What the post-resolution free-move window is offering one wizard this turn:
/// an Airy Barrier's burst step, a Boost's paid run, or both at once.
///
/// Derived from state by [TurnLoop.freeMoveGrantFor] on *both* devices — never
/// sent over the wire. The wire carries only the path the player chose, and the
/// receiver re-derives this grant to price and validate it (same trust-boundary
/// rule as `_certifiedManaCost`: a peer's claim about what it may do and what
/// that costs is never taken at face value).
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
  /// actually pay for (see [TurnLoop.boostMoveCost]). 0 means nothing to offer
  /// and no prompt is shown.
  final int maxTiles;

  bool get isEmpty => maxTiles <= 0;

  /// Steps that cost nothing: the burst step plus the boost's free tiles.
  int get freeTiles => (burstStep ? 1 : 0) + (boostResource == null ? 0 : boostFreeTiles);
}

/// Asks the local UI how far to move in the post-resolution free-move window,
/// given what [grant] is offering. Returns the declared path (step-adjacent
/// tiles, origin excluded, at most [FreeMoveGrant.maxTiles] long), or null /
/// empty to stand fast.
///
/// Only ever invoked for a player with a non-empty grant AND at least one legal
/// tile to step to. The returned path is re-validated and re-priced by
/// [TurnLoop] — a picker that returns something illegal or unaffordable gets it
/// truncated, not honoured.
typedef FreeMovePathPicker =
    Future<List<HexCoord>?> Function(FreeMoveGrant grant);

Future<List<HexCoord>?> _defaultNoFreeMove(FreeMoveGrant grant) async => null;

/// Asks the local UI which loadout artifact (if any) to spend this turn, given
/// the kinds the local wizard actually carries at least one of.
/// [available] is always non-empty when this is called — [TurnLoop] only
/// invokes it for a player who has something to spend. Return null to decline.
///
/// Declaring anything drops the declarer's own counter charms for the turn
/// (ARTIFACT_SYSTEM_PLAN.md §2.2), so the UI must make that cost legible
/// before the player commits.
typedef ArtifactActivationPicker =
    Future<AccoutrementKind?> Function(List<AccoutrementKind> available);

Future<AccoutrementKind?> _defaultNoActivation(
  List<AccoutrementKind> available,
) async => null;

/// Hands this turn's resolved walks to the UI *at the moment the avatars
/// actually move*, and waits for the playback to finish before the turn
/// continues.
///
/// The awaiting is the point. [TurnLoop] mutates [BattleState] in place and
/// then keeps awaiting network exchanges, while the battlefield painter
/// repaints every frame off a free-running controller — so a walk played back
/// after `runTurn` returns has already been spoiled: the token teleports to its
/// destination the instant [DeterministicResolution.resolveAvatarMovement]
/// runs, then snaps back to
/// the start when playback finally begins. Firing here, synchronously with the
/// position change, is what makes the walk the first thing anyone sees.
///
/// Cosmetic only, and safe to block on: it runs between the movement resolution
/// and the Phase 4b melee commit, which already blocks on an unbounded *human*
/// decision through [MeleeTargetPicker]. Both peers spend their own playback
/// time independently and re-synchronise at the next exchange. Defaults to
/// null — headless callers (tests, solo mode) animate nothing.
typedef MovementPlayback = Future<void> Function(List<AvatarMoveEvent> moves);

/// The Summons-phase counterpart of [MovementPlayback]: awaited once, after
/// every creature has acted, so their walks *and* their attacks play out before
/// the turn moves on. Same contract, same reason it is awaited rather than
/// fired and forgotten.
///
/// Both lists arrive together because the two are one event on screen: a melee
/// creature's lunge and the blow it lunged to land have to be seen happening at
/// the same moment, not one after the other. Either list may be empty — a
/// creature with reach attacks without moving, and a creature that closed the
/// distance may arrive with nothing left to strike with.
typedef SummonMovementPlayback =
    Future<void> Function(
      List<MinionMoveEvent> moves,
      List<AttackEvent> attacks,
    );

/// Awaited once at Phase 4b, after every wizard's haymaker has been applied, so
/// the punches are seen landing before the turn moves on to spell resolution.
/// Same cosmetic-and-blocking contract as [MovementPlayback]; defaults to null,
/// so headless callers animate nothing.
typedef AttackPlayback = Future<void> Function(List<AttackEvent> attacks);

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

/// What a counter-charm melee proc took from its victim.
enum CounterCharmProcKind { gemDestroyed, spellWithered }

/// One counter-charm melee proc that landed this turn — UI-only bookkeeping so
/// the battle screen can say *why* a gem vanished or a card greyed out. The
/// state change itself has already been applied; [TurnLoop] never reads these
/// back. An invisible proc reads as a bug rather than a mechanic.
class CounterCharmProcEvent {
  const CounterCharmProcEvent({
    required this.attackerId,
    required this.victimId,
    required this.outcome,
  });

  final String attackerId;
  final String victimId;
  final CounterCharmProcKind outcome;
}

/// Both players' settled Phase-0 declarations for one turn — what
/// [TurnLoop.beginArtifactPhase] returns and [TurnLoop.lastArtifactActivations]
/// holds.
///
/// Post-validation: a field is non-null only if that player really held the
/// declared artifact (see [TurnLoop._validateActivation]), so the UI can render
/// these directly without re-checking. A non-null [peer] is the information the
/// whole Phase-0 design exists to deliver — their counter charms are down this
/// turn, and the local player still has time to act on it.
class ArtifactActivationRound {
  const ArtifactActivationRound({this.local, this.peer});

  final AccoutrementKind? local;
  final AccoutrementKind? peer;

  bool get isEmpty => local == null && peer == null;
}

/// Implements [WildMagicHooks] and [ForcedCastHost] so wild-magic effects that
/// must re-enter turn-loop machinery (re-dealing a hand, forcing a reveal and
/// cast) reach it through a narrow named seam instead of the applicator
/// importing this file.
class TurnLoop implements WildMagicHooks, ForcedCastHost {
  TurnLoop({
    required this.state,
    required this.session,
    required this.localPlayerId,
    this.matchId,
    this.verifyProof,
    this.vkBytes,
    this.vkBytesForTier,
    this.peerBookRoot,
    this.peerBookLeafCount,
    this.peerOwnerPubkeyHex,
    this.peerPermissions = const [],
    this.tier = 24,
    this.isVocalComponents = false,
    this.isSomaticComponents = false,
    this.meleeTargetPicker = _defaultNoMelee,
    this.freeMoveDirectionPicker = _defaultNoFreeMove,
    this.artifactActivationPicker = _defaultNoActivation,
    this.onMovementResolved,
    this.onSummonMovementResolved,
    this.onMeleeResolved,
    this.onPhase,
    this.signMessage,
    this.peerRawPubkey,
    this.allowProoflessSpells = false,
    this.commitNonceSource,
  });

  /// The deterministic half of the engine: rules that are a pure function of
  /// [state] plus a seeded RNG, with no session, no suspension points and no
  /// notion of which device is running them.
  ///
  /// The seam the architecture review §5 asks for. `TurnLoop` keeps the
  /// network sequencing and the trust validation; everything on the far side
  /// of this field is independently callable without a `BattleSession` at all.
  /// It is deliberately narrow for now — end of turn and the helpers that
  /// phase shares — and is meant to grow as the suspending phases are untangled.
  ///
  /// Shares [state] by reference rather than owning a copy: both halves mutate
  /// one battle, and a second copy would be a desync surface, not a boundary.
  late final DeterministicResolution _resolution = DeterministicResolution(state);

  /// Test seam: overrides the source of commit-reveal salts.
  ///
  /// Production leaves this null and gets `Random.secure()`, which is the only
  /// correct answer — a commit salt an opponent can predict defeats the whole
  /// commit-reveal scheme, so this must NEVER be set outside tests.
  ///
  /// It exists because those salts make a turn **unreplayable**. The action
  /// phase RNG is seeded from `myCommit ^ peerCommit` (see [_actionPhaseSeed]),
  /// the commits are hashes of these salts, and anything drawn from that RNG —
  /// entity ids, tie-breaks, percentage rolls — therefore differs on every run
  /// even though both devices agree with each other within a run. The replay
  /// corpus (docs/REPLAY_HARNESS.md) pins them so a transcript is reproducible.
  ///
  /// Takes the byte count, returns exactly that many bytes.
  final Uint8List Function(int length)? commitNonceSource;

  /// A commit-reveal salt of [length] bytes: [commitNonceSource] when a test
  /// has pinned it, `Random.secure()` otherwise.
  Uint8List _commitNonce(int length) =>
      commitNonceSource?.call(length) ??
      CommitRevealEntropy.generateNonce().sublist(0, length);

  /// DEV FLAG — see [kAllowProoflessSpells] in lib/dev_flags.dart for the
  /// full rationale and the removal checklist. Defaults to false so every
  /// test and every non-UI construction site stays on the strict path; only
  /// BattleScreen wires the flag through. Delete this parameter with it.
  final bool allowProoflessSpells;

  final BattleState state;
  final BattleTurnSession session;
  final String localPlayerId;

  /// Called once per turn, after movement resolves, only when the local
  /// avatar has at least one adjacent hostile target. Defaults to always
  /// declining (headless callers — tests, solo mode's scripted dummy — never
  /// melee unless they override this).
  final MeleeTargetPicker meleeTargetPicker;

  /// Called once per turn, after all of phase 5's spells have resolved, only
  /// when the local avatar has something to spend in the free-move window —
  /// an Airy Barrier burst ([WizardAvatar.pendingFreeMoveBurst]) or a Boost
  /// ([WizardAvatar.pendingBoostMove]) — AND at least one adjacent free tile to
  /// step to. Defaults to always declining (headless callers — tests, solo
  /// mode's scripted dummy — never move unless they override this).
  ///
  /// Sorcerer seam: in a future real-time mode this should instead grant a
  /// temporary movement-speed boost rather than a discrete extra step —
  /// TODO(sorcerer): wire a speed-boost status effect for [GameMode.sorcerer]
  /// instead of prompting this picker.
  final FreeMovePathPicker freeMoveDirectionPicker;

  /// Called once per turn, at Phase 0 — before anything else in the turn — and
  /// only when the local avatar carries at least one activatable artifact (see
  /// [kActivatableArtifactKinds]). Defaults to always declining (headless
  /// callers — tests, solo mode's scripted dummy — never spend an artifact
  /// unless they override this).
  final ArtifactActivationPicker artifactActivationPicker;

  /// Optional UI playback hook: awaited once per turn, immediately after
  /// movement resolves and before anything else observes the new positions.
  /// See [MovementPlayback] for why this is awaited rather than fired and
  /// forgotten. Null (the default) skips it entirely.
  final MovementPlayback? onMovementResolved;

  /// Optional UI playback hook: awaited once per turn, after every summon has
  /// taken its Phase 5b action and before the dead are reaped, so a creature
  /// is seen making the move (or the melee lunge) that killed it. See
  /// [SummonMovementPlayback]. Null (the default) skips it entirely.
  final SummonMovementPlayback? onSummonMovementResolved;

  /// Optional UI playback hook: awaited once per turn, at Phase 4b, after every
  /// wizard's melee has been applied and before spell resolution begins. See
  /// [AttackPlayback]. Null (the default) skips it entirely.
  final AttackPlayback? onMeleeResolved;

  /// Optional UI notification hook: fired at the two phase boundaries a
  /// caller can't otherwise observe from outside [runTurn] — [TurnPhase
  /// .summons] just before the Summons-phase AI runs, and [TurnPhase
  /// .actionResolve] once the melee round has resolved and spell resolution
  /// is about to begin. The pre-submission phases (main/move) are already
  /// known locally by whatever UI called [beginTurn]/[runTurn], so this
  /// deliberately only covers the two phases that happen *inside* the
  /// opaque `await runTurn(...)` call. Never awaited, never affects
  /// resolution — purely a presentation seam.
  final void Function(TurnPhase phase)? onPhase;

  /// Cross-match domain separator folded into every phase seed.
  /// Set from [BattleSession.matchId] in production; null in solo/test.
  /// When non-null, identical entropy+turn+phase in two different matches
  /// produces a different HashRng stream, closing the cross-match seed
  /// collision. Defense-in-depth: entropy is freshly joint-revealed each turn
  /// so a collision requires both same entropy AND same matchId.
  final Uint8List? matchId;

  // ── Option 3: on-cast proof verification ─────────────────────────────────────

  /// FFI verifier function. When non-null, every peer spell cast is verified
  /// via [ProofIntake.verifyAndParse] before being accepted.
  final ProofVerifier? verifyProof;

  /// Verification key bytes, used when [vkBytesForTier] is null or has no
  /// entry for the tier being verified.
  ///
  /// A single match-wide VK is NOT sufficient on its own: every spell is
  /// proven at the smallest tier covering its own T ([tierForSteps]), so a
  /// tier-12 spell cast into a tier-24 match presents 42 public inputs to a
  /// VK expecting 66 and barretenberg rejects it ("num_public_inputs mismatch
  /// with VK"). That was a real two-device break — see [_vkForTier].
  final Uint8List? vkBytes;

  /// Resolves the bundled verification key for a given circuit tier
  /// (12 / 24 / 48). Supplied by the battle screen, which bundles all three.
  ///
  /// Null in solo/tests, where [vkBytes] (usually an empty placeholder
  /// alongside a null [verifyProof]) stands in.
  final Uint8List? Function(int tier)? vkBytesForTier;

  /// The peer's Merkle book root (hex), received at session handshake. Used
  /// to verify the membership proof included with each peer spell cast.
  final String? peerBookRoot;

  /// The peer's chapter leaf count, declared publicly at handshake alongside
  /// [peerBookRoot] (SPELL_DRAW_WIRING_PLAN.md §3). Lets this client deal the
  /// peer's [DrawSchedule] (position bookkeeping only — see [_drawSchedules])
  /// without ever learning the peer's chapter contents. Null in solo/test,
  /// matching [peerBookRoot]'s own doc comment.
  final int? peerBookLeafCount;

  /// The peer's *authenticated* owner_pubkey (BATTLE_AUTH_PLAN.md §3) — the
  /// result of a fresh-nonce Ed25519 challenge-response at handshake
  /// (`BattleSession.exchangeIdentityAuth`), NOT the unauthenticated value a
  /// proof merely declares. Gates cast authorization (§4): null in solo/test,
  /// where there is no real peer to authenticate and the check is skipped.
  final String? peerOwnerPubkeyHex;

  /// Signed loan/transfer grants naming the peer as grantee, verified at
  /// handshake (`BattleSession.exchangeSpellPermissions`,
  /// BATTLE_AUTH_PLAN.md §5). Consulted by [castingPlayerMayUse] when the
  /// peer casts a spell they don't own. Empty in solo/test.
  final List<SpellPermission> peerPermissions;

  /// Circuit tier (12 / 24 / 48), from [MatchConfig.tier].
  ///
  /// This is the tier the *match* negotiated — a ceiling, not the tier any
  /// given spell was proven at. Never verify or parse a spell against it; use
  /// [_tierForSpell] / [_vkForTier], which key off the spell's own T.
  final int tier;

  /// The circuit tier a spell with [t] generations was proven at — the
  /// smallest tier covering it, exactly as [inscribeSpell] chose at proving
  /// time. Null when [t] is outside the circuit's supported range.
  ///
  /// [t] arrives on the wire for a peer cast and is therefore untrusted, but
  /// using it only to *select* a verification key is fail-closed: a wrong tier
  /// picks a VK the proof cannot satisfy and verification rejects it.
  /// [_verifyPeerSpellCast] additionally re-checks the certified `outputs.t`
  /// against the claim, so the value that chose the layout is bound to the
  /// value the proof actually attests.
  static int? _tierForSpell(int t) => tierForSteps(t);

  /// The verification key for [tier], preferring the per-tier resolver and
  /// falling back to the single [vkBytes].
  Uint8List? _vkForTier(int tier) => vkBytesForTier?.call(tier) ?? vkBytes;

  /// When true, spell action payloads carry the [IncantationRecall] suffix,
  /// committed inside the action hash, and the peer prices the recital against
  /// the certified trajectory. Must match [MatchConfig.vocalComponents] on both
  /// sides.
  ///
  /// This is the ONLY component flag the wire format depends on. Somatic
  /// components add no wire field at all — see [isSomaticComponents].
  final bool isVocalComponents;

  /// When true, the caster selects their enhancement by gesture rather than by
  /// tapping. Must match [MatchConfig.somaticComponents] on both sides.
  ///
  /// The engine reads this for exactly one thing: [_componentsGameMode]. There
  /// is deliberately no somatic field on the wire and no somatic term in the
  /// mana chain, because a gesture is a self-attested sensor claim the peer can
  /// never recheck (docs/SPELL_COMPONENTS_PLAN.md §6). What DOES cross the wire
  /// is the resulting enhancement claim, which is certified against
  /// `supreme_dominance_flags` exactly as a tapped one is — an unbacked claim
  /// still forfeits, whichever way the caster selected it.
  final bool isSomaticComponents;

  /// [GameMode.sorcerer] whenever casting is a performance at all. Mirrors
  /// [MatchConfig.componentsEnabled]; both components land here identically
  /// because [CastingEnhancements.gameMode] asks "is this a performed cast",
  /// not "which component was performed".
  GameMode get _componentsGameMode => (isVocalComponents || isSomaticComponents)
      ? GameMode.sorcerer
      : GameMode.wizard;

  /// The local player's sorted chapter commitmentHex list — set after the
  /// spell library resolves (async after construction in the battle screen).
  /// When non-null, generates Merkle membership proofs for outgoing casts.
  /// When null, proof bytes and membership proofs are omitted from the wire.
  List<String>? localChapterCommitments;

  /// The local player's own chapter, as full [SpellAsset]s rather than just
  /// commitment hashes — set alongside [localChapterCommitments]. Needed to
  /// answer an incoming Watery Scrying Pool reveal (§ divination spellList
  /// flavor): the peer needs the actual spell data, not just its hash, to
  /// render anything. When null, an incoming reveal request is answered as
  /// "no active reveal" — same as having no chapter loaded yet.
  ///
  /// NOT required to be pre-sorted by commitmentHex — [_dealOpeningHandsIfNeeded]
  /// sorts its own canonical copy before dealing (see that method's doc
  /// comment for why: this field arrives in whatever order the UI's chapter
  /// resolution produced, which is not the Merkle leaf order).
  List<SpellAsset>? localChapterSpells;

  /// The local player's verified view of the enemy's spell list, when an
  /// outgoing Water [DivinationLink] is active this turn — null otherwise.
  /// Reset to null at the start of every [beginTurn] before the exchange
  /// runs, so a stale reveal never survives past the turn it was granted for
  /// (this is what makes the UI's reveal row clear at end of turn).
  List<SpellAsset>? revealedEnemyHand;

  // ── Hand/deck (SPELL_DRAW_WIRING_PLAN.md §2) ────────────────────────────────
  //
  // Two kinds of draw state, split by secrecy (§2 consequence 1):
  //   - CONTENTS (which SpellAsset sits at each position): local-only,
  //     [localSpellDraw], never serialized into the state hash.
  //   - POSITIONS (the in-hand/withered index sets): publicly computable by
  //     BOTH clients from the entropy stream + the public cast/effect log —
  //     [_drawSchedules], keyed by playerId, for BOTH players.
  // Both are dealt together, from the same seed bytes via two independently
  // constructed HashRng instances, so they can never desync from a shared
  // mutable-RNG-state bug (only from a genuine logic error, which
  // draw_schedule_test.dart's cross-check and the turn-loop determinism tests
  // guard against).

  /// The local player's live hand/deck contents. Null until [localChapterSpells]
  /// has resolved and the opening deal has run (see [_dealOpeningHandsIfNeeded]).
  SpellDraw? localSpellDraw;

  /// Position-only hand/deck bookkeeping for BOTH players, keyed by playerId.
  /// The single public source of truth §6's in-hand cast enforcement and §9's
  /// wither/reactivate run against. The local player's entry always stays in
  /// lockstep with [localSpellDraw] (same draws, independently seeded — see
  /// header comment above). The peer's entry exists only when [peerBookLeafCount]
  /// is non-null (a real duel); stays absent for solo/test, matching how there
  /// is no peer chapter at all in that mode.
  final Map<String, DrawSchedule> _drawSchedules = {};

  /// Cast spell contents revealed over the course of the match, keyed by
  /// (playerId, chapter position) — unlike [lastResolvedSpells], never
  /// cleared between turns. Populated once per cast, at the peer branch of
  /// [_advanceDrawState]'s two call sites: the peer's cast is reconstructed
  /// by [_decodeAction] with real name/formula/commitmentHex but an EMPTY
  /// [SpellAsset.initialGrid] (the ZK model never transmits grid/segment
  /// data, only a Merkle membership proof of which position was cast). The
  /// local player's own entries are never written here — [spellAt] already
  /// covers every local position via [localSpellAt], cast or not.
  final Map<String, Map<int, SpellAsset>> _revealedCastContents = {};

  /// Chapter positions [playerId] has permanently cast — i.e. left both
  /// [DrawSchedule.hand] and [DrawSchedule.remaining] forever, which only
  /// [DrawSchedule.useSlotAtPosition] does and never undoes. Derived, not
  /// stored: the complement of hand ∪ remaining within [0, chapterSize) —
  /// every non-deck-out cast moves exactly one position permanently out of
  /// both, so this needs no new synced state. Empty until both the
  /// schedule and this player's chapter size are known.
  Set<int> usedChapterPositions(String playerId) {
    final schedule = _drawSchedules[playerId];
    if (schedule == null) return const <int>{};
    final chapterSize = playerId == localPlayerId
        ? localChapterSpells?.length
        : (playerId == _peerId() ? peerBookLeafCount : null);
    if (chapterSize == null) return const <int>{};
    final known = <int>{...schedule.hand, ...schedule.remaining};
    return {
      for (var p = 0; p < chapterSize; p++)
        if (!known.contains(p)) p,
    };
  }

  /// Known content at [playerId]'s chapter [position], or null if unknown.
  /// The local player is always fully known (delegates to [localSpellAt]
  /// for every position, withered or not — withering never hides a card
  /// from its own owner). Any other player is known ONLY at positions
  /// they've actually cast (see [_revealedCastContents]) — a currently
  /// withered opponent position has, by construction, never been cast
  /// (once cast, a position can never become withered again), so it stays
  /// permanently unknown to this client unless/until it's later cast. This
  /// is a structural consequence of the ZK privacy model, not a bug — the
  /// graveyard UI (battle_screen.dart) renders these as face-down.
  SpellAsset? spellAt(String playerId, int position) {
    if (playerId == localPlayerId) return localSpellAt(position);
    return _revealedCastContents[playerId]?[position];
  }

  /// Set once [_dealOpeningHandsIfNeeded] has dealt the opening hands, so a
  /// later turn never re-deals (chapter resolution is async and may not be
  /// ready on turn 1 — see that method's doc comment).
  bool _handsDealt = false;

  /// True once [startBattle] has run the battle-start entropy exchange, so a
  /// second call (e.g. a re-render triggering the init path again) no-ops.
  bool _battleStarted = false;

  /// Monotonic per-player draw counter, folded into every refill (0x05) and
  /// wither (0x06) seed so multiple draws for one player within a single
  /// entropy window never collide onto the same RNG stream. The turn-based
  /// engine draws at most once per player per turn, so today this only ever
  /// reaches 1 per turn — but real-time/sorcerer mode casts as fast as mana +
  /// input allow (SPELL_DRAW_WIRING_PLAN.md §4), so the discriminator has to
  /// exist before that engine lands. Both clients increment it in the same
  /// lockstep resolution order, so it stays in sync (turn-loop determinism
  /// tests guard that).
  final Map<String, int> _drawSeedNonce = {};

  int _consumeDrawNonce(String playerId) {
    final n = _drawSeedNonce[playerId] ?? 0;
    _drawSeedNonce[playerId] = n + 1;
    return n;
  }

  /// Runs the battle-start commit-reveal (BATTLE_PROTOCOL.md §0's per-battle
  /// `exchangeNonce`, specified but previously unimplemented) and deals both
  /// opening hands from its joint entropy — once, *before* turn 1's action
  /// commit — so turn 1 is fully castable like any other turn. The UI must
  /// await this before enabling turn-1 interaction (battle_screen gates its
  /// `_loopReady` spinner on it).
  ///
  /// Mechanically this is just one extra round of the same `exchangeNonce`
  /// [_resolveEntropy] already runs every turn, placed ahead of the loop; both
  /// clients call it symmetrically from the same setup path. Idempotent.
  ///
  /// Headless callers (tests) that never call this still get an opening hand:
  /// [runTurn] deals from turn-1 entropy the first time via
  /// [_dealOpeningHandsIfNeeded] (the `_handsDealt` guard makes that a no-op
  /// once this has dealt). That fallback is why turn-based tests don't need a
  /// setup step.
  Future<void> startBattle() async {
    if (_battleStarted) return;
    _battleStarted = true;
    final startEntropy = await _resolveEntropy();
    _componentStartSeat =
        componentStartSeat(startEntropy, componentSeating.length);
    _dealOpeningHandsIfNeeded(startEntropy);
  }

  // ── Spell-component order (docs/SPELL_COMPONENTS_PLAN.md §5.2) ──────────────
  //
  // Pacing only. Nothing here touches the mana ledger, the state hash, or any
  // exchange the engine awaits — a client that ignores the whole mechanism
  // stalls its opponent's controls and desyncs nothing.

  /// Which seat leads on turn 1, drawn from the battle-start joint entropy so
  /// neither device chooses it. Null until [startBattle] has run; callers fall
  /// back to seat 0, which is stable and identical on both devices.
  int? _componentStartSeat;

  /// Player ids clockwise around the field by starting position. Falls back to
  /// [BattleState.avatars] order for states built before seating existed —
  /// already canonical, so the fallback is stable rather than arbitrary.
  List<String> get componentSeating => state.componentSeating.isNotEmpty
      ? state.componentSeating
      : [for (final a in state.avatars) a.playerId];

  /// The turn the components being performed right now belong to.
  ///
  /// [state.turnNumber] is only incremented at the top of [runTurn], so during
  /// the action phase it still holds the turn just finished — the turn being
  /// declared is the next one. Both devices are in lockstep on that value, so
  /// both label the signal identically.
  int get componentTurnNumber => state.turnNumber + 1;

  /// The performing order for [turnNumber], leading player first.
  List<String> componentOrder(int turnNumber) => componentOrderForTurn(
        seating: componentSeating,
        startSeat: _componentStartSeat ?? 0,
        turnNumber: turnNumber,
      );

  /// Where the local player sits in [turnNumber]'s order, or -1 if they are
  /// not in it.
  int localComponentSlot(int turnNumber) =>
      componentOrder(turnNumber).indexOf(localPlayerId);

  /// Announces that the local player has finished performing and locked in.
  ///
  /// Called at the lock-in point for EVERY action type, not just spell casts:
  /// a Dash consumes its slot exactly as a cast does, so that nothing about
  /// what a player chose leaks from the timing of when they acted.
  void signalComponentsDone() =>
      session.sendComponentsDone(componentTurnNumber);

  /// Completes when it is the local player's turn to perform.
  ///
  /// Returns immediately when this player leads, when ordering is off
  /// (simultaneous casting, or no components at all), or when there is no peer
  /// to wait on — [BattleTurnSession.peerComponentsDone] is already an
  /// immediately-completed future in those cases.
  ///
  /// LIMITATION (2-player): the transport is pairwise, so "everyone ahead of
  /// me" collapses to "the one peer". A mesh session with 3+ performers needs
  /// the signal to name its sender so a waiter can count them off; see
  /// MESH_ARCHITECTURE.md.
  Future<void> awaitComponentSlot() async {
    if (!state.config.sequentialCasting) return;
    if (localComponentSlot(componentTurnNumber) <= 0) return;
    await session.peerComponentsDone(componentTurnNumber);
  }

  /// Deals the opening hand/deck for both players, once, from [entropy].
  ///
  /// Interactive play deals from the **battle-start** joint entropy, via
  /// [startBattle], before turn 1's action commit — so turn 1 is fully castable
  /// (SPELL_DRAW_WIRING_PLAN.md §3). Headless callers that skip [startBattle]
  /// (turn-based tests) fall back to dealing from turn-1's entropy the first
  /// time [runTurn] reaches here; the `_handsDealt` guard makes whichever path
  /// runs first the only one that deals.
  ///
  /// No-ops (and leaves [_handsDealt] false, so the next turn retries) until
  /// [localChapterSpells] is set — mirrors [_maybeSetLocalChapterCommitments]'s
  /// same race in battle_screen.dart.
  ///
  /// [localChapterSpells] is NOT required to already be commitmentHex-sorted
  /// (battle_screen.dart's `_loadSpells` builds it in chapter-entry order) —
  /// this method sorts its own canonical copy first. That sort is load-bearing:
  /// SpellDraw/DrawSchedule's positions only line up with BookCommitment's
  /// Merkle leaf indices when both sort by the same key (§2 consequence 3).
  void _dealOpeningHandsIfNeeded(Uint8List entropy) {
    if (_handsDealt) return;
    final chapter = localChapterSpells;
    if (chapter == null) return;
    _handsDealt = true;

    final canonicalChapter = List<SpellAsset>.from(chapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    // Hand size is per-avatar (bookmarkCount + 1, always ≥ 1) — not a shared
    // negotiated MatchConfig value, since bookmarks come from each player's
    // own accoutrement loadout (accoutrementsFromArtifacts).
    final localHandSize = _localAvatar().bookmarkCount + 1;

    final localSeed = _playerPhaseSeed(
      entropy,
      matchId,
      state.turnNumber,
      0x07,
      localPlayerId,
    );
    localSpellDraw = SpellDraw.opening(
      canonicalChapter,
      localHandSize,
      HashRng(localSeed),
    );
    _drawSchedules[localPlayerId] = DrawSchedule.opening(
      canonicalChapter.length,
      localHandSize,
      HashRng(localSeed),
    );

    final peerId = _peerId();
    final leafCount = peerBookLeafCount;
    if (peerId != null && leafCount != null && leafCount > 0) {
      final peerHandSize = (_avatarById(peerId)?.bookmarkCount ?? 0) + 1;
      final peerSeed = _playerPhaseSeed(
        entropy,
        matchId,
        state.turnNumber,
        0x07,
        peerId,
      );
      _drawSchedules[peerId] = DrawSchedule.opening(
        leafCount,
        peerHandSize,
        HashRng(peerSeed),
      );
    }
  }

  /// Advances hand/deck draw state after a validated cast leaves [casterId]'s
  /// hand (SPELL_DRAW_WIRING_PLAN.md §4). [position] is the cast's
  /// authenticated chapter position (a Merkle leafIndex, derived identically
  /// whether [casterId] is the local player or the peer — see the two call
  /// sites in [runTurn]).
  ///
  /// Always advances the public [_drawSchedules] entry for [casterId] — the
  /// bookkeeping both clients compute for both players — when one has been
  /// dealt (no-ops otherwise: a chapter-load race, see
  /// [_dealOpeningHandsIfNeeded], not a correctness issue since no cast can
  /// reach here before dealing succeeds on an honest peer). Additionally
  /// advances [localSpellDraw]'s CONTENTS when [casterId] is the local
  /// player — the peer's contents are never known to this client.
  ///
  /// The schedule and (when local) SpellDraw updates use two independently
  /// constructed HashRng instances from the *same* seed bytes, never a
  /// shared mutable instance — see this class's "Hand/deck" header comment
  /// for why that's what keeps them from ever desyncing.
  void _advanceDrawState(String casterId, int position, Uint8List entropy) {
    final schedule = _drawSchedules[casterId];
    if (schedule == null) return;
    final handIndex = schedule.hand.indexOf(position);
    if (handIndex < 0) return; // already validated castable — shouldn't happen
    final seed = _playerPhaseSeed(
      entropy,
      matchId,
      state.turnNumber,
      0x05,
      casterId,
      _consumeDrawNonce(casterId),
    );
    _drawSchedules[casterId] = schedule.useSlotAtPosition(
      position,
      HashRng(seed),
    );
    if (casterId == localPlayerId) {
      final draw = localSpellDraw;
      if (draw != null && handIndex < draw.hand.length) {
        localSpellDraw = draw.useSpell(handIndex, HashRng(seed));
      }
    }
  }

  /// Reconciles [avatarId]'s hand size after its bookmark count changed from
  /// [beforeCount] to [afterCount] within one spell resolution (handSize ==
  /// bookmarkCount + 1 — see [_dealOpeningHandsIfNeeded]). Growing draws a
  /// fresh spell into a new slot immediately, using this turn's already-
  /// revealed entropy; shrinking returns a randomly chosen slot's spell to
  /// the deck (reinserted in canonical order — see [SpellDraw.removeSlot] /
  /// [DrawSchedule.removeSlot]).
  ///
  /// Mirrors [_advanceDrawState]'s dual-structure update: [_drawSchedules]
  /// (both players' public position bookkeeping) always advances;
  /// [localSpellDraw] (real contents) only advances when [avatarId] is the
  /// local player — the peer's contents are never known to this client.
  /// Each slot change consumes its own [_consumeDrawNonce] under domain tag
  /// `0x08`, so multiple simultaneous slot changes (e.g. burnArtifactCount >
  /// 1) never collide with each other or with refill (`0x05`) / wither
  /// (`0x06`) / opening-deal (`0x07`) draws.
  void _reconcileHandSize(
    String avatarId,
    int beforeCount,
    int afterCount,
    Uint8List entropy,
  ) {
    final schedule = _drawSchedules[avatarId];
    if (schedule == null) return;
    var currentSchedule = schedule;
    var currentDraw = avatarId == localPlayerId ? localSpellDraw : null;
    final delta = afterCount - beforeCount;
    if (delta > 0) {
      for (var i = 0; i < delta; i++) {
        final seed = _playerPhaseSeed(
          entropy,
          matchId,
          state.turnNumber,
          0x08,
          avatarId,
          _consumeDrawNonce(avatarId),
        );
        currentSchedule = currentSchedule.addSlot(HashRng(seed));
        if (currentDraw != null) {
          currentDraw = currentDraw.addSlot(HashRng(seed));
        }
      }
    } else {
      for (var i = 0; i < -delta && currentSchedule.hand.isNotEmpty; i++) {
        final seed = _playerPhaseSeed(
          entropy,
          matchId,
          state.turnNumber,
          0x08,
          avatarId,
          _consumeDrawNonce(avatarId),
        );
        final handIndex = HashRng(seed).nextInt(currentSchedule.hand.length);
        currentSchedule = currentSchedule.removeSlot(handIndex);
        if (currentDraw != null && handIndex < currentDraw.hand.length) {
          currentDraw = currentDraw.removeSlot(handIndex);
        }
      }
    }
    _drawSchedules[avatarId] = currentSchedule;
    if (avatarId == localPlayerId) localSpellDraw = currentDraw;
  }

  /// Whether chapter position [position] is currently withered, per this
  /// client's own public [_drawSchedules] bookkeeping for [playerId] — the
  /// same bookkeeping both clients compute identically (§9). False if that
  /// player's schedule isn't dealt yet. Exposed beyond [isHandSpellWithered]'s
  /// local-only convenience so callers (and tests — SPELL_DRAW_WIRING_PLAN.md
  /// §10 item 5) can assert cross-client agreement on withered state for
  /// either player, not just the local one.
  bool isPositionWithered(String playerId, int position) =>
      _drawSchedules[playerId]?.isWithered(position) ?? false;

  /// Read-only view of [playerId]'s public, position-only draw schedule — the
  /// bookkeeping both clients compute identically for BOTH players. Null until
  /// the opening deal has run.
  ///
  /// Safe to expose for either player: a [DrawSchedule] holds chapter
  /// POSITIONS, never spell contents (see draw_schedule.dart's header), so
  /// this leaks nothing about the peer's hand beyond its size and which slots
  /// are withered — both of which are already public.
  DrawSchedule? drawScheduleFor(String playerId) => _drawSchedules[playerId];

  /// Whether [spell] — a card currently in [localSpellDraw]'s hand — is
  /// withered and therefore not castable (FuelTransmutation Fire, §9). The
  /// UI seam (battle_screen.dart) uses this to grey out withered cards and
  /// [_selectSpell] should refuse them. False (never withered) if draw state
  /// isn't dealt yet or [spell] isn't a chapter member.
  ///
  /// Prefer [isHandSlotWithered] when the caller already knows which hand
  /// slot [spell] came from (docs/BASIC_SPELLS_PLAN.md §7) — this
  /// commitment-based lookup only resolves to the FIRST chapter occurrence
  /// of [spell]'s grid, which is wrong for a chapter holding more than one
  /// copy of the same Basic spell.
  bool isHandSpellWithered(SpellAsset spell) {
    final commitments = localChapterCommitments;
    if (commitments == null) return false;
    final proof = BookCommitment.proveMembership(commitments, spell.commitmentHex);
    if (proof == null) return false;
    return isPositionWithered(localPlayerId, proof.leafIndex);
  }

  /// Whether the card currently at [handIndex] in [localSpellDraw]'s hand is
  /// withered — the duplicate-safe form of [isHandSpellWithered]. False if
  /// draw state isn't dealt yet or [handIndex] is out of range.
  bool isHandSlotWithered(int handIndex) {
    final schedule = _drawSchedules[localPlayerId];
    if (schedule == null || handIndex < 0 || handIndex >= schedule.hand.length) {
      return false;
    }
    return isPositionWithered(localPlayerId, schedule.hand[handIndex]);
  }

  /// The chapter position of a local cast of [spell]: the caster's own hand
  /// slot when [handIndex] is known (the only form that stays correct when
  /// the chapter holds several copies of [spell]'s grid — see
  /// docs/BASIC_SPELLS_PLAN.md §7), else a commitment lookup (legacy path
  /// for solo/test call sites that never set handIndex, and for tests using
  /// single-copy chapters where the two forms always agree).
  int? _localCastPosition(SpellAsset spell, int? handIndex) {
    if (handIndex != null) {
      final schedule = _drawSchedules[localPlayerId];
      if (schedule != null && handIndex >= 0 && handIndex < schedule.hand.length) {
        return schedule.hand[handIndex];
      }
    }
    final commitments = localChapterCommitments;
    if (commitments == null) return null;
    return BookCommitment.proveMembership(commitments, spell.commitmentHex)?.leafIndex;
  }

  // ── Phase D: signed per-turn state hash (BATTLE_AUTH_PLAN.md §6) ───────────

  /// Signs a message with the local identity's private key
  /// (`Identity.sign`, bound at construction). When non-null, every
  /// outgoing state hash is signed; when null (solo/test), the raw 32-byte
  /// hash is sent unsigned, exactly as before Phase D existed.
  final Future<List<int>> Function(List<int> message)? signMessage;

  /// The peer's raw 32-byte Ed25519 public key, authenticated at handshake
  /// (`BattleSession.exchangeIdentityAuth`'s `AuthenticatedPeer.rawPubkey`) —
  /// NOT the unauthenticated value a proof merely declares. When non-null,
  /// every incoming state hash's signature is verified against it before the
  /// hash-equality lockstep check runs. Null in solo/test, where there is no
  /// real peer to verify against.
  final Uint8List? peerRawPubkey;

  /// commitmentHex values the peer has cast this match. A second cast of the
  /// same grid is a protocol violation; the match is forfeited on detection.
  /// EXCEPT for a shipped Basic spell (docs/BASIC_SPELLS_PLAN.md —
  /// isBasicGridAndT) or a Cantrip (certified trajectory under
  /// kKinshipMinElements, spell_identity.dart), either of which is exempt: a
  /// chapter may hold unlimited copies of one, so casting it more than once
  /// per match is legitimate, not an exploit.
  final _seenPeerCommitments = <String>{};

  /// Spell casts resolved during the most recent [runTurn] call, for the UI's
  /// cast animation. Cleared and repopulated at the start of every turn.
  List<SpellCastEvent> lastCastEvents = [];

  /// Spells resolved during the most recent [runTurn] call, in resolution
  /// order (the same order [_resolveActions] applied them) — including
  /// countered casts ([ResolvedSpellEvent.wasCountered]). Cleared and
  /// repopulated at the start of every turn. See [ResolvedSpellEvent].
  List<ResolvedSpellEvent> lastResolvedSpells = [];

  /// commitmentHex → certified BASE mana cost (5×segmentCount + dotCount,
  /// grown by 1.05^T × 1.5^effectCount — see [_certifiedBaseManaCost]) for
  /// every peer spell verified during the most recent [runTurn] call.
  /// Cleared and repopulated at the start of every turn, populated only for
  /// peer casts (by [_verifyPeerSpellCast]) — never for the local player's
  /// own cast. This is the "clean bestiary stat" (Sightings, docs/
  /// SIGHTINGS_PLAN.md §2), deliberately excluding the per-cast modifiers
  /// (chain discount, Efficiency, sorcerer multiplier, nextSpellCostDouble)
  /// that [_certifiedManaCost] layers on top for the actual mana deduction.
  Map<String, int> lastCertifiedBaseManaCosts = {};

  /// Conveyor-tile pushes (cascades, closed loops) resolved during the most
  /// recent [runTurn] call, for the UI's belt/loop animation. Cleared and
  /// repopulated at the start of every turn.
  List<ConveyorChainEvent> lastConveyorChainEvents = [];

  /// Counter-charm melee procs that landed during the most recent [runTurn]
  /// call, for the UI's "your gem shattered" / "that card just withered"
  /// feedback. Cleared and repopulated at the start of every turn.
  List<CounterCharmProcEvent> lastCounterCharmProcs = [];

  /// Every avatar's walk during the most recent [runTurn] call — one entry per
  /// living avatar, including those who stayed put — for the UI's movement
  /// animation. Cleared and repopulated at the start of every turn.
  ///
  /// All entries share one playback timeline (see battle_screen.dart), which is
  /// what makes a collision legible: the wizards converge on the contested tile
  /// at the same instant, and the loser recoils off it. See [AvatarMoveEvent].
  List<AvatarMoveEvent> lastAvatarMoveEvents = [];

  /// Every summon's walk during the most recent Summons phase — one entry per
  /// creature that actually went somewhere or lunged, for the UI's movement
  /// animation. Cleared at the start of the Summons phase rather than at the
  /// start of the turn: a Potent summon's bonus action happens back in Phase 5
  /// and is already shown by that spell's own card reveal, so replaying it here
  /// would walk the creature a second time. See [MinionMoveEvent].
  List<MinionMoveEvent> lastMinionMoveEvents = [];

  /// Every blow a summon landed during the most recent Summons phase, for the
  /// UI's attack animation. Cleared alongside [lastMinionMoveEvents] and for
  /// the same reason (a Potent summon's Phase 5 bonus action is already shown
  /// by its spell's card reveal). See [AttackEvent].
  List<AttackEvent> lastMinionAttackEvents = [];

  /// Every wizard haymaker that landed during the most recent Phase 4b melee
  /// round — the local player's and the peer's — for the UI's attack animation.
  /// Cleared and repopulated each turn at the melee round. See [AttackEvent].
  List<AttackEvent> lastMeleeAttackEvents = [];

  /// Wild-magic effects that fired during the most recent [runTurn] call, in
  /// resolution order. Cleared and repopulated at the start of every turn.
  ///
  /// **A global effect the player cannot see happen is a bug**, not a missing
  /// UI nicety: wild magic is untelegraphed by design, so battle_screen.dart's
  /// resolution reveal is the only place either player learns it fired at all.
  List<WildMagicEvent> lastWildMagicEvents = [];

  /// Per-turn counter folded into every 0x09 wild-magic seed, so two casts in
  /// the same turn never share an RNG stream. Same pattern as
  /// [_consumeDrawNonce]; reset at the start of each turn because the seed
  /// already includes the turn number.
  int _wildMagicNonce = 0;

  int _consumeWildMagicNonce() => _wildMagicNonce++;

  /// Per-match counter folded into the 0x0A Rippling Reflections coin, so two
  /// spells resolving in the same turn get independent flips.
  int _ripplingNonce = 0;

  /// Per-turn counter folded into every 0x0B turbulent-range roll, so two
  /// casts in the same turn don't fly the same rolled distance. Reset at the
  /// start of each turn (the seed already carries the turn number), same
  /// pattern as [_wildMagicNonce]. Both peers walk the sorted action list in
  /// the same order, so the counter advances identically on both devices.
  int _turbulentNonce = 0;

  /// Forced casts queued by [WildMagicApplicator] during the synchronous
  /// wild-magic sweep, drained (with their network round trip) before the
  /// triggering spell's own formula effects resolve. See [ForcedCast].
  final List<ForcedCastRequest> _pendingForcedCasts = [];

  /// This turn's revealed joint entropy, stashed so the [WildMagicHooks] /
  /// [ForcedCastHost] callbacks (which the applicator invokes without an
  /// entropy argument) can derive their seeds from it. Set in [runTurn] right
  /// after the Phase 3 reveal; null before the first turn.
  Uint8List? _turnEntropy;

  // ── Pending action state (set by beginTurn, consumed by runTurn) ─────────
  //
  // Lets the UI call beginTurn() as soon as the local player locks in their
  // action — before they've chosen a move path — so an active Airy Scrying
  // Pool link (MESH_ARCHITECTURE.md §13b) can reveal the opponent's spell
  // target in time to inform that choice. runTurn() calls beginTurn() itself
  // if the UI didn't prime it first, so every existing runTurn() caller
  // (tests, solo mode) is unaffected.
  TurnAction? _pendingAction;
  Uint8List? _pendingActionBytes;
  Uint8List? _pendingSaltA;
  Uint8List? _pendingSaltB;
  Uint8List? _pendingActionCommit;
  Uint8List? _pendingPeerActionCommit;

  /// Memoizes the in-flight/completed call so a concurrent or later call
  /// (from [runTurn], if the UI already primed this turn) awaits the same
  /// result instead of re-running the action-commit exchange a second time.
  /// See [beginTurn] / [cancelPendingTurn].
  Future<HexCoord?>? _beginTurnFuture;

  /// Memoizes this turn's Phase-0 exchange, exactly like [_beginTurnFuture]
  /// does for the action commit: the UI calls [beginArtifactPhase] at the top
  /// of the turn to learn the peer's declaration before choosing an action,
  /// and [beginTurn] awaits the same completed Future rather than re-running
  /// a second exchange over the wire. Cleared by [runTurn] once the turn it
  /// belongs to has been consumed.
  ///
  /// Deliberately NOT cleared by [cancelPendingTurn]: by the time a turn is
  /// abandoned the Phase-0 frames have already crossed the wire and the
  /// declaration has already been applied to both devices' state. Replaying it
  /// would send a second pair of frames the peer is not waiting for.
  Future<ArtifactActivationRound>? _artifactPhaseFuture;

  /// This turn's settled Phase-0 declarations — a UI read-out of what
  /// [beginArtifactPhase] resolved to, so a caller that didn't hold onto the
  /// Future (the battle screen's phase banner, the "charms are down" warning)
  /// can still render both sides. Reset at the start of each artifact phase.
  ArtifactActivationRound lastArtifactActivations =
      const ArtifactActivationRound();

  // ── Public entry point ────────────────────────────────────────────────────

  /// Phase 0 (ARTIFACT_SYSTEM_PLAN.md §4): declare which loadout artifact, if
  /// any, the local player is spending this turn; exchange that declaration
  /// with the peer under commit-reveal; validate both; apply both.
  ///
  /// Idempotent per turn, memoized in [_artifactPhaseFuture]. [beginTurn]
  /// awaits this before exchanging the action commit, so every existing caller
  /// — tests, solo mode, anything that calls [runTurn] directly — gets the
  /// phase for free, in the right order, without changing.
  ///
  /// Ordering is still the entire mechanic (§2.2: spending something drops
  /// your own counter charms for the turn, and the opponent must see that
  /// while they can still change their cast) — this always resolves before
  /// either side's action commit, whoever triggers it. But as of 2026-07-31
  /// the UI no longer forces this **early**: a player can browse their hand
  /// and the board first, and long-pressing a loadout tile declares and
  /// fires this exchange right then (so its effect — mana, hand, the rod
  /// bonus — is visible before they pick a spell). A player who commits a
  /// spell without ever long-pressing anything gets the implicit no-op path
  /// this always supported: [beginTurn] awaits this the same way regardless.
  Future<ArtifactActivationRound> beginArtifactPhase() =>
      _artifactPhaseFuture ??= _artifactPhaseImpl();

  /// Memoizes this turn's dedicated artifact-entropy exchange (see
  /// [beginArtifactEntropy]), exactly like [_artifactPhaseFuture] does for
  /// the kind declaration. Cleared alongside it in [runTurn].
  Future<Uint8List>? _artifactEntropyFuture;

  /// Fires the turn's dedicated Phase-0 entropy exchange and, once it
  /// resolves, rolls the Rod of Wind movement passive for every avatar that
  /// holds one — amended 2026-07-31 (docs/ARTIFACT_SYSTEM_PLAN.md §2.8's
  /// original "rolled at Phase 6 for the following turn" timing, superseded
  /// at Soren's direction: activation effects should be usable the turn
  /// they're decided, so players can weigh them against their hand and the
  /// tactical situation before committing).
  ///
  /// This CANNOT reuse the turn's main joint entropy: that is deliberately
  /// revealed only after the action/move commits (B-5 look-ahead fix), but
  /// the rod bonus has to be knowable *before* this turn's own move commit
  /// to be usable this turn. So it draws from a separate, dedicated
  /// commit-reveal — [BattleTurnSession.refreshEntropy], the mid-resolution
  /// seam docs/BATTLE_PROTOCOL.md §3b already names as "the integration
  /// point for future interactive spells." Knowing this value early leaks
  /// nothing into the look-ahead-sensitive systems (spell retargeting, burn
  /// targeting, summon collision) because it is never used for any of them —
  /// only for a player's own rod roll and their own bookmark redraw (see
  /// [_applyArtifactActivation]'s bookmark case).
  ///
  /// Unconditional every turn — the rod passive isn't gated on a Phase-0
  /// declaration at all, so this can't wait for one. Memoized and safe to
  /// call any number of times; the UI calls it eagerly at the top of the
  /// turn (before the player has looked at their hand) so the roll is
  /// already settled by the time they're deciding anything.
  Future<Uint8List> beginArtifactEntropy() =>
      _artifactEntropyFuture ??= _artifactEntropyImpl();

  Future<Uint8List> _artifactEntropyImpl() async {
    final entropy = await session.refreshEntropy('artifact_phase');

    // Sorted so both devices walk the avatars in one order, matching
    // _findCounteringCharm / the Phase 4b melee round's convention.
    final avatars = List<WizardAvatar>.from(state.avatars)
      ..sort((a, b) => a.playerId.compareTo(b.playerId));
    for (final av in avatars) {
      if (!av.isAlive) continue;
      // One roll at min(rods × 10, 100)%, not one roll per rod (§3.2).
      final rods = av.rodOfSpreadingCount;
      if (rods == 0) continue;
      final chancePct = min(rods * _kRodMovementPctPerRod, 100);
      final roll = HashRng(
        _playerPhaseSeed(entropy, matchId, state.turnNumber, 0x0A, av.playerId),
      ).nextInt(100);
      // remainingTurns: 1 is genuinely one-shot now: this status is read by
      // this SAME turn's movement sizing (below, before Phase 6), then
      // ticked away by this same turn's Phase 6 — it does not carry into
      // next turn. That is correct: a fresh roll happens every turn.
      if (roll < chancePct) {
        _addStatus(av, StatusEffectId.rodMobility, {'speedDelta': 1}, 1);
      }
    }
    return entropy;
  }

  Future<ArtifactActivationRound> _artifactPhaseImpl() async {
    lastArtifactActivations = const ArtifactActivationRound();

    // Ensures the rod roll (and the entropy the bookmark redraw needs) has
    // happened before declarations are applied below, whether or not the UI
    // already started it eagerly.
    final artifactEntropy = await beginArtifactEntropy();

    final localAvatar = _localAvatar();
    final available = localAvatar.isAlive
        ? _activatableKinds(localAvatar)
        : const <AccoutrementKind>[];
    final localChoice = available.isEmpty
        ? null
        : await artifactActivationPicker(available);

    final nonce = _commitNonce(_kRevealNonceBytes);
    final bytes = _encodeActivation(localChoice);
    final commit = await Sha256()
        .hash(Uint8List.fromList([...bytes, ...nonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerCommit = await session.exchangeArtifactActivationCommit(commit);

    final myReveal = Uint8List.fromList([...nonce, ...bytes]);
    final peerReveal = await session.exchangeArtifactActivationReveal(myReveal);
    await _verifyReveal(peerReveal, peerCommit, 'artifact');
    final peerChoice = _decodeActivation(peerReveal, _kRevealNonceBytes);

    // Applied in sorted-playerId order, not local-first, so both devices walk
    // the same sequence — the same convention _findCounteringCharm and the
    // Phase 4b melee round use. It matters here for the same reason: gem
    // activation mutates avatar state that later validation reads.
    final peerId = _peerId();
    final declarations = <(WizardAvatar, AccoutrementKind?)>[
      (localAvatar, localChoice),
      if (peerId != null)
        if (_avatarById(peerId) case final peerAvatar?) (peerAvatar, peerChoice),
    ]..sort((a, b) => a.$1.playerId.compareTo(b.$1.playerId));

    for (final (avatar, declared) in declarations) {
      _applyArtifactActivation(
        avatar,
        _validateActivation(avatar, declared),
        artifactEntropy,
      );
    }

    final round = ArtifactActivationRound(
      local: localAvatar.declaredActivation,
      peer: peerId == null ? null : _avatarById(peerId)?.declaredActivation,
    );
    lastArtifactActivations = round;
    return round;
  }

  /// The artifact kinds [av] could legally declare right now: the
  /// [kActivatableArtifactKinds] they actually carry at least one of.
  List<AccoutrementKind> _activatableKinds(WizardAvatar av) => [
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
  AccoutrementKind? _validateActivation(
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
  /// their declaration failed [_validateActivation]. [artifactEntropy] is
  /// this turn's dedicated Phase-0 entropy (see [beginArtifactEntropy]),
  /// needed by the bookmark redraw.
  ///
  /// Not every activation resolves here: the Rod of Wind's *activation* is
  /// still realised at cast time by [_consumeRodOfSpreading] (single
  /// rod-consumption path; its movement *passive* is unrelated and rolled by
  /// [beginArtifactEntropy]). Mana gem and bookmark both resolve instantly —
  /// amended 2026-07-31, ARTIFACT_SYSTEM_PLAN.md §2.7's original "resolves at
  /// Phase 6, new hand next turn" is superseded, see [beginArtifactEntropy]'s
  /// doc comment for why.
  void _applyArtifactActivation(
    WizardAvatar av,
    AccoutrementKind? kind,
    Uint8List artifactEntropy,
  ) {
    if (kind == null) return;
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
        _applyManaGain(av, state.config.manaGemPoolPerGem);

      case AccoutrementKind.bookmark:
        // Burned AND redrawn immediately, both in this same Phase-0 step —
        // the new hand is available for THIS turn's own action choice, using
        // the dedicated artifact entropy rather than this turn's main
        // entropy (which doesn't exist yet this early in the turn). §2.7's
        // price is now just the permanent hand slot; the tempo cost is gone.
        _consumeAccoutrement(av, AccoutrementKind.bookmark);
        _redrawHand(
          av.playerId,
          artifactEntropy,
          handSize: av.bookmarkCount + 1,
          tag: 0x09,
        );

      case AccoutrementKind.rodOfSpreading:
        // Not consumed here: _consumeRodOfSpreading remains the single
        // consumption path, and it runs at cast time so a declared rod that
        // never gets spent (no cast, a fizzle, a counter) is not destroyed —
        // only the activation budget is wasted.
        break;

      case AccoutrementKind.counterCharm:
      case AccoutrementKind.absorptionRod:
        // Unreachable: _validateActivation rejects these kinds. Listed
        // exhaustively so adding an AccoutrementKind is a compile error here
        // rather than a silent no-op.
        break;
    }
  }

  /// Consumes one accoutrement of [kind] from [av], chosen by sorting the
  /// owner's accoutrements by id and taking the first match — the same
  /// deterministic tie-break [_findCounteringCharm] uses, and the reason the
  /// wire declaration can name a kind instead of an id. Returns false if [av]
  /// holds none.
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

  static Uint8List _encodeActivation(AccoutrementKind? kind) => kind == null
      ? Uint8List.fromList([0x00])
      : Uint8List.fromList([0x01, kind.index]);

  /// Decodes an activation declaration from [data] at [offset]. Anything
  /// malformed — truncated, unknown lead byte, out-of-range kind index —
  /// reads as "declared nothing", which [_validateActivation] would have
  /// reduced it to anyway.
  static AccoutrementKind? _decodeActivation(Uint8List data, int offset) {
    if (offset >= data.length || data[offset] != 0x01) return null;
    if (offset + 1 >= data.length) return null;
    final index = data[offset + 1];
    if (index >= AccoutrementKind.values.length) return null;
    return AccoutrementKind.values[index];
  }

  /// Begins the action-commit phase for [action] early, before movement is
  /// chosen: exchanges the split action commitment (§13b.2.1) with the peer,
  /// deducts mana, and runs the Divination scrying exchange (§13b.2).
  ///
  /// Idempotent per turn: calling this more than once (e.g. the UI calls it,
  /// then [runTurn] also checks) returns the same in-flight/completed Future
  /// rather than re-exchanging the action commit. [runTurn] clears the
  /// memoized state once it consumes it. If this call fails (bad reveal, bad
  /// scry opening) and the caller abandons the turn instead of proceeding to
  /// [runTurn], it must call [cancelPendingTurn] so the next [beginTurn] call
  /// starts clean rather than replaying the cached failure.
  ///
  /// Returns the opponent's revealed spell-target tile for this turn if an
  /// active [DivinationLink] (Air flavor) with the local player as caster
  /// resolved one; null if there's no active link, the peer's action has no
  /// plaintext target yet (Pass, or a delayed Mystery cast), or the opening
  /// failed verification.
  Future<HexCoord?> beginTurn(TurnAction action) =>
      _beginTurnFuture ??= _beginTurnImpl(action);

  /// Discards a pending or failed [beginTurn] call without proceeding to
  /// [runTurn]. Call this from the UI when abandoning a turn after
  /// [beginTurn] threw, so the next attempt (a freshly chosen action) starts
  /// clean instead of replaying the cached failure.
  void cancelPendingTurn() {
    _pendingAction = null;
    _pendingActionBytes = null;
    _pendingSaltA = null;
    _pendingSaltB = null;
    _pendingActionCommit = null;
    _pendingPeerActionCommit = null;
    _beginTurnFuture = null;
  }

  Future<HexCoord?> _beginTurnImpl(TurnAction action) async {
    // Phase 0 must settle before the action commit crosses the wire — that
    // ordering IS the mechanic (see [beginArtifactPhase]). Memoized, so a UI
    // that already ran it explicitly (the intended flow) pays nothing here.
    await beginArtifactPhase();

    final saltA = _commitNonce(_kRevealNonceBytes);
    final saltB = _commitNonce(_kRevealNonceBytes);
    final actionBytes = _encodeAction(action);
    final actionCommit = await _splitActionCommit(actionBytes, saltA, saltB);
    final peerActionCommit = await session.exchangeActionCommit(actionCommit);

    _pendingAction = action;
    _pendingActionBytes = actionBytes;
    _pendingSaltA = saltA;
    _pendingSaltB = saltB;
    _pendingActionCommit = actionCommit;
    _pendingPeerActionCommit = peerActionCommit;

    _deductManaForCommittedSpell(action);

    final openedTarget = await _exchangeScryOpenings(
      actionBytes: actionBytes,
      saltA: saltA,
      saltB: saltB,
      peerActionCommit: peerActionCommit,
    );

    // Reset before the exchange so a stale reveal never survives past the
    // turn it was granted for — this is what makes the UI's thumbnail row
    // clear at end of turn, with no separate expiry timer needed.
    revealedEnemyHand = null;
    revealedEnemyHand = await _exchangeSpellRevealOpenings();

    return openedTarget;
  }

  /// Deducts mana for [action] immediately after its commit is exchanged
  /// (covers regular and mystery spells) — moved here from the inline Phase 1
  /// body so [beginTurn] can call it as soon as the action is committed.
  void _deductManaForCommittedSpell(TurnAction action) {
    final committedSpell = switch (action) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };
    if (committedSpell == null) return;
    // DEV FLAG — free on both devices. See [_isProoflessBypass].
    if (_isProoflessBypass(committedSpell)) return;

    final av = _localAvatar();
    final castingEnhancements = _castingEnhancementsFor(action);
    // A missing recall is a BLANK, not an exemption — but only once the cast
    // is actually being charged for. Two reasons it cannot stay null here:
    //
    //  1. The wire cannot represent "no vocal component" separately from
    //     "nothing was heard" (_appendSorcererBytes encodes null as silent),
    //     so the peer will score it as a blank. Pricing it as unscored on this
    //     side is a state-hash divergence — which is exactly what
    //     vocal_recall_parity_test caught.
    //  2. It would be a self-reported opt-out: a player weak at recall could
    //     suppress the capture and pay base price forever. That is the shape
    //     §8.6 refuses when it rejects an ambiguity flag.
    //
    // previewSpellCost deliberately does NOT coalesce, because before the
    // incantation is spoken the honest quote is the base price (§4).
    final recall = switch (action) {
      SpellCastAction(:final recall) => recall ?? IncantationRecall.silent,
      MysterySpellCastAction(:final recall) => recall ?? IncantationRecall.silent,
      _ => null,
    };

    // Price it WITHOUT charging first, so a shortfall can fizzle-and-refund
    // rather than silently clamping to zero (VOCAL_RECALL_PLAN.md §4).
    final preview = _spellCostBreakdown(
      committedSpell,
      av,
      enhancements: castingEnhancements,
      recall: recall,
    );
    if (_fizzlesForMana(av, preview.cost)) {
      _markFizzledForMana(action);
      return; // mana refunded (never deducted); the turn is still spent
    }

    av.mana = (av.mana -
            _spellManaCost(
              committedSpell,
              av,
              enhancements: castingEnhancements,
              recall: recall,
            ))
        .clamp(0, _kMaxMana);
  }

  /// Whether a cast priced at [cost] fizzles for want of mana.
  ///
  /// Applies in BOTH modes. Sorcerer mode needs it because recall can INFLATE
  /// a cost after the player has already committed (VOCAL_RECALL_PLAN.md §4),
  /// but the response is right for wizard mode too, and it replaces what used
  /// to be a match forfeit there.
  ///
  /// Forfeiting was never really punishing a cheat — an unaffordable cast wins
  /// its caster nothing — it was avoiding a DESYNC. The caster's own deduction
  /// clamped at zero and played on while the peer stopped the match, and those
  /// two devices disagreeing is the actual failure. Fizzling fixes that at the
  /// source: both devices price the cast from the same certified inputs, so
  /// both reach the same verdict and stay in step. Ending someone's match over
  /// it is a wildly disproportionate response to a move that already
  /// accomplishes nothing.
  ///
  /// The UI still gates affordability ([canAffordSpell]); this is the backstop
  /// behind it, not a replacement for it.
  ///
  /// Known narrow edge, accepted in §4: refund-on-shortfall is a take-back.
  /// Deliberately blanking a cast you regret returns the mana at the cost of
  /// the turn. Only reachable when a spell already costs most of the pool.
  bool _fizzlesForMana(WizardAvatar caster, int cost) => cost > caster.mana;

  /// Records that [action] fizzled for want of mana, so resolution skips its
  /// effects. Both devices compute this from the same certified cost and the
  /// same avatar mana, so they always agree without transmitting anything.
  static void _markFizzledForMana(TurnAction action) {
    switch (action) {
      case SpellCastAction():
        action.fizzledForMana = true;
      case MysterySpellCastAction():
        action.fizzledForMana = true;
      default:
        break;
    }
  }

  /// DEV FLAG (kAllowProoflessSpells — lib/dev_flags.dart). Delete with it.
  ///
  /// True when [spell] is being waved through unverified: the flag is on and
  /// the spell carries no proof (a Spell Test Lab fabrication). Such a cast is
  /// **free on both devices**, and that is the only option that can't desync.
  ///
  /// The alternative — charging the wire price on both sides — is not
  /// available: the 0x01 action encoding carries only commitment, T, target
  /// and formula. It has no segmentCount/dotCount, because the verifying
  /// device normally reads those from the *proof's* public outputs. Strip the
  /// proof and the opponent has no geometry to price from, so it computes a
  /// base of 0 while the caster prices from its local asset —
  /// `avatar.mana` diverges and [_exchangeStateHash] forfeits at the end of
  /// that same turn. The bypass would have swapped a clean forfeit for the
  /// "state hash mismatch on turn N" freeze it was meant to avoid.
  ///
  /// Charging nothing costs little in practice: SpellTestLabScreen writes
  /// `manaCost: 0, segmentCount: 0, dotCount: 0`, so these spells already
  /// price at zero. What it does mean is that a test spell no longer consumes
  /// a pending `nextSpellCostDouble` / `chainSurcharge` (that consumption
  /// lives inside [_spellManaCost]) — to exercise those, make the *follow-up*
  /// cast a real proven spell. Chain building is unaffected: it happens in
  /// [_updateChainState] during resolution, which still runs.
  bool _isProoflessBypass(SpellAsset spell) =>
      allowProoflessSpells && spell.proofBytes.isEmpty;

  /// The [CastingEnhancements] a spell-like [action] casts under, or null if
  /// it isn't a cast.
  ///
  /// In sorcerer mode these derive from the vocal score.
  /// [CastingEnhancements.fromSorcererQuality] reads only the u8-quantised
  /// accessors, so the caster's copy (computed here from the not-yet-
  /// transmitted score) agrees byte-for-byte with the one the opponent
  /// computes from the wire-decoded copy — see the determinism note on
  /// VocalScore.pronunciationU8/volumeU8.
  ///
  /// isPotent/isVelocity/isEfficiency double as "caster owns this loadout";
  /// in sorcerer mode vocal quality gates whether that loadout is actually
  /// realised this cast, in wizard mode it always is (isPotent/isVelocity
  /// don't affect cost, but isEfficiency must still reach [_spellManaCost]
  /// for the discount to apply).
  ///
  /// Shared by every site that has to price a cast — the caster's own
  /// deduction and the opponent's — so the two cannot drift apart. Mana lands
  /// in the canonical state hash, so a drift here is a desync, not a rounding
  /// difference (see M4_findings 2026-07-29).
  CastingEnhancements? _castingEnhancementsFor(TurnAction action) =>
      switch (action) {
        SpellCastAction(
          :final isPotent,
          :final isVelocity,
          :final isEfficiency,
        ) =>
          CastingEnhancements(
            isPotent: isPotent,
            isVelocity: isVelocity,
            isEfficiency: isEfficiency,
            gameMode: _componentsGameMode,
          ),
        MysterySpellCastAction(
          :final isPotent,
          :final isVelocity,
        ) =>
          CastingEnhancements(
            isPotent: isPotent,
            isVelocity: isVelocity,
            gameMode: _componentsGameMode,
          ),
        _ => null,
      };

  /// Run one full turn, returning a non-null [WinCheckResult] if the match is over.
  ///
  /// [input] carries the local player's action and movement intent. Throws
  /// [StateError] on protocol failures (withheld reveal, state hash mismatch).
  Future<WinCheckResult?> runTurn(TurnInput input) async {
    state.turnNumber++;
    lastCastEvents = [];
    lastResolvedSpells = [];
    lastConveyorChainEvents = [];
    lastCounterCharmProcs = [];
    lastAvatarMoveEvents = [];
    lastWildMagicEvents = [];
    lastCertifiedBaseManaCosts = {};
    _wildMagicNonce = 0;
    _turbulentNonce = 0;

    // Turn-scoped map from commitmentHex → certified ParsedFormulas derived from
    // the peer's verified proof. Populated by _verifyPeerSpellCast; consumed by
    // _resolveActions → _applySpell. At most one entry per turn (2-player: one
    // peer action per turn; delayed fires don't re-verify). Cleared here so a
    // stale entry from a previous turn can never leak into the current one.
    //
    // NOTE: this guarantee is structural — it depends on _verifyPeerSpellCast
    // being called at most once per turn. 3+ players (experimentalMultiplayer)
    // would break it: multiple peers could each cast the same starting grid,
    // producing colliding keys. Use a composite key if multi-player is ever wired.
    final certifiedPeerFormulas = <String, List<ParsedFormula>>{};

    // Parallel map for summon-mode spells (design doc "Summons"): the
    // certified flat element sequence a peer's creature must be derived
    // from, keyed and cleared identically to [certifiedPeerFormulas].
    final certifiedPeerElementSequences = <String, List<BorderZone>>{};

    // Parallel map for wild magic (docs/WILD_MAGIC_PLAN.md §4.6): the triggers
    // derived from the peer's CERTIFIED proof public outputs, never from the
    // wire SpellAsset. Same lifecycle, same clearing, same 3+-player caveat as
    // [certifiedPeerFormulas] above.
    final certifiedPeerWildMagic = <String, List<WildMagicTrigger>>{};

    // ── Phase 1: Action commit ─────────────────────────────────────────────
    // Committed before entropy is revealed so a modified client cannot
    // pre-compute the resolution RNG and choose their action accordingly
    // (B-5 look-ahead fix). beginTurn() is memoized per turn (see its doc
    // comment), so this either reuses the UI's already-in-flight/completed
    // call (normal interactive path — beginTurn() was called as soon as the
    // local player locked in their action, so an active Airy Scrying Pool
    // link can inform their move) or starts it fresh (tests, solo mode,
    // anything that calls runTurn() directly).
    await beginTurn(input.action);
    assert(
      identical(_pendingAction, input.action),
      'runTurn(input) must be called with the same action passed to beginTurn()',
    );
    final actionBytes = _pendingActionBytes!;
    final actionSaltA = _pendingSaltA!;
    final actionSaltB = _pendingSaltB!;
    final actionCommit = _pendingActionCommit!;
    final peerActionCommit = _pendingPeerActionCommit!;
    _pendingAction = null;
    _pendingActionBytes = null;
    _pendingSaltA = null;
    _pendingSaltB = null;
    _pendingActionCommit = null;
    _pendingPeerActionCommit = null;
    _beginTurnFuture = null;
    // Phase 0 already ran (beginTurn awaits it). Release the memo so the NEXT
    // turn opens a fresh exchange; the declarations themselves live on the
    // avatars until the end of this turn.
    _artifactPhaseFuture = null;
    _artifactEntropyFuture = null;

    // ── Phase 2: Movement commit-reveal ───────────────────────────────────
    // Also committed before entropy is known (same look-ahead protection as
    // Phase 1 — movement decisions should not be influenced by RNG foreknowledge).
    final preMovPos = Map<String, HexCoord>.fromEntries(
      state.avatars.map((av) => MapEntry(av.playerId, av.position)),
    );
    // Spell range as it stood when this turn's actions were committed, for the
    // range check in _resolveActions. Targeting is judged as of when the cast
    // was completed (ruling 2026-08-06), and Phase 1 is when it was: nothing
    // between that commit and this line can change a range, since statuses
    // tick at end of turn and spell effects do not resolve until Phase 4.
    // Reading effectiveSpellRange at resolution time instead would let an
    // Earthen Inertia resolving EARLIER in the same action phase clip a cast
    // that was legal when its caster chose it.
    final preMovRange = Map<String, int>.fromEntries(
      state.avatars.map((av) => MapEntry(av.playerId, av.effectiveSpellRange)),
    );

    // isDashing/meditateInMove ride along with the movement commit-reveal
    // (not the action commit-reveal) — see this file's header comment on
    // why: the action reveal is deliberately deferred until after movement
    // resolves, so Dash's same-turn speed boost has to travel some other
    // way to be known before avatar movement resolves.
    final iAmDashing = input.action is DashAction;
    final localPath = input.meditateInMove
        ? const <HexCoord>[]
        : input.movePath;
    final moveNonce = _commitNonce(_kRevealNonceBytes);
    final moveBytes = _encodeMovePayload(
      isDashing: iAmDashing,
      meditateInMove: input.meditateInMove,
      path: localPath,
    );
    final moveCommit = await Sha256()
        .hash(Uint8List.fromList([...moveBytes, ...moveNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerMoveCommit = await session.exchangeMoveCommit(moveCommit);

    // Reveal.
    final myMoveReveal = Uint8List.fromList([...moveNonce, ...moveBytes]);
    final peerMoveReveal = await session.exchangeMoveReveal(myMoveReveal);
    await _verifyReveal(peerMoveReveal, peerMoveCommit, 'movement');

    final peerMovePayload = _decodeMovePayload(
      peerMoveReveal,
      _kRevealNonceBytes,
    );
    final peerPath = peerMovePayload.path;
    final peerId = _peerId();

    // ignore: use_null_aware_elements
    final movePaths = {
      localPlayerId: localPath,
      if (peerId != null) peerId: peerPath,
    };
    final speeds = {
      for (final av in state.avatars)
        av.playerId:
            av.effectiveMoveSpeed *
            (((av.playerId == localPlayerId && iAmDashing) ||
                    (peerId != null &&
                        av.playerId == peerId &&
                        peerMovePayload.isDashing))
                ? 2
                : 1),
    };

    // Move-phase Meditate: forgo movement (path already forced empty above/
    // in the decoder) for +25 mana, independent of a main-phase Meditate.
    // The mana is NOT granted here — see [_applyMoveMeditations], called from
    // Phase 5 once both casts have been charged. Only the declaration is
    // captured at this point.
    final meditators = <String>[
      if (input.meditateInMove) localPlayerId,
      if (peerId != null && peerMovePayload.meditateInMove) peerId,
    ]..sort();

    // ── Phase 3: Entropy reveal ───────────────────────────────────────────
    // All player decisions for this turn are committed. Reveal joint entropy
    // now; it seeds all resolution RNG in phases 4–6.
    final entropy = await _resolveEntropy();
    // Stashed for the WildMagicHooks / ForcedCastHost callbacks, which the
    // applicator invokes without an entropy argument.
    _turnEntropy = entropy;

    // Opening hand/deck deal (SPELL_DRAW_WIRING_PLAN.md §3) — once only, the
    // first time localChapterSpells has resolved (in practice, turn 1).
    _dealOpeningHandsIfNeeded(entropy);

    // Movement resolution (contested-tile collision, then the actual walk)
    // is deferred to here rather than done inline in Phase 2: Phase 2 only
    // needs to exchange the *declared* paths fairly before entropy is known
    // (B-5 look-ahead protection). Resolving the walk needs a seeded RNG --
    // ConveyorTile loop-exit randomness (tile_entry_resolver.dart) -- so it
    // waits for entropy like every other RNG-driven phase.
    final walked = _resolution.resolveAvatarMovement(
      movePaths: movePaths,
      speeds: speeds,
      rng: HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x02)),
      moveEvents: lastAvatarMoveEvents,
      conveyorChainEvents: lastConveyorChainEvents,
    );

    // Walking into an enemy illusion's tile-neighbourhood dispels it on
    // sight (Earthen Scrying Pool) — resolved before the tokens are played
    // back, so the illusion is already gone in the state the animation and
    // everything downstream of it read.
    _dispelIllusionsNearScryers();

    // Walk the tokens now, while this is the only thing that has changed —
    // no frame gets a chance to render the new positions first, because
    // resolveAvatarMovement and this call sit in the same synchronous run.
    // See [MovementPlayback]. Everything below (cloud drift, the melee prompt,
    // spell resolution) reads positions this playback has already shown.
    final playMovement = onMovementResolved;
    if (playMovement != null) {
      await playMovement(
        List<AvatarMoveEvent>.unmodifiable(lastAvatarMoveEvents),
      );
    }

    // ── Phase 4: Cloud movement ─────────────────────────────────────────────
    // Air-flavor Clouds only; creature Summons AI (this used to run here
    // too) now runs as Phase 5b, after Action resolution — see this file's
    // header comment for why.
    onPhase?.call(TurnPhase.summons);
    _resolution.moveClouds();

    // ── Phase 4b: Melee commit-reveal ──────────────────────────────────────
    // Post-movement, post-cloud-move: final positions are known for
    // everything except this turn's creature Summons AI (Phase 5b runs
    // later now), so this can ask the local player which adjacent hostile
    // tile (if any) to melee. Independent of the main-phase action — a
    // player may cast a spell AND melee the same turn. Only prompted when a
    // target actually exists; everyone else implicitly passes. No
    // look-ahead concern (unlike Phase 1/2): entropy is already public by
    // this point.
    final localMeleeCandidates = _meleeCandidates(_localAvatar());
    final localMeleeTarget = localMeleeCandidates.isEmpty
        ? null
        : await meleeTargetPicker(localMeleeCandidates);
    final meleeNonce = _commitNonce(_kRevealNonceBytes);
    final meleeBytes = _encodeOptionalTarget(localMeleeTarget);
    final meleeCommit = await Sha256()
        .hash(Uint8List.fromList([...meleeBytes, ...meleeNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerMeleeCommit = await session.exchangeMeleeCommit(meleeCommit);

    final myMeleeReveal = Uint8List.fromList([...meleeNonce, ...meleeBytes]);
    final peerMeleeReveal = await session.exchangeMeleeReveal(myMeleeReveal);
    await _verifyReveal(peerMeleeReveal, peerMeleeCommit, 'melee');
    final peerMeleeTarget = _decodeOptionalTarget(
      peerMeleeReveal,
      _kRevealNonceBytes,
    );

    // Resolved at the very start of the resolution phase, before any spell
    // — see this file's header comment.
    final meleeRng = HashRng(
      _phaseSeed(entropy, matchId, state.turnNumber, 0x04),
    );
    // Sorted by playerId, NOT local-first. Both haymakers draw from the same
    // [meleeRng] stream (illusion redirect, and the counter-charm melee proc),
    // so applying them in device-relative order would have device A run
    // A-then-B while device B runs B-then-A — the two would consume the shared
    // stream in different orders and diverge. Same fixed-order convention as
    // [_findCounteringCharm]. See docs/ARTIFACT_SYSTEM_PLAN.md §6.1.
    final meleeApplications = <(WizardAvatar, HexCoord)>[
      if (localMeleeTarget != null) (_localAvatar(), localMeleeTarget),
      if (peerId != null && peerMeleeTarget != null)
        if (_avatarById(peerId) case final peerAvatarForMelee?)
          (peerAvatarForMelee, peerMeleeTarget),
    ]..sort((a, b) => a.$1.playerId.compareTo(b.$1.playerId));
    lastMeleeAttackEvents = [];
    for (final (actor, target) in meleeApplications) {
      // Emitted on the same adjacency test _applyHaymaker itself gates on, so
      // a punch thrown at a tile the actor is no longer next to (it lost a
      // contest, it was pushed) is neither applied nor animated. A haymaker
      // that lands on an illusion decoy still animates: the swing happened,
      // and the reveal that it hit a decoy is the decoy's job to tell.
      if (_isAdjacent(actor.position, target)) {
        lastMeleeAttackEvents.add(
          AttackEvent(from: actor.position, to: target, range: 1),
        );
      }
      final hit = _applyHaymaker(actor, target, walked, meleeRng);
      _applyCounterCharmProc(actor, hit, meleeRng);
    }
    // Played back after both haymakers have been applied, so simultaneous
    // punches are seen as simultaneous — the same "one shared timeline" rule
    // the movement playback follows.
    final playMelee = onMeleeResolved;
    if (playMelee != null && lastMeleeAttackEvents.isNotEmpty) {
      await playMelee(List<AttackEvent>.unmodifiable(lastMeleeAttackEvents));
    }

    onPhase?.call(TurnPhase.actionResolve);

    // ── Phase 5: Delayed spell reveals + Action reveal + resolution ───────
    // Both players simultaneously announce any pending delayed spells firing
    // this turn (independent of, and before, the current-turn action reveal).
    final localDelayedPayload = _buildDelayedRevealPayload(
      input.delayedSpellReveals,
    );
    final peerDelayedPayload = await session.exchangeDelayedSpellReveals(
      localDelayedPayload,
    );

    final myActionReveal = Uint8List.fromList([
      ...actionSaltA,
      ...actionSaltB,
      ...actionBytes,
    ]);
    final peerActionReveal = await session.exchangeActionReveal(myActionReveal);
    await _verifyActionReveal(peerActionReveal, peerActionCommit);

    final (:action, :merkleProof) = _decodeAction(
      peerActionReveal.sublist(_kRevealNonceBytes * 2),
      withProof: verifyProof != null,
      isVocalComponents: isVocalComponents,
    );

    // Option 3: verify the peer's spell proof and Merkle book membership before
    // resolving. Forfeits the match on any failure. Populates certifiedPeerFormulas
    // with the trajectory-derived formulas for use in _resolveActions.
    if (action is SpellCastAction || action is MysterySpellCastAction) {
      await _verifyPeerSpellCast(
        action,
        merkleProof,
        certifiedPeerFormulas,
        certifiedPeerElementSequences,
        certifiedPeerWildMagic,
      );
    }

    // Move-phase Meditate pays out HERE, not back at Phase 2 where it was
    // declared — the one point in the turn where both players' casts have
    // been charged on both devices. See [_applyMoveMeditations].
    _applyMoveMeditations(meditators);

    // Hand/deck refill (SPELL_DRAW_WIRING_PLAN.md §4) — a spell leaves the
    // caster's hand the instant its cast is committed this turn, regardless
    // of whether it resolves immediately or is held for a Mystery delay
    // (matches where the in-hand check above already validated it, and
    // where _appendSpellProofTail/proveMembership prove "which position").
    // Deliberately uses the ORIGINAL action/input.action (not myAction/
    // peerAction below) since those get mystery-converted, losing this
    // distinction for delayed casts, while .spell survives either way.
    final localSpell = switch (input.action) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };
    final localHandIndex = switch (input.action) {
      SpellCastAction(:final handIndex) => handIndex,
      MysterySpellCastAction(:final handIndex) => handIndex,
      _ => null,
    };
    if (localSpell != null) {
      final localPosition = _localCastPosition(localSpell, localHandIndex);
      if (localPosition != null) {
        _advanceDrawState(localPlayerId, localPosition, entropy);
      }
    }
    if ((action is SpellCastAction || action is MysterySpellCastAction) &&
        merkleProof != null &&
        peerId != null) {
      _advanceDrawState(peerId, merkleProof.leafIndex, entropy);
      final peerSpell = switch (action) {
        SpellCastAction(:final spell) => spell,
        MysterySpellCastAction(:final spell) => spell,
        _ => null,
      };
      if (peerSpell != null) {
        (_revealedCastContents[peerId] ??= {})[merkleProof.leafIndex] = peerSpell;
      }
    }

    // For immediate mystery spells (delay=0), verify the commitment and
    // convert to SpellCastAction. Fizzles to Pass on hash mismatch.
    final myAction = await _verifyMysteryAction(input.action);
    final peerAction = await _verifyMysteryAction(action);

    // Verify and collect delayed spell fires; removes matched entries from
    // state.pendingDelayedSpells so the state hash reflects the firings.
    final localFires = await _verifyAndCollectDelayedFires(
      localDelayedPayload,
      localPlayerId,
    );
    final peerFires = await _verifyAndCollectDelayedFires(
      peerDelayedPayload,
      peerId ?? '',
    );

    // Action phase seed folds in both action commits (XOR is order-independent
    // so both clients derive the same seed). Defence-in-depth: the seed is
    // bound to exactly the actions taken this turn even if entropy were somehow
    // exposed before the commit.
    final actionRng = HashRng(
      _actionPhaseSeed(
        entropy,
        matchId,
        actionCommit,
        peerActionCommit,
        state.turnNumber,
      ),
    );
    await _resolveActions(
      myAction,
      peerAction,
      preMovPos,
      preMovRange,
      actionRng,
      entropy,
      traversedPaths: walked,
      delayedFires: [...localFires, ...peerFires],
      certifiedPeerFormulas: certifiedPeerFormulas,
      certifiedPeerElementSequences: certifiedPeerElementSequences,
      certifiedPeerWildMagic: certifiedPeerWildMagic,
    );
    // Spells conjure illusions, and knockback/teleport shuffle who stands
    // where — either can put an enemy illusion next to a scryer.
    _dispelIllusionsNearScryers();

    // ── Phase 5b: Summons act ───────────────────────────────────────────────
    // Every spell for the turn (including any Potent summon's immediate
    // bonus action, above) has now resolved. Both clients run the same
    // deterministic AI for all living minions here, in creation order —
    // this turn's entropy is already public by this point (Phase 3), so
    // unlike the old pre-resolution placement there's nothing left for
    // either player's Phase 1 action commit to look ahead to.
    final summonsRng = HashRng(
      _phaseSeed(entropy, matchId, state.turnNumber, 0x01),
    );
    await _resolveSummons(summonsRng);

    // ── Phase 5.5: Post-resolution free-move (barrier burst) ──────────────
    // A barrier destroyed by damage this turn (a "burst" — not one that
    // merely expired from old age; see WizardAvatar.tickBarriers for that
    // separate, still-unwired path) with freeMoveOnCollapse grants its
    // bearer a single reactive step, once, after every spell for the turn
    // has fully resolved. This is deliberately *not* interleaved mid-
    // resolution: an interactive version that could let the bearer dodge a
    // second spell landing on the same tile later in the same turn would
    // need a new mid-loop suspension point (and a network round trip whose
    // *count* varies with how many barriers burst, unlike the two fixed
    // rounds here — a variable-length frame sequence is a much bigger change
    // than a second fixed one) for a niche payoff. Not worth it unless
    // playtesting says otherwise. This window still lets the bearer step off
    // hazardous terrain (FloorIsLava, clouds, fire-barrier aura) before
    // Phase 6's position-dependent damage applies; Phase 6.5 below catches
    // barriers that burst on that damage.
    //
    // Shape mirrors the Phase 4b melee commit-reveal exactly. Only prompted
    // when the local avatar actually earned a burst and has a legal tile to
    // step to; everyone else implicitly declines with no prompt shown.
    //
    // The same window carries a Boost (Air-Air Speed Manipulation, Fire or
    // Water flavor): a paid run of up to several tiles, priced by
    // [boostMoveCost]. The two stack — see [freeMoveGrantFor]. The RNG seed
    // resolves terrain crossed by the run (ice slides, closed conveyor loops)
    // and is distinct per window so the two rounds never roll alike.
    await _runFreeMoveRound(
      peerId,
      HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x05)),
    );

    // ── Phase 6: End of turn ──────────────────────────────────────────────
    final eotRng = HashRng(
      _phaseSeed(entropy, matchId, state.turnNumber, 0x03),
    );
    // The one phase with no network exchange and no host callback inside it,
    // so it lives behind the deterministic-resolution seam rather than in this
    // class. See deterministic_resolution.dart for what the seam is for.
    _resolution.resolveEndOfTurn(
      preMovPos: preMovPos,
      rng: eotRng,
      conveyorChainEvents: lastConveyorChainEvents,
      wildMagicEvents: lastWildMagicEvents,
    );

    // ── Phase 6.5: Second free-move window ────────────────────────────────
    // Phase 6 deals damage too — fire-barrier aura, FloorIsLava, conveyor
    // collisions, cloud damage-per-turn, haymaker DoT — so it can burst a
    // barrier *after* Phase 5.5's window has already closed. Without this
    // round that grant is either silently lost or (worse) leaks into the
    // next turn's Phase 5.5, prompting a step the bearer didn't earn.
    //
    // Costs one more commit-reveal pair per turn. That's the same fixed cost
    // Phase 5.5 already pays unconditionally (both rounds run every turn and
    // encode "no move" when nobody qualifies), and the sorcerer-mode budget
    // in SORCERER_REALTIME_PLAN.md §1.1 puts a 6-player mesh two-plus orders
    // of magnitude inside its bandwidth headroom — bytes are not the
    // constraint here. §1.2's real constraint is lockstep barrier stalls, and
    // this adds one more sync point per turn, which is the number to watch if
    // turn latency ever becomes a complaint.
    //
    // Boosts are already spent or cleared by Phase 5.5, so in practice this
    // round only ever carries a burst step — but it re-derives the grant from
    // state rather than assuming that, because a Phase 6 effect that grants a
    // boost later would otherwise silently lose it.
    await _runFreeMoveRound(
      peerId,
      HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x06)),
    );

    await _exchangeStateHash();

    // Phase-0 declarations are turn-scoped. Cleared AFTER the state-hash
    // exchange, never before: the flag gates counter-charm firing at Phase 5,
    // so it is part of the state both devices must agree on for this turn.
    for (final av in state.avatars) {
      av.declaredActivation = null;
    }

    // Last chance for a Phoenix save before the match can be declared over —
    // a wizard who dies to end-of-turn damage must still rise.
    _applyPhoenixSaves();

    final result = state.checkWinCondition();
    return result.isOver ? result : null;
  }

  // ── Phase-seed helpers ────────────────────────────────────────────────────

  /// SHA-256(entropy[32] ‖ matchId[N]? ‖ uint32BE(turnNumber)[4] ‖ phaseTag[1])
  ///
  /// matchId is included when non-null so identical entropy+turn+phase in two
  /// different matches can't produce the same HashRng stream.
  static Uint8List _phaseSeed(
    Uint8List entropy,
    Uint8List? matchId,
    int turnNumber,
    int tag,
  ) {
    final buf = BytesBuilder(copy: false);
    buf.add(entropy);
    if (matchId != null) buf.add(matchId);
    buf
      ..addByte((turnNumber >> 24) & 0xFF)
      ..addByte((turnNumber >> 16) & 0xFF)
      ..addByte((turnNumber >> 8) & 0xFF)
      ..addByte(turnNumber & 0xFF)
      ..addByte(tag);
    return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
  }

  /// Per-player phase seed: [_phaseSeed] with [playerId] folded into the
  /// preimage, so two players' draws in the same turn/phase never share a
  /// HashRng stream (SPELL_DRAW_ENTROPY_PLAN.md §9's "append to preimage"
  /// recommendation for per-player stream separation — this codebase has no
  /// numeric player-index convention, so [playerId] itself is the domain
  /// separator). Used for SpellDraw/DrawSchedule opening deals (tag 0x07),
  /// refill draws (tag 0x05), FuelTransmutation wither/reactivate draws
  /// (tag 0x06), and bookmark-driven hand slot add/remove (tag 0x08, see
  /// [_reconcileHandSize]) — see SPELL_DRAW_WIRING_PLAN.md §§4, 9.
  static Uint8List _playerPhaseSeed(
    Uint8List entropy,
    Uint8List? matchId,
    int turnNumber,
    int tag,
    String playerId, [
    int drawNonce = 0,
  ]) {
    final buf = BytesBuilder(copy: false);
    buf.add(_phaseSeed(entropy, matchId, turnNumber, tag));
    buf.add(utf8.encode(playerId));
    buf
      ..addByte((drawNonce >> 24) & 0xFF)
      ..addByte((drawNonce >> 16) & 0xFF)
      ..addByte((drawNonce >> 8) & 0xFF)
      ..addByte(drawNonce & 0xFF);
    return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
  }

  /// Action phase seed: folds in XOR of both action commits.
  /// XOR is commutative so both clients compute the same value regardless of
  /// which is local vs peer.
  /// SHA-256(entropy[32] ‖ matchId[N]? ‖ (myCommit XOR peerCommit)[32] ‖ uint32BE(turn)[4] ‖ 0x02[1])
  static Uint8List _actionPhaseSeed(
    Uint8List entropy,
    Uint8List? matchId,
    Uint8List myCommit,
    Uint8List peerCommit,
    int turnNumber,
  ) {
    final xor = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      xor[i] = myCommit[i] ^ peerCommit[i];
    }
    final buf = BytesBuilder(copy: false);
    buf.add(entropy);
    if (matchId != null) buf.add(matchId);
    buf.add(xor);
    buf
      ..addByte((turnNumber >> 24) & 0xFF)
      ..addByte((turnNumber >> 16) & 0xFF)
      ..addByte((turnNumber >> 8) & 0xFF)
      ..addByte(turnNumber & 0xFF)
      ..addByte(0x02);
    return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
  }

  // ── Phase 5b: Summons act ─────────────────────────────────────────────────

  /// Pure playback. The creature AI, the movement, the blows and the deaths
  /// are all decided by [DeterministicResolution.resolveSummonActions] before
  /// this method shows anybody anything, and the aftermath is decided by
  /// [DeterministicResolution.resolveSummonAftermath] after. Nothing between
  /// those two calls can influence either — the host callback in the middle
  /// only animates an outcome that already happened.
  Future<void> _resolveSummons(HashRng rng) async {
    final outcome = _resolution.resolveSummonActions(
      rng: rng,
      conveyorChainEvents: lastConveyorChainEvents,
    );
    // Replaces (rather than clears-and-fills) the two UI lists, exactly as the
    // old in-place `= []` did: whatever a Potent summon's Phase-5 bonus action
    // appended is discarded here either way — that is a real (pre-existing,
    // presentation-only) bug, recorded as M4.17 in docs/M4_findings.md and
    // deliberately preserved rather than fixed inside a no-behaviour-change
    // extraction.
    lastMinionMoveEvents = outcome.moveEvents;
    lastMinionAttackEvents = outcome.attackEvents;
    // Walk the tokens before anything reaps or dispels: a creature that lunged
    // in and died to a Molten Carapace should be seen making the lunge, not
    // vanish from the tile it never visibly left. Same await-the-UI contract
    // as the avatar walk in Phase 3 — see [SummonMovementPlayback].
    final playSummonMovement = onSummonMovementResolved;
    if (playSummonMovement != null) {
      await playSummonMovement(
        List<MinionMoveEvent>.unmodifiable(lastMinionMoveEvents),
        List<AttackEvent>.unmodifiable(lastMinionAttackEvents),
      );
    }
    _resolution.resolveSummonAftermath(
      rng: rng,
      wildMagicEvents: lastWildMagicEvents,
    );
  }

  // Cloud drift moved behind the deterministic seam — see
  // [DeterministicResolution.moveClouds]. This forwarder stays because
  // [_resolveActions] steps a single newly-born cloud from inside Phase 5.

  /// See [DeterministicResolution.moveCloud].
  void _moveCloud(CloudObject cloud) => _resolution.moveCloud(cloud);

  // ── Personality AI (design doc "Personalities") ───────────────────────────
  //
  // The creature AI, its movement and its attacks moved behind the
  // deterministic seam — see [DeterministicResolution.creatureTurn] and the
  // Phase 5b section of deterministic_resolution.dart. This forwarder stays
  // because a Potent summon acts once immediately at cast time, from inside
  // Phase 5's [_castSummon], and that call site keeps this class's event
  // lists as its sinks.

  /// See [DeterministicResolution.creatureTurn].
  void _creatureTurn(Minion creature, HashRng rng) => _resolution.creatureTurn(
    creature,
    rng,
    moveEvents: lastMinionMoveEvents,
    attackEvents: lastMinionAttackEvents,
    conveyorChainEvents: lastConveyorChainEvents,
  );

  /// See [DeterministicResolution.reapDead].
  void _reapDead(HashRng rng) => _resolution.reapDead(rng);

  // ── Phase 3 helpers: movement ─────────────────────────────────────────────
  //
  // Avatar movement itself moved behind the deterministic seam — see
  // [DeterministicResolution.resolveAvatarMovement] and the Phase 3 section of
  // deterministic_resolution.dart. This forwarder stays because the free-move
  // window (Phase 5.5/6.5) walks one avatar at a time through the same
  // terrain-aware walker, with this class's conveyor-event list as its sink.

  /// See [DeterministicResolution.walkAvatar].
  ({List<HexCoord> path, int spent}) _walkAvatar(
    WizardAvatar av,
    HexCoord origin,
    List<HexCoord> declaredPath,
    int budget,
    HashRng rng, {
    bool Function(HexCoord)? blocked,
  }) => _resolution.walkAvatar(
    av,
    origin,
    declaredPath,
    budget,
    rng,
    conveyorChainEvents: lastConveyorChainEvents,
    blocked: blocked,
  );

  // ── Phase 4: Action resolution ────────────────────────────────────────────

  /// Async because a wild-magic Spontaneous Combustion fires a forced
  /// reveal-and-cast mid-resolution, which needs a protocol round trip for the
  /// peer's private hand (docs/WILD_MAGIC_PLAN.md §9.5). Every other path
  /// through here is still synchronous.
  Future<void> _resolveActions(
    TurnAction myAction,
    TurnAction peerAction,
    Map<String, HexCoord> preMovPos,
    Map<String, int> preMovRange,
    HashRng rng,
    Uint8List entropy, {
    Map<String, List<HexCoord>> traversedPaths = const {},
    List<(WizardAvatar, SpellCastAction, CertifiedCast?)> delayedFires =
        const [],
    Map<String, List<ParsedFormula>> certifiedPeerFormulas = const {},
    Map<String, List<BorderZone>> certifiedPeerElementSequences = const {},
    Map<String, List<WildMagicTrigger>> certifiedPeerWildMagic = const {},
  }) async {
    final peerId = _peerId();
    final peerAvatar = peerId != null ? _avatarById(peerId) : null;

    // Pair each current-turn action with its actor, then fold in delayed fires
    // as SpellCastActions so they join the same resolution order.
    final pairs = <(WizardAvatar, TurnAction)>[
      (_localAvatar(), myAction),
      if (peerAvatar != null) (peerAvatar, peerAction),
      ...delayedFires.map((f) => (f.$1, f.$2 as TurnAction)),
    ];

    // A delayed fire carries its own certified semantics, captured on the turn
    // it was declared (TODO(B-1) closure — see [PendingDelayedSpell.certified]).
    // Keyed by object IDENTITY, not by commitmentHex: each fire builds a fresh
    // SpellCastAction, so identity is unique, while commitmentHex is grid-only
    // and a same-grid current-turn cast would collide with it.
    final delayedCertified = Map<TurnAction, CertifiedCast>.identity();
    for (final f in delayedFires) {
      if (f.$3 != null) delayedCertified[f.$2] = f.$3!;
    }

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
    // rewritten by _verifyMysteryAction upstream), so it stashes a
    // PendingDelayedSpell rather than resolving, and must not count as
    // "another cast" this turn. Delayed spells actually firing now arrive as
    // SpellCastActions via [delayedFires] and do count.
    final casters = pairs
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
    // equal, and since `pairs` is built local-actor-first the two clients
    // would then stably sort them into different orders. Nothing a Pass/
    // Dash/Meditate does is order-sensitive today, so that never actually
    // diverged canonical state — but it's a lockstep landmine, and this
    // change makes ties strictly more likely by collapsing groups.
    final sorted = List.of(pairs)
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
          _applyManaGain(actor, _kMeditateManaGain);
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
          // consumer below (counter-charm matching, _applySpell, mana, chain
          // state) so they can never disagree about what the proof said.
          //
          // A delayed fire brings its own, captured on its declaration turn;
          // a current-turn peer cast reads what _verifyPeerSpellCast derived
          // moments ago. The delayed entry is checked FIRST: its commitmentHex
          // may well collide with a same-grid cast this turn, and the pending
          // record is the one that belongs to this action.
          final delayedCert = delayedCertified[action];
          final certFormulas = delayedCert?.formulas ??
              certifiedPeerFormulas[spell.commitmentHex];
          final certElementSequence = delayedCert?.elementSequence ??
              certifiedPeerElementSequences[spell.commitmentHex];
          final certWildMagic = delayedCert?.wildMagic ??
              certifiedPeerWildMagic[spell.commitmentHex];
          // Recall NEVER gates the loadout enhancement and never fizzles a
          // cast (VOCAL_RECALL_PLAN.md §4: getting words wrong costs mana,
          // full stop). The only fizzle left is a cast whose recall-inflated
          // cost outran the caster's pool, and that is decided at commit time
          // on both devices — see [SpellCastAction.fizzledForMana].
          final enhancements = CastingEnhancements(
            isPotent: isPotent,
            isVelocity: isVelocity,
            isEfficiency: isEfficiency,
            gameMode: _componentsGameMode,
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
            final resolvedTarget = _turbulentTarget(actor, targetHex, entropy);
            // The orb still flies for a countered cast (it visibly happened
            // and drew a counter, unlike a fizzle) — emitted once here for
            // both outcomes below, then the two diverge.
            final affinity = primaryFormulaAffinity(spell.formula);
            if (affinity != null) {
              lastCastEvents.add(
                SpellCastEvent(
                  casterId: actor.playerId,
                  fromHex: action.delayedOriginHex ?? actor.position,
                  toHex: resolvedTarget,
                  affinity: affinity,
                ),
              );
            }
            // Counter charms match the cast's certified element sequence, so
            // the trigger test reads exactly what _applySpell would resolve:
            // the certified sequence for a verified peer cast or a delayed
            // fire, the local wire formula for our own spell (the same
            // fallback every other consumer of this data uses — see
            // _applySpell's certFormulas).
            final castSequence = certElementSequence ?? _elementSequence(spell);
            final counterHit = _findCounteringCharm(castSequence);
            // Whether the charm swallowed the WHOLE cast. Measured in
            // formulas for an incantation and in elements for a summon,
            // because a summon reads residuals too (CreatureSpec.fromElements
            // counts every activation, _parsedFormulas drops the trailing 1–2).
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
              // countered cast") for free, since _applySpell — the only place
              // wild magic fires — is never reached. A PARTIAL counter is a
              // cast that really happened, so it does resolve and its wild
              // magic does fire; see the else branch.
              lastResolvedSpells.add(
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
                _playerPhaseSeed(
                  entropy,
                  matchId,
                  state.turnNumber,
                  0x06,
                  actor.playerId,
                  _consumeDrawNonce(actor.playerId),
                ),
              );
              final summoned = await _applySpell(
                actor,
                spell,
                resolvedTarget,
                enhancements,
                rng,
                entropy,
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
                _redrawHand(actor.playerId, entropy);
              }
              // A cloud born this turn would otherwise sit dead-still until
              // *next* turn's Phase 4 (_moveClouds already ran, ahead of this
              // spell resolution, before the cloud existed) — give it its
              // Summons-phase move right now, same turn it's summoned, so it's
              // never visibly stationary. See _moveCloud's doc comment.
              for (final c in state.clouds) {
                if (!cloudsBefore.contains(c.id)) _moveCloud(c);
              }
              // Bookmark accoutrements gained/lost this resolution (e.g.
              // ArtifactsInteractionEffect Air/Fire, FuelTransmutationEffect
              // Fire/Air) resize the affected avatar's hand immediately —
              // handSize == bookmarkCount + 1 (see _reconcileHandSize).
              for (final av in state.avatars) {
                final before = bookmarksBefore[av.playerId]!;
                if (av.bookmarkCount != before) {
                  _reconcileHandSize(av.playerId, before, av.bookmarkCount, entropy);
                }
              }
              lastResolvedSpells.add(
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
          // Immediate mystery spells were converted to SpellCastAction by
          // _verifyMysteryAction before reaching here. A MysterySpellCastAction
          // at this point is always the non-immediate (delayed) variant.
          //
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
          // own proof, the verifier reuses what _verifyPeerSpellCast already
          // derived from the VERIFIED outputs. Branching on ownership rather
          // than on map presence matters — the maps are keyed by commitmentHex,
          // and the commitment is grid-only (CLAUDE.md invariant 2), so a peer
          // casting the same grid at a different T this turn would otherwise
          // hand the local caster the peer's certified data.
          final certifiedDeclaration = actor.playerId == localPlayerId
              ? _certifiedFromProofBytes(spell)
              : _certifiedPeerCast(
                    spell,
                    certifiedPeerFormulas,
                    certifiedPeerElementSequences,
                    certifiedPeerWildMagic,
                  ) ??
                  // Verification not wired up (solo/dev): parse unverified, the
                  // same way the owner's device does. No weaker than the wire
                  // formula this replaces, and identical on both devices.
                  _certifiedFromProofBytes(spell);
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
    _applyPhoenixSaves();
  }

  // ── Mystery / delayed spell helpers ──────────────────────────────────────

  /// Converts an immediate [MysterySpellCastAction] (delay=0) into a regular
  /// [SpellCastAction] after verifying the mystery commitment.
  /// Returns [PassAction] on hash mismatch. Non-immediate actions pass through.
  Future<TurnAction> _verifyMysteryAction(TurnAction action) async {
    if (action is! MysterySpellCastAction || !action.isImmediate) return action;

    final hash = await PendingDelayedSpell.commitmentHash(
      target: action.immediateTarget!,
      delay: 0,
      nonce: action.immediateNonce!,
    );
    if (!_bytesEqual(hash, action.mysteryCommitment)) return PassAction();

    return SpellCastAction(
      spell: action.spell,
      targetHex: action.immediateTarget!,
      isPotent: action.isPotent,
      isVelocity: action.isVelocity,
      recall: action.recall,
    );
  }

  /// Parses a delayed-reveal payload, verifies each entry against pending state,
  /// and returns the validated fires as (actor, SpellCastAction, certified)
  /// triples. Matching [PendingDelayedSpell]s are removed from state.
  ///
  /// The third element is the [CertifiedCast] captured when the spell was
  /// declared (see [PendingDelayedSpell.certified]) — the proof-attested
  /// semantics this fire must resolve from, rather than the wire
  /// `spell.formula` it used to fall back to.
  Future<List<(WizardAvatar, SpellCastAction, CertifiedCast?)>>
      _verifyAndCollectDelayedFires(
    Uint8List payload,
    String ownerId,
  ) async {
    if (payload.isEmpty) return [];
    final count = payload[0];
    final fires = <(WizardAvatar, SpellCastAction, CertifiedCast?)>[];
    var pos = 1;
    for (var i = 0; i < count; i++) {
      if (pos + 37 > payload.length)
        break; // 16 id + 4 coord + 1 delay + 16 nonce
      final idBytes = payload.sublist(pos, pos + 16);
      pos += 16;
      final targetTile = _decodeCoord(payload, pos);
      pos += 4;
      final delay = payload[pos++];
      final nonce = payload.sublist(pos, pos + 16);
      pos += 16;

      final id = idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final pending = state.pendingDelayedSpells
          .where((p) => p.id == id && p.ownerId == ownerId)
          .firstOrNull;
      if (pending == null) continue;

      // Timing: delay encoded in commitment must equal turns elapsed.
      if (state.turnNumber - pending.castTurn != delay) continue;

      // Commitment verification.
      final hash = await PendingDelayedSpell.commitmentHash(
        target: targetTile,
        delay: delay,
        nonce: nonce,
      );
      if (!_bytesEqual(hash, pending.commitment)) continue;

      final actor = _avatarById(pending.ownerId);
      if (actor == null || !actor.isAlive) continue;

      state.pendingDelayedSpells.remove(pending);
      fires.add((
        actor,
        SpellCastAction(
          spell: pending.spell,
          targetHex: targetTile,
          isPotent: pending.isPotent,
          isVelocity: pending.isVelocity,
          delayedOriginHex: pending.origin,
          delayedRange: pending.declaredRange,
        ),
        pending.certified,
      ));
    }
    return fires;
  }

  /// Encodes local [DelayedSpellReveal]s into the wire payload for
  /// [BattleSession.exchangeDelayedSpellReveals].
  /// Format: [count:1][ id:16, coord:4, delay:1, nonce:16 per entry ]
  /// Pays out this turn's move-phase Meditations, for the players in
  /// [meditatorIds] (already sorted by playerId).
  ///
  /// **Called from Phase 5, after both casts have been charged** — not from
  /// Phase 2, where the declaration is exchanged. The two cast-charging paths
  /// sit in different phases by design: a player's own cast is priced and
  /// deducted the moment its commit crosses the wire
  /// ([_deductManaForCommittedSpell], Phase 1), while the peer's cast can only
  /// be charged once its reveal has been verified ([_verifyPeerSpellCast],
  /// Phase 5). Any mana movement *between* those two points is therefore
  /// applied before the deduction on one device and after it on the other —
  /// and since [_applyManaGain] clamps at `maxMana`, a caster near their
  /// ceiling ended the turn with two different mana totals:
  ///
  ///   caster's device:  100 − 11 = 89, +25 → clamped 100
  ///   opponent's device: 100 + 25 → clamped 100, −11 = 89
  ///
  /// which [_exchangeStateHash] correctly reports as a broken duel. The
  /// caster's own ordering is the canonical one: their cast was committed —
  /// and gated for affordability — before the meditation was worth anything,
  /// so the meditation cannot fund this turn's spell. Paying out here makes
  /// every device agree with that.
  ///
  /// The same reasoning is why [_fizzlesForMana] has to be evaluated against
  /// the same mana on both sides: with the payout at Phase 2, the opponent
  /// priced an unaffordable cast against 25 more mana than the caster did and
  /// the two devices disagreed about whether the spell fizzled at all.
  ///
  /// Sorted rather than local-first for the usual reason (the convention
  /// [_findCounteringCharm] and the Phase 4b melee round follow): a Reflections
  /// manaMirror link makes one player's gain feed the other's, so the order
  /// the two payouts run in is observable, and "me first" is a different order
  /// on each device.
  void _applyMoveMeditations(List<String> meditatorIds) {
    for (final id in meditatorIds) {
      final av = _avatarById(id);
      if (av != null) _applyManaGain(av, _kMeditateManaGain);
    }
  }

  /// See [DeterministicResolution.applyManaGain].
  void _applyManaGain(WizardAvatar av, int amount) =>
      _resolution.applyManaGain(av, amount);

  static Uint8List _buildDelayedRevealPayload(
    List<DelayedSpellReveal> reveals,
  ) {
    final buf = BytesBuilder();
    buf.addByte(reveals.length.clamp(0, 255));
    for (final r in reveals) {
      buf.add(_hexToBytes(r.pendingSpellId)); // 32 hex chars → 16 bytes
      buf.add(_encodeCoord(r.targetTile)); // 4 bytes
      buf.addByte(r.delay & 0xFF); // 1 byte
      buf.add(r.nonce); // 16 bytes
    }
    return buf.toBytes();
  }

  /// Returns the avatars this punch actually damaged — i.e. the ones that did
  /// NOT dodge onto an illusion decoy. That list is what makes "a *successful*
  /// melee attack" precise for the counter-charm proc
  /// ([_applyCounterCharmProc]), which is applied by the caller rather than
  /// here: this method is already doing four things.
  List<WizardAvatar> _applyHaymaker(
    WizardAvatar actor,
    HexCoord targetTile,
    Map<String, List<HexCoord>> walked,
    HashRng rng,
  ) {
    if (!_isAdjacent(actor.position, targetTile)) return const [];

    final hitAvatars = <WizardAvatar>[];
    // Every avatar redirected onto an illusion decoy this punch — a dodge is
    // a full absorb, not just a dodge of the base damage, so every later pass
    // over this same tile (the Fire DoT sweep below) must also skip them.
    // Without the melee redirect's old position-teleport (removed 2026-07-31,
    // see _redirectIfIllusion), the real wizard stays put at [targetTile], so
    // a naive re-query by position would otherwise apply the DoT to a wizard
    // whose punch never actually landed.
    final redirected = <String>{};
    var damage = 1;

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
  /// **Draws from the shared [meleeRng], deliberately — do NOT give it its own
  /// stream.** That stream is already joint-entropy-seeded and sequenced at the
  /// right point in the turn. It is also what makes the melee round's
  /// sorted-playerId application order load-bearing rather than cosmetic: with
  /// this proc, *every* melee consumes the stream, so any turn with two melees
  /// would desync under the old local-first ordering (§6.1).
  ///
  /// Note this is NOT gated on [WizardAvatar.declaredActivation]: §2.2's gate
  /// suppresses charms *firing their counter*, not the passive they radiate
  /// while carried.
  void _applyCounterCharmProc(
    WizardAvatar attacker,
    List<WizardAvatar> victims,
    HashRng rng,
  ) {
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

      final schedule = _drawSchedules[victim.playerId];
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
          _drawSchedules[victim.playerId] =
              schedule!.witherPositions([position]);
      }
      lastCounterCharmProcs.add(
        CounterCharmProcEvent(
          attackerId: attacker.playerId,
          victimId: victim.playerId,
          outcome: outcome,
        ),
      );
    }
  }

  /// Returns the [Minion] just summoned, if [spell.isSummon] and the cast
  /// actually produced a creature (see [_castSummon]); null otherwise.
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
  Future<Minion?> _applySpell(
    WizardAvatar actor,
    SpellAsset spell,
    HexCoord targetHex,
    CastingEnhancements enhancements,
    HashRng rng,
    Uint8List entropy, {
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
    // formula loop. Countered and fizzled casts never reach _applySpell at
    // all, so A1 ("no wild magic on a countered or fizzled cast") holds for
    // free — do not add a hook upstream of the counter check.
    if (fireWildMagic) {
      await _fireWildMagic(actor, spell, certWildMagic, entropy);
    }

    // ── Rippling Reflections (row 3, Water) ───────────────────────────────
    // Once active there is no third outcome: every spell either fizzles or
    // resolves twice. Rolled after wild magic, before the formula loop.
    var repeatWholeSpell = 1;
    if (subjectToRippling && state.wildMagic.ripplingFizzlePct != null) {
      final pct = state.wildMagic.ripplingFizzlePct!;
      final coin = HashRng(
        _playerPhaseSeed(
          entropy,
          matchId,
          state.turnNumber,
          0x0A,
          actor.playerId,
          _ripplingNonce++,
        ),
      ).nextInt(100);
      if (coin < pct) {
        // Fizzle: no formula effects at all, drift 10% toward doubling.
        // Treated as a fizzle for chain purposes, matching the existing
        // enhancements.fizzle branch in _resolveActions.
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
      final sequence = certElementSequence ?? _elementSequence(spell);
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
    final allFormulas = certFormulas ?? _parsedFormulas(spell);
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
            drawSchedules: _drawSchedules,
            witherRng: witherRng,
            effectiveRadiusBonus: radiusBonus,
          ),
        );
      }
    }
    }
    lastConveyorChainEvents.addAll(conveyorEvents);

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
    WizardAvatar actor,
    HexCoord declared,
    Uint8List entropy,
  ) {
    if (!actor.hasTurbulent) return declared;
    final from = actor.position;
    final n = hexDistance(from, declared);
    // A cast on your own tile has no direction to be thrown off along.
    if (n == 0) return declared;

    final rng = HashRng(
      _playerPhaseSeed(
        entropy,
        matchId,
        state.turnNumber,
        0x0B,
        actor.playerId,
        _turbulentNonce++,
      ),
    );
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
  /// [certified] is the peer path: triggers derived by [_verifyPeerSpellCast]
  /// from the peer's VERIFIED proof public outputs, or — for a delayed fire —
  /// carried on the [PendingDelayedSpell] from the turn it was declared. Null
  /// means the local player's own cast (or the kAllowProoflessSpells dev
  /// flag) — see [_wildMagicFromOwnProof].
  Future<void> _fireWildMagic(
    WizardAvatar actor,
    SpellAsset spell,
    List<WildMagicTrigger>? certified,
    Uint8List entropy,
  ) async {
    final triggers = certified ?? _wildMagicFromOwnProof(spell);
    if (triggers.isEmpty) return;

    for (final trigger in triggers) {
      final rng = HashRng(
        _playerPhaseSeed(
          entropy,
          matchId,
          state.turnNumber,
          0x09,
          actor.playerId,
          _consumeWildMagicNonce(),
        ),
      );
      WildMagicApplicator.apply(
        WildMagicApplyContext(
          state: state,
          caster: actor,
          rng: rng,
          trigger: trigger,
          events: lastWildMagicEvents,
          hooks: this,
        ),
      );
    }

    // Spontaneous Combustion's reveal round trip sits HERE: after wild magic
    // has fired, before the triggering spell's own formula effects resolve
    // (WILD_MAGIC_PLAN.md §9.5). The applicator queues rather than resolving
    // because it is synchronous and this needs the network.
    await _drainForcedCasts(entropy);
  }

  /// The full certified semantics of a spell, derived from proof bytes this
  /// device already holds.
  ///
  /// Parses the proof bytes (signature verification skipped — see
  /// [ProofIntake.parseOwn]) and re-derives formulas, element sequence, and
  /// wild-magic triggers from the certified trajectory rather than the wire
  /// `spell.formula`, so this produces byte-identical results to the peer path
  /// ([_verifyPeerSpellCast]) for the same proof. One derivation, every call
  /// site — §10 invariant 2.
  ///
  /// Returns null when there are no proof bytes: the `kAllowProoflessSpells`
  /// dev flag. Both devices see the same (absent) proof bytes and both fall
  /// back to the wire formula, so it is desync-SAFE even though it is not
  /// trust-safe. That residue of TODO(B-1) is load-bearing for the dev flag —
  /// do not widen it and do not invent a second policy for it.
  // TODO(B-1): the remaining hole is the kAllowProoflessSpells flag. Closing it
  //   means deleting the flag, then making a null CertifiedCast for a
  //   current-turn peer spell a forfeit rather than a wire-formula fallback.
  ///
  /// For our own spell this is the authoritative derivation. For a peer's, it
  /// is a *fallback* used only when [_verifyPeerSpellCast] never ran (solo, or
  /// verification not wired up) — it parses without verifying, so it is no
  /// stronger than the bytes it was handed. When verification IS wired, the
  /// verified derivation always wins; see [_certifiedPeerCast]. Both devices
  /// parse the same bytes either way, so this arm stays in lockstep.
  CertifiedCast? _certifiedFromProofBytes(SpellAsset spell) {
    if (spell.proofBytes.isEmpty) return null;
    try {
      // The spell's OWN tier, not the match ceiling — parsing at the wrong
      // tier_max reads the trajectory arrays at the wrong offsets and would
      // derive different formulas and wild-magic triggers than the peer does
      // from the same proof (§10 invariant 2). The spell's recorded tier is
      // authoritative; fall back to deriving it from T for assets written
      // before the field was trustworthy.
      final ownTier = _tierForSpell(spell.t) ?? spell.tier;
      final outputs = ProofIntake.parseOwn(spell.proofBytes, ownTier);
      final formulas = TrajectoryParser.parse(outputs).formulas;
      return CertifiedCast(
        formulas: formulas,
        elementSequence: TrajectoryParser.certifiedElementSequence(outputs),
        wildMagic: WildMagic.triggersFor(
          outputs,
          formulas,
          state.config.communitySeed,
        ),
      );
    } on ProofIntakeException {
      // A malformed local proof is a bug, not an attack; falling back is the
      // same outcome on both devices (they parse the same bytes).
      return null;
    }
  }

  /// Wild-magic triggers for a spell whose proof this device authored.
  List<WildMagicTrigger> _wildMagicFromOwnProof(SpellAsset spell) =>
      _certifiedFromProofBytes(spell)?.wildMagic ?? const [];

  /// The [CertifiedCast] [_verifyPeerSpellCast] derived for [spell] earlier in
  /// this turn, or null if it never ran for it.
  ///
  /// Keyed by `commitmentHex` exactly as the three maps are — safe here because
  /// this is only ever asked about the peer's own current-turn action, which
  /// [_verifyPeerSpellCast] populates at most once per turn.
  CertifiedCast? _certifiedPeerCast(
    SpellAsset spell,
    Map<String, List<ParsedFormula>> certifiedPeerFormulas,
    Map<String, List<BorderZone>> certifiedPeerElementSequences,
    Map<String, List<WildMagicTrigger>> certifiedPeerWildMagic,
  ) {
    final formulas = certifiedPeerFormulas[spell.commitmentHex];
    final sequence = certifiedPeerElementSequences[spell.commitmentHex];
    if (formulas == null || sequence == null) return null;
    return CertifiedCast(
      formulas: formulas,
      elementSequence: sequence,
      // An empty trigger list is the normal case, not an absent one.
      wildMagic: certifiedPeerWildMagic[spell.commitmentHex] ?? const [],
    );
  }

  /// See [DeterministicResolution.applyPhoenixSaves]. The event sink is this
  /// turn's `lastWildMagicEvents`, which the resolver appends to in place.
  void _applyPhoenixSaves() =>
      _resolution.applyPhoenixSaves(lastWildMagicEvents);

  /// See [DeterministicResolution.breakStatuesque].
  void _breakStatuesque(String playerId) =>
      _resolution.breakStatuesque(playerId);

  // ── WildMagicHooks ────────────────────────────────────────────────────────

  @override
  void queueForcedCast(
    Set<String> playerIds,
    int countPerPlayer,
    String reasonTag,
  ) {
    _pendingForcedCasts.add(
      ForcedCastRequest(
        affectedPlayerIds: playerIds,
        countPerPlayer: countPerPlayer,
        reasonTag: reasonTag,
      ),
    );
  }

  /// Re-deals [playerId]'s entire hand: every card returns to `remaining` in
  /// canonical commitmentHex order (that sortedness is a load-bearing
  /// invariant — see spell_draw.dart's header), then a fresh hand is drawn.
  /// Old spells can come back: they are returned to the pool BEFORE the redraw,
  /// which is exactly what makes a bookmark burn a gamble rather than a
  /// guaranteed upgrade.
  ///
  /// Mirrors [_advanceDrawState]'s dual-structure update exactly: the public
  /// [_drawSchedules] entry always advances; [localSpellDraw]'s real CONTENTS
  /// only when [playerId] is the local player. Both use independently
  /// constructed HashRng instances over the SAME seed bytes — never a shared
  /// mutable instance — which is what keeps positions and contents in
  /// agreement (see this class's hand/deck header comment).
  ///
  /// [handSize] defaults to the current hand's size (wild magic's Scattered
  /// Gusts re-deals the same number of cards). The bookmark burn passes an
  /// explicitly SMALLER size, because burning the bookmark permanently removed
  /// the slot it paid for. [tag] is the phase-seed domain tag — `0x05` for a
  /// Scattered Gusts redraw, `0x09` for a bookmark burn — so the two can never
  /// collide on the same turn.
  void _redrawHand(
    String playerId,
    Uint8List entropy, {
    int? handSize,
    int tag = 0x05,
  }) {
    final schedule = _drawSchedules[playerId];
    if (schedule == null) return;
    final size = handSize ?? schedule.hand.length;
    if (size <= 0) return;
    final seed = _playerPhaseSeed(
      entropy,
      matchId,
      state.turnNumber,
      tag,
      playerId,
      _consumeDrawNonce(playerId),
    );
    _drawSchedules[playerId] = schedule.redrawHand(size, HashRng(seed));
    if (playerId == localPlayerId) {
      final draw = localSpellDraw;
      if (draw != null) {
        localSpellDraw = draw.redrawHand(size, HashRng(seed));
      }
    }
  }

  // ── ForcedCastHost ────────────────────────────────────────────────────────

  /// Drains every forced cast queued during the wild-magic sweep. Each runs
  /// the full public-slot-selection → reveal → verify → resolve sequence.
  Future<void> _drainForcedCasts(Uint8List entropy) async {
    if (_pendingForcedCasts.isEmpty) return;
    // Copy and clear FIRST: a forced cast's own resolution must not be able to
    // queue another one (A8 exempts free casts from wild magic entirely, so
    // this should be unreachable — belt and braces against an unbounded
    // cascade if a future effect forgets).
    final requests = List<ForcedCastRequest>.from(_pendingForcedCasts);
    _pendingForcedCasts.clear();
    for (final request in requests) {
      await ForcedCast.run(
        request,
        this,
        (playerId) => HashRng(
          _playerPhaseSeed(
            entropy,
            matchId,
            state.turnNumber,
            0x09,
            playerId,
            _consumeWildMagicNonce(),
          ),
        ),
      );
    }
  }

  @override
  List<int> publicHandPositions(String playerId) =>
      List<int>.from(_drawSchedules[playerId]?.hand ?? const <int>[]);

  @override
  Uint8List forcedCastSeed(String playerId, String reasonTag) {
    final entropy = _turnEntropy ?? Uint8List(32);
    final buf = BytesBuilder(copy: false)
      ..add(
        _playerPhaseSeed(
          entropy,
          matchId,
          state.turnNumber,
          0x09,
          playerId,
          _consumeWildMagicNonce(),
        ),
      )
      ..add(utf8.encode(reasonTag));
    return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
  }

  @override
  bool isLocalPlayer(String playerId) => playerId == localPlayerId;

  @override
  SpellAsset? localSpellAt(int position) {
    final chapter = localChapterSpells;
    if (chapter == null) return null;
    final canonical = List<SpellAsset>.from(chapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    if (position < 0 || position >= canonical.length) return null;
    return canonical[position];
  }

  @override
  MembershipProof? localMembershipProofAt(int position) {
    final commitments = localChapterCommitments;
    if (commitments == null) return null;
    return BookCommitment.proveMembershipAt(commitments, position);
  }

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ours) =>
      session.exchangeForcedReveal(ours);

  @override
  Future<void> verifyForcedReveal(
    String playerId,
    int position,
    SpellAsset spell,
    MembershipProof? merkleProof,
  ) async {
    // Runs the SAME path a normal peer cast takes. The duplicate-grid guard is
    // deliberately bypassed (see _verifyPeerSpellCast's forcedCast flag): a
    // forced cast is not the player's choice, so it must not consume their
    // once-per-match right to cast that grid, nor trip the duplicate forfeit.
    await _verifyPeerSpellCast(
      SpellCastAction(spell: spell, targetHex: const HexCoord(0, 0)),
      merkleProof,
      <String, List<ParsedFormula>>{},
      <String, List<BorderZone>>{},
      <String, List<WildMagicTrigger>>{},
      forcedCast: true,
    );
  }

  @override
  Future<void> resolveForcedCast(ForcedCastPick pick, HashRng rng) async {
    final actor = _avatarById(pick.playerId);
    if (actor == null || !actor.isAlive) return;
    final target = _randomTileInRange(actor, rng);
    final entropy = _turnEntropy ?? Uint8List(32);
    // A8, the load-bearing recursion guard: a free cast fires NO wild magic,
    // is not subject to Rippling Reflections, does not trigger Scattered
    // Gusts, does not build or break the chain, and is not consumed from hand.
    await _applySpell(
      actor,
      pick.spell,
      target,
      const CastingEnhancements(),
      rng,
      entropy,
      fireWildMagic: false,
      subjectToRippling: false,
      skipChainUpdate: true,
    );
  }

  @override
  void forfeitMatch(String reason) => session.sendForfeit(reason);

  /// A random tile within [av]'s effective spell range, drawn from a SORTED
  /// candidate list so both devices pick the same one from the same RNG.
  HexCoord _randomTileInRange(WizardAvatar av, HashRng rng) {
    final range = av.effectiveSpellRange;
    final candidates = <HexCoord>[];
    for (var dq = -range; dq <= range; dq++) {
      for (var dr = -range; dr <= range; dr++) {
        final h = HexCoord(av.position.q + dq, av.position.r + dr);
        if (!state.battlefield.isInBounds(h)) continue;
        if (hexDistance(av.position, h) > range) continue;
        candidates.add(h);
      }
    }
    if (candidates.isEmpty) return av.position;
    candidates.sort((a, b) {
      final qc = a.q.compareTo(b.q);
      return qc != 0 ? qc : a.r.compareTo(b.r);
    });
    return candidates[rng.nextInt(candidates.length)];
  }

  /// Rod of Wind (Air artifact): if [requested] and [actor] carries an
  /// unused rod, removes one from their loadout and returns +1 — the effective
  /// radius bonus for an incantation, or the size-rung bonus for a summon.
  /// Otherwise returns 0.
  ///
  /// [requested] now comes from the caster's **Phase-0 declaration**
  /// (`declaredActivation == rodOfSpreading`) rather than a flag on the action
  /// commit, but this stays the single rod-consumption path — which is what
  /// keeps the trust boundary in one place. Reading the bonus from the actor's
  /// OWN accoutrements, not from the wire, is that boundary: a peer that
  /// declares a rod without actually owning one gets no bonus. This mirrors
  /// how _certifiedManaCost recomputes cost from authoritative state rather
  /// than trusting the caster's word. Removing the accoutrement mutates the
  /// avatar, so it shows up in BattleState.toCanonicalBytes() and both devices
  /// stay in lockstep on the consumed rod.
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
  /// turn (see this file's header comment). A Potent cast additionally lets
  /// the creature act immediately right here (design doc: "Summons may take
  /// an immediate turn the generation they are summoned if spell is made
  /// potent"), so it ends up acting twice in a row this turn: once here,
  /// once again in Phase 5b.
  Minion? _castSummon(
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
      _creatureTurn(creature, rng);
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
      final mirrorOwner = _avatarById(link.casterId);
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
    for (final n in _neighbors(preferred)) {
      if (footprintOpen(n)) return n;
    }
    return preferred; // fallback: stack anyway
  }

  /// Advances/breaks [actor]'s chain following this cast. [spell.isSummon]
  /// spells build the chain like any other spell (design doc R4), keyed on
  /// the creature's derived affinity ([CreatureSpec.fromElements] — always a
  /// single element, so a summon is always pure) rather than
  /// [certFormulas]/[_parsedFormulas]; [certElementSequence] is the
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
            certElementSequence ?? _elementSequence(spell),
          )?.affinity
        : _pureAffinityOf(certFormulas ?? _parsedFormulas(spell));

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
  /// (the sole call site, in [_resolveActions]) decides between the
  /// full-counter path (skip [_applySpell] entirely) and the partial-counter
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

  // ── Entropy + state hash ──────────────────────────────────────────────────

  Future<Uint8List> _resolveEntropy() async {
    final ourNonce = _commitNonce(32);
    final ourCommit = await CommitRevealEntropy.commit(ourNonce);

    final (:theirNonce, :theirCommit) = await session.exchangeNonce(
      ourCommit: ourCommit,
      ourNonce: ourNonce,
    );

    final jointEntropy = await CommitRevealEntropy.revealAndCombine(
      ourNonce: ourNonce,
      theirNonce: theirNonce,
      theirCommit: theirCommit,
    );

    if (jointEntropy == null) {
      session.sendForfeit('withheld_reveal');
      throw StateError('peer withheld nonce reveal — match forfeit');
    }
    return jointEntropy;
  }

  /// Builds the message signed/verified over a state hash: distinct per
  /// match (matchId) and per turn (turnNumber), so a signature can't be
  /// replayed across matches or turns.
  List<int> _stateHashMessage(Uint8List hash) => [
        ...utf8.encode(kStateHashSignatureTag),
        ...(matchId ?? const <int>[]),
        ..._be4(state.turnNumber),
        ...hash,
      ];

  Future<void> _exchangeStateHash() async {
    final canonical = state.toCanonicalBytes();
    final hashBytes = await Sha256().hash(canonical);
    final ourHash = Uint8List.fromList(hashBytes.bytes);

    // Phase D (BATTLE_AUTH_PLAN.md §6): sign the hash when we have a local
    // identity to sign with (real duel); solo/test sends the raw 32-byte
    // hash unsigned, exactly as before Phase D existed.
    final sign = signMessage;
    final Uint8List outgoing;
    if (sign == null) {
      outgoing = ourHash;
    } else {
      final sig = await sign(_stateHashMessage(ourHash));
      outgoing = Uint8List.fromList([...ourHash, ...sig]);
    }

    final peerBytes = await session.exchangeStateHash(outgoing);

    final rawPeerKey = peerRawPubkey;
    final Uint8List peerHash;
    if (rawPeerKey == null) {
      peerHash = peerBytes;
    } else {
      if (peerBytes.length < 32 + 64) {
        session.sendForfeit('missing_state_signature');
        throw StateError(
          'peer state hash missing signature (turn ${state.turnNumber}) — match forfeit',
        );
      }
      peerHash = peerBytes.sublist(0, 32);
      final peerSig = peerBytes.sublist(32, 96);
      final sigOk = await Identity.verify(
        message: _stateHashMessage(peerHash),
        signatureBytes: peerSig,
        publicKeyBytes: rawPeerKey,
      );
      if (!sigOk) {
        session.sendForfeit('bad_state_signature');
        throw StateError(
          'peer state hash signature invalid (turn ${state.turnNumber}) — match forfeit',
        );
      }
    }

    if (!_bytesEqual(ourHash, peerHash)) {
      session.sendForfeit('state_hash_mismatch');
      throw StateError(
        'state hash mismatch on turn ${state.turnNumber}: '
        'local=${_hex(ourHash)} peer=${_hex(peerHash)}',
      );
    }
  }

  // ── Commit-reveal verification ────────────────────────────────────────────

  /// Verify that `data[0..15]` is the nonce and `SHA-256(data[16..] ‖ data[0..15]) == commit`.
  Future<void> _verifyReveal(
    Uint8List reveal,
    Uint8List commit,
    String label,
  ) async {
    if (reveal.length < _kRevealNonceBytes) {
      session.sendForfeit('malformed_reveal:$label');
      throw StateError('peer sent malformed $label reveal (too short)');
    }
    final nonce = reveal.sublist(0, _kRevealNonceBytes);
    final payload = reveal.sublist(_kRevealNonceBytes);
    final expected = await Sha256()
        .hash(Uint8List.fromList([...payload, ...nonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    if (!_bytesEqual(expected, commit)) {
      session.sendForfeit('withheld_reveal:$label');
      throw StateError(
        'peer $label reveal did not match commit — match forfeit',
      );
    }
  }

  /// Verify an action reveal against its split-leaf commitment (§13b.2.1):
  /// `data[0..15]` = remainder salt, `data[16..31]` = target salt,
  /// `data[32..]` = actionBytes. Recomputes both leaves from the revealed
  /// actionBytes and checks their combined hash against [commit].
  Future<void> _verifyActionReveal(Uint8List reveal, Uint8List commit) async {
    if (reveal.length < _kRevealNonceBytes * 2) {
      session.sendForfeit('malformed_reveal:action');
      throw StateError('peer sent malformed action reveal (too short)');
    }
    final saltA = reveal.sublist(0, _kRevealNonceBytes);
    final saltB = reveal.sublist(_kRevealNonceBytes, _kRevealNonceBytes * 2);
    final actionBytes = reveal.sublist(_kRevealNonceBytes * 2);
    final expected = await _splitActionCommit(actionBytes, saltA, saltB);
    if (!_bytesEqual(expected, commit)) {
      session.sendForfeit('withheld_reveal:action');
      throw StateError(
        'peer action reveal did not match commit — match forfeit',
      );
    }
  }

  // ── Divination scrying pattern (MESH_ARCHITECTURE.md §13b) ────────────────
  //
  // actionCommit = SHA-256( H(remainder ‖ saltA) ‖ H(target ‖ saltB) ). A
  // scryer with an active DivinationLink can verifiably learn (target, saltB)
  // early — via an encrypted scryOpen frame naming leafA as the Merkle
  // sibling — without learning remainder (spell identity/formula/enhancements).

  /// Splits action bytes into (targetBytes, remainderBytes): targetBytes is
  /// the plaintext (q,r) HexCoord slice a scry effect may verifiably open
  /// early; remainderBytes is everything else. Pass and delayed (non-
  /// immediate) Mystery casts have no plaintext target yet — targetBytes is
  /// empty for those.
  static (Uint8List target, Uint8List remainder) _splitActionTarget(
    Uint8List actionBytes,
  ) {
    if (actionBytes.isEmpty) return (Uint8List(0), actionBytes);
    int? targetOffset;
    switch (actionBytes[0]) {
      case 0x01:
        targetOffset = 1 + 32 + 2; // SpellCastAction: after type+commit+t.
    }
    if (targetOffset == null || actionBytes.length < targetOffset + 4) {
      return (Uint8List(0), actionBytes);
    }
    final target = actionBytes.sublist(targetOffset, targetOffset + 4);
    final remainder = Uint8List.fromList([
      ...actionBytes.sublist(0, targetOffset),
      ...actionBytes.sublist(targetOffset + 4),
    ]);
    return (Uint8List.fromList(target), remainder);
  }

  static Future<Uint8List> _leafHash(Uint8List data, Uint8List salt) async {
    final h = await Sha256().hash(Uint8List.fromList([...data, ...salt]));
    return Uint8List.fromList(h.bytes);
  }

  static Future<Uint8List> _splitActionCommit(
    Uint8List actionBytes,
    Uint8List saltA,
    Uint8List saltB,
  ) async {
    final (target, remainder) = _splitActionTarget(actionBytes);
    final leafA = await _leafHash(remainder, saltA);
    final leafB = await _leafHash(target, saltB);
    final h = await Sha256().hash(Uint8List.fromList([...leafA, ...leafB]));
    return Uint8List.fromList(h.bytes);
  }

  /// Runs the §13b scry-key/scry-open exchange for the current turn, in both
  /// directions at once (this player may simultaneously be scrying the peer
  /// via one link and be scried by the peer via another). Always calls both
  /// session methods — uniform slot, conditional content — so the exchange
  /// shape never depends on secret state.
  ///
  /// Returns the decrypted opponent target tile if this player has an active
  /// outgoing [DivinationLink] and the peer's opening verified; null
  /// otherwise (no active link, peer sent no plaintext target this turn, or
  /// the opening failed to verify — treated as a protocol violation, see
  /// below).
  Future<HexCoord?> _exchangeScryOpenings({
    required Uint8List actionBytes,
    required Uint8List saltA,
    required Uint8List saltB,
    required Uint8List peerActionCommit,
  }) async {
    final peerId = _peerId();
    final outgoingLink = peerId == null
        ? null
        : state.divinationLinks
              .where(
                (l) =>
                    l.casterId == localPlayerId &&
                    l.targetId == peerId &&
                    l.remainingTurns > 0,
              )
              .firstOrNull;
    final incomingLink = peerId == null
        ? null
        : state.divinationLinks
              .where(
                (l) =>
                    l.casterId == peerId &&
                    l.targetId == localPlayerId &&
                    l.remainingTurns > 0,
              )
              .firstOrNull;

    final x25519 = X25519();

    // ── Send our scryKey: a fresh, single-use X25519 pubkey iff we're scrying. ──
    SimpleKeyPair? myEphemeral;
    Uint8List myKeyFrame;
    if (outgoingLink != null) {
      myEphemeral = await x25519.newKeyPair();
      final pub = await myEphemeral.extractPublicKey();
      myKeyFrame = Uint8List.fromList([0x01, ...pub.bytes]);
    } else {
      myKeyFrame = Uint8List.fromList([0x00]);
    }
    final peerKeyFrame = await session.exchangeScryKey(myKeyFrame);

    // ── Send our scryOpen: an AEAD-encrypted target-leaf opening iff the ──
    // ── peer is scrying us. ──
    Uint8List myOpenFrame = Uint8List.fromList([0x00]);
    if (incomingLink != null &&
        peerKeyFrame.length == 33 &&
        peerKeyFrame[0] == 0x01) {
      final peerEkPub = SimplePublicKey(
        peerKeyFrame.sublist(1),
        type: KeyPairType.x25519,
      );
      final vk = await x25519.newKeyPair();
      final vkPub = await vk.extractPublicKey();
      final shared = await x25519.sharedSecretKey(
        keyPair: vk,
        remotePublicKey: peerEkPub,
      );
      final derived = await Hkdf(
        hmac: Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(secretKey: shared, info: _scryHkdfInfo());

      final (targetBytes, remainder) = _splitActionTarget(actionBytes);
      final leafA = await _leafHash(remainder, saltA);
      // Opening: targetBytes(4, may be 0) ‖ saltB(16) ‖ leafA(32, the Merkle
      // sibling needed to verify the leaf against the public actionCommit).
      final opening = Uint8List.fromList([...targetBytes, ...saltB, ...leafA]);
      final cipher = Xchacha20.poly1305Aead();
      final nonce = cipher.newNonce();
      final box = await cipher.encrypt(
        opening,
        secretKey: derived,
        nonce: nonce,
      );
      myOpenFrame = Uint8List.fromList([
        0x01,
        ...vkPub.bytes,
        ...box.concatenation(),
      ]);
    }
    final peerOpenFrame = await session.exchangeScryOpen(myOpenFrame);

    // ── Decrypt the peer's opening, if we're the scryer and they answered. ──
    if (myEphemeral == null ||
        peerOpenFrame.isEmpty ||
        peerOpenFrame[0] != 0x01) {
      return null;
    }
    if (peerOpenFrame.length < 1 + 32) return null;
    final vkPub = SimplePublicKey(
      peerOpenFrame.sublist(1, 33),
      type: KeyPairType.x25519,
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: myEphemeral,
      remotePublicKey: vkPub,
    );
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, info: _scryHkdfInfo());

    const nonceLen = 24, macLen = 16;
    final boxBytes = peerOpenFrame.sublist(33);
    if (boxBytes.length < nonceLen + macLen) return null;
    final box = SecretBox.fromConcatenation(
      boxBytes,
      nonceLength: nonceLen,
      macLength: macLen,
    );

    List<int> opening;
    try {
      opening = await Xchacha20.poly1305Aead().decrypt(box, secretKey: derived);
    } catch (_) {
      session.sendForfeit('bad_scry_opening');
      throw StateError('peer scry opening failed AEAD auth — match forfeit');
    }
    // Opening is targetBytes ‖ saltB(16) ‖ leafA(32); targetBytes is 4 bytes
    // for a Spell/Haymaker cast, 0 bytes (no plaintext target yet) for a
    // Pass or delayed Mystery cast — see [_splitActionTarget].
    final hasTarget = opening.length == 4 + 16 + 32;
    if (!hasTarget && opening.length != 16 + 32) return null;
    final openedTarget = hasTarget
        ? Uint8List.fromList(opening.sublist(0, 4))
        : Uint8List(0);
    final saltOffset = hasTarget ? 4 : 0;
    final openedSaltB = Uint8List.fromList(
      opening.sublist(saltOffset, saltOffset + 16),
    );
    final leafA = Uint8List.fromList(
      opening.sublist(saltOffset + 16, saltOffset + 48),
    );

    final leafB = await _leafHash(openedTarget, openedSaltB);
    final recombined = await Sha256().hash(
      Uint8List.fromList([...leafA, ...leafB]),
    );
    if (!_bytesEqual(Uint8List.fromList(recombined.bytes), peerActionCommit)) {
      session.sendForfeit('bad_scry_opening');
      throw StateError(
        'peer scry opening does not match their actionCommit — match forfeit',
      );
    }

    return hasTarget ? _decodeCoord(openedTarget, 0) : null;
  }

  /// Domain-separates the scry-key HKDF derivation by match and turn, so an
  /// ephemeral key reused (never should be, but defence-in-depth) across
  /// matches or turns still derives a distinct symmetric key.
  Uint8List _scryHkdfInfo() => Uint8List.fromList([
    ...utf8.encode('RWSCRY1'),
    ...(matchId ?? const <int>[]),
    ..._be4(state.turnNumber),
  ]);

  // ── Divination (Water) spell-list reveal ───────────────────────────────────
  //
  // Watery Scrying Pool ("see target's available spells") reuses the exact
  // §13b encrypted-broadcast transport shape as [_exchangeScryOpenings], but
  // carries a spell list rather than a single committed-target leaf, and is
  // verified against [peerBookRoot] (the peer's chapter Merkle root, already
  // exchanged at handshake) rather than a fresh per-turn action commitment.
  //
  // SPELL_DRAW_WIRING_PLAN.md §8: reveals the target's current HAND, not
  // their whole chapter (confirmed intent — scrying shows what an opponent
  // holds, not their whole deck). This is NOT the "transport unchanged"
  // claim §8's prose makes: the old design proved the revealed set honest by
  // recomputing [BookCommitment.computeRoot] over the *entire* revealed set
  // and checking it equals [peerBookRoot] — that only works when the
  // revealed set IS the whole chapter. A 3-card hand's root will never equal
  // the N-card chapter's root. So each revealed spell now carries its own
  // [MembershipProof] (siblings + directions) against [peerBookRoot]
  // instead — the only sound way to reveal a subset while staying tied to
  // the same root. Each proof's [MembershipProof.leafIndex] also lets the
  // receiver check the revealed positions match the target's publicly-
  // computed in-hand set (_drawSchedules) — checkable today, no ZK circuit
  // needed, since that bookkeeping is already public — so a cheat client
  // can't under-report its hand either, per §8's closing note.
  //
  // Residual trust boundary, shared with every other non-cast use of
  // commitmentHex in this codebase (CLAUDE.md invariant 1 — Poseidon2 is
  // never reimplemented in Dart, so a commitmentHex can't be independently
  // recomputed from grid data client-side): this verifies that each revealed
  // commitmentHex is a genuine chapter member at an in-hand position, not
  // that its displayed name/grid/formula is honestly bound to that
  // commitmentHex — that binding is only ever checked by the ZK proof at
  // actual cast time. A malicious peer could pair a real commitmentHex with
  // fabricated display data. Same boundary [_verifyPeerSpellCast] already
  // lives with for uncast spells.

  /// Returns the peer's verified current hand if this player has an active
  /// outgoing Water [DivinationLink] and the peer's opening verified; null
  /// otherwise (no active link, peer's hand isn't dealt yet, or the peer
  /// declined — e.g. solo/test sessions, which never have a real chapter to
  /// reveal).
  Future<List<SpellAsset>?> _exchangeSpellRevealOpenings() async {
    final peerId = _peerId();
    final outgoingLink = peerId == null
        ? null
        : state.divinationLinks
              .where(
                (l) =>
                    l.casterId == localPlayerId &&
                    l.targetId == peerId &&
                    l.remainingTurns > 0 &&
                    l.flavor == DivinationFlavor.spellList,
              )
              .firstOrNull;
    final incomingLink = peerId == null
        ? null
        : state.divinationLinks
              .where(
                (l) =>
                    l.casterId == peerId &&
                    l.targetId == localPlayerId &&
                    l.remainingTurns > 0 &&
                    l.flavor == DivinationFlavor.spellList,
              )
              .firstOrNull;

    final x25519 = X25519();

    SimpleKeyPair? myEphemeral;
    Uint8List myKeyFrame;
    if (outgoingLink != null) {
      myEphemeral = await x25519.newKeyPair();
      final pub = await myEphemeral.extractPublicKey();
      myKeyFrame = Uint8List.fromList([0x01, ...pub.bytes]);
    } else {
      myKeyFrame = Uint8List.fromList([0x00]);
    }
    final peerKeyFrame = await session.exchangeSpellRevealKey(myKeyFrame);

    Uint8List myOpenFrame = Uint8List.fromList([0x00]);
    final hand = localSpellDraw?.hand;
    final commitments = localChapterCommitments;
    if (incomingLink != null &&
        hand != null &&
        commitments != null &&
        peerKeyFrame.length == 33 &&
        peerKeyFrame[0] == 0x01) {
      final peerEkPub = SimplePublicKey(
        peerKeyFrame.sublist(1),
        type: KeyPairType.x25519,
      );
      final vk = await x25519.newKeyPair();
      final vkPub = await vk.extractPublicKey();
      final shared = await x25519.sharedSecretKey(
        keyPair: vk,
        remotePublicKey: peerEkPub,
      );
      final derived = await Hkdf(
        hmac: Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(secretKey: shared, info: _spellRevealHkdfInfo());

      // Each hand card carries its own Merkle proof (siblings/directions)
      // against our own committed book — the receiver checks it against
      // [peerBookRoot] on their side (see this method's header comment for
      // why a single batch root over just the hand can't work). Proved by
      // SLOT (schedule.hand[i]), not by commitment search — the duplicate-
      // safe form (docs/BASIC_SPELLS_PLAN.md §7): a hand may hold several
      // copies of the same Basic spell's grid, and DrawSchedule.hand /
      // SpellDraw.hand are index-parallel by construction, so slot i's
      // chapter position is schedule.hand[i] regardless of duplicates.
      final schedule = _drawSchedules[localPlayerId];
      final entries = <Map<String, dynamic>>[];
      for (var i = 0; i < hand.length; i++) {
        final spell = hand[i];
        final position = schedule != null && i < schedule.hand.length
            ? schedule.hand[i]
            : BookCommitment.proveMembership(commitments, spell.commitmentHex)?.leafIndex;
        final proof =
            position != null ? BookCommitment.proveMembershipAt(commitments, position) : null;
        if (proof == null) continue; // unreachable: hand spells are chapter members
        entries.add({
          'spell': spell.toJson(),
          'siblings': proof.siblings,
          'directions': proof.directions,
        });
      }
      final payload = Uint8List.fromList(utf8.encode(jsonEncode(entries)));
      final cipher = Xchacha20.poly1305Aead();
      final nonce = cipher.newNonce();
      final box = await cipher.encrypt(payload, secretKey: derived, nonce: nonce);
      myOpenFrame = Uint8List.fromList([
        0x01,
        ...vkPub.bytes,
        ...box.concatenation(),
      ]);
    }
    final peerOpenFrame = await session.exchangeSpellRevealOpen(myOpenFrame);

    if (myEphemeral == null ||
        peerOpenFrame.isEmpty ||
        peerOpenFrame[0] != 0x01) {
      return null;
    }
    if (peerOpenFrame.length < 1 + 32) return null;
    final vkPub = SimplePublicKey(
      peerOpenFrame.sublist(1, 33),
      type: KeyPairType.x25519,
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: myEphemeral,
      remotePublicKey: vkPub,
    );
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, info: _spellRevealHkdfInfo());

    const nonceLen = 24, macLen = 16;
    final boxBytes = peerOpenFrame.sublist(33);
    if (boxBytes.length < nonceLen + macLen) return null;
    final box = SecretBox.fromConcatenation(
      boxBytes,
      nonceLength: nonceLen,
      macLength: macLen,
    );

    List<int> payloadBytes;
    try {
      payloadBytes = await Xchacha20.poly1305Aead().decrypt(box, secretKey: derived);
    } catch (_) {
      session.sendForfeit('bad_spell_reveal');
      throw StateError('peer spell reveal failed AEAD auth — match forfeit');
    }

    List<SpellAsset> revealed;
    List<MembershipProof> revealedProofs;
    try {
      final decoded = jsonDecode(utf8.decode(payloadBytes)) as List<dynamic>;
      final spells = <SpellAsset>[];
      final proofs = <MembershipProof>[];
      for (final entryRaw in decoded) {
        final entry = entryRaw as Map<String, dynamic>;
        final spell = SpellAsset.fromJson(entry['spell'] as Map<String, dynamic>);
        final siblings = (entry['siblings'] as List<dynamic>).cast<String>();
        final directions = (entry['directions'] as List<dynamic>).cast<bool>();
        spells.add(spell);
        proofs.add(MembershipProof(
          root: '', // filled per-entry below, from peerBookRoot
          leafHex: spell.commitmentHex,
          siblings: siblings,
          directions: directions,
        ));
      }
      revealed = spells;
      revealedProofs = proofs;
    } catch (_) {
      session.sendForfeit('bad_spell_reveal');
      throw StateError('peer spell reveal payload malformed — match forfeit');
    }

    final root = peerBookRoot;
    if (root == null) {
      session.sendForfeit('bad_spell_reveal');
      throw StateError(
        'peer spell reveal received with no book commitment on file — match forfeit',
      );
    }
    // The public in-hand set for the revealing peer — checkable today with
    // no ZK circuit (see this method's header comment). Absent (skip, not
    // fail) if our own bookkeeping for them isn't dealt yet — a local
    // chapter-load race, not the peer's fault (mirrors §6's same treatment).
    final revealSchedule = _drawSchedules[peerId];
    try {
      for (var i = 0; i < revealed.length; i++) {
        final proofWithRoot = MembershipProof(
          root: root,
          leafHex: revealedProofs[i].leafHex,
          siblings: revealedProofs[i].siblings,
          directions: revealedProofs[i].directions,
        );
        if (!proofWithRoot.verify()) {
          session.sendForfeit('bad_spell_reveal');
          throw StateError(
            'peer spell reveal entry ${revealed[i].commitmentHex} failed '
            'membership verification — match forfeit',
          );
        }
        if (revealSchedule != null &&
            !revealSchedule.isInHand(proofWithRoot.leafIndex)) {
          session.sendForfeit('bad_spell_reveal');
          throw StateError(
            'peer spell reveal entry ${revealed[i].commitmentHex} is not in '
            'their public in-hand set — match forfeit',
          );
        }
      }
    } on StateError {
      rethrow;
    } catch (_) {
      session.sendForfeit('bad_spell_reveal');
      throw StateError('peer spell reveal entry malformed — match forfeit');
    }

    return revealed;
  }

  /// Domain-separates the spell-reveal HKDF derivation by match and turn —
  /// mirrors [_scryHkdfInfo] with a distinct tag so the two exchanges never
  /// derive the same symmetric key even if somehow run with identical
  /// ephemeral keys.
  Uint8List _spellRevealHkdfInfo() => Uint8List.fromList([
    ...utf8.encode('RWSPELLREV1'),
    ...(matchId ?? const <int>[]),
    ..._be4(state.turnNumber),
  ]);

  // ── Action wire encoding / decoding ──────────────────────────────────────

  /// Encode a [TurnAction] to bytes for commitment hashing and wire transmission.
  ///
  /// When [localChapterCommitments] is set on this [TurnLoop], spell actions
  /// include a trailing proof tail:
  ///   [proof_len:4 BE][proof_bytes:N][merkle_depth:1][merkle_path:depth*(32+1)]
  /// The receiver must parse this tail when [withProof] is true in [_decodeAction].
  /// Appends the two summon fields: `[isSummon:1][personalityIndex:1]`.
  ///
  /// Without these a summon cast arrived at the opponent as an ordinary
  /// incantation — the caster spawned a creature, the verifier resolved
  /// formula effects, and the match forfeited on the turn's state hash. See
  /// M4_findings M4.16; peer_summon_replication_test.dart is the regression.
  ///
  /// The personality travels as a [SummonPersonality] **index**, not its name:
  /// one byte instead of a length-prefixed string, and it cannot carry an
  /// arbitrary value. The cost is that **the enum's declaration order is now
  /// wire-visible — never reorder or remove a case, only append.** Same rule
  /// the element order already lives under (CLAUDE.md).
  static void _appendSummonBytes(BytesBuilder buf, SpellAsset spell) {
    buf.addByte(spell.isSummon ? 1 : 0);
    final idx = SummonPersonality.values
        .indexWhere((p) => p.name == spell.summonPersonality);
    buf.addByte(idx < 0 ? SummonPersonality.aggressive.index : idx);
  }

  /// Reads what [_appendSummonBytes] wrote, tolerating a truncated buffer the
  /// same way every other field here does.
  static ({bool isSummon, String personality}) _readSummonBytes(
    Uint8List bytes,
    int pos,
  ) {
    final isSummon = pos < bytes.length && bytes[pos] == 1;
    final rawIdx = pos + 1 < bytes.length ? bytes[pos + 1] : 0;
    // An out-of-range index means a peer built by a version that appended a
    // personality this build does not have. Falling back keeps both devices
    // agreeing on SOMETHING rather than throwing, and the protocol-version
    // gate is what actually prevents the mismatch reaching here.
    final personality = rawIdx < SummonPersonality.values.length
        ? SummonPersonality.values[rawIdx].name
        : SummonPersonality.aggressive.name;
    return (isSummon: isSummon, personality: personality);
  }

  Uint8List _encodeAction(TurnAction action) {
    final buf = BytesBuilder();
    switch (action) {
      case PassAction():
        buf.addByte(0x00);

      case SpellCastAction(
        :final spell,
        :final targetHex,
        :final isPotent,
        :final isVelocity,
        :final isEfficiency,
        :final recall,
        :final conveyorDirection,
        :final handIndex,
      ):
        buf.addByte(0x01);
        buf.add(_hexToBytes(spell.commitmentHex));
        buf.add(_be2(spell.t));
        buf.add(_encodeCoord(targetHex));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(_be2(formulaBytes.length));
        buf.add(formulaBytes);
        final nameBytes = utf8.encode(spell.name);
        buf.add(_be2(nameBytes.length));
        buf.add(nameBytes);
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        buf.addByte(isEfficiency ? 1 : 0);
        buf.addByte(conveyorDirection != null ? 1 : 0);
        if (conveyorDirection != null) buf.add(_encodeCoord(conveyorDirection));
        _appendSummonBytes(buf, spell);
        _appendSpellProofTail(buf, spell, handIndex);
        if (isVocalComponents) _appendSorcererBytes(buf, recall);

      case DashAction():
        buf.addByte(0x04);

      case MeditateAction():
        buf.addByte(0x05);

      case MysterySpellCastAction(
        :final spell,
        :final mysteryCommitment,
        :final immediateTarget,
        :final immediateNonce,
        :final isPotent,
        :final isVelocity,
        :final recall,
        :final handIndex,
      ):
        buf.addByte(0x03);
        buf.add(_hexToBytes(spell.commitmentHex));
        buf.add(_be2(spell.t));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(_be2(formulaBytes.length));
        buf.add(formulaBytes);
        final nameBytes3 = utf8.encode(spell.name);
        buf.add(_be2(nameBytes3.length));
        buf.add(nameBytes3);
        buf.add(mysteryCommitment);
        final isImmediate = immediateTarget != null && immediateNonce != null;
        buf.addByte(isImmediate ? 1 : 0);
        if (isImmediate) {
          buf.add(_encodeCoord(immediateTarget));
          buf.add(immediateNonce);
        }
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        _appendSummonBytes(buf, spell);
        _appendSpellProofTail(buf, spell, handIndex);
        if (isVocalComponents) _appendSorcererBytes(buf, recall);
    }
    return buf.toBytes();
  }

  /// Appends [proof_len:4][proof_bytes:N][merkle_depth:1][path:depth*(32+1)] to
  /// [buf] for the given [spell], but only when [localChapterCommitments] is set.
  ///
  /// [handIndex], when known, proves the caster's OWN hand slot rather than
  /// searching the chapter for a matching commitment — the duplicate-safe
  /// form (docs/BASIC_SPELLS_PLAN.md §7). Null falls back to the commitment
  /// search, correct only when the chapter holds no duplicate of [spell].
  void _appendSpellProofTail(BytesBuilder buf, SpellAsset spell, int? handIndex) {
    final commitments = localChapterCommitments;
    if (commitments == null || spell.proofBytes.isEmpty) return;
    buf.add(_be4(spell.proofBytes.length));
    buf.add(spell.proofBytes);
    final position = _localCastPosition(spell, handIndex);
    final proof = position != null
        ? BookCommitment.proveMembershipAt(commitments, position)
        : null;
    if (proof == null || proof.siblings.isEmpty) {
      buf.addByte(0); // depth 0: leaf is the only node (single-spell chapter)
      return;
    }
    buf.addByte(proof.siblings.length);
    for (var i = 0; i < proof.siblings.length; i++) {
      buf.add(_hexToBytes(proof.siblings[i]));
      buf.addByte(proof.directions[i] ? 1 : 0);
    }
  }

  /// Appends the sorcerer recall suffix to [buf] for spell action payloads.
  ///
  ///   [recall bytes: 2 + spokenCount][suffixLen: 1]
  ///
  /// Variable length, unlike the fixed 3-byte VocalScore suffix it replaces —
  /// a recital is one opener plus up to 48 element words. The TRAILING length
  /// byte is what keeps the decoder's read-from-the-end structure working:
  /// the payload is parsed front-to-back for the spell and proof tail, so the
  /// suffix can only be located by measuring back from the end, which a
  /// variable-length blob cannot be without first knowing its size.
  ///
  /// Only slot INDICES cross the wire, never the words filling them
  /// (VOCAL_RECALL_PLAN.md §8.10.1) — a player's vocabulary never leaves
  /// their device.
  void _appendSorcererBytes(BytesBuilder buf, IncantationRecall? recall) {
    final bytes = (recall ?? IncantationRecall.silent).toWireBytes();
    buf.add(bytes);
    buf.addByte(bytes.length);
  }

  /// Reads the trailing recall suffix written by [_appendSorcererBytes].
  ///
  /// Returns null in wizard mode. A malformed suffix decodes to "no
  /// utterance" rather than throwing: every unreadable position scores as
  /// WRONG, so a corrupt recall can only cost the caster mana — there is
  /// nothing here worth forfeiting a match over.
  static IncantationRecall? _decodeSorcererSuffix(
      Uint8List bytes, bool isVocalComponents) {
    if (!isVocalComponents || bytes.isEmpty) return null;
    final suffixLen = bytes[bytes.length - 1];
    final start = bytes.length - 1 - suffixLen;
    if (suffixLen < 2 || start < 0) return IncantationRecall.silent;
    return IncantationRecall.fromWireBytes(bytes, start).recall;
  }

  /// Decode a [TurnAction] from [bytes] and optionally parse the trailing proof
  /// tail (present when the peer has [localChapterCommitments] set).
  ///
  /// Returns `({TurnAction action, MembershipProof? merkleProof})`. [merkleProof]
  /// is non-null only when [withProof] is true and a valid tail was found. The
  /// [root] field of the returned proof is left empty — [_verifyPeerSpellCast]
  /// fills it from [peerBookRoot] before calling [verify].
  static ({TurnAction action, MembershipProof? merkleProof}) _decodeAction(
    Uint8List bytes, {
    bool withProof = false,
    bool isVocalComponents = false,
  }) {
    // BUG FIX (found via SPELL_DRAW_WIRING_PLAN.md §10 item 4's test — a
    // pre-existing bug, dormant because every prior test used a single-spell
    // chapter, where BookCommitment.proveMembership has no siblings and
    // _appendSpellProofTail writes depth=0, never exercising this path):
    // [pos] here is ALREADY past the wire's [proof_len:4][proof_bytes:N]
    // segment — both call sites below decode that segment themselves first
    // (into decodedProofBytes/decodedProofBytes3) and pass the ADVANCED
    // [pos]. This function used to re-read another [proof_len:4] from that
    // already-advanced position and skip that many (garbage) bytes, which
    // for any REAL multi-spell chapter (nonzero merkle depth) blew past
    // [b.length] and made every merkleProof silently null — book-membership
    // and hand-membership (§6) checks were both unconditionally skipped
    // for any chapter with more than one spell. The tail format is
    // [proof_len:4][proof_bytes:N][merkle_depth:1][path...] — this function
    // only ever needs to read from merkle_depth onward.
    MembershipProof? parseProofTail(
      Uint8List b,
      int pos,
      String commitmentHex,
    ) {
      if (!withProof || pos >= b.length) return null;
      final depth = b[pos++];
      final siblings = <String>[];
      final directions = <bool>[];
      for (var d = 0; d < depth; d++) {
        if (pos + 33 > b.length) return null;
        final sib = b.sublist(pos, pos + 32);
        pos += 32;
        directions.add(b[pos++] == 1);
        siblings.add(
          '0x${sib.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}',
        );
      }
      if (siblings.length != depth) return null;
      return MembershipProof(
        root: '', // filled by _verifyPeerSpellCast
        leafHex: commitmentHex,
        siblings: siblings,
        directions: directions,
      );
    }

    if (bytes.isEmpty) return (action: PassAction(), merkleProof: null);
    final type = bytes[0];
    switch (type) {
      case 0x00:
        return (action: PassAction(), merkleProof: null);

      case 0x01:
        if (bytes.length < 1 + 32 + 2 + 4 + 2 + 2 + 3) {
          return (action: PassAction(), merkleProof: null);
        }
        int pos = 1;
        final commitBytes = bytes.sublist(pos, pos + 32);
        pos += 32;
        final t = _readBe2(bytes, pos);
        pos += 2;
        final q = _readInt16(bytes, pos);
        pos += 2;
        final r = _readInt16(bytes, pos);
        pos += 2;
        final formulaLen = _readBe2(bytes, pos);
        pos += 2;
        final formulaStr = pos + formulaLen <= bytes.length
            ? utf8.decode(bytes.sublist(pos, pos + formulaLen))
            : '';
        pos += formulaLen;
        final formula = formulaStr.isEmpty ? <String>[] : formulaStr.split(',');
        final nameLen = pos + 2 <= bytes.length ? _readBe2(bytes, pos) : 0;
        pos += 2;
        final name = pos + nameLen <= bytes.length
            ? utf8.decode(bytes.sublist(pos, pos + nameLen))
            : '';
        pos += nameLen;
        final commitmentHex =
            '0x${commitBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

        final isPotent01 = pos < bytes.length && bytes[pos++] == 1;
        final isVelocity01 = pos < bytes.length && bytes[pos++] == 1;
        final isEfficiency01 = pos < bytes.length && bytes[pos++] == 1;

        HexCoord? conveyorDirection01;
        if (pos < bytes.length) {
          final hasDir = bytes[pos++] == 1;
          if (hasDir && pos + 4 <= bytes.length) {
            conveyorDirection01 = _decodeCoord(bytes, pos);
            pos += 4;
          }
        }

        final summon01 = _readSummonBytes(bytes, pos);
        pos += 2;

        // Parse proof bytes from the tail (needed for verification).
        Uint8List decodedProofBytes = Uint8List(0);
        if (withProof && pos + 4 <= bytes.length) {
          final proofLen = _readBe4(bytes, pos);
          pos += 4;
          if (pos + proofLen <= bytes.length) {
            decodedProofBytes = bytes.sublist(pos, pos + proofLen);
          }
          pos += proofLen;
        }

        final spell = SpellAsset(
          id: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24,
          t: t,
          ownerPubkeyHex: '',
          manaCost: 0,
          segmentCount: 0,
          dotCount: 0,
          initialGrid: const [],
          proofBytes: decodedProofBytes,
          name: name,
          commitmentHex: commitmentHex,
          spellHashHex: '',
          formula: formula,
          // M4.16: without these the peer resolved a summon as an ordinary
          // incantation and the match desynced on the spot.
          isSummon: summon01.isSummon,
          summonPersonality: summon01.personality,
        );
        final merkle = parseProofTail(bytes, pos, commitmentHex);
        // [KEY STRUCTURAL CONSTRAINT — no local recalculation]
        // What the caster SAID is read verbatim from the trailing suffix. It
        // is NEVER recomputed from local audio: _decodeAction is a static
        // method holding no scorer reference, making local recalculation
        // structurally impossible, and the peer's microphone is unavailable to
        // this device anyway.
        //
        // What IS recomputed locally is the EXPECTED sequence, derived from the
        // certified trajectory (see _certifiedManaCost). That asymmetry is the
        // whole of the recall model: the claim is the caster's, the check is
        // ours. Pronunciation quality could never be checked this way, which is
        // why it was replaced.
        final recall01 = _decodeSorcererSuffix(bytes, isVocalComponents);
        return (
          action: SpellCastAction(
            spell: spell,
            targetHex: HexCoord(q, r),
            isPotent: isPotent01,
            isVelocity: isVelocity01,
            isEfficiency: isEfficiency01,
            recall: recall01,
            conveyorDirection: conveyorDirection01,
          ),
          merkleProof: merkle,
        );

      case 0x04:
        return (action: DashAction(), merkleProof: null);

      case 0x05:
        return (action: MeditateAction(), merkleProof: null);

      case 0x03:
        if (bytes.length < 1 + 32 + 2 + 2 + 2)
          return (action: PassAction(), merkleProof: null);
        int pos3 = 1;
        final spellCommit = bytes.sublist(pos3, pos3 + 32);
        pos3 += 32;
        final t3 = _readBe2(bytes, pos3);
        pos3 += 2;
        final formulaLen3 = _readBe2(bytes, pos3);
        pos3 += 2;
        final formulaStr3 = pos3 + formulaLen3 <= bytes.length
            ? utf8.decode(bytes.sublist(pos3, pos3 + formulaLen3))
            : '';
        pos3 += formulaLen3;
        final nameLen3 = pos3 + 2 <= bytes.length ? _readBe2(bytes, pos3) : 0;
        pos3 += 2;
        final name3 = pos3 + nameLen3 <= bytes.length
            ? utf8.decode(bytes.sublist(pos3, pos3 + nameLen3))
            : '';
        pos3 += nameLen3;
        if (pos3 + 32 + 1 > bytes.length)
          return (action: PassAction(), merkleProof: null);
        final mysteryCommit = bytes.sublist(pos3, pos3 + 32);
        pos3 += 32;
        final hasImmediate = bytes[pos3++] == 1;
        HexCoord? immTarget;
        Uint8List? immNonce;
        if (hasImmediate && pos3 + 4 + 16 <= bytes.length) {
          immTarget = _decodeCoord(bytes, pos3);
          pos3 += 4;
          immNonce = bytes.sublist(pos3, pos3 + 16);
          pos3 += 16;
        }
        final isPotent3 = pos3 < bytes.length && bytes[pos3++] == 1;
        final isVelocity3 = pos3 < bytes.length && bytes[pos3++] == 1;
        final summon3 = _readSummonBytes(bytes, pos3);
        pos3 += 2;

        Uint8List decodedProofBytes3 = Uint8List(0);
        final commitmentHex3 =
            '0x${spellCommit.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
        if (withProof && pos3 + 4 <= bytes.length) {
          final proofLen = _readBe4(bytes, pos3);
          pos3 += 4;
          if (pos3 + proofLen <= bytes.length) {
            decodedProofBytes3 = bytes.sublist(pos3, pos3 + proofLen);
          }
          pos3 += proofLen;
        }

        final spell3 = SpellAsset(
          id: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24,
          t: t3,
          ownerPubkeyHex: '',
          manaCost: 0,
          segmentCount: 0,
          dotCount: 0,
          initialGrid: const [],
          proofBytes: decodedProofBytes3,
          name: name3,
          commitmentHex: commitmentHex3,
          spellHashHex: '',
          formula: formulaStr3.isEmpty ? [] : formulaStr3.split(','),
          // M4.16, same as the immediate-cast branch: a delayed summon has to
          // survive the wire too, or it desyncs when it eventually fires.
          isSummon: summon3.isSummon,
          summonPersonality: summon3.personality,
        );
        final merkle3 = parseProofTail(bytes, pos3, commitmentHex3);
        // Same no-local-recalculation constraint as case 0x01 above.
        final recall03 = _decodeSorcererSuffix(bytes, isVocalComponents);
        return (
          action: MysterySpellCastAction(
            spell: spell3,
            mysteryCommitment: mysteryCommit,
            immediateTarget: immTarget,
            immediateNonce: immNonce,
            isPotent: isPotent3,
            isVelocity: isVelocity3,
            recall: recall03,
          ),
          merkleProof: merkle3,
        );

      default:
        return (action: PassAction(), merkleProof: null);
    }
  }

  /// Verify a peer spell cast (Option 3). Forfeits the match on failure.
  ///
  /// Checks (in order):
  ///   1. UltraHonk proof verifies and public [commitmentHex] matches the wire value.
  ///   2. No duplicate grid cast — same (verified [commitmentHex], T) twice
  ///      is a protocol violation — UNLESS this is one of the shipped Basic
  ///      spells (docs/BASIC_SPELLS_PLAN.md) or a CANTRIP (certified
  ///      trajectory under kKinshipMinElements, spell_identity.dart), either
  ///      of which a chapter may legitimately hold in unlimited copies, so
  ///      casting one more than once per match is not an exploit. Keyed on
  ///      VERIFIED proof outputs, not the wire `spell.commitmentHex`/`.t`/
  ///      `.formula` — see [isBasicGridAndT]'s header for why that
  ///      distinction matters at a trust boundary; the Cantrip check is on
  ///      the certified element sequence for the same reason.
  ///   3. Merkle membership proof is valid against [peerBookRoot].
  ///
  /// On success, populates [certifiedPeerFormulas] with the trajectory-derived
  /// [ParsedFormula] list for this spell, and [certifiedPeerElementSequences]
  /// with the flat certified element sequence (design doc "Summons" — the
  /// same trust boundary extended to creature summoning; see
  /// TrajectoryParser.certifiedElementSequence). [_resolveActions] reads
  /// these entries when calling [_applySpell], replacing the untrusted wire
  /// formula (B-1 fix).
  ///
  /// [forcedCast] marks a reveal the peer did not choose to make (wild magic's
  /// Spontaneous Combustion — see [ForcedCast]). It exempts the reveal from
  /// the duplicate-grid guard: a forced cast must not consume that player's
  /// once-per-match right to cast the grid, nor trip the duplicate forfeit.
  /// Everything else — proof verification, commitment-vs-wire, Merkle
  /// membership — applies unchanged.
  Future<void> _verifyPeerSpellCast(
    TurnAction action,
    MembershipProof? merkleProof,
    Map<String, List<ParsedFormula>> certifiedPeerFormulas,
    Map<String, List<BorderZone>> certifiedPeerElementSequences,
    Map<String, List<WildMagicTrigger>> certifiedPeerWildMagic, {
    bool forcedCast = false,
  }) async {
    final verify = verifyProof;
    final bookRoot = peerBookRoot;
    if (verify == null || (vkBytes == null && vkBytesForTier == null))
      return; // solo or verification not wired up

    final SpellAsset spell;
    final IncantationRecall? recall;
    if (action is SpellCastAction) {
      spell = action.spell;
      recall = action.recall;
    } else if (action is MysterySpellCastAction) {
      spell = action.spell;
      recall = action.recall;
    } else {
      return;
    }

    // 1. Proof verification.
    if (spell.proofBytes.isEmpty) {
      // DEV FLAG (kAllowProoflessSpells — lib/dev_flags.dart): let a Spell
      // Test Lab spell through so effects can be exercised on two devices.
      // Delete this branch along with the flag.
      //
      // Nothing is charged here, and [_deductManaForCommittedSpell] doesn't
      // charge on the caster's side either — see [_isProoflessBypass] for why
      // free-on-both-sides is the only option that can't desync.
      //
      // Nothing is written to [certifiedPeerFormulas], so [_applySpell] falls
      // back to `_parsedFormulas(spell)`: the wire formula, which is also what
      // the caster resolves from. Same source on both devices, so effects and
      // chain state agree. That fallback is exactly the TODO(B-1) hole this
      // flag leans on — closing that TODO means removing this flag first.
      //
      // Not mirrored, deliberately: the peer's draw state doesn't advance
      // (there's no Merkle proof saying which chapter slot was spent). Draw
      // state isn't part of [BattleState.toCanonicalBytes], so it can't
      // desync the match, but the opponent's view of the caster's hand will
      // drift and scrying a test-spell hand reads stale.
      if (allowProoflessSpells) return;
      session.sendForfeit('missing_spell_proof');
      throw StateError(
        'peer sent a spell cast with no proof bytes — match forfeit',
      );
    }
    // The tier this spell was PROVEN at, not the match's negotiated ceiling.
    // Getting this wrong is not a soft failure: the public-input count is
    // 10 + 2*tier_max (+8 for barretenberg's pairing-point object), so a
    // tier-12 proof checked against the tier-24 VK aborts in the backend with
    // "num_public_inputs mismatch with VK" (42 vs 66) and forfeits a duel that
    // was perfectly legal. Every cast whose T fell outside the match tier used
    // to break lockstep this way.
    final spellTier = _tierForSpell(spell.t);
    if (spellTier == null) {
      session.sendForfeit('invalid_spell_tier');
      throw StateError(
        'peer spell declares T=${spell.t}, outside the circuit range '
        '(1..$kMaxInscribableSteps) — match forfeit',
      );
    }
    final vk = _vkForTier(spellTier);
    if (vk == null) {
      session.sendForfeit('missing_vk_for_tier');
      throw StateError(
        'no bundled verification key for tier $spellTier — match forfeit',
      );
    }
    final VerifiedSpellOutputs outputs;
    try {
      outputs = await ProofIntake.verifyAndParse(
        spell.proofBytes,
        vk,
        verify,
        spellTier,
      );
    } on ProofIntakeException catch (e) {
      session.sendForfeit('invalid_spell_proof');
      throw StateError('peer spell proof rejected: $e');
    }
    // Binds the wire-declared T (which selected the VK and the parse layout)
    // to the T the proof actually attests. Without this a peer could steer
    // tier selection with a value nothing checked.
    if (outputs.t != spell.t) {
      session.sendForfeit('t_mismatch');
      throw StateError(
        'peer proof certifies T=${outputs.t} but the wire declared T=${spell.t}'
        ' — match forfeit',
      );
    }
    if (outputs.commitmentHex != spell.commitmentHex) {
      session.sendForfeit('commitment_mismatch');
      throw StateError(
        'peer proof commitmentHex ${outputs.commitmentHex} '
        'does not match wire value ${spell.commitmentHex} — match forfeit',
      );
    }
    // Binds the ruleset epoch the proof attests to the one this match
    // negotiated. [ProofIntake] has parsed `ruleset_version` since it was
    // added, but nothing read it: the field named itself a negotiated
    // consensus parameter while enforcing nothing.
    //
    // Defence-in-depth rather than a live hole — RULESET_VERSION is a circuit
    // global, so it is baked into each tier's verification key and a proof
    // under a different epoch cannot satisfy the bundled VK. That makes this
    // unreachable between honest clients on matched builds, which is exactly
    // why it must be explicit: the implicit guarantee evaporates the moment
    // two VKs are bundled, and a silent cross-epoch acceptance is the sort of
    // thing a version field exists to make impossible.
    if (outputs.rulesetVersion != state.config.rulesetVersion) {
      session.sendForfeit('ruleset_version_mismatch');
      throw StateError(
        'peer proof certifies ruleset_version ${outputs.rulesetVersion} but '
        'the match negotiated ${state.config.rulesetVersion} — match forfeit',
      );
    }

    // Recompute formula triplets from the SNARK-certified trajectory (B-1 fix).
    // Replaces the untrusted wire spell.formula for both mana-cost deduction and
    // effect resolution. Stored here; read by _resolveActions → _applySpell.
    //
    // Computed before the duplicate-grid check below because the Cantrip
    // exemption needs the CERTIFIED element count, not the peer-claimed
    // `spell.formula.length`.
    final certFormulas = TrajectoryParser.parse(outputs).formulas;
    certifiedPeerFormulas[spell.commitmentHex] = certFormulas;
    final certElementSequence = TrajectoryParser.certifiedElementSequence(outputs);
    certifiedPeerElementSequences[spell.commitmentHex] = certElementSequence;

    // 2. Duplicate grid detection — skipped for a shipped Basic spell or a
    // Cantrip (certified trajectory under kKinshipMinElements), either of
    // which may legitimately be cast more than once per match.
    if (!forcedCast &&
        !isBasicGridAndT(outputs.commitmentHex, outputs.t) &&
        !isCantripElementCount(certElementSequence.length) &&
        !_seenPeerCommitments.add(outputs.commitmentHex)) {
      session.sendForfeit('duplicate_spell_cast:${outputs.commitmentHex}');
      throw StateError(
        'peer cast the same grid twice — match forfeit '
        '(commitmentHex=${outputs.commitmentHex})',
      );
    }
    // Wild magic, same trust boundary (WILD_MAGIC_PLAN.md §4.6): derived from
    // the VERIFIED public outputs + the certified formulas, never from the
    // wire SpellAsset. The community seed comes from the agreed MatchConfig,
    // so both devices hash the same preimage.
    certifiedPeerWildMagic[spell.commitmentHex] = WildMagic.triggersFor(
      outputs,
      certFormulas,
      state.config.communitySeed,
    );
    // Retained for Sightings capture (docs/SIGHTINGS_PLAN.md §2/§4) — the
    // clean bestiary base cost, independent of this cast's modifiers. Read
    // by battle_screen.dart's capture hook after runTurn returns.
    lastCertifiedBaseManaCosts[spell.commitmentHex] =
        _certifiedBaseManaCost(outputs, certFormulas);

    // 2b. Enhancement-claim verification. isPotent/isVelocity/isEfficiency
    // (and Mystery, implied by the action type itself) must each be backed
    // by this spell's own certified supreme-dominance zones — a peer cannot
    // claim Efficiency's mana discount (or Potency/Velocity's effect
    // gating) on a spell that never achieved supreme dominance in the
    // matching zone.
    final certifiedTags = TrajectoryParser.certifiedSupremeTags(outputs);
    final claimsPotent = action is SpellCastAction
        ? action.isPotent
        : (action as MysterySpellCastAction).isPotent;
    final claimsVelocity = action is SpellCastAction
        ? action.isVelocity
        : (action as MysterySpellCastAction).isVelocity;
    final claimsEfficiency = action is SpellCastAction
        ? action.isEfficiency
        : false;
    final claimsMystery = action is MysterySpellCastAction;

    if ((claimsPotent && !certifiedTags.contains('fire')) ||
        (claimsVelocity && !certifiedTags.contains('air')) ||
        (claimsEfficiency && !certifiedTags.contains('water')) ||
        (claimsMystery && !certifiedTags.contains('earth'))) {
      session.sendForfeit('unbacked_enhancement_claim');
      throw StateError(
        'peer claimed a cast-time enhancement not backed by certified '
        'supreme-dominance data — match forfeit '
        '(commitmentHex=${spell.commitmentHex})',
      );
    }

    // 3. Book membership.
    if (bookRoot != null && merkleProof != null) {
      final proofWithRoot = MembershipProof(
        root: bookRoot,
        leafHex: merkleProof.leafHex,
        siblings: merkleProof.siblings,
        directions: merkleProof.directions,
      );
      if (!proofWithRoot.verify()) {
        session.sendForfeit('book_membership_failed');
        throw StateError(
          'peer spell ${spell.commitmentHex} is not a member of their committed book — match forfeit',
        );
      }

      // 3a. Hand membership (SPELL_DRAW_WIRING_PLAN.md §6). The Merkle path
      // just verified doesn't only prove chapter membership — its directions
      // authenticate *which* position was cast (proofWithRoot.leafIndex).
      // That position must be in the caster's publicly-computed in-hand set
      // and not withered. This is the "interim soft" enforcement §6 calls
      // for: correct against an honest client; a malicious client could
      // still forge an unsorted book tree (closed by the §7 sortedness
      // circuit, not yet landed). Skipped (not failed) when our own
      // DrawSchedule bookkeeping for the peer isn't dealt yet — a local
      // chapter-load race (see _dealOpeningHandsIfNeeded), not the peer's
      // fault.
      final schedule = _drawSchedules[_peerId()];
      if (schedule != null && !schedule.isCastable(proofWithRoot.leafIndex)) {
        session.sendForfeit('cast_out_of_hand');
        throw StateError(
          'peer spell ${spell.commitmentHex} at position ${proofWithRoot.leafIndex} '
          'is not in their castable hand — match forfeit',
        );
      }
    }

    // 3b. Cast authorization (BATTLE_AUTH_PLAN.md §4). The proof declares an
    // owner_pubkey (outputs.ownerPubkeyHex), but per CLAUDE.md invariant 5 the
    // circuit never proves the caster holds that key — a proof alone can
    // declare any owner. [peerOwnerPubkeyHex] is the peer's *authenticated*
    // identity (verified via a fresh-nonce Ed25519 signature at handshake —
    // see BattleSession.exchangeIdentityAuth), so this check is what actually
    // stops a peer casting a spell they neither own nor hold a grant for.
    // Null in solo/test (no authenticated peer to check against — skip).
    final authenticatedPeerPubkeyHex = peerOwnerPubkeyHex;
    if (authenticatedPeerPubkeyHex != null) {
      final authorized = await castingPlayerMayUse(
        spellOwnerPubkeyHex: outputs.ownerPubkeyHex,
        commitmentHex: outputs.commitmentHex,
        t: outputs.t,
        castingPlayerPubkeyHex: authenticatedPeerPubkeyHex,
        permissions: peerPermissions,
      );
      if (!authorized) {
        session.sendForfeit('unauthorized_spell:${outputs.commitmentHex}');
        throw StateError(
          'peer cast a spell they neither own nor hold a grant for '
          '(owner=${outputs.ownerPubkeyHex}, caster=$authenticatedPeerPubkeyHex) '
          '— match forfeit',
        );
      }
    }

    // 4. Mana cost verification from proof public outputs (B-1 + B-8 fix).
    // Base cost is certified by the SNARK (5×segmentCount + dotCount).
    // effectCount, chain discount, sorcerer multiplier, and nextSpellCostDouble
    // all come from _certifiedManaCost — no untrusted wire values — so both
    // devices deduct the same amount and the mana ledger stays consistent.
    //
    // Skipped entirely for a FORCED cast (wild magic's Spontaneous
    // Combustion): it is free by definition, so charging for it would drain
    // mana the caster never chose to spend — and worse, the shortfall check
    // would forfeit the match against a player who simply happened to be
    // holding an expensive spell they were never given the option to not cast.
    final peerId = _peerId();
    final peerAvatar = peerId != null ? _avatarById(peerId) : null;
    if (peerAvatar != null && !forcedCast) {
      final verifiedCost = _certifiedManaCost(
        outputs,
        certFormulas,
        peerAvatar,
        recall: recall,
        isEfficiency: claimsEfficiency,
        isSummon: spell.isSummon,
        certElementSequence: certElementSequence,
      );
      // A peer who can't pay FIZZLES; it is not a forfeit any more.
      //
      // This used to end the match on `insufficient_mana_for_spell`. That was
      // aimed at a desync rather than a cheat — the caster's deduction clamped
      // at zero and played on while this device stopped — and it is a wildly
      // disproportionate answer to a move that wins its caster nothing. Both
      // devices now price the cast from the same certified inputs and reach
      // the same verdict, so the desync it guarded against cannot happen, and
      // nothing has to be transmitted to keep them agreed.
      //
      // Sorcerer mode makes a shortfall genuinely routine besides: recall can
      // inflate a cost after the player has committed, and previewSpellCost
      // deliberately quotes the honest base price rather than a worst case.
      if (_fizzlesForMana(peerAvatar, verifiedCost)) {
        _markFizzledForMana(action);
      } else {
        peerAvatar.mana = (peerAvatar.mana - verifiedCost).clamp(0, _kMaxMana);
      }
    }
  }

  // ── Mana cost ─────────────────────────────────────────────────────────────

  /// Compute mana cost from SNARK-certified outputs and certified formula list.
  ///
  /// Operation order mirrors [_spellManaCost] exactly so both the local and
  /// verifier paths apply the same modifiers in the same sequence:
  ///   1. Certified base: 5×segmentCount + dotCount, grown by 1.05^T × 1.5^effectCount.
  ///   2. Chain discount from [certFormulas] (trusted; replaces wire spell.formula).
  ///   3. Efficiency (Water) discount: −1/3, gated on [isEfficiency] (verified by the
  ///      caller against certified supreme-tags — see TrajectoryParser.certifiedSupremeTags).
  ///   4. Recall multiplier from the transmitted [recall] (committed in the action
  ///      hash), scored against the EXPECTED recital both clients derive from the
  ///      certified trajectory. Exact integer arithmetic — see incantation_recall.dart.
  ///   5. nextSpellCostDouble: consume + double + HP shortfall. Both clients execute this
  ///      identically, keeping the status-effect list and state hash in sync.
  ///
  /// NOTE(B-1, balance): certified effectCount is tighter than the wire formula for spells
  /// with residual activations. Example: 4 activations = 1 complete formula + 1 residual;
  /// wire gives effectCount=1 (floor((4-1)÷3)=1), certified gives effectCount=0
  /// (max(0,1-1)=0). The certified count is the correct trust boundary — the wire count
  /// was exploitable by padding the formula list.
  /// Certified base mana cost: 5×segmentCount + dotCount, grown by
  /// 1.05^T × 1.5^effectCount — step 1 of [_certifiedManaCost]'s modifier
  /// chain, factored out so it can't drift from the value Sightings capture
  /// stores (docs/SIGHTINGS_PLAN.md §2, "the clean bestiary stat" — every
  /// later step is a per-cast modifier, not intrinsic to the spell).
  int _certifiedBaseManaCost(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certFormulas,
  ) {
    final base = 5 * outputs.segmentCount + outputs.dotCount;
    final effectCount = max(0, certFormulas.length - 1);
    return (base * pow(1.05, outputs.t) * pow(1.5, effectCount)).round();
  }

  int _certifiedManaCost(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certFormulas,
    WizardAvatar caster, {
    IncantationRecall? recall,
    bool isEfficiency = false,
    bool isSummon = false,
    List<BorderZone>? certElementSequence,
  }) {
    // 1. Certified base + growth.
    var cost = _certifiedBaseManaCost(outputs, certFormulas);

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
          : _pureAffinityOf(certFormulas);
      cost = (cost * caster.chainCostMultiplier(pureAffinity)).ceil();
    }

    // 3. Efficiency (Water) loadout enhancement: −1/3 mana cost. [isEfficiency]
    // has already been verified against this spell's certified supreme-tags
    // by _verifyPeerSpellCast before reaching here — see
    // TrajectoryParser.certifiedSupremeTags. Mirrors _spellManaCost's step,
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
    // it — see _deductManaForCommittedSpell. Null reaches this only from
    // previewSpellCost, which must quote the honest base price because no
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

  /// Step 1 of [_spellManaCost], written to be the exact local mirror of
  /// [_certifiedBaseManaCost]: same inputs, same operations, same order.
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
  /// `_parsedFormulas(spell).length == certFormulas.length` for an honest
  /// spell; a dishonest one still loses, because the opponent charges the
  /// certified amount regardless and the state hash catches the difference.
  int _wireBaseManaCost(SpellAsset spell) {
    final base = 5 * spell.segmentCount + spell.dotCount;
    final effectCount = max(0, _parsedFormulas(spell).length - 1);
    return (base * pow(1.05, spell.t) * pow(1.5, effectCount)).round();
  }

  /// Charge [caster] for casting [spell]: the cost, *and* the state changes
  /// that pricing it implies (a consumed chainSurcharge, a consumed
  /// nextSpellCostDouble, the HP damage its shortfall converts to).
  ///
  /// The arithmetic lives in [_spellCostBreakdown] so [previewSpellCost] can
  /// ask "what would this cost?" without charging for it. Do not reintroduce a
  /// second copy of the formula here — the UI gate and the deduction must
  /// agree to the mana, or the player is offered casts that then fizzle for
  /// want of it (see [_fizzlesForMana]).
  int _spellManaCost(
    SpellAsset spell,
    WizardAvatar caster, {
    CastingEnhancements? enhancements,
    IncantationRecall? recall,
  }) {
    final b = _spellCostBreakdown(spell, caster,
        enhancements: enhancements, recall: recall);

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
  /// Operation order is the same as [_certifiedManaCost]'s — see its doc
  /// comment for the numbered steps and why the two must not drift. What this
  /// returns beyond the cost is everything the charging path has to *apply*:
  /// [hpDamage] to absorb, and the indices into [caster]'s current
  /// `activeStatusEffects` of the chainSurcharge / nextSpellCostDouble entries
  /// this cast consumes (-1 when absent).
  ({int cost, int hpDamage, int surchargeIdx, int doubleIdx})
  _spellCostBreakdown(
    SpellAsset spell,
    WizardAvatar caster, {
    CastingEnhancements? enhancements,
    IncantationRecall? recall,
  }) {
    // 1. Base + growth — mirrors _certifiedManaCost step 1.
    var cost = _wireBaseManaCost(spell);

    // Chain: a pending chainSurcharge (potent Air-flavor Chain Interaction)
    // overrides the ordinary chain lookup for this one cast, regardless of
    // affinity — mirrors _certifiedManaCost's step 2, same relative
    // position. Reported back for [_spellManaCost] to consume, so it doesn't
    // also fire in _updateChainState's normal advancement afterward.
    final surchargeIdx = caster.activeStatusEffects.indexWhere(
      (fx) => fx.effectTypeId == StatusEffectId.chainSurcharge,
    );
    if (surchargeIdx >= 0) {
      cost = (cost * pow(0.9, -1)).ceil();
    } else {
      final pureAffinity = spell.isSummon
          ? CreatureSpec.fromElements(_elementSequence(spell))?.affinity
          : _pureAffinityOf(_parsedFormulas(spell));
      cost = (cost * caster.chainCostMultiplier(pureAffinity)).ceil();
    }

    // Efficiency (Water) loadout enhancement: −1/3 mana cost. Applied after
    // chain discount, before the sorcerer multiplier — see _certifiedManaCost
    // for the mirrored step at the same relative position.
    if (enhancements?.isEfficiency ?? false) {
      cost = (cost * 2 / 3).ceil();
    }

    // Recall multiplier — the local mirror of _certifiedManaCost step 4, at
    // the same relative position (after the chain and Efficiency discounts, so
    // a shaky recital inflates the already-discounted cost).
    //
    // Reads the LOCAL element sequence where the certified path reads the
    // certified one. That is the same trust split every step here already
    // uses: this path prices the caster's own cast, and the certified path is
    // what the peer charges them.
    //
    // Null means "not spoken yet" here, and prices at base — that is
    // previewSpellCost's path. The charging path never passes null; see
    // _deductManaForCommittedSpell.
    if (isVocalComponents && recall != null) {
      cost = recall
          .tallyAgainst(
            expectedIsSummon: spell.isSummon,
            expectedElements: expectedRecitalSlots(_elementSequence(spell)),
          )
          .applyTo(cost);
    }

    // nextSpellCostDouble status effect: double the cost (and report the
    // effect back for [_spellManaCost] to consume).
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
      // returned here is never above `caster.mana`, and [canAffordSpell]
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

  // ── Cost preview (UI affordability gate) ──────────────────────────────────

  /// What casting [spell] would cost the local avatar **right now**, without
  /// charging for it or consuming anything. The UI's affordability gate and
  /// its cost readout both read this.
  ///
  /// In sorcerer mode the recall multiplier isn't knowable until after the
  /// incantation, which happens *after* the player commits — so this quotes the
  /// HONEST base price and lets an unaffordable outcome fizzle-and-refund
  /// (VOCAL_RECALL_PLAN.md §4).
  ///
  /// That is a deliberate reversal. This used to quote a 1.5× worst case, for
  /// one reason only: a cast the gate approved at 1.0× and the peer forfeited
  /// over at 1.5× would read as a desync. Making a shortfall a legal, refunded
  /// fizzle removes that failure mode, and with it the reason to quote a price
  /// nobody pays — §4 retires `maxManaCostMultiplier` on exactly this
  /// argument. Quoting the honest price also means the number the player reads
  /// is the number a clean recital charges.
  ///
  /// Returns 0 for a proofless dev-flag spell — those are free on both devices
  /// (see [_isProoflessBypass]).
  int previewSpellCost(
    SpellAsset spell, {
    bool isPotent = false,
    bool isVelocity = false,
    bool isEfficiency = false,
  }) {
    if (_isProoflessBypass(spell)) return 0;
    final enhancements = CastingEnhancements(
      isPotent: isPotent,
      isVelocity: isVelocity,
      isEfficiency: isEfficiency,
      gameMode: _componentsGameMode,
    );
    return _spellCostBreakdown(
      spell,
      _localAvatar(),
      enhancements: enhancements,
    ).cost;
  }

  /// Whether the local avatar can pay for [spell] this turn.
  ///
  /// This is the client-side mirror of [_fizzlesForMana]: casting anyway is no
  /// longer a forfeit, but it does waste the turn, so the UI should not offer
  /// it. Casting anyway isn't a local
  /// nuisance that resolves for less — the caster's own deduction clamps at 0
  /// and plays on while the *opponent's* device forfeits the match, which
  /// reads as a desync. Gate the cast in the UI instead.
  ///
  /// A pending nextSpellCostDouble makes every cast affordable by definition
  /// (the shortfall is converted to HP damage rather than refused), and that
  /// falls out of [previewSpellCost] without a special case here.
  bool canAffordSpell(
    SpellAsset spell, {
    bool isPotent = false,
    bool isVelocity = false,
    bool isEfficiency = false,
  }) =>
      previewSpellCost(
        spell,
        isPotent: isPotent,
        isVelocity: isVelocity,
        isEfficiency: isEfficiency,
      ) <=
      _localAvatar().mana;

  // ── Game state helpers ────────────────────────────────────────────────────

  WizardAvatar _localAvatar() => state.avatars.firstWhere(
    (av) => av.playerId == localPlayerId,
    orElse: () =>
        throw StateError('local player $localPlayerId not found in state'),
  );

  WizardAvatar? _avatarById(String id) => _resolution.avatarById(id);

  String? _peerId() => state.avatars
      .where((av) => av.playerId != localPlayerId)
      .map((av) => av.playerId)
      .firstOrNull;

  List<WizardAvatar> _avatarsAt(HexCoord hex) =>
      state.avatars.where((av) => av.isAlive && av.position == hex).toList();

  List<Minion> _minionsAt(HexCoord hex) =>
      state.minions.where((m) => m.isAlive && m.position == hex).toList();

  static bool _isAdjacent(HexCoord a, HexCoord b) =>
      DeterministicResolution.isAdjacent(a, b);

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

  /// Adjacent tiles holding at least one living hostile entity (enemy avatar
  /// or minion) — the melee-round prompt candidates for [actor]. Empty means
  /// no prompt is shown (see [MeleeTargetPicker]).
  List<HexCoord> _meleeCandidates(WizardAvatar actor) {
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

  /// Water-Air Illusions (Water flavor), melee-punch path: if [target] has
  /// active wizard decoys, roll 1/remaining -- on a hit the real wizard takes
  /// it (returns false); otherwise a random decoy is destroyed and the punch
  /// is fully absorbed (returns true) — **nothing else happens**: no damage,
  /// no position change, no haymaker side effect (slow/DoT/status-drain).
  /// The decoy dies regardless; the real wizard is untouched, full stop.
  ///
  /// Diverged from [EffectApplicator._resolveIllusionRedirect] (2026-07-31):
  /// the formula-effect path still teleports the target onto the decoy's tile
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

  /// [_freeMoveCandidates] for the avatar with [playerId] — the legal first
  /// steps of a free-move run, for BattleScreen's prompt highlight. Empty for
  /// an unknown or dead player.
  List<HexCoord> freeMoveCandidatesFor(String playerId) {
    final av = _avatarById(playerId);
    return av == null ? const [] : _freeMoveCandidates(av);
  }

  /// Adjacent tiles a post-resolution free-move run may step onto: in
  /// bounds, not [ImpassableTile], and unoccupied by any living avatar or
  /// minion. Mirrors the footprint check in [_findCreatureSpawnTile].
  List<HexCoord> _freeMoveCandidates(WizardAvatar actor) {
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
  /// [_applyHaymaker]'s adjacency check): the grant is re-derived from state
  /// via [freeMoveGrantFor] rather than taken from the peer's message, so a
  /// peer can neither claim a burst it didn't earn nor walk further than it
  /// can pay for. An over-long or illegal path is walked as far as it is legal
  /// and priced on that, never rejected wholesale — the two devices run this
  /// same truncation on the same state and land on the same answer.
  ///
  /// [rng] resolves the terrain the walk crosses (ice slides, closed conveyor
  /// loops); it is phase-seeded by the caller so both devices roll alike.
  void _applyFreeMove(WizardAvatar av, List<HexCoord> declaredPath, HashRng rng) {
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

  /// One free-move commit-reveal round: prompt the local player if they have a
  /// grant (an Airy Barrier burst, a Boost, or both), exchange with the peer,
  /// apply and charge both runs, then clear the one-shot grants so they can
  /// never roll into a later window.
  ///
  /// Called twice per turn — Phase 5.5 (spell-resolution bursts and Boosts)
  /// and Phase 6.5 (end-of-turn bursts). Both calls run unconditionally,
  /// encoding "no move" when nobody qualifies, so the frame sequence is
  /// identical on both clients regardless of who burst what. That fixed shape
  /// is what makes the second round safe on the wire:
  /// [BattleFrameReader.framesOfType] is a per-type FIFO queue that buffers
  /// rather than drops, so round 2 consumes round 2's frame even if it arrived
  /// while round 1 was still resolving.
  Future<void> _runFreeMoveRound(String? peerId, HashRng rng) async {
    final localGrant = freeMoveGrantFor(_localAvatar());
    final hasSomewhereToGo = _freeMoveCandidates(_localAvatar()).isNotEmpty;
    final localPath = (localGrant.isEmpty || !hasSomewhereToGo)
        ? null
        : await freeMoveDirectionPicker(localGrant);
    final nonce = _commitNonce(_kRevealNonceBytes);
    final bytes = _encodePath(localPath ?? const []);
    final commit = await Sha256()
        .hash(Uint8List.fromList([...bytes, ...nonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerCommit = await session.exchangeFreeMoveCommit(commit);

    final myReveal = Uint8List.fromList([...nonce, ...bytes]);
    final peerReveal = await session.exchangeFreeMoveReveal(myReveal);
    await _verifyReveal(peerReveal, peerCommit, 'freeMove');
    final peerPath = _decodePath(peerReveal, _kRevealNonceBytes);

    // Local first, then peer, on both devices — the order matters because the
    // second walk sees the first one's occupancy.
    if (localPath != null && localPath.isNotEmpty) {
      _applyFreeMove(_localAvatar(), localPath, rng);
    }
    if (peerId != null && peerPath.isNotEmpty) {
      final peerAvatar = _avatarById(peerId);
      if (peerAvatar != null) {
        _applyFreeMove(peerAvatar, peerPath, rng);
      }
    }
    // One-shot opportunity: clear regardless of whether it was used, so it
    // never rolls over to a later window or a later turn.
    for (final av in state.avatars) {
      av.pendingFreeMoveBurst = false;
      av.pendingBoostMove = null;
      av.pendingBoostFreeTiles = 0;
    }
    // A burst step or a Boost run can end beside an enemy illusion too.
    _dispelIllusionsNearScryers();
  }

  /// Earthen Scrying Pool's dispel-on-sight sweep
  /// ([EffectApplicator.dispelIllusionsNearScryers]). RNG-free and
  /// idempotent, so it is simply re-run after every phase that can change
  /// who stands next to what — movement, action resolution, the summons
  /// step, both free-move windows, and end of turn — rather than every
  /// individual mover having to remember it.
  void _dispelIllusionsNearScryers() =>
      EffectApplicator.dispelIllusionsNearScryers(state);

  List<HexCoord> _neighbors(HexCoord h) => state.battlefield.neighbors(h);

  void _addStatus(
    WizardAvatar av,
    String typeId,
    Map<String, int> mods,
    int turns,
  ) => _resolution.addStatus(av, typeId, mods, turns);

  // ── Formula helpers ───────────────────────────────────────────────────────

  static List<ParsedFormula> _parsedFormulas(SpellAsset spell) {
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
  /// by [_updateChainState] and [_spellManaCost]/[_certifiedManaCost] so
  /// "pure" can't drift between the advancement and discount paths.
  static SpellAffinity? _pureAffinityOf(List<ParsedFormula> formulas) {
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
  /// spell -- unlike [_parsedFormulas], residuals are kept (see
  /// CreatureSpec.fromElements: every activation counts toward a creature).
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

  static List<BorderZone> _elementSequence(SpellAsset spell) =>
      spell.formula.map(_zoneFromName).whereType<BorderZone>().toList();

  // ── Wire helpers ──────────────────────────────────────────────────────────

  /// Encode a move path as [count:1][q:2][r:2]… (4 bytes per coord).
  static Uint8List _encodePath(List<HexCoord> path) {
    final buf = BytesBuilder();
    buf.addByte(path.length.clamp(0, 255));
    for (final h in path) {
      buf.add(_encodeCoord(h));
    }
    return buf.toBytes();
  }

  /// Decode a move path from [data] starting at [offset].
  /// Format: [count:1][q:2][r:2]… Returns empty list on underflow.
  static List<HexCoord> _decodePath(Uint8List data, int offset) {
    if (offset >= data.length) return const [];
    final count = data[offset];
    final path = <HexCoord>[];
    var pos = offset + 1;
    for (var i = 0; i < count; i++) {
      if (pos + 4 > data.length) break;
      path.add(_decodeCoord(data, pos));
      pos += 4;
    }
    return path;
  }

  /// Encode the movement-phase payload: [isDashing:1][meditateInMove:1]
  /// followed by [_encodePath]'s bytes. See this file's header comment for
  /// why Dash/Meditate flags travel with movement rather than the action.
  static Uint8List _encodeMovePayload({
    required bool isDashing,
    required bool meditateInMove,
    required List<HexCoord> path,
  }) {
    final buf = BytesBuilder();
    buf.addByte(isDashing ? 1 : 0);
    buf.addByte(meditateInMove ? 1 : 0);
    buf.add(_encodePath(path));
    return buf.toBytes();
  }

  /// Decode a movement-phase payload from [data] starting at [offset].
  /// When [meditateInMove] is true, [path] is forced empty regardless of
  /// what was transmitted (defence-in-depth against a modified peer).
  static ({bool isDashing, bool meditateInMove, List<HexCoord> path})
  _decodeMovePayload(Uint8List data, int offset) {
    if (offset + 2 > data.length) {
      return (
        isDashing: false,
        meditateInMove: false,
        path: const <HexCoord>[],
      );
    }
    final isDashing = data[offset] == 1;
    final meditateInMove = data[offset + 1] == 1;
    final path = meditateInMove
        ? const <HexCoord>[]
        : _decodePath(data, offset + 2);
    return (isDashing: isDashing, meditateInMove: meditateInMove, path: path);
  }

  /// Encode an optional target tile — [0x00] = none, [0x01][q:2][r:2] = that
  /// tile. The resolution-phase melee choice; the post-resolution free-move
  /// choice used to share this shape but now carries a whole path (a Boost run
  /// can be several tiles long) and rides [_encodePath] instead, where an
  /// empty path is the "stand fast" encoding.
  static Uint8List _encodeOptionalTarget(HexCoord? target) {
    if (target == null) return Uint8List.fromList([0x00]);
    final buf = BytesBuilder();
    buf.addByte(0x01);
    buf.add(_encodeCoord(target));
    return buf.toBytes();
  }

  /// Decode an optional target tile from [data] starting at [offset].
  static HexCoord? _decodeOptionalTarget(Uint8List data, int offset) {
    if (offset >= data.length || data[offset] != 0x01) return null;
    if (offset + 5 > data.length) return null;
    return _decodeCoord(data, offset + 1);
  }

  static Uint8List _encodeCoord(HexCoord h) => Uint8List(4)
    ..[0] = (h.q >> 8) & 0xFF
    ..[1] = h.q & 0xFF
    ..[2] = (h.r >> 8) & 0xFF
    ..[3] = h.r & 0xFF;

  static HexCoord _decodeCoord(Uint8List data, int offset) =>
      HexCoord(_readInt16(data, offset), _readInt16(data, offset + 2));

  static int _readInt16(Uint8List data, int offset) {
    final u = (data[offset] << 8) | data[offset + 1];
    return u >= 0x8000 ? u - 0x10000 : u;
  }

  static int _readBe2(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int _readBe4(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  static Uint8List _be2(int v) => Uint8List(2)
    ..[0] = (v >> 8) & 0xFF
    ..[1] = v & 0xFF;

  static Uint8List _be4(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  static Uint8List _hexToBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final result = Uint8List(s.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
