// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_replay_test.dart — runs every scripted match and checks its transcript
// against the checked-in golden.
//
// ## Regenerating
//
//     RUNEWRIGHT_REGEN_REPLAY=1 flutter test test/battle/replay/
//
// Regeneration is a deliberate, separate act — never something the test does
// for you on failure. A harness that silently rewrites its own expectations
// protects nothing. **Any golden diff must be read and justified in the commit
// that changes it**, exactly as with the circuit's vector corpus
// (GOLDEN_VECTORS.md).
//
// A diff here means one of three things, in descending order of likelihood:
//
//   1. You changed engine behaviour on purpose. Read the diff, confirm it says
//      what you meant, regenerate, and explain it in the commit message.
//   2. You changed engine behaviour by accident. This is the case the harness
//      exists for — especially during the TurnLoop refactor, where the
//      intended change is "same behaviour, different structure" and ANY diff
//      is a bug.
//   3. You changed the script or the summary extractor. Then the diff is
//      noise; prefer not to, since it costs the corpus its history.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'match_replay.dart';
import 'replay_scripts.dart';

/// Where the corpus lives, relative to the repo root (tests run from there).
const _goldenDir = 'test/battle/replay/golden';

bool get _regenerating =>
    Platform.environment['RUNEWRIGHT_REGEN_REPLAY'] == '1';

void main() {
  late List<MatchScript> scripts;

  setUpAll(() async {
    scripts = await allScripts();
  });

  test('the corpus is not empty', () {
    expect(scripts, isNotEmpty,
        reason: 'a replay harness with no scripts asserts nothing');
  });

  test('no golden is orphaned', () {
    // A golden with no script behind it is worse than no golden: it looks like
    // coverage in the directory listing and asserts nothing. This catches the
    // leftovers from a script that was renamed or withdrawn.
    final dir = Directory(_goldenDir);
    if (!dir.existsSync()) return;
    final names = {for (final s in scripts) '${s.name}.json'};
    final orphans = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.json') && !names.contains(f.uri.pathSegments.last))
          f.uri.pathSegments.last,
    ];
    expect(orphans, isEmpty,
        reason: 'goldens with no script: $orphans — delete them, or restore '
            'the script that produced them');
  });

  test('every script replays to its golden transcript', () async {
    final failures = <String>[];

    for (final script in scripts) {
      final transcript = await runMatchScript(script);
      final file = File('$_goldenDir/${script.name}.json');

      // Lockstep first, and independently of the golden: two devices that
      // disagree with EACH OTHER is a worse failure than disagreeing with a
      // recorded expectation, and it stays a failure even while regenerating.
      for (final record in transcript.records) {
        expect(record.inLockstep, isTrue,
            reason: 'script "${script.name}" turn ${record.turn}: the two '
                'devices produced different canonical state. This is the '
                '"state hash mismatch on turn N" banner, reproduced in a '
                'test — fix it before looking at the golden.');
      }

      final actual = transcript.toPrettyJson();

      if (_regenerating) {
        await file.parent.create(recursive: true);
        await file.writeAsString(actual);
        continue;
      }

      if (!file.existsSync()) {
        failures.add(
          'script "${script.name}" has no golden at ${file.path}. '
          'Generate it with: RUNEWRIGHT_REGEN_REPLAY=1 flutter test '
          'test/battle/replay/',
        );
        continue;
      }

      final expected = await file.readAsString();
      if (expected != actual) {
        failures.add(
          'script "${script.name}" no longer replays to its golden.\n'
          '${_firstDifference(expected, actual)}',
        );
      }
    }

    if (_regenerating) {
      // Deliberately fails: a green run would let a regeneration slip into a
      // normal test invocation unnoticed, and the whole point is that
      // rewriting expectations is a conscious act.
      fail('goldens regenerated — re-run without RUNEWRIGHT_REGEN_REPLAY to '
          'verify, and read the diff before committing it');
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });
}

/// Locates the first differing turn and renders both sides, so a failure names
/// the turn rather than dumping two JSON blobs at the reader.
String _firstDifference(String expected, String actual) {
  Map<String, Object?> parse(String s) =>
      jsonDecode(s) as Map<String, Object?>;

  final List<Object?> expectedTurns;
  final List<Object?> actualTurns;
  try {
    expectedTurns = parse(expected)['turns']! as List<Object?>;
    actualTurns = parse(actual)['turns']! as List<Object?>;
  } on Object {
    return 'golden is not readable JSON; regenerate it';
  }

  const encoder = JsonEncoder.withIndent('  ');
  for (var i = 0; i < expectedTurns.length && i < actualTurns.length; i++) {
    if (encoder.convert(expectedTurns[i]) != encoder.convert(actualTurns[i])) {
      return 'first difference at turn ${i + 1}:\n'
          '--- golden ---\n${encoder.convert(expectedTurns[i])}\n'
          '--- actual ---\n${encoder.convert(actualTurns[i])}';
    }
  }
  return 'turn counts differ: golden has ${expectedTurns.length}, '
      'actual has ${actualTurns.length}';
}
