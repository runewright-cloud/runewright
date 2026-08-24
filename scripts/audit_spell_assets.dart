// SPDX-License-Identifier: GPL-3.0-or-later
//
// audit_spell_assets.dart — does every spell in a library agree with its own
// proof? (M4.22, docs/M4_findings.md)
//
// `inscribeSpell` persists `formula`, `supremeTags` and `manaCost` from
// caller-supplied arguments without ever checking them against the proof it
// just generated, so a stale UI FormulaTracker can be written verbatim to disk.
// This walks a directory of `SpellAsset.toJson()` files and reports every asset
// whose authored metadata its own proof contradicts.
//
// Usage:
//
//   dart run scripts/audit_spell_assets.dart [path ...]        # report only
//   dart run scripts/audit_spell_assets.dart --fix [path ...]  # rewrite them
//
// Each path may be a directory (scanned for *.json) or a single .json file.
// Defaults to assets/basic_spells (the shipped bundle). Exit status is 1 when
// any mismatch is found, so this is usable as a gate.
//
// --fix rewrites ONLY the three derivable fields, in place. The grid, `t`, the
// commitment, the proof bytes, the spell's identity (`id`, `spellHashHex`) and
// the summon declaration (`isSummon`, `summonPersonality` — M4.19, a separate
// defect) are never touched. An asset whose proof disagrees with its IDENTITY
// is reported and refused, not repaired: that is not stale prose, that is the
// wrong proof.

import 'dart:convert';
import 'dart:io';

import 'package:rune_duel/spells/spell_asset_integrity.dart';

void main(List<String> args) {
  final fix = args.contains('--fix');
  final paths = args.where((a) => a != '--fix').toList();
  if (paths.isEmpty) paths.add('assets/basic_spells');

  final files = <File>[];
  for (final p in paths) {
    final dir = Directory(p);
    if (dir.existsSync()) {
      files.addAll(dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json')));
    } else if (File(p).existsSync()) {
      files.add(File(p));
    } else {
      stderr.writeln('Not found: $p');
      exit(2);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  var scanned = 0;
  var proofless = 0;
  var bad = 0;
  var repaired = 0;

  for (final file in files) {
    final raw = file.readAsStringSync();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      continue; // not a spell asset
    }
    if (!json.containsKey('proofBytesBase64') || !json.containsKey('t')) {
      continue;
    }
    scanned++;
    final name = (json['name'] as String?) ?? '(unnamed)';

    final List<SpellSemanticMismatch> faults;
    try {
      faults = auditSpellJson(json);
    } on SpellSemanticsUnavailable catch (e) {
      bad++;
      stdout.writeln('BAD  ${file.path}  "$name"\n       $e');
      continue;
    }
    if ((json['proofBytesBase64'] as String? ?? '').isEmpty) {
      proofless++;
      stdout.writeln('SKIP ${file.path}  "$name" — proofless (dev flag)');
      continue;
    }
    if (faults.isEmpty) {
      stdout.writeln('OK   ${file.path}  "$name"');
      continue;
    }

    bad++;
    stdout.writeln('BAD  ${file.path}  "$name"');
    for (final f in faults) {
      stdout.writeln('       $f');
    }

    if (!fix) continue;
    try {
      final repairedJson = repairSpellJson(json);
      // Re-encode in the style the file already used: `SpellAsset.save()`
      // writes compact JSON, `export_basic_spells.dart` writes it indented.
      // Matching it keeps a repair to a three-field diff instead of a
      // whole-file reflow.
      file.writeAsStringSync(raw.contains('\n')
          ? const JsonEncoder.withIndent('  ').convert(repairedJson)
          : jsonEncode(repairedJson));
      repaired++;
      stdout.writeln('     → repaired in place');
    } on SpellSemanticsUnavailable catch (e) {
      stdout.writeln('     → NOT repaired: $e');
    }
  }

  stdout.writeln('\n$scanned proof-backed spell(s) scanned, '
      '$bad inconsistent, $proofless proofless'
      '${fix ? ', $repaired repaired' : ''}.');
  exit(bad > repaired ? 1 : 0);
}
