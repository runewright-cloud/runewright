// SPDX-License-Identifier: GPL-3.0-or-later
//
// streaming_phoneme_scorer_test.dart — unit tests for StreamingPhonemeScorer
// (lib/practice/streaming_phoneme_scorer.dart), using a fake
// VocalTemplateSource (no rootBundle/Flutter binding needed) so the
// checkpoint/debounce/no-static-window behaviour can be exercised with
// deterministic synthetic audio.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/practice/practice_feedback.dart';
import 'package:rune_duel/practice/streaming_phoneme_scorer.dart';
import 'package:rune_duel/practice/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

/// Always returns the same single-checkpoint template regardless of [word]
/// — sufficient for exercising the scorer's pointer/debounce/DTW logic in
/// isolation from asset loading or real speech.
class _FakeTemplateSource implements VocalTemplateSource {
  _FakeTemplateSource(this.template);

  final VocalTemplate template;

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async => template;
}

/// A linear frequency sweep — unlike silence or a steady tone, this has
/// real frame-to-frame spectral variation (confirmed empirically against
/// the actual generated word templates: even a ~10-frame slice of real
/// reference audio has nonzero per-coefficient stddev). A constant/steady
/// signal is a degenerate case for cepstral mean normalization: centering a
/// set of near-identical frames wipes out the very shape CMN is supposed to
/// preserve, which silence-vs-silence (or tone-vs-silence) fixtures can't
/// exercise — this sweep can.
Uint8List _chirpPcm(int samples, {required double startFreq, required double endFreq}) {
  final bytes = ByteData(samples * 2);
  const amplitude = 20000;
  for (int i = 0; i < samples; i++) {
    final t = i / MfccExtractor.sampleRate;
    final freq = startFreq + (endFreq - startFreq) * i / samples;
    final s = (amplitude * math.sin(2 * math.pi * freq * t)).round();
    bytes.setInt16(i * 2, s, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  // An upward sweep 300Hz->900Hz -> a handful of reference frames with real
  // internal spectral variation, used as the "target" for every checkpoint
  // in these tests (see _chirpPcm's doc comment for why not silence).
  final referenceFrames =
      MfccExtractor.extract(_chirpPcm(1600, startFreq: 300, endFreq: 900));
  final template = VocalTemplate(
    word: VocalWord.ignis,
    mfccFrames: referenceFrames,
    checkpointFrameIndices: [referenceFrames.length - 1],
    checkpointLabels: const ['x'],
  );

  StreamingPhonemeScorer buildScorer({int debounceFrames = 3}) =>
      StreamingPhonemeScorer(
        templateSource: _FakeTemplateSource(template),
        debounceFrames: debounceFrames,
      );

  test('feeding audio identical to the reference completes the formula', () async {
    final scorer = buildScorer();
    // Single-word formula: this fake template's one segment is the whole
    // thing under test here, and DTW's corner-anchored alignment needs
    // somewhat more matching content than the reference's own length to
    // fully converge (confirmed empirically: quality trends 12 -> 0 as more
    // repetitions of the identical sweep are fed) -- a two-word formula
    // would additionally require the second segment's query window to
    // happen to start at a fresh sweep-shaped boundary, which isn't
    // guaranteed by simple repetition and isn't the point of this test.
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    PracticeFeedback? feedback;
    scorer.onComplete.listen((f) => feedback = f);

    // Feed repetitions of the same sweep the reference was built from, in
    // small chunks, until it converges to a match.
    for (int rep = 0; rep < 5 && !scorer.isComplete; rep++) {
      final audio = _chirpPcm(1600, startFreq: 300, endFreq: 900);
      for (int offset = 0; offset < audio.length; offset += 160) {
        final end = (offset + 160).clamp(0, audio.length);
        scorer.acceptPcmChunk(Uint8List.sublistView(audio, offset, end));
        if (scorer.isComplete) break;
      }
    }
    // onComplete is a broadcast StreamController (async by default) -- let
    // the microtask queue flush so the listener above actually runs before
    // asserting on `feedback`. scorer.isComplete itself is a plain
    // synchronous field check and needs no such flush.
    await Future<void>.delayed(Duration.zero);

    expect(scorer.isComplete, isTrue);
    expect(feedback, isNotNull);
    expect(feedback!.checkpoints.length, 1); // one segment (single-checkpoint fake template)
    // Completion itself already guarantees quality <= floor at the crossing
    // frame; no need to additionally pin an exact number here (the floor
    // is expected to keep being recalibrated against real voices, and a
    // tight numeric assertion here would just be re-testing the floor
    // constant rather than the scorer's behaviour).
    scorer.dispose();
  });

  test('feeding audio that never matches the reference stalls the pointer '
      '(no timeout, no completion)', () async {
    // Deliberately strict floor, NOT kDefaultCheckpointFloor: this test
    // verifies the rejection *mechanism* (a floor tight enough to reject
    // exists and works), independent of what the production default
    // happens to be calibrated to. kDefaultCheckpointFloor is real-voice-
    // calibrated (see docs/M4_findings.md) and synthetic noise turned out
    // not to be a reliable proxy for where that number should land -- noise
    // vs. this toy reference sits close to the real-voice range purely
    // because CMN + a short synthetic reference leaves little dynamic
    // range, which doesn't necessarily hold for real word references.
    final scorer = StreamingPhonemeScorer(
      templateSource: _FakeTemplateSource(template),
      checkpointFloor: 3.0,
    );
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    final initialTarget = scorer.currentTarget;
    expect(initialTarget, isNotNull);

    final noise = math.Random(1234);
    for (int i = 0; i < 20; i++) {
      final bytes = ByteData(320 * 2);
      for (int s = 0; s < 320; s++) {
        bytes.setInt16(s * 2, noise.nextInt(40001) - 20000, Endian.little);
      }
      scorer.acceptPcmChunk(bytes.buffer.asUint8List());
    }

    expect(scorer.isComplete, isFalse);
    expect(scorer.currentTarget, equals(initialTarget)); // pointer never advanced
    scorer.dispose();
  });

  test('debounce requires sustained clearance, not a single lucky frame', () async {
    final scorer = buildScorer(debounceFrames: 5);
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    // One small matching-shaped chunk clears the floor for at most a
    // couple of frames -- nowhere near 5 consecutive -- so it should not
    // complete a segment on the very first call.
    scorer.acceptPcmChunk(_chirpPcm(160, startFreq: 300, endFreq: 900)); // ~1 new frame's worth
    expect(scorer.currentTarget?.wordIndex, 0);
    expect(scorer.isComplete, isFalse);

    scorer.dispose();
  });
}
