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
//     concatenated into a flat list of phoneme "segments" (one per
//     LatinPhonemes entry), each segment carrying its slice of that word's
//     reference MFCC frames.
//   - A pointer advances through segments in order. For the segment the
//     pointer currently sits on, every time new audio frames arrive, this
//     recomputes a fresh corner-to-corner DTW between "all query frames
//     captured since the previous segment was crossed" and that segment's
//     reference frames (DtwMatcher.distanceWithSteps).
//   - The floor check uses cost/steps (length-normalized local match
//     quality), NOT raw accumulated cost. Raw cost is a running sum that
//     grows with path length even for a perfect match (more frames -> more
//     nonnegative terms), so a fixed threshold on raw cost would force
//     slower speech to match tighter per frame than fast speech just to
//     stay under budget — breaking rate invariance. Dividing by step count
//     removes that bias: a slow, clean "aqua" and a fast, clean "aqua" both
//     land at a similar cost-per-step, so they clear the same floor.
//   - Clearing the floor must hold for [_debounceFrames] consecutive
//     updates (tens of ms) before the segment is considered crossed — a
//     debounce, not a listening window: there is no timeout, no maximum
//     wait, and an unmet floor simply leaves the pointer stalled forever
//     (anti-gabble is this stall, not a separate check).
//   - Formula completion fires the instant the final segment's debounce is
//     satisfied. Time-to-completion is reported but never gates or scores
//     anything.
//   - MFCC coefficient c0 (index 0 of each 13-element frame) is dropped
//     before any distance comparison. c0 is overall log-energy — loudness,
//     not phonetic shape — so keeping it would make the match distance
//     hugely sensitive to mic gain/distance-from-mic on the query side vs.
//     Piper's fixed studio-quality render on the reference side, failing
//     even flawless real pronunciation for reasons that have nothing to do
//     with pronunciation. Dropping c0 is standard practice for DTW-based
//     pronunciation scoring for exactly this reason.
//   - Cepstral mean normalization: each segment's reference frames (once,
//     at load) and each evaluation's query window (every time, since it
//     grows) are independently centered — per-coefficient mean across that
//     segment/window's own frames subtracted out. A real phone's mic/room/
//     vocal-tract-length differs from Piper's studio voice by roughly a
//     constant per-coefficient offset, which raw distance can't tell apart
//     from an actual pronunciation difference; CMN removes that constant
//     bias from each side independently while preserving the frame-to-frame
//     *pattern* that carries the actual phonetic content. Standard technique
//     for exactly this cross-recording-condition mismatch.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sorcerer/mfcc.dart';
import 'formula_generator.dart';
import 'practice_feedback.dart';
import 'vocal_template_source.dart';

class _Segment {
  _Segment({
    required this.wordIndex,
    required this.phonemeLabel,
    required this.referenceFrames,
  });

  final int wordIndex;
  final String phonemeLabel;
  final List<List<double>> referenceFrames;
}

/// Drops MFCC coefficient c0 (loudness/log-energy, not phonetic content) —
/// see file header for why this matters for real-mic-vs-TTS-reference
/// matching.
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

/// How clean a match must be (cost per DTW step) to count as "cleared".
/// Lower = stricter.
///
/// REVISED DOWN (2026-07-10): the 11.0 this was previously set to was
/// calibrated against real-voice data (8.0-8.5) gathered *before* the
/// unbounded-query-window drift bug was fixed (see docs/M4_findings.md) --
/// that data was itself inflated by the same bug and shouldn't have been
/// trusted. Confirmed on-device: at 11.0, a formula would complete the
/// instant capture started, before any word was actually spoken -- Android's
/// mic backend apparently delivers a larger first buffered chunk than
/// Linux's parecord pipe did, and 11.0 turned out loose enough that even
/// near-silent/ambient audio clears it in one shot. A synthetic stress test
/// (random noise against the bounded window) found noise settles around
/// ~10.6 -- i.e. 11.0 wasn't discriminating real speech from noise at all.
/// 7.0 leaves real margin below that noise baseline. Still a placeholder
/// pending fresh real-voice data gathered under the fixed windowing -- the
/// old 8.0-8.5 numbers are stale and shouldn't inform the next adjustment.
const double kDefaultCheckpointFloor = 7.0;

/// Consecutive cleared updates required before a segment is considered
/// crossed. At ~10ms/frame this is a 30-50ms debounce, not a listening
/// window — see file header.
const int kDefaultDebounceFrames = 4;

class StreamingPhonemeScorer {
  StreamingPhonemeScorer({
    required VocalTemplateSource templateSource,
    double checkpointFloor = kDefaultCheckpointFloor,
    int debounceFrames = kDefaultDebounceFrames,
  })  : _templateSource = templateSource,
        _floor = checkpointFloor,
        _debounceFrames = debounceFrames;

  final VocalTemplateSource _templateSource;
  final double _floor;
  final int _debounceFrames;

  final BytesBuilder _pcmBuffer = BytesBuilder();
  List<List<double>> _queryFrames = const [];

  List<_Segment> _segments = const [];
  int _currentSegmentIdx = 0;
  int _segmentQueryStart = 0;
  int _framesClear = 0;
  double? _lastNormalizedQuality;

  final List<CheckpointClarity> _completedCheckpoints = [];
  DateTime? _formulaStart;
  DateTime? _segmentStart;

  final _completionController = StreamController<PracticeFeedback>.broadcast();

  /// Fires once when the formula's final checkpoint clears its debounce.
  Stream<PracticeFeedback> get onComplete => _completionController.stream;

  /// The floor a checkpoint's normalized quality must clear. Exposed (along
  /// with [currentNormalizedQuality]) purely so the UI can show live
  /// numbers during capture — useful for calibrating [kDefaultCheckpointFloor]
  /// against real voices instead of guessing blind.
  double get floor => _floor;

  /// The most recently computed normalized quality for the segment the
  /// pointer currently sits on (lower is better; null before any audio has
  /// been evaluated for it). Informational/diagnostic only — never read by
  /// scoring logic itself.
  double? get currentNormalizedQuality => _lastNormalizedQuality;

  /// Current pointer position, for UI highlighting: (wordIndex, phonemeLabel)
  /// of the segment currently being listened for, or null once complete.
  ({int wordIndex, String phonemeLabel})? get currentTarget {
    if (_currentSegmentIdx >= _segments.length) return null;
    final s = _segments[_currentSegmentIdx];
    return (wordIndex: s.wordIndex, phonemeLabel: s.phonemeLabel);
  }

  bool get isComplete => _segments.isNotEmpty && _currentSegmentIdx >= _segments.length;

  /// Loads reference templates for [formula] and resets all pointer state.
  /// Must be called before the first [acceptPcmChunk].
  Future<void> beginFormula(PracticeFormula formula) async {
    final segments = <_Segment>[];
    for (int wordIndex = 0; wordIndex < formula.words.length; wordIndex++) {
      final word = formula.words[wordIndex];
      final template = await _templateSource.templateFor(word);
      int prevBoundary = -1;
      for (int p = 0; p < template.checkpointFrameIndices.length; p++) {
        final boundary = template.checkpointFrameIndices[p];
        final slice = template.mfccFrames.sublist(prevBoundary + 1, boundary + 1);
        segments.add(_Segment(
          wordIndex: wordIndex,
          phonemeLabel: template.phonemeLabels[p],
          referenceFrames: _meanNormalize(_dropC0All(slice)),
        ));
        prevBoundary = boundary;
      }
    }

    _segments = segments;
    _currentSegmentIdx = 0;
    _segmentQueryStart = 0;
    _framesClear = 0;
    _lastNormalizedQuality = null;
    _pcmBuffer.clear();
    _queryFrames = const [];
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
    for (int len = previousLength + 1; len <= frames.length; len++) {
      if (isComplete) return;
      _evaluateCurrentSegment(len);
    }
  }

  void _evaluateCurrentSegment(int queryLengthSoFar) {
    if (_currentSegmentIdx >= _segments.length) return;
    final segment = _segments[_currentSegmentIdx];
    if (queryLengthSoFar <= _segmentQueryStart) return;

    // Bounded sliding window, not "everything since this segment started."
    // Corner-anchored DTW forces the path to include every query frame; as
    // query length grows far past the reference's length, most of that
    // excess collapses onto repeated reference columns, and cost/steps
    // drifts toward whatever the reference's *typical* nearest-neighbour
    // distance is -- a property of the reference's own scale, not of
    // whether the query actually matches it. Confirmed empirically: pure
    // random noise's normalized quality drifted from ~12 down to ~9.8 over
    // 20 chunks purely from query length growing, with no floor able to
    // both accept real speech and reject that drift. Capping the window to
    // ~2x the reference length (the point by which a genuine match already
    // converges to near-zero cost, per the "identical audio" test) keeps
    // the comparison meaningful indefinitely -- this is a sliding
    // evaluation window, not a timeout: there's still no time limit on how
    // long the pointer can stall, it just never gets to "coast" on window
    // growth alone.
    final windowCap = segment.referenceFrames.length * 2;
    final windowStart = math.max(_segmentQueryStart, queryLengthSoFar - windowCap);
    final queryWindow = _meanNormalize(_queryFrames.sublist(windowStart, queryLengthSoFar));

    final result = DtwMatcher.distanceWithSteps(queryWindow, segment.referenceFrames);
    final normalized = result.cost / result.steps;
    _lastNormalizedQuality = normalized;

    if (normalized <= _floor) {
      _framesClear++;
    } else {
      _framesClear = 0;
    }

    if (_framesClear < _debounceFrames) return;

    // Segment crossed.
    final now = DateTime.now();
    _completedCheckpoints.add(CheckpointClarity(
      wordIndex: segment.wordIndex,
      phonemeLabel: segment.phonemeLabel,
      normalizedQuality: normalized,
      dwellMs: now.difference(_segmentStart!).inMilliseconds,
    ));
    _segmentQueryStart = queryLengthSoFar;
    _framesClear = 0;
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
