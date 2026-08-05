// SPDX-License-Identifier: GPL-3.0-or-later
//
// recall_real_voice_e2e_test.dart — IncantationRecallScorer against the REAL
// bundled templates (assets/practice_templates/*.json) and real Piper speech
// fixtures (test/practice/fixtures/voices/ — see its README for provenance).
//
// Ported from real_template_e2e_test / multi_exemplar_e2e_test when the
// streaming pronunciation scorer retired (VOCAL_RECALL_PLAN.md §9). Those
// tests earned their keep: the 2026-07-16 redesign happened because a
// floor-only rule passed every synthetic unit test while pure silence crossed
// the real templates in 40 ms. Synthetic chirps cannot catch that class of
// bug, so the real-voice loop had to survive the rewrite.
//
// What recall asks is easier than what the old scorer asked — "which of these
// four" rather than "how well was that said" — so the assertions are stronger
// here than they could be there:
//
//   - same-voice (lessac2, the enrolled-player proxy): every element word is
//     identified CORRECTLY, and the two openers are told apart;
//   - cross-voice (amy, the unenrolled-fallback proxy): NOT asserted correct.
//     Cross-voice discrimination is genuinely weak (2/5 measured, M4_findings
//     2026-07-16) — that is precisely why enrollment exists, and under recall
//     a mis-spot costs mana rather than nothing. Asserted only to be stable
//     and in-vocabulary;
//   - silence yields no words at all rather than confident wrong ones.

@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/incantation_recall_scorer.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/sorcerer/vocal_template_source.dart';

/// The real bundled templates, read from disk (tests run from the repo root;
/// rootBundle would need a Flutter binding).
class _DiskTemplateSource implements VocalTemplateSource {
  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async {
    final raw =
        File('assets/practice_templates/${word.name}.json').readAsStringSync();
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

/// Reads a PCM-16 mono WAV, resampling to 16 kHz if needed (linear
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

Uint8List _silence(int samples) => Uint8List(samples * 2);

void main() {
  final fixtures = <String, Map<VocalSlot, Uint8List>>{
    for (final voice in ['lessac2', 'amy'])
      voice: {
        for (final w in VocalSlot.values)
          w: _pcmFromWav(
              'test/practice/fixtures/voices/${voice}_${w.name}.wav'),
      },
  };

  /// Splices [words] into one held utterance, with the pauses a chanted
  /// incantation actually has between words.
  Uint8List utterance(String voice, List<VocalSlot> words) {
    final out = BytesBuilder();
    out.add(_silence(2400));
    for (var i = 0; i < words.length; i++) {
      if (i > 0) out.add(_silence(3200));
      out.add(fixtures[voice]![words[i]]!);
    }
    out.add(_silence(2400));
    return out.toBytes();
  }

  late IncantationRecallScorer scorer;

  setUp(() async {
    scorer = IncantationRecallScorer(templateSource: _DiskTemplateSource());
    await scorer.load();
  });

  group('same voice as the templates (enrolled-player proxy)', () {
    test('identifies every element word in a full incantation', () async {
      const spoken = [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.air,
        VocalSlot.water,
        VocalSlot.earth,
        VocalSlot.fire,
        VocalSlot.water,
      ];
      final recall = scorer.score(
        utterance('lessac2', spoken),
        expectedElements: spoken.length - 1,
      );
      expect(recall.elements, spoken.sublist(1),
          reason: 'same-voice element discrimination should be exact');
    });

    // §8.7 calls this the load-bearing distance: it is the only pair a player
    // is motivated to collapse, because it hides whether a cast is a summon.
    test('tells the two openers apart', () async {
      for (final opener in VocalSlot.openers) {
        final recall = scorer.score(
          utterance('lessac2', [opener, VocalSlot.fire]),
          expectedElements: 1,
        );
        expect(recall.opener, opener, reason: 'opener ${opener.name}');
      }
    });

    test('each element word is identified on its own', () async {
      for (final element in VocalSlot.elements) {
        final recall = scorer.score(
          utterance('lessac2', [VocalSlot.openerGeneral, element]),
          expectedElements: 1,
        );
        expect(recall.elements.single, element, reason: element.name);
      }
    });

    test('segments a 9-element recital without losing count', () async {
      final elements = [
        for (var i = 0; i < 9; i++) VocalSlot.elements[i % 4],
      ];
      final recall = scorer.score(
        utterance('lessac2', [VocalSlot.openerSummon, ...elements]),
        expectedElements: 9,
      );
      expect(recall.elements.whereType<VocalSlot>().length, 9,
          reason: 'every position should hear SOMETHING');
      expect(recall.elements, elements);
    });
  });

  group('a different voice (unenrolled-fallback proxy)', () {
    // Correctness is deliberately not asserted: cross-voice ranking is weak,
    // which is why enrollment exists. What must hold is that it stays
    // in-vocabulary and stable — never null, never out of range.
    test('still produces a decision at every position', () async {
      const spoken = [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.air,
        VocalSlot.water,
      ];
      final recall = scorer.score(
        utterance('amy', spoken),
        expectedElements: 3,
      );
      expect(recall.opener, isNotNull);
      expect(recall.opener!.isOpener, isTrue);
      expect(recall.elements, hasLength(3));
      for (final e in recall.elements) {
        expect(e, isNotNull);
        expect(e!.isElement, isTrue,
            reason: 'an element position must never decode to an opener');
      }
    });

    test('is deterministic across runs', () async {
      final audio = utterance('amy', const [
        VocalSlot.openerSummon,
        VocalSlot.earth,
        VocalSlot.water,
      ]);
      final a = scorer.score(audio, expectedElements: 2);
      final b = scorer.score(audio, expectedElements: 2);
      expect(a.elements, b.elements);
      expect(a.opener, b.opener);
    });
  });

  group('degenerate audio', () {
    // The bug that motivated the 2026-07-16 redesign was silence CROSSING the
    // real templates. It must not now confidently decode as words.
    test('silence yields no words against the real templates', () async {
      final recall = scorer.score(_silence(32000), expectedElements: 3);
      expect(recall.opener, isNull);
      expect(recall.elements, everyElement(isNull));
    });

    test('a recital shorter than the spell leaves the tail blank', () async {
      final recall = scorer.score(
        utterance('lessac2', const [VocalSlot.openerGeneral, VocalSlot.fire]),
        expectedElements: 4,
      );
      expect(recall.elements, hasLength(4));
      expect(recall.elements.first, VocalSlot.fire);
      expect(recall.elements.sublist(1), everyElement(isNull));
    });
  });
}
