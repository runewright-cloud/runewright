// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_state.dart — BattleState: the full match container.
//
// Holds all mutable match state:
//   - WizardAvatars (players), Teams, Battlefield
//   - Minions (spirits and hounds) — currently only created by Illusions'
//     Fire flavor (a 1-HP clone); Fire-Earth/Earth-Fire no longer summon them
//     directly (moved to Status Effect Interaction/Fuel Transmutation in the
//     v3.0 effect-table rework -- see effect_kind.dart)
//   - Tile effects — permanent terrain placed by Earth-Water spells
//   - Cloud objects — temporary area effects placed by Water-Fire spells
//   - Wizard illusion decoy sets + illusion terrain copies — Water-Air spells
//
// Canonical serialisation (for the per-turn state-hash exchange) covers all
// of the above in a deterministic, fixed-width byte encoding. Both clients
// must produce identical bytes or the match is flagged as diverged.
//
// See docs/BATTLE_PROTOCOL.md §6 (state hash) and §8 (win condition).

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/terrain.dart'
    show CloudObject, TileEffect, CloudKind,
         ToxicCloud, DustCloud, WaterCloud, MobileCloud,
         FloorIsLava, ImpassableTile, SlowTile, ConveyorTile,
         IceTile, ChasmTile,
         tileIsDestructibleTerrain, terrainMaxHpOf;
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;

import 'match_config.dart';
import 'wild_magic_state.dart';
import 'pending_delayed_spell.dart';
import 'reflection_link.dart';
import 'divination_link.dart';
import 'illusion.dart';
import 'wizard_avatar.dart';
import 'hex_battlefield.dart';
import 'minion.dart';

// ── Team ──────────────────────────────────────────────────────────────────────

class Team {
  const Team({required this.id, required this.playerIds});

  final String id;
  final List<String> playerIds;

  Map<String, dynamic> toJson() => {'id': id, 'playerIds': playerIds};
}

// ── Win check result ──────────────────────────────────────────────────────────

class WinCheckResult {
  const WinCheckResult({
    required this.isOver,
    this.winningTeamId,
    required this.condition,
  });

  final bool isOver;
  final String? winningTeamId;
  final WinCondition condition;
}

// ── BattleState ───────────────────────────────────────────────────────────────

class BattleState {
  BattleState({
    required this.config,
    required this.avatars,
    required this.teams,
    required this.battlefield,
    this.turnNumber = 0,
    List<Minion>? minions,
    Map<HexCoord, TileEffect>? tileEffects,
    List<CloudObject>? clouds,
    List<PendingDelayedSpell>? pendingDelayedSpells,
    List<ReflectionLink>? reflectionLinks,
    List<DivinationLink>? divinationLinks,
    List<WizardIllusionSet>? wizardIllusions,
    Map<HexCoord, String>? illusionTerrainTiles,
    Map<HexCoord, int>? expiringTiles,
    Map<HexCoord, int>? terrainHp,
    Map<HexCoord, Map<SpellAffinity, BarrierState>>? terrainBarriers,
    WildMagicState? wildMagic,
    List<String>? componentSeating,
  })  : componentSeating = componentSeating ?? const [],
        minions = minions ?? [],
        expiringTiles = expiringTiles ?? {},
        terrainHp = terrainHp ?? {},
        terrainBarriers = terrainBarriers ?? {},
        wildMagic = wildMagic ?? WildMagicState(),
        tileEffects = tileEffects ?? {},
        clouds = clouds ?? [],
        pendingDelayedSpells = pendingDelayedSpells ?? [],
        reflectionLinks = reflectionLinks ?? [],
        divinationLinks = divinationLinks ?? [],
        wizardIllusions = wizardIllusions ?? [],
        illusionTerrainTiles = illusionTerrainTiles ?? {};

  final MatchConfig config;
  final List<WizardAvatar> avatars;
  final List<Team> teams;
  final Battlefield battlefield;
  int turnNumber;

  /// Player ids ordered clockwise around the field by the vertex each one
  /// SPAWNED on — the seating that decides who performs their spell components
  /// first each turn (docs/SPELL_COMPONENTS_PLAN.md §5.2). Built by the setup
  /// builders via [clockwiseComponentOrder], which is why this is stored
  /// rather than derived: current positions change as wizards walk, and the
  /// seating must not change with them.
  ///
  /// Empty for states built before this existed (and for headless test
  /// fixtures) — callers fall back to [avatars] order, which is already
  /// canonical, so an empty list degrades to a stable order rather than to
  /// nothing.
  ///
  /// NOT part of [toCanonicalBytes]: it is a pure function of setup inputs
  /// both devices already agree on, so hashing it would add a desync surface
  /// without adding any check the setup builders don't already give.
  final List<String> componentSeating;

  /// All living minions (spirits and hounds) in creation order.
  final List<Minion> minions;

  /// Permanent tile effects keyed by hex coordinate. Placed by tileModification
  /// (Earth-Water) spells. Overwritten if two effects land on the same tile
  /// (last-resolution wins — see design doc §multi-player same-tile).
  final Map<HexCoord, TileEffect> tileEffects;

  /// Active cloud objects from Clouds (Water-Fire) spells.
  final List<CloudObject> clouds;

  /// Mystery-enhanced spells committed but not yet resolved.
  /// Keyed by [PendingDelayedSpell.id]; expires at [PendingDelayedSpell.maxTurn].
  final List<PendingDelayedSpell> pendingDelayedSpells;

  /// Active Reflections (Water-Water) links. Each link binds a caster to a
  /// target for the remainder of the match, carrying 2–3 randomly-chosen
  /// reaction triggers. Removed when either participant dies.
  final List<ReflectionLink> reflectionLinks;

  /// Active Divination (Air-Water) links. Each link binds a scryer (caster)
  /// to the player whose committed spell target is revealed to them each
  /// turn — see MESH_ARCHITECTURE.md §13b and TurnLoop.beginTurn. Removed
  /// when either participant dies or the duration expires.
  final List<DivinationLink> divinationLinks;

  /// Active wizard-decoy sets from Illusions (Water-Air, Water flavor). At
  /// most one per owner; removed once its last decoy is consumed.
  final List<WizardIllusionSet> wizardIllusions;

  /// Hexes whose tileEffects entry is an Illusions (Water-Air, Earth flavor)
  /// terrain copy with 1 HP -- destroyed by any damage that touches the tile
  /// (see EffectApplicator._applyDamage), mapped to the playerId of the
  /// wizard who conjured the copy. The owner is what lets an Earthen Scrying
  /// Pool bearer tell an *enemy* illusion from their own team's
  /// (EffectApplicator.dispelIllusionsNearScryers).
  final Map<HexCoord, String> illusionTerrainTiles;

  /// Temporary tile effects: coord → the LAST turn number the effect is active
  /// (swept at the end of that turn, in Phase 6). The mechanism for the
  /// wild-magic terrain effects — Mountains (2[3] turns), Chasm, Glacier —
  /// every TileEffect predating wild magic is permanent and needed no such
  /// thing. An entry here is always paired with a [tileEffects] entry on the
  /// same coord; sweeping removes both.
  final Map<HexCoord, int> expiringTiles;

  /// Current HP of every destructible terrain tile (docs/WALL_LOS_PLAN.md
  /// §5.0). A side-map, not a field on [TileEffect]: that class is
  /// deliberately immutable, which is why expiry already lives outside it in
  /// [expiringTiles].
  ///
  /// Seeded at max by [placeTerrain]; an entry exists exactly while a
  /// destructible tile does. Both affinity and max HP are pure functions of
  /// the tile type (terrain.dart), so there is nothing else to store.
  ///
  /// Read through [terrainHpAt], never directly — an illusory copy overrides
  /// the type's pool at 1 HP (§3.7).
  final Map<HexCoord, int> terrainHp;

  /// Barriers imbued into terrain by an Earth-Earth cast aimed at a terrain
  /// tile (§2.3/§2.6), keyed by coord then by element exactly like
  /// [Minion.barriers]. Absorbs before [terrainHp], so the elemental wheel
  /// applies per layer.
  final Map<HexCoord, Map<SpellAffinity, BarrierState>> terrainBarriers;

  /// Match-scoped wild-magic globals (Burning Hot's armed turn, Phoenix /
  /// Statuesque player sets, Rippling Reflections' drift, Scattered Gusts).
  /// All of it is consensus state — see [toCanonicalBytes].
  final WildMagicState wildMagic;

  // ── Terrain HP (docs/WALL_LOS_PLAN.md §5.0) ───────────────────────────────

  /// Current HP of the terrain on [hex], or 0 when there is none.
  ///
  /// Checks [illusionTerrainTiles] FIRST: an Earthen Illusions copy is 1 HP by
  /// design, and letting it inherit the real type's pool would turn that spell
  /// into a terrain-duplication engine (§3.7).
  /// A tile with terrain but no [terrainHp] entry reads as FULL, not dead —
  /// that is a fixture built by assigning `tileEffects` directly rather than
  /// through [placeTerrain], and treating it as 0 HP would make it vanish on
  /// the first scratch. [damageTerrain] makes the same assumption.
  int terrainHpAt(HexCoord hex) {
    if (illusionTerrainTiles.containsKey(hex)) return 1;
    return terrainHp[hex] ?? terrainMaxHpOf(tileEffects[hex]);
  }

  /// Places [effect] on [hex], seeding a full HP pool and clearing anything
  /// the previous tile left behind.
  ///
  /// **Use this rather than assigning `tileEffects[hex]` directly.** Terrain is
  /// not re-elemented in place: a new tile means a new type, a new affinity,
  /// full HP, and no inherited barriers (§3.4). Skipping the clear is how a
  /// later tile silently inherits ghost HP and ghost barriers (§5.0/§7).
  ///
  /// [illusionOwner] marks the tile as an Earthen Illusions copy conjured by
  /// that player: 1 HP regardless of type, so it gets no [terrainHp] entry at
  /// all and [terrainHpAt] answers for it instead (§3.7).
  void placeTerrain(HexCoord hex, TileEffect effect, {String? illusionOwner}) {
    tileEffects[hex] = effect;
    terrainBarriers.remove(hex);
    if (illusionOwner != null) {
      illusionTerrainTiles[hex] = illusionOwner;
      terrainHp.remove(hex);
      return;
    }
    illusionTerrainTiles.remove(hex);
    if (tileIsDestructibleTerrain(effect)) {
      terrainHp[hex] = terrainMaxHpOf(effect);
    } else {
      terrainHp.remove(hex);
    }
  }

  /// Removes the terrain on [hex] and every trace of it. Destruction, expiry,
  /// and dispel all funnel here so no side-map is ever left orphaned.
  void removeTerrain(HexCoord hex) {
    tileEffects.remove(hex);
    terrainHp.remove(hex);
    terrainBarriers.remove(hex);
    illusionTerrainTiles.remove(hex);
  }

  // TODO(battle): add SpellDrawState per player once SpellDraw is wired in.
  // TODO(battle): add CommitRevealState for the current turn's entropy.

  // ── Win condition ─────────────────────────────────────────────────────────

  WinCheckResult checkWinCondition() {
    return switch (config.winCondition) {
      WinCondition.lastTeamStanding => _checkLastTeamStanding(),
      WinCondition.captureTheFlag => _checkAlternate(WinCondition.captureTheFlag),
    };
  }

  WinCheckResult _checkLastTeamStanding() {
    final livingTeams = <String>{};
    for (final avatar in avatars) {
      if (avatar.isAlive) livingTeams.add(avatar.teamId);
    }
    if (livingTeams.length == 1) {
      return WinCheckResult(
        isOver: true,
        winningTeamId: livingTeams.first,
        condition: WinCondition.lastTeamStanding,
      );
    }
    if (livingTeams.isEmpty) {
      return WinCheckResult(
        isOver: true,
        winningTeamId: null,
        condition: WinCondition.lastTeamStanding,
      );
    }
    return WinCheckResult(
      isOver: false,
      winningTeamId: null,
      condition: WinCondition.lastTeamStanding,
    );
  }

  WinCheckResult _checkAlternate(WinCondition condition) {
    // TODO(battle): implement alternate win condition resolution.
    return WinCheckResult(isOver: false, winningTeamId: null, condition: condition);
  }

  // ── Per-turn ticks ────────────────────────────────────────────────────────

  /// Ticks clouds, removing expired ones.
  void tickClouds() => clouds.removeWhere((c) => !c.tick());

  /// Ticks minion actedThisTurn flags (reset for next turn).
  void resetMinionActions() {
    for (final m in minions) {
      m.actedThisTurn = false;
    }
  }

  // ── Canonical serialisation ───────────────────────────────────────────────

  /// Deterministic binary encoding of all turn-relevant game state for
  /// SHA-256 hashing. Both clients must produce byte-identical output.
  ///
  /// Field order: turnNumber, config basics, avatars (sorted by playerId),
  /// teams (sorted by id), minions (sorted by id), tileEffects (sorted by
  /// coord), clouds (sorted by id).
  Uint8List toCanonicalBytes() {
    final buf = _ByteWriter();

    buf.writeUint32(turnNumber);
    buf.writeUint8(config.winCondition.index);

    // Avatars
    final sortedAvatars = (List<WizardAvatar>.from(avatars)
          ..sort((a, b) => a.playerId.compareTo(b.playerId)));
    buf.writeUint16(sortedAvatars.length);
    for (final a in sortedAvatars) {
      buf.writeUtf8(a.playerId);
      buf.writeHex(a.ownerPubkeyHex);
      buf.writeInt32(a.hp);
      buf.writeInt32(a.mana);
      buf.writeInt32(a.maxMana);
      buf.writeInt16(a.position.q);
      buf.writeInt16(a.position.r);
      buf.writeUtf8(a.teamId);

      // Phase-0 artifact activation (ARTIFACT_SYSTEM_PLAN.md §6.3). Turn-scoped
      // but hashed: it gates counter-charm firing at Phase 5, so a divergence
      // here would silently change which casts get countered. 0xFF = declared
      // nothing. Accoutrement *removal* needs no field of its own — the
      // accoutrement list below shortens on both devices.
      buf.writeUint8(a.declaredActivation?.index ?? 0xFF);

      final sortedAcc = (List<Accoutrement>.from(a.accoutrements)
            ..sort((x, y) => x.id.compareTo(y.id)));
      buf.writeUint16(sortedAcc.length);
      for (final acc in sortedAcc) {
        buf.writeUtf8(acc.id);
        buf.writeUint8(acc.kind.index);
        buf.writeUint8(acc.counterCharmRevealed ? 1 : 0);
        // Counter-charm trajectory (COUNTER_CHARM_KINSHIP_PLAN.md Phase 2).
        // Hashed because it decides which formulas of a cast get cancelled: a
        // divergence here changes resolution, not just display. Length-
        // prefixed, one byte per element, so an unattuned charm (length 0)
        // and a charm attuned to nothing-yet stay distinguishable.
        final trajectory = acc.charmTrajectory;
        buf.writeUint8(trajectory?.length ?? 0);
        for (final z in trajectory ?? const <BorderZone>[]) {
          buf.writeUint8(z.index);
        }
      }

      final sortedFx = (List<StatusEffect>.from(a.activeStatusEffects)
            ..sort((x, y) => x.effectTypeId.compareTo(y.effectTypeId)));
      buf.writeUint16(sortedFx.length);
      for (final fx in sortedFx) {
        buf.writeUtf8(fx.effectTypeId);
        buf.writeInt32(fx.remainingTurns);
        buf.writeUint8(fx.isDormant ? 1 : 0);
        final sortedKeys = fx.modifiers.keys.toList()..sort();
        buf.writeUint16(sortedKeys.length);
        for (final key in sortedKeys) {
          buf.writeUtf8(key);
          buf.writeInt32(fx.modifiers[key]!);
        }
      }

      // Barriers
      final sortedBarriers = a.barriers.entries.toList()
        ..sort((x, y) => x.key.index.compareTo(y.key.index));
      buf.writeUint8(sortedBarriers.length);
      for (final entry in sortedBarriers) {
        buf.writeUint8(entry.key.index);
        buf.writeInt32(entry.value.hp);
        buf.writeInt32(entry.value.remainingTurns);
      }

      // Chain state
      buf.writeUint8(a.activeChainElement?.index ?? 0xFF);
      final sortedChains = a.chainLengths.entries.toList()
        ..sort((x, y) => x.key.index.compareTo(y.key.index));
      buf.writeUint8(sortedChains.length);
      for (final entry in sortedChains) {
        buf.writeUint8(entry.key.index);
        buf.writeInt32(entry.value);
      }

      // Pending multipliers
      final sortedMults = a.pendingEffectMultipliers.entries.toList()
        ..sort((x, y) => x.key.index.compareTo(y.key.index));
      buf.writeUint8(sortedMults.length);
      for (final entry in sortedMults) {
        buf.writeUint8(entry.key.index);
        buf.writeUint8(entry.value.multiplier);
        buf.writeUint8(entry.value.remainingTurns);
      }

      // Aetherial Armor (engine v6). Hashed because armor now moves
      // deterministic gameplay — starting HP, melee, move speed, spell range —
      // so two devices holding different readings of the same worn armor must
      // not be able to agree on a state hash.
      //
      // The COMPLETE certified semantics go in, not just the four numbers that
      // are live today. Two armors can grant identical active bonuses off
      // different element counts, keyword sets and trajectories; encoding only
      // the bonuses would let such a pair hash equal while the devices disagree
      // about what is worn, and the first keyword to become live would then
      // silently desync a match that had looked in lockstep. Nothing authored
      // participates — no proof bytes, no `SpellAsset` metadata — for the same
      // reason `CertifiedArmor` never reads them (M4.22).
      //
      // Presence is its own byte, so "no armor" and "an armor whose sequence
      // happens to be empty" stay distinguishable.
      final armor = a.armor;
      buf.writeUint8(armor == null ? 0 : 1);
      if (armor != null) {
        // T alongside slotCost: the cost is a lossy function of T (four T
        // values share each rung), so agreeing on the cost is not agreeing on
        // the armor.
        buf.writeUint8(armor.t);
        buf.writeUint8(armor.slotCost);
        buf.writeUint8(armor.fireCount);
        buf.writeUint8(armor.airCount);
        buf.writeUint8(armor.waterCount);
        buf.writeUint8(armor.earthCount);
        buf.writeUint8(armor.meleeBonus);
        buf.writeUint8(armor.moveSpeedBonus);
        buf.writeUint8(armor.spellRangeBonus);
        buf.writeUint8(armor.armorHpBonus);
        // Keywords as a bitmask over ArmorKeyword's declaration order, exactly
        // as a minion's abilities are encoded below — a Set's iteration order
        // is insertion order and would make the bytes depend on the order the
        // patterns happened to match.
        var keywordMask = 0;
        for (final k in armor.keywords) {
          keywordMask |= 1 << k.index;
        }
        buf.writeUint16(keywordMask);
        // The certified dominance sequence, encoded exactly like a counter
        // charm's trajectory above (length-prefixed, one byte per zone) — one
        // BorderZone encoding in this function, not two.
        buf.writeUint8(armor.elementSequence.length);
        for (final z in armor.elementSequence) {
          buf.writeUint8(z.index);
        }
      }
    }

    // Teams
    final sortedTeams = (List<Team>.from(teams)..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedTeams.length);
    for (final t in sortedTeams) {
      buf.writeUtf8(t.id);
      buf.writeUint16(t.playerIds.length);
      for (final pid in t.playerIds) {
        buf.writeUtf8(pid);
      }
    }

    // Minions. Footprint (see Minion.occupiedTiles) is a pure function of
    // position + abilities + sizeBonus (the Rod of Wind size rung), so
    // only sizeBonus needs encoding alongside them.
    final sortedMinions = (List<Minion>.from(minions)..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedMinions.length);
    for (final m in sortedMinions) {
      buf.writeUtf8(m.id);
      buf.writeUtf8(m.ownerId);
      buf.writeUtf8(m.teamId);
      buf.writeInt16(m.position.q);
      buf.writeInt16(m.position.r);
      buf.writeInt32(m.hp);
      buf.writeUint8(m.affinity.index);
      buf.writeInt32(m.stats.maxHp);
      buf.writeInt32(m.stats.damage);
      buf.writeInt32(m.stats.moveSpeed);
      buf.writeInt32(m.stats.attackRange);
      var abilityMask = 0;
      for (final a in m.abilities) {
        abilityMask |= 1 << a.index;
      }
      buf.writeUint16(abilityMask);
      buf.writeUint8(m.personality.index);
      buf.writeUint8(m.sizeBonus);
      // Illusory creatures die on sight to an Earthen Scrying Pool bearer,
      // so this is gameplay state both clients must agree on (unlike the
      // purely presentational copiedFromMinionId, which stays out).
      buf.writeUint8(m.isIllusion ? 1 : 0);
    }

    // Tile effects
    final sortedTiles = tileEffects.entries.toList()
      ..sort((a, b) {
        final qc = a.key.q.compareTo(b.key.q);
        return qc != 0 ? qc : a.key.r.compareTo(b.key.r);
      });
    buf.writeUint16(sortedTiles.length);
    for (final entry in sortedTiles) {
      buf.writeInt16(entry.key.q);
      buf.writeInt16(entry.key.r);
      buf.writeUint8(_tileEffectIndex(entry.value));
    }

    // Clouds
    final sortedClouds = (List<CloudObject>.from(clouds)..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedClouds.length);
    for (final c in sortedClouds) {
      buf.writeUtf8(c.id);
      buf.writeInt16(c.position.q);
      buf.writeInt16(c.position.r);
      buf.writeInt32(c.remainingTurns);
      buf.writeUint8(_cloudKindIndex(c.kind));
      buf.writeUint8(c.radius);
    }

    // Pending delayed spells (commitment only — target/delay remain hidden).
    final sortedPending = (List<PendingDelayedSpell>.from(pendingDelayedSpells)
      ..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedPending.length);
    for (final p in sortedPending) {
      buf.writeUtf8(p.id);
      buf.writeUtf8(p.ownerId);
      buf.writeUint32(p.castTurn);
      buf.writeBytes(p.commitment); // 32 bytes, opaque
      buf.writeUint8(p.isPotent ? 1 : 0);
      buf.writeUint8(p.isVelocity ? 1 : 0);
    }

    final sortedLinks = (List<ReflectionLink>.from(reflectionLinks)
      ..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedLinks.length);
    for (final l in sortedLinks) {
      final lb = BytesBuilder();
      l.writeToBytes(lb);
      final bytes = lb.toBytes();
      buf.writeUint16(bytes.length);
      buf.writeBytes(bytes);
    }

    final sortedDivinationLinks = (List<DivinationLink>.from(divinationLinks)
      ..sort((a, b) => a.id.compareTo(b.id)));
    buf.writeUint16(sortedDivinationLinks.length);
    for (final l in sortedDivinationLinks) {
      final lb = BytesBuilder();
      l.writeToBytes(lb);
      final bytes = lb.toBytes();
      buf.writeUint16(bytes.length);
      buf.writeBytes(bytes);
    }

    // Wizard illusion decoy sets
    final sortedIllusions = (List<WizardIllusionSet>.from(wizardIllusions)
      ..sort((a, b) => a.ownerId.compareTo(b.ownerId)));
    buf.writeUint16(sortedIllusions.length);
    for (final s in sortedIllusions) {
      final sb = BytesBuilder();
      s.writeToBytes(sb);
      final bytes = sb.toBytes();
      buf.writeUint16(bytes.length);
      buf.writeBytes(bytes);
    }

    // Illusion terrain-copy tiles (destructible, 1 HP) + the conjurer's id
    // (read by the Earthen Scrying Pool dispel, so it is consensus state).
    final sortedIllusionTiles = illusionTerrainTiles.keys.toList()
      ..sort((a, b) {
        final qc = a.q.compareTo(b.q);
        return qc != 0 ? qc : a.r.compareTo(b.r);
      });
    buf.writeUint16(sortedIllusionTiles.length);
    for (final hex in sortedIllusionTiles) {
      buf.writeInt16(hex.q);
      buf.writeInt16(hex.r);
      buf.writeUtf8(illusionTerrainTiles[hex]!);
    }

    // ── Wild magic (docs/WILD_MAGIC_PLAN.md §7.4) ────────────────────────
    // Every field of WildMagicState is consensus state. Sort every collection:
    // Set<String> iteration is INSERTION order in Dart, so two clients that
    // added the same players in different orders would produce different bytes
    // from identical game state.
    buf.writeInt32(wildMagic.spellDamageBonusAmount);
    buf.writeInt32(wildMagic.spellDamageBonusTurn);

    // Each persistent effect carries its round window (Slice 4), so both
    // bounds are consensus state: they cross the per-turn state-hash exchange
    // in the round they are armed, and two devices holding the same players
    // with different expiries must not agree on a hash.
    //
    // Windows are written as their two INCLUSIVE bounds, in map-key order —
    // never insertion order. `pendingStatuesquePlayerIds` is gone: the window
    // expresses "not until next round" on its own.
    void writeWindows(Map<String, WildMagicWindow> windows) {
      final ids = windows.keys.toList()..sort();
      buf.writeUint16(ids.length);
      for (final id in ids) {
        buf.writeUtf8(id);
        buf.writeInt32(windows[id]!.activeFromTurn);
        buf.writeInt32(windows[id]!.expiresAfterTurn);
      }
    }

    writeWindows(wildMagic.phoenixWindows);
    writeWindows(wildMagic.statuesqueWindows);

    // Rippling Reflections: one shared window plus its drifting percentage.
    // The presence byte keeps a 0% counter distinguishable from "inactive".
    final ripplingWindow = wildMagic.ripplingWindow;
    buf.writeUint8(ripplingWindow == null ? 0 : 1);
    if (ripplingWindow != null) {
      buf.writeInt32(ripplingWindow.activeFromTurn);
      buf.writeInt32(ripplingWindow.expiresAfterTurn);
      buf.writeInt32(wildMagic.ripplingFizzlePct ?? 0);
    }

    // Scattered Gusts: per wizard, and the armed-from round matters — a Gust
    // armed this round must not be spendable by this round's casts.
    final gustIds = wildMagic.scatteredGustsArmedFrom.keys.toList()..sort();
    buf.writeUint16(gustIds.length);
    for (final id in gustIds) {
      buf.writeUtf8(id);
      buf.writeInt32(wildMagic.scatteredGustsArmedFrom[id]!);
    }

    final sortedExpiring = expiringTiles.entries.toList()
      ..sort((a, b) {
        final qc = a.key.q.compareTo(b.key.q);
        return qc != 0 ? qc : a.key.r.compareTo(b.key.r);
      });
    buf.writeUint16(sortedExpiring.length);
    for (final entry in sortedExpiring) {
      buf.writeInt16(entry.key.q);
      buf.writeInt16(entry.key.r);
      buf.writeInt32(entry.value);
    }

    // ── Terrain HP + barriers (docs/WALL_LOS_PLAN.md §7) ─────────────────
    // Terrain HP changes mid-turn, so it crosses the state-hash exchange
    // point within the turn it changes — the same hazard WILD_MAGIC_PLAN.md
    // A6 called out for pending latching state. Leaving either map out lets
    // two clients agree on a hash while holding different terrain.
    final sortedTerrainHp = terrainHp.entries.toList()
      ..sort((a, b) {
        final qc = a.key.q.compareTo(b.key.q);
        return qc != 0 ? qc : a.key.r.compareTo(b.key.r);
      });
    buf.writeUint16(sortedTerrainHp.length);
    for (final entry in sortedTerrainHp) {
      buf.writeInt16(entry.key.q);
      buf.writeInt16(entry.key.r);
      buf.writeInt32(entry.value);
    }

    // Nested map: sort the outer by (q, r) AND the inner by
    // SpellAffinity.index. An unsorted inner map is the easy way to produce a
    // mismatch that only shows up on a two-device run.
    final sortedTerrainBarriers = terrainBarriers.entries.toList()
      ..sort((a, b) {
        final qc = a.key.q.compareTo(b.key.q);
        return qc != 0 ? qc : a.key.r.compareTo(b.key.r);
      });
    buf.writeUint16(sortedTerrainBarriers.length);
    for (final entry in sortedTerrainBarriers) {
      buf.writeInt16(entry.key.q);
      buf.writeInt16(entry.key.r);
      final inner = entry.value.entries.toList()
        ..sort((x, y) => x.key.index.compareTo(y.key.index));
      buf.writeUint8(inner.length);
      for (final b in inner) {
        buf.writeUint8(b.key.index);
        buf.writeInt32(b.value.hp);
        buf.writeInt32(b.value.remainingTurns);
      }
    }

    return buf.toBytes();
  }

  /// Wire tags for the tile-effect variants. **Never renumber an existing
  /// tag** — a tag change silently reinterprets both clients' state bytes.
  /// Append new variants at the end.
  static int _tileEffectIndex(TileEffect e) => switch (e) {
        FloorIsLava() => 0,
        ImpassableTile() => 1,
        SlowTile() => 2,
        ConveyorTile() => 3,
        IceTile() => 4,
        ChasmTile() => 5,
      };

  static int _cloudKindIndex(CloudKind k) => switch (k) {
        ToxicCloud() => 0,
        DustCloud() => 1,
        WaterCloud() => 2,
        MobileCloud() => 3,
      };
}

// ── Minimal byte writer ───────────────────────────────────────────────────────

class _ByteWriter {
  final List<int> _bytes = [];

  void writeUint8(int v) => _bytes.add(v & 0xFF);

  void writeUint16(int v) {
    _bytes.add((v >> 8) & 0xFF);
    _bytes.add(v & 0xFF);
  }

  void writeUint32(int v) {
    _bytes.add((v >> 24) & 0xFF);
    _bytes.add((v >> 16) & 0xFF);
    _bytes.add((v >> 8) & 0xFF);
    _bytes.add(v & 0xFF);
  }

  void writeInt16(int v) {
    final u = v & 0xFFFF;
    _bytes.add((u >> 8) & 0xFF);
    _bytes.add(u & 0xFF);
  }

  void writeInt32(int v) {
    final u = v & 0xFFFFFFFF;
    _bytes.add((u >> 24) & 0xFF);
    _bytes.add((u >> 16) & 0xFF);
    _bytes.add((u >> 8) & 0xFF);
    _bytes.add(u & 0xFF);
  }

  void writeUtf8(String s) {
    final encoded = utf8.encode(s);
    writeUint16(encoded.length);
    _bytes.addAll(encoded);
  }

  void writeBytes(Uint8List bytes) => _bytes.addAll(bytes);

  void writeHex(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    for (var i = 0; i < s.length; i += 2) {
      _bytes.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}
