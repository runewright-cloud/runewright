// SPDX-License-Identifier: GPL-3.0-or-later
//
// basic_spell_seed.dart — seeds the five bundled "Basic *" starter spells
// (lib/spells/basic_spells.dart) into the player's library.
//
// Idempotent and marker-gated: a normal launch seeds once per
// kBasicSpellSetVersion and never re-adds a spell the player deleted (the
// "deletable, stays deleted" decision — docs/BASIC_SPELLS_PLAN.md §1). The
// version marker is what lets a future sixth basic reach installs that
// already seeded the first five, without disturbing spells 1-5 (the
// per-spellHashHex existence check in [seedBasicSpells] skips any already on
// disk, so bumping the version and reseeding is safe even for a player who
// kept all five).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'basic_spells.dart';
import 'spell_asset.dart';

Future<File> _markerFile() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/spells');
  if (!await dir.exists()) await dir.create(recursive: true);
  return File('${dir.path}/_basics_seeded.txt');
}

Future<int?> _seededVersion() async {
  final file = await _markerFile();
  if (!await file.exists()) return null;
  return int.tryParse((await file.readAsString()).trim());
}

Future<void> _writeSeededVersion(int version) async {
  final file = await _markerFile();
  await file.writeAsString('$version');
}

/// Copies any bundled basic spell not already present in the player's
/// library (matched by [SpellAsset.spellHashHex]) onto disk. Never
/// overwrites an existing file — a player who renamed or re-arted their copy
/// keeps it, and a player who deleted one keeps it gone.
///
/// Skipped entirely (returns 0) when the on-disk marker already records a
/// version >= [kBasicSpellSetVersion], unless [force] is true — [force] is
/// the Library's "Restore basic spells" action, which re-adds any of the
/// five currently missing regardless of the marker.
///
/// Returns the number of spells actually written.
Future<int> seedBasicSpells({bool force = false}) async {
  if (!force) {
    final seededVersion = await _seededVersion();
    if (seededVersion != null && seededVersion >= kBasicSpellSetVersion) {
      return 0;
    }
  }

  final existing = await SpellAsset.loadAll();
  final existingHashes = existing.map((s) => s.spellHashHex).toSet();

  var written = 0;
  for (final entry in kBasicSpells) {
    if (existingHashes.contains(entry.spellHashHex)) continue;
    final raw = await rootBundle.loadString(entry.assetPath);
    final spell = SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    await spell.save();
    written++;
  }

  await _writeSeededVersion(kBasicSpellSetVersion);
  return written;
}
