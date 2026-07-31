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

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/terrain.dart'
    show CloudObject, TileEffect, CloudKind,
         ToxicCloud, DustCloud, WaterCloud, MobileCloud,
         FloorIsLava, ImpassableTile, SlowTile, ConveyorTile,
         IceTile, ChasmTile;

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
    Set<HexCoord>? illusionTerrainTiles,
    Map<HexCoord, int>? expiringTiles,
    WildMagicState? wildMagic,
  })  : minions = minions ?? [],
        expiringTiles = expiringTiles ?? {},
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
  /// (see EffectApplicator._applyDamage).
  final Set<HexCoord> illusionTerrainTiles;

  /// Temporary tile effects: coord → the LAST turn number the effect is active
  /// (swept at the end of that turn, in Phase 6). The mechanism for the
  /// wild-magic terrain effects — Mountains (2[3] turns), Chasm, Glacier —
  /// every TileEffect predating wild magic is permanent and needed no such
  /// thing. An entry here is always paired with a [tileEffects] entry on the
  /// same coord; sweeping removes both.
  final Map<HexCoord, int> expiringTiles;

  /// Match-scoped wild-magic globals (Burning Hot's armed turn, Phoenix /
  /// Statuesque player sets, Rippling Reflections' drift, Scattered Gusts).
  /// All of it is consensus state — see [toCanonicalBytes].
  final WildMagicState wildMagic;

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

      final sortedAcc = (List<Accoutrement>.from(a.accoutrements)
            ..sort((x, y) => x.id.compareTo(y.id)));
      buf.writeUint16(sortedAcc.length);
      for (final acc in sortedAcc) {
        buf.writeUtf8(acc.id);
        buf.writeUint8(acc.kind.index);
        buf.writeUint8(acc.counterCharmRevealed ? 1 : 0);
        final target = acc.targetCommitmentHex;
        if (target != null) {
          buf.writeUint8(1);
          buf.writeHex(target);
        } else {
          buf.writeUint8(0);
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
    // position + abilities + sizeBonus (the Rod of Spreading size rung), so
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
      buf.writeUint8(p.isRodOfSpreading ? 1 : 0);
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

    // Illusion terrain-copy tiles (destructible, 1 HP)
    final sortedIllusionTiles = illusionTerrainTiles.toList()
      ..sort((a, b) {
        final qc = a.q.compareTo(b.q);
        return qc != 0 ? qc : a.r.compareTo(b.r);
      });
    buf.writeUint16(sortedIllusionTiles.length);
    for (final hex in sortedIllusionTiles) {
      buf.writeInt16(hex.q);
      buf.writeInt16(hex.r);
    }

    // ── Wild magic (docs/WILD_MAGIC_PLAN.md §7.4) ────────────────────────
    // Every field of WildMagicState is consensus state. Sort every collection:
    // Set<String> iteration is INSERTION order in Dart, so two clients that
    // added the same players in different orders would produce different bytes
    // from identical game state.
    buf.writeInt32(wildMagic.spellDamageBonusAmount);
    buf.writeInt32(wildMagic.spellDamageBonusTurn);

    final sortedPhoenix = wildMagic.phoenixPlayerIds.toList()..sort();
    buf.writeUint16(sortedPhoenix.length);
    for (final id in sortedPhoenix) {
      buf.writeUtf8(id);
    }

    final sortedStatuesque = wildMagic.statuesquePlayerIds.toList()..sort();
    buf.writeUint16(sortedStatuesque.length);
    for (final id in sortedStatuesque) {
      buf.writeUtf8(id);
    }

    // Pending (armed this turn, latching at end of turn — A6). Encoded too:
    // it survives across the state-hash exchange point within the turn it is
    // set, so leaving it out would let two clients agree on a hash while
    // holding different pending sets.
    final sortedPendingStatuesque = wildMagic.pendingStatuesquePlayerIds.toList()
      ..sort();
    buf.writeUint16(sortedPendingStatuesque.length);
    for (final id in sortedPendingStatuesque) {
      buf.writeUtf8(id);
    }

    final fizzlePct = wildMagic.ripplingFizzlePct;
    buf.writeUint8(fizzlePct == null ? 0 : 1);
    if (fizzlePct != null) buf.writeInt32(fizzlePct);

    buf.writeUint8(wildMagic.scatteredGusts ? 1 : 0);

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
