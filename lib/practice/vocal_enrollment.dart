// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_enrollment.dart — VocalEnrollment: persistence and audio
// processing for per-user voice templates (Practice Mode).
//
// Why this exists (2026-07-16): the MFCC+DTW metric's absolute costs are
// uncalibratable across speakers, but its *ranking* across the closed
// 5-word vocabulary is reliable when the reference templates are the same
// voice as the query — measured 5/5 correct argmin with >= 1.0 margins
// same-voice vs 2/5 cross-voice (see docs/M4_findings.md, 2026-07-16
// entry). So the player records each word once, and those recordings
// replace the Piper renders as the scoring references. The Piper renders
// remain the *pronunciation model* the player hears and imitates.
//
// Storage: <app documents>/practice_enrollment/<word>.json, same schema as
// the bundled assets/practice_templates/*.json ({"frames": [[13 doubles]]})
// so PerUserEnrolledTemplateSource can treat both identically. Local-only,
// never leaves the device, consensus-invisible.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../sorcerer/mfcc.dart';
import '../sorcerer/vocal_score.dart';

/// Thrown when an enrollment recording can't yield a usable template
/// (too quiet, too short). The message is user-presentable.
class EnrollmentException implements Exception {
  const EnrollmentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Persistence + processing for per-user vocal templates. [baseDir] is
/// injectable for tests; production callers use [VocalEnrollment.open],
/// which anchors it under the app documents directory (same pattern as
/// lib/spells/*).
class VocalEnrollment {
  VocalEnrollment(this.baseDir);

  final Directory baseDir;

  static Future<VocalEnrollment> open() async {
    final docs = await getApplicationDocumentsDirectory();
    return VocalEnrollment(Directory('${docs.path}/practice_enrollment'));
  }

  /// A recording must keep at least this many voiced MFCC frames (~10ms
  /// each) after trimming to count as a real utterance.
  static const int minVoicedFrames = 20;

  /// Frames kept as padding on each side of the detected voiced span.
  static const int trimPaddingFrames = 3;

  File _fileFor(VocalWord word) => File('${baseDir.path}/${word.name}.json');

  bool hasEnrollment(VocalWord word) => _fileFor(word).existsSync();

  Set<VocalWord> enrolledWords() =>
      VocalWord.values.where(hasEnrollment).toSet();

  Future<List<List<double>>?> loadFrames(VocalWord word) async {
    final file = _fileFor(word);
    if (!file.existsSync()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return (json['frames'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();
  }

  /// Trims leading/trailing silence from [pcm] (PCM-16 LE mono, 16 kHz),
  /// extracts MFCC frames, validates the result, and persists it as
  /// [word]'s template. Returns the stored frame count.
  ///
  /// Throws [EnrollmentException] when the recording is too quiet or the
  /// voiced span too short to be a usable reference.
  Future<int> saveFromRecording(VocalWord word, Uint8List pcm) async {
    final trimmed = trimSilence(pcm);
    final frames = MfccExtractor.extract(trimmed);
    if (frames.length < minVoicedFrames) {
      throw const EnrollmentException(
          'Recording was too quiet or too short — say the word clearly, '
          'a little louder, and try again.');
    }
    await baseDir.create(recursive: true);
    await _fileFor(word).writeAsString(jsonEncode({'frames': frames}));
    return frames.length;
  }

  Future<void> clearAll() async {
    if (baseDir.existsSync()) await baseDir.delete(recursive: true);
  }

  /// Cuts [pcm] down to its voiced span: per-10ms-hop RMS, voiced =
  /// above max(absolute epsilon, 10% of peak RMS), first-to-last voiced
  /// hop plus [trimPaddingFrames] padding. Returns an empty buffer when
  /// nothing voiced was found.
  static Uint8List trimSilence(Uint8List pcm) {
    const hop = 160; // 10ms at 16 kHz, matches MfccExtractor's stride
    final bd = ByteData.sublistView(pcm);
    final totalSamples = pcm.length ~/ 2;
    final hopCount = totalSamples ~/ hop;
    if (hopCount == 0) return Uint8List(0);

    final rms = List<double>.generate(hopCount, (i) {
      var sum = 0.0;
      for (int s = i * hop; s < (i + 1) * hop; s++) {
        final v = bd.getInt16(s * 2, Endian.little) / 32768.0;
        sum += v * v;
      }
      return math.sqrt(sum / hop);
    });

    final peak = rms.reduce(math.max);
    final threshold = math.max(0.004, peak * 0.1);
    int first = -1, last = -1;
    for (int i = 0; i < hopCount; i++) {
      if (rms[i] >= threshold) {
        if (first < 0) first = i;
        last = i;
      }
    }
    if (first < 0) return Uint8List(0);

    final startHop = math.max(0, first - trimPaddingFrames);
    final endHop = math.min(hopCount, last + 1 + trimPaddingFrames);
    return Uint8List.sublistView(pcm, startHop * hop * 2, endHop * hop * 2);
  }
}
