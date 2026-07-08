// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_scorer.dart — VocalScorer abstract interface, AmbientCalibrator,
// and VocalScorerFactory.
//
// The battle layer (TurnLoop, SpellCastAction) depends only on VocalScorer.
// Concrete implementations (ReferenceMatchVocalScorer, SherpaVocalScorer) are
// never imported by battle code; only the factory is.
//
// Per-cast lifecycle:
//   1. Match start  — AmbientCalibrator.measure() → ambientFloorRms (once)
//   2. Cast begins  — await scorer.beginCapture(targetWord)
//   3. Player speaks
//   4. Cast window closes — score = await scorer.endCapture(ambientFloorRms: ...)
//   5. score is attached to SpellCastAction.vocalScore and committed
//   6. Match end    — await scorer.dispose()

import 'dart:typed_data';

import 'package:record/record.dart';

import 'mfcc.dart';
import 'reference_match_vocal_scorer.dart';
import 'vocal_score.dart';

// ── Abstract interface ────────────────────────────────────────────────────────

/// Interface for Sorcerer-mode vocal capture and scoring.
///
/// Implementations must not be imported by battle-layer code. Use
/// [VocalScorerFactory.create] to obtain an instance.
abstract class VocalScorer {
  /// Opens the microphone and begins buffering audio for one cast.
  ///
  /// [targetWord] is the expected incantation. The implementation uses it to
  /// select the reference template or keyword for pronunciation scoring.
  /// Must not be called while a capture is already in progress.
  Future<void> beginCapture(VocalWord targetWord);

  /// Stops the microphone and returns the computed [VocalScore].
  ///
  /// [ambientFloorRms] is the noise-floor measurement from
  /// [AmbientCalibrator.measure], used to normalise the volume component.
  Future<VocalScore> endCapture({required double ambientFloorRms});

  /// Releases audio resources. Do not call during an active capture.
  Future<void> dispose();
}

// ── Ambient noise calibration ─────────────────────────────────────────────────

class AmbientCalibrator {
  AmbientCalibrator._();

  /// Records [duration] of ambient audio and returns the RMS noise floor.
  ///
  /// Call once at match start (before the first [VocalScorer.beginCapture]).
  /// Pass the returned value to every [VocalScorer.endCapture] call.
  ///
  /// Returns 0.0 if RECORD_AUDIO permission is denied or the microphone
  /// cannot be opened. [VocalScore.volumeFromRms] is a no-op when floor is 0.
  ///
  // TODO(sorcerer): tune [duration] vs match pacing; 3 s is a reasonable
  //   default for an indoor game setting.
  static Future<double> measure({
    Duration duration = const Duration(seconds: 3),
  }) async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) return 0.0;
      final chunks = <Uint8List>[];
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      final sub = stream.listen(chunks.add, onError: (_) {});
      await Future<void>.delayed(duration);
      await sub.cancel();
      await recorder.stop();
      final allBytes = chunks
          .fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c))
          .toBytes();
      return MfccExtractor.computeRms(allBytes);
    } catch (_) {
      return 0.0;
    } finally {
      recorder.dispose();
    }
  }
}

// ── Factory ───────────────────────────────────────────────────────────────────

class VocalScorerFactory {
  VocalScorerFactory._();

  /// Returns the active [VocalScorer] implementation.
  ///
  /// Currently returns [ReferenceMatchVocalScorer] (MFCC+DTW) so the
  /// capture→commit→transmit path works end to end before Sherpa validation.
  /// [SherpaVocalScorer] is the intended default once Latin-phoneme accuracy
  /// has been confirmed; see sherpa_vocal_scorer.dart for the integration steps.
  ///
  /// [templates] — optional pre-extracted MFCC reference templates, keyed by
  /// [VocalWord]. When absent the scorer uses energy-based fallback scoring
  /// (real, audio-dependent, but less accurate than DTW).
  ///
  // TODO(sorcerer): switch to SherpaVocalScorer once validated:
  //   return SherpaVocalScorer(delegate: ReferenceMatchVocalScorer(templates: templates ?? {}));
  static VocalScorer create({
    Map<VocalWord, List<List<double>>>? templates,
  }) =>
      ReferenceMatchVocalScorer(templates: templates ?? {});
}
