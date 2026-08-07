// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_backup.dart — export/import for a complete local backup of the
// player's library: crafted + loaned spells (and their custom art),
// chapters, sightings (the bestiary, plus any synced sighting art), loan
// grants, and discovered recipes. Deliberately separate from
// lib/identity/backup.dart, which backs up the *Runekey* (the private seed)
// -- this backs up everything *built* with that key, not the key itself.
//
// Import is strictly additive: nothing already on disk is ever overwritten
// or deleted. Each record kind has its own natural dedup key --
// spellHashHex for spells, opponentPubkeyHex+commitmentHex (SightingAsset.id)
// for sightings, id for chapters/permissions, the recipe key itself for the
// recipe book. A record whose key already exists locally is skipped as a
// redundancy. [SpellAsset.id] is a device-local timestamp, not
// content-derived, so it is NOT used to dedupe spells -- reusing a foreign
// id verbatim risks colliding with an unrelated local spell. Every newly
// added spell is instead given a freshly minted id, and chapters (which
// reference spells by id) have their entries rewritten through the id
// substitutions recorded while importing spells -- see [_importSpells].
//
// A spell imported from someone else's library keeps their ownerPubkeyHex
// unchanged. That is what makes it correctly unusable for casting: battle
// cast-time authorization recomputes Poseidon2(this device's own presented
// key) and compares it against the proof's owner_pubkey
// (identity.dart's ownerPubkeyMatches, used by spell_authorization.dart's
// localIdentityMayUse/castingPlayerMayUse), which can only ever match this
// device's own Runekey. Nothing in this file enforces that -- it falls out
// of the existing trust boundary for free, which is the point.

import 'dart:convert';

import 'chapter_asset.dart';
import 'recipe_book.dart';
import 'sighting_asset.dart';
import 'spell_art_store.dart';
import 'spell_asset.dart';
import 'spell_permission.dart';
import 'spell_sound_store.dart';

const String _kMagic = 'RUNEWRIGHT_LIBRARY_BACKUP';
const int _kVersion = 1;

class LibraryBackupFormatException implements Exception {
  LibraryBackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'LibraryBackupFormatException: $message';
}

/// What an import actually did, for a post-import summary dialog. Every
/// `*Skipped` count is a redundancy the import left untouched, not a
/// failure.
class LibraryImportSummary {
  const LibraryImportSummary({
    required this.spellsAdded,
    required this.spellsSkipped,
    required this.chaptersAdded,
    required this.chaptersSkipped,
    required this.sightingsAdded,
    required this.sightingsSkipped,
    required this.permissionsAdded,
    required this.permissionsSkipped,
    required this.recipesAdded,
  });

  final int spellsAdded;
  final int spellsSkipped;
  final int chaptersAdded;
  final int chaptersSkipped;
  final int sightingsAdded;
  final int sightingsSkipped;
  final int permissionsAdded;
  final int permissionsSkipped;
  final int recipesAdded;

  bool get addedNothing =>
      spellsAdded == 0 &&
      chaptersAdded == 0 &&
      sightingsAdded == 0 &&
      permissionsAdded == 0 &&
      recipesAdded == 0;
}

/// Builds the backup document as a pretty-printed JSON string. This is a
/// point-in-time snapshot of everything currently on disk, not a live view.
Future<String> exportLibraryBackup() async {
  final spells = await SpellAsset.loadAll();
  final chapters = await ChapterAsset.loadAll();
  final sightings = await SightingAsset.loadAll();
  final permissions = await SpellPermission.loadAll();
  final recipes = await RecipeBook.load();

  final spellArt = <String, dynamic>{};
  for (final spell in spells) {
    // Built-in pack art ships in the asset bundle already (spell_art_pack.dart)
    // -- nothing to copy out of SpellArtStore for it.
    if (spell.artHash == null || spell.artSource == SpellArtSource.builtIn) continue;
    final blob = await _loadArtBase64(spell.spellHashHex);
    if (blob != null) spellArt[spell.spellHashHex] = blob;
  }

  final sightingArt = <String, dynamic>{};
  for (final sighting in sightings) {
    if (sighting.artHash == null) continue;
    final blob = await _loadArtBase64(sighting.id);
    if (blob != null) sightingArt[sighting.id] = blob;
  }

  final spellSound = <String, dynamic>{};
  for (final spell in spells) {
    // Built-in pack sound ships in the asset bundle already (spell_sound_pack.dart)
    // -- nothing to copy out of SpellSoundStore for it. Mirrors spellArt above.
    if (spell.soundHash == null || spell.soundSource == SpellSoundSource.builtIn) continue;
    final bytes = await SpellSoundStore.load(spell.spellHashHex);
    if (bytes != null) spellSound[spell.spellHashHex] = base64Encode(bytes);
  }

  final sightingSound = <String, dynamic>{};
  for (final sighting in sightings) {
    if (sighting.soundHash == null || sighting.soundSource == SpellSoundSource.builtIn) continue;
    final bytes = await SpellSoundStore.load(sighting.id);
    if (bytes != null) sightingSound[sighting.id] = base64Encode(bytes);
  }

  final doc = {
    'magic': _kMagic,
    'version': _kVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'spells': spells.map((s) => s.toJson()).toList(),
    'spellArt': spellArt,
    'spellSound': spellSound,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'sightings': sightings.map((s) => s.toJson()).toList(),
    'sightingArt': sightingArt,
    'sightingSound': sightingSound,
    'permissions': permissions.map((p) => p.toJson()).toList(),
    'recipes': recipes.toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(doc);
}

Future<Map<String, String>?> _loadArtBase64(String key) async {
  final full = await SpellArtStore.loadFull(key);
  final thumb = await SpellArtStore.loadThumb(key);
  if (full == null || thumb == null) return null;
  return {'full': base64Encode(full), 'thumb': base64Encode(thumb)};
}

/// Parses and additively merges [jsonText] into the on-device library.
/// Never overwrites or deletes anything already on disk -- see this file's
/// header for the per-kind dedup keys. Throws [LibraryBackupFormatException]
/// for an unrecognized file; malformed record contents surface as whatever
/// exception the underlying `fromJson` throws, same as a corrupt on-disk file.
Future<LibraryImportSummary> importLibraryBackup(String jsonText) async {
  final Map<String, dynamic> doc;
  try {
    doc = jsonDecode(jsonText) as Map<String, dynamic>;
  } on FormatException {
    throw LibraryBackupFormatException('not valid JSON');
  }
  if (doc['magic'] != _kMagic) {
    throw LibraryBackupFormatException('not a Runewright library backup (bad magic)');
  }
  if (doc['version'] != _kVersion) {
    throw LibraryBackupFormatException('unsupported library backup version ${doc['version']}');
  }

  final spellResult = await _importSpells(
    (doc['spells'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
    (doc['spellArt'] as Map<String, dynamic>? ?? {}).cast<String, dynamic>(),
    (doc['spellSound'] as Map<String, dynamic>? ?? {}).cast<String, dynamic>(),
  );
  final chapterResult = await _importChapters(
    (doc['chapters'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
    spellResult.idRemap,
  );
  final sightingResult = await _importSightings(
    (doc['sightings'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
    (doc['sightingArt'] as Map<String, dynamic>? ?? {}).cast<String, dynamic>(),
    (doc['sightingSound'] as Map<String, dynamic>? ?? {}).cast<String, dynamic>(),
  );
  final permissionResult = await _importPermissions(
    (doc['permissions'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
  );
  final recipesAdded = await _importRecipes((doc['recipes'] as List<dynamic>? ?? []).cast<String>());

  return LibraryImportSummary(
    spellsAdded: spellResult.added,
    spellsSkipped: spellResult.skipped,
    chaptersAdded: chapterResult.added,
    chaptersSkipped: chapterResult.skipped,
    sightingsAdded: sightingResult.added,
    sightingsSkipped: sightingResult.skipped,
    permissionsAdded: permissionResult.added,
    permissionsSkipped: permissionResult.skipped,
    recipesAdded: recipesAdded,
  );
}

class _ImportCounts {
  const _ImportCounts(this.added, this.skipped);
  final int added;
  final int skipped;
}

class _SpellImportResult {
  const _SpellImportResult(this.added, this.skipped, this.idRemap);
  final int added;
  final int skipped;

  /// Backup spell id -> the id it resolves to on this device, whether newly
  /// minted or an existing duplicate's. Used to rewrite ChapterEntry.spellId
  /// references in [_importChapters].
  final Map<String, String> idRemap;
}

Future<_SpellImportResult> _importSpells(
  List<Map<String, dynamic>> spellJsons,
  Map<String, dynamic> spellArtJson,
  Map<String, dynamic> spellSoundJson,
) async {
  final existingBySpellHash = {for (final s in await SpellAsset.loadAll()) s.spellHashHex: s};
  final idRemap = <String, String>{};
  var added = 0, skipped = 0, mintCounter = 0;

  for (final raw in spellJsons) {
    final json = Map<String, dynamic>.from(raw);
    final backupId = json['id'] as String;
    final spellHashHex = (json['spellHashHex'] as String?) ?? '';

    // An empty spellHashHex means a pre-RULESET_VERSION-3 legacy spell --
    // never treat those as duplicates of each other, only real hashes dedupe.
    final dupe = spellHashHex.isEmpty ? null : existingBySpellHash[spellHashHex];
    if (dupe != null) {
      idRemap[backupId] = dupe.id;
      skipped++;
      continue;
    }

    final newId = '${DateTime.now().toUtc().microsecondsSinceEpoch}_import${mintCounter++}';
    json['id'] = newId;
    final asset = SpellAsset.fromJson(json);
    await asset.save();
    if (spellHashHex.isNotEmpty) existingBySpellHash[spellHashHex] = asset;
    idRemap[backupId] = newId;
    added++;

    final art = spellArtJson[spellHashHex] as Map<String, dynamic>?;
    if (art != null && await SpellArtStore.loadFull(spellHashHex) == null) {
      await SpellArtStore.save(
        spellHashHex,
        full: base64Decode(art['full'] as String),
        thumb: base64Decode(art['thumb'] as String),
      );
    }

    final soundBase64 = spellSoundJson[spellHashHex] as String?;
    if (soundBase64 != null && await SpellSoundStore.load(spellHashHex) == null) {
      await SpellSoundStore.save(spellHashHex, base64Decode(soundBase64));
    }
  }
  return _SpellImportResult(added, skipped, idRemap);
}

Future<_ImportCounts> _importChapters(
  List<Map<String, dynamic>> chapterJsons,
  Map<String, String> spellIdRemap,
) async {
  final existingIds = (await ChapterAsset.loadAll()).map((c) => c.id).toSet();
  var added = 0, skipped = 0;

  for (final json in chapterJsons) {
    final id = json['id'] as String;
    if (existingIds.contains(id)) {
      skipped++;
      continue;
    }
    final chapter = ChapterAsset.fromJson(json);
    final remappedEntries = <ChapterEntry>[
      for (final entry in chapter.entries)
        if (spellIdRemap[entry.spellId] case final resolvedId?)
          ChapterEntry(spellId: resolvedId, summonPersonality: entry.summonPersonality),
      // Entries whose spellId has no remap (the referenced spell wasn't in
      // this backup at all -- an edited or partial file) are silently
      // dropped rather than left dangling.
    ];
    await ChapterAsset(
      id: chapter.id,
      name: chapter.name,
      createdAt: chapter.createdAt,
      entries: remappedEntries,
      artifacts: chapter.artifacts,
    ).save();
    existingIds.add(id);
    added++;
  }
  return _ImportCounts(added, skipped);
}

Future<_ImportCounts> _importSightings(
  List<Map<String, dynamic>> sightingJsons,
  Map<String, dynamic> sightingArtJson,
  Map<String, dynamic> sightingSoundJson,
) async {
  final existingIds = (await SightingAsset.loadAll()).map((s) => s.id).toSet();
  var added = 0, skipped = 0;

  for (final json in sightingJsons) {
    final sighting = SightingAsset.fromJson(json);
    if (existingIds.contains(sighting.id)) {
      skipped++;
      continue;
    }
    await sighting.save();
    existingIds.add(sighting.id);
    added++;

    final art = sightingArtJson[sighting.id] as Map<String, dynamic>?;
    if (art != null && await SpellArtStore.loadFull(sighting.id) == null) {
      await SpellArtStore.save(
        sighting.id,
        full: base64Decode(art['full'] as String),
        thumb: base64Decode(art['thumb'] as String),
      );
    }

    final soundBase64 = sightingSoundJson[sighting.id] as String?;
    if (soundBase64 != null && await SpellSoundStore.load(sighting.id) == null) {
      await SpellSoundStore.save(sighting.id, base64Decode(soundBase64));
    }
  }
  return _ImportCounts(added, skipped);
}

Future<_ImportCounts> _importPermissions(List<Map<String, dynamic>> permissionJsons) async {
  final existingIds = (await SpellPermission.loadAll()).map((p) => p.id).toSet();
  var added = 0, skipped = 0;

  for (final json in permissionJsons) {
    final id = json['id'] as String;
    if (existingIds.contains(id)) {
      skipped++;
      continue;
    }
    await SpellPermission.fromJson(json).save();
    existingIds.add(id);
    added++;
  }
  return _ImportCounts(added, skipped);
}

Future<int> _importRecipes(List<String> keys) async {
  final before = await RecipeBook.load();
  final after = await RecipeBook.markDiscovered(keys);
  return after.length - before.length;
}
