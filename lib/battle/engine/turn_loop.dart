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
// ── Where the bytes live ─────────────────────────────────────────────────────
//
// Every wire encoding this file used to spell out now lives in
// `battle_wire_codec.dart`, one small class per message, each carrying the
// field-order spec it implements: `ActionWire` (the main-phase action, its
// proof tail, its recall suffix and its split-leaf commitment preimage),
// `MoveWire`, `MeleeWire`, `ArtifactActivationWire`, `DelayedRevealWire`,
// `StateHashWire`, and the two divination exchanges' framing
// (`SealedExchangeFrames`, `ScryWire`, `SpellRevealWire`).
//
// What stays here is everything the codec deliberately does not do: the order
// the exchanges happen in, what is committed before what is revealed, which
// peer claims get verified and against what, and what happens to the match
// when one fails. The codec answers "what value do these bytes represent";
// this file answers "should we believe it, and what do we do next".
//
// The commit/reveal envelope itself — commit = SHA-256(payload ‖ nonce),
// reveal = nonce(16) ‖ payload — stays here too, because it is one line at
// each phase's exchange and inseparable from the sequencing around it. The
// action phase is the exception in shape as well as ownership: it commits to
// a two-leaf split (see `ActionWire.splitActionCommit`) so a Divination can
// open the target leaf early, and so its reveal is saltA(16) ‖ saltB(16) ‖
// payload.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/spells/spell_permission.dart';

import '../models/battle_state.dart';
import '../models/casting_enhancements.dart';
import '../models/certified_cast.dart';
import '../models/component_order.dart';
import '../models/pending_delayed_spell.dart';
import '../models/divination_link.dart';
import '../models/effect_descriptor.dart'; // exports SpellAffinity, spellAffinityFromZone
import '../models/hex_battlefield.dart' show hexDistance;
import '../models/wizard_avatar.dart';
import '../networking/battle_session.dart';
import '../../identity/identity.dart';
import '../../identity/key_packing.dart' show compareCanonicalPubkeyHex;
import '../../protocol/match_session.dart' show ProofVerifier;
import 'battle_events.dart';
import 'battle_wire_codec.dart';
import 'book_commitment.dart';
import 'commit_reveal.dart';
import 'deterministic_resolution.dart';
import 'draw_schedule.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'peer_cast_verifier.dart';
import 'proof_intake.dart';
import 'spell_draw.dart';
import 'tile_entry_resolver.dart';
import 'turn_actions.dart';
import 'wild_magic_applicator.dart';
import 'forced_cast.dart';
import '../../sorcerer/incantation_recall.dart';

// AvatarMoveEvent, MinionMoveEvent and AttackEvent moved to battle_events.dart
// so the deterministic seam can emit them without importing this file.
// Re-exported so every existing `import '.../turn_loop.dart'` naming them
// keeps compiling.
export 'battle_events.dart';

// FreeMoveGrant (and the Boost price constant it is quoted in) moved to the
// deterministic seam alongside the operations that derive them. Re-exported so
// every existing `import '.../turn_loop.dart'` naming them keeps compiling —
// BattleScreen holds a TurnLoop and prices its free-move preview off this.
export 'deterministic_resolution.dart'
    show FreeMoveGrant, kActivatableArtifactKinds, kBoostManaPerTile;

// The TurnAction hierarchy and the two events action resolution emits moved to
// turn_actions.dart, so deterministic_resolution.dart can name them without
// importing this file — the same split battle_events.dart made. Re-exported so
// every existing `import '.../turn_loop.dart'` naming them keeps compiling.
export 'turn_actions.dart';

// The battle protocol's serialization boundary moved to battle_wire_codec.dart
// — every encoder, decoder and framing rule, with no trust decision among
// them. Re-exported so `kStateHashSignatureTag` (and the codecs themselves,
// for anyone hand-building a frame) stay reachable through this file.
export 'battle_wire_codec.dart';

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


// AvatarMoveEvent, MinionMoveEvent and AttackEvent live in battle_events.dart
// (re-exported above) so the deterministic seam can emit them without
// importing this file.

// ── Turn phase enum ───────────────────────────────────────────────────────────

enum TurnPhase {
  summons,
  actionCommit,
  movement,
  actionResolve,
  endOfTurn,
  winCheck,
}

// ── Phase-5 cast settlement (M4.10b) ──────────────────────────────────────────

/// One committed cast, waiting to be priced and paid for at Phase 5.
///
/// [settle] prices the cast against the state as it stands when it is called
/// and applies everything that pricing implies — the mana, a consumed
/// chainSurcharge or nextSpellCostDouble, the HP a shortfall converts to, or
/// the fizzle mark if it can no longer be paid for at all.
///
/// **There is deliberately no "certified?" flag on this record.** The closure is
/// built by the site that already knows which of the two pricing mirrors this
/// cast belongs to: [TurnLoop._localCastSettlement] prices the caster's own
/// spell from its own [SpellAsset], and [TurnLoop._certifiedPeerCastSettlement]
/// prices a peer's from verified proof outputs. A settlement record carrying
/// "use certified semantics: true/false" would be precisely the generic branch
/// B-1/B-8 closed — one flag away from letting an untrusted caller select the
/// trusted path. The two mirrors meet here as opaque closures and nowhere else;
/// see deterministic_resolution.dart's "Mana cost" section header.
typedef _CastSettlement = ({String playerId, void Function() settle});

// ── TurnLoop ──────────────────────────────────────────────────────────────────

// Wire spec: action/move reveal format is nonce(_kRevealNonceBytes) ‖ payload.
// All sites — nonce generation (.sublist(0, _kRevealNonceBytes)), reveal
// construction, skip-offset on receipt, and _verifyReveal — must use this
// constant; do not change one in isolation.
const _kRevealNonceBytes = 16;

// Maximum mana value — avatars are clamped to [0, _kMaxMana] after every
// spend or gain. Mirrored by deterministic_resolution.dart's constant of the
// same name, which is where the two pricing mirrors now clamp.
const _kMaxMana = 9999;

/// Mana restored by a single Meditate choice (main phase or move phase).
/// Taking both in the same turn grants 2 × this amount — see
/// [TurnInput.meditateInMove] and [MeditateAction].
// Meditate's payout moved to the deterministic seam with the action phase
// that spends it; the move-phase Meditate below still reads it.

// The Counter Charm proc rate moved to the deterministic seam with the melee
// application it prices (deterministic_resolution.dart, "Phase 4b").

// The Rod of Wind's per-rod movement chance moved to the deterministic seam
// with the roll it prices (deterministic_resolution.dart, "Phase 0").


/// Asks the local UI which adjacent tile (if any) to melee this turn, given
/// the list of adjacent tiles that hold at least one living hostile entity.
/// [candidates] is always non-empty when this is called — [TurnLoop] only
/// invokes it for a player who actually has a valid target (design: "pass
/// and make no melee attack" is the implicit choice for everyone else, with
/// no prompt shown at all). Return null to decline.
typedef MeleeTargetPicker =
    Future<HexCoord?> Function(List<HexCoord> candidates);

Future<HexCoord?> _defaultNoMelee(List<HexCoord> candidates) async => null;

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

// `kActivatableArtifactKinds` — which loadout artifacts may be declared at
// Phase 0 — moved to the deterministic seam with the validation that reads it
// (deterministic_resolution.dart, "Phase 0"), and is re-exported above for the
// UI, which long-presses against the same list.

/// Both players' settled Phase-0 declarations for one turn — what
/// [TurnLoop.beginArtifactPhase] returns and [TurnLoop.lastArtifactActivations]
/// holds.
///
/// Post-validation: a field is non-null only if that player really held the
/// declared artifact (see [DeterministicResolution.validateActivation]), so the
/// UI can render
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
class TurnLoop
    implements WildMagicHooks, ForcedCastHost, ActionResolutionHost {
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
  /// with VK"). That was a real two-device break — see
  /// [PeerCastVerifier.tierForSpell].
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
  /// given spell was proven at. Never verify or parse a spell against it; the
  /// verifier keys off the spell's own T ([PeerCastVerifier.tierForSpell]).
  final int tier;

  /// **The peer-cast trust boundary.** Everything that decides whether a peer's
  /// declared spell may be believed, and which facts about it are believable.
  ///
  /// The sibling of [_resolution]: that field holds the rules that are a pure
  /// function of state, this one holds the rules that are a function of a
  /// *proof*. Between them they leave `TurnLoop` holding the network
  /// sequencing and the protocol reactions — which is all it should hold.
  ///
  /// The verifier cannot end a match. It returns a [PeerCastVerdict]; mapping a
  /// [PeerCastRejected] onto `session.sendForfeit` + an aborting throw is
  /// [_verifyPeerSpellCast]'s job, right here, because that is protocol and not
  /// certification.
  late final PeerCastVerifier _peerCastVerifier = PeerCastVerifier(
    verifyProof: verifyProof,
    vkBytes: vkBytes,
    vkBytesForTier: vkBytesForTier,
    peerBookRoot: peerBookRoot,
    peerOwnerPubkeyHex: peerOwnerPubkeyHex,
    peerPermissions: peerPermissions,
    allowProoflessSpells: allowProoflessSpells,
  );

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

  /// The proof-tail seam handed to [ActionWire.encodeAction].
  ///
  /// **Null when this caster has no committed chapter**, which is what makes
  /// the codec omit the tail entirely rather than write an empty one — the
  /// distinction is a wire-visible byte difference, so it has to be decided
  /// here, where "do we have a chapter" is known, rather than inside the
  /// encoder.
  ///
  /// Non-null, it answers only "which chapter position is this spell being
  /// cast from" — hand slots, duplicate commitments and the local draw
  /// schedule are all local bookkeeping the codec has no business knowing.
  MembershipProofResolver? get _castProofResolver =>
      localChapterCommitments == null ? null : _membershipProofForCast;

  MembershipProof? _membershipProofForCast(SpellAsset spell, int? handIndex) {
    final commitments = localChapterCommitments;
    if (commitments == null) return null;
    final position = _localCastPosition(spell, handIndex);
    return position != null
        ? BookCommitment.proveMembershipAt(commitments, position)
        : null;
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

  /// Spell casts resolved during the most recent [runTurn] call, for the UI's
  /// cast animation. Cleared and repopulated at the start of every turn.
  List<SpellCastEvent> lastCastEvents = [];

  /// Spells resolved during the most recent [runTurn] call, in resolution
  /// order (the same order [_resolveActions] applied them) — including
  /// countered casts ([ResolvedSpellEvent.wasCountered]). Cleared and
  /// repopulated at the start of every turn. See [ResolvedSpellEvent].
  List<ResolvedSpellEvent> lastResolvedSpells = [];

  /// commitmentHex → certified BASE mana cost (5×segmentCount + dotCount,
  /// grown by 1.05^T × 1.5^effectCount — see
  /// [PeerCastVerifier.certifiedBaseManaCost]) for
  /// every peer spell verified during the most recent [runTurn] call.
  /// Cleared and repopulated at the start of every turn, populated only for
  /// peer casts (by [_verifyPeerSpellCast]) — never for the local player's
  /// own cast. This is the "clean bestiary stat" (Sightings, docs/
  /// SIGHTINGS_PLAN.md §2), deliberately excluding the per-cast modifiers
  /// (chain discount, Efficiency, sorcerer multiplier, nextSpellCostDouble)
  /// that [DeterministicResolution.certifiedManaCost] layers on top for the
  /// actual mana deduction.
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

  /// Every summon walk this turn — one entry per creature that actually went
  /// somewhere or lunged, for the UI's movement animation. Cleared and
  /// repopulated at the start of every turn, exactly like the other per-turn
  /// sinks above.
  ///
  /// **One chronological timeline, appended to by two phases.** A Potent
  /// summon takes its bonus action back in Phase 5, from inside the cast that
  /// created it, and every summon takes its ordinary action in Phase 5b — so
  /// this list runs bonus-action-first, then the sweep in `state.minions`
  /// creation order. It is never reassigned mid-turn; both phases append.
  ///
  /// That is the M4.17 fix. This doc used to claim the Phase-5 bonus action was
  /// "already shown by that spell's own card reveal", and Phase 5b cleared the
  /// list on that basis. The claim was false: `_playSummonWalks`
  /// (`onSummonMovementResolved`) is the ONLY consumer of these events anywhere
  /// in the app, and the card-reveal sequence never reads them — so the bonus
  /// action was shown nowhere, and the creature visibly teleported across it.
  /// See [MinionMoveEvent] and docs/M4_findings.md M4.17.
  List<MinionMoveEvent> lastMinionMoveEvents = [];

  /// Every blow a summon landed this turn, for the UI's attack animation.
  /// Cleared, repopulated and ordered exactly like [lastMinionMoveEvents], and
  /// for the same reason — a Potent summon's bonus blow is a real blow that
  /// nothing else animates. See [AttackEvent].
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
  /// [DeterministicResolution.applyArtifactActivation]'s bookmark case).
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
      // Each avatar's roll is its own phase-seeded stream, so building the RNG
      // for a wizard who turns out to hold no rod costs a hash that is never
      // drawn from and cannot shift anyone else's roll.
      _resolution.applyRodMobilityRoll(
        av,
        HashRng(
          _playerPhaseSeed(
            entropy,
            matchId,
            state.turnNumber,
            0x0A,
            av.playerId,
          ),
        ),
      );
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
        ? _resolution.activatableKinds(localAvatar)
        : const <AccoutrementKind>[];
    final localChoice = available.isEmpty
        ? null
        : await artifactActivationPicker(available);

    final nonce = _commitNonce(_kRevealNonceBytes);
    final bytes = ArtifactActivationWire.encode(localChoice);
    final commit = await Sha256()
        .hash(Uint8List.fromList([...bytes, ...nonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerCommit = await session.exchangeArtifactActivationCommit(commit);

    final myReveal = Uint8List.fromList([...nonce, ...bytes]);
    final peerReveal = await session.exchangeArtifactActivationReveal(myReveal);
    await _verifyReveal(peerReveal, peerCommit, 'artifact');
    final peerChoice =
        ArtifactActivationWire.decode(peerReveal, _kRevealNonceBytes);

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
      // Validation and application are both across the seam; the bookmark burn
      // hands its redraw back because re-dealing a hand touches this device's
      // private draw state (deterministic_resolution.dart, "Phase 0"). The
      // redraw runs inside this same loop iteration, so it still lands between
      // the two declarations exactly where it always did.
      final redrawHandSize = _resolution.applyArtifactActivation(
        avatar,
        _resolution.validateActivation(avatar, declared),
      );
      if (redrawHandSize != null) {
        _redrawHand(
          avatar.playerId,
          artifactEntropy,
          handSize: redrawHandSize,
          tag: 0x09,
        );
      }
    }

    final round = ArtifactActivationRound(
      local: localAvatar.declaredActivation,
      peer: peerId == null ? null : _avatarById(peerId)?.declaredActivation,
    );
    lastArtifactActivations = round;
    return round;
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
    final actionBytes = ActionWire.encodeAction(
      action,
      isVocalComponents: isVocalComponents,
      membershipProofFor: _castProofResolver,
    );
    final actionCommit =
        await ActionWire.splitActionCommit(actionBytes, saltA, saltB);
    final peerActionCommit = await session.exchangeActionCommit(actionCommit);

    _pendingAction = action;
    _pendingActionBytes = actionBytes;
    _pendingSaltA = saltA;
    _pendingSaltB = saltB;
    _pendingActionCommit = actionCommit;
    _pendingPeerActionCommit = peerActionCommit;

    // NOTHING IS CHARGED HERE (M4.10b). Committing a cast does not reserve
    // mana, HP, a chainSurcharge or a nextSpellCostDouble — all of that is
    // settled at Phase 5 by [_settleCommittedCasts], against the state as it
    // stands then. Phase 1 stays free to do local bookkeeping, but it must
    // never become a second authoritative settlement path: that is exactly the
    // asymmetry M4.10b removed.

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

  /// The local player's committed cast, as a Phase-5 settlement — or null when
  /// this turn's action is not a chargeable cast.
  ///
  /// Prices from the caster's own [SpellAsset]. Trusting the wire here is sound
  /// because it is the caster's own spell; the peer's cast is priced from
  /// certified proof outputs instead, by [_certifiedPeerCastSettlement]. See
  /// [_CastSettlement] on why those two never merge.
  _CastSettlement? _localCastSettlement(TurnAction action) {
    final committedSpell = switch (action) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };
    if (committedSpell == null) return null;
    // DEV FLAG — free on both devices. See [_isProoflessBypass].
    if (_isProoflessBypass(committedSpell)) return null;

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

    return (
      playerId: localPlayerId,
      settle: () {
        // Everything below reads the avatar as it stands NOW, at settlement.
        // Nothing is carried forward from Phase 1 — that is the whole point of
        // M4.10b, and re-reading here rather than closing over a Phase-1 value
        // is what makes it true.
        final av = _localAvatar();
        final castingEnhancements = _castingEnhancementsFor(action);

        // Price it WITHOUT charging first, so a shortfall can fizzle-and-refund
        // rather than silently clamping to zero (VOCAL_RECALL_PLAN.md §4).
        final preview = _resolution.spellCostBreakdown(
          committedSpell,
          av,
          enhancements: castingEnhancements,
          recall: recall,
          isVocalComponents: isVocalComponents,
        );
        if (_fizzlesForMana(av, preview.cost)) {
          _markFizzledForMana(action);
          return; // mana refunded (never deducted); the turn is still spent
        }

        av.mana = (av.mana -
                _resolution.applySpellManaCost(
                  committedSpell,
                  av,
                  enhancements: castingEnhancements,
                  recall: recall,
                  isVocalComponents: isVocalComponents,
                ))
            .clamp(0, _kMaxMana);
      },
    );
  }

  /// See [DeterministicResolution.fizzlesForMana] — the rule and the reasoning
  /// behind it live there. This side owns only what a fizzle means to the
  /// protocol; see [_markFizzledForMana].
  bool _fizzlesForMana(WizardAvatar caster, int cost) =>
      _resolution.fizzlesForMana(caster, cost);

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
    // Reset here, with every other per-turn sink, and NOT again in Phase 5b.
    // These two used to be replaced at the Summons phase instead, which threw
    // away a Potent summon's Phase-5 bonus action and — because `_castContext`
    // captures the list objects, not the fields — appended it into the
    // PREVIOUS turn's already-delivered list. That was M4.17; see
    // [lastMinionMoveEvents].
    lastMinionMoveEvents = [];
    lastMinionAttackEvents = [];
    lastWildMagicEvents = [];
    lastCertifiedBaseManaCosts = {};
    _wildMagicNonce = 0;
    _turbulentNonce = 0;

    // Turn-scoped map from certified commitmentHex → the [CertifiedCast]
    // [PeerCastVerifier] established for the peer's cast: its formulas, its flat
    // element sequence (design doc "Summons"), and its wild-magic triggers
    // (docs/WILD_MAGIC_PLAN.md §4.6). Populated by [_verifyPeerSpellCast];
    // consumed by [DeterministicResolution.resolveActions] → applySpell, which
    // reads it in place of the untrusted wire formula (B-1 fix).
    //
    // At most one entry per turn (2-player: one peer action per turn; delayed
    // fires carry their own certification instead). Declared here, per turn, so
    // a stale entry from a previous turn can never leak into the current one.
    //
    // NOTE: that guarantee is structural — it depends on _verifyPeerSpellCast
    // being called at most once per turn. 3+ players (experimentalMultiplayer)
    // would break it: multiple peers could each cast the same starting grid,
    // producing colliding keys. Use a composite key if multi-player is ever wired.
    final certifiedPeerCasts = <String, CertifiedCast>{};

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
    final moveBytes = MoveWire.encodePayload(
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

    final peerMovePayload = MoveWire.decodePayload(
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
    final localMeleeCandidates = _resolution.meleeCandidates(_localAvatar());
    final localMeleeTarget = localMeleeCandidates.isEmpty
        ? null
        : await meleeTargetPicker(localMeleeCandidates);
    final meleeNonce = _commitNonce(_kRevealNonceBytes);
    final meleeBytes = MeleeWire.encodeTarget(localMeleeTarget);
    final meleeCommit = await Sha256()
        .hash(Uint8List.fromList([...meleeBytes, ...meleeNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerMeleeCommit = await session.exchangeMeleeCommit(meleeCommit);

    final myMeleeReveal = Uint8List.fromList([...meleeNonce, ...meleeBytes]);
    final peerMeleeReveal = await session.exchangeMeleeReveal(myMeleeReveal);
    await _verifyReveal(peerMeleeReveal, peerMeleeCommit, 'melee');
    final peerMeleeTarget = MeleeWire.decodeTarget(
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
      // Emitted on the same adjacency test applyHaymaker itself gates on, so
      // a punch thrown at a tile the actor is no longer next to (it lost a
      // contest, it was pushed) is neither applied nor animated. A haymaker
      // that lands on an illusion decoy still animates: the swing happened,
      // and the reveal that it hit a decoy is the decoy's job to tell.
      if (_isAdjacent(actor.position, target)) {
        lastMeleeAttackEvents.add(
          AttackEvent(from: actor.position, to: target, range: 1),
        );
      }
      final hit = _resolution.applyHaymaker(actor, target, walked, meleeRng);
      _resolution.applyCounterCharmProc(
        actor,
        hit,
        meleeRng,
        drawSchedules: _drawSchedules,
        procEvents: lastCounterCharmProcs,
      );
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
    final localDelayedPayload = DelayedRevealWire.encode([
      for (final r in input.delayedSpellReveals)
        (
          pendingSpellId: r.pendingSpellId,
          targetTile: r.targetTile,
          delay: r.delay,
          nonce: r.nonce,
        ),
    ]);
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

    final (:action, :merkleProof) = ActionWire.decodeAction(
      peerActionReveal.sublist(_kRevealNonceBytes * 2),
      withProof: verifyProof != null,
      isVocalComponents: isVocalComponents,
    );

    // Option 3: verify the peer's spell proof and Merkle book membership before
    // resolving. Forfeits the match on any failure. Populates
    // certifiedPeerCasts with the trajectory-derived semantics for use in
    // Phase 5's resolution, and hands back the peer's charge as a settlement
    // for the sorted pass below rather than applying it inline.
    final settlements = <_CastSettlement>[];
    if (action is SpellCastAction || action is MysterySpellCastAction) {
      await _verifyPeerSpellCast(
        action,
        merkleProof,
        certifiedPeerCasts,
        settlements: settlements,
      );
    }

    // Cast settlement (M4.10b). The first resource mutation of Phase 5, and
    // the ONLY point at which a committed cast is paid for: both players'
    // casts, priced against the state Phases 2–4b left behind, in ascending
    // playerId order, on both devices. See [_settleCommittedCasts].
    //
    // Nothing between the Phase-1 commit and this line may charge for a cast.
    _settleCommittedCasts(input.action, settlements);

    // Move-phase Meditate pays out AFTER settlement, not back at Phase 2 where
    // it was declared. Both orderings matter and for different reasons: Phase 2
    // was a lockstep bug (M4.10), and being after settlement rather than before
    // is what keeps a move-Meditate from funding the same turn's spell — the
    // ruling M4.10 settled and M4.10b preserves. See [_applyMoveMeditations].
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

    // Pair each current-turn action with its actor, then fold in delayed fires
    // as SpellCastActions so they join the same resolution order. Built here,
    // not behind the seam, because it is the one thing about Phase 5 that needs
    // to know which device this is — and it is safe precisely because the sort
    // inside [DeterministicResolution.resolveActions] is a TOTAL order, so a
    // local-first input list cannot produce a device-relative output order.
    final delayedFires = [...localFires, ...peerFires];
    final peerAvatarForActions = peerId != null ? _avatarById(peerId) : null;
    final actionPairs = <(WizardAvatar, TurnAction)>[
      (_localAvatar(), myAction),
      if (peerAvatarForActions != null) (peerAvatarForActions, peerAction),
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

    await _resolution.resolveActions(
      _castContext(entropy),
      actions: actionPairs,
      delayedCertified: delayedCertified,
      preMovPos: preMovPos,
      preMovRange: preMovRange,
      rng: actionRng,
      traversedPaths: walked,
      certifiedPeerCasts: certifiedPeerCasts,
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
    // Appends to the turn's three event sinks rather than replacing any of
    // them: a Potent summon's Phase-5 bonus action is already sitting in the
    // first two, and the sweep's events belong after it in the same
    // chronological timeline (M4.17). All three are passed the same way for
    // the same reason — `conveyorChainEvents` is the one that was always
    // correct, and the other two now match it.
    _resolution.resolveSummonActions(
      rng: rng,
      moveEvents: lastMinionMoveEvents,
      attackEvents: lastMinionAttackEvents,
      conveyorChainEvents: lastConveyorChainEvents,
    );
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

  // Cloud drift, the creature AI and the death sweep all moved behind the
  // deterministic seam. The forwarders that used to sit here existed only
  // because Phase 5 was still in this class and reached back across for them —
  // a newly-born cloud's immediate drift, a Potent summon's bonus action, the
  // end-of-phase reap. Phase 5 moved too, so all three are gone and those
  // operations are private to deterministic_resolution.dart again.

  // ── ActionResolutionHost ──────────────────────────────────────────────────
  //
  // What Phase 5 still needs from this side of the seam, and nothing more. See
  // [ActionResolutionHost] for why each member is here; the short version is
  // that each one either needs to know which device this is, reads a proof, or
  // suspends on the network.

  /// The turn-scoped sinks and services a cast writes through.
  ///
  /// Built fresh per call rather than cached, so it always captures the CURRENT
  /// `lastX` lists — [runTurn] reassigns them at the top of every turn, and a
  /// stale context would silently append this turn's events to last turn's
  /// lists.
  ActionResolutionContext _castContext(Uint8List entropy) =>
      ActionResolutionContext(
        host: this,
        entropy: entropy,
        drawSchedules: _drawSchedules,
        castEvents: lastCastEvents,
        resolvedSpells: lastResolvedSpells,
        conveyorChainEvents: lastConveyorChainEvents,
        wildMagicEvents: lastWildMagicEvents,
        minionMoveEvents: lastMinionMoveEvents,
        minionAttackEvents: lastMinionAttackEvents,
      );

  @override
  GameMode get componentsGameMode => _componentsGameMode;

  @override
  Uint8List witherSeed(Uint8List entropy, String playerId) => _playerPhaseSeed(
    entropy,
    matchId,
    state.turnNumber,
    0x06,
    playerId,
    _consumeDrawNonce(playerId),
  );

  @override
  Uint8List ripplingSeed(Uint8List entropy, String playerId) =>
      _playerPhaseSeed(
        entropy,
        matchId,
        state.turnNumber,
        0x0A,
        playerId,
        _ripplingNonce++,
      );

  @override
  Uint8List turbulentSeed(Uint8List entropy, String playerId) =>
      _playerPhaseSeed(
        entropy,
        matchId,
        state.turnNumber,
        0x0B,
        playerId,
        _turbulentNonce++,
      );

  @override
  Uint8List wildMagicSeed(Uint8List entropy, String playerId) =>
      _playerPhaseSeed(
        entropy,
        matchId,
        state.turnNumber,
        0x09,
        playerId,
        _consumeWildMagicNonce(),
      );

  @override
  void redrawHand(String playerId, Uint8List entropy) =>
      _redrawHand(playerId, entropy);

  @override
  void reconcileHandSize(
    String playerId,
    int beforeCount,
    int afterCount,
    Uint8List entropy,
  ) => _reconcileHandSize(playerId, beforeCount, afterCount, entropy);

  @override
  Future<void> drainForcedCasts(Uint8List entropy) =>
      _drainForcedCasts(entropy);

  // ── Mystery / delayed spell helpers ──────────────────────────────────────

  /// Converts an immediate [MysterySpellCastAction] (delay=0) into a regular
  /// [SpellCastAction] after verifying the mystery commitment.
  /// Returns [PassAction] on hash mismatch. Non-immediate actions pass through.
  ///
  /// **This is a rebuild, and a rebuild is a place where semantics get lost.**
  /// [_settleCommittedCasts] has already run by the time this is called — that
  /// ordering is deliberate and predates M4.10b — so the action arriving here
  /// may already be marked [MysterySpellCastAction.fizzledForMana]. Dropping
  /// that on the floor was M4.21: the cast reached resolution with
  /// `fizzle == false`, resolved at full effect, and kept the mana settlement
  /// had refunded. A free cast, silently, from an unmodified client.
  ///
  /// The flag is **carried, never recomputed**. This method must not become a
  /// second affordability oracle: there is exactly one canonical verdict, made
  /// at Phase 5 from settled state, and re-pricing here would be a second one
  /// reading a different moment — precisely the asymmetry M4.10b abolished.
  ///
  /// Everything else the destination type can hold is accounted for:
  /// `targetHex` is reconstructed from the now-opened `immediateTarget`;
  /// `delayedOriginHex`/`delayedRange` are correctly null for a same-turn cast;
  /// `conveyorDirection` and `isEfficiency` have no representation on a Mystery
  /// action at all (Mystery and Efficiency are mutually exclusive enhancement
  /// claims, and the 0x03 encoding has no byte for either). `handIndex` is
  /// dropped and stays dropped: every consumer — `appendSpellProofTail` at
  /// encode time, `_advanceDrawState` in Phase 5 — runs upstream of this
  /// conversion and deliberately reads `input.action` instead. Copying a field
  /// nothing reads is how the next audit gets a false negative.
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
    )
      // Settled at Phase 5, before this line. Carried, not recomputed. M4.21.
      ..fizzledForMana = action.fizzledForMana;
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
    final fires = <(WizardAvatar, SpellCastAction, CertifiedCast?)>[];
    for (final (:id, :targetTile, :delay, :nonce)
        in DelayedRevealWire.decode(payload)) {
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
  /// **Called from Phase 5, immediately after [_settleCommittedCasts]** — not
  /// from Phase 2, where the declaration is exchanged.
  ///
  /// Two separate rulings hold this call in place, and they are worth keeping
  /// apart because only one of them is still a desync concern:
  ///
  /// *Not Phase 2* (M4.10). Cast charging used to straddle the turn — a
  /// player's own cast deducted at Phase 1, the peer's at Phase 5 — so a payout
  /// at Phase 2 landed before the deduction on one device and after it on the
  /// other. Since [_applyManaGain] clamps at `maxMana`, a caster near their
  /// ceiling ended the turn with two different totals:
  ///
  ///   caster's device:  100 − 11 = 89, +25 → clamped 100
  ///   opponent's device: 100 + 25 → clamped 100, −11 = 89
  ///
  /// which [_exchangeStateHash] correctly reports as a broken duel. M4.10b has
  /// since moved BOTH charges to Phase 5 ([_settleCommittedCasts]), so the
  /// straddle is gone and this particular hazard could no longer arise even
  /// from Phase 2 — but the payout stays here regardless, because of:
  ///
  /// *After settlement, not before* (the ruling M4.10 settled). A move-phase
  /// Meditate must not fund the same turn's spell. That used to fall out of the
  /// caster charging at Phase 1; now it is exactly and only the order of these
  /// two calls. Moving this line above [_settleCommittedCasts] would let a
  /// meditation pay for a cast, silently, on both devices — a rules change
  /// wearing the costume of a reordering. See
  /// `mana_charge_window_characterization_test.dart`'s "move-phase Meditate
  /// cannot fund this turn's cast" group, which pins it in both directions.
  ///
  /// Sorted rather than local-first for the usual reason (the convention
  /// [_findCounteringCharm] and the Phase 4b melee round follow): a Reflections
  /// manaMirror link makes one player's gain feed the other's, so the order
  /// the two payouts run in is observable, and "me first" is a different order
  /// on each device.
  void _applyMoveMeditations(List<String> meditatorIds) {
    for (final id in meditatorIds) {
      final av = _avatarById(id);
      if (av != null) _applyManaGain(av, kMeditateManaGain);
    }
  }

  /// See [DeterministicResolution.applyManaGain].
  void _applyManaGain(WizardAvatar av, int amount) =>
      _resolution.applyManaGain(av, amount);

  // The haymaker itself and the counter-charm proc it feeds moved to the
  // deterministic seam (deterministic_resolution.dart, "Phase 4b") — both are
  // functions of (state, arguments, rng), and the round above keeps every
  // await, the commit-reveal, and the sorted application order.

  // ── Wild magic (docs/WILD_MAGIC_PLAN.md) ──────────────────────────────────

  /// The full certified semantics of a spell, derived from proof bytes this
  /// device already holds — the [ActionResolutionHost] seam's one proof read.
  ///
  /// The trust logic itself is [PeerCastVerifier.certifyOwnProof]; this is the
  /// host binding that hands it the match's community seed. Keeping the seam
  /// rather than letting [DeterministicResolution] reach for the verifier
  /// directly is the point: resolution asks its host "what did this proof say",
  /// and stays ignorant of both proof parsing and which device it is running on.
  ///
  /// The peer path and this one share [PeerCastVerifier.semanticsOf], so the
  /// same proof produces byte-identical formulas, element sequence and
  /// wild-magic triggers on both sides of the trust boundary — one derivation,
  /// every call site (§10 invariant 2). What differs is only whether the bytes
  /// were verified first: for our own spell this is authoritative; for a peer's
  /// it is a *fallback* used only when [_verifyPeerSpellCast] never ran (solo,
  /// or verification not wired up), and it is no stronger than the bytes it was
  /// handed. When verification IS wired, the verified derivation always wins —
  /// see [DeterministicResolution]'s `_certifiedPeerCast`.
  @override
  CertifiedCast? certifiedFromProofBytes(SpellAsset spell) =>
      PeerCastVerifier.certifyOwnProof(
        spell,
        communitySeed: state.config.communitySeed,
      );

  /// See [DeterministicResolution.applyPhoenixSaves]. The event sink is this
  /// turn's `lastWildMagicEvents`, which the resolver appends to in place.
  void _applyPhoenixSaves() =>
      _resolution.applyPhoenixSaves(lastWildMagicEvents);

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
  Future<CertifiedCast?> verifyForcedReveal(
    String playerId,
    int position,
    SpellAsset spell,
    MembershipProof? merkleProof,
  ) async {
    // Runs the SAME path a normal peer cast takes. The duplicate-grid guard is
    // deliberately bypassed (see _verifyPeerSpellCast's forcedCast flag): a
    // forced cast is not the player's choice, so it must not consume their
    // once-per-match right to cast that grid, nor trip the duplicate forfeit.
    //
    // The RETURN VALUE is the whole point of the call (M4.20). It used to be
    // discarded, and [resolveForcedCast] then resolved the peer's authored
    // `spell.formula` — a wire field no proof attests. The turn-scoped map is
    // still a throwaway on purpose: a forced reveal is not a cast the peer
    // chose, so it must not publish itself into this turn's certified maps
    // where an ordinary cast of the same grid would pick it up.
    return _verifyPeerSpellCast(
      SpellCastAction(spell: spell, targetHex: const HexCoord(0, 0)),
      merkleProof,
      <String, CertifiedCast>{},
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
    //
    // The certified triple is what the cast MEANS (M4.20). Passing it here is
    // the same thing `resolveActions` does for an ordinary cast: with it,
    // `applySpell` reads the proof-attested trajectory; without it, it falls
    // back to `parsedFormulas(spell)` / `elementSequence(spell)` — the authored
    // wire formula, which nothing binds. A null [pick.certified] means there
    // was no proof to derive from at all, and both devices see that identically.
    //
    // certWildMagic is inert under `fireWildMagic: false` (A8 — a free cast
    // fires none), and is passed anyway so the certified triple travels as one
    // value rather than as two-thirds of one.
    await _resolution.applySpell(
      _castContext(entropy),
      actor,
      pick.spell,
      target,
      const CastingEnhancements(),
      rng,
      certFormulas: pick.certified?.formulas,
      certElementSequence: pick.certified?.elementSequence,
      certWildMagic: pick.certified?.wildMagic,
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
      final sig = await sign(StateHashWire.signatureMessage(
        matchId: matchId,
        turnNumber: state.turnNumber,
        hash: ourHash,
      ));
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
        message: StateHashWire.signatureMessage(
          matchId: matchId,
          turnNumber: state.turnNumber,
          hash: peerHash,
        ),
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
        'local=${WireBytes.hex(ourHash)} peer=${WireBytes.hex(peerHash)}',
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
    final expected =
        await ActionWire.splitActionCommit(actionBytes, saltA, saltB);
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
      myKeyFrame = SealedExchangeFrames.keyFrame(pub.bytes);
    } else {
      myKeyFrame = SealedExchangeFrames.decline();
    }
    final peerKeyFrame = await session.exchangeScryKey(myKeyFrame);

    // ── Send our scryOpen: an AEAD-encrypted target-leaf opening iff the ──
    // ── peer is scrying us. ──
    Uint8List myOpenFrame = SealedExchangeFrames.decline();
    final peerScryKey = SealedExchangeFrames.keyFramePublicKey(peerKeyFrame);
    if (incomingLink != null && peerScryKey != null) {
      final peerEkPub = SimplePublicKey(
        peerScryKey,
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
      ).deriveKey(
        secretKey: shared,
        info: ScryWire.hkdfInfo(
          matchId: matchId,
          turnNumber: state.turnNumber,
        ),
      );

      final (targetBytes, remainder) = ActionWire.splitActionTarget(actionBytes);
      final leafA = await ActionWire.leafHash(remainder, saltA);
      // Opening: targetBytes(4, may be 0) ‖ saltB(16) ‖ leafA(32, the Merkle
      // sibling needed to verify the leaf against the public actionCommit).
      final opening = ScryWire.encodeOpening(
        target: targetBytes,
        saltB: saltB,
        leafA: leafA,
      );
      final cipher = Xchacha20.poly1305Aead();
      final nonce = cipher.newNonce();
      final box = await cipher.encrypt(
        opening,
        secretKey: derived,
        nonce: nonce,
      );
      myOpenFrame =
          SealedExchangeFrames.sealedFrame(vkPub.bytes, box.concatenation());
    }
    final peerOpenFrame = await session.exchangeScryOpen(myOpenFrame);

    // ── Decrypt the peer's opening, if we're the scryer and they answered. ──
    final peerSealed = SealedExchangeFrames.openSealedFrame(peerOpenFrame);
    if (myEphemeral == null || peerSealed == null) return null;
    final vkPub = SimplePublicKey(
      peerSealed.vkPub,
      type: KeyPairType.x25519,
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: myEphemeral,
      remotePublicKey: vkPub,
    );
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: shared,
      info: ScryWire.hkdfInfo(matchId: matchId, turnNumber: state.turnNumber),
    );

    const nonceLen = 24, macLen = 16;
    final boxBytes = peerSealed.box;
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
    // for a Spell cast, 0 bytes (no plaintext target yet) for a Pass or
    // delayed Mystery cast — see [ActionWire.splitActionTarget].
    final decoded = ScryWire.decodeOpening(opening);
    if (decoded == null) return null;
    final (target: openedTarget, saltB: openedSaltB, leafA: leafA) = decoded;
    final hasTarget = openedTarget.isNotEmpty;

    final leafB = await ActionWire.leafHash(openedTarget, openedSaltB);
    final recombined = await Sha256().hash(
      Uint8List.fromList([...leafA, ...leafB]),
    );
    if (!_bytesEqual(Uint8List.fromList(recombined.bytes), peerActionCommit)) {
      session.sendForfeit('bad_scry_opening');
      throw StateError(
        'peer scry opening does not match their actionCommit — match forfeit',
      );
    }

    return hasTarget ? WireBytes.decodeCoord(openedTarget, 0) : null;
  }

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
      myKeyFrame = SealedExchangeFrames.keyFrame(pub.bytes);
    } else {
      myKeyFrame = SealedExchangeFrames.decline();
    }
    final peerKeyFrame = await session.exchangeSpellRevealKey(myKeyFrame);

    Uint8List myOpenFrame = SealedExchangeFrames.decline();
    final hand = localSpellDraw?.hand;
    final commitments = localChapterCommitments;
    final peerRevealKey = SealedExchangeFrames.keyFramePublicKey(peerKeyFrame);
    if (incomingLink != null &&
        hand != null &&
        commitments != null &&
        peerRevealKey != null) {
      final peerEkPub = SimplePublicKey(
        peerRevealKey,
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
      ).deriveKey(
        secretKey: shared,
        info: SpellRevealWire.hkdfInfo(
          matchId: matchId,
          turnNumber: state.turnNumber,
        ),
      );

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
      final entries = <SpellRevealEntry>[];
      for (var i = 0; i < hand.length; i++) {
        final spell = hand[i];
        final position = schedule != null && i < schedule.hand.length
            ? schedule.hand[i]
            : BookCommitment.proveMembership(commitments, spell.commitmentHex)?.leafIndex;
        final proof =
            position != null ? BookCommitment.proveMembershipAt(commitments, position) : null;
        if (proof == null) continue; // unreachable: hand spells are chapter members
        entries.add((
          spell: spell,
          siblings: proof.siblings,
          directions: proof.directions,
        ));
      }
      final payload = SpellRevealWire.encodeEntries(entries);
      final cipher = Xchacha20.poly1305Aead();
      final nonce = cipher.newNonce();
      final box = await cipher.encrypt(payload, secretKey: derived, nonce: nonce);
      myOpenFrame =
          SealedExchangeFrames.sealedFrame(vkPub.bytes, box.concatenation());
    }
    final peerOpenFrame = await session.exchangeSpellRevealOpen(myOpenFrame);

    final peerSealed = SealedExchangeFrames.openSealedFrame(peerOpenFrame);
    if (myEphemeral == null || peerSealed == null) return null;
    final vkPub = SimplePublicKey(
      peerSealed.vkPub,
      type: KeyPairType.x25519,
    );
    final shared = await x25519.sharedSecretKey(
      keyPair: myEphemeral,
      remotePublicKey: vkPub,
    );
    final derived = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: shared,
      info: SpellRevealWire.hkdfInfo(
        matchId: matchId,
        turnNumber: state.turnNumber,
      ),
    );

    const nonceLen = 24, macLen = 16;
    final boxBytes = peerSealed.box;
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
      final spells = <SpellAsset>[];
      final proofs = <MembershipProof>[];
      for (final entry in SpellRevealWire.decodeEntries(payloadBytes)) {
        spells.add(entry.spell);
        proofs.add(MembershipProof(
          root: '', // filled per-entry below, from peerBookRoot
          leafHex: entry.spell.commitmentHex,
          siblings: entry.siblings,
          directions: entry.directions,
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

  /// The protocol reaction to [PeerCastVerifier]'s verdict on a peer's declared
  /// spell cast.
  ///
  /// No trust logic lives here any more — the checks, their order, and the exact
  /// tag each one produces are all in [PeerCastVerifier.certifyPeerCast]. What
  /// stays is the three things a verifier must not do:
  ///
  ///   * turn a [PeerCastRejected] into `session.sendForfeit` + an aborting
  ///     throw, with the tag and message the verdict carries verbatim;
  ///   * publish the certified facts into this turn's `certifiedPeer*` maps,
  ///     which is how they reach [DeterministicResolution.resolveActions];
  ///   * charge the peer for the cast, which mutates their avatar (consuming a
  ///     chainSurcharge or nextSpellCostDouble, converting a shortfall into HP
  ///     damage) and so cannot happen inside verification.
  ///
  /// [forcedCast] marks a reveal the peer did not choose to make (wild magic's
  /// Spontaneous Combustion — see [ForcedCast]). The verifier exempts it from
  /// the duplicate-grid guard; here it additionally skips the mana charge,
  /// because a forced cast is free by definition. Charging for it would drain
  /// mana the caster never chose to spend — and worse, the shortfall check
  /// would penalise a player who simply happened to be holding an expensive
  /// spell they were never given the option to not cast.
  ///
  /// Returns the [CertifiedCast] this verification established, or null when
  /// nothing was certified ([PeerCastUncertified] — solo, verification not
  /// wired up, or the proofless dev flag). A rejection throws instead. The
  /// ordinary cast path ignores the return and reads [certifiedPeerCasts];
  /// [verifyForcedReveal] needs it directly, because a forced reveal
  /// deliberately does not publish itself into this turn's certified maps.
  Future<CertifiedCast?> _verifyPeerSpellCast(
    TurnAction action,
    MembershipProof? merkleProof,
    Map<String, CertifiedCast> certifiedPeerCasts, {
    bool forcedCast = false,
    List<_CastSettlement>? settlements,
  }) async {
    final verdict = await _peerCastVerifier.certifyPeerCast(
      action,
      merkleProof,
      rulesetVersion: state.config.rulesetVersion,
      communitySeed: state.config.communitySeed,
      peerDrawSchedule: _drawSchedules[_peerId()],
      forcedCast: forcedCast,
    );

    switch (verdict) {
      // Solo, verification not wired up, not a spell action, or the
      // kAllowProoflessSpells dev flag. Nothing is certified, so resolution
      // falls back to the wire formula on BOTH devices: not trust-safe, but
      // desync-safe, which is the property the fallback exists for.
      case PeerCastUncertified():
        return null;

      case PeerCastRejected(:final forfeitReason, :final detail):
        session.sendForfeit(forfeitReason);
        throw StateError(detail);

      case PeerCastCertified(:final cast):
        // The certified semantics, published for _resolveActions → _applySpell
        // to read in place of the untrusted wire formula (B-1 fix). Keyed on
        // the CERTIFIED commitment — bound to the wire value by the verifier's
        // commitment_mismatch check, so this is the same key resolution looks
        // up, just sourced from the side of the boundary that proved it.
        certifiedPeerCasts[cast.commitmentHex] = cast.semantics;
        // Retained for Sightings capture (docs/SIGHTINGS_PLAN.md §2/§4) — the
        // clean bestiary base cost, independent of this cast's modifiers. Read
        // by battle_screen.dart's capture hook after runTurn returns.
        lastCertifiedBaseManaCosts[cast.commitmentHex] = cast.baseManaCost;

        // Mana cost (B-1 + B-8) is NOT applied here. Certification and
        // settlement are two different jobs and, since M4.10b, two different
        // moments: this method establishes what the proof says, and hands the
        // charge back as a [_CastSettlement] for [_settleCommittedCasts] to
        // run in canonical player order alongside the local cast. Charging
        // inline would put this peer's deduction ahead of the local one on
        // every device, which is the asymmetry M4.10b removed.
        //
        // Two callers deliberately pass no [settlements] list and are therefore
        // never charged, exactly as before: a forced cast (wild magic's
        // Spontaneous Combustion — the victim did not choose to cast and does
        // not pay), and any caller with no peer avatar to charge.
        final peerId = _peerId();
        final peerAvatar = peerId != null ? _avatarById(peerId) : null;
        if (peerAvatar == null || forcedCast || settlements == null) {
          return cast.semantics;
        }
        final spell = switch (action) {
          SpellCastAction(:final spell) => spell,
          MysterySpellCastAction(:final spell) => spell,
          _ => null,
        };
        final recall = switch (action) {
          SpellCastAction(:final recall) => recall,
          MysterySpellCastAction(:final recall) => recall,
          _ => null,
        };
        if (spell == null) return cast.semantics;
        settlements.add(_certifiedPeerCastSettlement(
          action: action,
          cast: cast,
          peerAvatar: peerAvatar,
          spell: spell,
          recall: recall,
        ));
        return cast.semantics;
    }
  }

  /// A verified peer cast, as a Phase-5 settlement.
  ///
  /// Every pricing input is certified: [cast]'s base price, formulas and
  /// element sequence come from [PeerCastVerifier] over verified public
  /// outputs, and `isEfficiency` has already been checked against this spell's
  /// own certified supreme-dominance zones. Nothing here reads a wire field —
  /// which is the B-1/B-8 property — with the one deliberate exception noted at
  /// `isSummon` below.
  ///
  /// Split out of [_verifyPeerSpellCast] rather than left inline so the charge
  /// can be *ordered* against the local one (M4.10b). The separation is also
  /// load-bearing for trust: this is the only constructor of a certified
  /// settlement, it takes a [PeerCastCertified]'s payload directly, and there
  /// is no parameter by which a caller could ask it to price from wire data
  /// instead. See [_CastSettlement].
  _CastSettlement _certifiedPeerCastSettlement({
    required TurnAction action,
    required CertifiedPeerCast cast,
    required WizardAvatar peerAvatar,
    required SpellAsset spell,
    required IncantationRecall? recall,
  }) {
    return (
      playerId: peerAvatar.playerId,
      settle: () {
        final verifiedCost = _resolution.certifiedManaCost(
          cast.baseManaCost,
          cast.semantics.formulas,
          peerAvatar,
          recall: recall,
          isEfficiency: cast.isEfficiency,
          // UNCERTIFIED, deliberately — M4.19. The only wire field on this
          // path; every other input above is proof-derived. Preserved as-is by
          // the extraction, fix deferred to the Phase-4 identity migration.
          isSummon: spell.isSummon,
          certElementSequence: cast.semantics.elementSequence,
          isVocalComponents: isVocalComponents,
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
      },
    );
  }

  // ── Mana cost ─────────────────────────────────────────────────────────────
  //
  // The arithmetic moved to DeterministicResolution's "Mana cost" section —
  // both mirrors, the recital derivation, and the fizzle predicate. What stays
  // here is orchestration: choosing which inputs a call gets, the proofless
  // dev-flag bypass, coalescing a null recall, marking an action fizzled, and
  // — since M4.10b — WHEN each cast is settled and in what order.
  //
  // The two mirrors stay separate over there for the reason they were separate
  // here: one is a trust boundary and the other is not. See that section's
  // header before touching either.

  /// Prices and pays for every chargeable committed cast this turn, in
  /// ascending `playerId` order, from the state as it stands at the start of
  /// Phase 5 (M4.10b).
  ///
  /// **This is the only authoritative settlement path.** A committed cast
  /// reserves nothing: no mana, no HP, no chainSurcharge, no
  /// nextSpellCostDouble. Between the Phase-1 commit and here, Phases 2–4b are
  /// free to drain the caster's mana (a SlowTile), destroy the very statuses
  /// that would have priced the cast (a Water haymaker), shrink their maximum
  /// pool (a counter-charm proc destroying a mana gem) or punch them — and all
  /// of it lands *before* the price is read, identically on both devices.
  ///
  /// That is the whole fix. The old rule charged the local cast at Phase 1 and
  /// the peer's at Phase 5, so for any single cast one device deducted four
  /// phases earlier than the other and everything in between was applied on
  /// opposite sides of the deduction. See docs/M4_findings.md M4.10 / M4.10b.
  ///
  /// Called after the peer's reveal has cleared the trust boundary — that is
  /// the earliest point at which both devices know the same set of casts — and
  /// before [_applyMoveMeditations], which is what keeps M4.10's ruling that a
  /// move-phase Meditate cannot fund the same turn's spell.
  ///
  /// **On the sort.** Charging one caster cannot currently change any pricing
  /// input of the other: each settlement reads and writes only its own avatar's
  /// mana, statuses, chain and HP, and the one cross-player mana link that
  /// exists (a Reflections `manaMirror`) lives in
  /// [DeterministicResolution.applyManaGain], which is gain-only and is not on
  /// this path. So the order is not observable today. It is fixed anyway, by
  /// the same convention [_findCounteringCharm], the Phase 4b melee round and
  /// [_applyMoveMeditations] follow, because "not observable today" is a
  /// property of the current effect list and not of the settlement machinery —
  /// and the alternative, local-first, is a *different* order on each device.
  /// Anything added here that does read across players must be brought to
  /// Soren as an interaction, not left to the sort to define.
  void _settleCommittedCasts(
    TurnAction localAction,
    List<_CastSettlement> settlements,
  ) {
    final local = _localCastSettlement(localAction);
    if (local != null) settlements.add(local);
    settlements.sort((a, b) => a.playerId.compareTo(b.playerId));
    for (final settlement in settlements) {
      settlement.settle();
    }
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
    return _resolution.spellCostBreakdown(
      spell,
      _localAvatar(),
      enhancements: enhancements,
      isVocalComponents: isVocalComponents,
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

  static bool _isAdjacent(HexCoord a, HexCoord b) =>
      DeterministicResolution.isAdjacent(a, b);

  // The tile queries the melee round used (_avatarsAt / _minionsAt), the
  // candidate list it prompts with, and the illusion redirect a punch rolls
  // against moved to the deterministic seam with the haymaker itself — see
  // deterministic_resolution.dart, "Phase 4b". They had no callers outside it.

  // ── Phase 5.5 / 6.5 helpers: the free-move window ─────────────────────────
  //
  // The rules of the window — what a wizard is offered, where it may step,
  // what a Boost run costs, and what happens when it walks — live behind the
  // deterministic seam (deterministic_resolution.dart, "Phase 5.5 / 6.5"),
  // because none of them needs a session, an await, or a notion of which
  // device this is. What stays here is the protocol around them: the prompt,
  // the commit-reveal exchange, the reveal verification, the order the two
  // runs are applied in, and the end-of-round clearing.
  //
  // The forwarders below are kept for two reasons. BattleScreen holds a
  // [TurnLoop], not a resolution, and needs the *identical* grant and the
  // *identical* price the engine will charge, so it must reach the same code
  // (B-1/B-8 — one price, one code path). And [_applyFreeMove] is where this
  // turn's shared conveyor-event list is injected as the walk's sink, exactly
  // as the movement phase does.

  /// See [DeterministicResolution.freeMoveCandidatesFor].
  List<HexCoord> freeMoveCandidatesFor(String playerId) =>
      _resolution.freeMoveCandidatesFor(playerId);

  /// See [DeterministicResolution.boostMoveCost].
  static int boostMoveCost(SpellAffinity resource, int paidTiles) =>
      DeterministicResolution.boostMoveCost(resource, paidTiles);

  /// See [DeterministicResolution.freeMoveGrantFor].
  FreeMoveGrant freeMoveGrantFor(WizardAvatar av) =>
      _resolution.freeMoveGrantFor(av);

  /// See [DeterministicResolution.applyFreeMove]. The event sink is this
  /// turn's `lastConveyorChainEvents`, which the walk appends to in place.
  void _applyFreeMove(WizardAvatar av, List<HexCoord> declaredPath, HashRng rng) =>
      _resolution.applyFreeMove(
        av,
        declaredPath,
        rng,
        conveyorChainEvents: lastConveyorChainEvents,
      );

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
    final hasSomewhereToGo =
        _resolution.freeMoveCandidates(_localAvatar()).isNotEmpty;
    final localPath = (localGrant.isEmpty || !hasSomewhereToGo)
        ? null
        : await freeMoveDirectionPicker(localGrant);
    final nonce = _commitNonce(_kRevealNonceBytes);
    final bytes = MoveWire.encodePath(localPath ?? const []);
    final commit = await Sha256()
        .hash(Uint8List.fromList([...bytes, ...nonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerCommit = await session.exchangeFreeMoveCommit(commit);

    final myReveal = Uint8List.fromList([...nonce, ...bytes]);
    final peerReveal = await session.exchangeFreeMoveReveal(myReveal);
    await _verifyReveal(peerReveal, peerCommit, 'freeMove');
    final peerPath = MoveWire.decodePath(peerReveal, _kRevealNonceBytes);

    // Applied in ascending canonical owner_pubkey byte order, NOT local-first.
    // This used to run the local wizard first and the peer second, which is a
    // device-relative order: device A ran A-then-B while device B ran B-then-A.
    // Both runs draw from this one [rng] (a closed conveyor loop rolls its exit
    // tile) and both resolve against live occupancy (the second walk sees where
    // the first one stopped), so whenever both players moved in the same window
    // the two devices could bind different draws to different wizards, or hand
    // a contested tile to different players, and diverge on the turn's state
    // hash. Reproduced in free_move_ordering_test.dart.
    //
    // Ordered on the owner_pubkey rather than the playerId that
    // [_findCounteringCharm] and the Phase 4b melee round sort on: the pubkey
    // is the identity both devices authenticated, and comparing its canonical
    // BYTES is immune to how either side spelled the hex (see
    // key_packing.dart's canonical-ordering note). playerId is the tiebreak
    // only, for solo/test states where both avatars carry the same sentinel
    // key — it keeps the order total, so this never depends on sort stability.
    final freeMoveApplications = <(WizardAvatar, List<HexCoord>)>[
      if (localPath != null && localPath.isNotEmpty) (_localAvatar(), localPath),
      if (peerId != null && peerPath.isNotEmpty)
        if (_avatarById(peerId) case final peerAvatar?) (peerAvatar, peerPath),
    ]..sort((a, b) {
      final byKey = compareCanonicalPubkeyHex(
        a.$1.ownerPubkeyHex,
        b.$1.ownerPubkeyHex,
      );
      return byKey != 0 ? byKey : a.$1.playerId.compareTo(b.$1.playerId);
    });
    for (final (avatar, path) in freeMoveApplications) {
      _applyFreeMove(avatar, path, rng);
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

  // ── Formula helpers ───────────────────────────────────────────────────────
  //
  // The three delegates that used to live here (_parsedFormulas,
  // _pureAffinityOf, _elementSequence) and expectedRecitalSlots went with the
  // mana chain: they had no other caller on this side of the seam. See
  // DeterministicResolution's "Mana cost" section.

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

}
