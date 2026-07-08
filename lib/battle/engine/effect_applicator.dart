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
//   - Air / TileModification: conveyor direction requires caster input (UI)
//   - Fire+Earth / FuelTransmutation: wither/reactivate a hand spell (needs
//     SpellDraw wired into BattleState — see battle_state.dart TODO)
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
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';

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
  }) : rodConsumedFor = rodConsumedFor ?? {},
       movePaths      = movePaths      ?? {};

  final EffectDescriptor descriptor;
  final HexCoord targetTile;
  final WizardAvatar caster;
  final BattleState state;
  final Random rng;

  /// Tracks which playerIds have had an absorption rod consumed for this spell.
  final Set<String> rodConsumedFor;

  /// Full traversed paths for this turn: playerId → [origin, step1, ..., dest].
  /// Used by knockback to bounce the target back along the path they walked.
  final Map<String, List<HexCoord>> movePaths;
}

// ── Effect applicator ─────────────────────────────────────────────────────────

class EffectApplicator {
  /// Apply [ctx.descriptor.spellEffect] to [ctx.state], targeting [ctx.targetTile].
  static void apply(ApplyContext ctx) => switch (ctx.descriptor.spellEffect) {
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

  // ── Damage (Fire-Fire) ────────────────────────────────────────────────────

  static void _applyDamage(ApplyContext ctx, DamageEffect e) {
    switch (e.kind) {
      case DamageKind.direct:
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
          _hitMinion(m, e.amount);
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
            if (m is SpiritMinion) _hitMinion(m, e.amount); // traversal hits spirits
          }
          _destroyIllusionTerrainIfPresent(ctx, hex);
        }
        // Hit the final target (not already walked).
        for (final av in _avatarsAt(ctx.state, ctx.targetTile)) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in _minionsAt(ctx.state, ctx.targetTile)) {
          _hitMinion(m, e.amount);
        }
        _destroyIllusionTerrainIfPresent(ctx, ctx.targetTile);

      case DamageKind.splash:
        final inRadius = _entitiesInRadius(ctx.state, ctx.targetTile, e.splashRadius);
        for (final av in inRadius.$1) {
          _hitAvatar(av, e.amount, ctx);
        }
        for (final m in inRadius.$2) {
          _hitMinion(m, e.amount);
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
          _hitMinion(m, e.amount);
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
    // Barriers are self-buffs: applied to the caster.
    ctx.caster.barriers[affinity] = BarrierState(
      element: affinity,
      hp: e.hp,
      maxHp: e.hp,
      remainingTurns: e.durationTurns,
      fireAura: e.fireAura,
      manaRegenBonusPct: e.manaRegenBonusPct,
      freeMoveOnCollapse: e.freeMoveOnCollapse,
    );
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
      // Self-buff on caster.
      _addStatus(ctx.caster, StatusEffectId.highMobility, {'freeExtraTiles': e.freeExtraTiles}, ctx);
      return;
    }
    if (e.highLiquidity) {
      _addStatus(ctx.caster, StatusEffectId.highLiquidity, {'freeExtraTiles': e.freeExtraTiles}, ctx);
      return;
    }
    // Speed delta affects the target (Earth debuff) or caster (Air buff).
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
        // Inherit target's chain state, overwriting own.
        ctx.caster.activeChainElement = target.activeChainElement;
        ctx.caster.chainLengths.clear();
        ctx.caster.chainLengths.addAll(target.chainLengths);
        if (e.chainTransferBonus > 0 && ctx.caster.activeChainElement != null) {
          final el = ctx.caster.activeChainElement!;
          ctx.caster.chainLengths[el] = (ctx.caster.chainLengths[el] ?? 0) + e.chainTransferBonus;
        }
      }
      return;
    }
    if (e.setAllChainsToNegative) {
      if (e.negativeValue < 0) {
        // Potent: set all chains to negative value.
        for (final el in SpellAffinity.values) {
          ctx.caster.chainLengths[el] = e.negativeValue;
        }
        ctx.caster.activeChainElement = null;
      } else {
        // Base: clear all chains.
        ctx.caster.chainLengths.clear();
        ctx.caster.activeChainElement = null;
      }
      return;
    }
    // Fire: chain accrues faster / Earth: chain accrues slower.
    final pct = (e.chainAccumulationMultiplier * 100).round();
    final typeId = e.chainAccumulationMultiplier >= 1.0
        ? StatusEffectId.chainFast
        : StatusEffectId.chainSlow;
    _addStatusWithDuration(ctx.caster, typeId, {'chainAccMultiplierPct': pct}, e.durationTurns, ctx);
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
      _addStatusWithDuration(ctx.caster, StatusEffectId.quick, {}, e.durationTurns, ctx);
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

  // ── Reflection trigger helpers ────────────────────────────────────────────

  /// summonMirror: when the Reflections link TARGET summons a minion, the
  /// CASTER receives an identical minion on a nearby spawn tile.
  ///
  /// Currently unreachable: incantation formulas no longer create Minions
  /// directly (Fire-Earth/Earth-Fire moved to Status Effect Interaction/Fuel
  /// Transmutation in the v3.0 effect-table rework). Kept for the upcoming
  /// Rune Craft "summons" mode toggle, which will call this again once it has
  /// its own minion-creation path.
  // ignore: unused_element
  static void _fireSummonMirror(
      ApplyContext ctx, MinionStats stats, SpellAffinity affinity,
      {required bool isSpiritNotHound}) {
    for (final link in ctx.state.reflectionLinks) {
      if (link.targetId != ctx.caster.playerId) continue;
      if (!link.activeTriggers.contains(ReflectionTrigger.summonMirror)) continue;
      final mirror = ctx.state.avatars
          .where((a) => a.playerId == link.casterId && a.isAlive)
          .firstOrNull;
      if (mirror == null) continue;
      final spawn = _findSpawnTile(ctx.state, mirror.position);
      if (isSpiritNotHound) {
        ctx.state.minions.add(SpiritMinion(
          id: _uid(ctx, 'ms'),
          ownerId: link.casterId,
          teamId: mirror.teamId,
          position: spawn,
          affinity: affinity,
          stats: stats,
          actedThisTurn: true,
        ));
      } else {
        ctx.state.minions.add(HoundMinion(
          id: _uid(ctx, 'mh'),
          ownerId: link.casterId,
          teamId: mirror.teamId,
          position: spawn,
          affinity: affinity,
          stats: stats,
          actedThisTurn: true,
        ));
      }
    }
  }

  // ── Tile Modification (Earth-Water) ──────────────────────────────────────

  static void _applyTileModification(ApplyContext ctx, TileModificationEffect e) {
    ctx.state.tileEffects[ctx.targetTile] = e.tileEffect;
    if (e.canPlaceSecond) {
      // TODO(ui): second tile placement requires caster to select an adjacent
      //   tile during effect resolution. Stub: no second tile placed.
      //   For ConveyorTile, the direction is also selected here.
    }
  }

  // ── Range Modification (Earth-Air) ───────────────────────────────────────

  static void _applyRangeModification(ApplyContext ctx, RangeModificationEffect e) {
    if (e.penetrating) {
      _addStatusWithDuration(ctx.caster, StatusEffectId.penetrating, {
        'penetrationDamage': e.penetrationDamage,
      }, e.durationTurns, ctx);
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
    switch (e.affinity) {
      case SpellAffinity.fire:
        // TODO(battle): wither e.witherSpellCount random active (hand)
        //   spells, found by bookmark. Requires SpellDraw wired into
        //   BattleState (see battle_state.dart TODO) plus a withered-spell
        //   flag enforced at cast time.
        for (var i = 0; i < e.gainArtifactCount; i++) {
          const pool = [
            AccoutrementKind.manaGem,
            AccoutrementKind.bookmark,
            AccoutrementKind.deflectionTotem,
          ];
          final kind = pool[ctx.rng.nextInt(pool.length)];
          ctx.caster.accoutrements.add(Accoutrement(id: _uid(ctx, 'ft'), kind: kind));
          if (kind == AccoutrementKind.manaGem) {
            ctx.caster.maxMana = ctx.caster.maxManaFromGems;
          }
        }

      case SpellAffinity.earth:
        ctx.caster.absorbDamage(e.burnLife);
        // TODO(battle): reactivate e.reactivateSpellCount withered hand
        //   spells. Same SpellDraw-wiring dependency as the Fire flavor above.

      case SpellAffinity.water:
        ctx.caster.mana = (ctx.caster.mana - e.burnMana).clamp(0, ctx.caster.maxMana);
        ctx.caster.hp += e.gainLife;

      case SpellAffinity.air:
        final burnable = ctx.caster.accoutrements.where((a) => !a.isCoreGem).toList();
        var burned = 0;
        while (burned < e.burnArtifactCount && burnable.isNotEmpty) {
          final idx = ctx.rng.nextInt(burnable.length);
          final target = burnable.removeAt(idx);
          ctx.caster.accoutrements.remove(target);
          burned++;
        }
        ctx.caster.mana = (ctx.caster.mana + e.gainMana).clamp(0, ctx.caster.maxMana);
    }
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
            // Find burnable accoutrements (not core gems).
            final burnable = av.accoutrements
                .where((a) => !a.isCoreGem)
                .toList();
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
        }

      case SpellAffinity.earth:
        // Summon deflection totem(s) for caster.
        for (var i = 0; i < e.count; i++) {
          ctx.caster.accoutrements.add(Accoutrement(
            id: _uid(ctx, 'dt'),
            kind: AccoutrementKind.deflectionTotem,
          ));
        }

      case SpellAffinity.water:
        // Summon mana gem(s) for caster.
        for (var i = 0; i < e.count; i++) {
          ctx.caster.accoutrements.add(Accoutrement(
            id: _uid(ctx, 'mg'),
            kind: AccoutrementKind.manaGem,
          ));
          // Update caster's max mana to reflect new gem.
          ctx.caster.maxMana = ctx.caster.maxManaFromGems;
        }

      case SpellAffinity.air:
        // Summon bookmark(s) for caster.
        for (var i = 0; i < e.count; i++) {
          ctx.caster.accoutrements.add(Accoutrement(
            id: _uid(ctx, 'bm'),
            kind: AccoutrementKind.bookmark,
          ));
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
  /// always closing to attack rather than kiting (Minion.aggressive).
  static void _applyIllusionMinionCopy(ApplyContext ctx) {
    final source = _minionsAt(ctx.state, ctx.targetTile).firstOrNull;
    if (source == null) return;
    final spawn = _findSpawnTile(ctx.state, ctx.targetTile);
    final clonedStats = source.stats.copyWith(maxHp: 1);
    final Minion clone = source is SpiritMinion
        ? SpiritMinion(
            id: _uid(ctx, 'ic'),
            ownerId: ctx.caster.playerId,
            teamId: ctx.caster.teamId,
            position: spawn,
            affinity: source.affinity,
            stats: clonedStats,
            aggressive: true,
          )
        : HoundMinion(
            id: _uid(ctx, 'ic'),
            ownerId: ctx.caster.playerId,
            teamId: ctx.caster.teamId,
            position: spawn,
            affinity: source.affinity,
            stats: clonedStats,
            aggressive: true,
          );
    ctx.state.minions.add(clone);
  }

  /// Earth flavor: clone the TileEffect on the target tile onto every
  /// terrain-free neighbor; copies are destroyed by any damage touching
  /// their tile (see BattleState.illusionTerrainTiles / _applyDamage).
  static void _applyIllusionTerrainCopy(ApplyContext ctx) {
    final source = ctx.state.tileEffects[ctx.targetTile];
    if (source == null) return;
    for (final n in _hexNeighbors(ctx.targetTile)) {
      if (!ctx.state.battlefield.isInBounds(n)) continue;
      if (ctx.state.tileEffects.containsKey(n)) continue;
      ctx.state.tileEffects[n] = source;
      ctx.state.illusionTerrainTiles.add(n);
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
    // Store pending multiplier; consumed by EffectResolver the next time the
    // caster resolves a spell with an effect of targetElement affinity.
    ctx.caster.pendingEffectMultipliers[e.targetElement] = e.multiplier;
  }

  // ── Haymaker Interaction (Air-Earth) ─────────────────────────────────────

  static void _applyHaymakerInteraction(ApplyContext ctx, HaymakerInteractionEffect e) {
    if (e.doTStackIncrement > 0) {
      _addStatusWithDuration(ctx.caster, StatusEffectId.haymakerDot,
          {'doTStackIncrement': e.doTStackIncrement}, e.durationTurns, ctx);
    }
    if (e.slowsTarget) {
      _addStatusWithDuration(ctx.caster, StatusEffectId.haymakerSlow, {}, e.durationTurns, ctx);
    }
    if (e.drainTargetStatus) {
      _addStatusWithDuration(ctx.caster, StatusEffectId.haymakerStatusDrain, {}, e.durationTurns, ctx);
    }
    if (e.distanceBonusDamage) {
      _addStatusWithDuration(ctx.caster, StatusEffectId.haymakerDistanceBonus, {}, e.durationTurns, ctx);
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
    if (e.requiresOpponentReveal) {
      // Water/Air Divination: opponent must send a DivinationReveal protocol message.
      // TODO(battle): send DivinationRevealRequest via BattleSession; await
      //   DivinationReveal frame; apply revealed data to local UI state.
      //   Stub: mark the status effect so the UI can show "divination pending."
      final typeId = ctx.descriptor.affinity == SpellAffinity.water
          ? StatusEffectId.revealSpells
          : StatusEffectId.revealTargetTile;
      _addStatusWithDuration(ctx.caster, typeId, {}, e.durationTurns, ctx);
    }
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

  static void _hitMinion(Minion m, int amount) {
    if (amount <= 0) return;
    m.takeDamage(amount);
  }

  /// Push [av] back along their move path (or away from caster if they didn't move).
  static void _knockback(WizardAvatar av, ApplyContext ctx) {
    final path = ctx.movePaths[av.playerId];
    if (path != null && path.length >= 2) {
      // Bounce: step back one tile along the path they walked this turn.
      final bounceTarget = path[path.length - 2];
      if (ctx.state.battlefield.isInBounds(bounceTarget) &&
          ctx.state.tileEffects[bounceTarget] is! ImpassableTile) {
        av.position = bounceTarget;
        ctx.state.battlefield.occupancy[av.playerId] = bounceTarget;
        return;
      }
    }
    // Fallback: push one tile away from the caster.
    final dir = _pushDir(ctx.caster.position, av.position);
    if (dir == null) return;
    final pushed = HexCoord(av.position.q + dir.q, av.position.r + dir.r);
    if (!ctx.state.battlefield.isInBounds(pushed)) return;
    if (ctx.state.tileEffects[pushed] is ImpassableTile) return;
    av.position = pushed;
    ctx.state.battlefield.occupancy[av.playerId] = pushed;
  }

  static void _knockbackMinion(Minion m, ApplyContext ctx) {
    final dir = _pushDir(ctx.caster.position, m.position);
    if (dir == null) return;
    final pushed = HexCoord(m.position.q + dir.q, m.position.r + dir.r);
    if (!ctx.state.battlefield.isInBounds(pushed)) return;
    if (ctx.state.tileEffects[pushed] is ImpassableTile) return;
    m.position = pushed;
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

  /// Find the nearest unoccupied tile to [preferred], including [preferred].
  static HexCoord _findSpawnTile(BattleState state, HexCoord preferred) {
    if (_isTileOpen(state, preferred)) return preferred;
    for (final n in _hexNeighbors(preferred)) {
      if (state.battlefield.isInBounds(n) && _isTileOpen(state, n)) return n;
    }
    return preferred; // fallback: stack on the target tile
  }

  static bool _isTileOpen(BattleState state, HexCoord hex) {
    if (state.tileEffects[hex] is ImpassableTile) return false;
    if (state.avatars.any((av) => av.position == hex)) return false;
    if (state.minions.any((m) => m is HoundMinion && m.position == hex)) return false;
    return true;
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  static List<WizardAvatar> _avatarsAt(BattleState state, HexCoord hex) =>
      state.avatars.where((av) => av.isAlive && av.position == hex).toList();

  static List<Minion> _minionsAt(BattleState state, HexCoord hex) =>
      state.minions.where((m) => m.isAlive && m.position == hex).toList();

  /// All avatars and minions within [radius] tiles of [center].
  static (List<WizardAvatar>, List<Minion>) _entitiesInRadius(
      BattleState state, HexCoord center, int radius) {
    final avs = state.avatars
        .where((av) => av.isAlive && hexDistance(av.position, center) <= radius)
        .toList();
    final mns = state.minions
        .where((m) => m.isAlive && hexDistance(m.position, center) <= radius)
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
