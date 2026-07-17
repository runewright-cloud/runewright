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
//      Phase 5) reflects this turn's move, not last turn's.
//   4b. Melee commit-reveal — after movement has resolved, each player with
//      an adjacent hostile target may commit an optional melee choice;
//      resolved at the start of phase 5, independent of the main action (a
//      player may cast AND melee the same turn). Candidates reflect
//      post-movement, post-cloud-move positions — NOT post-Summons (5b runs
//      later in the turn now; see below), so a minion that hasn't taken its
//      turn yet this round won't appear in the melee prompt.
//   5. Action resolution — reveal main-phase actions, sort spells
//      (quick→haymaker-tier→normal→sluggish, then by step count T ascending,
//      then commitmentHex), apply each in order. A Potent summon-mode cast
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
// other's dash status before _resolveAvatarMovement runs — the action
// reveal itself is deliberately deferred until after movement resolves (so
// a spell's target can't inform the opponent's move), which would otherwise
// make Dash's same-turn speed boost impossible to apply deterministically.
// meditateInMove forces the declared path to be treated as empty (stay put)
// regardless of what was sent, and grants +25 mana at reveal time.
//
// Melee wire encoding (separate commit-reveal, after movement resolves):
//   No melee: [0x00]   Melee: [0x01][q:2][r:2]
// Commit/reveal shape identical to movement's.

import 'dart:convert' show utf8;
import 'dart:math' show max, min, pow;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../models/battle_state.dart';
import '../models/casting_enhancements.dart';
import '../models/creature_spec.dart'
    show CreatureSpec, ResistanceTier, resistanceTierOf;
import '../models/pending_delayed_spell.dart';
import '../models/reflection_link.dart';
import '../models/divination_link.dart';
import '../models/effect_descriptor.dart'; // exports SpellAffinity, spellAffinityFromZone
import '../models/hex_battlefield.dart' show hexDistance, hexNeighbors;
import '../models/minion.dart';
import '../models/status_effect_ids.dart';
import '../models/terrain.dart'
    show
        ImpassableTile,
        ToxicCloud,
        DustCloud,
        WaterCloud,
        FloorIsLava,
        MobileCloud,
        SlowTile,
        ConveyorTile;
import '../models/wizard_avatar.dart';
import '../networking/battle_session.dart';
import '../../protocol/match_session.dart' show ProofVerifier;
import 'book_commitment.dart';
import 'commit_reveal.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'effect_resolver.dart';
import 'proof_intake.dart';
import 'tile_entry_resolver.dart';
import 'trajectory_parser.dart';
import '../../sorcerer/vocal_score.dart';

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
    this.vocalScore,
    this.conveyorDirection,
    this.delayedOriginHex,
  });

  final SpellAsset spell;
  final HexCoord targetHex;
  final bool isPotent;
  final bool isVelocity;
  final bool isEfficiency;

  /// Sorcerer-mode vocal quality score for this cast. Null in Wizard mode.
  ///
  /// Set by the caster's device from the VocalScorer output and committed
  /// inside the action hash. Populated on the receiving side by decoding the
  /// transmitted bytes — never recomputed from local audio (see _decodeAction).
  final VocalScore? vocalScore;

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

/// One spell resolved this turn, in resolution order — drives the UI's
/// MtG-style card reveal sequence (battle_screen.dart): each entry is shown
/// full-card for 2s, then becomes a thumbnail (neutral tray for incantations,
/// on-grid for summons). [summonMinionId]/[summonPosition] are set only when
/// [isSummon] is true and the summon actually spawned (null for a void/no-op
/// summon cast — no thumbnail to place).
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
  });

  final SpellAsset spell;
  final String casterId;
  final HexCoord targetHex;
  final bool isSummon;
  final String? summonMinionId;
  final HexCoord? summonPosition;

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
    this.vocalScore,
  });

  final SpellAsset spell;

  /// SHA-256(encodeCoord(target) ‖ delay_byte ‖ nonce_16). 32 bytes.
  final Uint8List mysteryCommitment;

  /// Non-null iff delay == 0 (fire this turn).
  final HexCoord? immediateTarget;
  final Uint8List? immediateNonce; // 16 bytes

  final bool isPotent;
  final bool isVelocity;

  /// Sorcerer-mode vocal quality score. Null in Wizard mode.
  /// Transmitted and decoded identically to SpellCastAction.vocalScore.
  final VocalScore? vocalScore;

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

// ── Summon AI target ──────────────────────────────────────────────────────────

/// One resolved AI target for a creature's turn: a position plus whichever
/// of avatar/minion is the actual entity there.
class _AiTarget {
  const _AiTarget({required this.position, this.avatar, this.minion});
  final HexCoord position;
  final WizardAvatar? avatar;
  final Minion? minion;
}

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

/// Mana restored by a single Meditate choice (main phase or move phase).
/// Taking both in the same turn grants 2 × this amount — see
/// [TurnInput.meditateInMove] and [MeditateAction].
const _kMeditateManaGain = 25;

/// Asks the local UI which adjacent tile (if any) to melee this turn, given
/// the list of adjacent tiles that hold at least one living hostile entity.
/// [candidates] is always non-empty when this is called — [TurnLoop] only
/// invokes it for a player who actually has a valid target (design: "pass
/// and make no melee attack" is the implicit choice for everyone else, with
/// no prompt shown at all). Return null to decline.
typedef MeleeTargetPicker =
    Future<HexCoord?> Function(List<HexCoord> candidates);

Future<HexCoord?> _defaultNoMelee(List<HexCoord> candidates) async => null;

/// Asks the local UI which adjacent free tile (if any) to step onto for a
/// post-resolution free-move burst (see [WizardAvatar.pendingFreeMoveBurst]).
/// [candidates] is always non-empty when this is called — [TurnLoop] only
/// invokes it for a player whose barrier actually burst this turn AND who
/// has at least one legal tile to step to. Return null to decline.
typedef FreeMoveDirectionPicker =
    Future<HexCoord?> Function(List<HexCoord> candidates);

Future<HexCoord?> _defaultNoFreeMove(List<HexCoord> candidates) async => null;

class TurnLoop {
  TurnLoop({
    required this.state,
    required this.session,
    required this.localPlayerId,
    this.matchId,
    this.verifyProof,
    this.vkBytes,
    this.peerBookRoot,
    this.tier = 24,
    this.isSorcererMode = false,
    this.meleeTargetPicker = _defaultNoMelee,
    this.freeMoveDirectionPicker = _defaultNoFreeMove,
    this.onPhase,
  });

  final BattleState state;
  final BattleTurnSession session;
  final String localPlayerId;

  /// Called once per turn, after movement resolves, only when the local
  /// avatar has at least one adjacent hostile target. Defaults to always
  /// declining (headless callers — tests, solo mode's scripted dummy — never
  /// melee unless they override this).
  final MeleeTargetPicker meleeTargetPicker;

  /// Called once per turn, after all of phase 5's spells have resolved, only
  /// when the local avatar's barrier burst from damage this turn (see
  /// [WizardAvatar.pendingFreeMoveBurst]) AND has at least one adjacent free
  /// tile to step to. Defaults to always declining (headless callers — tests,
  /// solo mode's scripted dummy — never move unless they override this).
  ///
  /// Sorcerer seam: in a future real-time mode this should instead grant a
  /// temporary movement-speed boost rather than a discrete extra step —
  /// TODO(sorcerer): wire a speed-boost status effect for [GameMode.sorcerer]
  /// instead of prompting this picker.
  final FreeMoveDirectionPicker freeMoveDirectionPicker;

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

  /// Verification key bytes for the agreed circuit tier.
  final Uint8List? vkBytes;

  /// The peer's Merkle book root (hex), received at session handshake. Used
  /// to verify the membership proof included with each peer spell cast.
  final String? peerBookRoot;

  /// Circuit tier (12 / 24 / 48), from [MatchConfig.tier]. Required for
  /// [ProofIntake.verifyAndParse] to parse public outputs correctly.
  final int tier;

  /// When true, spell action payloads carry a 3-byte sorcerer suffix
  /// (pronunciation_u8, volume_u8, somatic_u8) committed inside the action hash.
  /// Must match [MatchConfig.sorcererMode] on both sides.
  final bool isSorcererMode;

  /// The local player's sorted chapter commitmentHex list — set after the
  /// spell library resolves (async after construction in the battle screen).
  /// When non-null, generates Merkle membership proofs for outgoing casts.
  /// When null, proof bytes and membership proofs are omitted from the wire.
  List<String>? localChapterCommitments;

  /// commitmentHex values the peer has cast this match. A second cast of the
  /// same grid is a protocol violation (Kin-stacking exploit); the match is
  /// forfeited on detection.
  final _seenPeerCommitments = <String>{};

  /// Spell casts resolved during the most recent [runTurn] call, for the UI's
  /// cast animation. Cleared and repopulated at the start of every turn.
  List<SpellCastEvent> lastCastEvents = [];

  /// Spells resolved during the most recent [runTurn] call, in resolution
  /// order (the same order [_resolveActions] applied them). Cleared and
  /// repopulated at the start of every turn. See [ResolvedSpellEvent].
  List<ResolvedSpellEvent> lastResolvedSpells = [];

  /// Conveyor-tile pushes (cascades, closed loops) resolved during the most
  /// recent [runTurn] call, for the UI's belt/loop animation. Cleared and
  /// repopulated at the start of every turn.
  List<ConveyorChainEvent> lastConveyorChainEvents = [];

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

  // ── Public entry point ────────────────────────────────────────────────────

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
    final saltA = CommitRevealEntropy.generateNonce().sublist(
      0,
      _kRevealNonceBytes,
    );
    final saltB = CommitRevealEntropy.generateNonce().sublist(
      0,
      _kRevealNonceBytes,
    );
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

    return _exchangeScryOpenings(
      actionBytes: actionBytes,
      saltA: saltA,
      saltB: saltB,
      peerActionCommit: peerActionCommit,
    );
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

    final av = _localAvatar();
    // In sorcerer mode, derive enhancements from the (not-yet-transmitted)
    // vocal score. fromSorcererQuality reads only the u8-quantised
    // accessors, so this agrees byte-for-byte with what _resolveActions
    // computes later from the wire-decoded copy — see the determinism note
    // on VocalScore.pronunciationU8/volumeU8.
    // isPotent/isVelocity/isEfficiency double as "caster owns this
    // loadout"; in sorcerer mode, vocal quality gates whether that
    // loadout is actually realised this cast; in wizard mode it's always
    // realised (isPotent/isVelocity don't affect cost, but isEfficiency
    // must still reach _spellManaCost here for the discount to apply).
    final castingEnhancements = switch (action) {
      SpellCastAction(
        :final vocalScore,
        :final isPotent,
        :final isVelocity,
        :final isEfficiency,
      ) =>
        isSorcererMode && vocalScore != null
            ? CastingEnhancements.fromSorcererQuality(
                vocalScore: vocalScore,
                hasPotentLoadout: isPotent,
                hasVelocityLoadout: isVelocity,
                hasEfficiencyLoadout: isEfficiency,
              )
            : CastingEnhancements(
                isPotent: isPotent,
                isVelocity: isVelocity,
                isEfficiency: isEfficiency,
              ),
      MysterySpellCastAction(
        :final vocalScore,
        :final isPotent,
        :final isVelocity,
      ) =>
        isSorcererMode && vocalScore != null
            ? CastingEnhancements.fromSorcererQuality(
                vocalScore: vocalScore,
                hasPotentLoadout: isPotent,
                hasVelocityLoadout: isVelocity,
                hasEfficiencyLoadout: false,
              )
            : CastingEnhancements(isPotent: isPotent, isVelocity: isVelocity),
      _ => null,
    };
    av.mana =
        (av.mana -
                _spellManaCost(
                  committedSpell,
                  av,
                  enhancements: castingEnhancements,
                ))
            .clamp(0, _kMaxMana);
  }

  /// Run one full turn, returning a non-null [WinCheckResult] if the match is over.
  ///
  /// [input] carries the local player's action and movement intent. Throws
  /// [StateError] on protocol failures (withheld reveal, state hash mismatch).
  Future<WinCheckResult?> runTurn(TurnInput input) async {
    state.turnNumber++;
    lastCastEvents = [];
    lastResolvedSpells = [];
    lastConveyorChainEvents = [];

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

    // ── Phase 2: Movement commit-reveal ───────────────────────────────────
    // Also committed before entropy is known (same look-ahead protection as
    // Phase 1 — movement decisions should not be influenced by RNG foreknowledge).
    final preMovPos = Map<String, HexCoord>.fromEntries(
      state.avatars.map((av) => MapEntry(av.playerId, av.position)),
    );

    // isDashing/meditateInMove ride along with the movement commit-reveal
    // (not the action commit-reveal) — see this file's header comment on
    // why: the action reveal is deliberately deferred until after movement
    // resolves, so Dash's same-turn speed boost has to travel some other
    // way to be known before _resolveAvatarMovement runs.
    final iAmDashing = input.action is DashAction;
    final localPath = input.meditateInMove
        ? const <HexCoord>[]
        : input.movePath;
    final moveNonce = CommitRevealEntropy.generateNonce().sublist(
      0,
      _kRevealNonceBytes,
    );
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
    if (input.meditateInMove)
      _applyManaGain(_localAvatar(), _kMeditateManaGain);
    if (peerId != null && peerMovePayload.meditateInMove) {
      final peerAvatarForMeditate = _avatarById(peerId);
      if (peerAvatarForMeditate != null) {
        _applyManaGain(peerAvatarForMeditate, _kMeditateManaGain);
      }
    }

    // ── Phase 3: Entropy reveal ───────────────────────────────────────────
    // All player decisions for this turn are committed. Reveal joint entropy
    // now; it seeds all resolution RNG in phases 4–6.
    final entropy = await _resolveEntropy();

    // Movement resolution (contested-tile collision, then the actual walk)
    // is deferred to here rather than done inline in Phase 2: Phase 2 only
    // needs to exchange the *declared* paths fairly before entropy is known
    // (B-5 look-ahead protection). Resolving the walk needs a seeded RNG --
    // ConveyorTile loop-exit randomness (tile_entry_resolver.dart) -- so it
    // waits for entropy like every other RNG-driven phase.
    final walked = _resolveAvatarMovement(
      movePaths,
      speeds,
      HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x02)),
    );

    // ── Phase 4: Cloud movement ─────────────────────────────────────────────
    // Air-flavor Clouds only; creature Summons AI (this used to run here
    // too) now runs as Phase 5b, after Action resolution — see this file's
    // header comment for why.
    onPhase?.call(TurnPhase.summons);
    _moveClouds();

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
    final meleeNonce = CommitRevealEntropy.generateNonce().sublist(
      0,
      _kRevealNonceBytes,
    );
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
    if (localMeleeTarget != null) {
      _applyHaymaker(_localAvatar(), localMeleeTarget, walked, meleeRng);
    }
    if (peerId != null && peerMeleeTarget != null) {
      final peerAvatarForMelee = _avatarById(peerId);
      if (peerAvatarForMelee != null) {
        _applyHaymaker(peerAvatarForMelee, peerMeleeTarget, walked, meleeRng);
      }
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
      isSorcererMode: isSorcererMode,
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
      );
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
    _resolveActions(
      myAction,
      peerAction,
      preMovPos,
      actionRng,
      traversedPaths: walked,
      delayedFires: [...localFires, ...peerFires],
      certifiedPeerFormulas: certifiedPeerFormulas,
      certifiedPeerElementSequences: certifiedPeerElementSequences,
    );

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
    _resolveSummons(summonsRng);

    // ── Phase 5.5: Post-resolution free-move (barrier burst) ──────────────
    // A barrier destroyed by damage this turn (a "burst" — not one that
    // merely expired from old age; see WizardAvatar.tickBarriers for that
    // separate, still-unwired path) with freeMoveOnCollapse grants its
    // bearer a single reactive step, once, after every spell for the turn
    // has fully resolved. This is deliberately *not* interleaved mid-
    // resolution: an interactive version that could let the bearer dodge a
    // second spell landing on the same tile later in the same turn would
    // need a new mid-loop suspension point (and, for real duels, a fresh
    // network round trip per burst rather than one fixed one) for a niche
    // payoff — not worth it unless playtesting shows Airy Barrier is
    // underpowered without it. This version still lets the bearer step off
    // hazardous terrain (FloorIsLava, clouds, fire-barrier aura) before
    // Phase 6's position-dependent damage applies.
    //
    // Shape mirrors the Phase 4b melee commit-reveal exactly. Only prompted
    // when the local avatar actually earned a burst and has a legal tile to
    // step to; everyone else implicitly declines with no prompt shown.
    final localFreeMoveCandidates = _localAvatar().pendingFreeMoveBurst
        ? _freeMoveCandidates(_localAvatar())
        : const <HexCoord>[];
    final localFreeMoveTarget = localFreeMoveCandidates.isEmpty
        ? null
        : await freeMoveDirectionPicker(localFreeMoveCandidates);
    final freeMoveNonce = CommitRevealEntropy.generateNonce().sublist(
      0,
      _kRevealNonceBytes,
    );
    final freeMoveBytes = _encodeOptionalTarget(localFreeMoveTarget);
    final freeMoveCommit = await Sha256()
        .hash(Uint8List.fromList([...freeMoveBytes, ...freeMoveNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerFreeMoveCommit = await session.exchangeFreeMoveCommit(
      freeMoveCommit,
    );

    final myFreeMoveReveal = Uint8List.fromList([
      ...freeMoveNonce,
      ...freeMoveBytes,
    ]);
    final peerFreeMoveReveal = await session.exchangeFreeMoveReveal(
      myFreeMoveReveal,
    );
    await _verifyReveal(peerFreeMoveReveal, peerFreeMoveCommit, 'freeMove');
    final peerFreeMoveTarget = _decodeOptionalTarget(
      peerFreeMoveReveal,
      _kRevealNonceBytes,
    );

    if (localFreeMoveTarget != null) {
      _applyFreeMove(_localAvatar(), localFreeMoveTarget);
    }
    if (peerId != null && peerFreeMoveTarget != null) {
      final peerAvatarForFreeMove = _avatarById(peerId);
      if (peerAvatarForFreeMove != null) {
        _applyFreeMove(peerAvatarForFreeMove, peerFreeMoveTarget);
      }
    }
    // One-shot opportunity: clear regardless of whether it was used, so it
    // never rolls over to a later turn.
    for (final av in state.avatars) {
      av.pendingFreeMoveBurst = false;
    }

    // ── Phase 6: End of turn ──────────────────────────────────────────────
    final eotRng = HashRng(
      _phaseSeed(entropy, matchId, state.turnNumber, 0x03),
    );
    _endOfTurn(preMovPos, eotRng);

    await _exchangeStateHash();

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

  void _resolveSummons(HashRng rng) {
    // Both clients run the same deterministic AI for all minions (creation
    // order maintained by state.minions list). A summon cast this very turn
    // (Potent or not) starts with actedThisTurn=false, so it's included in
    // this sweep — its first action is always this same turn, here. A
    // Potent summon additionally got an immediate bonus action during Phase
    // 5 (see _castSummon), so it acts a second time right here.
    final living = state.minions
        .where((m) => m.isAlive && !m.actedThisTurn)
        .toList();
    for (final creature in living) {
      _creatureTurn(creature, rng);
      creature.actedThisTurn = true;
    }
    state.resetMinionActions();
    _reapDead(rng);
  }

  /// Air-flavor Clouds (Water-Fire) auto-seek: move 1 tile toward the nearest
  /// enemy of the cloud owner's team during the Summons step each turn.
  void _moveClouds() {
    for (final cloud in state.clouds) {
      if (cloud.kind is! MobileCloud) continue;
      final ownerTeamId = _avatarById(cloud.ownerId)?.teamId;
      if (ownerTeamId == null) continue;
      final nearestEnemy = _nearestEnemyTarget(ownerTeamId, cloud.position);
      if (nearestEnemy == null) continue;
      final step = _greedyStep(cloud.position, nearestEnemy);
      if (step != null) cloud.position = step;
    }
  }

  // ── Personality AI (design doc "Personalities") ───────────────────────────

  void _creatureTurn(Minion creature, HashRng rng) {
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
        final owner = _avatarById(creature.ownerId);
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
    switch (personality) {
      case SummonPersonality.evasive:
        _evasiveMove(creature, target.position, rng);
      case SummonPersonality.protective:
        final owner = _avatarById(creature.ownerId);
        if (owner != null && owner.isAlive) {
          // Interpose: aim for the tile between the owner and the threat.
          final dir = _directionTowards(owner.position, target.position);
          final interpose = dir == null
              ? owner.position
              : HexCoord(owner.position.q + dir.q, owner.position.r + dir.r);
          _aggressiveMove(creature, interpose, rng);
        } else {
          _aggressiveMove(creature, target.position, rng);
        }
      case SummonPersonality.aggressive:
      case SummonPersonality.tactical:
      case SummonPersonality.obedient: // unreachable — see above
        _aggressiveMove(creature, target.position, rng);
    }
    final movedTiles = hexDistance(before, creature.position);

    if (creature.distanceTo(target.position) <= creature.effectiveAttackRange) {
      _creatureAttack(creature, target, rng, movedTiles: movedTiles);
    }
  }

  /// Nearest living enemy of [teamId] to [from]: enemy players first, then
  /// (if none) enemy minions — Stealthy (AWAW) ones excluded unless [from]
  /// is already within 1 tile. Ties broken by [rng] (design doc: "Targets
  /// that are both equally close and equal priority chosen at random").
  _AiTarget? _nearestEnemyEntity(HexCoord from, String teamId, HashRng rng) {
    final avatars = state.avatars
        .where((av) => av.isAlive && av.teamId != teamId)
        .toList();
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
    final minions = state.minions
        .where(
          (m) =>
              m.isAlive &&
              m.teamId != teamId &&
              (!m.abilities.contains(SummonAbility.stealthy) ||
                  m.distanceTo(from) <= 1),
        )
        .toList();
    if (minions.isEmpty) return null;
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
  void _aggressiveMove(Minion creature, HexCoord target, HashRng rng) {
    final flying = creature.abilities.contains(SummonAbility.flying);
    var steps = creature.effectiveMoveSpeed;
    while (steps > 0 && creature.isAlive && creature.distanceTo(target) > 0) {
      final step = _creatureGreedyStep(creature, target);
      if (step == null) break;
      creature.position = step;
      steps -= _terrainMoveCost(creature, step, flying);
      _resolveMinionConveyorPush(creature, flying, rng);
    }
  }

  /// Evasive: back away while closer than attack range, approach while
  /// farther, stop once at ideal range — using the full move-speed budget.
  /// Same immediate-push-then-continue conveyor behavior as [_aggressiveMove].
  void _evasiveMove(Minion creature, HexCoord target, HashRng rng) {
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
      steps -= _terrainMoveCost(creature, step, flying);
      _resolveMinionConveyorPush(creature, flying, rng);
    }
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
  /// (tile_entry_resolver.dart) right away. No-op if flying.
  void _resolveMinionConveyorPush(Minion creature, bool flying, HashRng rng) {
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
    if (outcome.totalDamage > 0) creature.takeDamage(outcome.totalDamage);
    if (outcome.animationPath.length > 1) {
      lastConveyorChainEvents.add(
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
    for (final n in _neighbors(creature.position)) {
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

  bool _footprintValid(HexCoord center, Minion creature) {
    final flying = creature.abilities.contains(SummonAbility.flying);
    for (final t in footprintFor(center, creature.abilities)) {
      if (!state.battlefield.isInBounds(t)) return false;
      if (!flying && state.tileEffects[t] is ImpassableTile) return false;
    }
    return true;
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
        m.activeStatusEffects.removeWhere(
          (fx) => fx.effectTypeId == StatusEffectId.speedDown,
        );
        m.activeStatusEffects.add(
          StatusEffect(
            effectTypeId: StatusEffectId.speedDown,
            remainingTurns: 1,
            modifiers: const {'speedDelta': -1},
          ),
        );
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

  // ── Phase 3 helpers: movement ─────────────────────────────────────────────

  /// Resolves this turn's avatar movement: a deterministic (no-RNG)
  /// collision preview -- Battlefield.resolveMovement's naive walk +
  /// contested-tile arbitration, ignoring conveyor tiles, just to decide who
  /// wins a contested destination -- then a full terrain-aware walk
  /// ([_walkAvatar]) for each non-bounced avatar from their real origin.
  /// Bounced avatars don't move at all (stay at origin, per the existing
  /// speed-tiebreak rule). Returns each avatar's actually-walked path
  /// (bounced: just [origin]), for knockback's move-path bounce reference.
  Map<String, List<HexCoord>> _resolveAvatarMovement(
    Map<String, List<HexCoord>> movePaths,
    Map<String, int> speeds,
    HashRng rng,
  ) {
    final preview = state.battlefield.resolveMovement(
      movePaths,
      speeds,
      tileEffects: state.tileEffects,
    );
    final walked = <String, List<HexCoord>>{};
    for (final av in state.avatars) {
      final origin = av.position;
      if (preview.bounced.contains(av.playerId)) {
        walked[av.playerId] = [origin];
        continue;
      }
      final budget = max(0, speeds[av.playerId] ?? av.effectiveMoveSpeed);
      final path = _walkAvatar(
        av,
        origin,
        movePaths[av.playerId] ?? const [],
        budget,
        rng,
      );
      av.position = path.last;
      state.battlefield.occupancy[av.playerId] = path.last;
      walked[av.playerId] = path;
    }
    return walked;
  }

  /// Walks [declaredPath] from [origin] for [av], tile by tile, up to
  /// [budget] movement points: ImpassableTile blocks; SlowTile costs
  /// 1 + [SlowTile.extraMoveCost] and drains mana on entry; FloorIsLava
  /// damages per tile entered; and ConveyorTile pushes *immediately* --
  /// cascading, possibly into a closed loop (tile_entry_resolver.dart) --
  /// with [av] then continuing to walk the rest of [declaredPath] from
  /// wherever the push left it, using whatever budget remains (a push
  /// itself is free -- it doesn't consume budget). Returns every tile
  /// actually visited, in order, starting with [origin].
  List<HexCoord> _walkAvatar(
    WizardAvatar av,
    HexCoord origin,
    List<HexCoord> declaredPath,
    int budget,
    HashRng rng,
  ) {
    var current = origin;
    var remaining = budget;
    final path = <HexCoord>[origin];

    for (final step in declaredPath) {
      if (remaining <= 0 || !av.isAlive) break;
      if (!state.battlefield.isInBounds(step)) break;
      if (hexDistance(current, step) != 1) break; // path must be step-adjacent
      final effect = state.tileEffects[step];
      if (effect is ImpassableTile) break;
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
      if (effect is ConveyorTile && effect.directionSet) {
        final outcome = resolveTileEntry(
          state: state,
          rng: rng,
          enteredTile: current,
          flying: false,
          currentHp: av.hp,
          applyEntryLava: false, // already charged just above
        );
        current = outcome.finalPosition;
        path.addAll(outcome.animationPath.skip(1));
        if (outcome.totalDamage > 0) av.absorbDamage(outcome.totalDamage);
        if (outcome.animationPath.length > 1) {
          lastConveyorChainEvents.add(
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
    return path;
  }

  // ── Phase 4: Action resolution ────────────────────────────────────────────

  void _resolveActions(
    TurnAction myAction,
    TurnAction peerAction,
    Map<String, HexCoord> preMovPos,
    HashRng rng, {
    Map<String, List<HexCoord>> traversedPaths = const {},
    List<(WizardAvatar, SpellCastAction)> delayedFires = const [],
    Map<String, List<ParsedFormula>> certifiedPeerFormulas = const {},
    Map<String, List<BorderZone>> certifiedPeerElementSequences = const {},
  }) {
    final peerId = _peerId();
    final peerAvatar = peerId != null ? _avatarById(peerId) : null;

    // Pair each current-turn action with its actor, then fold in delayed fires
    // as SpellCastActions so they join the same resolution order.
    final pairs = <(WizardAvatar, TurnAction)>[
      (_localAvatar(), myAction),
      if (peerAvatar != null) (peerAvatar, peerAction),
      ...delayedFires.map((f) => (f.$1, f.$2 as TurnAction)),
    ];

    // Extract the spell from any spell-like action for sort comparisons.
    SpellAsset? extractSpell(TurnAction a) => switch (a) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };

    // Assign resolution group per action.
    _ResolutionGroup group((WizardAvatar, TurnAction) pair) {
      final av = pair.$1;
      final action = pair.$2;
      return switch (action) {
        PassAction() ||
        DashAction() ||
        MeditateAction() => _ResolutionGroup.normalSpell,
        SpellCastAction() || MysterySpellCastAction() =>
          av.isQuick
              ? _ResolutionGroup.quickSpell
              : av.isSluggish
              ? _ResolutionGroup.sluggishSpell
              : _ResolutionGroup.normalSpell,
      };
    }

    // Sort: group first, then T ascending, then commitmentHex within group.
    final sorted = List.of(pairs)
      ..sort((a, b) {
        final dc = group(a).index.compareTo(group(b).index);
        if (dc != 0) return dc;
        final sa = extractSpell(a.$2);
        final sb = extractSpell(b.$2);
        if (sa != null && sb != null) {
          final tc = sa.t.compareTo(sb.t);
          if (tc != 0) return tc;
          return sa.commitmentHex.compareTo(sb.commitmentHex);
        }
        return 0;
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
          :final vocalScore,
          :final conveyorDirection,
        ):
          // isSorcererMode + non-null vocalScore is checked at both ends of
          // the wire (commit-time mana deduction above, here at resolution),
          // so the two are always in lockstep — see CastingEnhancements
          // .fromSorcererQuality for why this agrees with the peer's copy.
          final enhancements = isSorcererMode && vocalScore != null
              ? CastingEnhancements.fromSorcererQuality(
                  vocalScore: vocalScore,
                  hasPotentLoadout: isPotent,
                  hasVelocityLoadout: isVelocity,
                  hasEfficiencyLoadout: isEfficiency,
                )
              : CastingEnhancements(
                  isPotent: isPotent,
                  isVelocity: isVelocity,
                  isEfficiency: isEfficiency,
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
          if (enhancements.fizzle || ignoredCloudRestriction) {
            // Botched incantation, or an illegal cast that ignored the
            // cloud's adjacent-only targeting restriction: spell fails
            // entirely. Mana was already spent at commit time. Treated like
            // a Pass for chain purposes.
            _regressChain(actor);
          } else {
            final affinity = primaryFormulaAffinity(spell.formula);
            if (affinity != null) {
              lastCastEvents.add(
                SpellCastEvent(
                  casterId: actor.playerId,
                  fromHex: action.delayedOriginHex ?? actor.position,
                  toHex: targetHex,
                  affinity: affinity,
                ),
              );
            }
            // Snapshot the field so the UI's resolution reveal can tell which
            // clouds/terrain/minions THIS spell brought into being (diffed
            // right around its application), and animate them in per-card.
            final cloudsBefore = state.clouds.map((c) => c.id).toSet();
            final tilesBefore = state.tileEffects.keys.toSet();
            final minionsBefore = state.minions.map((m) => m.id).toSet();
            final summoned = _applySpell(
              actor,
              spell,
              targetHex,
              enhancements,
              rng,
              traversedPaths: traversedPaths,
              certFormulas: certifiedPeerFormulas[spell.commitmentHex],
              certElementSequence:
                  certifiedPeerElementSequences[spell.commitmentHex],
              conveyorDirection: conveyorDirection,
            );
            lastResolvedSpells.add(
              ResolvedSpellEvent(
                spell: spell,
                casterId: actor.playerId,
                targetHex: targetHex,
                isSummon: spell.isSummon,
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

        case MysterySpellCastAction(
          :final spell,
          :final mysteryCommitment,
          :final isPotent,
          :final isVelocity,
        ):
          // Immediate mystery spells were converted to SpellCastAction by
          // _verifyMysteryAction before reaching here. A MysterySpellCastAction
          // at this point is always the non-immediate (delayed) variant.
          state.pendingDelayedSpells.add(
            PendingDelayedSpell(
              id: PendingDelayedSpell.idFromCommitment(mysteryCommitment),
              ownerId: actor.playerId,
              spell: spell,
              commitment: mysteryCommitment,
              castTurn: state.turnNumber,
              origin: actor.position,
              isPotent: isPotent,
              isVelocity: isVelocity,
            ),
          );
      }
    }

    _reapDead(rng);
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
      vocalScore: action.vocalScore,
    );
  }

  /// Parses a delayed-reveal payload, verifies each entry against pending state,
  /// and returns the validated fires as (actor, SpellCastAction) pairs.
  /// Matching [PendingDelayedSpell]s are removed from state.
  Future<List<(WizardAvatar, SpellCastAction)>> _verifyAndCollectDelayedFires(
    Uint8List payload,
    String ownerId,
  ) async {
    if (payload.isEmpty) return [];
    final count = payload[0];
    final fires = <(WizardAvatar, SpellCastAction)>[];
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
        ),
      ));
    }
    return fires;
  }

  /// Encodes local [DelayedSpellReveal]s into the wire payload for
  /// [BattleSession.exchangeDelayedSpellReveals].
  /// Format: [count:1][ id:16, coord:4, delay:1, nonce:16 per entry ]
  /// Apply mana gain to [av] and fire the manaMirror trigger on any active
  /// Reflections links where [av] is the link's target.
  void _applyManaGain(WizardAvatar av, int amount) {
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

  void _applyHaymaker(
    WizardAvatar actor,
    HexCoord targetTile,
    Map<String, List<HexCoord>> walked,
    HashRng rng,
  ) {
    if (!_isAdjacent(actor.position, targetTile)) return;

    var damage = 1;

    // Air haymaker: bonus damage = half the tiles actually traversed this
    // turn (path length, not net displacement), rounded down. Uses the
    // walked path from _resolveAvatarMovement so conveyor detours and
    // winding routes count same as their tile length — rewards a longer
    // path (e.g. riding conveyors) over a straight-line approach.
    if (actor.hasHaymakerDistanceBonus) {
      final tilesMoved = (walked[actor.playerId]?.length ?? 1) - 1;
      damage += tilesMoved ~/ 2;
    }

    // Apply damage to entities on target tile.
    for (final av in _avatarsAt(targetTile)) {
      if (av.playerId != actor.playerId && _redirectIfIllusion(av, rng))
        continue;
      av.absorbDamage(damage);

      // Earth haymaker: slow target.
      if (actor.hasHaymakerSlow) {
        _addStatus(av, StatusEffectId.speedDown, {'speedDelta': -1}, 1);
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

    // Fire haymaker DoT: add stacks to each hit avatar.
    if (actor.hasHaymakerDot) {
      for (final av in _avatarsAt(targetTile)) {
        final existing = av.activeStatusEffects
            .where((fx) => fx.effectTypeId == StatusEffectId.haymakerDot)
            .firstOrNull;
        if (existing != null) {
          existing.remainingTurns += 2;
        } else {
          _addStatus(av, StatusEffectId.haymakerDot, {'damagePerTick': 1}, 2);
        }
      }
    }
  }

  /// Returns the [Minion] just summoned, if [spell.isSummon] and the cast
  /// actually produced a creature (see [_castSummon]); null otherwise.
  Minion? _applySpell(
    WizardAvatar actor,
    SpellAsset spell,
    HexCoord targetHex,
    CastingEnhancements enhancements,
    HashRng rng, {
    Map<String, List<HexCoord>> traversedPaths = const {},
    List<ParsedFormula>? certFormulas,
    List<BorderZone>? certElementSequence,
    HexCoord? conveyorDirection,
  }) {
    // design doc "Summons": a summon-mode spell's element sequence is read
    // as a creature instead of being resolved as incantation effects.
    // Bypasses EffectResolver/EffectApplicator and the chain-discount system
    // entirely -- summoning is "instead of creating spell effect
    // incantations", not a 17th effect kind.
    if (spell.isSummon) {
      final sequence = certElementSequence ?? _elementSequence(spell);
      return _castSummon(
        actor,
        targetHex,
        sequence,
        spell.summonPersonality,
        enhancements,
        rng,
      );
    }

    // TODO(B-1): null certFormulas means either a local spell (trusted wire
    // formula) or a peer delayed-fire (not yet on the certified path). When
    // the wiring pass enables full verification, a null entry for a
    // current-turn peer spell must forfeit rather than fall through here.
    final formulas = certFormulas ?? _parsedFormulas(spell);
    if (formulas.isEmpty) {
      // Wild-magic stub (zero formulas = void spell).
      return null;
    }

    // Absorption rod: tracked per-target for this whole spell.
    final rodConsumedFor = <String>{};

    // Conveyor-chain events (knockback landing on a conveyor mid-spell)
    // collected across every formula of this cast, then folded into the
    // per-turn list once for the UI's belt/loop animation.
    final conveyorEvents = <ConveyorChainEvent>[];

    // Consume any pending multiplier from a previous Air-Fire multiplierCycle.
    // TODO(battle): apply the retrieved multiplier to per-field effect scaling
    //   once SpellEffect supports it.
    final primaryAffinity = formulas.isNotEmpty
        ? spellAffinityFromZone(formulas.first.affinity)
        : null;
    if (primaryAffinity != null) {
      actor.pendingEffectMultipliers.remove(primaryAffinity);
    }

    for (final formula in formulas) {
      final descriptor = EffectResolver.resolve(formula, enhancements);
      EffectApplicator.apply(
        ApplyContext(
          descriptor: descriptor,
          targetTile: targetHex,
          caster: actor,
          state: state,
          rng: rng,
          rodConsumedFor: rodConsumedFor,
          movePaths: traversedPaths,
          chosenConveyorDirection: conveyorDirection,
          conveyorChainEvents: conveyorEvents,
        ),
      );
    }
    lastConveyorChainEvents.addAll(conveyorEvents);

    // Update chain state after casting.
    _updateChainState(actor, spell, certFormulas: certFormulas);
    return null;
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
    HashRng rng,
  ) {
    final spec = CreatureSpec.fromElements(sequence);
    if (spec == null) return null; // no activations -- nothing to summon (void)

    final personality = SummonPersonality.values.firstWhere(
      (p) => p.name == personalityName,
      orElse: () => SummonPersonality.aggressive,
    );
    final spawn = _findCreatureSpawnTile(targetHex, spec.abilities);
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
        ),
      );
    }
  }

  /// Finds the nearest tile to [preferred] whose full footprint (see
  /// [footprintFor]) is in bounds, passable, and unoccupied.
  HexCoord _findCreatureSpawnTile(
    HexCoord preferred,
    Set<SummonAbility> abilities,
  ) {
    bool footprintOpen(HexCoord center) {
      for (final t in footprintFor(center, abilities)) {
        if (!state.battlefield.isInBounds(t)) return false;
        if (state.tileEffects[t] is ImpassableTile) return false;
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

  void _updateChainState(
    WizardAvatar actor,
    SpellAsset spell, {
    List<ParsedFormula>? certFormulas,
  }) {
    final formulas = certFormulas ?? _parsedFormulas(spell);
    if (formulas.isEmpty) return;

    final castAffinity = spellAffinityFromZone(formulas.first.affinity);
    if (actor.activeChainElement == castAffinity) {
      // Continuing the chain — increment length.
      final multiplier = actor.chainAccumulationMultiplier;
      final increment = multiplier >= 2.0 ? 2 : 1;
      actor.chainLengths[castAffinity] =
          (actor.chainLengths[castAffinity] ?? 0) + increment;
    } else {
      // Break the old chain; start a new one for this affinity.
      actor.activeChainElement = castAffinity;
      actor.chainLengths[castAffinity] = 1;
    }
  }

  void _regressChain(WizardAvatar actor) {
    final el = actor.activeChainElement;
    if (el == null) return;
    final current = actor.chainLengths[el] ?? 0;
    if (current > 1) {
      actor.chainLengths[el] = current - 1;
    } else {
      actor.chainLengths.remove(el);
      actor.activeChainElement = null;
    }
  }

  // ── Phase 5: End of turn ──────────────────────────────────────────────────

  void _endOfTurn(Map<String, HexCoord> preMovPos, HashRng rng) {
    // Fire barrier aura: deal 1 damage to all adjacent entities per fire-barrier holder.
    for (final av in state.avatars) {
      final fb = av.barriers[SpellAffinity.fire];
      if (fb == null || !fb.isAlive || !fb.fireAura) continue;
      for (final other in state.avatars) {
        if (other.playerId == av.playerId) continue;
        if (_isAdjacent(av.position, other.position)) other.absorbDamage(1);
      }
      for (final m in state.minions) {
        if (_isAdjacent(av.position, m.position)) m.takeDamage(1);
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
        lastConveyorChainEvents.add(
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
        lastConveyorChainEvents.add(
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
          // LEFT this cloud's radius this turn.
          for (final av in state.avatars) {
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

    // Mana regeneration (gems + Water barrier bonus).
    for (final av in state.avatars) {
      if (!av.isAlive) continue;
      final regen = av.manaRegenPerTurn + av.barrierManaRegenFor(av.maxMana);
      _applyManaGain(av, regen);
    }

    // Haymaker DoT tick: deal damage = remainingTurns per active haymakerDot.
    for (final av in state.avatars) {
      final dot = av.activeStatusEffects
          .where((fx) => fx.effectTypeId == StatusEffectId.haymakerDot)
          .firstOrNull;
      if (dot != null && !dot.isDormant) {
        av.absorbDamage(dot.remainingTurns); // damage = turns remaining
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
    state.tickClouds();

    _reapDead(rng);

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
  }

  // ── Entropy + state hash ──────────────────────────────────────────────────

  Future<Uint8List> _resolveEntropy() async {
    final ourNonce = CommitRevealEntropy.generateNonce();
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

    // TODO(battle): prepend Ed25519 signature to ourHash before sending
    //   (BATTLE_PROTOCOL.md §6); depends on identity module.
    final peerHash = await session.exchangeStateHash(ourHash);

    if (!_bytesEqual(ourHash, peerHash)) {
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

  // ── Action wire encoding / decoding ──────────────────────────────────────

  /// Encode a [TurnAction] to bytes for commitment hashing and wire transmission.
  ///
  /// When [localChapterCommitments] is set on this [TurnLoop], spell actions
  /// include a trailing proof tail:
  ///   [proof_len:4 BE][proof_bytes:N][merkle_depth:1][merkle_path:depth*(32+1)]
  /// The receiver must parse this tail when [withProof] is true in [_decodeAction].
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
        :final vocalScore,
        :final conveyorDirection,
      ):
        buf.addByte(0x01);
        buf.add(_hexToBytes(spell.commitmentHex));
        buf.add(_be2(spell.t));
        buf.add(_encodeCoord(targetHex));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(_be2(formulaBytes.length));
        buf.add(formulaBytes);
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        buf.addByte(isEfficiency ? 1 : 0);
        buf.addByte(conveyorDirection != null ? 1 : 0);
        if (conveyorDirection != null) buf.add(_encodeCoord(conveyorDirection));
        _appendSpellProofTail(buf, spell);
        if (isSorcererMode) _appendSorcererBytes(buf, vocalScore);

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
        :final vocalScore,
      ):
        buf.addByte(0x03);
        buf.add(_hexToBytes(spell.commitmentHex));
        buf.add(_be2(spell.t));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(_be2(formulaBytes.length));
        buf.add(formulaBytes);
        buf.add(mysteryCommitment);
        final isImmediate = immediateTarget != null && immediateNonce != null;
        buf.addByte(isImmediate ? 1 : 0);
        if (isImmediate) {
          buf.add(_encodeCoord(immediateTarget));
          buf.add(immediateNonce);
        }
        buf.addByte(isPotent ? 1 : 0);
        buf.addByte(isVelocity ? 1 : 0);
        _appendSpellProofTail(buf, spell);
        if (isSorcererMode) _appendSorcererBytes(buf, vocalScore);
    }
    return buf.toBytes();
  }

  /// Appends [proof_len:4][proof_bytes:N][merkle_depth:1][path:depth*(32+1)] to
  /// [buf] for the given [spell], but only when [localChapterCommitments] is set.
  void _appendSpellProofTail(BytesBuilder buf, SpellAsset spell) {
    final commitments = localChapterCommitments;
    if (commitments == null || spell.proofBytes.isEmpty) return;
    buf.add(_be4(spell.proofBytes.length));
    buf.add(spell.proofBytes);
    final proof = BookCommitment.proveMembership(
      commitments,
      spell.commitmentHex,
    );
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

  /// Appends the 3-byte sorcerer suffix to [buf] for spell action payloads.
  ///
  /// Wire precision: pronunciation and volume are quantised to u8 [0x00–0xFE];
  /// encoding: field_u8 = (value × 254).round().clamp(0, 254);
  /// decoding: value = u8 / 254.0.
  /// ±(1/254) ≈ 0.4% precision loss. Full double precision does NOT survive
  /// the wire round trip.
  ///
  /// Somatic score byte: 0xFF = absent (this pass). 0xFF is permanently
  /// reserved as the absent sentinel — real somatic scores MUST fit [0x00–0xFE]
  /// when implemented in the somatic-gesture pass.
  // TODO(sorcerer): replace somatic 0xFF with somatic_u8 = (somaticScore × 254).round()
  //   in the somatic-gesture pass.
  void _appendSorcererBytes(BytesBuilder buf, VocalScore? score) {
    buf.add(
      (score ?? const VocalScore(pronunciation: 0.0, volume: 0.0))
          .toWireBytes(),
    );
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
    bool isSorcererMode = false,
  }) {
    MembershipProof? parseProofTail(
      Uint8List b,
      int pos,
      String commitmentHex,
    ) {
      if (!withProof || pos + 4 > b.length) return null;
      final proofLen = _readBe4(b, pos);
      pos += 4;
      if (pos + proofLen > b.length) return null;
      // proofBytes are on the spell — already decoded separately; skip past them.
      pos += proofLen;
      if (pos >= b.length) return null;
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
        if (bytes.length < 1 + 32 + 2 + 4 + 2 + 3) {
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
          name: '',
          commitmentHex: commitmentHex,
          spellHashHex: '',
          formula: formula,
        );
        final merkle = parseProofTail(bytes, pos, commitmentHex);
        // [KEY STRUCTURAL CONSTRAINT — no local recalculation]
        // The vocal score is read verbatim from the last [VocalScore.wireSizeBytes]
        // bytes of the payload. It is NEVER recomputed from local audio on the
        // receiving side. Architectural guarantee: _decodeAction is a static method
        // that holds no VocalScorer reference, making local recalculation
        // structurally impossible. Recalculating the opponent's score from local
        // audio would also be impossible (their microphone is unavailable to this
        // device) and would desync lockstep if attempted via any other code path.
        final vocalScore01 =
            isSorcererMode && bytes.length >= VocalScore.wireSizeBytes
            ? VocalScore.fromWireBytes(
                bytes,
                bytes.length - VocalScore.wireSizeBytes,
              )
            : null;
        return (
          action: SpellCastAction(
            spell: spell,
            targetHex: HexCoord(q, r),
            isPotent: isPotent01,
            isVelocity: isVelocity01,
            isEfficiency: isEfficiency01,
            vocalScore: vocalScore01,
            conveyorDirection: conveyorDirection01,
          ),
          merkleProof: merkle,
        );

      case 0x04:
        return (action: DashAction(), merkleProof: null);

      case 0x05:
        return (action: MeditateAction(), merkleProof: null);

      case 0x03:
        if (bytes.length < 1 + 32 + 2 + 2)
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
          name: '',
          commitmentHex: commitmentHex3,
          spellHashHex: '',
          formula: formulaStr3.isEmpty ? [] : formulaStr3.split(','),
        );
        final merkle3 = parseProofTail(bytes, pos3, commitmentHex3);
        // Same no-local-recalculation constraint as case 0x01 above.
        final vocalScore03 =
            isSorcererMode && bytes.length >= VocalScore.wireSizeBytes
            ? VocalScore.fromWireBytes(
                bytes,
                bytes.length - VocalScore.wireSizeBytes,
              )
            : null;
        return (
          action: MysterySpellCastAction(
            spell: spell3,
            mysteryCommitment: mysteryCommit,
            immediateTarget: immTarget,
            immediateNonce: immNonce,
            isPotent: isPotent3,
            isVelocity: isVelocity3,
            vocalScore: vocalScore03,
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
  ///   1. No duplicate grid cast — same [commitmentHex] twice is Kin-stacking.
  ///   2. UltraHonk proof verifies and public [commitmentHex] matches the wire value.
  ///   3. Merkle membership proof is valid against [peerBookRoot].
  ///
  /// On success, populates [certifiedPeerFormulas] with the trajectory-derived
  /// [ParsedFormula] list for this spell, and [certifiedPeerElementSequences]
  /// with the flat certified element sequence (design doc "Summons" — the
  /// same trust boundary extended to creature summoning; see
  /// TrajectoryParser.certifiedElementSequence). [_resolveActions] reads
  /// these entries when calling [_applySpell], replacing the untrusted wire
  /// formula (B-1 fix).
  Future<void> _verifyPeerSpellCast(
    TurnAction action,
    MembershipProof? merkleProof,
    Map<String, List<ParsedFormula>> certifiedPeerFormulas,
    Map<String, List<BorderZone>> certifiedPeerElementSequences,
  ) async {
    final vk = vkBytes;
    final verify = verifyProof;
    final bookRoot = peerBookRoot;
    if (verify == null || vk == null)
      return; // solo or verification not wired up

    final SpellAsset spell;
    final VocalScore? vocalScore;
    if (action is SpellCastAction) {
      spell = action.spell;
      vocalScore = action.vocalScore;
    } else if (action is MysterySpellCastAction) {
      spell = action.spell;
      vocalScore = action.vocalScore;
    } else {
      return;
    }

    // 1. Duplicate grid detection.
    if (!_seenPeerCommitments.add(spell.commitmentHex)) {
      session.sendForfeit('duplicate_spell_cast:${spell.commitmentHex}');
      throw StateError(
        'peer cast the same grid twice — match forfeit '
        '(commitmentHex=${spell.commitmentHex})',
      );
    }

    // 2. Proof verification.
    if (spell.proofBytes.isEmpty) {
      session.sendForfeit('missing_spell_proof');
      throw StateError(
        'peer sent a spell cast with no proof bytes — match forfeit',
      );
    }
    final VerifiedSpellOutputs outputs;
    try {
      outputs = await ProofIntake.verifyAndParse(
        spell.proofBytes,
        vk,
        verify,
        tier,
      );
    } on ProofIntakeException catch (e) {
      session.sendForfeit('invalid_spell_proof');
      throw StateError('peer spell proof rejected: $e');
    }
    if (outputs.commitmentHex != spell.commitmentHex) {
      session.sendForfeit('commitment_mismatch');
      throw StateError(
        'peer proof commitmentHex ${outputs.commitmentHex} '
        'does not match wire value ${spell.commitmentHex} — match forfeit',
      );
    }

    // Recompute formula triplets from the SNARK-certified trajectory (B-1 fix).
    // Replaces the untrusted wire spell.formula for both mana-cost deduction and
    // effect resolution. Stored here; read by _resolveActions → _applySpell.
    final certFormulas = TrajectoryParser.parse(outputs).formulas;
    certifiedPeerFormulas[spell.commitmentHex] = certFormulas;
    certifiedPeerElementSequences[spell.commitmentHex] =
        TrajectoryParser.certifiedElementSequence(outputs);

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
    }

    // 4. Mana cost verification from proof public outputs (B-1 + B-8 fix).
    // Base cost is certified by the SNARK (5×segmentCount + dotCount).
    // effectCount, chain discount, sorcerer multiplier, and nextSpellCostDouble
    // all come from _certifiedManaCost — no untrusted wire values — so both
    // devices deduct the same amount and the mana ledger stays consistent.
    final peerId = _peerId();
    final peerAvatar = peerId != null ? _avatarById(peerId) : null;
    if (peerAvatar != null) {
      final verifiedCost = _certifiedManaCost(
        outputs,
        certFormulas,
        peerAvatar,
        vocalScore: vocalScore,
        isEfficiency: claimsEfficiency,
      );
      if (peerAvatar.mana < verifiedCost) {
        session.sendForfeit('insufficient_mana_for_spell');
        throw StateError(
          'peer spell requires $verifiedCost mana but peer avatar only has '
          '${peerAvatar.mana} — match forfeit',
        );
      }
      peerAvatar.mana = (peerAvatar.mana - verifiedCost).clamp(0, _kMaxMana);
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
  ///   4. Sorcerer multiplier from wire-quantised [vocalScore] (committed in action hash;
  ///      both clients run [CastingEnhancements.fromSorcererQuality] on the same u8 bytes).
  ///   5. nextSpellCostDouble: consume + double + HP shortfall. Both clients execute this
  ///      identically, keeping the status-effect list and state hash in sync.
  ///
  /// NOTE(B-1, balance): certified effectCount is tighter than the wire formula for spells
  /// with residual activations. Example: 4 activations = 1 complete formula + 1 residual;
  /// wire gives effectCount=1 (floor((4-1)÷3)=1), certified gives effectCount=0
  /// (max(0,1-1)=0). The certified count is the correct trust boundary — the wire count
  /// was exploitable by padding the formula list.
  int _certifiedManaCost(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certFormulas,
    WizardAvatar caster, {
    VocalScore? vocalScore,
    bool isEfficiency = false,
  }) {
    // 1. Certified base + growth.
    final base = 5 * outputs.segmentCount + outputs.dotCount;
    final effectCount = max(0, certFormulas.length - 1);
    var cost = (base * pow(1.05, outputs.t) * pow(1.5, effectCount)).round();

    // 2. Chain discount from certified formulas.
    final chainEl = caster.activeChainElement;
    if (chainEl != null && certFormulas.isNotEmpty) {
      final matching = certFormulas
          .where((f) => spellAffinityFromZone(f.affinity) == chainEl)
          .length;
      final alignFraction = matching / certFormulas.length;
      final discount = caster.chainDiscountMultiplier(alignFraction);
      cost = (cost * (1.0 - discount)).ceil();
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

    // 4. Sorcerer multiplier from wire-quantised vocal score.
    // hasPotentLoadout/hasVelocityLoadout only gate effects, not cost; pass false.
    if (isSorcererMode && vocalScore != null) {
      final enhancements = CastingEnhancements.fromSorcererQuality(
        vocalScore: vocalScore,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: false,
      );
      cost = (cost * enhancements.manaCostMultiplier).ceil();
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

  int _spellManaCost(
    SpellAsset spell,
    WizardAvatar caster, {
    CastingEnhancements? enhancements,
  }) {
    var cost = spell.manaCost;

    // Chain discount.
    final formulas = _parsedFormulas(spell);
    final chainEl = caster.activeChainElement;
    if (chainEl != null && formulas.isNotEmpty) {
      final matching = formulas
          .where((f) => spellAffinityFromZone(f.affinity) == chainEl)
          .length;
      final alignFraction = matching / formulas.length;
      final discount = caster.chainDiscountMultiplier(alignFraction);
      cost = (cost * (1.0 - discount)).ceil();
    }

    // Efficiency (Water) loadout enhancement: −1/3 mana cost. Applied after
    // chain discount, before the sorcerer multiplier — see _certifiedManaCost
    // for the mirrored step at the same relative position.
    if (enhancements?.isEfficiency ?? false) {
      cost = (cost * 2 / 3).ceil();
    }

    // Sorcerer-mode cost multiplier from vocal (and eventually somatic) quality.
    // Applied after chain discount so poor casting inflates the already-discounted cost.
    // TODO(sorcerer): placeholder passthrough — manaCostMultiplier is always 1.0
    //   until CastingEnhancements.fromSorcererQuality() formula is finalised (playtest gate).
    if (enhancements != null) {
      cost = (cost * enhancements.manaCostMultiplier).ceil();
    }

    // nextSpellCostDouble status effect: consume it and double the cost.
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
      final shortfall = (cost - caster.mana).clamp(0, 9999);
      if (shortfall > 0) {
        final hpDamage = ((shortfall / manaPerHp) * hpPerMana).ceil();
        caster.absorbDamage(hpDamage);
        cost = caster.mana; // pay what they have
      }
      caster.activeStatusEffects.removeAt(doubleIdx);
    }

    return cost.clamp(0, _kMaxMana);
  }

  // ── Greedy pathfinding helpers ─────────────────────────────────────────────

  /// Move one step from [from] toward [to], avoiding impassable tiles.
  /// Returns null if no valid step found.
  HexCoord? _greedyStep(HexCoord from, HexCoord to) {
    HexCoord? best;
    var bestDist = hexDistance(from, to);
    for (final n in _neighbors(from)) {
      if (state.tileEffects[n] is ImpassableTile) continue;
      final d = hexDistance(n, to);
      if (d < bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  // ── Game state helpers ────────────────────────────────────────────────────

  WizardAvatar _localAvatar() => state.avatars.firstWhere(
    (av) => av.playerId == localPlayerId,
    orElse: () =>
        throw StateError('local player $localPlayerId not found in state'),
  );

  WizardAvatar? _avatarById(String id) =>
      state.avatars.where((av) => av.playerId == id).firstOrNull;

  String? _peerId() => state.avatars
      .where((av) => av.playerId != localPlayerId)
      .map((av) => av.playerId)
      .firstOrNull;

  List<WizardAvatar> _avatarsAt(HexCoord hex) =>
      state.avatars.where((av) => av.isAlive && av.position == hex).toList();

  List<Minion> _minionsAt(HexCoord hex) =>
      state.minions.where((m) => m.isAlive && m.position == hex).toList();

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

  static bool _isAdjacent(HexCoord a, HexCoord b) => hexDistance(a, b) == 1;

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
  /// it (returns false); otherwise a random decoy is destroyed and [target]
  /// is moved to its tile instead (returns true, meaning this hit is dodged).
  /// Mirrors EffectApplicator._resolveIllusionRedirect for the formula-effect
  /// path; duplicated here since the melee punch bypasses EffectApplicator.
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
    final decoyPos = set.decoyPositions.removeAt(idx);
    target.position = decoyPos;
    state.battlefield.occupancy[target.playerId] = decoyPos;
    if (set.decoyPositions.isEmpty) state.wizardIllusions.remove(set);
    return true;
  }

  /// Adjacent tiles a post-resolution free-move burst may step onto: in
  /// bounds, not [ImpassableTile], and unoccupied by any living avatar or
  /// minion. Mirrors the footprint check in [_findCreatureSpawnTile].
  List<HexCoord> _freeMoveCandidates(WizardAvatar actor) {
    if (!actor.isAlive) return const [];
    final candidates = <HexCoord>[];
    for (final tile in hexNeighbors(actor.position)) {
      if (!state.battlefield.isInBounds(tile)) continue;
      if (state.tileEffects[tile] is ImpassableTile) continue;
      if (state.avatars.any((av) => av.isAlive && av.position == tile))
        continue;
      if (state.minions.any((m) => m.isAlive && m.position == tile)) continue;
      candidates.add(tile);
    }
    return candidates;
  }

  /// Applies a post-resolution free-move step for [av] to [target].
  /// Re-validates independently of the wire claim (defense-in-depth,
  /// matching [_applyHaymaker]'s adjacency check): [av] must actually have
  /// [WizardAvatar.pendingFreeMoveBurst] set — both clients compute this
  /// deterministically from this turn's damage resolution, so a peer cannot
  /// claim a burst it didn't earn — and [target] must be a currently-legal
  /// [_freeMoveCandidates] tile for [av].
  void _applyFreeMove(WizardAvatar av, HexCoord target) {
    if (!av.pendingFreeMoveBurst) return;
    if (!_isAdjacent(av.position, target)) return;
    if (!_freeMoveCandidates(av).contains(target)) return;
    av.position = target;
    state.battlefield.occupancy[av.playerId] = target;
  }

  List<HexCoord> _neighbors(HexCoord h) => state.battlefield.neighbors(h);

  void _addStatus(
    WizardAvatar av,
    String typeId,
    Map<String, int> mods,
    int turns,
  ) {
    av.activeStatusEffects.removeWhere((fx) => fx.effectTypeId == typeId);
    av.activeStatusEffects.add(
      StatusEffect(
        effectTypeId: typeId,
        remainingTurns: turns,
        modifiers: mods,
      ),
    );
  }

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
  /// tile. Shared shape for the resolution-phase melee choice and the
  /// post-resolution free-move choice (both are "optional adjacent tile").
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
