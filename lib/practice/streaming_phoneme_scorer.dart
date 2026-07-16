// SPDX-License-Identifier: GPL-3.0-or-later
//
// streaming_phoneme_scorer.dart — StreamingPhonemeScorer: the no-static-
// window, rate-invariant vocal scorer for Practice Mode.
//
// Design (see docs/M4_findings.md for the full rationale): real ASR-grade
// per-phoneme streaming confidence needs a trained acoustic model, which
// this repo doesn't have (Sherpa-ONNX is an unintegrated KWS-shaped scaffold
// — see lib/sorcerer/sherpa_vocal_scorer.dart — that couldn't do this even
// once wired up). Instead this reuses the existing MFCC/DTW machinery
// (lib/sorcerer/mfcc.dart) as a closed-vocabulary, checkpoint-based scorer:
//
//   - The target formula's words are looked up via VocalTemplateSource and
//     turned into a flat list of "segments," one per word. A pointer
//     advances through segments in order; on every new ~10ms MFCC frame a
//     fresh corner-anchored DTW runs between the recent query window and
//     the current segment's reference frames.
//   - The quality metric is cost/steps (length-normalized local match
//     quality), NOT raw accumulated cost, so slow and fast deliveries of
//     the same content score alike (rate invariance).
//   - MFCC c0 is dropped (loudness, not phonetic shape) and both sides are
//     cepstral-mean-normalized independently (cancels constant mic/room/
//     vocal-tract offsets). Standard for cross-recording-condition DTW.
//   - The query window is capped at 2x the reference length — unbounded
//     growth lets any audio "coast" to a pass (see M4_findings 2026-07-09).
//
// Crossing a segment requires ALL of the following, held for
// [_debounceFrames] consecutive frames (2026-07-16 redesign — the previous
// absolute-floor-only rule was empirically unable to reject even pure
// silence against the real word templates; see M4_findings):
//
//   1. MINIMUM-AUDIO GUARD: at least kMinSegmentAudioFraction x the
//      reference's frame count of fresh audio since the segment started.
//      Short CMN'd windows are degenerate — after mean-centering, a
//      handful of frames carries almost no shape, and DTW costs collapse
//      toward the reference's own average frame magnitude. Measured: pure
//      silence crossed aqua/terra/aer at the 4-frame debounce minimum.
//   2. ENERGY GATE: at least kMinVoicedFraction of the evaluated window's
//      frames must be "voiced" — RMS above max(kSpeechRmsEpsilon,
//      kVoicedAmbientRatio x a rolling ambient-noise-floor estimate).
//      After c0-drop + CMN, silence is the single BEST imposter the metric
//      has (its DTW cost is just the template's mean frame magnitude,
//      which measures BELOW a correct word spoken by a different voice) —
//      no DTW-side threshold can reject it, so loudness has to gate it
//      out before the metric ever votes. The ambient estimate adapts
//      instantly downward and slowly upward, so inter-word gaps keep it
//      honest without speech dragging it up.
//   3. ABSOLUTE CAP: the target's cost/steps must be <= [_floor]. This is
//      no longer the discriminator (it cannot be one — measured correct
//      cross-speaker speech and wrong-word speech overlap completely); it
//      only rejects "matches nothing at all" babble.
//   4. CONTRASTIVE MARGIN (the actual word discriminator): the target
//      template's quality must beat every other vocabulary word's template
//      on the same audio by [_contrastiveMargin]. Absolute DTW costs are
//      uncalibratable across speakers/mics, but the RANKING across the
//      closed 5-word vocabulary is informative — measured 5/5 correct
//      argmin with >= 1.0 margins for same-voice templates (the enrolled
//      case), vs only 2/5 for cross-voice (why enrollment matters; see
//      PerUserEnrolledTemplateSource).
//
// There is still no timeout anywhere: an unmet condition simply stalls the
// pointer forever — that stall IS the anti-gabble mechanism. Completion
// fires the instant the final segment's debounce is satisfied;
// time-to-completion is reported but never gates anything.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sorcerer/mfcc.dart';
import '../sorcerer/vocal_score.dart';
import 'formula_generator.dart';
import 'practice_feedback.dart';
import 'vocal_template_source.dart';

class _Segment {
  _Segment({
    required this.wordIndex,
    required this.word,
    required this.label,
    required this.referenceFrames,
  });

  final int wordIndex;
  final VocalWord word;
  final String label;
  final List<List<double>> referenceFrames;
}

/// Drops MFCC coefficient c0 (loudness/log-energy, not phonetic content) —
/// see file header for why this matters for real-mic-vs-reference matching.
List<double> _dropC0(List<double> frame) => frame.sublist(1);
List<List<double>> _dropC0All(List<List<double>> frames) =>
    frames.map(_dropC0).toList();

/// Cepstral mean normalization: subtracts the per-coefficient mean (across
/// [frames]) from every frame. See file header for why. No-op-safe on an
/// empty list.
List<List<double>> _meanNormalize(List<List<double>> frames) {
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

/// Absolute cap on the target's cost/steps (condition 3). NOT the word
/// discriminator — see file header.
///
/// Calibrated 2026-07-16 by grid search through the real scorer against
/// the fixture corpus (test/practice/fixtures/voices/ + noise/silence):
/// (floor 6.25, margin 0.9, debounce 8) was one of three operating points
/// with all 5 same-voice correct words completing and ZERO false advances
/// (the others: 5.75/0.85/6 and 6.0/0.85/6); this one pairs the strongest
/// discriminators (margin+debounce) with the most floor headroom, since a
/// real human enrollment will match itself more loosely than the Piper
/// same-voice proxy does. Re-run the e2e harness before trusting any
/// retune.
const double kDefaultCheckpointFloor = 6.25;

/// Consecutive cleared updates required before a segment is considered
/// crossed. At ~10ms/frame this is an ~80ms debounce, not a listening
/// window — see file header. Part of the calibrated operating point on
/// [kDefaultCheckpointFloor]: transient dips that satisfy the margin for
/// a frame or two are how wrong words sneak across.
const int kDefaultDebounceFrames = 8;

/// Condition 4's margin: how much better (lower) the target template's
/// cost/steps must be than the best competing vocabulary word's. Part of
/// the calibrated operating point on [kDefaultCheckpointFloor]. At 0.75
/// the fixture corpus produced 4 wrong-word false advances (3 with aer,
/// the shortest/lowest-content template, as target); 0.9 + the 8-frame
/// debounce eliminated all of them while keeping every same-voice correct
/// word. Strict-biased per Soren's 2026-07-16 decision: a missed crossing
/// costs a retry, a false advance corrupts the training loop.
const double kDefaultContrastiveMargin = 0.9;

/// Condition 1's guard: fraction of the reference's frame count that must
/// have arrived fresh (since the segment started) before a crossing can
/// even be evaluated. 0.6 x the shortest template (aer, 34 frames) is
/// ~200ms — well under any real utterance, well over the degenerate
/// few-frame windows that crossed on silence.
const double kMinSegmentAudioFraction = 0.6;

/// Condition 2's gate: fraction of the evaluated window's frames that must
/// be voiced (RMS above the ambient-adaptive threshold).
const double kMinVoicedFraction = 0.35;

/// Absolute RMS below which a frame is never voiced (full-scale 1.0),
/// regardless of the ambient estimate — protects the gate when ambient
/// adapts toward digital silence (0.004 ~= 130/32768).
const double kSpeechRmsEpsilon = 0.004;

/// A frame is voiced when its RMS exceeds this multiple of the rolling
/// ambient-noise-floor estimate (subject to [kSpeechRmsEpsilon]).
const double kVoicedAmbientRatio = 2.5;

/// Condition 2b: minimum mean L2 norm of the (c0-dropped, CMN'd) query
/// window's frames. Loudness says "sound is happening"; this says "the
/// sound has speech-like spectral structure." Broadband noise passes the
/// RMS gate at any volume but has an almost flat mel spectrum, so after
/// CMN its frames nearly vanish — measured 2026-07-16: real speech 4.1-8.0
/// (both voices, all 5 words), uniform noise ~1.96 at ANY amplitude,
/// silence 0.0. Without this, loud noise cross-matched aer (whose template
/// norm, 3.43, is itself the vocabulary's lowest — open vowels carry the
/// least spectral structure) at every floor/margin combination tried.
const double kMinSpectralNorm = 3.0;

/// How fast the ambient estimate rises toward a louder steady state, per
/// frame (falls are instant). Slow on purpose: continuous speech must not
/// drag the floor up to speech level before natural inter-word gaps can
/// pull it back down.
const double kAmbientRisePerFrame = 0.002;

/// How often (in frames) the full-vocabulary "best guess" used by the
/// stall-hint UI is refreshed while the pointer is stalled. Competitor
/// DTWs are otherwise evaluated lazily (only when conditions 1-3 pass).
const int kHintEvalIntervalFrames = 30;

/// Attempt segmentation: this many consecutive unvoiced frames (~300ms of
/// quiet) resets the segment's evaluation window to "now". Corner-anchored
/// DTW must explain every frame in the window, so after a failed attempt
/// the stale audio would otherwise keep inflating the cost of a clean
/// retry indefinitely. A pause marks a fresh attempt; as a side effect,
/// leading silence before a word never enters the evaluated window at all.
const int kAttemptGapFrames = 30;

class StreamingPhonemeScorer {
  StreamingPhonemeScorer({
    required VocalTemplateSource templateSource,
    double checkpointFloor = kDefaultCheckpointFloor,
    int debounceFrames = kDefaultDebounceFrames,
    double contrastiveMargin = kDefaultContrastiveMargin,
  })  : _templateSource = templateSource,
        _floor = checkpointFloor,
        _debounceFrames = debounceFrames,
        _contrastiveMargin = contrastiveMargin;

  final VocalTemplateSource _templateSource;
  final double _floor;
  final int _debounceFrames;
  final double _contrastiveMargin;

  final BytesBuilder _pcmBuffer = BytesBuilder();
  List<List<double>> _queryFrames = const [];
  final List<double> _frameRms = [];

  /// Rolling ambient-noise-floor estimate. Starts at 0 (not the first
  /// frame's RMS): capture may open mid-speech, and seeding with a speech-
  /// level frame would lock the voiced threshold above speech forever.
  /// While it's still near 0, [kSpeechRmsEpsilon] alone rejects silence.
  double _ambientRms = 0.0;

  List<_Segment> _segments = const [];

  /// CMN'd, c0-dropped reference frames for every word in the vocabulary —
  /// the contrastive competitors (condition 4).
  Map<VocalWord, List<List<double>>> _vocabulary = const {};

  int _currentSegmentIdx = 0;
  int _segmentQueryStart = 0;
  int _framesClear = 0;
  double? _lastNormalizedQuality;
  ({String label, double quality})? _bestGuess;

  final List<CheckpointClarity> _completedCheckpoints = [];
  DateTime? _formulaStart;
  DateTime? _segmentStart;

  final _completionController = StreamController<PracticeFeedback>.broadcast();

  /// Fires once when the formula's final checkpoint clears its debounce.
  Stream<PracticeFeedback> get onComplete => _completionController.stream;

  /// The absolute cost/steps cap (condition 3). Exposed (along with
  /// [currentNormalizedQuality]) purely so the UI can show live numbers
  /// during capture — useful for calibrating the constants against real
  /// voices instead of guessing blind.
  double get floor => _floor;

  /// The most recently computed normalized quality for the segment the
  /// pointer currently sits on (lower is better; null before enough audio
  /// has arrived to evaluate it). Informational/diagnostic only.
  double? get currentNormalizedQuality => _lastNormalizedQuality;

  /// The vocabulary word whose template best explains the recent audio, if
  /// it isn't the current target — i.e. "what it sounds like you said."
  /// Refreshed every [kHintEvalIntervalFrames] frames while stalled; null
  /// when nothing voiced has been heard yet or the target itself is the
  /// best match. Drives the stall-hint UI; never gates anything.
  ({String label, double quality})? get currentBestGuess => _bestGuess;

  /// Wall-clock milliseconds the pointer has spent on the current segment.
  int get currentSegmentDwellMs => _segmentStart == null
      ? 0
      : DateTime.now().difference(_segmentStart!).inMilliseconds;

  /// Current pointer position, for UI highlighting: (wordIndex, label) of
  /// the segment currently being listened for, or null once complete.
  ({int wordIndex, String label})? get currentTarget {
    if (_currentSegmentIdx >= _segments.length) return null;
    final s = _segments[_currentSegmentIdx];
    return (wordIndex: s.wordIndex, label: s.label);
  }

  bool get isComplete =>
      _segments.isNotEmpty && _currentSegmentIdx >= _segments.length;

  /// Loads reference templates for [formula] (plus the rest of the
  /// vocabulary, as contrastive competitors) and resets all pointer state.
  /// Must be called before the first [acceptPcmChunk].
  Future<void> beginFormula(PracticeFormula formula) async {
    final vocabulary = <VocalWord, List<List<double>>>{};
    for (final word in VocalWord.values) {
      final template = await _templateSource.templateFor(word);
      vocabulary[word] = _meanNormalize(_dropC0All(template.mfccFrames));
    }

    final segments = <_Segment>[];
    for (int wordIndex = 0; wordIndex < formula.words.length; wordIndex++) {
      final word = formula.words[wordIndex];
      segments.add(_Segment(
        wordIndex: wordIndex,
        word: word,
        label: word.name,
        referenceFrames: vocabulary[word]!,
      ));
    }

    _segments = segments;
    _vocabulary = vocabulary;
    _currentSegmentIdx = 0;
    _segmentQueryStart = 0;
    _framesClear = 0;
    _lastNormalizedQuality = null;
    _bestGuess = null;
    _pcmBuffer.clear();
    _queryFrames = const [];
    _frameRms.clear();
    _ambientRms = 0.0;
    _completedCheckpoints.clear();
    _formulaStart = DateTime.now();
    _segmentStart = _formulaStart;
  }

  /// Feeds newly-captured PCM-16 LE mono audio (16 kHz, matching
  /// MfccExtractor.sampleRate) and re-evaluates the current checkpoint.
  ///
  /// No-op once [isComplete]. Safe to call with small, frequent chunks (as
  /// `record`'s startStream delivers) — this is the continuous, no-static-
  /// window evaluation loop.
  void acceptPcmChunk(Uint8List chunk) {
    if (isComplete) return;
    _pcmBuffer.add(chunk);
    final frames = _dropC0All(MfccExtractor.extract(_pcmBuffer.toBytes()));
    if (frames.length <= _queryFrames.length) return;

    // Evaluate one new frame at a time (not once per chunk): `record`'s
    // stream can deliver many new frames per call, and _framesClear must
    // count actual ~10ms frames to match the debounce duration documented
    // above — counting per-chunk instead would make the debounce length
    // depend on the platform's chunk size, not on elapsed audio time.
    final previousLength = _queryFrames.length;
    _queryFrames = frames;
    _extendFrameRms(frames.length);
    for (int len = previousLength + 1; len <= frames.length; len++) {
      if (isComplete) return;
      _evaluateCurrentSegment(len);
    }
  }

  /// Computes per-frame RMS (full-scale 0-1) for frames [_frameRms.length,
  /// count) from the PCM buffer, and feeds the ambient-noise-floor
  /// follower: instant attack downward, slow release upward (see
  /// [kAmbientRisePerFrame]).
  void _extendFrameRms(int count) {
    final bytes = _pcmBuffer.toBytes();
    final bd = ByteData.sublistView(bytes);
    const hop = 160; // MfccExtractor: 10ms at 16 kHz
    const frameSize = 400; // MfccExtractor: 25ms at 16 kHz
    for (int i = _frameRms.length; i < count; i++) {
      final start = i * hop;
      final end = math.min(start + frameSize, bytes.length ~/ 2);
      var sum = 0.0;
      for (int s = start; s < end; s++) {
        final v = bd.getInt16(s * 2, Endian.little) / 32768.0;
        sum += v * v;
      }
      final rms = end > start ? math.sqrt(sum / (end - start)) : 0.0;
      _frameRms.add(rms);

      if (rms < _ambientRms) {
        _ambientRms = rms;
      } else {
        _ambientRms += (rms - _ambientRms) * kAmbientRisePerFrame;
      }
    }
  }

  bool _isVoiced(double rms) =>
      rms >= math.max(kSpeechRmsEpsilon, kVoicedAmbientRatio * _ambientRms);

  /// cost/steps of the window ending at [queryEnd] against [ref], using
  /// ref's own 2x sliding cap (each template is evaluated exactly as it
  /// would be as a target, so contrastive comparisons are fair).
  double _windowQuality(List<List<double>> ref, int queryEnd) {
    final windowStart =
        math.max(_segmentQueryStart, queryEnd - ref.length * 2);
    final window = _meanNormalize(_queryFrames.sublist(windowStart, queryEnd));
    final result = DtwMatcher.distanceWithSteps(window, ref);
    return result.cost / result.steps;
  }

  void _evaluateCurrentSegment(int queryLengthSoFar) {
    if (_currentSegmentIdx >= _segments.length) return;
    final segment = _segments[_currentSegmentIdx];
    if (queryLengthSoFar <= _segmentQueryStart) return;

    // Attempt segmentation: a sustained quiet gap means whatever came
    // before it is a finished (failed) attempt — drop it from the window
    // so a clean retry isn't scored against stale audio (see
    // [kAttemptGapFrames]). While silence continues this keeps sliding
    // forward, which also trims leading silence off the next attempt.
    if (queryLengthSoFar - _segmentQueryStart >= kAttemptGapFrames) {
      var allQuiet = true;
      for (int i = queryLengthSoFar - kAttemptGapFrames;
          i < queryLengthSoFar;
          i++) {
        if (_isVoiced(_frameRms[i])) {
          allQuiet = false;
          break;
        }
      }
      if (allQuiet) {
        _segmentQueryStart = queryLengthSoFar;
        _framesClear = 0;
        _lastNormalizedQuality = null;
        _bestGuess = null;
        return;
      }
    }

    // Condition 1: minimum fresh audio since this segment started. Short
    // CMN'd windows are degenerate (see file header) — don't even run DTW.
    final freshFrames = queryLengthSoFar - _segmentQueryStart;
    final minFrames =
        (segment.referenceFrames.length * kMinSegmentAudioFraction).ceil();
    if (freshFrames < minFrames) {
      _framesClear = 0;
      return;
    }

    // Target window, built once: DTW quality, energy gate, and spectral
    // gate all read the same frames.
    final windowStart = math.max(
        _segmentQueryStart, queryLengthSoFar - segment.referenceFrames.length * 2);
    final targetWindow =
        _meanNormalize(_queryFrames.sublist(windowStart, queryLengthSoFar));
    final targetResult =
        DtwMatcher.distanceWithSteps(targetWindow, segment.referenceFrames);
    final targetQuality = targetResult.cost / targetResult.steps;
    _lastNormalizedQuality = targetQuality;

    // Condition 2: enough of the evaluated window must be voiced. Silence
    // is the metric's best imposter — it has to be gated on energy, not
    // on DTW cost (see file header).
    int voiced = 0;
    for (int i = windowStart; i < queryLengthSoFar; i++) {
      if (_isVoiced(_frameRms[i])) voiced++;
    }
    var voicedOk =
        voiced >= (queryLengthSoFar - windowStart) * kMinVoicedFraction;

    // Condition 2b: the window must carry speech-like spectral structure,
    // not just energy — broadband noise is loud but nearly featureless
    // after CMN (see [kMinSpectralNorm]). Measured over the VOICED frames
    // only, centered on their own mean: the window can carry a stub of
    // leading silence (the attempt-gap reset lags speech onset by up to
    // kAttemptGapFrames-1 frames), and CMN over a bimodal silence+sound
    // window inflates every frame's deviation — the silence-vs-sound
    // contrast would masquerade as spectral structure.
    if (voicedOk) {
      final voicedFrames = <List<double>>[
        for (int i = windowStart; i < queryLengthSoFar; i++)
          if (_isVoiced(_frameRms[i])) _queryFrames[i],
      ];
      final centered = _meanNormalize(voicedFrames);
      var normSum = 0.0;
      for (final f in centered) {
        var n = 0.0;
        for (final v in f) {
          n += v * v;
        }
        normSum += math.sqrt(n);
      }
      voicedOk = normSum / centered.length >= kMinSpectralNorm;
    }

    // Condition 3: absolute cap (anti-babble, not word discrimination).
    final capOk = targetQuality <= _floor;

    // Condition 4: contrastive margin — the target template must beat
    // every other vocabulary word on this audio. Competitor DTWs are
    // evaluated lazily (only when 1-3 pass) plus periodically for the
    // stall-hint best-guess.
    bool marginOk = false;
    final wantHint = freshFrames % kHintEvalIntervalFrames == 0;
    if ((voicedOk && capOk) || wantHint) {
      var bestLabel = segment.label;
      var bestQuality = targetQuality;
      var bestCompetitor = double.infinity;
      for (final entry in _vocabulary.entries) {
        if (entry.key == segment.word) continue;
        final q = _windowQuality(entry.value, queryLengthSoFar);
        if (q < bestCompetitor) bestCompetitor = q;
        if (q < bestQuality) {
          bestQuality = q;
          bestLabel = entry.key.name;
        }
      }
      marginOk = targetQuality + _contrastiveMargin <= bestCompetitor;
      _bestGuess = (!voicedOk || bestLabel == segment.label)
          ? null
          : (label: bestLabel, quality: bestQuality);
    }

    if (voicedOk && capOk && marginOk) {
      _framesClear++;
    } else {
      _framesClear = 0;
    }

    if (_framesClear < _debounceFrames) return;

    // Segment crossed.
    final now = DateTime.now();
    _completedCheckpoints.add(CheckpointClarity(
      wordIndex: segment.wordIndex,
      label: segment.label,
      normalizedQuality: targetQuality,
      dwellMs: now.difference(_segmentStart!).inMilliseconds,
    ));
    _segmentQueryStart = queryLengthSoFar;
    _framesClear = 0;
    _lastNormalizedQuality = null;
    _bestGuess = null;
    _segmentStart = now;
    _currentSegmentIdx++;

    if (_currentSegmentIdx >= _segments.length) {
      final totalMs = now.difference(_formulaStart!).inMilliseconds;
      final loudness = MfccExtractor.computeRms(_pcmBuffer.toBytes());
      _completionController.add(PracticeFeedback(
        checkpoints: List.unmodifiable(_completedCheckpoints),
        timeToCompletionMs: totalMs,
        averageLoudness: loudness.clamp(0.0, 1.0),
      ));
    }
  }

  void dispose() {
    _completionController.close();
  }
}
