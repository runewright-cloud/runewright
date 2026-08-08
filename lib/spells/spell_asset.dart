// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_asset.dart — the persisted record of an inscribed spell: the proof
// binding a CA simulation to the player's Runekey, plus just enough
// metadata to eventually list in a library. The library UI itself is out
// of scope (CLAUDE.md: "Spellbook/bestiary UI... do not build") -- this is
// the "minimal persistence" half of the in-scope tracer bullet (inscribe a
// grid -> generate a proof -> persist it -> verify it), so [loadAll] exists
// and is tested even though no screen calls it yet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'chapter_asset.dart';
import 'spell_art_pack.dart' show kPainterlyPack;
import 'spell_identity.dart' show behaviouralKinKey, kKinshipMinElements;
import 'spell_sound_pack.dart' show kSpellSoundPack;

/// Where a spell's custom art (lib/spells/spell_art_store.dart) came from.
/// P1 only ever writes [localImport]. [received]/[synced] are reserved for
/// P2 (opponent art advertised in battle) and P3 (post-match sync) -- values,
/// not behavior, so this enum doesn't have to change shape when those land.
/// [builtIn] (docs/SPELL_ART_PACK_PLAN.md) is a spell using an icon from a
/// shipped art pack (lib/spells/spell_art_pack.dart) rather than an imported
/// image -- its bytes live in the asset bundle, not [SpellArtStore].
enum SpellArtSource { localImport, received, synced, builtIn }

/// Where a spell's custom sound (lib/spells/spell_sound_store.dart) came
/// from. Mirrors [SpellArtSource] but with no `received` value -- Sound has
/// no P2-battle-advertised-art analogue (docs/SPELL_SOUND_PACK_PLAN.md D-5/
/// F-1); a sound only ever arrives as a local import or a Sync Art bundle.
enum SpellSoundSource { localImport, synced, builtIn }

class SpellAsset {
  SpellAsset({
    required this.id,
    required this.createdAt,
    required this.tier,
    required this.t,
    required this.ownerPubkeyHex,
    required this.manaCost,
    required this.segmentCount,
    required this.dotCount,
    required this.initialGrid,
    required this.proofBytes,
    required this.name,
    required this.commitmentHex,
    required this.spellHashHex,
    this.formula = const [],
    this.supremeTags = const [],
    this.isSummon = false,
    this.summonPersonality = 'aggressive',
    this.artHash,
    this.artSource,
    this.artUpdatedAt,
    this.artPackId,
    this.soundHash,
    this.soundSource,
    this.soundUpdatedAt,
    this.soundPackId,
    this.gridWithheld = false,
  });

  /// Unique within a device install -- a microsecond timestamp is more than
  /// sufficient for a single-player, button-press-cadence action (not a
  /// distributed identifier).
  final String id;
  final DateTime createdAt;

  /// Which of the three circuit tiers (12/24/48) this proof was generated
  /// against -- needed to pick the matching VK if this spell is ever
  /// re-verified.
  final int tier;

  /// Number of CA generations simulated (1 <= t <= tier).
  final int t;

  /// `owner_pubkey` hex, as bound into the proof's public inputs --
  /// CIRCUIT_IO.md CIRCUIT_IO 5/6.
  final String ownerPubkeyHex;

  final int manaCost;

  /// Geometry of the initial grid (T=0), computed from public circuit outputs.
  /// segmentCount: maximal runs of ≥2 contiguous inscribable active cells per axis.
  /// dotCount: inscribable active cells with zero inscribable active neighbors.
  /// Both are pure functions of grid_state; used to derive and verify manaCost.
  /// Value -1 indicates a legacy spell inscribed before RULESET_VERSION 3.
  final int segmentCount;
  final int dotCount;

  /// The 469-cell packed initial grid state (see HexGrid.packGridState) --
  /// kept alongside the proof so a future library UI can render a thumbnail
  /// without re-deriving it from the proof's opaque commitment.
  final List<int> initialGrid;

  /// Raw proof bytes in the noir-rs wire format (public inputs + proof,
  /// see TimedProofResult) -- self-contained, opaque to this app
  /// (CLAUDE.md hard invariant 1: never reimplement the circuit's crypto).
  final Uint8List proofBytes;

  /// Player-assigned name for this spell.
  final String name;

  /// `Poseidon2(packed_grid)` — the in-circuit grid commitment, extracted
  /// from the proof's public inputs (field index 3, CIRCUIT_IO.md CIRCUIT_IO 4).
  /// A GRID identity: one-to-one with the initial state, and still what
  /// permissions, art sync and book membership key to.
  ///
  /// It is no longer what makes two spells "Kin" — see [kinKey]. That moved
  /// to behaviour in docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 3, because a
  /// throwaway dot that dies in generation 1 changes the commitment while
  /// changing nothing about what the spell does.
  final String commitmentHex;

  /// `Poseidon2(commitment, T)` — computed off-circuit via FFI
  /// (lib/ffi/identity.dart). Unique per (grid, T) pair; used as the
  /// duplicate-detection key when saving a new inscription.
  final String spellHashHex;

  /// Elemental activations committed to the formula bar during this spell's
  /// simulation, stored as BorderZone enum names ('fire', 'air', 'water',
  /// 'earth'). Empty for spells inscribed before this field was added.
  final List<String> formula;

  /// BorderZone enum names for elements that achieved supreme dominance at
  /// least once during this spell's simulation. Determines which cast-time
  /// enhancement (Potency/Velocity/Efficiency/Mystery) is choosable when
  /// casting this spell in battle. Empty for older spells.
  final List<String> supremeTags;

  /// design doc "Summons": when true, casting this spell derives a creature
  /// from [formula] (see CreatureSpec.fromElements) instead of resolving it
  /// as a 16-cell incantation effect. False for ordinary spells.
  final bool isSummon;

  /// design doc "Personalities": the battlefield-behavior glyph this summon
  /// will fight with, stored as the SummonPersonality enum name
  /// ('aggressive', 'evasive', 'protective', 'tactical'). A raw string, not
  /// the enum itself, so this persistence-layer file doesn't depend on the
  /// battle engine's minion.dart -- mirrors how [formula] stores raw
  /// BorderZone names rather than the enum.
  ///
  /// This is a fallback default, not the assignment point: personality is
  /// chosen per-chapter, when the spell is added to a Chapter (see
  /// ChapterEntry.summonPersonality / [withSummonPersonality]), not at
  /// inscription -- the same base spell may be added to different chapters
  /// with different personalities. This field is only what a summon uses
  /// when no chapter-entry override is present (e.g. legacy chapters saved
  /// before this field existed). Meaningless when [isSummon] is false.
  final String summonPersonality;

  /// Hex SHA-256 of the player-imported custom art's canonical full-size
  /// bytes (lib/spells/spell_art_import.dart), or null if this spell has no
  /// custom art and renders the commitmentHex-derived coat of arms.
  ///
  /// The art bytes themselves are NOT stored here -- see
  /// lib/spells/spell_art_store.dart's header comment for why (inline blobs
  /// would balloon the loadAll() dedup scan every inscribeSpell() call runs).
  /// This field is only a pointer + integrity check for that side store.
  final String? artHash;

  /// Where this spell's custom art came from. P1 only ever writes
  /// [SpellArtSource.localImport]; the other values are reserved for P2
  /// (received from an opponent) and P3 (post-match sync).
  final SpellArtSource? artSource;

  /// When [artHash] was last set. Null iff [artHash] is null.
  final DateTime? artUpdatedAt;

  /// The [SpellArtPackEntry.id] this spell's art was set from, when
  /// [artSource] is [SpellArtSource.builtIn]. Null otherwise. The pack's
  /// bytes are looked up by this id (lib/spells/spell_art_pack.dart) rather
  /// than by [spellHashHex] -- [SpellArtStore] is never touched for built-in
  /// art. [artHash] is still set (copied from the pack manifest's sha256),
  /// so Sync Art's integrity check needs no special case for pack art.
  final String? artPackId;

  /// Hex SHA-256 of the player-imported custom sound's raw bytes
  /// (lib/spells/spell_sound_import.dart), or null if this spell has no
  /// custom sound and resolves D-6's elemental default at cast time.
  ///
  /// The sound bytes themselves are NOT stored here -- same reasoning as
  /// [artHash]/[SpellArtStore]: see lib/spells/spell_sound_store.dart.
  final String? soundHash;

  /// Where this spell's custom sound came from. Mirrors [artSource].
  final SpellSoundSource? soundSource;

  /// When [soundHash] was last set. Null iff [soundHash] is null.
  final DateTime? soundUpdatedAt;

  /// The [SpellSoundPackEntry.id] this spell's sound was set from, when
  /// [soundSource] is [SpellSoundSource.builtIn]. Null otherwise. Mirrors
  /// [artPackId] -- looked up in [kSpellSoundPack], never touches
  /// [SpellSoundStore]. [soundHash] is still set (copied from the pack
  /// manifest's sha256), so Sync Sound's integrity check needs no special
  /// case for pack sound (docs/SPELL_SOUND_PACK_PLAN.md D-5).
  final String? soundPackId;

  /// True iff [initialGrid] was deliberately redacted (stored empty) before
  /// this asset was handed to someone other than its creator -- the Trade
  /// loan case (docs/COMMUNE_TRADE_PLAN.md §2): the loanee gets proof bytes
  /// (zero-knowledge -- they don't leak the grid) plus enough metadata to
  /// use the spell locally, but never the grid itself. False for every
  /// spell this device inscribed or received via a full transfer.
  final bool gridWithheld;

  /// This spell's behavioural kinship key, or null if it is kinship-exempt
  /// (a trajectory under [kKinshipMinElements]).
  ///
  /// Derived, never persisted: it is a pure function of [formula] and
  /// [manaCost], both of which are already stored, and both of which a peer
  /// can recompute from certified proof outputs. See spell_identity.dart for
  /// why this must never be used to authorize anything.
  String? get kinKey =>
      behaviouralKinKey(trajectory: formula, baseManaCost: manaCost);

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'tier': tier,
        't': t,
        'ownerPubkeyHex': ownerPubkeyHex,
        'manaCost': manaCost,
        'segmentCount': segmentCount,
        'dotCount': dotCount,
        'initialGrid': initialGrid,
        'proofBytesBase64': base64Encode(proofBytes),
        'name': name,
        'commitmentHex': commitmentHex,
        'spellHashHex': spellHashHex,
        'formula': formula,
        'supremeTags': supremeTags,
        'isSummon': isSummon,
        'summonPersonality': summonPersonality,
        if (artHash != null) 'artHash': artHash,
        if (artSource != null) 'artSource': artSource!.name,
        if (artUpdatedAt != null) 'artUpdatedAt': artUpdatedAt!.toIso8601String(),
        if (artPackId != null) 'artPackId': artPackId,
        if (soundHash != null) 'soundHash': soundHash,
        if (soundSource != null) 'soundSource': soundSource!.name,
        if (soundUpdatedAt != null) 'soundUpdatedAt': soundUpdatedAt!.toIso8601String(),
        if (soundPackId != null) 'soundPackId': soundPackId,
        if (gridWithheld) 'gridWithheld': gridWithheld,
      };

  static SpellAsset fromJson(Map<String, dynamic> json) => SpellAsset(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        tier: json['tier'] as int,
        t: json['t'] as int,
        ownerPubkeyHex: json['ownerPubkeyHex'] as String,
        manaCost: json['manaCost'] as int,
        // -1 sentinel: spell was inscribed before RULESET_VERSION 3 geometry
        // outputs existed. Library will purge these on next load.
        segmentCount: (json['segmentCount'] as int?) ?? -1,
        dotCount: (json['dotCount'] as int?) ?? -1,
        initialGrid: (json['initialGrid'] as List).cast<int>(),
        proofBytes: base64Decode(json['proofBytesBase64'] as String),
        name: (json['name'] as String?) ?? '',
        commitmentHex: (json['commitmentHex'] as String?) ?? '',
        spellHashHex: (json['spellHashHex'] as String?) ?? '',
        formula: (json['formula'] as List<dynamic>? ?? []).cast<String>(),
        supremeTags: (json['supremeTags'] as List<dynamic>? ?? []).cast<String>(),
        isSummon: (json['isSummon'] as bool?) ?? false,
        summonPersonality: (json['summonPersonality'] as String?) ?? 'aggressive',
        artHash: json['artHash'] as String?,
        artSource: switch (json['artSource'] as String?) {
          null => null,
          final s => SpellArtSource.values.firstWhere((v) => v.name == s,
              orElse: () => SpellArtSource.localImport),
        },
        artUpdatedAt: json['artUpdatedAt'] != null
            ? DateTime.parse(json['artUpdatedAt'] as String)
            : null,
        artPackId: json['artPackId'] as String?,
        soundHash: json['soundHash'] as String?,
        soundSource: switch (json['soundSource'] as String?) {
          null => null,
          final s => SpellSoundSource.values.firstWhere((v) => v.name == s,
              orElse: () => SpellSoundSource.localImport),
        },
        soundUpdatedAt: json['soundUpdatedAt'] != null
            ? DateTime.parse(json['soundUpdatedAt'] as String)
            : null,
        soundPackId: json['soundPackId'] as String?,
        gridWithheld: (json['gridWithheld'] as bool?) ?? false,
      );

  static Future<Directory> _spellsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/spells');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns a copy with [tags] substituted for [supremeTags]; all other
  /// fields are unchanged. Used to migrate legacy spells (inscribed before the
  /// supremeTags field was added) without re-inscription.
  SpellAsset withSupremeTags(List<String> tags) => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: tags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
        artPackId: artPackId,
        soundHash: soundHash,
        soundSource: soundSource,
        soundUpdatedAt: soundUpdatedAt,
        soundPackId: soundPackId,
      );

  /// Returns a copy with [personality] substituted for [summonPersonality];
  /// all other fields unchanged. Used to bind the battlefield-behavior glyph
  /// chosen when this spell is added to a Chapter (see
  /// ChapterEntry.summonPersonality) -- not called at inscription, since the
  /// same base spell may be added to different chapters (or, for Basic
  /// spells, added more than once to the same chapter) with different
  /// personalities each time.
  SpellAsset withSummonPersonality(String personality) => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: personality,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
        artPackId: artPackId,
        soundHash: soundHash,
        soundSource: soundSource,
        soundUpdatedAt: soundUpdatedAt,
        soundPackId: soundPackId,
        gridWithheld: gridWithheld,
      );

  /// Returns a copy with custom-art metadata set to [hash]/[source], stamped
  /// with the current time. The art bytes themselves go to
  /// [SpellArtStore.save] separately -- this only updates the pointer.
  /// Deliberately does not carry [artPackId] forward: importing an image
  /// supersedes any previous built-in-pack selection, so switching to local
  /// import clears the pack pointer rather than leaving it stale.
  SpellAsset withArt({required String hash, required SpellArtSource source}) => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        artHash: hash,
        artSource: source,
        artUpdatedAt: DateTime.now().toUtc(),
        soundHash: soundHash,
        soundSource: soundSource,
        soundUpdatedAt: soundUpdatedAt,
        soundPackId: soundPackId,
      );

  /// Returns a copy with this spell's art set to the built-in pack entry
  /// [packId] (docs/SPELL_ART_PACK_PLAN.md), stamped with the current time.
  /// Mirrors [withArt] but for pack art: [artHash] is copied from the pack's
  /// own manifest (so Sync Art's integrity check needs no special case for
  /// built-in art -- see lib/trade/sync_art_session.dart), and no bytes go
  /// to [SpellArtStore] -- the pack ships in the asset bundle already.
  SpellAsset withPackArt({required String packId}) {
    final entry = kPainterlyPack.firstWhere(
      (e) => e.id == packId,
      orElse: () => throw ArgumentError.value(packId, 'packId', 'not in kPainterlyPack'),
    );
    return SpellAsset(
      id: id,
      createdAt: createdAt,
      tier: tier,
      t: t,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: manaCost,
      segmentCount: segmentCount,
      dotCount: dotCount,
      initialGrid: initialGrid,
      proofBytes: proofBytes,
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: spellHashHex,
      formula: formula,
      supremeTags: supremeTags,
      isSummon: isSummon,
      summonPersonality: summonPersonality,
      artHash: entry.sha256,
      artSource: SpellArtSource.builtIn,
      artUpdatedAt: DateTime.now().toUtc(),
      artPackId: packId,
      soundHash: soundHash,
      soundSource: soundSource,
      soundUpdatedAt: soundUpdatedAt,
      soundPackId: soundPackId,
    );
  }

  /// Returns a copy with custom-art metadata cleared (including any built-in
  /// pack selection) -- the card reverts to the commitmentHex-derived coat
  /// of arms. Does NOT delete anything from [SpellArtStore]; callers pair
  /// this with [SpellArtStore.delete] when the cleared art was a local
  /// import (a no-op if it was pack art, since pack art was never stored
  /// there).
  SpellAsset withoutArt() => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        soundHash: soundHash,
        soundSource: soundSource,
        soundUpdatedAt: soundUpdatedAt,
        soundPackId: soundPackId,
      );

  /// Returns a copy with custom-sound metadata set to [hash]/[source],
  /// stamped with the current time. The sound bytes themselves go to
  /// [SpellSoundStore.save] separately -- this only updates the pointer.
  /// Deliberately does not carry [soundPackId] forward: importing a clip
  /// supersedes any previous built-in-pack selection. Mirrors [withArt].
  SpellAsset withSound({required String hash, required SpellSoundSource source}) => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
        artPackId: artPackId,
        soundHash: hash,
        soundSource: source,
        soundUpdatedAt: DateTime.now().toUtc(),
      );

  /// Returns a copy with this spell's sound set to the built-in pack entry
  /// [packId] (docs/SPELL_SOUND_PACK_PLAN.md), stamped with the current
  /// time. Mirrors [withPackArt].
  SpellAsset withPackSound({required String packId}) {
    final entry = kSpellSoundPack.firstWhere(
      (e) => e.id == packId,
      orElse: () => throw ArgumentError.value(packId, 'packId', 'not in kSpellSoundPack'),
    );
    return SpellAsset(
      id: id,
      createdAt: createdAt,
      tier: tier,
      t: t,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: manaCost,
      segmentCount: segmentCount,
      dotCount: dotCount,
      initialGrid: initialGrid,
      proofBytes: proofBytes,
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: spellHashHex,
      formula: formula,
      supremeTags: supremeTags,
      isSummon: isSummon,
      summonPersonality: summonPersonality,
      artHash: artHash,
      artSource: artSource,
      artUpdatedAt: artUpdatedAt,
      artPackId: artPackId,
      soundHash: entry.sha256,
      soundSource: SpellSoundSource.builtIn,
      soundUpdatedAt: DateTime.now().toUtc(),
      soundPackId: packId,
    );
  }

  /// Returns a copy with custom-sound metadata cleared (including any
  /// built-in pack selection) -- casting this spell falls back to D-6's
  /// elemental default. Does NOT delete anything from [SpellSoundStore];
  /// callers pair this with [SpellSoundStore.delete] when the cleared sound
  /// was a local import. Mirrors [withoutArt].
  SpellAsset withoutSound() => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: initialGrid,
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
        artPackId: artPackId,
      );

  /// Returns a copy with [initialGrid] redacted (stored empty) and
  /// [gridWithheld] set -- what a Trade loan sends its grantee: proof bytes
  /// and every other field are copied through unchanged (proofBytes are
  /// zero-knowledge and don't leak the grid), but the grid itself never
  /// leaves this device. See docs/COMMUNE_TRADE_PLAN.md §2 and
  /// lib/trade/trade_session.dart.
  ///
  /// Carries art metadata through (fixed alongside the artPackId addition,
  /// docs/SPELL_ART_PACK_PLAN.md Phase C -- this previously dropped
  /// artHash/artSource/artUpdatedAt silently, since this method predates the
  /// custom-art feature and was never updated when those fields were added;
  /// a loaned spell with custom art lost its art on the wire). Carries sound
  /// metadata through for the same reason, from the start
  /// (docs/SPELL_SOUND_PACK_PLAN.md Phase C).
  SpellAsset withGridWithheld() => SpellAsset(
        id: id,
        createdAt: createdAt,
        tier: tier,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: const [],
        proofBytes: proofBytes,
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: spellHashHex,
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
        artPackId: artPackId,
        soundHash: soundHash,
        soundSource: soundSource,
        soundUpdatedAt: soundUpdatedAt,
        soundPackId: soundPackId,
        gridWithheld: true,
      );

  /// Deletes this spell's persisted JSON file (silently no-ops if already
  /// gone) and strips it out of every chapter that referenced it — a chapter
  /// entry is only ever a [SpellAsset.id], so this covers a deletion from
  /// either the Craftings tab or the Loans tab the same way.
  Future<void> delete() async {
    final dir = await _spellsDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
    await ChapterAsset.removeSpellFromAllChapters(id);
  }

  /// Persists this spell as `<app documents>/spells/<id>.json`. Returns the
  /// written file.
  Future<File> save() async {
    final dir = await _spellsDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  /// Loads every persisted spell, newest first. Not called by any screen
  /// yet (the library UI is a later milestone) -- exists so the read path
  /// is exercised by tests rather than written blind.
  static Future<List<SpellAsset>> loadAll() async {
    final dir = await _spellsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final assets = <SpellAsset>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      assets.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    assets.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return assets;
  }
}
