// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_armor.dart — the seam where a ChapterAsset's armor binding meets the
// SpellAsset it points at.
//
// [ChapterAsset] stores only [ChapterAsset.armorSpellId], so it cannot answer
// "does this fit?" on its own: the cost is `ceil(T/4)` and T lives on the
// spell. Rather than give the chapter model a global dependency on the spell
// repository, the two are joined here — the narrowest place that already has
// both — and the chapter keeps a flat, ID-only persisted shape.
//
// For the same reason this file also owns [resolveEquippedArmor], the one
// place that turns [ChapterAsset.armorSpellId] back into the [SpellAsset] it
// names. It lived privately in `duel_setup.dart` until solo/practice needed
// the identical lookup; a second copy is exactly how the two surfaces would
// drift into disagreeing about what "equipped" means, so there is one.
//
// ## Trust
//
// Everything in this file reads [SpellAsset.t], a LOCAL persisted field that
// no proof binds. That is deliberate and it is enough for what this file does:
// decide what the player may equip and save on their own device. It is NOT
// network semantics. Duel setup will recompute the authoritative slot cost
// from [CertifiedArmor.fromOutputs] over the proof's public outputs, and must
// never accept a peer's stored T, a peer's `isArmor` marker, or a cached slot
// cost — which is why no slot cost is persisted anywhere. Both readings share
// [armorSlotCostForT] so only the source of T can differ, never the formula.

import '../battle/models/certified_armor.dart' show armorSlotCostForT;

import 'chapter_asset.dart';
import 'spell_asset.dart';

/// Why an armor could not be bound to a chapter. Null return values mean
/// "accepted"; see [armorBindError].
enum ArmorBindError {
  /// The asset is not marked [SpellAsset.isArmor] — an ordinary spell or a
  /// summon cannot be worn.
  notAnArmor,

  /// The armor's `ceil(T/4)` slots plus the chapter's ordinary artifacts would
  /// exceed [ChapterAsset.maxArtifactSlots].
  exceedsSlotBudget,
}

/// Artifact slots [armor] occupies locally: `ceil(T/4)` from its persisted T.
///
/// Named "local" as a standing reminder that this is the editor/accounting
/// reading, not the certified one. See the file header.
int localArmorSlotCost(SpellAsset armor) => armorSlotCostForT(armor.t);

/// The slot cost of [chapter]'s bound armor, given the [armor] asset it
/// resolves to. Zero when the chapter wears none, and zero when the binding
/// could not be resolved to a spell (a dangling reference — normally
/// impossible, since [ChapterAsset.removeSpellFromAllChapters] clears the
/// binding when the armor is deleted).
int chapterArmorSlotCost(ChapterAsset chapter, SpellAsset? armor) {
  if (!chapter.hasArmor || armor == null) return 0;
  return localArmorSlotCost(armor);
}

/// Slots [chapter] uses, resolving its armor binding through [armor].
int chapterSlotsUsed(ChapterAsset chapter, SpellAsset? armor) =>
    chapter.artifactSlotsUsed(armorSlotCost: chapterArmorSlotCost(chapter, armor));

/// Slots [chapter] has left, resolving its armor binding through [armor].
int chapterSlotsRemaining(ChapterAsset chapter, SpellAsset? armor) =>
    chapter.artifactSlotsRemaining(
        armorSlotCost: chapterArmorSlotCost(chapter, armor));

/// Why [armor] cannot be bound to [chapter], or null if it can.
///
/// Binding replaces any armor already worn, so the outgoing armor's slots are
/// released before the incoming one is measured — a chapter at its limit can
/// always swap in a cheaper armor. Only ordinary artifacts constrain the fit.
ArmorBindError? armorBindError(ChapterAsset chapter, SpellAsset armor) {
  if (!armor.isArmor) return ArmorBindError.notAnArmor;
  if (chapter.ordinaryArtifactCount + localArmorSlotCost(armor) >
      ChapterAsset.maxArtifactSlots) {
    return ArmorBindError.exceedsSlotBudget;
  }
  return null;
}

/// Binds [armor] to [chapter], or returns null if [armorBindError] rejects it.
///
/// Nothing here verifies the proof: editing a local chapter must not cost a
/// verification. The authoritative check happens at duel setup.
ChapterAsset? bindArmor(ChapterAsset chapter, SpellAsset armor) =>
    armorBindError(chapter, armor) == null ? chapter.withArmor(armor.id) : null;

/// Removes [chapter]'s armor, freeing its slots immediately.
ChapterAsset unbindArmor(ChapterAsset chapter) => chapter.withoutArmor();

/// Adds one ordinary [artifact] to [chapter] if a slot is free once the armor
/// resolved by [armor] is accounted for; returns null if the chapter is full.
///
/// [ChapterAsset.withArtifact] itself stays unchecked (it is also the load and
/// migration path); this is the checked front door for the editor, and the
/// reason armor cannot be bypassed by adding artifacts after equipping it.
ChapterAsset? addArtifactWithinBudget(
  ChapterAsset chapter,
  ArtifactEntry artifact, {
  required SpellAsset? armor,
}) {
  if (chapterSlotsRemaining(chapter, armor) <= 0) return null;
  return chapter.withArtifact(artifact);
}

// ── Resolving the binding ─────────────────────────────────────────────────────

/// The [SpellAsset] this chapter equips as armor, or null if it equips none.
///
/// Resolves exactly [ChapterAsset.armorSpellId] — the local binding — and
/// nothing else. A binding that no longer resolves is a hard error rather than
/// a silent "no armor": the player believes they are wearing something, and
/// starting a battle without it would be a surprise mid-match, not a
/// convenience. (Deleting an armor clears the binding from every chapter, so
/// this should be unreachable outside hand-edited data.)
///
/// THE shared implementation. Duel setup (step 7b) and solo/practice setup
/// both call this one function, so "which spell am I wearing?" cannot be
/// answered two ways. It resolves the binding and stops: nothing here reads
/// [SpellAsset.isArmor] or any other authored field as gameplay truth —
/// `certifyOwnArmor` is what decides what the armor MEANS, from its proof.
Future<SpellAsset?> resolveEquippedArmor(ChapterAsset chapter) async {
  final id = chapter.armorSpellId;
  if (id == null) return null;
  final all = await SpellAsset.loadAll();
  for (final s in all) {
    if (s.id == id) return s;
  }
  throw StateError(
    'chapter "${chapter.name}" equips armor $id, which is no longer in the '
    'library — match aborted',
  );
}
