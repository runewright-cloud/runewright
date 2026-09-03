// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_applicator.dart — applies one COALESCED wild-magic world event to
// the battle state (docs/WILD_MAGIC_PLAN.md §7.7, as amended by slice 7's
// collect → coalesce → order → resolve phase; see wild_magic_phase.dart).
//
// Shaped like EffectApplicator.apply: one switch over the effect kind, driven
// by a context object. Deliberately NOT inside turn_loop.dart, which is already
// ~5,000 lines.
//
// ── The rule that governs every case below ────────────────────────────────────
// WILD MAGIC IS SYMMETRIC. Every effect hits ALL players, the caster included.
// The skill being tested is *positioning* yourself to benefit from a shared
// effect, not aiming it. There is no "except the caster" clause anywhere in
// this file and there must never be one (§10 invariant 10).
//
// ── Determinism ───────────────────────────────────────────────────────────────
// Both clients run this identically or the per-turn state hash diverges. So:
// no Random/Random.secure/DateTime/hashCode, and never iterate a Set or Map
// for anything order-sensitive — sort first (avatars by playerId, minions by
// id, tiles by (q, r)). ctx.rng is a HashRng seeded from joint per-turn
// entropy under domain tag 0x0C — the COALESCED EVENT's stream (see
// [wildMagicEventSeed]), which is a function of the event and nothing else.
// It is deliberately not keyed on a caster or an encounter-order nonce: this
// file resolves world events, and a world event that rolled differently
// depending on whose cast reached it first would not be one.

import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:rune_duel/engine/hex_grid.dart';

import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance;
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wild_magic_state.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';

import 'wild_magic_phase.dart';

// ── Event ─────────────────────────────────────────────────────────────────────

/// One wild-magic effect that fired this turn, for the UI's resolution reveal.
///
/// A global effect the player cannot see happen is a BUG, not a missing UI
/// nicety: wild magic is untelegraphed by design, so this reveal is the only
/// place either player learns it fired at all.
class WildMagicEvent {
  const WildMagicEvent({
    required this.effect,
    required this.contributingCasterIds,
    required this.bracketSteps,
    this.affectedTiles = const [],
    this.affectedPlayerIds = const [],
    this.note,
  });

  final WildMagicEffectKind effect;

  /// Every caster whose admitted cast contributed a trigger to this event,
  /// deduplicated and sorted by playerId. The effect still hits everyone —
  /// this is attribution for the reveal card, not a targeting field.
  ///
  /// A LIST since slice 7, because an event can now have more than one author:
  /// two casters who both roll Zephyr in one batch produce one gale between
  /// them. It can also be a single id that is not a caster at all — a Phoenix
  /// SAVE names the wizard who rose (see
  /// `DeterministicResolution.applyPhoenixSaves`), which is what the reveal
  /// card wants to say there.
  final List<String> contributingCasterIds;

  /// `max` of the contributing triggers' bracket steps — never their sum.
  final int bracketSteps;

  /// Tiles the effect touched (terrain placed, teleport destinations), for the
  /// animation. Not gameplay-authoritative.
  final List<HexCoord> affectedTiles;

  /// Players the effect touched. Not gameplay-authoritative.
  final List<String> affectedPlayerIds;

  /// Free-text detail for the reveal card (e.g. which axis a chasm took).
  final String? note;

  String get label => kWildMagicEffectLabel[effect] ?? effect.name;
  String get description => kWildMagicEffectDescription[effect] ?? '';
}

// ── Hooks back into the turn loop ─────────────────────────────────────────────

/// Spontaneous Combustion has to re-enter turn-loop machinery (a protocol
/// round trip, then spell resolution). It reaches it through this seam rather
/// than by importing TurnLoop — which would be a cycle, and would put spell
/// resolution back inside the applicator's switch.
///
/// Scattered Gusts deliberately does NOT go through here: it only sets a
/// match-scoped flag, and TurnLoop re-deals the hand after each cast resolves,
/// which is where it can tell a chosen cast from a free one (A8).
abstract class WildMagicHooks {
  /// Spontaneous Combustion: queue a forced reveal-and-cast for each named
  /// player. Asynchronous by nature (it needs a protocol round trip for a
  /// peer's private hand), so it is queued here and drained by TurnLoop after
  /// the synchronous wild-magic sweep — see ForcedCast.
  void queueForcedCast(Set<String> playerIds, int countPerPlayer, String reasonTag);
}

// ── Context ───────────────────────────────────────────────────────────────────

class WildMagicApplyContext {
  WildMagicApplyContext({
    required this.state,
    required this.event,
    required this.rng,
    required this.events,
    this.hooks,
  });

  final BattleState state;

  /// The coalesced world event being resolved: WHAT happens, HOW STRONGLY, and
  /// (attribution only) who contributed a trigger to it.
  ///
  /// Replaced a `caster` + `trigger` pair in slice 7. That pair could not name
  /// an event two casters had both caused, and carrying one arbitrary caster
  /// of several would have handed the applicator a field it must never read —
  /// see the symmetry rule in this file's header.
  final CoalescedWildMagicEvent event;

  /// HashRng seeded from the COALESCED EVENT (domain tag 0x0C). See
  /// [wildMagicEventSeed] for what may and may not enter it.
  final Random rng;

  /// Sink for [WildMagicEvent]s, owned by TurnLoop and cleared per turn.
  final List<WildMagicEvent> events;

  /// Null in unit tests that don't exercise Scattered Gusts / Spontaneous
  /// Combustion; those two then no-op rather than crash.
  final WildMagicHooks? hooks;

  WildMagicEffectKind get effect => event.effect;

  int get bracketSteps => event.effectiveBracketSteps;

  WildMagicState get wild => state.wildMagic;

  /// Living avatars in a deterministic order. NEVER iterate `state.avatars`
  /// directly for anything order-sensitive: its order is construction order,
  /// which two clients need not share.
  List<WizardAvatar> get livingAvatars =>
      state.avatars.where((a) => a.isAlive).toList()
        ..sort((a, b) => a.playerId.compareTo(b.playerId));

  List<Minion> get livingMinions => state.minions.where((m) => m.isAlive).toList()
    ..sort((a, b) => a.id.compareTo(b.id));

  /// All in-bounds tiles, sorted by (q, r).
  List<HexCoord> get sortedTiles {
    final r = state.config.gridRadius;
    final out = <HexCoord>[];
    for (var q = -r; q <= r; q++) {
      for (var rr = -r; rr <= r; rr++) {
        final h = HexCoord(q, rr);
        if (state.battlefield.isInBounds(h)) out.add(h);
      }
    }
    out.sort((a, b) {
      final qc = a.q.compareTo(b.q);
      return qc != 0 ? qc : a.r.compareTo(b.r);
    });
    return out;
  }

  void emit(
    WildMagicEffectKind effect, {
    List<HexCoord> tiles = const [],
    List<String> players = const [],
    String? note,
  }) {
    events.add(
      WildMagicEvent(
        effect: effect,
        contributingCasterIds: event.contributingCasterIds,
        bracketSteps: bracketSteps,
        affectedTiles: tiles,
        affectedPlayerIds: players,
        note: note,
      ),
    );
  }
}

// ── Chasm evacuation (Slice 6) ────────────────────────────────────────────────

/// Where every body a Chasm firing invalidated must end up.
///
/// Anchors, not footprints: [minionDestinations] holds each creature's new
/// [Minion.position], from which its footprint follows. Computed by
/// [WildMagicApplicator.planChasmEvacuation] from the pre-effect board and
/// applied by [WildMagicApplicator.applyChasmEvacuation]; the split is what
/// lets the plan be read from a snapshot that placing the terrain would
/// otherwise have destroyed.
class ChasmEvacuation {
  const ChasmEvacuation({
    required this.avatarDestinations,
    required this.minionDestinations,
    required this.stranded,
  });

  /// playerId → the tile the wizard was displaced to.
  final Map<String, HexCoord> avatarDestinations;

  /// Minion id → the creature's new anchor position.
  final Map<String, HexCoord> minionDestinations;

  /// Bodies the chasm invalidated for which the board offered no legal
  /// destination at all, in the same canonical order they were processed in.
  ///
  /// ── This is an EXCEPTIONAL FALLBACK, not Chasm's intended behaviour ──────
  /// Ordinary Chasm behaviour is that every invalidated body is displaced.
  /// This list is what happens when the board makes that impossible, and it
  /// should be read as a degenerate case being handled deterministically —
  /// never as a second, legitimate outcome of the effect.
  ///
  /// The fallback is exactly three things, chosen because all three are the
  /// PRE-SLICE status quo rather than new game semantics:
  ///
  ///   * the displacement fails;
  ///   * the body stays at its original position (which is now chasm);
  ///   * its id is recorded here, so the condition is observable instead of
  ///     silent.
  ///
  /// Deliberately NOT done: killing the body, deleting or shrinking the
  /// chasm, leaving it at an illegal position it did not already hold, or
  /// teleporting it off-board. Picking any of those would be inventing a rule.
  ///
  /// Expected to stay empty in every reachable position. Opening one axis of a
  /// radius-r board leaves 3r(r+1) + 1 - (2r + 1) tiles standing — 52 at the
  /// default radius 4, 14 at the UI's minimum radius 2 — and EVERY one of them
  /// would have to be a wall, a pre-existing chasm, or a body that is not
  /// itself leaving, before this list gains a single entry. It is constructible
  /// (see the Slice 6 test) but not reachable by ordinary play, which is why
  /// the fallback is a documented degenerate case rather than a designed rule.
  /// What SHOULD happen there is an open question for a future generalized
  /// forced-relocation pass — see docs/WILD_MAGIC_PLAN_VNEXT.md.
  final List<String> stranded;

  bool get isEmpty =>
      avatarDestinations.isEmpty && minionDestinations.isEmpty;
}

// ── Applicator ────────────────────────────────────────────────────────────────

class WildMagicApplicator {
  /// Resolve one COALESCED world event.
  ///
  /// Callers resolve a batch's events in ascending [kWildMagicEffectCode]
  /// order (see `coalesceWildMagicTriggers`), which is today's row-then-element
  /// order expressed so a mutable effect table cannot silently move it. That is
  /// what makes a four-way-balanced spell's four simultaneous effects — and two
  /// casters' overlapping ones — deterministic.
  ///
  /// **Exactly once per effect kind per batch.** Every bound in this file that
  /// is stated "per living wizard" (Mountains' three walls, Spontaneous
  /// Combustion's one forced cast) is enforced by that and nothing else: before
  /// slice 7 a second firing simply re-ran the whole capped selection.
  static void apply(WildMagicApplyContext ctx) {
    switch (ctx.effect) {
      // ── Row 1 (`000`) ─────────────────────────────────────────────────
      case WildMagicEffectKind.burningHot:
        _burningHot(ctx);
      case WildMagicEffectKind.mountains:
        _mountains(ctx);
      case WildMagicEffectKind.manaFlood:
        _manaFlood(ctx);
      case WildMagicEffectKind.zephyr:
        _zephyr(ctx);

      // ── Row 2 (`111`) ─────────────────────────────────────────────────
      case WildMagicEffectKind.spontaneousCombustion:
        _spontaneousCombustion(ctx);
      case WildMagicEffectKind.chasm:
        _chasm(ctx);
      case WildMagicEffectKind.glacier:
        _glacier(ctx);
      case WildMagicEffectKind.updraft:
        _updraft(ctx);

      // ── Row 3 (`0123`) ────────────────────────────────────────────────
      case WildMagicEffectKind.phoenix:
        _phoenix(ctx);
      case WildMagicEffectKind.statuesque:
        _statuesque(ctx);
      case WildMagicEffectKind.ripplingReflections:
        _ripplingReflections(ctx);
      case WildMagicEffectKind.scatteredGusts:
        _scatteredGusts(ctx);
    }
  }

  // ── Row 1, Fire — Burning Hot ─────────────────────────────────────────────
  // "All spell effects next turn deal +1 fire damage [+1 damage per effect]."

  static void _burningHot(WildMagicApplyContext ctx) {
    final amount = 1 + ctx.bracketSteps;
    // Applies to EVERY player's spells next turn, per damage effect — so a
    // three-formula spell gets it three times. Read back in
    // EffectApplicator._applyDamage via WildMagicState.spellDamageBonusFor.
    ctx.wild.armSpellDamageBonus(ctx.state.turnNumber + 1, amount);
    ctx.emit(
      WildMagicEffectKind.burningHot,
      players: [for (final a in ctx.livingAvatars) a.playerId],
      note: '+$amount damage to every spell effect next turn',
    );
  }

  // ── Row 1, Earth — Mountains ──────────────────────────────────────────────
  // "All adjacent cells become earth walls 2 turns [+1 turn]."

  /// The most walls Mountains may raise around any one living wizard.
  ///
  /// "All adjacent cells" is up to six, and six walls around every wizard at
  /// once seals the board — the effect stopped being terrain and became a
  /// win condition. Capped at three (Slice 5), which still reshapes the
  /// neighbourhood without enclosing anyone.
  ///
  /// The cap is per LIVING WIZARD, not per firing: two wizards select three
  /// each, and if they pick the same tile it is raised once (see [_mountains]).
  static const int kMountainsWallsPerWizard = 3;

  static void _mountains(WildMagicApplyContext ctx) {
    // A5: "all adjacent cells" has no antecedent in the design doc. Walling
    // the tiles adjacent to every living WIZARD AVATAR (not minions) is the
    // symmetric, board-wide reading.
    //
    // ── Eligibility (unchanged by Slice 5) ────────────────────────────────
    // A neighbour tile may become a Mountain when it is:
    //   * in bounds — `battlefield.isInBounds`;
    //   * carrying NO tile effect at all, so this can never become a hidden
    //     destroy-terrain effect (that covers existing walls, chasms, ice,
    //     lava, conveyors, slow tiles and illusion terrain alike);
    //   * unoccupied by any living avatar or any tile of a living minion's
    //     footprint, so nobody is buried where they stand.
    // Clouds are deliberately NOT consulted: a cloud is not a tile effect and
    // sits above the ground, so a tile under one is eligible. That is the
    // behaviour this slice inherited and preserves.
    //
    // ── One snapshot for everybody (Slice 5) ──────────────────────────────
    // Eligibility is read from a snapshot taken BEFORE any wall goes up, so a
    // wall raised for the first wizard cannot shrink the second wizard's
    // candidate set. Under the old uncapped rule this was invisible — walling
    // every eligible tile gives the same union whatever order you walk it in —
    // but with a cap of three it decides which three each wizard gets, and a
    // result that depended on player order would be a rules artefact of the
    // alphabet.
    final selection = selectMountainTiles(ctx);

    // ── Application ───────────────────────────────────────────────────────
    // The union of every wizard's picks, applied once, in canonical tile
    // order. A tile two wizards both chose is raised once and buys neither of
    // them a replacement fourth pick.
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    final placed = <HexCoord>{for (final tiles in selection.values) ...tiles}
        .toList()
      ..sort(_byQThenR);
    for (final tile in placed) {
      // A Mountains wall is an ImpassableTile like any other: it blocks
      // line of sight and carries the Earth-flavor HP pool, so it can be
      // broken early even though it would also expire on its own.
      ctx.state.placeTerrain(tile, const ImpassableTile());
      ctx.state.expiringTiles[tile] = expiry;
    }
    ctx.emit(
      WildMagicEffectKind.mountains,
      tiles: placed,
      players: [for (final a in ctx.livingAvatars) a.playerId],
    );
  }

  /// Each living wizard's chosen Mountains tiles, keyed by playerId, in
  /// canonical player order — the whole of the selection decision, separated
  /// from applying it so both halves can be reasoned about (and tested)
  /// independently.
  ///
  /// **Consumes [ctx].rng.** Call once per firing; [_mountains] does.
  ///
  /// Every wizard's candidate set is derived from ONE snapshot taken before
  /// this method returns anything, so no wizard's picks can narrow another's.
  /// The two mutable inputs are snapshotted explicitly rather than read live:
  ///
  ///   * the tiles already carrying a tile effect — the one thing wall
  ///     placement changes, and the reason a snapshot is needed at all;
  ///   * the tiles a living body stands on — which placement cannot change,
  ///     snapshotted anyway so the guarantee is structural rather than an
  ///     argument about what `placeTerrain` happens not to touch today.
  ///
  /// Draws come from [WildMagicApplyContext.rng]: the coalesced event's
  /// `HashRng`, seeded from this turn's joint entropy under the wild-magic
  /// EVENT domain tag (0x0C), the resolution batch, the effect code and the
  /// effective bracket. That stream is private to this event and no other
  /// effect reads it, so it already IS the Mountains selection subdomain —
  /// both devices build identical candidate lists and draw identically from
  /// it. Nothing here reads private data, UI state, or object identity.
  ///
  /// Since slice 7 this runs ONCE per batch however many casters rolled
  /// Mountains, which is what finally makes [kMountainsWallsPerWizard] a bound
  /// on the PHASE rather than on a single firing.
  @visibleForTesting
  static Map<String, List<HexCoord>> selectMountainTiles(
    WildMagicApplyContext ctx,
  ) {
    final blockedBefore = ctx.state.tileEffects.keys.toSet();
    final occupiedBefore = _occupiedTiles(ctx.state);

    final out = <String, List<HexCoord>>{};
    for (final av in ctx.livingAvatars) {
      // Sorted canonically BEFORE any draw, so the choice cannot inherit
      // `_neighbors`' declaration order or any Dart collection's insertion
      // order. Drawn without replacement, exactly as `ForcedCast` picks hand
      // slots.
      final candidates = mountainsCandidates(
        ctx.state,
        av.position,
        blocked: blockedBefore,
        occupied: occupiedBefore,
      );
      final chosen = <HexCoord>[];
      for (var i = 0;
          i < kMountainsWallsPerWizard && candidates.isNotEmpty;
          i++) {
        chosen.add(candidates.removeAt(ctx.rng.nextInt(candidates.length)));
      }
      out[av.playerId] = chosen..sort(_byQThenR);
    }
    return out;
  }

  /// The tiles adjacent to [center] that may become Mountains, canonically
  /// sorted. [blocked] and [occupied] are the snapshot; see
  /// [selectMountainTiles].
  ///
  /// The eligibility rules themselves are unchanged by the cap — see
  /// [_mountains]'s comment for what each one is for.
  @visibleForTesting
  static List<HexCoord> mountainsCandidates(
    BattleState state,
    HexCoord center, {
    required Set<HexCoord> blocked,
    required Set<HexCoord> occupied,
  }) =>
      <HexCoord>[
        for (final n in _neighbors(center))
          if (state.battlefield.isInBounds(n) &&
              !blocked.contains(n) &&
              !occupied.contains(n))
            n,
      ]..sort(_byQThenR);

  /// Canonical hex order: q ascending, then r. The one tie-break for anything
  /// whose result must not depend on how a Dart collection happened to be
  /// built.
  static int _byQThenR(HexCoord a, HexCoord b) {
    final qc = a.q.compareTo(b.q);
    return qc != 0 ? qc : a.r.compareTo(b.r);
  }

  // ── Row 1, Water — Mana Flood ─────────────────────────────────────────────
  // "All mana bars immediately fill."

  static void _manaFlood(WildMagicApplyContext ctx) {
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      // Set directly rather than through TurnLoop._applyManaGain: the mirror
      // triggers that helper fires (Reflections' manaMirror) would double-count
      // against an effect that already fills EVERY bar to full. Filling a full
      // bar is a no-op, so there is nothing left for a mirror to add.
      av.mana = av.maxMana;
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.manaFlood, players: touched);
  }

  // ── Row 1, Air — Zephyr ───────────────────────────────────────────────────
  // "All players and minions teleported to random locations."

  static void _zephyr(WildMagicApplyContext ctx) {
    // Deterministic procedure — order matters far more than cleverness here.
    // 1. Eligible tiles: in-bounds, sorted by (q, r), minus blocked terrain.
    //    Blocked tiles are excluded for EVERYONE, including flying entities:
    //    the simplest correct call, and it keeps the shuffle a single draw
    //    rather than a per-entity filter (A11's flying exemption is about
    //    movement, not about where a gale can deposit you).
    final pool = [
      for (final t in ctx.sortedTiles)
        if (ctx.state.tileEffects[t] is! ImpassableTile &&
            ctx.state.tileEffects[t] is! ChasmTile)
          t,
    ];
    // 2. Shuffle a DETERMINISTICALLY SORTED list (never the output of a Set or
    //    Map iteration) with the joint-entropy RNG.
    pool.shuffle(ctx.rng);

    // 3. Assign in fixed entity order, one entity per tile.
    var next = 0;
    final landed = <HexCoord>[];
    final movedPlayers = <String>[];
    for (final av in ctx.livingAvatars) {
      if (next >= pool.length) break;
      final dest = pool[next++];
      // 5. position and occupancy are two mirrors of the same fact — update
      //    them together or they drift apart into a long-lived desync.
      av.position = dest;
      ctx.state.battlefield.occupancy[av.playerId] = dest;
      landed.add(dest);
      movedPlayers.add(av.playerId);
    }
    for (final m in ctx.livingMinions) {
      if (next >= pool.length) break;
      m.position = pool[next++];
      landed.add(m.position);
    }

    // 6. Landing on FloorIsLava / SlowTile / ConveyorTile is deliberately NOT
    //    routed through resolveTileEntry. A gale that drops everyone at once
    //    and then cascades conveyor pushes in entity order would make the
    //    final board depend on iteration order in a way that is far harder to
    //    keep in lockstep than the loss of flavour is worth. A teleport onto a
    //    conveyor gets pushed at end of turn by _endOfTurn's standing-on-a-
    //    conveyor sweep, which is the same outcome one phase later.
    ctx.emit(
      WildMagicEffectKind.zephyr,
      tiles: landed,
      players: movedPlayers,
    );
  }

  // ── Row 2, Fire — Spontaneous Combustion ──────────────────────────────────
  // "A random spell from each player's hand is cast at a random target."

  static void _spontaneousCombustion(WildMagicApplyContext ctx) {
    // Cannot resolve inline: a peer's hand CONTENTS are private (only the
    // positions are public, via DrawSchedule), so the local client does not
    // hold the peer's selected spell and cannot fabricate it without
    // desyncing. Queued here and drained by TurnLoop through ForcedCast, which
    // does the public slot selection, the reveal round trip, and the
    // verification. See WILD_MAGIC_PLAN.md §3.1/§9.5.
    //
    // EXACTLY ONE cast per living wizard, whatever the bracket (Slice 5).
    // `1 + bracketSteps` turned a bracket-2 firing into three forced casts
    // each, which shredded both hands and cascaded far past what the effect
    // describes. Bracket still says the trigger fired at strength N — it is
    // still carried on the trigger and reported in the event — it just no
    // longer multiplies how many spells leave your hand.
    //
    // "Living" is read at the instant the trigger fires, from the same
    // `livingAvatars` every other wild-magic effect uses. A wizard who is dead
    // now does not get a forced cast because a Phoenix might raise them later:
    // this effect resolves immediately and stores no targeting state.
    final affected = {for (final a in ctx.livingAvatars) a.playerId};
    ctx.hooks?.queueForcedCast(
      affected,
      1,
      'spontaneousCombustion',
    );
    ctx.emit(
      WildMagicEffectKind.spontaneousCombustion,
      players: affected.toList()..sort(),
    );
  }

  // ── Row 2, Earth — Chasm ──────────────────────────────────────────────────
  // "A randomly drawn line bisects the battlefield. It is impassible (without
  //  flying), and indestructible for 2[+1] turns, but has no bearing on
  //  targeting."
  //
  // ── Occupied-tile behaviour (Slice 6) ─────────────────────────────────────
  // Ratified: the chasm opens REGARDLESS of who is standing there, and any
  // living body whose position (or, for a creature, whose footprint) the new
  // chasm INVALIDATES is immediately and involuntarily displaced to the
  // nearest legal solid position. Ties among equally-near destinations are
  // broken with this trigger's own RNG.
  //
  // "Invalidates" is the load-bearing word, and it is what preserves A11: a
  // chasm is ignored by flying, so it does not invalidate a flyer's position
  // and a flying wizard or creature is simply not displaced. See
  // [planChasmEvacuation]'s Flying note.
  //
  // Before this slice the chasm simply opened under people and left them
  // standing in it — a wizard on a chasm tile could still be shot at (chasm
  // does not block targeting) but could be walled in by their own hole. This
  // is emergency displacement caused by terrain collapse, NOT movement: it
  // ignores pathfinding, movement allowance, line of sight, intervening
  // terrain and route connectivity entirely. We choose a safe final position;
  // we do not walk anybody there.
  //
  // ── Why the plan is computed before the terrain is placed ─────────────────
  // Every evacuation is resolved against ONE snapshot of the pre-effect board,
  // so no evacuee's destination can depend on where another evacuee has
  // already physically moved. Destinations are nevertheless RESERVED as they
  // are assigned, so two displaced bodies can never be handed overlapping
  // ground. See [planChasmEvacuation].

  static void _chasm(WildMagicApplyContext ctx) {
    // A10: "bisects" means through the centre, so the only free choice left is
    // WHICH of the three hex axes. Uniform over the three, from joint entropy.
    // This is the FIRST draw of the trigger's stream; every evacuation draw
    // below follows it.
    final axis = ctx.rng.nextInt(3);
    bool onAxis(HexCoord h) => switch (axis) {
          0 => h.q == 0,
          1 => h.r == 0,
          _ => h.q + h.r == 0,
        };

    // 1. Every terrain cell this firing will open, in canonical (q, r) order.
    final placed = [
      for (final t in ctx.sortedTiles)
        if (onAxis(t)) t,
    ];
    final opening = placed.toSet();

    // 2. Who the opening invalidates, and where each of them goes — decided
    //    entirely from the pre-effect board, before a single tile changes.
    final evacuation = planChasmEvacuation(ctx, opening);

    // 3. Open the chasm.
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    for (final t in placed) {
      // Overwrites whatever terrain was there. A chasm opening in the ground
      // destroying a wall is the reading that matches "the ground splits";
      // the indestructibility clause protects the chasm FROM later effects
      // (see _blockedForTerrainPlacement), not the terrain from the chasm.
      ctx.state.placeTerrain(t, const ChasmTile());
      ctx.state.expiringTiles[t] = expiry;
    }

    // 4. Drop everybody the hole displaced onto the ground it left them.
    applyChasmEvacuation(ctx, evacuation);

    ctx.emit(
      WildMagicEffectKind.chasm,
      tiles: placed,
      // Displaced wizards only — `affectedPlayerIds` is the reveal card's
      // "who did this touch", and a chasm that opened under nobody touches
      // nobody. Creatures have no player-id channel on the event; their
      // relocation shows up in the animation via the board state.
      players: evacuation.avatarDestinations.keys.toList()..sort(),
      // UNCHANGED FORMAT. The axis note is asserted verbatim by existing
      // tests and read by the reveal card; displacement detail does not
      // belong in it.
      note: switch (axis) { 0 => 'q = 0', 1 => 'r = 0', _ => 'q + r = 0' },
    );
  }

  /// Plans every Chasm evacuation from ONE pre-effect snapshot of the board.
  ///
  /// Pure with respect to [BattleState] — it mutates nothing, which is what
  /// lets `_chasm` call it before placing any terrain and still describe the
  /// post-placement world. **Consumes [WildMagicApplyContext.rng]:** exactly
  /// one draw per evacuee that finds a destination (see "RNG" below).
  ///
  /// [opening] is the complete set of cells this firing will turn into chasm.
  ///
  /// ── The snapshot ──────────────────────────────────────────────────────────
  /// Two things are read once, up front, and never re-read:
  ///
  ///   * `state.tileEffects` — the terrain that decides which tiles a body may
  ///     stand on. Snapshotted because `_chasm` places terrain afterwards and
  ///     a live read would then answer differently depending on when it ran.
  ///   * every living body's tiles (`_occupiedTiles`) — each living avatar's
  ///     tile and each living creature's whole footprint. Snapshotted so that
  ///     one evacuee physically moving cannot widen or narrow the next
  ///     evacuee's candidate set.
  ///
  /// ── Evacuees ─────────────────────────────────────────────────────────────
  /// A living avatar standing on a cell in [opening]; a living creature ANY of
  /// whose footprint tiles is in [opening] — the whole creature moves, never
  /// just the struck tile. Dead bodies are neither evacuated nor counted as
  /// occupancy, which is exactly the existing rule (`_occupiedTiles`,
  /// `tileOccupied`): this slice does not invent corpse physics.
  ///
  /// ── Flying ───────────────────────────────────────────────────────────────
  /// A FLYING body is never an evacuee. `WILD_MAGIC_PLAN.md` A11 and
  /// `WILD_MAGIC_PLAN_VNEXT.md` both say a chasm is ignored by flying, and the
  /// ratified evacuation rule displaces a body only when the chasm actually
  /// INVALIDATES its position — which, for something that is not standing on
  /// the ground, it does not. So a flying wizard (`WizardAvatar.isFlying`,
  /// i.e. Updraft) and a flying creature (`SummonAbility.flying`) both stay
  /// exactly where they are when the ground opens under them.
  ///
  /// The exemption lives at evacuee COLLECTION, not inside the legality
  /// predicate: `free` below stays a single flying-agnostic definition of
  /// solid ground, so there is never a second, per-entity notion of where a
  /// body may stand. Flying entities simply never enter this planner on
  /// Chasm's account.
  ///
  /// This changes nothing about Zephyr, which deliberately excludes blocked
  /// tiles for everyone (a gale can deposit a flyer anywhere it likes), nor
  /// about flying movement anywhere else.
  ///
  /// ── Legal destination ────────────────────────────────────────────────────
  /// A candidate anchor is legal when EVERY tile of the body that would sit
  /// there is:
  ///
  ///   * in bounds (`battlefield.isInBounds`);
  ///   * not a cell in [opening] — you cannot be evacuated into the hole that
  ///     is evacuating you;
  ///   * not blocked terrain in the snapshot — `tileBlocksMovement`, the
  ///     engine's one authoritative "a body may not be here" terrain
  ///     predicate (walls and PRE-EXISTING chasms). Nothing else is excluded:
  ///     ice, lava, conveyors, slow ground and clouds are all places a body
  ///     may legally stand, and inventing new exclusions for them here would
  ///     be a second, contradictory definition of solid ground;
  ///   * not held by a living body that is STAYING (see below);
  ///   * not already reserved for an earlier evacuee.
  ///
  /// Reachability is deliberately not consulted. This is not a walk.
  ///
  /// ── Who blocks whom ──────────────────────────────────────────────────────
  /// The snapshot's occupancy is split in two. Bodies that are NOT evacuating
  /// hold their ground and block destinations. Bodies that ARE evacuating are
  /// leaving, so the tiles they are about to vacate do not block anyone —
  /// which matters for a creature only partly over the hole, whose surviving
  /// footprint tiles are perfectly good ground once it has stepped off them.
  /// New reservations then re-block ground as it is claimed.
  ///
  /// ── Order and RNG ────────────────────────────────────────────────────────
  /// Evacuees are processed in one total canonical order: every avatar by
  /// `playerId`, then every creature by `id`. For each, the search widens by
  /// hex distance from the body's own anchor — distance 1, then 2, and so on
  /// (distance 0 is excluded: that is the ground being taken away). The first
  /// distance holding at least one legal candidate is the one used; candidates
  /// within it are collected in canonical (q, r) order and ONE draw of
  /// `ctx.rng` picks among them. So a body may be displaced further than a
  /// body ahead of it in the order whose reservations took all the near
  /// ground — intentional, and the alternative (assign, then untangle
  /// collisions) is exactly the order-dependence this design exists to avoid.
  ///
  /// `HashRng.nextInt(1)` returns without consuming a byte, so a body with
  /// only one legal destination costs nothing from the stream: the draw count
  /// is "one per AMBIGUOUS evacuation", and calling it unconditionally is
  /// simply the shorter way to write that.
  @visibleForTesting
  static ChasmEvacuation planChasmEvacuation(
    WildMagicApplyContext ctx,
    Set<HexCoord> opening,
  ) {
    final state = ctx.state;

    // ── The one snapshot ──────────────────────────────────────────────────
    final terrainBefore = Map<HexCoord, TileEffect>.of(state.tileEffects);
    final occupiedBefore = _occupiedTiles(state);
    final board = ctx.sortedTiles; // in-bounds, canonical (q, r) order

    // ── Evacuees, in the one total canonical order ────────────────────────
    // Flying bodies are filtered out HERE, at collection, and never reach the
    // search below. A11 says a chasm is ignored by flying, so a chasm opening
    // under a flyer does not invalidate its position and there is nothing to
    // evacuate it from — see this method's "Flying" note. Doing it here rather
    // than by threading an exemption through `free` keeps ONE definition of
    // legal ground: `free` answers "may a body stand here", and that answer
    // does not change depending on who is asking.
    //
    // A flyer that stays put is still a body: it remains in `staying` below
    // and keeps blocking the ground it is on, exactly like any other body the
    // chasm did not move.
    final avatars = [
      for (final a in ctx.livingAvatars)
        if (!a.isFlying && opening.contains(a.position)) a,
    ];
    final minions = [
      for (final m in ctx.livingMinions)
        if (!m.abilities.contains(SummonAbility.flying) &&
            m.occupiedTiles.any(opening.contains))
          m,
    ];

    // Ground that is being given up by the bodies standing on it. Removing it
    // from the static occupancy is what stops a half-swallowed creature's own
    // surviving footprint from blocking its neighbour's escape.
    final vacating = <HexCoord>{
      for (final a in avatars) a.position,
      for (final m in minions) ...m.occupiedTiles,
    };
    final staying = occupiedBefore.difference(vacating);

    final reserved = <HexCoord>{};
    bool free(HexCoord t) =>
        state.battlefield.isInBounds(t) &&
        !opening.contains(t) &&
        !tileBlocksMovement(terrainBefore[t]) &&
        !staying.contains(t) &&
        !reserved.contains(t);

    /// Nearest legal anchor for a body whose tiles at anchor `c` are
    /// `shape(c)`, or null if the board has nowhere to put it.
    HexCoord? nearest(HexCoord origin, List<HexCoord> Function(HexCoord) shape) {
      // 2 * radius is the board's diameter — the furthest two in-bounds tiles
      // can be from each other, so the search is exhaustive by construction.
      final maxDistance = 2 * state.config.gridRadius;
      for (var d = 1; d <= maxDistance; d++) {
        final tier = [
          for (final c in board)
            if (hexDistance(origin, c) == d && shape(c).every(free)) c,
        ];
        if (tier.isEmpty) continue;
        return tier[ctx.rng.nextInt(tier.length)];
      }
      return null;
    }

    final avatarDestinations = <String, HexCoord>{};
    final minionDestinations = <String, HexCoord>{};
    final stranded = <String>[];

    for (final a in avatars) {
      final dest = nearest(a.position, (c) => [c]);
      if (dest == null) {
        // EXCEPTIONAL FALLBACK, not ordinary Chasm behaviour: the board
        // offered nowhere legal at any distance. Displacement fails, the body
        // stays exactly where it is — the pre-slice status quo, not a new rule
        // — and it keeps holding its ground so nobody else is handed it. See
        // [ChasmEvacuation.stranded] for why this is the only choice here that
        // invents nothing.
        stranded.add(a.playerId);
        reserved.add(a.position);
        continue;
      }
      avatarDestinations[a.playerId] = dest;
      reserved.add(dest);
    }

    for (final m in minions) {
      List<HexCoord> shape(HexCoord c) =>
          footprintFor(c, m.abilities, m.sizeBonus);
      final dest = nearest(m.position, shape);
      if (dest == null) {
        stranded.add(m.id);
        reserved.addAll(m.occupiedTiles);
        continue;
      }
      minionDestinations[m.id] = dest;
      reserved.addAll(shape(dest));
    }

    return ChasmEvacuation(
      avatarDestinations: avatarDestinations,
      minionDestinations: minionDestinations,
      stranded: stranded,
    );
  }

  /// Moves the bodies [planChasmEvacuation] assigned destinations to.
  ///
  /// INVOLUNTARY by construction: it writes position and occupancy and does
  /// nothing else. It does not break Statuesque (`statuesque_break.dart`'s
  /// inventory lists the five voluntary channels; terrain is not one of them),
  /// does not spend a Scattered Gust (spent only by a chosen cast), does not
  /// touch movement budget, and does not run `resolveTileEntry` — following
  /// Zephyr, whose comment explains why a mass relocation must not cascade
  /// conveyor pushes in entity order. Ice, lava and conveyors under an
  /// evacuee are collected by the end-of-turn sweep like anyone else's.
  @visibleForTesting
  static void applyChasmEvacuation(
    WildMagicApplyContext ctx,
    ChasmEvacuation evacuation,
  ) {
    for (final av in ctx.livingAvatars) {
      final dest = evacuation.avatarDestinations[av.playerId];
      if (dest == null) continue;
      // position and occupancy are two mirrors of the same fact — update them
      // together or they drift apart into a long-lived desync.
      av.position = dest;
      ctx.state.battlefield.occupancy[av.playerId] = dest;
    }
    for (final m in ctx.livingMinions) {
      final dest = evacuation.minionDestinations[m.id];
      if (dest == null) continue;
      m.position = dest;
    }
  }

  // ── Row 2, Water — Glacier ────────────────────────────────────────────────
  // "Tiles without existing terrain all become Ice tiles for 2 [+1] turns;
  //  when moving onto ice a player continues moving that direction."

  static void _glacier(WildMagicApplyContext ctx) {
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    final placed = <HexCoord>[];
    for (final t in ctx.sortedTiles) {
      if (ctx.state.tileEffects.containsKey(t)) continue;
      ctx.state.placeTerrain(t, const IceTile());
      ctx.state.expiringTiles[t] = expiry;
      placed.add(t);
    }
    ctx.emit(WildMagicEffectKind.glacier, tiles: placed);
  }

  // ── Row 2, Air — Updraft ──────────────────────────────────────────────────
  // "All players gain flying for 2 [+1] turns."

  static void _updraft(WildMagicApplyContext ctx) {
    final turns = 2 + ctx.bracketSteps;
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      StatusEffect.applyTo(
          av.activeStatusEffects, StatusEffectId.flying, const {}, turns);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.updraft, players: touched);
  }

  // ── Row 3, Fire — Phoenix ─────────────────────────────────────────────────
  // "All players gain: the next time they would die, they respawn with 1
  //  hitpoint instead."

  static void _phoenix(WildMagicApplyContext ctx) {
    // One-shot per player, consumed by the death it saves — see
    // DeterministicResolution.applyPhoenixSaves. Bounded since Slice 4: the
    // save covers the two rounds AFTER this one, so it cannot rescue a wizard
    // from a death still resolving in the round that granted it, and it does
    // not sit on the board for the rest of the match waiting to be spent.
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      ctx.wild.armPhoenix(av.playerId, triggerTurn: ctx.state.turnNumber);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.phoenix, players: touched);
  }

  // ── Row 3, Earth — Statuesque ─────────────────────────────────────────────
  // "All players return to full health and mana each turn; the effect is lost
  //  if they move or cast a spell."

  static void _statuesque(WildMagicApplyContext ctx) {
    // A6's "the latch begins after the turn it fires" is now expressed by the
    // window itself: it covers the two rounds AFTER this one, so the cast that
    // triggered it cannot immediately break its own effect and there is no
    // pending set to promote. Healing happens at the START of each covered
    // round (resolveWildMagicRoundStart), not at end of turn.
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      ctx.wild.armStatuesque(av.playerId, triggerTurn: ctx.state.turnNumber);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.statuesque, players: touched);
  }

  // ── Row 3, Water — Rippling Reflections ───────────────────────────────────
  // "Going forward, upon spell resolution, every spell has a 50% chance to
  //  fizzle and a 50% chance to resolve twice. Every time a spell fizzles the
  //  odds shift 10% towards doubling, and vice versa."

  static void _ripplingReflections(WildMagicApplyContext ctx) {
    // Bounded since Slice 4 to the single round after this one — "going
    // forward" turned out to mean "for the rest of the match", which no other
    // row-3 effect does. The percentage is still idempotent across re-arms: a
    // second Rippling must NOT reset a drifted counter back to 50, or a player
    // who keeps casting the spell that carries it re-arms it forever.
    ctx.wild.armRippling(triggerTurn: ctx.state.turnNumber);
    ctx.emit(
      WildMagicEffectKind.ripplingReflections,
      note: 'fizzle chance ${ctx.wild.ripplingFizzlePct}%',
    );
  }

  // ── Row 3, Air — Scattered Gusts ──────────────────────────────────────────
  // "Going forward, every time a player casts a spell all their bookmarks are
  //  blown out of place and they randomly find a new set of spells to mark."

  static void _scatteredGusts(WildMagicApplyContext ctx) {
    // Per wizard since Slice 4, and one redeal each: the old global bool blew
    // every player's bookmarks loose after every cast for the rest of the
    // match. Each affected wizard now carries their own pending Gust from next
    // round until their own next voluntary cast spends it; free casts are
    // exempt (A8) or Spontaneous Combustion becomes a hand-shredder.
    //
    // Armed for the living, matching every other row-3 effect's symmetry —
    // see this file's header. The old bool had no target list at all, so
    // "everyone, forever, including whoever arrives later" was implicit.
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      ctx.wild
          .armScatteredGusts(av.playerId, triggerTurn: ctx.state.turnNumber);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.scatteredGusts, players: touched);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// The six hex neighbours, in a fixed order.
  static List<HexCoord> _neighbors(HexCoord c) => [
        HexCoord(c.q + 1, c.r),
        HexCoord(c.q + 1, c.r - 1),
        HexCoord(c.q, c.r - 1),
        HexCoord(c.q - 1, c.r),
        HexCoord(c.q - 1, c.r + 1),
        HexCoord(c.q, c.r + 1),
      ];

  /// Every tile a living body stands on: each living avatar's tile and each
  /// living minion's whole footprint.
  ///
  /// The set form of what used to be a per-tile `_isOccupied` predicate.
  /// Mountains needs it snapshotted rather than queried, and one definition of
  /// "occupied" beats a predicate and a set that could drift apart.
  static Set<HexCoord> _occupiedTiles(BattleState state) => {
        for (final a in state.avatars)
          if (a.isAlive) a.position,
        for (final m in state.minions)
          if (m.isAlive) ...m.occupiedTiles,
      };
}

