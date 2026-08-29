// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_semantics_migration.dart — repairs already-installed spells whose
// authored metadata its own proof contradicts (M4.22-F1, docs/M4_findings.md).
//
// `inscribeSpell` persisted `formula`, `supremeTags` and `manaCost` from
// caller-supplied arguments without checking them against the proof it had
// just generated, so a stale UI FormulaTracker could be written verbatim to
// disk. M4.22 fixed the write path and regenerated the bundled assets, but a
// corrected bundle cannot reach an install that already has those spells:
// `seedBasicSpells` skips per `spellHashHex`, and `spellHashHex` is
// `Poseidon2(commitment, T)` — a metadata-only repair changes neither the
// commitment nor T, so the existence check always hits. Bumping
// `kBasicSpellSetVersion` only clears the marker gate, and Library →
// "Restore basic spells" (`force: true`) falls through the same check.
//
// So the fix cannot be a reseed; it has to be a migration over device state.
// This is `scripts/audit_spell_assets.dart --fix` run against the player's
// library instead of the bundle, keyed on [kSpellSemanticsMigrationVersion]
// rather than on any spell's identity — which is the whole point, since the
// identity is exactly what a metadata repair leaves alone.
//
// It rewrites ONLY the three derivable fields, in place. The grid, `t`, the
// commitment, the proof bytes, the spell's identity (`id`, `spellHashHex`)
// and the summon declaration (`isSummon`, `summonPersonality` — M4.19, a
// separate defect) are never touched. An asset whose proof disagrees with its
// IDENTITY is refused, not repaired: that is not stale prose, that is the
// wrong proof, and silently rewriting it would launder it.
//
// This repairs inscribed spells generally, not just the bundled basics — a
// spell the player inscribed while the write path was still unchecked has the
// same defect and is not reachable by any reseed at all.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'spell_asset_integrity.dart';

/// Bump to re-run the migration over every installed spell on next launch.
///
/// 1 — M4.22-F1: the first pass, repairing assets written by the pre-M4.22
///     `inscribeSpell` (notably the shipped Basic Windhound, whose authored
///     formula was 12 elements against a certified fire/water/water, and
///     whose authored mana cost was 83 against a certified 25).
const int kSpellSemanticsMigrationVersion = 1;

/// What one migration pass did. Counts are over proof-backed spell files
/// only; anything that isn't a spell asset is ignored without being counted.
class SpellSemanticsMigrationReport {
  const SpellSemanticsMigrationReport({
    this.scanned = 0,
    this.repaired = 0,
    this.refused = 0,
    this.proofless = 0,
    this.skipped = false,
  });

  /// Proof-backed spell files examined.
  final int scanned;

  /// Files whose three derivable fields were rewritten from their own proof.
  final int repaired;

  /// Files left alone because their proof contradicts their identity, or
  /// because they could not be read/parsed at all. Never rewritten.
  final int refused;

  /// Files carrying no proof bytes (the dev proofless flag) — nothing to
  /// re-derive from, so nothing to check against.
  final int proofless;

  /// True when the version marker already recorded this migration and the
  /// pass returned without touching the library.
  final bool skipped;

  @override
  String toString() => skipped
      ? 'SpellSemanticsMigrationReport(skipped)'
      : 'SpellSemanticsMigrationReport(scanned: $scanned, '
          'repaired: $repaired, refused: $refused, proofless: $proofless)';
}

Future<Directory> _spellsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/spells');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<File> _markerFile() async =>
    File('${(await _spellsDir()).path}/_semantics_migration.txt');

Future<int?> _migratedVersion() async {
  final file = await _markerFile();
  if (!await file.exists()) return null;
  return int.tryParse((await file.readAsString()).trim());
}

/// Audits every installed spell against its own proof and rewrites the three
/// derivable fields of any that disagree.
///
/// Skipped entirely (returns `skipped: true`) when the on-disk marker already
/// records a version >= [kSpellSemanticsMigrationVersion], unless [force].
///
/// Best-effort per file: an unreadable or unparseable asset is counted as
/// refused and the pass continues, so one bad file cannot leave the rest of
/// the library un-migrated. The marker is written only after a completed
/// pass — if the pass throws, the next launch retries it.
Future<SpellSemanticsMigrationReport> migrateSpellSemantics({
  bool force = false,
}) async {
  if (!force) {
    final done = await _migratedVersion();
    if (done != null && done >= kSpellSemanticsMigrationVersion) {
      return const SpellSemanticsMigrationReport(skipped: true);
    }
  }

  final dir = await _spellsDir();
  final files = await dir
      .list()
      .where((e) => e is File && e.path.endsWith('.json'))
      .cast<File>()
      .toList();

  var scanned = 0;
  var repaired = 0;
  var refused = 0;
  var proofless = 0;

  for (final file in files) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      continue; // not a spell asset; not this migration's business
    }
    // The same shape test the off-device auditor uses: a spell asset is a
    // map carrying proof bytes and a generation count.
    if (!json.containsKey('proofBytesBase64') || !json.containsKey('t')) {
      continue;
    }
    scanned++;

    if ((json['proofBytesBase64'] as String? ?? '').isEmpty) {
      proofless++;
      continue;
    }

    try {
      if (auditSpellJson(json).isEmpty) continue;
      final fixed = repairSpellJson(json);
      // Compact, matching SpellAsset.save() — this file was written by
      // save() and must stay byte-comparable with one.
      await file.writeAsString(jsonEncode(fixed));
      repaired++;
    } catch (_) {
      // SpellSemanticsUnavailable (proof unparseable, or contradicting the
      // asset's identity), or a malformed field the audit tripped over.
      // Left exactly as it was found.
      refused++;
    }
  }

  await (await _markerFile())
      .writeAsString('$kSpellSemanticsMigrationVersion');

  return SpellSemanticsMigrationReport(
    scanned: scanned,
    repaired: repaired,
    refused: refused,
    proofless: proofless,
  );
}
