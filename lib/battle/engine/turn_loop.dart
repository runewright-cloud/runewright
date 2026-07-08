// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop.dart — TurnLoop: drives one full turn through all five phases.
//
// Phase order (B-5: entropy reveal moved after all player decisions):
//   1. Action commit — each player commits their action (spell / haymaker / pass)
//      before entropy is known. Mana is deducted at commit time.
//   2. Movement commit-reveal — simultaneous declaration and resolution.
//   3. Entropy reveal — joint commit-reveal entropy derived once all decisions
//      are locked in. Seeds all resolution RNG in phases 4–6.
//   4. Summons act  — deterministic AI for all living minions, creation order.
//   5. Action resolution — reveal actions, sort (quick→haymaker→normal→sluggish),
//      apply each in order.
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
//             [optional proof tail when book proofs are enabled]
//             [sorcerer mode only: pronunciation_u8:1, volume_u8:1, somatic_u8:1]
//   Haymaker: [0x02][q:2][r:2]
//
// Commit:  SHA-256(action_bytes ‖ nonce)  32 bytes
// Reveal:  nonce(16) ‖ action_bytes       variable

import 'dart:convert' show utf8;
import 'dart:math' show max, pow;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../models/battle_state.dart';
import '../models/casting_enhancements.dart';
import '../models/pending_delayed_spell.dart';
import '../models/reflection_link.dart';
import '../models/effect_descriptor.dart'; // exports SpellAffinity, spellAffinityFromZone
import '../models/hex_battlefield.dart'
    show hexDistance, MovementResult, SlowTileEntryEvent, ConveyorPushEvent;
import '../models/minion.dart';
import '../models/status_effect_ids.dart';
import '../models/terrain.dart'
    show ImpassableTile, ToxicCloud, DustCloud, WaterCloud, FloorIsLava, MobileCloud;
import '../models/wizard_avatar.dart';
import '../networking/battle_session.dart';
import '../../protocol/match_session.dart' show ProofVerifier;
import 'book_commitment.dart';
import 'commit_reveal.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'effect_resolver.dart';
import 'proof_intake.dart';
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
    this.delayedSpellReveals = const [],
  });

  /// What the player wants to do: cast a spell, haymaker, or pass.
  final TurnAction action;

  /// Ordered list of tiles to enter this turn (not including current position).
  /// Empty means stay put. Each tile must be adjacent to the previous.
  final List<HexCoord> movePath;

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
    this.vocalScore,
  });

  final SpellAsset spell;
  final HexCoord targetHex;
  final bool isPotent;
  final bool isVelocity;

  /// Sorcerer-mode vocal quality score for this cast. Null in Wizard mode.
  ///
  /// Set by the caster's device from the VocalScorer output and committed
  /// inside the action hash. Populated on the receiving side by decoding the
  /// transmitted bytes — never recomputed from local audio (see _decodeAction).
  final VocalScore? vocalScore;
}

/// Haymaker: deal 1 base HP damage to entity on [targetTile] (must be adjacent).
/// Only valid if the player has not cast a spell this turn.
class HaymakerAction extends TurnAction {
  HaymakerAction({required this.targetTile});
  final HexCoord targetTile;
}

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

enum TurnPhase { summons, actionCommit, movement, actionResolve, endOfTurn, winCheck }

// ── Resolution group (step 4 ordering) ───────────────────────────────────────

enum _ResolutionGroup { quickSpell, haymaker, normalSpell, sluggishSpell }

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
  });

  final BattleState state;
  final BattleTurnSession session;
  final String localPlayerId;

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

  // ── Public entry point ────────────────────────────────────────────────────

  /// Run one full turn, returning a non-null [WinCheckResult] if the match is over.
  ///
  /// [input] carries the local player's action and movement intent. Throws
  /// [StateError] on protocol failures (withheld reveal, state hash mismatch).
  Future<WinCheckResult?> runTurn(TurnInput input) async {
    state.turnNumber++;
    lastCastEvents = [];

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

    // ── Phase 1: Action commit ─────────────────────────────────────────────
    // Committed before entropy is revealed so a modified client cannot
    // pre-compute the resolution RNG and choose their action accordingly
    // (B-5 look-ahead fix).
    // Wire spec: reveal format is nonce(16) ‖ payload, so action/move nonces
    // are 16 bytes (not the 32-byte entropy nonce from generateNonce).
    final actionNonce = CommitRevealEntropy.generateNonce().sublist(0, _kRevealNonceBytes);
    final actionBytes = _encodeAction(input.action);
    final actionCommit = await Sha256()
        .hash(Uint8List.fromList([...actionBytes, ...actionNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerActionCommit = await session.exchangeActionCommit(actionCommit);

    // Deduct mana immediately after commit (covers regular and mystery spells).
    final committedSpell = switch (input.action) {
      SpellCastAction(:final spell) => spell,
      MysterySpellCastAction(:final spell) => spell,
      _ => null,
    };
    if (committedSpell != null) {
      final av = _localAvatar();
      // In sorcerer mode, derive enhancements from the (not-yet-transmitted)
      // vocal score. fromSorcererQuality reads only the u8-quantised
      // accessors, so this agrees byte-for-byte with what _resolveActions
      // computes later from the wire-decoded copy — see the determinism note
      // on VocalScore.pronunciationU8/volumeU8.
      // isPotent/isVelocity double as "caster owns this loadout"; sorcerer
      // quality gates whether that loadout is actually realised this cast.
      final castingEnhancements = isSorcererMode
          ? switch (input.action) {
              SpellCastAction(:final vocalScore, :final isPotent, :final isVelocity)
                  when vocalScore != null =>
                CastingEnhancements.fromSorcererQuality(
                  vocalScore: vocalScore,
                  hasPotentLoadout: isPotent,
                  hasVelocityLoadout: isVelocity,
                ),
              MysterySpellCastAction(:final vocalScore, :final isPotent, :final isVelocity)
                  when vocalScore != null =>
                CastingEnhancements.fromSorcererQuality(
                  vocalScore: vocalScore,
                  hasPotentLoadout: isPotent,
                  hasVelocityLoadout: isVelocity,
                ),
              _ => null,
            }
          : null;
      av.mana = (av.mana -
              _spellManaCost(committedSpell, av,
                  enhancements: castingEnhancements))
          .clamp(0, _kMaxMana);
    }

    // ── Phase 2: Movement commit-reveal ───────────────────────────────────
    // Also committed before entropy is known (same look-ahead protection as
    // Phase 1 — movement decisions should not be influenced by RNG foreknowledge).
    final preMovPos = Map<String, HexCoord>.fromEntries(
      state.avatars.map((av) => MapEntry(av.playerId, av.position)),
    );

    final localPath = input.movePath;
    final moveNonce = CommitRevealEntropy.generateNonce().sublist(0, _kRevealNonceBytes);
    final moveBytes = _encodePath(localPath);
    final moveCommit = await Sha256()
        .hash(Uint8List.fromList([...moveBytes, ...moveNonce]))
        .then((h) => Uint8List.fromList(h.bytes));
    final peerMoveCommit = await session.exchangeMoveCommit(moveCommit);

    // Reveal.
    final myMoveReveal = Uint8List.fromList([...moveNonce, ...moveBytes]);
    final peerMoveReveal = await session.exchangeMoveReveal(myMoveReveal);
    await _verifyReveal(peerMoveReveal, peerMoveCommit, 'movement');

    final peerPath = _decodePath(peerMoveReveal, _kRevealNonceBytes);
    final peerId   = _peerId();

    // Resolve movement for all avatars.
    // ignore: use_null_aware_elements
    final movePaths = {localPlayerId: localPath, if (peerId != null) peerId: peerPath};
    final speeds = {for (final av in state.avatars) av.playerId: av.effectiveMoveSpeed};
    final moveResult = state.battlefield.resolveMovement(
      movePaths, speeds,
      tileEffects: state.tileEffects,
    );
    state.battlefield.applyMovement(moveResult.positions);
    for (final av in state.avatars) {
      final pos = moveResult.positions[av.playerId];
      if (pos != null) av.position = pos;
    }
    _applyMovementEvents(moveResult);

    // FloorIsLava: damage for every lava tile entered along each avatar's path.
    for (final av in state.avatars) {
      if (!av.isAlive) continue;
      final traversed = moveResult.traversedPaths[av.playerId] ?? [];
      for (final hex in traversed.skip(1)) { // skip origin
        final effect = state.tileEffects[hex];
        if (effect is FloorIsLava) av.absorbDamage(effect.damage);
      }
    }

    // ── Phase 3: Entropy reveal ───────────────────────────────────────────
    // All player decisions for this turn are committed. Reveal joint entropy
    // now; it seeds all resolution RNG in phases 4–6.
    final entropy = await _resolveEntropy();

    // ── Phase 4: Summons act ──────────────────────────────────────────────
    final summonsRng = HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x01));
    _resolveSummons(summonsRng);
    _moveClouds();

    // ── Phase 5: Delayed spell reveals + Action reveal + resolution ───────
    // Both players simultaneously announce any pending delayed spells firing
    // this turn (independent of, and before, the current-turn action reveal).
    final localDelayedPayload = _buildDelayedRevealPayload(input.delayedSpellReveals);
    final peerDelayedPayload = await session.exchangeDelayedSpellReveals(localDelayedPayload);

    final myActionReveal = Uint8List.fromList([...actionNonce, ...actionBytes]);
    final peerActionReveal = await session.exchangeActionReveal(myActionReveal);
    await _verifyReveal(peerActionReveal, peerActionCommit, 'action');

    final (:action, :merkleProof) = _decodeAction(
      peerActionReveal.sublist(_kRevealNonceBytes),
      withProof: verifyProof != null,
      isSorcererMode: isSorcererMode,
    );

    // Option 3: verify the peer's spell proof and Merkle book membership before
    // resolving. Forfeits the match on any failure. Populates certifiedPeerFormulas
    // with the trajectory-derived formulas for use in _resolveActions.
    if (action is SpellCastAction || action is MysterySpellCastAction) {
      await _verifyPeerSpellCast(action, merkleProof, certifiedPeerFormulas);
    }

    // For immediate mystery spells (delay=0), verify the commitment and
    // convert to SpellCastAction. Fizzles to Pass on hash mismatch.
    final myAction = await _verifyMysteryAction(input.action);
    final peerAction = await _verifyMysteryAction(action);

    // Verify and collect delayed spell fires; removes matched entries from
    // state.pendingDelayedSpells so the state hash reflects the firings.
    final localFires = await _verifyAndCollectDelayedFires(
        localDelayedPayload, localPlayerId);
    final peerFires = await _verifyAndCollectDelayedFires(
        peerDelayedPayload, peerId ?? '');

    // Action phase seed folds in both action commits (XOR is order-independent
    // so both clients derive the same seed). Defence-in-depth: the seed is
    // bound to exactly the actions taken this turn even if entropy were somehow
    // exposed before the commit.
    final actionRng = HashRng(_actionPhaseSeed(
        entropy, matchId, actionCommit, peerActionCommit, state.turnNumber));
    _resolveActions(myAction, peerAction, preMovPos, actionRng,
        traversedPaths: moveResult.traversedPaths,
        delayedFires: [...localFires, ...peerFires],
        certifiedPeerFormulas: certifiedPeerFormulas);

    // ── Phase 6: End of turn ──────────────────────────────────────────────
    final eotRng = HashRng(_phaseSeed(entropy, matchId, state.turnNumber, 0x03));
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
      Uint8List entropy, Uint8List? matchId, int turnNumber, int tag) {
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
      Uint8List entropy, Uint8List? matchId,
      Uint8List myCommit, Uint8List peerCommit, int turnNumber) {
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

  // ── Phase 4: Summons act ──────────────────────────────────────────────────

  void _resolveSummons(HashRng rng) {
    // Both clients run the same deterministic AI for all minions (creation order
    // maintained by state.minions list). Minions summoned this turn with
    // mayActImmediately=false have actedThisTurn=true already — they skip.
    final living = state.minions.where((m) => m.isAlive && !m.actedThisTurn).toList();
    for (final minion in living) {
      final nearestEnemy = _nearestEnemyTarget(minion.teamId, minion.position);
      if (nearestEnemy == null) continue;

      if (minion is SpiritMinion) {
        _spiritTurn(minion, nearestEnemy, rng);
      } else if (minion is HoundMinion) {
        _houndTurn(minion, nearestEnemy, rng);
      }
      minion.actedThisTurn = true;
    }
    state.resetMinionActions();
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

  void _spiritTurn(SpiritMinion sprite, HexCoord enemyPos, HashRng rng) {
    final range = sprite.effectiveAttackRange;
    final dist = hexDistance(sprite.position, enemyPos);
    // Illusions (Water-Air, Fire flavor) clones always close in and attack
    // rather than maintaining kiting distance -- see Minion.aggressive.
    if (sprite.aggressive) {
      if (dist > range) {
        final step = _greedyStep(sprite.position, enemyPos);
        if (step != null) sprite.position = step;
      }
    } else if (dist < range) {
      // Too close — back away.
      final step = _greedyStepAway(sprite.position, enemyPos);
      if (step != null) sprite.position = step;
    } else if (dist > range) {
      // Too far — approach.
      final step = _greedyStep(sprite.position, enemyPos);
      if (step != null) sprite.position = step;
    }
    // Attack if now in range.
    if (hexDistance(sprite.position, enemyPos) <= range) {
      _minionAttack(sprite, enemyPos, rng);
    }
  }

  void _houndTurn(HoundMinion hound, HexCoord enemyPos, HashRng rng) {
    // Hounds move directly toward the nearest enemy, pathfinding around walls.
    var steps = hound.effectiveMoveSpeed;
    while (steps > 0 && hound.position != enemyPos) {
      final step = _greedyStep(hound.position, enemyPos);
      if (step == null) break;
      hound.position = step;
      steps--;
    }
    if (hexDistance(hound.position, enemyPos) <= hound.stats.attackRange) {
      _minionAttack(hound, enemyPos, rng);
    }
  }

  void _minionAttack(Minion minion, HexCoord target, HashRng rng) {
    final damage = minion.stats.damage;
    if (minion.stats.splashRadius > 0) {
      // AoE: hit everything within splashRadius.
      for (final av in state.avatars) {
        if (hexDistance(av.position, target) <= minion.stats.splashRadius &&
            av.teamId != minion.teamId) {
          av.absorbDamage(damage);
        }
      }
      for (final m in state.minions) {
        if (m == minion) continue;
        if (hexDistance(m.position, target) <= minion.stats.splashRadius) {
          m.takeDamage(damage); // AoE friendly fire possible
        }
      }
    } else {
      // Single target: prioritise enemy avatars, then enemy minions.
      final primaryTargets = state.avatars
          .where((av) => av.isAlive && av.position == target && av.teamId != minion.teamId)
          .toList();
      for (final av in primaryTargets) {
        av.absorbDamage(damage);
        if (minion.stats.knockback > 0) _knockbackAvatar(av, minion.position);
      }
      if (primaryTargets.isEmpty) {
        for (final m in state.minions) {
          if (m != minion && m.isAlive && m.position == target) {
            m.takeDamage(damage);
          }
        }
      }
    }
    // Remove dead minions.
    state.minions.removeWhere((m) => !m.isAlive);
  }

  // ── Phase 3 helpers: movement ─────────────────────────────────────────────

  void _applyMovementEvents(MovementResult result) {
    for (final event in result.events) {
      switch (event) {
        case SlowTileEntryEvent(:final playerId, :final manaDrain):
          final av = state.avatars.firstWhere(
            (a) => a.playerId == playerId,
            orElse: () => throw StateError('SlowTileEntry: unknown player $playerId'),
          );
          av.mana = (av.mana - manaDrain).clamp(0, 9999).toInt();

        case ConveyorPushEvent(:final playerId, :final to):
          final av = state.avatars.firstWhere(
            (a) => a.playerId == playerId,
            orElse: () => throw StateError('ConveyorPush: unknown player $playerId'),
          );
          av.position = to;
          state.battlefield.occupancy[playerId] = to;
      }
    }
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
        PassAction() => _ResolutionGroup.normalSpell,
        HaymakerAction() => _ResolutionGroup.haymaker,
        SpellCastAction() || MysterySpellCastAction() => av.isQuick
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

        case HaymakerAction(:final targetTile):
          _applyHaymaker(actor, targetTile, preMovPos, rng);

        case SpellCastAction(:final spell, :final targetHex, :final isPotent,
            :final isVelocity, :final vocalScore):
          // isSorcererMode + non-null vocalScore is checked at both ends of
          // the wire (commit-time mana deduction above, here at resolution),
          // so the two are always in lockstep — see CastingEnhancements
          // .fromSorcererQuality for why this agrees with the peer's copy.
          final enhancements = isSorcererMode && vocalScore != null
              ? CastingEnhancements.fromSorcererQuality(
                  vocalScore: vocalScore,
                  hasPotentLoadout: isPotent,
                  hasVelocityLoadout: isVelocity,
                )
              : CastingEnhancements(isPotent: isPotent, isVelocity: isVelocity);
          if (enhancements.fizzle) {
            // Botched incantation: spell fails entirely. Mana was already
            // spent at commit time. Treated like a Pass for chain purposes.
            _regressChain(actor);
          } else {
            final affinity = primaryFormulaAffinity(spell.formula);
            if (affinity != null) {
              lastCastEvents.add(SpellCastEvent(
                casterId: actor.playerId,
                fromHex: actor.position,
                toHex: targetHex,
                affinity: affinity,
              ));
            }
            _applySpell(actor, spell, targetHex, enhancements, rng,
                traversedPaths: traversedPaths,
                certFormulas: certifiedPeerFormulas[spell.commitmentHex]);
          }

        case MysterySpellCastAction(:final spell, :final mysteryCommitment,
            :final isPotent, :final isVelocity):
          // Immediate mystery spells were converted to SpellCastAction by
          // _verifyMysteryAction before reaching here. A MysterySpellCastAction
          // at this point is always the non-immediate (delayed) variant.
          state.pendingDelayedSpells.add(PendingDelayedSpell(
            id: PendingDelayedSpell.idFromCommitment(mysteryCommitment),
            ownerId: actor.playerId,
            spell: spell,
            commitment: mysteryCommitment,
            castTurn: state.turnNumber,
            isPotent: isPotent,
            isVelocity: isVelocity,
          ));
      }
    }

    state.minions.removeWhere((m) => !m.isAlive);
  }

  // ── Mystery / delayed spell helpers ──────────────────────────────────────

  /// Converts an immediate [MysterySpellCastAction] (delay=0) into a regular
  /// [SpellCastAction] after verifying the mystery commitment.
  /// Returns [PassAction] on hash mismatch. Non-immediate actions pass through.
  Future<TurnAction> _verifyMysteryAction(TurnAction action) async {
    if (action is! MysterySpellCastAction || !action.isImmediate) return action;

    final preimage = Uint8List.fromList([
      ..._encodeCoord(action.immediateTarget!),
      0, // delay = 0
      ...action.immediateNonce!,
    ]);
    final hash = await Sha256()
        .hash(preimage)
        .then((h) => Uint8List.fromList(h.bytes));
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
      Uint8List payload, String ownerId) async {
    if (payload.isEmpty) return [];
    final count = payload[0];
    final fires = <(WizardAvatar, SpellCastAction)>[];
    var pos = 1;
    for (var i = 0; i < count; i++) {
      if (pos + 37 > payload.length) break; // 16 id + 4 coord + 1 delay + 16 nonce
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
      final preimage = Uint8List.fromList([..._encodeCoord(targetTile), delay, ...nonce]);
      final hash = await Sha256()
          .hash(preimage)
          .then((h) => Uint8List.fromList(h.bytes));
      if (!_bytesEqual(hash, pending.commitment)) continue;

      final actor = _avatarById(pending.ownerId);
      if (actor == null || !actor.isAlive) continue;

      state.pendingDelayedSpells.remove(pending);
      fires.add((actor, SpellCastAction(
        spell: pending.spell,
        targetHex: targetTile,
        isPotent: pending.isPotent,
        isVelocity: pending.isVelocity,
      )));
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

  static Uint8List _buildDelayedRevealPayload(List<DelayedSpellReveal> reveals) {
    final buf = BytesBuilder();
    buf.addByte(reveals.length.clamp(0, 255));
    for (final r in reveals) {
      buf.add(_hexToBytes(r.pendingSpellId)); // 32 hex chars → 16 bytes
      buf.add(_encodeCoord(r.targetTile));    // 4 bytes
      buf.addByte(r.delay & 0xFF);            // 1 byte
      buf.add(r.nonce);                       // 16 bytes
    }
    return buf.toBytes();
  }

  void _applyHaymaker(
    WizardAvatar actor,
    HexCoord targetTile,
    Map<String, HexCoord> preMovPos,
    HashRng rng,
  ) {
    if (!_isAdjacent(actor.position, targetTile)) return;

    var damage = 1;

    // Air haymaker: bonus damage = tiles moved toward target this turn.
    if (actor.hasHaymakerDistanceBonus) {
      final preDist = hexDistance(preMovPos[actor.playerId] ?? actor.position, targetTile);
      final postDist = hexDistance(actor.position, targetTile);
      damage += max(0, preDist - postDist);
    }

    // Apply damage to entities on target tile.
    for (final av in _avatarsAt(targetTile)) {
      if (av.playerId != actor.playerId && _redirectIfIllusion(av, rng)) continue;
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

  void _applySpell(
    WizardAvatar actor,
    SpellAsset spell,
    HexCoord targetHex,
    CastingEnhancements enhancements,
    HashRng rng, {
    Map<String, List<HexCoord>> traversedPaths = const {},
    List<ParsedFormula>? certFormulas,
  }) {
    // TODO(B-1): null certFormulas means either a local spell (trusted wire
    // formula) or a peer delayed-fire (not yet on the certified path). When
    // the wiring pass enables full verification, a null entry for a
    // current-turn peer spell must forfeit rather than fall through here.
    final formulas = certFormulas ?? _parsedFormulas(spell);
    if (formulas.isEmpty) {
      // Wild-magic stub (zero formulas = void spell).
      return;
    }

    // Absorption rod: tracked per-target for this whole spell.
    final rodConsumedFor = <String>{};

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
      EffectApplicator.apply(ApplyContext(
        descriptor: descriptor,
        targetTile: targetHex,
        caster: actor,
        state: state,
        rng: rng,
        rodConsumedFor: rodConsumedFor,
        movePaths: traversedPaths,
      ));
    }

    // Update chain state after casting.
    _updateChainState(actor, spell, certFormulas: certFormulas);
  }

  void _updateChainState(WizardAvatar actor, SpellAsset spell,
      {List<ParsedFormula>? certFormulas}) {
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
      for (final av in state.avatars.where((a) => a.isAlive && a.position == tile)) {
        av.absorbDamage(lava.damage);
      }
      for (final m in state.minions.where((m) => m.isAlive && m.position == tile)) {
        if (m is SpiritMinion && m.stats.ignoresTerrain) continue;
        m.takeDamage(lava.damage);
      }
    }

    // Cloud effects. Base effect (all flavors): entities within cloud.radius
    // may only target/be targeted by adjacent entities -- enforced live by
    // position at cast-target-selection time (battle_screen.dart), not here.
    for (final cloud in state.clouds) {
      switch (cloud.kind) {
        case ToxicCloud(:final damagePerTurn):
          for (final av in state.avatars.where((a) => a.isAlive && hexDistance(a.position, cloud.position) <= cloud.radius)) {
            av.absorbDamage(damagePerTurn);
          }
          for (final m in state.minions.where((m) => m.isAlive && hexDistance(m.position, cloud.position) <= cloud.radius)) {
            m.takeDamage(damagePerTurn);
          }

        case DustCloud(:final restrictionTurnsAfterLeaving):
          // The adjacent-only targeting restriction lingers on avatars who
          // LEFT this cloud's radius this turn.
          for (final av in state.avatars) {
            final wasIn = hexDistance(preMovPos[av.playerId] ?? av.position, cloud.position) <= cloud.radius;
            final isOut = hexDistance(av.position, cloud.position) > cloud.radius;
            if (wasIn && isOut) {
              _addStatus(av, StatusEffectId.cloudBoundTargeting, {}, restrictionTurnsAfterLeaving);
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

    // Remove dead minions.
    state.minions.removeWhere((m) => !m.isAlive);

    // Expire mystery spells whose reveal window has passed (castTurn + 3).
    // Mana is already spent; caster chose not to reveal.
    state.pendingDelayedSpells
        .removeWhere((p) => p.maxTurn <= state.turnNumber);

    // Tick Reflections links; remove expired or dead-participant links.
    final alive = state.avatars.where((a) => a.isAlive).map((a) => a.playerId).toSet();
    for (final l in state.reflectionLinks) { l.remainingTurns--; }
    state.reflectionLinks.removeWhere((l) =>
        l.remainingTurns <= 0 ||
        !alive.contains(l.casterId) ||
        !alive.contains(l.targetId));
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
  Future<void> _verifyReveal(Uint8List reveal, Uint8List commit, String label) async {
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
      throw StateError('peer $label reveal did not match commit — match forfeit');
    }
  }

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

      case SpellCastAction(:final spell, :final targetHex, :final vocalScore):
        buf.addByte(0x01);
        buf.add(_hexToBytes(spell.commitmentHex));
        buf.add(_be2(spell.t));
        buf.add(_encodeCoord(targetHex));
        final formulaStr = spell.formula.join(',');
        final formulaBytes = utf8.encode(formulaStr);
        buf.add(_be2(formulaBytes.length));
        buf.add(formulaBytes);
        _appendSpellProofTail(buf, spell);
        if (isSorcererMode) _appendSorcererBytes(buf, vocalScore);

      case HaymakerAction(:final targetTile):
        buf.addByte(0x02);
        buf.add(_encodeCoord(targetTile));

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
    final proof = BookCommitment.proveMembership(commitments, spell.commitmentHex);
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
    buf.add((score ?? const VocalScore(pronunciation: 0.0, volume: 0.0))
        .toWireBytes());
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
    MembershipProof? parseProofTail(Uint8List b, int pos, String commitmentHex) {
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
        siblings.add('0x${sib.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}');
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
        if (bytes.length < 1 + 32 + 2 + 4 + 2) {
          return (action: PassAction(), merkleProof: null);
        }
        int pos = 1;
        final commitBytes = bytes.sublist(pos, pos + 32);
        pos += 32;
        final t = _readBe2(bytes, pos); pos += 2;
        final q = _readInt16(bytes, pos); pos += 2;
        final r = _readInt16(bytes, pos); pos += 2;
        final formulaLen = _readBe2(bytes, pos); pos += 2;
        final formulaStr = pos + formulaLen <= bytes.length
            ? utf8.decode(bytes.sublist(pos, pos + formulaLen)) : '';
        pos += formulaLen;
        final formula = formulaStr.isEmpty ? <String>[] : formulaStr.split(',');
        final commitmentHex =
            '0x${commitBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

        // Parse proof bytes from the tail (needed for verification).
        Uint8List decodedProofBytes = Uint8List(0);
        if (withProof && pos + 4 <= bytes.length) {
          final proofLen = _readBe4(bytes, pos); pos += 4;
          if (pos + proofLen <= bytes.length) {
            decodedProofBytes = bytes.sublist(pos, pos + proofLen);
          }
          pos += proofLen;
        }

        final spell = SpellAsset(
          id: '', createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24, t: t, ownerPubkeyHex: '', manaCost: 0,
          segmentCount: 0, dotCount: 0,
          initialGrid: const [], proofBytes: decodedProofBytes, name: '',
          commitmentHex: commitmentHex, spellHashHex: '', formula: formula,
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
        final vocalScore01 = isSorcererMode &&
                bytes.length >= VocalScore.wireSizeBytes
            ? VocalScore.fromWireBytes(
                bytes, bytes.length - VocalScore.wireSizeBytes)
            : null;
        return (
          action: SpellCastAction(
              spell: spell,
              targetHex: HexCoord(q, r),
              vocalScore: vocalScore01),
          merkleProof: merkle,
        );

      case 0x02:
        if (bytes.length < 5) return (action: PassAction(), merkleProof: null);
        final q = _readInt16(bytes, 1);
        final r = _readInt16(bytes, 3);
        return (action: HaymakerAction(targetTile: HexCoord(q, r)), merkleProof: null);

      case 0x03:
        if (bytes.length < 1 + 32 + 2 + 2) return (action: PassAction(), merkleProof: null);
        int pos3 = 1;
        final spellCommit = bytes.sublist(pos3, pos3 + 32);
        pos3 += 32;
        final t3 = _readBe2(bytes, pos3); pos3 += 2;
        final formulaLen3 = _readBe2(bytes, pos3); pos3 += 2;
        final formulaStr3 = pos3 + formulaLen3 <= bytes.length
            ? utf8.decode(bytes.sublist(pos3, pos3 + formulaLen3)) : '';
        pos3 += formulaLen3;
        if (pos3 + 32 + 1 > bytes.length) return (action: PassAction(), merkleProof: null);
        final mysteryCommit = bytes.sublist(pos3, pos3 + 32); pos3 += 32;
        final hasImmediate = bytes[pos3++] == 1;
        HexCoord? immTarget;
        Uint8List? immNonce;
        if (hasImmediate && pos3 + 4 + 16 <= bytes.length) {
          immTarget = _decodeCoord(bytes, pos3); pos3 += 4;
          immNonce = bytes.sublist(pos3, pos3 + 16); pos3 += 16;
        }
        final isPotent3 = pos3 < bytes.length && bytes[pos3++] == 1;
        final isVelocity3 = pos3 < bytes.length && bytes[pos3++] == 1;

        Uint8List decodedProofBytes3 = Uint8List(0);
        final commitmentHex3 =
            '0x${spellCommit.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
        if (withProof && pos3 + 4 <= bytes.length) {
          final proofLen = _readBe4(bytes, pos3); pos3 += 4;
          if (pos3 + proofLen <= bytes.length) {
            decodedProofBytes3 = bytes.sublist(pos3, pos3 + proofLen);
          }
          pos3 += proofLen;
        }

        final spell3 = SpellAsset(
          id: '', createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          tier: 24, t: t3, ownerPubkeyHex: '', manaCost: 0,
          segmentCount: 0, dotCount: 0,
          initialGrid: const [], proofBytes: decodedProofBytes3, name: '',
          commitmentHex: commitmentHex3, spellHashHex: '',
          formula: formulaStr3.isEmpty ? [] : formulaStr3.split(','),
        );
        final merkle3 = parseProofTail(bytes, pos3, commitmentHex3);
        // Same no-local-recalculation constraint as case 0x01 above.
        final vocalScore03 = isSorcererMode &&
                bytes.length >= VocalScore.wireSizeBytes
            ? VocalScore.fromWireBytes(
                bytes, bytes.length - VocalScore.wireSizeBytes)
            : null;
        return (
          action: MysterySpellCastAction(
            spell: spell3, mysteryCommitment: mysteryCommit,
            immediateTarget: immTarget, immediateNonce: immNonce,
            isPotent: isPotent3, isVelocity: isVelocity3,
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
  /// [ParsedFormula] list for this spell. [_resolveActions] reads that entry when
  /// calling [_applySpell], replacing the untrusted wire formula (B-1 fix).
  Future<void> _verifyPeerSpellCast(
    TurnAction action,
    MembershipProof? merkleProof,
    Map<String, List<ParsedFormula>> certifiedPeerFormulas,
  ) async {
    final vk = vkBytes;
    final verify = verifyProof;
    final bookRoot = peerBookRoot;
    if (verify == null || vk == null) return; // solo or verification not wired up

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
      throw StateError('peer sent a spell cast with no proof bytes — match forfeit');
    }
    final VerifiedSpellOutputs outputs;
    try {
      outputs = await ProofIntake.verifyAndParse(spell.proofBytes, vk, verify, tier);
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
        outputs, certFormulas, peerAvatar,
        vocalScore: vocalScore,
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
  ///   3. Sorcerer multiplier from wire-quantised [vocalScore] (committed in action hash;
  ///      both clients run [CastingEnhancements.fromSorcererQuality] on the same u8 bytes).
  ///   4. nextSpellCostDouble: consume + double + HP shortfall. Both clients execute this
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
  }) {
    // 1. Certified base + growth.
    final base = 5 * outputs.segmentCount + outputs.dotCount;
    final effectCount = max(0, certFormulas.length - 1);
    var cost = (base * pow(1.05, outputs.t) * pow(1.5, effectCount)).round();

    // 2. Chain discount from certified formulas.
    final chainEl = caster.activeChainElement;
    if (chainEl != null && certFormulas.isNotEmpty) {
      final matching =
          certFormulas.where((f) => spellAffinityFromZone(f.affinity) == chainEl).length;
      final alignFraction = matching / certFormulas.length;
      final discount = caster.chainDiscountMultiplier(alignFraction);
      cost = (cost * (1.0 - discount)).ceil();
    }

    // 3. Sorcerer multiplier from wire-quantised vocal score.
    // hasPotentLoadout/hasVelocityLoadout only gate effects, not cost; pass false.
    if (isSorcererMode && vocalScore != null) {
      final enhancements = CastingEnhancements.fromSorcererQuality(
        vocalScore: vocalScore,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
      );
      cost = (cost * enhancements.manaCostMultiplier).ceil();
    }

    // 4. nextSpellCostDouble: consume and double cost, convert excess to HP damage.
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

  /// Move one step from [from] AWAY from [toward].
  HexCoord? _greedyStepAway(HexCoord from, HexCoord toward) {
    HexCoord? best;
    var bestDist = hexDistance(from, toward);
    for (final n in _neighbors(from)) {
      if (!state.battlefield.isInBounds(n)) continue;
      if (state.tileEffects[n] is ImpassableTile) continue;
      final d = hexDistance(n, toward);
      if (d > bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  // ── Game state helpers ────────────────────────────────────────────────────

  WizardAvatar _localAvatar() => state.avatars.firstWhere(
        (av) => av.playerId == localPlayerId,
        orElse: () => throw StateError('local player $localPlayerId not found in state'),
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

  /// Water-Air Illusions (Water flavor), melee-punch path: if [target] has
  /// active wizard decoys, roll 1/remaining -- on a hit the real wizard takes
  /// it (returns false); otherwise a random decoy is destroyed and [target]
  /// is moved to its tile instead (returns true, meaning this hit is dodged).
  /// Mirrors EffectApplicator._resolveIllusionRedirect for the formula-effect
  /// path; duplicated here since the melee punch bypasses EffectApplicator.
  bool _redirectIfIllusion(WizardAvatar target, HashRng rng) {
    final set = state.wizardIllusions
        .where((s) => s.ownerId == target.playerId && s.decoyPositions.isNotEmpty)
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

  List<HexCoord> _neighbors(HexCoord h) => state.battlefield.neighbors(h);

  void _knockbackAvatar(WizardAvatar av, HexCoord source) {
    const dirs = [
      HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
      HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
    ];
    final dq = av.position.q - source.q;
    final dr = av.position.r - source.r;
    if (dq == 0 && dr == 0) return;
    int bestDot = -999;
    HexCoord bestDir = dirs[0];
    for (final d in dirs) {
      final dot = dq * d.q + dr * d.r;
      if (dot > bestDot) { bestDot = dot; bestDir = d; }
    }
    final dest = HexCoord(av.position.q + bestDir.q, av.position.r + bestDir.r);
    if (state.battlefield.isInBounds(dest) && state.tileEffects[dest] is! ImpassableTile) {
      av.position = dest;
      state.battlefield.occupancy[av.playerId] = dest;
    }
  }

  void _addStatus(WizardAvatar av, String typeId, Map<String, int> mods, int turns) {
    av.activeStatusEffects.removeWhere((fx) => fx.effectTypeId == typeId);
    av.activeStatusEffects.add(StatusEffect(
      effectTypeId: typeId,
      remainingTurns: turns,
      modifiers: mods,
    ));
  }

  // ── Formula helpers ───────────────────────────────────────────────────────

  static List<ParsedFormula> _parsedFormulas(SpellAsset spell) {
    final zones = spell.formula
        .map(_zoneFromName)
        .whereType<BorderZone>()
        .toList();
    final formulas = <ParsedFormula>[];
    for (var i = 0; i + 2 < zones.length; i += 3) {
      formulas.add(ParsedFormula(
        affinity: zones[i],
        effectType1: zones[i + 1],
        effectType2: zones[i + 2],
      ));
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
    final path  = <HexCoord>[];
    var pos = offset + 1;
    for (var i = 0; i < count; i++) {
      if (pos + 4 > data.length) break;
      path.add(_decodeCoord(data, pos));
      pos += 4;
    }
    return path;
  }

  static Uint8List _encodeCoord(HexCoord h) =>
      Uint8List(4)
        ..[0] = (h.q >> 8) & 0xFF
        ..[1] = h.q & 0xFF
        ..[2] = (h.r >> 8) & 0xFF
        ..[3] = h.r & 0xFF;

  static HexCoord _decodeCoord(Uint8List data, int offset) => HexCoord(
        _readInt16(data, offset),
        _readInt16(data, offset + 2),
      );

  static int _readInt16(Uint8List data, int offset) {
    final u = (data[offset] << 8) | data[offset + 1];
    return u >= 0x8000 ? u - 0x10000 : u;
  }

  static int _readBe2(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int _readBe4(Uint8List data, int offset) =>
      (data[offset] << 24) | (data[offset + 1] << 16) |
      (data[offset + 2] << 8) | data[offset + 3];

  static Uint8List _be2(int v) =>
      Uint8List(2)
        ..[0] = (v >> 8) & 0xFF
        ..[1] = v & 0xFF;

  static Uint8List _be4(int v) =>
      Uint8List(4)
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
    for (var i = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
    return diff == 0;
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
