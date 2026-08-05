// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_slot.dart — VocalSlot: the six incantation SLOTS.
//
// A slot is an identity, not a word. Which word fills it is the player's
// choice and lives in VocabularyProfile (vocabulary_profile.dart), local to
// one device. This split is the whole of VOCAL_RECALL_PLAN.md §8: the
// incantation becomes an enciphered telegraph an opponent must learn per
// player, rather than a fixed Latin phrase everyone can read.
//
// Replaces the old `VocalWord{ignis, ventus, aqua, terra, finitus}`, which
// named slots after specific Latin words — actively misleading once a player
// says "blaze" for fire.
//
// INVARIANT (§8.10.1): only a slot INDEX ever crosses the wire, never the
// word filling it. A vocabulary never leaves the device that chose it. The
// peer scores a recall claim by comparing indices against the expected
// sequence it derives from the certified trajectory — it never needs, and
// must never receive, the caster's labels.
//
// `finitus` is gone. VOCAL_RECALL_PLAN.md §8.4: its only description was a
// comment, no chain-cast or dismissal code referenced it, and capture is
// window-delimited rather than terminator-delimited, so nothing depended on
// it. The opener subsumes its only real job and does it better — a listener
// needs STARTS marked, not ends.

/// The six incantation slots: four elements plus a two-valued opener.
///
/// Cast shape is `OPENER + 3n element words` (§8.1). The opener is one slot
/// with two possible values, not two stacked words, so a summon cast is not
/// one word longer than an incantation and the distinction lands on the very
/// first syllable — where it is most audible.
enum VocalSlot {
  fire,
  air,
  water,
  earth,
  openerGeneral,
  openerSummon;

  /// The four element slots, in wire-index order. Matches the element order
  /// the stepper is canonical for (CLAUDE.md: `[0=neutral, 1=fire, 2=air,
  /// 3=water, 4=earth]`, minus neutral, which is never spoken).
  static const List<VocalSlot> elements = [fire, air, water, earth];

  /// The two opener values.
  static const List<VocalSlot> openers = [openerGeneral, openerSummon];

  bool get isElement => index < 4;
  bool get isOpener => index >= 4;

  /// Maps a spell's affinity zone name (`SpellAsset.formula` entries; one of
  /// 'fire'/'air'/'water'/'earth', see spell_asset.dart) to the element slot
  /// the caster must speak. Returns null for an unrecognised or empty name.
  static VocalSlot? fromAffinityZone(String zone) =>
      switch (zone.toLowerCase()) {
        'fire' => VocalSlot.fire,
        'air' => VocalSlot.air,
        'water' => VocalSlot.water,
        'earth' => VocalSlot.earth,
        _ => null,
      };

  /// The opener a cast of this kind expects.
  ///
  /// [isSummon] is `SpellAsset.isSummon`, which is already consensus-visible
  /// — TurnLoop._updateChainState branches on it to compute chain affinity on
  /// both devices, so they must already agree or chains would desync. That is
  /// what lets the peer verify an opener claim without trusting the caster
  /// (§8.6).
  static VocalSlot openerFor({required bool isSummon}) =>
      isSummon ? openerSummon : openerGeneral;

  /// Persistence/asset filename key. Enrollment takes are stored at
  /// `<docs>/practice_enrollment/<key>.json` and bundled Piper templates at
  /// `assets/practice_templates/<key>.json`.
  String get storageKey => name;

  /// The shipped default word for this slot, before any player choice.
  ///
  /// Lives here rather than on VocabularyProfile so that Flutter-free code —
  /// notably scripts/generate_practice_assets.dart, which renders the
  /// bundled Piper templates and cannot import path_provider — can reach it.
  /// VocabularyProfile layers the player's overrides on top.
  ///
  /// The four elements are settled (VOCAL_RECALL_PLAN.md §8.1). The openers
  /// were chosen 2026-08-04, closing §8.11's first open item.
  String get defaultWord => switch (this) {
        VocalSlot.fire => 'ignis',
        VocalSlot.air => 'ventus',
        VocalSlot.water => 'aqua',
        VocalSlot.earth => 'terra',
        VocalSlot.openerGeneral => 'reformare',
        VocalSlot.openerSummon => 'invoco',
      };

  /// Pre-§8 enrollment/template filenames, for reading recordings made before
  /// slots existed. Read path only — nothing is ever written under these.
  /// `finitus` is deliberately absent: that slot is gone, and any take
  /// recorded for it is dropped rather than migrated.
  static const Map<String, VocalSlot> legacyStorageKeys = {
    'ignis': VocalSlot.fire,
    'ventus': VocalSlot.air,
    'aqua': VocalSlot.water,
    'terra': VocalSlot.earth,
  };

  /// Resolves a persisted filename key to a slot, accepting both the current
  /// key and the pre-§8 Latin filename. Returns null for `finitus` and for
  /// anything unrecognised.
  static VocalSlot? fromStorageKey(String key) {
    for (final slot in VocalSlot.values) {
      if (slot.storageKey == key) return slot;
    }
    return legacyStorageKeys[key];
  }
}
