// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_calibration.dart — offline diagnostic + threshold-calibration harness
// for Practice Mode vocal scoring, run against REAL per-user data (enrollment
// templates + optional recorded attempt clips) instead of the Piper proxies
// real_template_e2e_test.dart uses.
//
// NOT a CI test (no _test.dart suffix → the default `flutter test` glob skips
// it). Run explicitly, passing dirs via --dart-define:
//
//   flutter test test/practice/vocal_calibration.dart \
//     --dart-define=ENROLL_DIR=/abs/path/to/enroll \
//     [--dart-define=ATTEMPTS_DIR=/abs/path/to/attempts]
//
//   ENROLL_DIR    dir of <word>.json enrollment templates ({"frames":[[..]]}),
//                 pulled via: adb shell run-as com.runeduel.rune_duel \
//                   cat app_flutter/practice_enrollment/<word>.json
//   ATTEMPTS_DIR  optional dir of attempt clips named <word>[_<n>].wav
//                 (PCM-16 mono, any rate — resampled to 16k). When present,
//                 each clip runs through the REAL StreamingPhonemeScorer and
//                 a floor/margin/debounce grid search is reported.
//
// It runs under `flutter test` (not `dart run`) because the scorer's
// template source transitively imports package:flutter/services → dart:ui.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/practice/streaming_phoneme_scorer.dart';
import 'package:rune_duel/practice/vocal_enrollment.dart';
import 'package:rune_duel/practice/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

const _enrollDir = String.fromEnvironment('ENROLL_DIR');
const _attemptsDir = String.fromEnvironment('ATTEMPTS_DIR');

/// When set, ignore ENROLL_DIR and instead DERIVE a template per word from
/// its attempt clips (the median-length clip, trimmed + MFCC'd exactly as
/// VocalEnrollment does), using the remaining clips of that word as queries.
/// Simulates "what if enrollment were captured the same brisk hold-to-record
/// way as the attempts" — a zero-rebuild validation of the pace hypothesis.
const _deriveTemplates = bool.fromEnvironment('DERIVE_TEMPLATES');

/// Skip the (slow, ~2000-run) grid search and print only the separability
/// matrix + attempt-ranking snapshot — the fast, decisive outputs. The grid
/// is worth running only once the rankings say discrimination is viable.
const _skipGrid = bool.fromEnvironment('SKIP_GRID');

/// When set (with ATTEMPTS_DIR), run the multi-exemplar leave-one-out
/// ranking (recommendation #1: score against a SET of same-word exemplars,
/// min distance over the set) instead of the single-median-template mode.
/// Takes priority over DERIVE_TEMPLATES.
const _multiExemplar = bool.fromEnvironment('MULTI_EXEMPLAR');

/// Append delta (Δ) coefficients (MfccExtractor.deltas) to the static
/// c0-dropped features before CMN/DTW — an offline A/B toggle to validate
/// whether transition dynamics fix confusable pairs (aqua/terra, ignis/
/// ventus) BEFORE wiring deltas into the live scorer. See mfcc.dart's
/// deltas() doc for why.
const _useDeltas = bool.fromEnvironment('USE_DELTAS');

/// Scale applied to the delta block before concatenation. Deltas are
/// differences over a ~20ms window and have much smaller natural magnitude
/// than static coefficients, so raw (1.0) concatenation lets statics
/// dominate an unweighted Euclidean DTW distance — this lets the offline A/B
/// test whether up-weighting the delta stream changes the outcome.
final _deltaWeight =
    double.tryParse(const String.fromEnvironment('DELTA_WEIGHT')) ?? 1.0;

List<List<double>> _maybeAddDeltas(List<List<double>> dropC0Frames) {
  if (!_useDeltas || dropC0Frames.isEmpty) return dropC0Frames;
  final d = MfccExtractor.deltas(dropC0Frames);
  return [
    for (int t = 0; t < dropC0Frames.length; t++)
      [...dropC0Frames[t], ...d[t].map((v) => v * _deltaWeight)],
  ];
}

// ── Scorer-identical preprocessing (mirrors streaming_phoneme_scorer.dart) ──

List<double> _dropC0(List<double> f) => f.sublist(1);
List<List<double>> _dropC0All(List<List<double>> fs) => fs.map(_dropC0).toList();

List<List<double>> _cmn(List<List<double>> frames) {
  if (frames.isEmpty) return frames;
  final dims = frames.first.length;
  final mean = List<double>.filled(dims, 0.0);
  for (final f in frames) {
    for (int d = 0; d < dims; d++) {
      mean[d] += f[d];
    }
  }
  for (int d = 0; d < dims; d++) {
    mean[d] /= frames.length;
  }
  return [
    for (final f in frames) [for (int d = 0; d < dims; d++) f[d] - mean[d]],
  ];
}

/// cost/steps of query [q] (raw c0-dropped frames) against CMN'd ref [refCmn],
/// using ref's own 2x sliding window cap — identical to the scorer's
/// _windowQuality against a full-length query.
double _quality(List<List<double>> q, List<List<double>> refCmn) {
  final start = math.max(0, q.length - refCmn.length * 2);
  final window = _cmn(q.sublist(start));
  final r = DtwMatcher.distanceWithSteps(window, refCmn);
  return r.cost / r.steps;
}

Map<VocalWord, List<List<double>>> _loadEnroll(String dir) {
  final out = <VocalWord, List<List<double>>>{};
  for (final w in VocalWord.values) {
    final f = File('$dir/${w.name}.json');
    if (!f.existsSync()) {
      stderr.writeln('WARNING: missing enrollment ${f.path}');
      continue;
    }
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    out[w] = (json['frames'] as List)
        .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
        .toList();
  }
  return out;
}

void _printSeparabilityMatrix(Map<VocalWord, List<List<double>>> enroll) {
  final words = enroll.keys.toList();
  final rawQ = {
    for (final w in words) w: _maybeAddDeltas(_dropC0All(enroll[w]!)),
  };
  final refCmn = {
    for (final w in words) w: _cmn(_maybeAddDeltas(_dropC0All(enroll[w]!))),
  };

  stdout.writeln('\n=== Template separability (cost/steps; row=spoken, '
      'col=reference; lower=closer) ===');
  stdout.write('spoken'.padRight(9));
  for (final w in words) {
    stdout.write(w.name.padLeft(9));
  }
  stdout.writeln('   nearest-non-self   margin');

  for (final spoken in words) {
    stdout.write(spoken.name.padRight(9));
    final scores = <VocalWord, double>{};
    for (final ref in words) {
      final q = _quality(rawQ[spoken]!, refCmn[ref]!);
      scores[ref] = q;
      stdout.write(q.toStringAsFixed(2).padLeft(9));
    }
    final others = scores.entries.where((e) => e.key != spoken).toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final bestOther = others.first;
    final margin = bestOther.value - scores[spoken]!;
    stdout.writeln('   ${bestOther.key.name.padRight(10)} '
        '${bestOther.value.toStringAsFixed(2)}  '
        '${margin >= 0 ? '+' : ''}${margin.toStringAsFixed(2)}');
  }
  stdout.writeln('\nSelf-column is a single exemplar vs itself (~0); the '
      'informative cells are off-diagonal cross-distances and each row\'s '
      'nearest non-self competitor. A nearest-competitor below the shipped '
      '0.9 margin means those references are intrinsically confusable '
      'regardless of threshold.');
}

// ── WAV loading (PCM-16 mono, resample to 16k) ──────────────────────────────

Uint8List _pcmFromWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  int off = 12;
  int rate = 16000;
  Uint8List? data;
  while (off + 8 <= bytes.length) {
    final id = ascii.decode(bytes.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') rate = bd.getUint32(off + 12, Endian.little);
    if (id == 'data') data = bytes.sublist(off + 8, off + 8 + size);
    off += 8 + size + (size & 1);
  }
  if (data == null) throw StateError('no data chunk in $path');
  if (rate == 16000) return data;
  final srcBd = ByteData.sublistView(data);
  final srcLen = data.length ~/ 2;
  final dstLen = (srcLen * 16000 / rate).floor();
  final out = ByteData(dstLen * 2);
  for (int i = 0; i < dstLen; i++) {
    final p = i * rate / 16000;
    final i0 = p.floor();
    final i1 = math.min(i0 + 1, srcLen - 1);
    final frac = p - i0;
    final s = srcBd.getInt16(i0 * 2, Endian.little) * (1 - frac) +
        srcBd.getInt16(i1 * 2, Endian.little) * frac;
    out.setInt16(i * 2, s.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Backs the streaming scorer with either a single template per word
/// (legacy grid) or a multi-take exemplar SET per word (multi-exemplar grid).
class _EnrollSource implements VocalTemplateSource {
  _EnrollSource(Map<VocalWord, List<List<double>>> enroll)
      : sets = {for (final e in enroll.entries) e.key: [e.value]};
  _EnrollSource.sets(this.sets);

  final Map<VocalWord, List<List<List<double>>>> sets;

  VocalTemplate _tpl(VocalWord word, List<List<double>> frames) => VocalTemplate(
        word: word,
        mfccFrames: frames,
        checkpointFrameIndices: [frames.length - 1],
        checkpointLabels: [word.name],
      );

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async =>
      _tpl(word, sets[word]!.first);

  @override
  Future<List<VocalTemplate>> templatesFor(VocalWord word) async =>
      [for (final f in sets[word]!) _tpl(word, f)];
}

/// Leave-one-out: build a template per word from its median-length attempt
/// clip (trimmed + MFCC'd like enrollment), returning (derivedEnroll,
/// remainingQueries). Simulates same-pace hold-to-record enrollment.
({
  Map<VocalWord, List<List<double>>> enroll,
  List<({VocalWord word, String path})> queries,
}) _deriveFromClips(List<({VocalWord word, String path})> all) {
  final byWord = <VocalWord, List<String>>{};
  for (final a in all) {
    byWord.putIfAbsent(a.word, () => []).add(a.path);
  }
  final enroll = <VocalWord, List<List<double>>>{};
  final queries = <({VocalWord word, String path})>[];
  for (final entry in byWord.entries) {
    final paths = entry.value..sort();
    // Extract trimmed MFCC for each clip; pick the median by frame count as
    // the template (avoids the too-long "getting used to it" first take and
    // any too-short clip).
    final framed = [
      for (final p in paths)
        (path: p, frames: MfccExtractor.extract(
            VocalEnrollment.trimSilence(_pcmFromWav(p)))),
    ]..sort((a, b) => a.frames.length.compareTo(b.frames.length));
    final templateIdx = framed.length ~/ 2; // median
    enroll[entry.key] = framed[templateIdx].frames;
    for (int i = 0; i < framed.length; i++) {
      if (i == templateIdx) continue;
      queries.add((word: entry.key, path: framed[i].path));
    }
  }
  return (enroll: enroll, queries: queries);
}

/// Multi-exemplar leave-one-out (recommendation #1: does scoring against a
/// SET of same-word exemplars — min distance over the set — stabilize the
/// confusable pairs, without any new features?). For each clip of word W
/// held out as the query: W's template SET is its OTHER clips (no leakage);
/// every OTHER word's template SET is ALL of its clips (no leakage risk,
/// different word). Distance to a word = min cost/steps over its set.
void _printMultiExemplarRankings(List<({VocalWord word, String path})> all) {
  final byWord = <VocalWord, List<String>>{};
  for (final a in all) {
    byWord.putIfAbsent(a.word, () => []).add(a.path);
  }
  // Precompute each clip's trimmed, c0-dropped, delta-augmented, CMN'd
  // reference frames once (used both as a template and, for the raw
  // query side, the pre-CMN dropC0+delta frames).
  final refByPath = <String, List<List<double>>>{};
  final rawByPath = <String, List<List<double>>>{};
  for (final paths in byWord.values) {
    for (final p in paths) {
      final raw = _maybeAddDeltas(
          _dropC0All(MfccExtractor.extract(VocalEnrollment.trimSilence(_pcmFromWav(p)))));
      rawByPath[p] = raw;
      refByPath[p] = _cmn(raw);
    }
  }

  stdout.writeln('\n=== Multi-exemplar leave-one-out (min distance over '
      'same-word exemplar SET; lower=closer) ===');
  stdout.write('attempt'.padRight(10));
  final words = byWord.keys.toList();
  for (final w in words) {
    stdout.write(w.name.padLeft(9));
  }
  stdout.writeln('   argmin   target-margin');

  int correct = 0, total = 0;
  for (final word in words) {
    final paths = byWord[word]!;
    for (final heldOut in paths) {
      total++;
      final query = rawByPath[heldOut]!;
      final scores = <VocalWord, double>{};
      for (final w in words) {
        final setPaths = w == word
            ? paths.where((p) => p != heldOut).toList()
            : byWord[w]!;
        var best = double.infinity;
        for (final p in setPaths) {
          final q = _quality(query, refByPath[p]!);
          if (q < best) best = q;
        }
        scores[w] = best;
      }
      stdout.write(word.name.padRight(10));
      for (final w in words) {
        stdout.write(scores[w]!.toStringAsFixed(2).padLeft(9));
      }
      final ranked = scores.entries.toList()
        ..sort((x, y) => x.value.compareTo(y.value));
      final argmin = ranked.first.key;
      final targetScore = scores[word]!;
      final bestOther = scores.entries
          .where((e) => e.key != word)
          .map((e) => e.value)
          .reduce(math.min);
      final margin = bestOther - targetScore;
      final flag = argmin == word ? 'OK ' : 'MISS';
      if (argmin == word) correct++;
      stdout.writeln('   ${argmin.name.padRight(8)} '
          '$flag ${margin >= 0 ? '+' : ''}${margin.toStringAsFixed(2)}');
    }
  }
  stdout.writeln('\n$correct/$total correct (argmin == target).');
}

List<({VocalWord word, String path})> _loadAttempts(String dir) {
  final out = <({VocalWord word, String path})>[];
  for (final f in Directory(dir).listSync().whereType<File>()) {
    if (!f.path.toLowerCase().endsWith('.wav')) continue;
    final base = f.uri.pathSegments.last.replaceAll('.wav', '');
    final word =
        VocalWord.values.where((w) => w.name == base.split('_').first).firstOrNull;
    if (word == null) {
      stderr.writeln('skip (name not a VocalWord): ${f.path}');
      continue;
    }
    out.add((word: word, path: f.path));
  }
  return out;
}

Future<bool> _runOne(
  Map<VocalWord, List<List<double>>> enroll,
  VocalWord target,
  Uint8List pcm, {
  required double floor,
  required int debounce,
  required double margin,
}) async {
  final scorer = StreamingPhonemeScorer(
    templateSource: _EnrollSource(enroll),
    checkpointFloor: floor,
    debounceFrames: debounce,
    contrastiveMargin: margin,
  );
  await scorer.beginFormula(PracticeFormula([target]));
  final silence = Uint8List(8000 * 2);
  void feed(Uint8List a) {
    for (int o = 0; o < a.length && !scorer.isComplete; o += 640) {
      final e = (o + 640).clamp(0, a.length);
      scorer.acceptPcmChunk(Uint8List.sublistView(a, o, e));
    }
  }

  feed(silence);
  feed(pcm);
  feed(silence);
  final done = scorer.isComplete;
  scorer.dispose();
  return done;
}

/// Fast, scorer-metric-identical snapshot: each real attempt clip scored
/// (whole-utterance cost/steps) against every enrolled template. Shows
/// directly whether the target wins the argmin on the real voice and by how
/// much — the core question, without the expensive streaming grid.
void _printAttemptRankings(
  Map<VocalWord, List<List<double>>> enroll,
  List<({VocalWord word, String path})> attempts,
) {
  final words = enroll.keys.toList();
  final refCmn = {
    for (final w in words) w: _cmn(_maybeAddDeltas(_dropC0All(enroll[w]!))),
  };

  stdout.writeln('\n=== Attempt rankings (real clip vs every template; '
      'cost/steps, lower=closer) ===');
  stdout.write('attempt'.padRight(10));
  for (final w in words) {
    stdout.write(w.name.padLeft(9));
  }
  stdout.writeln('   argmin   target-margin');

  for (final a in attempts) {
    final q =
        _maybeAddDeltas(_dropC0All(MfccExtractor.extract(_pcmFromWav(a.path))));
    stdout.write(a.word.name.padRight(10));
    final scores = <VocalWord, double>{};
    for (final w in words) {
      final s = _quality(q, refCmn[w]!);
      scores[w] = s;
      stdout.write(s.toStringAsFixed(2).padLeft(9));
    }
    final ranked = scores.entries.toList()
      ..sort((x, y) => x.value.compareTo(y.value));
    final argmin = ranked.first.key;
    // Margin the TARGET has over its best competitor (positive = target is
    // best and leads by this much; negative = a wrong word beat the target).
    final targetScore = scores[a.word]!;
    final bestOther = scores.entries
        .where((e) => e.key != a.word)
        .map((e) => e.value)
        .reduce(math.min);
    final margin = bestOther - targetScore;
    final flag = argmin == a.word ? 'OK ' : 'MISS';
    stdout.writeln('   ${argmin.name.padRight(8)} '
        '$flag ${margin >= 0 ? '+' : ''}${margin.toStringAsFixed(2)}');
  }
  stdout.writeln('\nargmin=target (OK) means the right word is the closest '
      'match; target-margin is how far it leads the best wrong word (must '
      'exceed the contrastive margin to cross). Negative margin = the scorer '
      'genuinely hears another word as closer.');
}

Future<void> _gridSearch(
  Map<VocalWord, List<List<double>>> enroll,
  List<({VocalWord word, String path})> attempts,
) async {
  final pcm = {for (final a in attempts) a.path: _pcmFromWav(a.path)};

  stdout.writeln('\n=== Per-attempt result at shipped constants '
      '(floor 6.25 / margin 0.9 / debounce 8) ===');
  for (final a in attempts) {
    final ok = await _runOne(enroll, a.word, pcm[a.path]!,
        floor: 6.25, debounce: 8, margin: 0.9);
    final wrongWins = <String>[];
    for (final other in VocalWord.values) {
      if (other == a.word) continue;
      if (await _runOne(enroll, other, pcm[a.path]!,
          floor: 6.25, debounce: 8, margin: 0.9)) {
        wrongWins.add(other.name);
      }
    }
    stdout.writeln('  ${a.word.name.padRight(9)} '
        '${ok ? 'COMPLETES' : 'stalls   '}'
        '${wrongWins.isEmpty ? '' : '   ALSO accepted-as: ${wrongWins.join(",")}'}');
  }

  stdout.writeln('\n=== Grid search (want: max correct complete, 0 wrong) ===');
  stdout.writeln('floor  margin  deb   correct/total   wrongAccepts');
  const floors = [6.5, 7.5, 8.5, 10.0, 12.0];
  const margins = [0.3, 0.5, 0.75, 0.9];
  const debounces = [8];
  final results = <({double f, double m, int d, int ok, int tot, int wrong})>[];

  for (final f in floors) {
    for (final m in margins) {
      for (final d in debounces) {
        int ok = 0, tot = 0, wrong = 0;
        for (final a in attempts) {
          tot++;
          if (await _runOne(enroll, a.word, pcm[a.path]!,
              floor: f, debounce: d, margin: m)) {
            ok++;
          }
          for (final other in VocalWord.values) {
            if (other == a.word) continue;
            if (await _runOne(enroll, other, pcm[a.path]!,
                floor: f, debounce: d, margin: m)) {
              wrong++;
            }
          }
        }
        results.add((f: f, m: m, d: d, ok: ok, tot: tot, wrong: wrong));
        stdout.writeln('${f.toStringAsFixed(1).padLeft(4)}  '
            '${m.toStringAsFixed(2).padLeft(5)}  ${d.toString().padLeft(3)}   '
            '${'$ok/$tot'.padLeft(11)}   ${wrong.toString().padLeft(6)}');
      }
    }
  }

  final clean = results.where((r) => r.wrong == 0).toList()
    ..sort((a, b) {
      final byOk = b.ok.compareTo(a.ok);
      return byOk != 0 ? byOk : b.f.compareTo(a.f);
    });
  stdout.writeln('\n=== Recommendation ===');
  if (clean.isEmpty) {
    stdout.writeln('NO zero-false-advance operating point in the grid — the '
        'enrolled templates are not separable enough for this metric on this '
        'voice. Fix is length-normalization / better features / re-enrollment, '
        'NOT a threshold (see the separability matrix).');
  } else {
    final b = clean.first;
    stdout.writeln('floor ${b.f}, margin ${b.m}, debounce ${b.d}  '
        '-> ${b.ok}/${b.tot} correct, 0 wrong.');
  }
}

void main() {
  test('vocal calibration harness', () async {
    if (_multiExemplar) {
      if (_attemptsDir.isEmpty) {
        stdout.writeln('MULTI_EXEMPLAR needs ATTEMPTS_DIR. Skipping.');
        return;
      }
      final all = _loadAttempts(_attemptsDir);
      _printMultiExemplarRankings(all);
      return;
    }

    Map<VocalWord, List<List<double>>> enroll;
    List<({VocalWord word, String path})> attempts;

    if (_deriveTemplates) {
      if (_attemptsDir.isEmpty) {
        stdout.writeln('DERIVE_TEMPLATES needs ATTEMPTS_DIR. Skipping.');
        return;
      }
      final all = _loadAttempts(_attemptsDir);
      final derived = _deriveFromClips(all);
      enroll = derived.enroll;
      attempts = derived.queries;
      stdout.writeln('DERIVE_TEMPLATES: templates built from median attempt '
          'clip per word; remaining clips used as queries.');
      stdout.writeln('Derived ${enroll.length} templates:');
      for (final e in enroll.entries) {
        stdout.writeln('  ${e.key.name.padRight(9)} ${e.value.length} frames '
            '(template)');
      }
    } else {
      if (_enrollDir.isEmpty) {
        stdout.writeln('ENROLL_DIR not set — pass '
            '--dart-define=ENROLL_DIR=/abs/path. Skipping.');
        return;
      }
      enroll = _loadEnroll(_enrollDir);
      stdout.writeln('Loaded ${enroll.length} enrollment templates:');
      for (final e in enroll.entries) {
        stdout.writeln('  ${e.key.name.padRight(9)} ${e.value.length} frames');
      }
      attempts =
          _attemptsDir.isEmpty ? const [] : _loadAttempts(_attemptsDir);
    }

    _printSeparabilityMatrix(enroll);

    if (attempts.isNotEmpty) {
      stdout.writeln('\nUsing ${attempts.length} query clips.');
      _printAttemptRankings(enroll, attempts);
      if (_skipGrid) {
        stdout.writeln('\n(SKIP_GRID set — ranking snapshot only.)');
      } else {
        await _gridSearch(enroll, attempts);
      }
    } else {
      stdout.writeln('\n(No query clips — separability matrix only.)');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
