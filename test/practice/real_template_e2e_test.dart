// SPDX-License-Identifier: GPL-3.0-or-later
//
// real_template_e2e_test.dart — end-to-end StreamingPhonemeScorer runs
// against the REAL bundled templates (assets/practice_templates/*.json)
// with real Piper speech fixtures (test/practice/fixtures/voices/ — see
// its README for provenance). This is the closed-loop check the synthetic
// chirp tests can't provide: the 2026-07-16 redesign happened because the
// old floor-only rule passed unit tests while pure silence crossed the
// real templates in 40ms.
//
// What is asserted, per Soren's strict-tuning decision (never
// false-advance):
//   - same-voice (lessac2, the enrolled-player proxy): the CORRECT word
//     completes, every WRONG word stalls;
//   - cross-voice (amy, the unenrolled-fallback proxy): every WRONG
//     word stalls. Correct-word completion is NOT asserted cross-voice —
//     measured discrimination is genuinely weak there (that's why
//     enrollment exists), and a correct-but-stalled fallback attempt is
//     the accepted failure mode.
//   - silence and noise never complete.

@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/practice/streaming_phoneme_scorer.dart';
import 'package:rune_duel/sorcerer/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

/// Loads the real bundled templates from disk (tests run from the repo
/// root; rootBundle would need a Flutter binding).
class _DiskTemplateSource implements VocalTemplateSource {
  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async {
    final raw = File('assets/practice_templates/${word.name}.json')
        .readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final frames = (json['frames'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    return VocalTemplate(
      word: word,
      mfccFrames: frames,
      checkpointFrameIndices: [frames.length - 1],
      checkpointLabels: [word.name],
    );
  }

  @override
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async =>
      [await templateFor(word)];
}

/// Reads a PCM-16 mono WAV and resamples to 16 kHz if needed (linear
/// interpolation, mirroring scripts/generate_practice_assets.dart).
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

void main() {
  const words = VocalSlot.values;
  final fixtures = <String, Map<VocalSlot, Uint8List>>{
    for (final voice in ['lessac2', 'amy'])
      voice: {
        for (final w in words)
          w: _pcmFromWav('test/practice/fixtures/voices/${voice}_${w.name}.wav'),
      },
  };

  /// Runs a fresh scorer targeting [target], feeding [attempts] repetitions
  /// of [spoken]'s audio separated by 0.5s pauses (mimicking a real
  /// retry cadence and triggering attempt segmentation). Returns true if
  /// the formula completed.
  Future<bool> run(VocalSlot target, Uint8List spokenAudio,
      {int attempts = 2}) async {
    final scorer =
        StreamingPhonemeScorer(templateSource: _DiskTemplateSource());
    await scorer.beginFormula(PracticeFormula([target]));

    final silence = Uint8List(8000 * 2); // 0.5s
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

  test('same voice (enrolled proxy): correct word completes', () async {
    final failures = <String>[];
    for (final w in words) {
      if (!await run(w, fixtures['lessac2']![w]!)) failures.add(w.name);
    }
    expect(failures, isEmpty,
        reason: 'correct same-voice words that stalled: $failures');
  });

  test('same voice (enrolled proxy): every wrong word stalls', () async {
    final falseAdvances = <String>[];
    for (final target in words) {
      for (final spoken in words) {
        if (spoken == target) continue;
        if (await run(target, fixtures['lessac2']![spoken]!)) {
          falseAdvances.add('${spoken.name} accepted as ${target.name}');
        }
      }
    }
    expect(falseAdvances, isEmpty,
        reason: 'false advances (release blocker): $falseAdvances');
  });

  test('cross voice (fallback proxy): every wrong word stalls', () async {
    final falseAdvances = <String>[];
    for (final target in words) {
      for (final spoken in words) {
        if (spoken == target) continue;
        if (await run(target, fixtures['amy']![spoken]!)) {
          falseAdvances.add('${spoken.name} accepted as ${target.name}');
        }
      }
    }
    expect(falseAdvances, isEmpty,
        reason: 'false advances (release blocker): $falseAdvances');
  });

  test('silence and noise never complete against real templates', () async {
    // The 2026-07-16 smoking gun: pure silence used to cross aqua/terra/
    // aer in 40ms and all five words within a second.
    for (final w in words) {
      expect(await run(w, Uint8List(16000 * 2)), isFalse,
          reason: 'silence completed "${w.name}"');
    }
    final rand = math.Random(7);
    final noise = ByteData(16000 * 2 * 2);
    for (int i = 0; i < 16000 * 2; i++) {
      noise.setInt16(i * 2, rand.nextInt(16001) - 8000, Endian.little);
    }
    for (final w in words) {
      expect(await run(w, noise.buffer.asUint8List()), isFalse,
          reason: 'noise completed "${w.name}"');
    }
  });
}
