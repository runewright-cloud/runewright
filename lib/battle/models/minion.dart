// SPDX-License-Identifier: GPL-3.0-or-later
//
// minion.dart — Minion: a summoned creature (design doc v3.0 "Summons").
//
// Replaces the earlier Sprite/Hound (v2.4) model: a single concrete
// creature class whose identity is fully derived from the inscribing
// spell's element sequence via CreatureSpec.fromElements (creature_spec.dart)
// — affinity, stats, and abilities — plus a personality assigned separately
// (glyph-assigned per design; no UI this pass, see SpellAsset.summonPersonality).
//
// Summon open TODOs (design doc "Summons", all [TODO — playtest]):
//   - Lifespan: indefinite (no expiry turn) until destroyed.
//   - Cap: none for now.
//   - AoE friendly fire: possible (affects caster's own summons).

import 'dart:math' show min;

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/creature_spec.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance, hexNeighbors;
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/summon_lexicon.dart' show SummonLexicon;
import 'package:rune_duel/battle/models/wizard_avatar.dart' show StatusEffect;

export 'creature_spec.dart' show MinionStats, SummonAbility;

// ── Personality ───────────────────────────────────────────────────────────────

/// Battlefield behavior assigned to a summon (design doc "Personalities").
/// Glyph-assigned at inscription time in the design; no picker UI exists yet
/// this pass — [SpellAsset.summonPersonality] defaults to [aggressive].
enum SummonPersonality {
  /// "Move on path most directly to nearest enemy... not particularly
  /// intelligent." The v2.4 hound's behavior generalized to all creatures.
  aggressive,

  /// "Try to put themselves at a distance from all enemies while still being
  /// in attack range of at least one. Prefer targeting players in ties."
  evasive,

  /// "Prioritize trying to insert themselves between their summoner and
  /// other hostile entities."
  protective,

  /// "Prioritize trying to slay targets with the fewest hitpoints. Factoring
  /// in resistances and vulnerabilities."
  tactical,

  /// Lets the summoner manually dictate this creature's move and attack
  /// during the Summons phase instead of following an AI personality, or
  /// let it default to [aggressive] behaviour when not directed.
  ///
  /// Seam only this pass: no picker UI or live manual-control path exists
  /// yet — TurnLoop._creatureTurn falls through to aggressive for every
  /// obedient creature. Wiring up real player control requires moving the
  /// Summons phase ahead of the B-5 entropy reveal (a protocol change), so
  /// it's deliberately deferred — see battle_screen.dart's phase banner.
  obedient,
}

/// Friendly display names for [SummonPersonality] -- for the inscription-time
/// picker (design doc: "glyphs may be added to force a particular
/// personality"). Lives here rather than creature_spec.dart to avoid an
/// import cycle (this file already imports creature_spec.dart).
const Map<SummonPersonality, String> kSummonPersonalityLabel = {
  SummonPersonality.aggressive: 'Aggressive',
  SummonPersonality.evasive: 'Evasive',
  SummonPersonality.protective: 'Protective',
  SummonPersonality.tactical: 'Tactical',
  SummonPersonality.obedient: 'Obedient',
};

// ── Footprint geometry (size ladder) ──────────────────────────────────────────

/// The tiles a creature occupies when centered at [center], as a function of
/// its size rung on the ladder **[1 tile → 3-tile triangle → 7-tile hex]**:
///
///   rung 0 → `[center]` (single tile)
///   rung 1 → `[center]` + its first two neighbors: a deterministic 3-tile
///            triangle (consecutive hex directions are 60° apart, so those two
///            neighbors are mutually adjacent — a true triangle). This is the
///            `big` (EEEE) creature's natural size.
///   rung 2 → the full radius-1 hex: `[center]` + all six neighbors (7 tiles),
///            the largest possible size.
///
/// The rung is `min((big ? 1 : 0) + sizeBonus, 2)`, so a Rod of Wind
/// ([sizeBonus] = 1) pushes a normal creature to the triangle and an already-Big
/// one to the full hex, capped at 7 tiles (design v3.0 §Artifacts).
List<HexCoord> footprintFor(
  HexCoord center,
  Set<SummonAbility> abilities, [
  int sizeBonus = 0,
]) {
  final rung = ((abilities.contains(SummonAbility.big) ? 1 : 0) + sizeBonus).clamp(0, 2);
  if (rung == 0) return [center];
  final ns = hexNeighbors(center);
  if (rung == 1) return [center, ns[0], ns[1]];
  return [center, ...ns];
}

// ── Minion ────────────────────────────────────────────────────────────────────

class Minion {
  Minion({
    required this.id,
    required this.ownerId,
    required this.teamId,
    required this.position,
    required this.affinity,
    required this.stats,
    required this.elementSequence,
    Set<SummonAbility>? abilities,
    this.personality = SummonPersonality.aggressive,
    int? hp,
    List<StatusEffect>? activeStatusEffects,
    Map<SpellAffinity, BarrierState>? barriers,
    this.actedThisTurn = false,
    this.forceCloseToAttack = false,
    this.isIllusion = false,
    this.sizeBonus = 0,
    this.copiedFromMinionId,
  })  : abilities = abilities ?? const {},
        hp = hp ?? stats.maxHp,
        activeStatusEffects = activeStatusEffects ?? [],
        barriers = barriers ?? {};

  final String id;
  final String ownerId;
  final String teamId;
  HexCoord position;

  /// Elemental affinity — the most-common element in [elementSequence]
  /// (first-appearance tiebreak). Drives the token colour, the damage type
  /// this creature deals, and its own resistance-wheel weakness/resistance.
  final SpellAffinity affinity;

  final MinionStats stats;

  /// Set once at creation from [CreatureSpec.abilities]; see SummonAbility.
  final Set<SummonAbility> abilities;

  /// The full element activation sequence this creature was derived from —
  /// retained (not just the derived spec) so Morphic (WWWW) can re-derive a
  /// smaller creature from a random half of it on death.
  final List<BorderZone> elementSequence;

  SummonPersonality personality;

  int hp;
  bool actedThisTurn;

  /// Water-Air Illusions (Fire flavor): an illusory clone that always closes
  /// to attack rather than following its personality's normal positioning
  /// (e.g. an Evasive original's kiting is skipped for its clone).
  final bool forceCloseToAttack;

  /// This creature is an illusion — either conjured as one (Illusions'
  /// Fire-flavor 1 HP clone) or turned into one (the Air flavor's
  /// convertToIllusion, hence non-final). Gameplay-relevant, unlike the
  /// presentational [copiedFromMinionId]: an Earthen Scrying Pool bearer
  /// dispels an adjacent enemy illusion on sight (EffectApplicator
  /// .dispelIllusionsNearScryers), so this is consensus state and is hashed
  /// in [BattleState.toCanonicalBytes].
  bool isIllusion;

  final List<StatusEffect> activeStatusEffects;
  final Map<SpellAffinity, BarrierState> barriers;

  /// Extra size rungs granted at summon time by a Rod of Wind (0 or 1).
  /// Folds into the footprint ladder in [footprintFor]; see [occupiedTiles].
  final int sizeBonus;

  /// Set when this creature was conjured as a copy of another rather than by
  /// a direct summon cast — Reflections' summonMirror (turn_loop.dart) and
  /// Illusions' Fire-flavor minion clone (effect_applicator.dart). Holds the
  /// id of the ORIGINAL cast creature, not the immediate source, so a copy of
  /// a copy still resolves in one hop.
  ///
  /// Purely presentational: a copy has no cast of its own, so this is how the
  /// UI finds the SpellAsset whose art it should wear (battle_screen.dart's
  /// _MinionArtOverlay / long-press card, both of which render it phantasmal
  /// blue to distinguish it from the original). Nothing in the engine reads
  /// it, and it must stay that way — it is not a gameplay-relevant link, and
  /// the original may be dead and reaped while the copy lives on.
  final String? copiedFromMinionId;

  bool get isAlive => hp > 0;

  /// Tiles this creature occupies. See [footprintFor].
  List<HexCoord> get occupiedTiles => footprintFor(position, abilities, sizeBonus);

  /// Minimum hex distance from any of this creature's occupied tiles to [point].
  int distanceTo(HexCoord point) =>
      occupiedTiles.map((t) => hexDistance(t, point)).reduce(min);

  /// Applies the elemental resistance wheel (if [attackType] is given), then
  /// absorbs through active barriers, then real HP.
  void takeDamage(int amount, {SpellAffinity? attackType}) {
    var remaining =
        attackType != null ? applyResistance(amount, attackType, affinity) : amount;
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null || !b.isAlive || remaining <= 0) continue;
      remaining = b.absorb(remaining);
      if (!b.isAlive) barriers.remove(element);
    }
    if (remaining > 0) hp = (hp - remaining).clamp(0, stats.maxHp);
  }

  int get effectiveMoveSpeed {
    var speed = stats.moveSpeed;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.speedUp ||
          fx.effectTypeId == StatusEffectId.speedDown) {
        speed += fx.modifiers['speedDelta'] ?? 0;
      }
    }
    return speed.clamp(0, 999);
  }

  /// Reach, in tiles, from any tile of this creature's footprint.
  ///
  /// **Zero is a real value, not a floor to be clamped away.** `attackRange`
  /// is `waterCount ~/ 3` (creature_spec.dart), so most creatures have none at
  /// all: they are melee, and melee means standing on what you are hitting.
  /// TurnLoop._creatureTurn spends a movement point to step such a creature
  /// into its target's tile and shoves it straight back out again — bodies are
  /// exclusive, so the blow and the recoil are the same beat. Clamping this to
  /// 1 (as it used to be) quietly turned every melee creature into a
  /// reach-1 skirmisher that could strike for free from an adjacent tile.
  int get effectiveAttackRange {
    var range = stats.attackRange;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.rangeUp ||
          fx.effectTypeId == StatusEffectId.rangeDown) {
        range += fx.modifiers['rangeDelta'] ?? 0;
      }
    }
    return range.clamp(0, 999);
  }

  /// Morphic (WWWW): on death, reforms into a new creature derived from half
  /// (rounded down) of [elementSequence], chosen at random via [nextInt]
  /// (pass a seeded HashRng.nextInt so both battle clients reform
  /// identically). Returns an empty list if this creature isn't Morphic, or
  /// if the halved sequence would be empty (nothing coalesces).
  ///
  /// The reformed creature spawns on this creature's own tile (or its
  /// footprint's first tile) with a fresh id built from [newId].
  /// [lexicon] is the match's summon reading — the reformed creature's
  /// abilities are derived from the REDUCED sequence under the same leyline the
  /// original was summoned under (audit R-8). Defaulted to the ordinary lexicon
  /// so out-of-match callers and fixtures read as they always have; in-match,
  /// `DeterministicResolution` passes its own.
  List<Minion> onDeath(
    int Function(int max) nextInt,
    String newId, {
    SummonLexicon lexicon = SummonLexicon.ordinary,
  }) {
    if (!abilities.contains(SummonAbility.morphic)) return const [];
    final reduced = morphicReducedSequence(elementSequence, nextInt);
    if (reduced == null) return const [];
    final spec = lexicon.specOf(reduced);
    if (spec == null) return const [];
    return [
      Minion(
        id: newId,
        ownerId: ownerId,
        teamId: teamId,
        position: occupiedTiles.first,
        affinity: spec.affinity,
        stats: spec.stats,
        elementSequence: reduced,
        abilities: spec.abilities,
        personality: personality,
      ),
    ];
  }
}
