// SPDX-License-Identifier: GPL-3.0-or-later
//
// certified_armor.dart — CertifiedArmor: the complete semantics of an
// Aetherial Armor, derived solely from a spell proof's public outputs.
//
// ## Why this type exists
//
// An Aetherial Armor is an inscribed spell worn rather than cast: its CA
// trajectory is what the armor *is*. Everything a wearer gets from it — how
// many armor slots it occupies, its stat bonuses, its keywords — is therefore
// a pure function of [VerifiedSpellOutputs], the SNARK-certified side of a
// SpellAsset.
//
// The same trust-boundary rule that produced [CertifiedCast] applies here, for
// the same reason: `SpellAsset.formula`, `manaCost`, `supremeTags`, and every
// cached armor field are plain wire values that nothing binds to the proof. A
// modified client can write anything into them. So nothing in this file reads
// a SpellAsset at all — [CertifiedArmor.fromOutputs] takes the outputs and
// nothing else, and it is the ONE derivation both the local (`parseOwn`) and
// the peer (`verifyAndParse`) paths are expected to call. One proof, one
// meaning (M4.22).
//
// ## Semantics
//
// The armor reads the certified dominance trajectory as
// [TrajectoryParser.certifiedPerGenerationDominantSequence]: at most one element per
// generation, neutral generations contribute nothing, repeats count, and only
// generations `0 .. T-1` are considered. Note this is the *raw* dominance
// sequence, not [TrajectoryParser.certifiedElementSequence] — armor scores how
// long an element actually held the lead, where a formula scores lead changes
// and pulses. See that method's doc for why both readings are legitimate
// views of one array.
//
// This layer is pure: no I/O, no Flutter, no networking, no BattleState.

import 'package:rune_duel/engine/border_zone.dart';

import '../engine/proof_outputs.dart' show VerifiedSpellOutputs;
import '../engine/trajectory_parser.dart' show TrajectoryParser;

// ── Keywords ──────────────────────────────────────────────────────────────────

/// A property an armor grants when its four-element pattern appears anywhere
/// in the certified dominance sequence.
///
/// Patterns are contiguous substrings of that sequence. Elements may be reused
/// between keywords and matches may overlap, but each keyword is granted at
/// most once no matter how many times its pattern occurs.
enum ArmorKeyword {
  /// AAAA
  flying,

  /// FFFF
  cleave,

  /// FAFA
  charger,

  /// WEWE
  muddy,

  /// EFEF
  moltenCarapace,

  /// AWAW
  stealthy,

  /// EEEE
  anchored,
}

/// The certified pattern for each keyword, as a contiguous element run.
//
// Morphic (WWWW) is deliberately absent — it is designed but not implemented,
// so a WWWW armor grants no keyword rather than a placeholder one.
const Map<ArmorKeyword, List<BorderZone>> armorKeywordPatterns = {
  ArmorKeyword.flying: [
    BorderZone.air, BorderZone.air, BorderZone.air, BorderZone.air,
  ],
  ArmorKeyword.cleave: [
    BorderZone.fire, BorderZone.fire, BorderZone.fire, BorderZone.fire,
  ],
  ArmorKeyword.charger: [
    BorderZone.fire, BorderZone.air, BorderZone.fire, BorderZone.air,
  ],
  ArmorKeyword.muddy: [
    BorderZone.water, BorderZone.earth, BorderZone.water, BorderZone.earth,
  ],
  ArmorKeyword.moltenCarapace: [
    BorderZone.earth, BorderZone.fire, BorderZone.earth, BorderZone.fire,
  ],
  ArmorKeyword.stealthy: [
    BorderZone.air, BorderZone.water, BorderZone.air, BorderZone.water,
  ],
  ArmorKeyword.anchored: [
    BorderZone.earth, BorderZone.earth, BorderZone.earth, BorderZone.earth,
  ],
};

// ── Bonus ladders ─────────────────────────────────────────────────────────────

/// Fire / Air / Water share one ladder: `count → bonus`, highest reached wins.
const List<({int count, int bonus})> armorElementLadder = [
  (count: 4, bonus: 1),
  (count: 10, bonus: 2),
  (count: 18, bonus: 3),
  (count: 28, bonus: 4),
  (count: 40, bonus: 5),
];

/// Earth has its own ladder, denominated in max-HP rather than in a stat step.
const List<({int count, int bonus})> armorEarthLadder = [
  (count: 2, bonus: 2),
  (count: 6, bonus: 5),
  (count: 12, bonus: 8),
  (count: 20, bonus: 11),
  (count: 30, bonus: 14),
  (count: 42, bonus: 17),
];

/// The highest rung of [ladder] whose threshold [count] has reached; 0 if none.
int armorLadderBonus(int count, List<({int count, int bonus})> ladder) {
  var bonus = 0;
  for (final rung in ladder) {
    if (count >= rung.count) bonus = rung.bonus;
  }
  return bonus;
}

// ── Slot cost ─────────────────────────────────────────────────────────────────

/// Artifact slots an armor of [t] generations occupies: `ceil(T / 4)`, so 1 for
/// T 1–4 through 12 for T 45–48. No diminishing returns.
///
/// THE one implementation of this formula. [CertifiedArmor.slotCost] is this
/// applied to a proof's certified T — the only authoritative reading. The local
/// chapter editor applies it to the T stored on a [SpellAsset] instead
/// (lib/spells/chapter_armor.dart), which is fine for deciding what the player
/// may save on their own device and must never be treated as network semantics:
/// duel setup recomputes from [CertifiedArmor.fromOutputs]. Both go through
/// here so the two readings can never disagree about the arithmetic, only about
/// where T came from.
int armorSlotCostForT(int t) => (t + 3) ~/ 4;

// ── The armor ─────────────────────────────────────────────────────────────────

/// The proof-attested semantics of one Aetherial Armor.
///
/// Immutable and derived once, at the point of verification; see the file
/// header for why it must never be reconstructed from authored wire fields.
class CertifiedArmor {
  const CertifiedArmor({
    required this.t,
    required this.slotCost,
    required this.fireCount,
    required this.airCount,
    required this.waterCount,
    required this.earthCount,
    required this.meleeBonus,
    required this.moveSpeedBonus,
    required this.spellRangeBonus,
    required this.armorHpBonus,
    required this.keywords,
    required this.elementSequence,
  });

  /// Derive the complete armor semantics from a verified proof's outputs.
  ///
  /// This is the single AUTHORITATIVE derivation. Local and peer paths both
  /// call it, so an armor cannot mean one thing on the wearer's device and
  /// another on the opponent's.
  factory CertifiedArmor.fromOutputs(VerifiedSpellOutputs outputs) =>
      CertifiedArmor.previewFromElementSequence(
        TrajectoryParser.certifiedPerGenerationDominantSequence(outputs),
        t: outputs.t,
      );

  /// PREVIEW ONLY — the same rules applied to a per-generation dominant
  /// [sequence] supplied directly, for the ONE case where no proof exists yet:
  /// the Rune Craft editor's live "what will this inscribe as" strip, which
  /// reads the dominance the stepper is producing right now (exactly as
  /// `_SummonPreview` previews `CreatureSpec.fromElements` live).
  ///
  /// **Nothing in battle, setup, or networking may call this.** The name says
  /// `preview` because the returned object is a `CertifiedArmor` that nothing
  /// certified: hand it untrusted element data and it will compute confident
  /// stats for an armor no proof stands behind. [fromOutputs] is the only
  /// production path from proof data to battle-usable semantics, and routing a
  /// persisted or peer asset through here would resurrect exactly the
  /// local-vs-certified split M4.22 closed.
  ///
  /// Both paths share every rule below; only the source of the sequence
  /// differs. That sharing is the point — the editor must preview the same
  /// arithmetic the duel will enforce.
  factory CertifiedArmor.previewFromElementSequence(
    List<BorderZone> sequence, {
    required int t,
  }) {
    var fire = 0, air = 0, water = 0, earth = 0;
    for (final zone in sequence) {
      switch (zone) {
        case BorderZone.fire:
          fire++;
        case BorderZone.air:
          air++;
        case BorderZone.water:
          water++;
        case BorderZone.earth:
          earth++;
      }
    }

    final keywords = <ArmorKeyword>{};
    for (final entry in armorKeywordPatterns.entries) {
      if (_containsRun(sequence, entry.value)) keywords.add(entry.key);
    }

    return CertifiedArmor(
      t: t,
      slotCost: armorSlotCostForT(t),
      fireCount: fire,
      airCount: air,
      waterCount: water,
      earthCount: earth,
      meleeBonus: armorLadderBonus(fire, armorElementLadder),
      moveSpeedBonus: armorLadderBonus(air, armorElementLadder),
      spellRangeBonus: armorLadderBonus(water, armorElementLadder),
      armorHpBonus: armorLadderBonus(earth, armorEarthLadder),
      keywords: Set.unmodifiable(keywords),
      elementSequence: List.unmodifiable(sequence),
    );
  }

  /// Generations this armor was inscribed for. Carried because [slotCost] is
  /// a lossy function of it (four T values share each cost) and a read-out
  /// wants to show both -- never re-derive T from [slotCost] or from
  /// [elementSequence], which drops neutral generations.
  final int t;

  /// Armor slots this armor occupies: `ceil(T / 4)`, so 1 for T 1–4 through 12
  /// for T 45–48.
  final int slotCost;

  /// Certified occurrences of each element in [elementSequence].
  final int fireCount;
  final int airCount;
  final int waterCount;
  final int earthCount;

  /// Fire's ladder result — a melee bonus.
  final int meleeBonus;

  /// Air's ladder result — a move-speed bonus.
  final int moveSpeedBonus;

  /// Water's ladder result — a spell-range bonus.
  final int spellRangeBonus;

  /// Earth's ladder result, held separately from any innate max-HP so a later
  /// armor-breaking mechanic can strip exactly the HP the armor granted.
  final int armorHpBonus;

  /// Keywords granted, each at most once. See [armorKeywordPatterns].
  final Set<ArmorKeyword> keywords;

  /// The certified dominance sequence this armor was derived from, kept for
  /// display and for debugging a disagreement between devices.
  final List<BorderZone> elementSequence;

  bool hasKeyword(ArmorKeyword keyword) => keywords.contains(keyword);

  @override
  String toString() => 'CertifiedArmor(T $t, slots: $slotCost, '
      'F$fireCount A$airCount W$waterCount E$earthCount, '
      'melee +$meleeBonus, move +$moveSpeedBonus, range +$spellRangeBonus, '
      'armor HP +$armorHpBonus, keywords: ${keywords.map((k) => k.name).join(', ')})';
}

/// Whether [pattern] occurs as a contiguous run anywhere in [sequence].
bool _containsRun(List<BorderZone> sequence, List<BorderZone> pattern) {
  for (var start = 0; start + pattern.length <= sequence.length; start++) {
    var matched = true;
    for (var i = 0; i < pattern.length; i++) {
      if (sequence[start + i] != pattern[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}
