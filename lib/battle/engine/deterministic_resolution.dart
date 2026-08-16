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
// be split this way and should not be forced. Action resolution (5) is the
// hard one: it suspends repeatedly, for peer verification, and the answers
// change what resolves.
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
// ## What is NOT here yet
//
// Spell application and melee are still in `TurnLoop`. Both are deterministic
// underneath; they are just entangled with suspension points, and moving them
// is a separate change with its own corpus run. Melee is the next candidate,
// and it should come across the same way the free-move window did — as
// operations, not as a phase.

import 'dart:math' show max, min;

import 'package:rune_duel/engine/hex_grid.dart';

import '../models/battle_state.dart';
import '../models/creature_spec.dart' show ResistanceTier, resistanceTierOf;
import '../models/effect_descriptor.dart'; // exports SpellAffinity
import '../models/hex_battlefield.dart'
    show MovementContest, hexDistance, hexNeighbors;
import '../models/minion.dart';
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
import '../models/wild_magic_effect.dart' show WildMagicEffectKind;
import '../models/wizard_avatar.dart';
import 'battle_events.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'line_of_sight.dart';
import 'terrain_ops.dart';
import 'tile_entry_resolver.dart';
import 'wild_magic_applicator.dart';

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

// ── Summon AI target ──────────────────────────────────────────────────────────

/// One resolved AI target for a creature's turn: a position plus whichever
/// of avatar/minion is the actual entity there.
class _AiTarget {
  const _AiTarget({required this.position, this.avatar, this.minion});
  final HexCoord position;
  final WizardAvatar? avatar;
  final Minion? minion;
}

/// Everything the Summons phase decided, computed before any of it is shown.
///
/// This is the whole point of splitting [DeterministicResolution.
/// resolveSummonActions] out of `TurnLoop._resolveSummons`: the movement and
/// the blows are *already resolved* — state is fully mutated, damage applied,
/// deaths recorded — by the time the caller has this object. The caller's
/// remaining job is playback, and playback cannot change the outcome because
/// there is nothing left to decide.
class SummonActionOutcome {
  const SummonActionOutcome({
    required this.moveEvents,
    required this.attackEvents,
  });

  /// Every creature that visibly moved or lunged, in AI sweep order.
  final List<MinionMoveEvent> moveEvents;

  /// Every creature blow that landed, in the order it landed.
  final List<AttackEvent> attackEvents;
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
  // are its only callers and both live here. [breakStatuesque] stays public
  // because a *cast* also breaks the latch, and casts resolve in TurnLoop's
  // Phase 5; it is reached through a one-line delegator there, the same
  // forwarding convention as the shared helpers at the bottom of this file.

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
    final bodies = occupiedTiles();
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
      if (path.length > 1) breakStatuesque(av.playerId);
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
  Set<HexCoord> occupiedTiles() => {
    for (final av in state.avatars)
      if (av.isAlive) av.position,
    for (final m in state.minions)
      if (m.isAlive) ...m.occupiedTiles,
  };

  /// Statuesque (wild magic, row 3 Earth): the latch breaks the moment a
  /// player *chooses* to move or cast. Involuntary movement (knockback,
  /// conveyor, ice slide, Zephyr) does NOT break it — "if they move" reads as
  /// a choice.
  void breakStatuesque(String playerId) {
    state.wildMagic.statuesquePlayerIds.remove(playerId);
    state.wildMagic.pendingStatuesquePlayerIds.remove(playerId);
  }

  // ── Phase 4: Cloud drift ──────────────────────────────────────────────────

  /// Air-flavor Clouds (Water-Fire) auto-seek: move 1 tile toward the nearest
  /// enemy of the cloud owner's team during the Summons step each turn.
  void moveClouds() {
    for (final cloud in state.clouds) {
      moveCloud(cloud);
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
  void moveCloud(CloudObject cloud) {
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
  /// Returns the playback record for what happened. Conveyor pushes picked up
  /// mid-walk are appended to [conveyorChainEvents], which the caller owns and
  /// shares with the rest of the turn (see this file's header).
  ///
  /// Does NOT reap the dead: a creature that lunged in and died to a Molten
  /// Carapace has to be seen making the lunge before it is removed, so the
  /// caller plays the outcome back first and calls [resolveSummonAftermath]
  /// second.
  SummonActionOutcome resolveSummonActions({
    required HashRng rng,
    required List<ConveyorChainEvent> conveyorChainEvents,
  }) {
    // Both clients run the same deterministic AI for all minions (creation
    // order maintained by state.minions list). A summon cast this very turn
    // (Potent or not) starts with actedThisTurn=false, so it's included in
    // this sweep — its first action is always this same turn, here. A
    // Potent summon additionally got an immediate bonus action during Phase
    // 5 (see TurnLoop._castSummon), so it acts a second time right here.
    final moveEvents = <MinionMoveEvent>[];
    final attackEvents = <AttackEvent>[];
    final living = state.minions
        .where((m) => m.isAlive && !m.actedThisTurn)
        .toList();
    for (final creature in living) {
      creatureTurn(
        creature,
        rng,
        moveEvents: moveEvents,
        attackEvents: attackEvents,
        conveyorChainEvents: conveyorChainEvents,
      );
      creature.actedThisTurn = true;
    }
    state.resetMinionActions();
    return SummonActionOutcome(
      moveEvents: moveEvents,
      attackEvents: attackEvents,
    );
  }

  /// The other half of the Summons phase: what settles once the walk has been
  /// shown. Reaps creatures killed during the sweep, gives a wizard who died
  /// to one their Phoenix save, and unmakes any illusory clone whose own AI
  /// walked it into a scryer's arms.
  void resolveSummonAftermath({
    required HashRng rng,
    required List<WildMagicEvent> wildMagicEvents,
  }) {
    reapDead(rng);
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
  void creatureTurn(
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
      footprintValid: (t) => footprintValid(t, creature),
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
      if (!footprintValid(n, creature)) continue;
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
        addStatus(av, StatusEffectId.speedDown, {'speedDelta': -1}, 1);
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
    breakStatuesque(av.playerId);

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
        footprintValid: (t) => footprintValid(t, m),
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
              addStatus(
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
      av.hp = state.config.playerHp;
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

    reapDead(rng);
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
  void reapDead(HashRng rng) {
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
  /// Called everywhere avatar HP can reach zero — beside every [reapDead]
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
  bool footprintValid(HexCoord center, Minion creature) {
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

  void addStatus(
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
}
