// SPDX-License-Identifier: GPL-3.0-or-later
//
// sherpa_vocal_scorer.dart — SherpaVocalScorer: Sherpa-ONNX integration scaffold.
//
// NOT YET INTEGRATED. sherpa_onnx is absent from pubspec.yaml until Latin-phoneme
// accuracy has been validated against real recordings of ignis/aer/aqua/terra/finitus.
//
// Integration checklist (complete in order before switching the factory):
//   1. Add to pubspec.yaml:
//        sherpa_onnx: ^1.x.x   (check k2-fsa pub.dev page for current version)
//   2. Bundle the KWS model under assets/models/kws/ and register in pubspec.yaml:
//        encoder.onnx   (~6.7 MB)  ─┐
//        decoder.onnx   (~1.2 MB)  ─┤ sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
//        joiner.onnx    (~0.4 MB)  ─┘
//        tokens.txt
//   3. Run flutter pub get.
//   4. Replace the delegation body below with real KeywordSpotter API calls.
//   5. In VocalScorerFactory.create(), return SherpaVocalScorer(...) instead.
//   6. Delete this comment block once stable.
//
// TODO(sorcerer): validate Latin-phoneme accuracy for ignis, aer, aqua, terra, finitus
//   against the sherpa-onnx-kws-zipformer-gigaspeech-3.3M model before promoting this
//   to the active implementation. Phoneme coverage for short Latin words trained on
//   English GigaSpeech data is an open empirical question.

import 'vocal_score.dart';
import 'vocal_scorer.dart';
import 'reference_match_vocal_scorer.dart';

/// Sherpa-ONNX [KeywordSpotter]-based [VocalScorer] (not yet integrated).
///
/// Currently delegates entirely to [ReferenceMatchVocalScorer] so that the
/// capture→score→transmit path is end-to-end functional while Sherpa
/// validation is in progress. Swap the delegation body for Sherpa API calls
/// once validated (see file-header checklist).
class SherpaVocalScorer implements VocalScorer {
  SherpaVocalScorer({required ReferenceMatchVocalScorer delegate})
      : _delegate = delegate;

  final ReferenceMatchVocalScorer _delegate;

  // ── Sherpa-ONNX fields (uncomment after step 4 above) ────────────────────
  // late final KeywordSpotter _kws;       // from sherpa_onnx package
  // late final OnlineStream _stream;      // per-utterance stream
  // VocalWord? _pendingTarget;
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Future<void> beginCapture(VocalWord targetWord) async {
    // TODO(sorcerer): create a new OnlineStream from _kws here and start
    //   piping PCM chunks into _kws.acceptWaveform(). The keyword to match
    //   is targetWord.name (e.g. 'ignis').
    await _delegate.beginCapture(targetWord);
  }

  @override
  Future<VocalScore> endCapture({required double ambientFloorRms}) async {
    // TODO(sorcerer): finalise _stream, call _kws.decode(), and extract the
    //   confidence score for the pending keyword. Feed it as `pronunciation`.
    //   Compute `volume` from the same PCM buffer via MfccExtractor.computeRms.
    return _delegate.endCapture(ambientFloorRms: ambientFloorRms);
  }

  @override
  Future<void> dispose() async {
    // TODO(sorcerer): _stream.free(); _kws.free();
    await _delegate.dispose();
  }
}
