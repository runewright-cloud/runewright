// scripts/gen_vectors.dart — turns test_vectors/seeds.json into
// test_vectors/corpus.json, per GOLDEN_VECTORS.md §4.
//
// Two-oracle discipline (GOLDEN_VECTORS.md §0.1):
//   - CA outputs (border_activations, dominance_trajectory,
//     supreme_dominance_flags, segment_count, dot_count) come from the Dart
//     stepper (runStepper / gridGeometry), never from the circuit's own output.
//   - commitment comes from the Noir circuit (nargo execute), never Dart.
//   - The circuit's segment_count/dot_count outputs are cross-checked against
//     the Dart oracle; a mismatch is a release blocker (same as CA outputs).
//
// Run with: dart run scripts/gen_vectors.dart [--tier=12|24|48]
//           --tier=12 (default) writes test_vectors/corpus.json
//           --tier=24            writes test_vectors/corpus_tier24.json
//           --tier=48            writes test_vectors/corpus_tier48.json
//
// For backward compat, --tier12-dir=<path> still overrides the tier-12 circuit path.
//
// owner_pubkey / key_hi / key_lo: no identity module exists yet (CLAUDE.md
// scope fence). Every vector's witness uses the interim zero keys; the
// circuit-side dummy owner_pubkey = poseidon2_hash2(0, 0), pinned in
// CIRCUIT_IO.md §5/§9. Each seed's owner_pubkey_hex field is reserved for
// the future identity module and is not yet consumed here.

import 'dart:convert';
import 'dart:io';

import 'package:rune_duel/engine/ca_run.dart';

const int gridSize = 469;

// poseidon2_hash2(0, 0), computed via /tmp/poseidon_probe and pinned in
// CIRCUIT_IO.md §5. Must match circuits/ca_v2_4_tier12/src/main.nr's
// poseidon2_hash2 helper exactly — if that helper changes, regenerate this.
const String dummyOwnerPubkey =
    '0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1';

List<int> _expandGrid(List<dynamic> activeCells, Map<String, dynamic>? rawOverrides) {
  final grid = List<int>.filled(gridSize, 0);
  for (final c in activeCells) {
    grid[c as int] = 1;
  }
  if (rawOverrides != null) {
    rawOverrides.forEach((idxStr, value) {
      grid[int.parse(idxStr)] = value as int;
    });
  }
  return grid;
}

String _proverToml({
  required int t,
  required int rulesetVersion,
  required List<int> grid,
}) {
  final buf = StringBuffer();
  buf.writeln('T = "$t"');
  buf.writeln('owner_pubkey = "$dummyOwnerPubkey"');
  buf.writeln('ruleset_version = "$rulesetVersion"');
  buf.writeln('key_hi = "0"');
  buf.writeln('key_lo = "0"');
  buf.writeln('grid_state = [${grid.join(', ')}]');
  return buf.toString();
}

class NargoResult {
  final bool success;
  final String stdout;
  final String stderr;
  NargoResult(this.success, this.stdout, this.stderr);
}

NargoResult _runNargoExecute(String circuitDir, String proverToml) {
  final proverPath = '$circuitDir/Prover.toml';
  final backup = File(proverPath).existsSync() ? File(proverPath).readAsStringSync() : null;
  File(proverPath).writeAsStringSync(proverToml);
  try {
    // Default to $PATH lookup (noirup installs to ~/.nargo/bin); run_vectors.sh
    // passes NARGO_BIN through explicitly.
    final nargoBin = Platform.environment['NARGO_BIN'] ?? 'nargo';
    final result = Process.runSync(
      nargoBin,
      ['execute', '--silence-warnings'],
      workingDirectory: circuitDir,
    );
    final success = result.exitCode == 0;
    return NargoResult(success, result.stdout.toString(), result.stderr.toString());
  } finally {
    if (backup != null) File(proverPath).writeAsStringSync(backup);
  }
}

// Parses nargo execute's
// "Circuit output: (0x.., [..], [..], [..], 0x.., 0x..)" line into
// (commitment, border_activations, dominance_trajectory, supreme_flags,
//  segmentCount, dotCount).
({
  String commitment,
  List<int> borderActivations,
  List<int> trajectory,
  List<int> supreme,
  int segmentCount,
  int dotCount,
}) _parseCircuitOutput(String stdout) {
  final line = stdout.split('\n').firstWhere(
        (l) => l.contains('Circuit output:'),
        orElse: () => '',
      );
  if (line.isEmpty) {
    throw FormatException('No "Circuit output:" line found in nargo stdout:\n$stdout');
  }
  final tupleStr = line.substring(line.indexOf('(') + 1, line.lastIndexOf(')'));
  // Split on commas that are NOT inside brackets.
  final parts = <String>[];
  var depth = 0;
  var cur = StringBuffer();
  for (final ch in tupleStr.split('')) {
    if (ch == '[') depth++;
    if (ch == ']') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(cur.toString());
      cur = StringBuffer();
    } else {
      cur.write(ch);
    }
  }
  parts.add(cur.toString());
  if (parts.length != 6) {
    throw FormatException(
        'Expected 6-element circuit output tuple, got ${parts.length}: $parts');
  }

  List<int> parseArr(String s) {
    final inner = s.trim().substring(1, s.trim().length - 1);
    if (inner.trim().isEmpty) return [];
    return inner.split(',').map((v) => int.parse(v.trim())).toList();
  }

  return (
    commitment: parts[0].trim(),
    borderActivations: parseArr(parts[1]),
    trajectory: parseArr(parts[2]),
    supreme: parseArr(parts[3]),
    // nargo outputs scalar Fields as hex (e.g. 0x04); int.parse handles 0x.
    segmentCount: int.parse(parts[4].trim()),
    dotCount: int.parse(parts[5].trim()),
  );
}

void main(List<String> args) {
  var selectedTier = 12;
  var tier12DirOverride = '';
  for (final a in args) {
    if (a.startsWith('--tier=')) selectedTier = int.parse(a.substring('--tier='.length));
    if (a.startsWith('--tier12-dir=')) tier12DirOverride = a.substring('--tier12-dir='.length);
  }

  final tierDir = tier12DirOverride.isNotEmpty
      ? tier12DirOverride
      : 'circuits/ca_v2_4_tier$selectedTier';
  final corpusPath = selectedTier == 12
      ? 'test_vectors/corpus.json'
      : 'test_vectors/corpus_tier$selectedTier.json';

  final seedsJson = jsonDecode(File('test_vectors/seeds.json').readAsStringSync())
      as Map<String, dynamic>;
  final vectors = seedsJson['vectors'] as List<dynamic>;

  final out = <Map<String, dynamic>>[];
  var failures = 0;

  for (final raw in vectors) {
    final v = raw as Map<String, dynamic>;
    final id = v['id'] as String;
    final kind = v['kind'] as String;
    final input = v['input'] as Map<String, dynamic>;
    final activeCells = input['active_cells'] as List<dynamic>;
    final t = input['T'] as int;
    final rulesetVersion = input['ruleset_version'] as int;
    final rawOverrides = v['raw_overrides'] as Map<String, dynamic>?;
    final declaredOverride = v['declared_override'] as Map<String, dynamic>?;

    // Seeds declare tier_max=12 (the minimum tier they're meaningful for).
    // For higher tiers, all these seeds are valid since T <= 12 <= selectedTier.
    // Negative T-range vectors are tier-specific: neg_out_of_range_T_too_large
    // uses T=13 which is only invalid at tier-12; skip it for higher tiers.
    if (id == 'neg_out_of_range_T_too_large' && selectedTier > 12) {
      stdout.writeln('SKIP $id: T=$t is in-range for tier-$selectedTier (tier-specific negative)');
      continue;
    }
    // For any seed with T > selectedTier (shouldn't happen with current seeds), skip.
    if (t > selectedTier && kind == 'positive') {
      stdout.writeln('SKIP $id: T=$t exceeds tier_max=$selectedTier');
      continue;
    }
    // Use selectedTier as the effective tierMax for stepper and corpus output.
    final tierMax = selectedTier;

    final grid = _expandGrid(activeCells, rawOverrides);

    if (kind == 'positive') {
      // Oracle #1 (Dart stepper) for CA outputs.
      final tIsInRange = t >= 1 && t <= tierMax;
      if (!tIsInRange) {
        stdout.writeln('FAIL $id: positive vector has out-of-range T=$t');
        failures++;
        continue;
      }
      final stepperResult = runStepper(grid, t, tierMax);

      // Oracle #2 (Noir circuit) for the commitment + cross-check of CA outputs.
      final proverToml = _proverToml(t: t, rulesetVersion: rulesetVersion, grid: grid);
      final result = _runNargoExecute(tierDir, proverToml);
      if (!result.success) {
        stdout.writeln('FAIL $id: expected nargo execute to SUCCEED but it failed.\n${result.stderr}');
        failures++;
        continue;
      }
      final parsed = _parseCircuitOutput(result.stdout);

      final mismatches = <String>[];
      if (!_listEq(parsed.borderActivations, stepperResult.borderActivations)) {
        mismatches.add('border_activations: circuit=${parsed.borderActivations} stepper=${stepperResult.borderActivations}');
      }
      if (!_listEq(parsed.trajectory, stepperResult.dominanceTrajectory)) {
        mismatches.add('dominance_trajectory: circuit=${parsed.trajectory} stepper=${stepperResult.dominanceTrajectory}');
      }
      if (!_listEq(parsed.supreme, stepperResult.supremeFlags)) {
        mismatches.add('supreme_dominance_flags: circuit=${parsed.supreme} stepper=${stepperResult.supremeFlags}');
      }
      if (parsed.segmentCount != stepperResult.segmentCount) {
        mismatches.add('segment_count: circuit=${parsed.segmentCount} stepper=${stepperResult.segmentCount}');
      }
      if (parsed.dotCount != stepperResult.dotCount) {
        mismatches.add('dot_count: circuit=${parsed.dotCount} stepper=${stepperResult.dotCount}');
      }
      if (mismatches.isNotEmpty) {
        stdout.writeln('FAIL $id: circuit/stepper mismatch:\n  ${mismatches.join('\n  ')}');
        failures++;
        continue;
      }

      stdout.writeln('OK   $id (positive): commitment=${parsed.commitment} seg=${stepperResult.segmentCount} dot=${stepperResult.dotCount}');
      out.add({
        'id': id,
        'kind': kind,
        'tier_max': tierMax,
        'input': input,
        'expected': {
          'commitment': parsed.commitment,
          'border_activations': stepperResult.borderActivations,
          'dominance_trajectory': stepperResult.dominanceTrajectory,
          'supreme_dominance_flags': stepperResult.supremeFlags,
          'segment_count': stepperResult.segmentCount,
          'dot_count': stepperResult.dotCount,
          'verifies': true,
        },
      });
    } else {
      // Negative vector with a declared_override: this tests SNARK
      // public-input binding (does bb verify reject a tampered proof?), not
      // a Runewright circuit constraint. border_activations/trajectory/
      // commitment are return values, not inputs, so nargo execute
      // structurally cannot accept a "declared" lie — the relevant §10.4/
      // §10.5/§10.6 property is enforced by construction and discharged by
      // the positive vectors' exact circuit-vs-stepper match. The remaining
      // "tampered proof gets rejected" half is deferred to a single
      // end-to-end bb prove/tamper/verify smoke test in M3.4 (see seeds.json
      // for which positive vector discharges each one).
      if (declaredOverride != null) {
        stdout.writeln('SKIP $id (negative): SNARK public-input-binding check, '
            'not a circuit-constraint vector — see seeds.json description for '
            'which positive vector discharges it. Deferred to the M3.4 tamper smoke test.');
        out.add({
          'id': id,
          'kind': kind,
          'tier_max': tierMax,
          'input': input,
          'declared_override': declaredOverride,
          'violates_constraint': v['violates_constraint'],
          'expected': {'verifies': false},
          'status': 'SNARK_BINDING_CHECK_DEFERRED_TO_M3.4_TAMPER_SMOKE_TEST',
        });
        continue;
      }

      final proverToml = _proverToml(t: t, rulesetVersion: rulesetVersion, grid: grid);
      final result = _runNargoExecute(tierDir, proverToml);
      if (result.success) {
        stdout.writeln('FAIL $id: expected nargo execute to FAIL (negative vector) but it SUCCEEDED. '
            'This is a release-blocking bug — the circuit accepted a witness it should reject.');
        failures++;
        continue;
      }
      stdout.writeln('OK   $id (negative): witness generation correctly failed.');
      out.add({
        'id': id,
        'kind': kind,
        'tier_max': tierMax,
        'input': input,
        'raw_overrides': rawOverrides,
        'violates_constraint': v['violates_constraint'],
        'expected': {'verifies': false},
      });
    }
  }

  File(corpusPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));

  stdout.writeln('\n${out.length} vectors written to $corpusPath, $failures failure(s).');
  if (failures > 0) exit(1);
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
