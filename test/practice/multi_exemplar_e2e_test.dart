// SPDX-License-Identifier: GPL-3.0-or-later
//
// multi_exemplar_e2e_test.dart — end-to-end false-advance check for
// MULTI-exemplar template sets (2026-07-22 rework: StreamingPhonemeScorer
// scores min-distance over a word's exemplar SET, not one template — see
// docs/M4_findings.md). real_template_e2e_test.dart's golden corpus only
// ever exercised 1-element sets; this extends the same zero-false-advance
// guarantee to a 2-element set per word, built from data already committed
// under test/practice/fixtures/voices/ — no new fixtures needed.
//
// Template set per word: [bundled single-take template, lessac2 (same
// voice, different utterance)]. Adding a second exemplar is the SAFETY-
// relevant direction to prove here — more reference material per word is
// more surface for an accidental cross-word match. The completion-improves
// direction (multi-exemplar rescuing a correct word that a single brittle
// template rejects) is already demonstrated against Soren's own voice
// (25/25 leave-one-out, see docs/M4_findings.md 2026-07-22) — an automated
// Piper-only corpus can't reproduce that finding, since it needs genuine
// cross-take speaker variation, not multiple renders of one synthetic voice.
//
// Asserted: with these 2-element sets, every WRONG word (both lessac2 and
// amy queries) still stalls — the enlarged set introduces zero new false
// advances relative to the 1-element baseline in real_template_e2e_test.dart.

@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/practice/streaming_phoneme_scorer.dart';
import 'package:rune_duel/practice/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

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
    final srcPos = i * rate / 16000;
    final i0 = srcPos.floor();
    final i1 = math.min(i0 + 1, srcLen - 1);
    final frac = srcPos - i0;
    final s = srcBd.getInt16(i0 * 2, Endian.little) * (1 - frac) +
        srcBd.getInt16(i1 * 2, Endian.little) * frac;
    out.setInt16(i * 2, s.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// [VocalTemplateSource] backed by a fixed multi-take set per word.
class _MultiTakeSource implements VocalTemplateSource {
  _MultiTakeSource(this.sets);
  final Map<VocalWord, List<List<List<double>>>> sets;

  VocalTemplate _tpl(VocalWord w, List<List<double>> f) => VocalTemplate(
        word: w,
        mfccFrames: f,
        checkpointFrameIndices: [f.length - 1],
        checkpointLabels: [w.name],
      );

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async =>
      _tpl(word, sets[word]!.first);

  @override
  Future<List<VocalTemplate>> templatesFor(VocalWord word) async =>
      [for (final f in sets[word]!) _tpl(word, f)];
}

void main() {
  const words = VocalWord.values;

  // 2-element multi-take set per word: the bundled single-take template
  // (the trainer's own render) plus lessac2 (same voice, different
  // utterance) — both already committed, no new fixtures needed.
  final sets = <VocalWord, List<List<List<double>>>>{};
  for (final w in words) {
    final bundled = jsonDecode(
        File('assets/practice_templates/${w.name}.json').readAsStringSync());
    final bundledFrames = (bundled['frames'] as List)
        .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    final lessac2Frames = MfccExtractor.extract(
        _pcmFromWav('test/practice/fixtures/voices/lessac2_${w.name}.wav'));
    sets[w] = [bundledFrames, lessac2Frames];
  }
  final source = _MultiTakeSource(sets);

  final fixtures = <String, Map<VocalWord, Uint8List>>{
    for (final voice in ['lessac2', 'amy'])
      voice: {
        for (final w in words)
          w: _pcmFromWav('test/practice/fixtures/voices/${voice}_${w.name}.wav'),
      },
  };

  Future<bool> run(VocalWord target, Uint8List spokenAudio,
      {int attempts = 2}) async {
    final scorer = StreamingPhonemeScorer(templateSource: source);
    await scorer.beginFormula(PracticeFormula([target]));

    final silence = Uint8List(8000 * 2);
    void feed(Uint8List audio) {
      for (int off = 0; off < audio.length && !scorer.isComplete; off += 640) {
        final end = (off + 640).clamp(0, audio.length);
        scorer.acceptPcmChunk(Uint8List.sublistView(audio, off, end));
      }
    }

    for (int a = 0; a < attempts && !scorer.isComplete; a++) {
      feed(silence);
      feed(spokenAudio);
    }
    if (!scorer.isComplete) feed(silence);
    final complete = scorer.isComplete;
    scorer.dispose();
    return complete;
  }

  test('multi-exemplar (2-take) sets: correct word still completes '
      '(same-voice query)', () async {
    final failures = <String>[];
    for (final w in words) {
      if (!await run(w, fixtures['lessac2']![w]!)) failures.add(w.name);
    }
    expect(failures, isEmpty,
        reason: 'correct words that stalled with a 2-take set: $failures');
  });

  for (final voice in ['lessac2', 'amy']) {
    test('multi-exemplar (2-take) sets: every wrong word stalls '
        '($voice queries)', () async {
      final falseAdvances = <String>[];
      for (final target in words) {
        for (final spoken in words) {
          if (spoken == target) continue;
          if (await run(target, fixtures[voice]![spoken]!)) {
            falseAdvances.add('${spoken.name} accepted as ${target.name}');
          }
        }
      }
      expect(falseAdvances, isEmpty,
          reason: 'false advances with an enlarged set (release blocker): '
              '$falseAdvances');
    });
  }
}
