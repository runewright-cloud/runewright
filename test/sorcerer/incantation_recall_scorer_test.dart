// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_recall_scorer_test.dart — the whole-utterance segmenter and the
// per-position argmin (lib/sorcerer/incantation_recall_scorer.dart).
//
// Synthetic stand-ins, not real speech: each slot is a distinct chirp, so a
// failure here is a bug in the segmentation or the ranking rather than a
// judgement about a DTW threshold. Real-voice behaviour is what the fixture
// e2e tests and a device pass are for.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/incantation_recall_scorer.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/sorcerer/vocal_template_source.dart';

/// Distinct sweep per slot. The openers sweep DOWN and the elements UP: after
/// c0 is dropped and cepstral mean normalisation applied, a narrow chirp is
/// distinguished mostly by sweep SHAPE, and six same-shaped sweeps do not
/// separate (learned the hard way in streaming_phoneme_scorer_test).
const Map<VocalSlot, ({double start, double end})> _bands = {
  VocalSlot.fire: (start: 300, end: 900),
  VocalSlot.air: (start: 1100, end: 1700),
  VocalSlot.water: (start: 1900, end: 2500),
  VocalSlot.earth: (start: 2700, end: 3300),
  VocalSlot.openerGeneral: (start: 3300, end: 2700),
  VocalSlot.openerSummon: (start: 1700, end: 1100),
};

Uint8List _chirp(int samples, {required double startFreq, required double endFreq}) {
  final bytes = ByteData(samples * 2);
  var phase = 0.0;
  for (var i = 0; i < samples; i++) {
    final t = i / samples;
    final freq = startFreq + (endFreq - startFreq) * t;
    phase += 2 * math.pi * freq / MfccExtractor.sampleRate;
    bytes.setInt16(i * 2, (math.sin(phase) * 12000).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

Uint8List _silence(int samples) => Uint8List(samples * 2);

Uint8List _wordAudio(VocalSlot slot, {int samples = 6400}) {
  final band = _bands[slot]!;
  return _chirp(samples, startFreq: band.start, endFreq: band.end);
}

/// Concatenates words with silence between them, the way a held chant arrives.
Uint8List _utterance(List<VocalSlot> words, {int gapSamples = 2400}) {
  final out = BytesBuilder();
  out.add(_silence(1600));
  for (var i = 0; i < words.length; i++) {
    if (i > 0) out.add(_silence(gapSamples));
    out.add(_wordAudio(words[i]));
  }
  out.add(_silence(1600));
  return out.toBytes();
}

class _ChirpTemplateSource implements VocalTemplateSource {
  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async => VocalTemplate(
        word: word,
        mfccFrames: MfccExtractor.extract(_wordAudio(word)),
        checkpointFrameIndices: const [0],
        checkpointLabels: [word.name],
      );

  @override
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async =>
      [await templateFor(word)];
}

void main() {
  late IncantationRecallScorer scorer;

  setUp(() async {
    scorer = IncantationRecallScorer(templateSource: _ChirpTemplateSource());
    await scorer.load();
  });

  group('segmentation', () {
    test('a clean chant decodes every position', () {
      const spoken = [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.air,
        VocalSlot.water,
      ];
      final recall =
          scorer.score(_utterance(spoken), expectedElements: 3);
      expect(recall.opener, VocalSlot.openerGeneral);
      expect(recall.elements,
          [VocalSlot.fire, VocalSlot.air, VocalSlot.water]);
    });

    test('distinguishes the two openers', () {
      final general = scorer.score(
        _utterance(const [VocalSlot.openerGeneral, VocalSlot.fire]),
        expectedElements: 1,
      );
      final summon = scorer.score(
        _utterance(const [VocalSlot.openerSummon, VocalSlot.fire]),
        expectedElements: 1,
      );
      expect(general.opener, VocalSlot.openerGeneral);
      expect(summon.opener, VocalSlot.openerSummon);
    });

    test('a long recital decodes without drifting', () {
      final elements = [
        for (var i = 0; i < 9; i++) VocalSlot.elements[i % 4],
      ];
      final recall = scorer.score(
        _utterance([VocalSlot.openerSummon, ...elements]),
        expectedElements: 9,
      );
      expect(recall.opener, VocalSlot.openerSummon);
      expect(recall.elements, elements);
    });
  });

  group('mismatched length never re-flows', () {
    // The alignment rule that matters: a short recital must leave the missing
    // TAIL positions blank, never shift later words onto earlier slots.
    test('too few words leaves the tail blank, not shifted', () {
      final recall = scorer.score(
        _utterance(const [
          VocalSlot.openerGeneral,
          VocalSlot.fire,
          VocalSlot.air,
        ]),
        expectedElements: 5,
      );
      expect(recall.elements.length, 5);
      expect(recall.elements[0], VocalSlot.fire);
      expect(recall.elements[1], VocalSlot.air);
      expect(recall.elements.sublist(2), everyElement(isNull));
    });

    test('too many words are dropped, not wrapped', () {
      final recall = scorer.score(
        _utterance(const [
          VocalSlot.openerGeneral,
          VocalSlot.fire,
          VocalSlot.air,
          VocalSlot.water,
          VocalSlot.earth,
        ]),
        expectedElements: 2,
      );
      expect(recall.elements, [VocalSlot.fire, VocalSlot.air]);
    });
  });

  group('degenerate input', () {
    test('silence is a total blank', () {
      final recall = scorer.score(_silence(16000), expectedElements: 3);
      expect(recall.opener, isNull);
      expect(recall.elements, everyElement(isNull));
    });

    test('an empty buffer is a total blank', () {
      final recall = scorer.score(Uint8List(0), expectedElements: 3);
      expect(recall.opener, isNull);
      expect(recall.elements, isEmpty);
    });

    test('a scorer that never loaded returns silence rather than throwing', () {
      final cold =
          IncantationRecallScorer(templateSource: _ChirpTemplateSource());
      final recall = cold.score(
        _utterance(const [VocalSlot.openerGeneral, VocalSlot.fire]),
        expectedElements: 1,
      );
      expect(recall.opener, isNull);
    });

    test('a run too short to be a word is not a word', () {
      // 40 ms of tone: under minWordFrames, so it never becomes a segment.
      final blip = BytesBuilder()
        ..add(_silence(1600))
        ..add(_wordAudio(VocalSlot.fire, samples: 640))
        ..add(_silence(1600));
      final recall =
          scorer.score(blip.toBytes(), expectedElements: 1);
      expect(recall.opener, isNull);
    });
  });
}
