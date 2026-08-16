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
// ordering, scheduling, or the number of suspension points in a turn. Phases
// that *do* suspend (action resolution, the free-move rounds, summon movement
// playback) are a harder problem and are deliberately left where they are.
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
// Avatar movement, spell application, melee, summon AI and the free-move
// rounds are all still in `TurnLoop`. Several of them are deterministic too;
// they are just entangled with suspension points, and moving them is a
// separate change with its own corpus run.

import 'package:rune_duel/engine/hex_grid.dart';

import '../models/battle_state.dart';
import '../models/effect_descriptor.dart'; // exports SpellAffinity
import '../models/hex_battlefield.dart' show hexDistance;
import '../models/minion.dart';
import '../models/reflection_link.dart';
import '../models/status_effect_ids.dart';
import '../models/terrain.dart'
    show
        ConveyorTile,
        DustCloud,
        FloorIsLava,
        MobileCloud,
        ToxicCloud,
        WaterCloud,
        tileBlocksMovement;
import '../models/wild_magic_effect.dart' show WildMagicEffectKind;
import '../models/wizard_avatar.dart';
import 'effect_applicator.dart';
import 'hash_rng.dart';
import 'terrain_ops.dart';
import 'tile_entry_resolver.dart';
import 'wild_magic_applicator.dart';

/// Battle resolution that runs identically on both devices, given the same
/// state and the same seeded RNG.
///
/// Holds [state] and nothing else — no session, no identity, no local-player
/// notion. Anything that needs to know *which device it is* is by definition
/// not deterministic resolution and belongs on the caller's side of the seam.
class DeterministicResolution {
  DeterministicResolution(this.state);

  final BattleState state;

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
