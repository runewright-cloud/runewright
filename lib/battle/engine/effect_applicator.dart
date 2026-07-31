// SPDX-License-Identifier: GPL-3.0-or-later
//
// effect_applicator.dart — EffectApplicator: applies a resolved SpellEffect to
// BattleState.
//
// Called once per formula in a spell's trajectory. The caller (TurnLoop) builds
// an ApplyContext for each formula and calls EffectApplicator.apply().
//
// Absorption rod (AccoutrementKind.absorptionRod / deflectionTotem):
//   When an enemy spell first hits a player, one rod is consumed and all
//   time-based effect durations from that spell on that player are halved
//   (rounded up). The TurnLoop tracks which players have had their rod
//   consumed for the current spell via ApplyContext.rodConsumedFor; the
//   applicator reads and updates this set.
//
// Stubs (require additional system seams — noted inline):
//   - Water / SpellInteraction: copy target's last-cast spell (needs history)
//   - Water+Air / Divination: requires DivinationReveal protocol message
//
// Fire+Earth / FuelTransmutation's wither/reactivate (SPELL_DRAW_WIRING_
// PLAN.md §9) needs the caster's DrawSchedule (draw_schedule.dart) and a
// dedicated RNG, both supplied by the caller via ApplyContext.drawSchedules/
// .witherRng — no-ops gracefully when either is absent (e.g. direct
// ApplyContext construction in tests that don't exercise this flavor).
//
// Tile effects produced here are "instantiated" on state.tileEffects.
// Cloud objects are added to state.clouds with a UUID-ish id.
// Minions are added to state.minions.

import 'dart:math';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart'; // also exports SpellAffinity
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance;
import 'package:rune_duel/battle/models/illusion.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/reflection_link.dart';
import 'package:rune_duel/battle/models/divination_link.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'draw_schedule.dart';
import 'tile_entry_resolver.dart';

// ── Apply context ─────────────────────────────────────────────────────────────

/// All inputs needed to apply one formula's effect to game state.
class ApplyContext {
  ApplyContext({
    required this.descriptor,
    required this.targetTile,
    required this.caster,
    required this.state,
    required this.rng,
    Set<String>? rodConsumedFor,
    Map<String, List<HexCoord>>? movePaths,
    this.chosenConveyorDirection,
    List<ConveyorChainEvent>? conveyorChainEvents,
    this.drawSchedules,
    this.witherRng,
    this.effectiveRadiusBonus = 0,
  }) : rodConsumedFor = rodConsumedFor ?? {},
       movePaths      = movePaths      ?? {},
       conveyorChainEvents = conveyorChainEvents ?? [];

  final EffectDescriptor descriptor;
  final HexCoord targetTile;
  final WizardAvatar caster;
  final BattleState state;
  final Random rng;

  /// Rod of Spreading bonus: +1 effective radius applied to this spell's
  /// spatial effects (0 when no rod was activated). Set once for the whole
  /// cast in TurnLoop. See EffectApplicator.apply's footprint expansion.
  // TODO(velocity): the Air "Velocity (+2 range)" enhancement — a documented
  //   no-op today (casting_enhancements.dart) — should feed this same seam.
  final int effectiveRadiusBonus;

  /// Tracks which playerIds have had an absorption rod consumed for this spell.
  final Set<String> rodConsumedFor;

  /// Full traversed paths for this turn: playerId → [origin, step1, ..., dest].
  /// Used by knockback to bounce the target back along the path they walked.
  final Map<String, List<HexCoord>> movePaths;

  /// The caster's chosen push direction for a ConveyorTile this formula is
  /// about to create, if the cast flow collected one (see battle_screen.dart
  /// direction picker). Null means "not supplied" -- _applyTileModification
  /// falls back to a random direction (also the seam for a future real-time
  /// choose-or-timeout mode, and for Mystery/delayed casts, which don't
  /// collect a direction this pass).
  final HexCoord? chosenConveyorDirection;

  /// Collects ConveyorChainEvents emitted by knockback landing an entity on
  /// a conveyor tile mid-spell, so the caller (TurnLoop) can fold them into
  /// its per-turn event list for UI animation.
  final List<ConveyorChainEvent> conveyorChainEvents;

  /// TurnLoop's own position-only hand/deck bookkeeping for both players
  /// (SPELL_DRAW_WIRING_PLAN.md §9) — the SAME mutable map instance, passed
  /// by reference, so FuelTransmutation wither/reactivate can update
  /// `drawSchedules[caster.playerId]` directly, the same way other handlers
  /// mutate `state` in place. Null when the caller has no draw state to
  /// offer (e.g. direct ApplyContext construction in tests that don't
  /// exercise FuelTransmutation) — wither/reactivate then no-op.
  final Map<String, DrawSchedule>? drawSchedules;

  /// Dedicated RNG for FuelTransmutation wither/reactivate position
  /// selection (§9), seeded independently from [rng]/`actionRng` so drawing
  /// from it can never desync the shared action-resolution RNG stream. Null
  /// has the same no-op effect as a null [drawSchedules].
  final Random? witherRng;
}

// ── Effect applicator ─────────────────────────────────────────────────────────

class EffectApplicator {
  /// Apply [ctx.descriptor.spellEffect] to [ctx.state], targeting
  /// [ctx.targetTile].
  ///
  /// Rod of Spreading ([ApplyContext.effectiveRadiusBonus] > 0) enlarges a
  /// spell's *spatial* effects by that many rings. Three shapes of expansion:
  ///
  ///   1. Radius-carrying effects (splash damage, clouds) grow their own
  ///      radius field by the bonus — one application, wider disc.
  ///   2. Tile-local effects that hit whatever is on the target tile (direct/
  ///      knockback damage, status-effect interactions, terrain summons) are
  ///      re-applied once per tile of the wall-blocked disc around the target
  ///      (Earth ImpassableTile walls block the spread; design v3.0 §Artifacts).
  ///   3. Everything else is left single-target: caster self-buffs (barrier,
  ///      quick, penetrating…) and meta effects that land on whoever occupies
  ///      the one target tile (chain, haymaker priming, Bellows…) have no
  ///      spatial radius, and re-running them per tile would wrongly multiply
  ///      a single-recipient effect. [_isSpreadableAtTiles] names exactly the
  ///      case-2 set — audit it when a new effect kind lands.
  static void apply(ApplyContext ctx) {
    final bonus = ctx.effectiveRadiusBonus;
    final effect = ctx.descriptor.spellEffect;

    if (bonus > 0) {
      // Case 1: bump a radius-carrying effect's own footprint.
      final widened = _withRadiusBonus(effect, bonus);
      if (widened != null) {
        _dispatch(_reTargeted(ctx, ctx.targetTile, widened), widened);
        return;
      }
      // Case 2: re-apply a tile-local effect across the wall-blocked disc.
      if (_isSpreadableAtTiles(effect)) {
        for (final tile in _spreadTiles(ctx.state, ctx.targetTile, bonus)) {
          _dispatch(_reTargeted(ctx, tile, effect), effect);
        }
        return;
      }
    }
    // Case 3 (and the no-bonus fast path): apply once at the target tile.
    _dispatch(ctx, effect);
  }

  static void _dispatch(ApplyContext ctx, SpellEffect effect) => switch (effect) {
        DamageEffect e => _applyDamage(ctx, e),
        BarrierEffect e => _applyBarrier(ctx, e),
        ReflectionEffect e => _applyReflections(ctx, e),
        SpeedManipulationEffect e => _applySpeedManipulation(ctx, e),
        ChainInteractionEffect e => _applyChainInteraction(ctx, e),
        SpellInteractionEffect e => _applySpellInteraction(ctx, e),
        TileModificationEffect e => _applyTileModification(ctx, e),
        RangeModificationEffect e => _applyRangeModification(ctx, e),
        CloudEffect e => _applyClouds(ctx, e),
        FuelTransmutationEffect e => _applyFuelTransmutation(ctx, e),
        ArtifactsInteractionEffect e => _applyArtifactsInteraction(ctx, e),
        StatusEffectInteractionEffect e => _applyStatusEffectInteraction(ctx, e),
        IllusionEffect e => _applyIllusions(ctx, e),
        MultiplierCyclesEffect e => _applyMultiplierCycles(ctx, e),
        HaymakerInteractionEffect e => _applyHaymakerInteraction(ctx, e),
        DivinationEffect e => _applyDivination(ctx, e),
      };

  // ── Rod of Spreading: footprint expansion ─────────────────────────────────

  /// If [effect] already carries its own AoE radius (splash damage, clouds),
  /// returns a copy with that radius grown by [bonus]; otherwise null (the
  /// caller then tries the per-tile disc expansion instead).
  static SpellEffect? _withRadiusBonus(SpellEffect effect, int bonus) =>
      switch (effect) {
        DamageEffect e when e.kind == DamageKind.splash => DamageEffect(
            amount: e.amount,
            kind: e.kind,
            splashRadius: e.splashRadius + bonus,
            knockback: e.knockback,
          ),
        CloudEffect e => CloudEffect(
            affinity: e.affinity,
            kind: e.kind,
            radius: e.radius + bonus,
            durationTurns: e.durationTurns,
          ),
        _ => null,
      };

  /// Effects that resolve against whatever occupies a single target tile, so
  /// re-running them once per tile of an enlarged disc is a true AoE (case 2).
  /// Deliberately excludes: splash/cloud (handled by [_withRadiusBonus]),
  /// traversal damage (already a caster→target line), self-buffs, and
  /// caster-mutating meta effects (which would multiply if looped).
  static bool _isSpreadableAtTiles(SpellEffect effect) => switch (effect) {
        DamageEffect e =>
          e.kind == DamageKind.direct || e.kind == DamageKind.knockback,
        StatusEffectInteractionEffect _ => true,
        TileModificationEffect _ => true,
        _ => false,
      };

  /// Tiles reachable from [center] within [radius] steps without passing
  /// *through* an ImpassableTile (Earth wall). BFS so a wall shadows the tiles
  /// behind it — matching traversal damage's stop-at-wall rule and the design's
  /// "Earth wall tiles still prevent spell effects from traveling past them
  /// through this AoE." [center] is always included; blocked *destination*
  /// tiles are still valid targets (the wall tile itself can be hit), they just
  /// don't propagate the spread onward.
  static List<HexCoord> _spreadTiles(BattleState state, HexCoord center, int radius) {
    final seen = <HexCoord>{center};
    final result = <HexCoord>[center];
    var frontier = <HexCoord>[center];
    for (var step = 0; step < radius; step++) {
      final next = <HexCoord>[];
      for (final tile in frontier) {
        // A wall stops the spread from continuing past it, but the wall tile
        // itself (already added when it was reached) remains a valid target.
        if (state.tileEffects[tile] is ImpassableTile) continue;
        for (final n in _hexNeighbors(tile)) {
          if (!state.battlefield.isInBounds(n) || !seen.add(n)) continue;
          result.add(n);
          next.add(n);
        }
      }
      frontier = next;
    }
    return result;
  }

  /// A copy of [ctx] centered on [tile] with the rod bonus cleared (so a
  /// per-tile dispatch never re-expands) and [effect] as its spell effect.
  /// Shares every mutable collection (state, rodConsumedFor, movePaths,
  /// conveyorChainEvents, drawSchedules) by reference — the whole point is that
  /// bookkeeping accumulates across the expanded tiles exactly as it would for
  /// a single application.
  static ApplyContext _reTargeted(ApplyContext ctx, HexCoord tile, SpellEffect effect) =>
      ApplyContext(
        descriptor: EffectDescriptor(
          affinity: ctx.descriptor.affinity,
          effectKind: ctx.descriptor.effectKind,
          spellEffect: effect,
        ),
        targetTile: tile,
        caster: ctx.caster,
        state: ctx.state,
        rng: ctx.rng,
        rodConsumedFor: ctx.rodConsumedFor,
        movePaths: ctx.movePaths,
        chosenConveyorDirection: ctx.chosenConveyorDirection,
        conveyorChainEvents: ctx.conveyorChainEvents,
        drawSchedules: ctx.drawSchedules,
        witherRng: ctx.witherRng,
        effectiveRadiusBonus: 0,
      );

  // ── Damage (Fire-Fire) ────────────────────────────────────────────────────

  static void _applyDamage(ApplyContext ctx, DamageEffect e) {
    // Burning Hot (wild magic, row 1 Fire): "all spell effects next turn deal
    // +1 fire damage [+1 damage per effect]". Applied here, at the single
    // damage chokepoint, so it lands once per damage EFFECT — a three-formula
    // spell gets it three times — and on EVERY player's spells, caster
    // included (wild magic is symmetric).
    final bonus = ctx.state.wildMagic.spellDamageBonusFor(ctx.state.turnNumber);
    if (bonus > 0) {
      e = DamageEffect(
        amount: e.amount + bonus,
        kind: e.kind,
        splashRadius: e.splashRadius,
        knockback: e.knockback,
      );
    }
    switch (e.kind) {
      case DamageKind.direct:
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
          _hitMinion(ctx, m, e.amount);
        }
        _destroyIllusionTerrainIfPresent(ctx, ctx.targetTile);

      case DamageKind.traversal:
        // Walk path from caster to target; stop at ImpassableTile.
        final path = _hexLinePath(ctx.caster.position, ctx.targetTile);
        for (final hex in path) {
          if (ctx.state.tileEffects[hex] is ImpassableTile) break;
          for (final av in _avatarsAt(ctx.state, hex)) {
            _hitAvatar(av, e.amount, ctx);
          }
          for (final m in _minionsAt(ctx.state, hex)) {
            _hitMinion(ctx, m, e.amount);
          }
          _destroyIllusionTerrainIfPresent(ctx, hex);
        }
        // Hit the final target (not already walked).
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
          _hitMinion(ctx, m, e.amount);
        }
        _destroyIllusionTerrainIfPresent(ctx, ctx.targetTile);

      case DamageKind.splash:
        final inRadius = _entitiesInRadius(ctx.state, ctx.targetTile, e.splashRadius);
        for (final av in inRadius.$1) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in inRadius.$2) {
          _hitMinion(ctx, m, e.amount);
        }
        for (final hex in ctx.state.illusionTerrainTiles.toList()) {
          if (hexDistance(hex, ctx.targetTile) <= e.splashRadius) {
            _destroyIllusionTerrainIfPresent(ctx, hex);
          }
        }

      case DamageKind.knockback:
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          _hitAvatar(av, e.amount, ctx);
          _knockback(av, ctx);
        }
        for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
          _hitMinion(ctx, m, e.amount);
          _knockbackMinion(m, ctx);
        }
        _destroyIllusionTerrainIfPresent(ctx, ctx.targetTile);
    }
  }

  /// Water-Air Illusions (Earth flavor): terrain copies have 1 HP -- any
  /// damage that touches their tile destroys the copy (and its tileEffect).
  static void _destroyIllusionTerrainIfPresent(ApplyContext ctx, HexCoord hex) {
    if (ctx.state.illusionTerrainTiles.remove(hex)) {
      ctx.state.tileEffects.remove(hex);
    }
  }

  // ── Barrier (Earth-Earth) ─────────────────────────────────────────────────

  static void _applyBarrier(ApplyContext ctx, BarrierEffect e) {
    final affinity = ctx.descriptor.affinity;
    // Lands on whoever occupies the target tile -- self-target your own
    // tile to armor yourself; an ally's tile to armor them instead.
    for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
      if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
      av.barriers[affinity] = BarrierState(
        element: affinity,
        hp: e.hp,
        maxHp: e.hp,
        remainingTurns: e.durationTurns,
        fireAura: e.fireAura,
        manaRegenBonusPct: e.manaRegenBonusPct,
        freeMoveOnCollapse: e.freeMoveOnCollapse,
      );
    }
  }

  // ── Reflections (Water-Water) ─────────────────────────────────────────────

  static void _applyReflections(ApplyContext ctx, ReflectionEffect e) {
    // Only valid when the target tile contains a living enemy.
    final target = _avatarsAt(ctx.state, ctx.targetTile)
        .where((av) => av.teamId != ctx.caster.teamId)
        .firstOrNull;
    if (target == null) return;

    // Randomly select e.triggerCount triggers from the full pool.
    final pool = ReflectionTrigger.values.toList()..shuffle(ctx.rng);
    final selected = pool.take(e.triggerCount).toSet();

    ctx.state.reflectionLinks.add(ReflectionLink(
      id: _uid(ctx, 'rl'),
      casterId: ctx.caster.playerId,
      targetId: target.playerId,
      activeTriggers: selected,
      remainingTurns: e.durationTurns,
    ));
  }

  // ── Speed Manipulation (Air-Air) ──────────────────────────────────────────

  static void _applySpeedManipulation(ApplyContext ctx, SpeedManipulationEffect e) {
    if (e.highMobility) {
      // Lands on whoever occupies the target tile -- self-target to grant
      // yourself the ability.
      for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
        if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
        _addStatus(av, StatusEffectId.highMobility, {'freeExtraTiles': e.freeExtraTiles}, ctx);
      }
      return;
    }
    if (e.highLiquidity) {
      for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
        if (_prepareForHit(av, ctx) == null) continue;
        _addStatus(av, StatusEffectId.highLiquidity, {'freeExtraTiles': e.freeExtraTiles}, ctx);
      }
      return;
    }
    // Speed delta always affects whoever occupies the target tile (both
    // Earth's debuff and Air's buff already set affectsTarget: true in
    // effect_resolver.dart); [ctx.caster] is unreachable dead-code fallback
    // kept only because SpeedManipulationEffect's affectsTarget field is a
    // general mechanism, not because any current flavor uses it.
    final targets = e.affectsTarget
        ? _avatarsAt(ctx.state, ctx.targetTile)
        : [ctx.caster];
    final typeId = e.speedDelta > 0 ? StatusEffectId.speedUp : StatusEffectId.speedDown;
    for (final av in targets) {
      final half = _prepareForHit(av, ctx);
      if (half == null) continue; // redirected onto an illusion decoy
      final dur = _dur(e.durationTurns, half);
      _addStatusWithDuration(av, typeId, {'speedDelta': e.speedDelta}, dur);
    }
  }

  // ── Clouds (Water-Fire) ────────────────────────────────────────────────────

  static void _applyClouds(ApplyContext ctx, CloudEffect e) {
    ctx.state.clouds.add(CloudObject(
      id: _uid(ctx, 'cl'),
      position: ctx.targetTile,
      kind: e.kind,
      remainingTurns: e.durationTurns,
      ownerId: ctx.caster.playerId,
      radius: e.radius,
    ));
  }

  // ── Chain Interaction (Fire-Water) ────────────────────────────────────────

  static void _applyChainInteraction(ApplyContext ctx, ChainInteractionEffect e) {
    if (e.transferChainFromTarget) {
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      if (targets.isNotEmpty) {
        final target = targets.first;
        // Water flavor explicitly reads FROM the target and writes TO the
        // caster ("you gain all chain status of the affected target") --
        // the one flavor that doesn't affect the target tile's occupant.
        ctx.caster.activeChainElement = target.activeChainElement;
        ctx.caster.chainLengths.clear();
        ctx.caster.chainLengths.addAll(target.chainLengths);
        if (e.chainTransferBonus > 0 && ctx.caster.activeChainElement != null) {
          final el = ctx.caster.activeChainElement!;
          // chainTransferBonus is in whole casts (+1 under potency);
          // chainLengths stores half-credits.
          ctx.caster.chainLengths[el] =
              (ctx.caster.chainLengths[el] ?? 0) + e.chainTransferBonus * 2;
        }
      }
      return;
    }

    // Every other flavor affects whoever occupies the target tile, like
    // nearly every spell effect in this game -- "Chain Interaction" isn't
    // special-cased to hit the caster. A self-cast (own tile targeted)
    // buffs the caster; an enemy-targeted cast curses/debuffs them instead.
    final targets = _avatarsAt(ctx.state, ctx.targetTile);
    if (targets.isEmpty) return;
    final affected = targets.first;

    if (e.setAllChainsToNegative) {
      // Base and potent both clear the target's chain outright ("all chain
      // bonuses removed").
      affected.chainLengths.clear();
      affected.activeChainElement = null;
      if (e.negativeValue < 0) {
        // Potent: additionally curse the target's very next spell cast --
        // charged as if their chain length were -1, regardless of that
        // spell's own affinity. Normal chain building resumes starting
        // with that same cast (see StatusEffectId.chainSurcharge).
        // remainingTurns=2 mirrors nextSpellCostDouble: survives this
        // turn's tick, applies to the next cast.
        _addStatusWithDuration(
            affected, StatusEffectId.chainSurcharge, const {}, 2, ctx);
      }
      return;
    }

    // Fire: chain accrues faster / Earth: chain accrues slower.
    final pct = (e.chainAccumulationMultiplier * 100).round();
    final typeId = e.chainAccumulationMultiplier >= 1.0
        ? StatusEffectId.chainFast
        : StatusEffectId.chainSlow;
    _addStatusWithDuration(affected, typeId, {'chainAccMultiplierPct': pct}, e.durationTurns, ctx);
  }

  // ── Spell Interaction (Fire-Air) ──────────────────────────────────────────

  static void _applySpellInteraction(ApplyContext ctx, SpellInteractionEffect e) {
    if (e.isSlugEffect) {
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      for (final av in targets) {
        final half = _prepareForHit(av, ctx);
        if (half == null) continue; // redirected onto an illusion decoy
        _addStatusWithDuration(av, StatusEffectId.sluggish, {}, _dur(e.durationTurns, half));
      }
      return;
    }
    if (e.isQuickEffect) {
      // Mirrors the isSlugEffect branch above: lands on whoever occupies
      // the target tile, not automatically the caster.
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      for (final av in targets) {
        final half = _prepareForHit(av, ctx);
        if (half == null) continue; // redirected onto an illusion decoy
        _addStatusWithDuration(av, StatusEffectId.quick, {}, _dur(e.durationTurns, half));
      }
      return;
    }
    if (e.nextSpellCostMultiplier > 1) {
      // Fire affinity: double target's next spell cost; mana shortfall → HP.
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      for (final av in targets) {
        if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
        _addStatusWithDuration(av, StatusEffectId.nextSpellCostDouble, {
          'costMultiplier': e.nextSpellCostMultiplier,
          'hpPerManaMissed': e.hpPerManaMissed,
          'manaPerHp': e.manaPerHp,
        }, 2); // remainingTurns=2: survives this turn's tick, applies to next cast
      }
      return;
    }
    if (e.copySpellCount > 0) {
      // TODO(battle): copy target's last-cast spell [copySpellCount] times.
      //   Requires per-player spell history (last_cast_spell per player).
      //   Needs SpellHistory tracking in BattleState.
    }
  }

  // ── Tile Modification (Earth-Water) ──────────────────────────────────────

  static void _applyTileModification(ApplyContext ctx, TileModificationEffect e) {
    // A live chasm is indestructible for its duration (wild magic, row 2
    // Earth): it must not be removed by a terrain-destruction effect, nor
    // paved over by another tile effect landing on it. Silently no-ops rather
    // than erroring — the caster aimed at a legal tile, the ground just
    // refused the spell.
    if (tileIsIndestructible(ctx.state.tileEffects[ctx.targetTile])) return;
    var effect = e.tileEffect;
    if (effect is ConveyorTile && !effect.directionSet) {
      final dir = ctx.chosenConveyorDirection ?? _randomDirection(ctx.rng);
      effect = effect.withDirection(dir);
    }
    ctx.state.tileEffects[ctx.targetTile] = effect;
    if (e.canPlaceSecond) {
      // TODO(ui): second tile placement requires caster to select an adjacent
      //   tile during effect resolution. Stub: no second tile placed.
    }
  }

  /// Fallback conveyor direction when the caster didn't supply one (real-time
  /// timeout seam, or the Mystery/delayed-cast path, which doesn't collect a
  /// direction this pass). ctx.rng is the shared deterministic per-turn RNG,
  /// so this replays identically on both peers with no interactivity.
  static HexCoord _randomDirection(Random rng) =>
      HexGrid.directions[rng.nextInt(HexGrid.directions.length)];

  // ── Range Modification (Earth-Air) ───────────────────────────────────────

  static void _applyRangeModification(ApplyContext ctx, RangeModificationEffect e) {
    if (e.penetrating) {
      // Lands on whoever occupies the target tile -- self-target to grant
      // yourself the ability.
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      for (final av in targets) {
        final half = _prepareForHit(av, ctx);
        if (half == null) continue; // redirected onto an illusion decoy
        _addStatusWithDuration(av, StatusEffectId.penetrating, {
          'penetrationDamage': e.penetrationDamage,
        }, _dur(e.durationTurns, half));
      }
      return;
    }
    if (e.turbulent) {
      final targets = _avatarsAt(ctx.state, ctx.targetTile);
      for (final av in targets) {
        final half = _prepareForHit(av, ctx);
        if (half == null) continue; // redirected onto an illusion decoy
        _addStatusWithDuration(av, StatusEffectId.turbulent, {}, _dur(e.durationTurns, half));
      }
      return;
    }
    // Range delta: Earth (affectsTarget=true) debuffs target; Air self-buffs.
    final targets = e.affectsTarget
        ? _avatarsAt(ctx.state, ctx.targetTile)
        : [ctx.caster];
    final typeId = e.rangeDelta > 0 ? StatusEffectId.rangeUp : StatusEffectId.rangeDown;
    for (final av in targets) {
      final half = e.affectsTarget ? _prepareForHit(av, ctx) : false;
      if (half == null) continue; // redirected onto an illusion decoy
      _addStatusWithDuration(av, typeId, {'rangeDelta': e.rangeDelta},
          _dur(e.durationTurns, half), e.affectsTarget ? null : ctx);
    }
  }

  // ── Fuel Transmutation (Water-Fire) ───────────────────────────────────────

  static void _applyFuelTransmutation(ApplyContext ctx, FuelTransmutationEffect e) {
    // Every flavor is a resource trade against whoever occupies the target
    // tile -- self-target to spend/gain your own resources; an ally's tile
    // to spend/gain theirs instead.
    final targets = _avatarsAt(ctx.state, ctx.targetTile);
    for (final av in targets) {
      if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
      switch (e.affinity) {
        case SpellAffinity.fire:
          _witherHandPositions(ctx, av, e.witherSpellCount);
          for (var i = 0; i < e.gainArtifactCount; i++) {
            const pool = [
              AccoutrementKind.manaGem,
              AccoutrementKind.bookmark,
              AccoutrementKind.deflectionTotem,
            ];
            final kind = pool[ctx.rng.nextInt(pool.length)];
            av.accoutrements.add(Accoutrement(id: _uid(ctx, 'ft'), kind: kind));
            if (kind == AccoutrementKind.manaGem) {
              av.maxMana = av.maxManaFor(ctx.state.config);
            }
          }

        case SpellAffinity.earth:
          av.absorbDamage(e.burnLife);
          _reactivateHandPositions(ctx, av, e.reactivateSpellCount);

        case SpellAffinity.water:
          av.mana = (av.mana - e.burnMana).clamp(0, av.maxMana);
          av.hp += e.gainLife;

        case SpellAffinity.air:
          // Every artifact is burnable — there is no indestructible core gem
          // any more, so a wizard's last gem can be taken. Recompute maxMana
          // afterwards or the pool would keep the burned gem's capacity.
          final burnable = av.accoutrements.toList();
          var burned = 0;
          while (burned < e.burnArtifactCount && burnable.isNotEmpty) {
            final idx = ctx.rng.nextInt(burnable.length);
            final burnTarget = burnable.removeAt(idx);
            av.accoutrements.remove(burnTarget);
            burned++;
          }
          _syncMaxMana(av, ctx);
          av.mana = (av.mana + e.gainMana).clamp(0, av.maxMana);
      }
    }
  }

  /// Fire flavor: withers up to [count] random in-hand, not-already-withered
  /// positions for [affected] (SPELL_DRAW_WIRING_PLAN.md §9) -- the avatar
  /// occupying the spell's target tile, not necessarily the caster. No-ops
  /// if draw state isn't available (see [ApplyContext.drawSchedules]/
  /// [ApplyContext.witherRng]'s doc comments) or [affected] has none in hand.
  /// Picks without replacement from a shrinking pool, same technique as the
  /// Air flavor's burnable-accoutrement selection above — deterministic
  /// given [ApplyContext.witherRng].
  static void _witherHandPositions(ApplyContext ctx, WizardAvatar affected, int count) {
    final schedules = ctx.drawSchedules;
    final rng = ctx.witherRng;
    if (schedules == null || rng == null || count <= 0) return;
    final playerId = affected.playerId;
    final schedule = schedules[playerId];
    if (schedule == null) return;
    final pool = schedule.hand.where((p) => !schedule.withered.contains(p)).toList();
    final chosen = <int>[];
    while (chosen.length < count && pool.isNotEmpty) {
      chosen.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    if (chosen.isNotEmpty) {
      schedules[playerId] = schedule.witherPositions(chosen);
    }
  }

  /// Earth flavor: clears the withered flag on up to [count] random withered
  /// positions for [affected]. Mirrors [_witherHandPositions]; see its doc
  /// comment for the no-op conditions and selection technique.
  static void _reactivateHandPositions(ApplyContext ctx, WizardAvatar affected, int count) {
    final schedules = ctx.drawSchedules;
    final rng = ctx.witherRng;
    if (schedules == null || rng == null || count <= 0) return;
    final playerId = affected.playerId;
    final schedule = schedules[playerId];
    if (schedule == null) return;
    final pool = schedule.withered.toList();
    final chosen = <int>[];
    while (chosen.length < count && pool.isNotEmpty) {
      chosen.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    if (chosen.isNotEmpty) {
      schedules[playerId] = schedule.reactivatePositions(chosen);
    }
  }

  /// Recomputes [av]'s stored [WizardAvatar.maxMana] from its current gem
  /// count and clamps current mana into the new pool. Call after any effect
  /// that adds or removes a mana gem: maxMana is hashed state, not a live
  /// derivation, so a stale value desyncs the two clients' state hashes.
  static void _syncMaxMana(WizardAvatar av, ApplyContext ctx) {
    av.maxMana = av.maxManaFor(ctx.state.config);
    if (av.mana > av.maxMana) av.mana = av.maxMana;
  }

  // ── Artifacts Interaction (Water-Earth) ───────────────────────────────────

  static void _applyArtifactsInteraction(ApplyContext ctx, ArtifactsInteractionEffect e) {
    switch (e.affinity) {
      case SpellAffinity.fire:
        // Burn random accoutrements from entity on target tile.
        final targets = _avatarsAt(ctx.state, ctx.targetTile);
        for (final av in targets) {
          if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
          int burned = 0;
          while (burned < e.count) {
            // Every artifact is burnable — the indestructible core gem is
            // gone, so an unlucky victim can lose their last mana gem.
            final burnable = av.accoutrements.toList();
            if (burnable.isEmpty) break;
            final idx = ctx.rng.nextInt(burnable.length);
            final target = burnable[idx];
            av.accoutrements.remove(target);
            av.hp = (av.hp - 1).clamp(0, 999999);
            // Burning a counter charm reveals its target commitment.
            // (Reveal logic is a UI/protocol concern; the state change here
            // is simply that the accoutrement is removed.)
            burned++;
          }
          // A burned gem shrinks the pool; see _syncMaxMana.
          _syncMaxMana(av, ctx);
        }

      case SpellAffinity.earth:
        // Summon deflection totem(s) for whoever occupies the target tile --
        // self-target to gift yourself the artifact; an ally's tile to gift
        // them instead.
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
          for (var i = 0; i < e.count; i++) {
            av.accoutrements.add(Accoutrement(
              id: _uid(ctx, 'dt'),
              kind: AccoutrementKind.deflectionTotem,
            ));
          }
        }

      case SpellAffinity.water:
        // Summon mana gem(s) for whoever occupies the target tile.
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          if (_prepareForHit(av, ctx) == null) continue;
          for (var i = 0; i < e.count; i++) {
            av.accoutrements.add(Accoutrement(
              id: _uid(ctx, 'mg'),
              kind: AccoutrementKind.manaGem,
            ));
            // Update max mana to reflect the new gem.
            av.maxMana = av.maxManaFor(ctx.state.config);
          }
        }

      case SpellAffinity.air:
        // Summon bookmark(s) for whoever occupies the target tile.
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          if (_prepareForHit(av, ctx) == null) continue;
          for (var i = 0; i < e.count; i++) {
            av.accoutrements.add(Accoutrement(
              id: _uid(ctx, 'bm'),
              kind: AccoutrementKind.bookmark,
            ));
          }
        }
    }
  }

  // ── Status Effect Interaction (Fire-Earth) ────────────────────────────────

  static void _applyStatusEffectInteraction(ApplyContext ctx, StatusEffectInteractionEffect e) {
    final targets = _avatarsAt(ctx.state, ctx.targetTile);
    switch (e.affinity) {
      case SpellAffinity.fire:
        for (final av in targets) {
          final count = av.activeStatusEffects
              .where((fx) => !fx.isDormant)
              .length;
          _hitAvatar(av, count * e.damagePerEffect, ctx);
        }

      case SpellAffinity.earth:
        for (final av in targets) {
          final half = _prepareForHit(av, ctx);
          if (half == null) continue; // redirected onto an illusion decoy
          final dur = _dur(e.durationTurns, half);
          for (final fx in av.activeStatusEffects) {
            fx.isDormant = true;
          }
          _addStatusWithDuration(av, StatusEffectId.statusDormant, {}, dur);
        }

      case SpellAffinity.water:
        for (final av in targets) {
          final half = _prepareForHit(av, ctx);
          if (half == null) continue; // redirected onto an illusion decoy
          final remove = half ? ((e.turnsRemoved + 1) ~/ 2) : e.turnsRemoved;
          for (final fx in av.activeStatusEffects) {
            fx.remainingTurns = (fx.remainingTurns - remove).clamp(0, 9999);
          }
          av.activeStatusEffects.removeWhere((fx) => fx.remainingTurns <= 0);
        }

      case SpellAffinity.air:
        for (final av in targets) {
          if (_prepareForHit(av, ctx) == null) continue; // redirected onto an illusion decoy
          for (final fx in av.activeStatusEffects) {
            fx.remainingTurns += e.turnsAdded;
          }
        }
    }
  }

  // ── Illusions (Water-Air) ─────────────────────────────────────────────────

  static void _applyIllusions(ApplyContext ctx, IllusionEffect e) {
    if (e.copyAggressiveMinion) {
      _applyIllusionMinionCopy(ctx);
    } else if (e.copyTerrainExpand) {
      _applyIllusionTerrainCopy(ctx);
    } else if (e.wizardDecoyCount > 0) {
      _applyIllusionWizardDecoys(ctx, e.wizardDecoyCount);
    } else if (e.convertToIllusion) {
      for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
        m.hp = m.hp.clamp(0, 1);
      }
    }
  }

  /// Fire flavor: clone the minion on the target tile for the caster at 1 HP,
  /// always closing to attack rather than following its personality's normal
  /// positioning (Minion.forceCloseToAttack).
  static void _applyIllusionMinionCopy(ApplyContext ctx) {
    final source = _minionsAt(ctx.state, ctx.targetTile).firstOrNull;
    if (source == null) return;
    final spawn = _findCreatureSpawnTile(
        ctx.state, ctx.targetTile, source.abilities, source.sizeBonus);
    ctx.state.minions.add(Minion(
      id: _uid(ctx, 'ic'),
      ownerId: ctx.caster.playerId,
      teamId: ctx.caster.teamId,
      position: spawn,
      affinity: source.affinity,
      stats: source.stats.copyWith(maxHp: 1),
      elementSequence: source.elementSequence,
      abilities: source.abilities,
      personality: source.personality,
      forceCloseToAttack: true,
      sizeBonus: source.sizeBonus,
    ));
  }

  /// Earth flavor: clone the TileEffect on the target tile onto every
  /// terrain-free neighbor; copies are destroyed by any damage touching
  /// their tile (see BattleState.illusionTerrainTiles / _applyDamage).
  ///
  /// Special-cased for a ConveyorTile source: the copies default to forming
  /// a clockwise-or-counterclockwise loop around the source (random
  /// rotation, chosen once for this cast) rather than all sharing the exact
  /// same direction as a coincidence of copy-by-reference. (Today's
  /// non-conveyor copy path *does* share the source instance by reference,
  /// which is also how conveyor copies would share one direction if this
  /// special case were removed -- flagged here as the seam if the loop
  /// default is ever swapped for independent per-copy directions.)
  static void _applyIllusionTerrainCopy(ApplyContext ctx) {
    final source = ctx.state.tileEffects[ctx.targetTile];
    if (source == null) return;

    // (tile, ringIndex) for every eligible (in bounds, terrain-free)
    // neighbor, in HexGrid.clockwiseDirections' angular order.
    final ring = HexGrid.clockwiseDirections;
    final eligible = <(HexCoord, int)>[];
    for (var i = 0; i < ring.length; i++) {
      final n = HexCoord(ctx.targetTile.q + ring[i].q, ctx.targetTile.r + ring[i].r);
      if (!ctx.state.battlefield.isInBounds(n)) continue;
      if (ctx.state.tileEffects.containsKey(n)) continue;
      eligible.add((n, i));
    }
    if (eligible.isEmpty) return;

    if (source is! ConveyorTile) {
      for (final (tile, _) in eligible) {
        ctx.state.tileEffects[tile] = source;
        ctx.state.illusionTerrainTiles.add(tile);
      }
      return;
    }

    // ConveyorTile source: approximate a loop. A gap (missing/blocked
    // neighbor) breaks ring-adjacency there; that copy falls back to an
    // independent random direction instead of forcing an invalid
    // multi-tile-jump "direction".
    final reversed = ctx.rng.nextBool();
    final ordered = reversed ? eligible.reversed.toList() : eligible;
    for (var i = 0; i < ordered.length; i++) {
      final (tile, ringIndex) = ordered[i];
      final (nextTile, nextRingIndex) = ordered[(i + 1) % ordered.length];
      final expectedNextRingIndex =
          reversed ? (ringIndex - 1 + ring.length) % ring.length : (ringIndex + 1) % ring.length;
      final ringAdjacent = nextRingIndex == expectedNextRingIndex;
      final dir = (ordered.length > 1 && ringAdjacent)
          ? HexCoord(nextTile.q - tile.q, nextTile.r - tile.r)
          : _randomDirection(ctx.rng);
      ctx.state.tileEffects[tile] = ConveyorTile(direction: dir);
      ctx.state.illusionTerrainTiles.add(tile);
    }
  }

  /// Water flavor: surround the caster with [count] decoys spaced evenly
  /// among open neighboring tiles. Replaces any decoy set the caster already
  /// has active. See EffectApplicator._resolveIllusionRedirect for the
  /// redirect-on-hit mechanic.
  static void _applyIllusionWizardDecoys(ApplyContext ctx, int count) {
    final neighbors = _hexNeighbors(ctx.caster.position)
        .where((n) => ctx.state.battlefield.isInBounds(n) && _isTileOpen(ctx.state, n))
        .toList();
    if (neighbors.isEmpty) return;
    final step = (neighbors.length / count).ceil().clamp(1, neighbors.length);
    final decoys = <HexCoord>[];
    for (var i = 0; i < neighbors.length && decoys.length < count; i += step) {
      decoys.add(neighbors[i]);
    }
    if (decoys.isEmpty) return;
    ctx.state.wizardIllusions.removeWhere((s) => s.ownerId == ctx.caster.playerId);
    ctx.state.wizardIllusions.add(
      WizardIllusionSet(ownerId: ctx.caster.playerId, decoyPositions: decoys),
    );
  }

  // ── Multiplier Cycles (Air-Fire) ──────────────────────────────────────────

  static void _applyMultiplierCycles(ApplyContext ctx, MultiplierCyclesEffect e) {
    // Lands on whoever occupies the target tile, like nearly every spell
    // effect -- not automatically the caster (2026-07-27: this used to be a
    // hardcoded self-buff; trying it as tile-targeted like everything else).
    // Consumed the next time WHOEVER RECEIVED IT resolves a formula of
    // targetElement affinity -- immediately if one follows later in the same
    // spell, otherwise on a spell cast next turn -- which applies that
    // formula's effect this many times instead of once. Expires unused after
    // 2 turns total; see WizardAvatar.tickStatusEffects.
    final targets = _avatarsAt(ctx.state, ctx.targetTile);
    if (targets.isEmpty) return;
    targets.first.pendingEffectMultipliers[e.targetElement] =
        PendingMultiplier(multiplier: e.multiplier, remainingTurns: 2);
  }

  // ── Haymaker Interaction (Air-Earth) ─────────────────────────────────────

  /// Primes a future melee punch with a bonus (design doc "melee attacks":
  /// "Spell effects (Air-Earth row) can empower a melee attack with
  /// bonuses"). Lands on whoever occupies the target tile, like nearly every
  /// spell effect -- not automatically the caster, so buffing your own next
  /// haymaker requires targeting your own tile (and an opponent fast enough
  /// to reach that tile first, or scrying it, can take the buff instead).
  /// [TurnLoop._applyHaymaker] later reads these off whoever actually throws
  /// the punch, so this only needs to get the status onto the right avatar
  /// now -- consumption doesn't care who that ends up being.
  static void _applyHaymakerInteraction(ApplyContext ctx, HaymakerInteractionEffect e) {
    final targets = _avatarsAt(ctx.state, ctx.targetTile);
    if (targets.isEmpty) return;
    final affected = targets.first;
    if (e.doTStackIncrement > 0) {
      _addStatusWithDuration(affected, StatusEffectId.haymakerDot,
          {'doTStackIncrement': e.doTStackIncrement}, e.durationTurns, ctx);
    }
    if (e.slowsTarget) {
      _addStatusWithDuration(affected, StatusEffectId.haymakerSlow, {}, e.durationTurns, ctx);
    }
    if (e.drainTargetStatus) {
      _addStatusWithDuration(affected, StatusEffectId.haymakerStatusDrain, {}, e.durationTurns, ctx);
    }
    if (e.distanceBonusDamage) {
      _addStatusWithDuration(affected, StatusEffectId.haymakerDistanceBonus, {}, e.durationTurns, ctx);
    }
  }

  // ── Divination (Air-Water) ────────────────────────────────────────────────

  static void _applyDivination(ApplyContext ctx, DivinationEffect e) {
    if (e.revealsCounterCharms) {
      // durationTurns=0 → rest-of-match; use 999 as "indefinite" sentinel.
      _addStatusWithDuration(ctx.caster, StatusEffectId.revealCounterCharms, {},
          e.durationTurns == 0 ? 999 : e.durationTurns, ctx);
      return;
    }
    if (!e.requiresOpponentReveal) return;

    // Water (Watery Scrying Pool — "see target's available spell list") and
    // Air (Airy Scrying Pool — "see target's committed spell target tile")
    // both require a living enemy at the target tile to link to; the actual
    // reveal is driven each turn by TurnLoop from state.divinationLinks (see
    // MESH_ARCHITECTURE.md §13b and TurnLoop._exchangeScryOpenings /
    // _exchangeSpellRevealOpenings). The status chip added below is cosmetic
    // only.
    final target = _avatarsAt(ctx.state, ctx.targetTile)
        .where((av) => av.teamId != ctx.caster.teamId)
        .firstOrNull;
    if (target == null) return;

    final isWater = ctx.descriptor.affinity == SpellAffinity.water;
    ctx.state.divinationLinks.add(DivinationLink(
      id: _uid(ctx, 'dv'),
      casterId: ctx.caster.playerId,
      targetId: target.playerId,
      remainingTurns: e.durationTurns,
      flavor: isWater ? DivinationFlavor.spellList : DivinationFlavor.targetTile,
    ));
    _addStatusWithDuration(
      ctx.caster,
      isWater ? StatusEffectId.revealSpells : StatusEffectId.revealTargetTile,
      {},
      e.durationTurns,
      ctx,
    );
  }

  // ── Absorption rod / illusion-decoy helpers ───────────────────────────────

  /// Check if [target] needs an absorption rod consumed for this spell, or
  /// is redirected onto an illusion decoy instead of being hit at all.
  ///
  /// Returns:
  ///   - null  — redirected onto a decoy; caller must skip applying the
  ///             effect to [target] this time (see _resolveIllusionRedirect).
  ///   - true  — durations should be halved (rod consumed or already was).
  ///   - false — hit lands normally, no halving.
  ///
  /// No-ops for self-buff (same player as caster).
  static bool? _prepareForHit(WizardAvatar target, ApplyContext ctx) {
    if (target.playerId == ctx.caster.playerId) return false;
    if (_resolveIllusionRedirect(target, ctx)) return null;
    if (ctx.rodConsumedFor.contains(target.playerId)) return true;
    if (target.absorptionRodCount > 0) {
      final idx = target.accoutrements.indexWhere(
        (a) =>
            a.kind == AccoutrementKind.absorptionRod ||
            a.kind == AccoutrementKind.deflectionTotem,
      );
      if (idx >= 0) target.accoutrements.removeAt(idx);
      ctx.rodConsumedFor.add(target.playerId);
      return true;
    }
    return false;
  }

  /// Water-Air Illusions (Water flavor): if [target] has active wizard
  /// decoys, roll 1/remaining -- on a hit the real wizard takes it (returns
  /// false); otherwise a random decoy is destroyed and [target] is moved to
  /// its tile instead (returns true, meaning the actual hit is dodged).
  static bool _resolveIllusionRedirect(WizardAvatar target, ApplyContext ctx) {
    final set = ctx.state.wizardIllusions
        .where((s) => s.ownerId == target.playerId && s.decoyPositions.isNotEmpty)
        .firstOrNull;
    if (set == null) return false;
    final n = set.decoyPositions.length;
    if (ctx.rng.nextInt(n) == 0) return false; // chance 1/n: real wizard is hit
    final idx = ctx.rng.nextInt(n);
    final decoyPos = set.decoyPositions.removeAt(idx);
    target.position = decoyPos;
    ctx.state.battlefield.occupancy[target.playerId] = decoyPos;
    if (set.decoyPositions.isEmpty) ctx.state.wizardIllusions.remove(set);
    return true;
  }

  // ── Damage helpers ────────────────────────────────────────────────────────

  static void _hitAvatar(WizardAvatar av, int amount, ApplyContext ctx) {
    if (amount <= 0) return;
    if (_prepareForHit(av, ctx) == null) return; // redirected onto an illusion decoy
    av.absorbDamage(amount);
    // damageReflect: whenever the Reflections link CASTER takes damage, the
    // TARGET takes equal damage. Uses absorbDamage directly to prevent chains.
    for (final link in ctx.state.reflectionLinks) {
      if (link.casterId != av.playerId) continue;
      if (!link.activeTriggers.contains(ReflectionTrigger.damageReflect)) continue;
      final reflectTarget = ctx.state.avatars
          .where((a) => a.playerId == link.targetId && a.isAlive)
          .firstOrNull;
      reflectTarget?.absorbDamage(amount);
    }
  }

  /// Damages [m] with [ctx.descriptor.affinity] as the attack type (so the
  /// resistance wheel applies), then handles Molten Carapace (EFEF): a hit
  /// from a source within 1 range reflects 1 fire damage back to the caster.
  static void _hitMinion(ApplyContext ctx, Minion m, int amount) {
    if (amount <= 0) return;
    m.takeDamage(amount, attackType: ctx.descriptor.affinity);
    if (m.abilities.contains(SummonAbility.moltenCarapace) &&
        hexDistance(ctx.caster.position, m.position) <= 1) {
      ctx.caster.absorbDamage(1);
    }
  }

  /// Push [av] back along their move path (or away from caster if they didn't
  /// move), then resolve tile-entry effects (lava, cascading/looping conveyor
  /// pushes) on the tile they land on -- see tile_entry_resolver.dart. This is
  /// what makes a knockback-into-a-conveyor immediately push further before
  /// the next formula in the same spell cast resolves.
  static void _knockback(WizardAvatar av, ApplyContext ctx) {
    final path = ctx.movePaths[av.playerId];
    HexCoord? landed;
    if (path != null && path.length >= 2) {
      // Bounce: step back one tile along the path they walked this turn.
      final bounceTarget = path[path.length - 2];
      if (ctx.state.battlefield.isInBounds(bounceTarget) &&
          !tileBlocksMovement(ctx.state.tileEffects[bounceTarget])) {
        landed = bounceTarget;
      }
    }
    // Fallback: push one tile away from the caster.
    landed ??= () {
      final dir = _pushDir(ctx.caster.position, av.position);
      if (dir == null) return null;
      final pushed = HexCoord(av.position.q + dir.q, av.position.r + dir.r);
      if (!ctx.state.battlefield.isInBounds(pushed)) return null;
      if (tileBlocksMovement(ctx.state.tileEffects[pushed])) return null;
      return pushed;
    }();
    if (landed == null) return;

    final outcome = resolveTileEntry(
      state: ctx.state,
      rng: ctx.rng,
      enteredTile: landed,
      flying: false,
      currentHp: av.hp,
    );
    av.position = outcome.finalPosition;
    ctx.state.battlefield.occupancy[av.playerId] = outcome.finalPosition;
    if (outcome.totalDamage > 0) av.absorbDamage(outcome.totalDamage);
    if (outcome.animationPath.length > 1) {
      ctx.conveyorChainEvents.add(ConveyorChainEvent(
        entityId: av.playerId,
        path: outcome.animationPath,
        damage: outcome.totalDamage,
        killed: outcome.killed,
      ));
    }
  }

  static void _knockbackMinion(Minion m, ApplyContext ctx) {
    // Any multi-tile body is immovable by exterior forces — naturally Big
    // (EEEE) or enlarged by a Rod of Spreading. Keying off the footprint (not
    // the ability) keeps a rod-grown creature consistent with a born-Big one.
    if (m.occupiedTiles.length > 1) return;
    final dir = _pushDir(ctx.caster.position, m.position);
    if (dir == null) return;
    final pushed = HexCoord(m.position.q + dir.q, m.position.r + dir.r);
    if (!ctx.state.battlefield.isInBounds(pushed)) return;
    if (tileBlocksMovement(ctx.state.tileEffects[pushed])) return;

    final flying = m.abilities.contains(SummonAbility.flying);
    final outcome = resolveTileEntry(
      state: ctx.state,
      rng: ctx.rng,
      enteredTile: pushed,
      flying: flying,
      currentHp: m.hp,
      footprintValid: (t) => _minionFootprintValid(ctx.state, t, m),
    );
    m.position = outcome.finalPosition;
    if (outcome.totalDamage > 0) m.takeDamage(outcome.totalDamage);
    if (outcome.animationPath.length > 1) {
      ctx.conveyorChainEvents.add(ConveyorChainEvent(
        entityId: m.id,
        path: outcome.animationPath,
        damage: outcome.totalDamage,
        killed: outcome.killed,
      ));
    }
  }

  /// Whether [m]'s full footprint (Big/EEEE occupies 3 tiles) fits centered
  /// at [center]: in bounds and not ImpassableTile (flying minions ignore
  /// ImpassableTile, matching TurnLoop._footprintValid's movement rule).
  static bool _minionFootprintValid(BattleState state, HexCoord center, Minion m) {
    final flying = m.abilities.contains(SummonAbility.flying);
    for (final t in footprintFor(center, m.abilities, m.sizeBonus)) {
      if (!state.battlefield.isInBounds(t)) return false;
      if (!flying && tileBlocksMovement(state.tileEffects[t])) return false;
    }
    return true;
  }

  // ── Status-effect helpers ─────────────────────────────────────────────────

  static void _addStatus(WizardAvatar av, String typeId, Map<String, int> mods,
      [ApplyContext? ctx]) {
    av.activeStatusEffects.removeWhere((fx) => fx.effectTypeId == typeId);
    av.activeStatusEffects.add(StatusEffect(
      effectTypeId: typeId,
      remainingTurns: 999,
      modifiers: mods,
    ));
    if (ctx != null && av.playerId == ctx.caster.playerId) {
      _mirrorStatus(ctx.state, av.playerId, typeId, mods, 999);
    }
  }

  /// statusMirror: give the Reflections link caster the same status effect that
  /// their linked target just self-cast.
  static void _mirrorStatus(BattleState state, String targetPlayerId,
      String typeId, Map<String, int> mods, int turns) {
    for (final link in state.reflectionLinks) {
      if (link.targetId != targetPlayerId) continue;
      if (!link.activeTriggers.contains(ReflectionTrigger.statusMirror)) continue;
      final mirror = state.avatars
          .where((a) => a.playerId == link.casterId && a.isAlive)
          .firstOrNull;
      if (mirror == null) continue;
      mirror.activeStatusEffects.removeWhere((fx) => fx.effectTypeId == typeId);
      mirror.activeStatusEffects.add(StatusEffect(
        effectTypeId: typeId,
        remainingTurns: turns,
        modifiers: mods,
      ));
    }
  }

  static void _addStatusWithDuration(
      WizardAvatar av, String typeId, Map<String, int> mods, int turns,
      [ApplyContext? ctx]) {
    av.activeStatusEffects.removeWhere((fx) => fx.effectTypeId == typeId);
    av.activeStatusEffects.add(StatusEffect(
      effectTypeId: typeId,
      remainingTurns: turns,
      modifiers: mods,
    ));
    // statusMirror: only fires for self-buffs (caster == recipient).
    if (ctx != null && av.playerId == ctx.caster.playerId) {
      _mirrorStatus(ctx.state, av.playerId, typeId, mods, turns);
    }
  }

  // ── Summon helpers ────────────────────────────────────────────────────────

  /// Finds the nearest tile whose full footprint (see [footprintFor] --
  /// non-Big creatures occupy just the one tile) is open, preferring
  /// [preferred] itself.
  static HexCoord _findCreatureSpawnTile(
      BattleState state, HexCoord preferred, Set<SummonAbility> abilities,
      [int sizeBonus = 0]) {
    bool footprintOpen(HexCoord center) {
      for (final t in footprintFor(center, abilities, sizeBonus)) {
        if (!state.battlefield.isInBounds(t)) return false;
        if (!_isTileOpen(state, t)) return false;
      }
      return true;
    }

    if (footprintOpen(preferred)) return preferred;
    for (final n in _hexNeighbors(preferred)) {
      if (footprintOpen(n)) return n;
    }
    return preferred; // fallback: stack anyway
  }

  static bool _isTileOpen(BattleState state, HexCoord hex) {
    if (tileBlocksMovement(state.tileEffects[hex])) return false;
    if (state.avatars.any((av) => av.position == hex)) return false;
    if (state.minions.any((m) => m.isAlive && m.occupiedTiles.contains(hex))) return false;
    return true;
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  static List<WizardAvatar> _avatarsAt(BattleState state, HexCoord hex) =>
      state.avatars.where((av) => av.isAlive && av.position == hex).toList();

  static List<Minion> _minionsAt(BattleState state, HexCoord hex) =>
      state.minions.where((m) => m.isAlive && m.occupiedTiles.contains(hex)).toList();

  /// All avatars and minions within [radius] tiles of [center].
  static (List<WizardAvatar>, List<Minion>) _entitiesInRadius(
      BattleState state, HexCoord center, int radius) {
    final avs = state.avatars
        .where((av) => av.isAlive && hexDistance(av.position, center) <= radius)
        .toList();
    final mns = state.minions
        .where((m) => m.isAlive && m.distanceTo(center) <= radius)
        .toList();
    return (avs, mns);
  }

  /// Tiles strictly between [from] and [to] (exclusive of both endpoints).
  static List<HexCoord> _hexLinePath(HexCoord from, HexCoord to) {
    final n = hexDistance(from, to);
    if (n <= 1) return [];
    final path = <HexCoord>[];
    for (var i = 1; i < n; i++) {
      final t = i / n;
      final q = (from.q * (1 - t) + to.q * t).round();
      final r = (from.r * (1 - t) + to.r * t).round();
      path.add(HexCoord(q, r));
    }
    return path;
  }

  static List<HexCoord> _hexNeighbors(HexCoord h) {
    const dirs = [
      HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
      HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
    ];
    return dirs.map((d) => HexCoord(h.q + d.q, h.r + d.r)).toList();
  }

  /// Axial direction pushing [from] away from [source]. Null if same tile.
  static HexCoord? _pushDir(HexCoord source, HexCoord from) {
    final dq = from.q - source.q;
    final dr = from.r - source.r;
    if (dq == 0 && dr == 0) return null;
    // Snap to one of the 6 hex directions.
    const dirs = [
      HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
      HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
    ];
    int bestDot = -999999;
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

  static int _dur(int base, bool half) =>
      half ? ((base + 1) ~/ 2) : base; // ceil(base / 2) when half

  static String _uid(ApplyContext ctx, String tag) =>
      '${ctx.caster.playerId}_${tag}_${ctx.rng.nextInt(1 << 30).toRadixString(36)}';
}
