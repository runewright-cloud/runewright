// SPDX-License-Identifier: GPL-3.0-or-later
//
// trajectory_histogram.dart — Phase 1 of docs/COUNTER_CHARM_KINSHIP_PLAN.md.
//
// Histograms two things over a corpus of spells:
//
//   1. The distribution of OPENING FORMULAS (the first 3 committed elements).
//      Counter charms match on a 3-element prefix, so a wildly non-uniform
//      opening distribution means a cheap charm covers more of the meta than
//      the 1-in-64 the plan's breadth argument assumes. Feeds `k` in §3.2.
//
//   2. The distribution of TRAJECTORY LENGTHS, to sanity-check the ≥9-element
//      kinship threshold (§2.6). If a large share of real spells land under 9
//      elements, the short-spell stacking exemption (§3.4, open question 1) is
//      a much bigger hole than it looks.
//
// Reads `formula` (the flat committed element sequence) straight out of spell
// JSON, so it needs no Flutter, no FFI, and no proof verification: the corpus
// is whatever files you point it at.
//
// Usage:
//
//   dart scripts/trajectory_histogram.dart [path ...]
//
// Each path may be:
//   • a spell asset JSON       (a map with a `formula` key)
//   • a library backup JSON    (a map with a `spells` list — what the Library's
//                               export produces; this is how you fold in the
//                               spells collected at a playtest)
//   • a directory              (scanned recursively for .json files)
//
// With no paths it defaults to assets/basic_spells/, the shipped set.

import 'dart:convert';
import 'dart:io';

const _elements = ['fire', 'air', 'water', 'earth'];

void main(List<String> args) {
  final paths = args.isEmpty ? ['assets/basic_spells'] : args;

  final spells = <_Spell>[];
  for (final p in paths) {
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.directory) {
      _collectDir(Directory(p), spells);
    } else if (type == FileSystemEntityType.file) {
      _collectFile(File(p), spells);
    } else {
      stderr.writeln('skipping (not found): $p');
    }
  }

  if (spells.isEmpty) {
    stderr.writeln('No spells found. Nothing to histogram.');
    exitCode = 1;
    return;
  }

  print('Corpus: ${spells.length} spells from ${paths.join(", ")}\n');
  _openingFormulaHistogram(spells);
  print('');
  _lengthHistogram(spells);
  print('');
  _kinshipThresholdSummary(spells);
}

// ── Corpus loading ───────────────────────────────────────────────────────────

class _Spell {
  _Spell(this.name, this.elements, this.isSummon);

  final String name;
  final List<String> elements;
  final bool isSummon;

  /// The leading complete formula, or null if the spell committed fewer than
  /// three elements (nothing a charm could ever match).
  String? get openingFormula =>
      elements.length < 3 ? null : elements.take(3).join('-');
}

void _collectDir(Directory dir, List<_Spell> out) {
  final entries = dir.listSync(recursive: true).whereType<File>();
  for (final f in entries) {
    if (f.path.endsWith('.json')) _collectFile(f, out);
  }
}

void _collectFile(File file, List<_Spell> out) {
  final Object? doc;
  try {
    doc = jsonDecode(file.readAsStringSync());
  } catch (_) {
    stderr.writeln('skipping (not JSON): ${file.path}');
    return;
  }
  if (doc is! Map<String, dynamic>) return;

  // A library backup carries a whole library under `spells`.
  final backup = doc['spells'];
  if (backup is List) {
    for (final s in backup) {
      if (s is Map<String, dynamic>) _addSpell(s, out);
    }
    return;
  }
  _addSpell(doc, out);
}

void _addSpell(Map<String, dynamic> json, List<_Spell> out) {
  final raw = json['formula'];
  if (raw is! List) return;
  final elements = raw
      .map((e) => e.toString().toLowerCase())
      .where(_elements.contains)
      .toList();
  out.add(_Spell(
    (json['name'] as String?) ?? '(unnamed)',
    elements,
    (json['isSummon'] as bool?) ?? false,
  ));
}

// ── Histograms ───────────────────────────────────────────────────────────────

void _openingFormulaHistogram(List<_Spell> spells) {
  final counts = <String, int>{};
  var tooShort = 0;
  for (final s in spells) {
    final opening = s.openingFormula;
    if (opening == null) {
      tooShort++;
      continue;
    }
    counts[opening] = (counts[opening] ?? 0) + 1;
  }

  final matchable = spells.length - tooShort;
  print('── Opening formula (first 3 committed elements) ──');
  print('matchable spells: $matchable of ${spells.length}'
      '${tooShort > 0 ? "  ($tooShort committed fewer than 3 elements)" : ""}');
  print('distinct openings seen: ${counts.length} of 64 possible\n');

  if (matchable == 0) return;

  final sorted = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  for (final e in sorted) {
    final pct = 100 * e.value / matchable;
    print('  ${e.key.padRight(20)} ${e.value.toString().padLeft(4)}  '
        '${pct.toStringAsFixed(1).padLeft(5)}%  ${_bar(pct)}');
  }

  // The number that actually feeds `k`: how much of the meta the single best
  // 3-element charm would cover.
  final top = sorted.first;
  print('\n  heaviest opening: ${top.key} covers '
      '${(100 * top.value / matchable).toStringAsFixed(1)}% of matchable spells');
  print('  uniform baseline would be ${(100 / 64).toStringAsFixed(1)}%');

  // First-element skew on its own — the FormulaTracker lead-change rule is the
  // suspected source of any non-uniformity (§2, breadth objection residual).
  final firsts = <String, int>{};
  for (final s in spells) {
    if (s.elements.isEmpty) continue;
    firsts[s.elements.first] = (firsts[s.elements.first] ?? 0) + 1;
  }
  final firstTotal = firsts.values.fold(0, (a, b) => a + b);
  if (firstTotal > 0) {
    print('\n  first element alone (uniform baseline 25.0%):');
    for (final el in _elements) {
      final n = firsts[el] ?? 0;
      print('    ${el.padRight(8)} ${n.toString().padLeft(4)}  '
          '${(100 * n / firstTotal).toStringAsFixed(1).padLeft(5)}%');
    }
  }
}

void _lengthHistogram(List<_Spell> spells) {
  print('── Trajectory length (committed elements) ──');
  final counts = <int, int>{};
  for (final s in spells) {
    counts[s.elements.length] = (counts[s.elements.length] ?? 0) + 1;
  }
  final lengths = counts.keys.toList()..sort();
  for (final len in lengths) {
    final n = counts[len]!;
    final pct = 100 * n / spells.length;
    final marker = len < 9 ? '  ← kinship-exempt (§2.6)' : '';
    print('  ${len.toString().padLeft(3)} elements  ${n.toString().padLeft(4)}  '
        '${pct.toStringAsFixed(1).padLeft(5)}%  ${_bar(pct)}$marker');
  }
}

void _kinshipThresholdSummary(List<_Spell> spells) {
  final short = spells.where((s) => s.elements.length < 9).length;
  final pct = 100 * short / spells.length;
  print('── Kinship threshold (§2.6, open question 1) ──');
  print('  under 9 elements: $short of ${spells.length} '
      '(${pct.toStringAsFixed(1)}%) — freely kin-stackable under §3.4');
  if (pct >= 50) {
    print('  ⚠ over half the corpus is exempt. Revisit open question 1 before');
    print('    treating the exemption as harmless.');
  }

  // Collision check: how often two DIFFERENT spells already share a trajectory.
  final byTrajectory = <String, List<String>>{};
  for (final s in spells) {
    if (s.elements.length < 9) continue;
    byTrajectory.putIfAbsent(s.elements.join('-'), () => []).add(s.name);
  }
  final collisions =
      byTrajectory.entries.where((e) => e.value.length > 1).toList();
  print('  ≥9-element trajectory collisions: ${collisions.length}');
  for (final c in collisions) {
    print('    ${c.value.join(", ")}');
  }
}

String _bar(double pct) => '█' * (pct / 2).round();
