// SPDX-License-Identifier: GPL-3.0-or-later
//
// reference_match_vocal_scorer.dart — MFCC+DTW VocalScorer implementation.
//
// Scores pronunciation by comparing captured MFCC features against a
// pre-recorded reference template via Dynamic Time Warping. Volume is scored
// as RMS relative to the calibrated ambient noise floor.
//
// When no reference template is available for the target word, the scorer
// degrades to an energy-based pronunciation proxy (RMS ratio). This is a
// real, audio-dependent score — it varies with the actual audio captured —
// but it measures loudness only, not phoneme shape. The fallback is clearly
// annotated in endCapture().
//
// Reference templates are injected at construction or recorded at runtime via
// recordTemplate(). VocalScorerFactory.create() wires the active instance.

import 'dart:typed_data';

import 'package:record/record.dart';

import 'mfcc.dart';
import 'vocal_score.dart';
import 'vocal_scorer.dart';

/// MFCC+DTW [VocalScorer]. The active implementation while Sherpa-ONNX is
/// pending Latin-phoneme validation. See [VocalScorerFactory.create].
class ReferenceMatchVocalScorer implements VocalScorer {
  ReferenceMatchVocalScorer({
    Map<VocalWord, List<List<double>>>? templates,
  }) : _templates = Map.of(templates ?? {});

  // word → sequence of 13-element MFCC vectors (one per 10 ms frame)
  final Map<VocalWord, List<List<double>>> _templates;

  final AudioRecorder _recorder = AudioRecorder();
  final List<Uint8List> _chunks = [];
  VocalWord? _targetWord;
  bool _capturing = false;

  // ── VocalScorer interface ─────────────────────────────────────────────────

  @override
  Future<void> beginCapture(VocalWord targetWord) async {
    assert(!_capturing, 'beginCapture called while already capturing');
    _targetWord = targetWord;
    _chunks.clear();
    _capturing = true;
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: MfccExtractor.sampleRate,
    ));
    stream.listen(_chunks.add, onError: (_) {}, cancelOnError: false);
  }

  @override
  Future<VocalScore> endCapture({required double ambientFloorRms}) async {
    assert(_capturing, 'endCapture called without a preceding beginCapture');
    _capturing = false;
    await _recorder.stop();

    final allBytes = _chunks
        .fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c))
        .toBytes();
    _chunks.clear();

    final rms = MfccExtractor.computeRms(allBytes);
    final volume = VocalScore.volumeFromRms(rms, ambientFloorRms);

    final target = _targetWord;
    _targetWord = null;

    // Require at least ~0.5 s of audio (8000 samples × 2 bytes) to attempt
    // MFCC extraction; treat anything shorter as silence.
    if (target == null || allBytes.length < MfccExtractor.sampleRate) {
      return VocalScore(pronunciation: 0.0, volume: volume);
    }

    final features = MfccExtractor.extract(allBytes);
    final template = _templates[target];

    final double pronunciation;
    if (template != null && template.isNotEmpty && features.isNotEmpty) {
      // Full MFCC+DTW path — compare against the recorded reference template.
      final dist = DtwMatcher.distance(features, template);
      pronunciation = DtwMatcher.score(dist);
    } else {
      // Energy-based fallback: no reference template is available for this word.
      // The score still varies with the actual audio captured (louder, more
      // confident speech → higher score), but phoneme shape is not checked.
      // Use recordTemplate() to enable the DTW path for this word.
      // TODO(sorcerer): remove once reference templates are bundled as assets.
      pronunciation = volume;
    }

    return VocalScore(pronunciation: pronunciation, volume: volume);
  }

  @override
  Future<void> dispose() async {
    if (_capturing) {
      _capturing = false;
      await _recorder.stop();
    }
    _recorder.dispose();
  }

  // ── Template management ───────────────────────────────────────────────────

  /// Records [duration] of speech for [word] and stores it as the reference
  /// template. Returns the extracted MFCC features.
  ///
  /// Serialise the returned value (e.g. as JSON) and pass it back via the
  /// [templates] constructor argument to persist across sessions.
  ///
  /// Must not be called while [beginCapture]…[endCapture] is in progress.
  Future<List<List<double>>> recordTemplate(
    VocalWord word, {
    Duration duration = const Duration(seconds: 2),
  }) async {
    assert(!_capturing, 'recordTemplate called while a capture is pending');
    final chunks = <Uint8List>[];
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: MfccExtractor.sampleRate,
    ));
    stream.listen(chunks.add, onError: (_) {}, cancelOnError: false);
    await Future<void>.delayed(duration);
    await _recorder.stop();
    final allBytes = chunks
        .fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c))
        .toBytes();
    final features = MfccExtractor.extract(allBytes);
    _templates[word] = features;
    return features;
  }

  /// Unmodifiable view of current templates (for serialisation).
  Map<VocalWord, List<List<double>>> get templates =>
      Map.unmodifiable(_templates);
}
