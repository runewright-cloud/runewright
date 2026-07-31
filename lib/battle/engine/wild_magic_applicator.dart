// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_applicator.dart — applies a fired WildMagicTrigger to the battle
// state (docs/WILD_MAGIC_PLAN.md §7.7).
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
// entropy under domain tag 0x09.

import 'dart:math' show Random;

import 'package:rune_duel/engine/hex_grid.dart';

import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wild_magic_state.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';

// ── Event ─────────────────────────────────────────────────────────────────────

/// One wild-magic effect that fired this turn, for the UI's resolution reveal.
///
/// A global effect the player cannot see happen is a BUG, not a missing UI
/// nicety: wild magic is untelegraphed by design, so this reveal is the only
/// place either player learns it fired at all.
class WildMagicEvent {
  const WildMagicEvent({
    required this.effect,
    required this.casterId,
    required this.bracketSteps,
    this.affectedTiles = const [],
    this.affectedPlayerIds = const [],
    this.note,
  });

  final WildMagicEffectKind effect;

  /// Whose spell carried the trigger. The effect still hits everyone — this is
  /// attribution for the reveal card, not a targeting field.
  final String casterId;

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
    required this.caster,
    required this.rng,
    required this.trigger,
    required this.events,
    this.hooks,
  });

  final BattleState state;

  /// Whose spell carried the trigger. Used for event attribution and nothing
  /// else — see the symmetry rule in this file's header.
  final WizardAvatar caster;

  /// HashRng seeded from joint per-turn entropy, domain tag 0x09.
  final Random rng;

  final WildMagicTrigger trigger;

  /// Sink for [WildMagicEvent]s, owned by TurnLoop and cleared per turn.
  final List<WildMagicEvent> events;

  /// Null in unit tests that don't exercise Scattered Gusts / Spontaneous
  /// Combustion; those two then no-op rather than crash.
  final WildMagicHooks? hooks;

  int get bracketSteps => trigger.bracketSteps;

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
        casterId: caster.playerId,
        bracketSteps: bracketSteps,
        affectedTiles: tiles,
        affectedPlayerIds: players,
        note: note,
      ),
    );
  }
}

// ── Applicator ────────────────────────────────────────────────────────────────

class WildMagicApplicator {
  /// Resolve one trigger. Callers fire triggers in row-then-element order (see
  /// WildMagic.triggersFor), which is what makes a four-way-balanced spell's
  /// four simultaneous effects deterministic.
  static void apply(WildMagicApplyContext ctx) {
    switch (ctx.trigger.effect) {
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

  static void _mountains(WildMagicApplyContext ctx) {
    // A5: "all adjacent cells" has no antecedent in the design doc. Walling
    // the tiles adjacent to every living WIZARD AVATAR (not minions) is the
    // symmetric, board-wide reading. Tiles that already carry terrain are
    // skipped so this can't become a hidden destroy-terrain effect, and
    // occupied tiles are skipped so nobody gets buried where they stand.
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    final placed = <HexCoord>[];
    for (final av in ctx.livingAvatars) {
      for (final n in _neighbors(av.position)) {
        if (!ctx.state.battlefield.isInBounds(n)) continue;
        if (ctx.state.tileEffects.containsKey(n)) continue;
        if (_isOccupied(ctx.state, n)) continue;
        ctx.state.tileEffects[n] = const ImpassableTile();
        ctx.state.expiringTiles[n] = expiry;
        placed.add(n);
      }
    }
    ctx.emit(
      WildMagicEffectKind.mountains,
      tiles: placed,
      players: [for (final a in ctx.livingAvatars) a.playerId],
    );
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
    final affected = {for (final a in ctx.livingAvatars) a.playerId};
    ctx.hooks?.queueForcedCast(
      affected,
      1 + ctx.bracketSteps,
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

  static void _chasm(WildMagicApplyContext ctx) {
    // A10: "bisects" means through the centre, so the only free choice left is
    // WHICH of the three hex axes. Uniform over the three, from joint entropy.
    final axis = ctx.rng.nextInt(3);
    bool onAxis(HexCoord h) => switch (axis) {
          0 => h.q == 0,
          1 => h.r == 0,
          _ => h.q + h.r == 0,
        };
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    final placed = <HexCoord>[];
    for (final t in ctx.sortedTiles) {
      if (!onAxis(t)) continue;
      // Overwrites whatever terrain was there. A chasm opening in the ground
      // destroying a wall is the reading that matches "the ground splits";
      // the indestructibility clause protects the chasm FROM later effects
      // (see _blockedForTerrainPlacement), not the terrain from the chasm.
      ctx.state.tileEffects[t] = const ChasmTile();
      ctx.state.expiringTiles[t] = expiry;
      ctx.state.illusionTerrainTiles.remove(t);
      placed.add(t);
    }
    ctx.emit(
      WildMagicEffectKind.chasm,
      tiles: placed,
      note: switch (axis) { 0 => 'q = 0', 1 => 'r = 0', _ => 'q + r = 0' },
    );
  }

  // ── Row 2, Water — Glacier ────────────────────────────────────────────────
  // "Tiles without existing terrain all become Ice tiles for 2 [+1] turns;
  //  when moving onto ice a player continues moving that direction."

  static void _glacier(WildMagicApplyContext ctx) {
    final expiry = ctx.state.turnNumber + 1 + ctx.bracketSteps;
    final placed = <HexCoord>[];
    for (final t in ctx.sortedTiles) {
      if (ctx.state.tileEffects.containsKey(t)) continue;
      ctx.state.tileEffects[t] = const IceTile();
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
      av.activeStatusEffects
          .removeWhere((fx) => fx.effectTypeId == StatusEffectId.flying);
      av.activeStatusEffects.add(
        StatusEffect(
          effectTypeId: StatusEffectId.flying,
          remainingTurns: turns,
          modifiers: const {},
        ),
      );
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.updraft, players: touched);
  }

  // ── Row 3, Fire — Phoenix ─────────────────────────────────────────────────
  // "All players gain: the next time they would die, they respawn with 1
  //  hitpoint instead."

  static void _phoenix(WildMagicApplyContext ctx) {
    // One-shot per player, consumed by the death it saves — see
    // TurnLoop._reapDeadAvatars.
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      ctx.wild.phoenixPlayerIds.add(av.playerId);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.phoenix, players: touched);
  }

  // ── Row 3, Earth — Statuesque ─────────────────────────────────────────────
  // "All players return to full health and mana each turn; the effect is lost
  //  if they move or cast a spell."

  static void _statuesque(WildMagicApplyContext ctx) {
    // A6: the latch begins at the END of the turn it fires, so the cast that
    // triggered it does not immediately break it — the literal reading would
    // have the wild-magic caster break their own effect in the same instant.
    // TurnLoop promotes pending → active in Phase 6.
    final touched = <String>[];
    for (final av in ctx.livingAvatars) {
      ctx.wild.pendingStatuesquePlayerIds.add(av.playerId);
      touched.add(av.playerId);
    }
    ctx.emit(WildMagicEffectKind.statuesque, players: touched);
  }

  // ── Row 3, Water — Rippling Reflections ───────────────────────────────────
  // "Going forward, upon spell resolution, every spell has a 50% chance to
  //  fizzle and a 50% chance to resolve twice. Every time a spell fizzles the
  //  odds shift 10% towards doubling, and vice versa."

  static void _ripplingReflections(WildMagicApplyContext ctx) {
    // Idempotent: a second Rippling Reflections must NOT reset a drifted
    // counter back to 50, or the effect would be repeatedly re-armed by a
    // player who keeps casting the spell that carries it.
    ctx.wild.ripplingFizzlePct ??= 50;
    ctx.emit(
      WildMagicEffectKind.ripplingReflections,
      note: 'fizzle chance ${ctx.wild.ripplingFizzlePct}%',
    );
  }

  // ── Row 3, Air — Scattered Gusts ──────────────────────────────────────────
  // "Going forward, every time a player casts a spell all their bookmarks are
  //  blown out of place and they randomly find a new set of spells to mark."

  static void _scatteredGusts(WildMagicApplyContext ctx) {
    // Once true, stays true for the match. TurnLoop re-deals the caster's hand
    // after each cast resolves; free casts are exempt (A8) or Spontaneous
    // Combustion becomes a hand-shredder.
    ctx.wild.scatteredGusts = true;
    ctx.emit(WildMagicEffectKind.scatteredGusts);
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

  static bool _isOccupied(BattleState state, HexCoord t) =>
      state.avatars.any((a) => a.isAlive && a.position == t) ||
      state.minions.any((m) => m.isAlive && m.occupiedTiles.contains(t));
}

