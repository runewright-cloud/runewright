// SPDX-License-Identifier: GPL-3.0-or-later
//
// streaming_phoneme_scorer_test.dart — unit tests for StreamingPhonemeScorer
// (lib/practice/streaming_phoneme_scorer.dart), using a fake
// VocalTemplateSource (no rootBundle/Flutter binding needed) so the
// crossing conditions (min-audio guard, energy gate, absolute cap,
// contrastive margin, debounce) can be exercised with deterministic
// synthetic audio.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/practice/practice_feedback.dart';
import 'package:rune_duel/practice/streaming_phoneme_scorer.dart';
import 'package:rune_duel/practice/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

/// Returns a distinct template per word. Contrastive scoring (condition 4)
/// compares the target against every other vocabulary word's template, so
/// a fake source that returned one shared template for every word would
/// make crossing impossible by construction (the target could never beat
/// an identical competitor by the margin).
class _FakeTemplateSource implements VocalTemplateSource {
  _FakeTemplateSource(this.templates);

  final Map<VocalWord, VocalTemplate> templates;

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async => templates[word]!;

  @override
  Future<List<VocalTemplate>> templatesFor(VocalWord word) async =>
      [templates[word]!];
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

/// One distinct chirp band per vocabulary word, so each word's "audio" and
/// template are unambiguous synthetic stand-ins.
final Map<VocalWord, ({double start, double end})> _bands = {
  VocalWord.ignis: (start: 300, end: 900),
  VocalWord.ventus: (start: 1100, end: 1700),
  VocalWord.aqua: (start: 1900, end: 2500),
  VocalWord.terra: (start: 2700, end: 3300),
  VocalWord.finitus: (start: 3500, end: 4100),
};

/// 0.4s per word (~38 MFCC frames) — the real Piper templates are 34-75
/// frames, and the guard/window logic behaves degenerately differently on
/// unrealistically tiny references.
Uint8List _wordAudio(VocalWord word, {int samples = 6400}) {
  final band = _bands[word]!;
  return _chirpPcm(samples, startFreq: band.start, endFreq: band.end);
}

void main() {
  final templates = <VocalWord, VocalTemplate>{
    for (final word in VocalWord.values)
      word: VocalTemplate(
        word: word,
        mfccFrames: MfccExtractor.extract(_wordAudio(word)),
        checkpointFrameIndices: [
          MfccExtractor.extract(_wordAudio(word)).length - 1
        ],
        checkpointLabels: [word.name],
      ),
  };

  StreamingPhonemeScorer buildScorer({
    int debounceFrames = 3,
    double? checkpointFloor,
  }) =>
      StreamingPhonemeScorer(
        templateSource: _FakeTemplateSource(templates),
        debounceFrames: debounceFrames,
        checkpointFloor: checkpointFloor ?? kDefaultCheckpointFloor,
      );

  /// Feeds [audio] to [scorer] in ~10ms chunks, stopping early on
  /// completion.
  void feed(StreamingPhonemeScorer scorer, Uint8List audio) {
    for (int offset = 0; offset < audio.length; offset += 320) {
      final end = (offset + 320).clamp(0, audio.length);
      scorer.acceptPcmChunk(Uint8List.sublistView(audio, offset, end));
      if (scorer.isComplete) return;
    }
  }

  test('feeding audio identical to the reference completes the formula', () async {
    final scorer = buildScorer();
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    PracticeFeedback? feedback;
    scorer.onComplete.listen((f) => feedback = f);

    // Feed repetitions of the same sweep the reference was built from —
    // corner-anchored DTW needs somewhat more matching content than the
    // reference's own length to fully converge.
    for (int rep = 0; rep < 5 && !scorer.isComplete; rep++) {
      feed(scorer, _wordAudio(VocalWord.ignis));
    }
    // onComplete is a broadcast StreamController (async by default) — let
    // the microtask queue flush so the listener above actually runs.
    await Future<void>.delayed(Duration.zero);

    expect(scorer.isComplete, isTrue);
    expect(feedback, isNotNull);
    expect(feedback!.checkpoints.length, 1);
    scorer.dispose();
  });

  test('the WRONG vocabulary word stalls the pointer (contrastive margin)',
      () async {
    final scorer = buildScorer();
    // Target is aqua; speak terra (a word whose template is a competitor).
    await scorer.beginFormula(const PracticeFormula([VocalWord.aqua]));

    for (int rep = 0; rep < 5 && !scorer.isComplete; rep++) {
      feed(scorer, _wordAudio(VocalWord.terra));
    }

    expect(scorer.isComplete, isFalse);
    expect(scorer.currentTarget?.label, 'aqua');

    // ...and the stall hint should finger the word actually spoken.
    expect(scorer.currentBestGuess?.label, 'terra');

    // Pause, then say the right word: completes. The quiet gap is what
    // discards the failed attempt's audio (attempt segmentation —
    // kAttemptGapFrames); a retry chanted with no pause at all stays
    // stalled because corner-anchored DTW must still explain the stale
    // window, and that's accepted strict-side behaviour.
    feed(scorer, Uint8List(16000)); // 0.5s silence
    for (int rep = 0; rep < 5 && !scorer.isComplete; rep++) {
      feed(scorer, _wordAudio(VocalWord.aqua));
    }
    expect(scorer.isComplete, isTrue);
    scorer.dispose();
  });

  test('pure digital silence never crosses (energy gate)', () async {
    final scorer = buildScorer();
    await scorer.beginFormula(const PracticeFormula([VocalWord.ventus]));

    final initialTarget = scorer.currentTarget;
    // 3 seconds of true silence. Before the 2026-07-16 redesign this
    // crossed real word templates within ~40ms-1s: after c0-drop + CMN,
    // silence's DTW cost is just the template's mean frame magnitude,
    // BELOW where correct cross-speaker speech lands — no DTW-side floor
    // can reject it, only the energy gate can.
    feed(scorer, Uint8List(3 * 16000 * 2));

    expect(scorer.isComplete, isFalse);
    expect(scorer.currentTarget, equals(initialTarget));
    scorer.dispose();
  });

  test('random noise stalls the pointer (no timeout, no completion)', () async {
    // Deliberately strict floor, NOT kDefaultCheckpointFloor: this verifies
    // the absolute-cap *mechanism* independent of the production value
    // (which is calibrated against real voices, not synthetic noise).
    final scorer = buildScorer(checkpointFloor: 3.0);
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    final initialTarget = scorer.currentTarget;
    final noise = math.Random(1234);
    for (int i = 0; i < 200; i++) {
      final bytes = ByteData(320 * 2);
      for (int s = 0; s < 320; s++) {
        bytes.setInt16(s * 2, noise.nextInt(40001) - 20000, Endian.little);
      }
      scorer.acceptPcmChunk(bytes.buffer.asUint8List());
    }

    expect(scorer.isComplete, isFalse);
    expect(scorer.currentTarget, equals(initialTarget));
    scorer.dispose();
  });

  test('minimum-audio guard: no evaluation until enough fresh audio arrives',
      () async {
    // Floor 0.0 so nothing can ever cross — this test probes only whether
    // DTW evaluation starts at the guard boundary (a crossing would reset
    // currentNormalizedQuality to null and confuse the probe).
    final scorer = buildScorer(checkpointFloor: 0.0);
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    final refFrames = templates[VocalWord.ignis]!.mfccFrames.length;
    final guardFrames = (refFrames * kMinSegmentAudioFraction).ceil();

    // Feed matching audio worth clearly fewer frames than the guard: the
    // scorer must not even run DTW (quality stays null), let alone cross.
    // Short CMN'd windows are degenerate — measured: silence crossed real
    // templates at the 4-frame debounce minimum before the guard existed.
    final fewSamples = (guardFrames - 5) * 160;
    feed(scorer, _wordAudio(VocalWord.ignis, samples: fewSamples));

    expect(scorer.currentNormalizedQuality, isNull);
    expect(scorer.isComplete, isFalse);

    // Once past the guard, evaluation resumes normally.
    feed(scorer, _wordAudio(VocalWord.ignis));
    expect(scorer.currentNormalizedQuality, isNotNull);
    expect(scorer.isComplete, isFalse);
    scorer.dispose();
  });

  test('debounce requires sustained clearance, not a single lucky frame', () async {
    final scorer = buildScorer(debounceFrames: 5);
    await scorer.beginFormula(const PracticeFormula([VocalWord.ignis]));

    scorer.acceptPcmChunk(_wordAudio(VocalWord.ignis, samples: 160));
    expect(scorer.currentTarget?.wordIndex, 0);
    expect(scorer.isComplete, isFalse);

    scorer.dispose();
  });
}
