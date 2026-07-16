// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_enrollment_test.dart — unit tests for VocalEnrollment
// (lib/practice/vocal_enrollment.dart) and PerUserEnrolledTemplateSource's
// enrolled/fallback split, using an injected temp directory (no
// path_provider / Flutter binding needed).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/practice/vocal_enrollment.dart';
import 'package:rune_duel/practice/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

Uint8List _chirpPcm(int samples,
    {required double startFreq, required double endFreq, int amplitude = 20000}) {
  final bytes = ByteData(samples * 2);
  for (int i = 0; i < samples; i++) {
    final t = i / MfccExtractor.sampleRate;
    final freq = startFreq + (endFreq - startFreq) * i / samples;
    final s = (amplitude * math.sin(2 * math.pi * freq * t)).round();
    bytes.setInt16(i * 2, s, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// [voiced] with [padding] samples of digital silence on each side —
/// shaped like a real enrollment take (mic opens early, closes late).
Uint8List _padded(Uint8List voiced, int padding) {
  final out = Uint8List(voiced.length + padding * 4);
  out.setRange(padding * 2, padding * 2 + voiced.length, voiced);
  return out;
}

void main() {
  late Directory tempDir;
  late VocalEnrollment enrollment;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('vocal_enrollment_test');
    enrollment = VocalEnrollment(Directory('${tempDir.path}/enroll'));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('trimSilence cuts the silent padding, keeps the voiced span', () {
    final voiced = _chirpPcm(3200, startFreq: 300, endFreq: 900);
    final padded = _padded(voiced, 8000); // 0.5s silence each side

    final trimmed = VocalEnrollment.trimSilence(padded);

    // Voiced span (3200 samples) + up to trimPaddingFrames * 160 each side.
    const slack = VocalEnrollment.trimPaddingFrames * 160 * 2;
    expect(trimmed.length ~/ 2, greaterThanOrEqualTo(3200 - 320));
    expect(trimmed.length ~/ 2, lessThanOrEqualTo(3200 + 2 * slack));
  });

  test('trimSilence on pure silence returns an empty buffer', () {
    expect(VocalEnrollment.trimSilence(Uint8List(16000)).length, 0);
  });

  test('saveFromRecording -> loadFrames roundtrip, hasEnrollment, clearAll',
      () async {
    final take = _padded(_chirpPcm(4800, startFreq: 300, endFreq: 900), 8000);

    expect(enrollment.hasEnrollment(VocalWord.ignis), isFalse);
    final frameCount =
        await enrollment.saveFromRecording(VocalWord.ignis, take);
    expect(frameCount, greaterThanOrEqualTo(VocalEnrollment.minVoicedFrames));
    expect(enrollment.hasEnrollment(VocalWord.ignis), isTrue);
    expect(enrollment.enrolledWords(), {VocalWord.ignis});

    final frames = await enrollment.loadFrames(VocalWord.ignis);
    expect(frames, isNotNull);
    expect(frames!.length, frameCount);
    expect(frames.first.length, MfccExtractor.numCoeffs);

    await enrollment.clearAll();
    expect(enrollment.enrolledWords(), isEmpty);
    expect(await enrollment.loadFrames(VocalWord.ignis), isNull);
  });

  test('a too-quiet/too-short recording throws EnrollmentException', () async {
    // All-silence take: trims to nothing.
    await expectLater(
      enrollment.saveFromRecording(VocalWord.aqua, Uint8List(16000)),
      throwsA(isA<EnrollmentException>()),
    );
    // A blip far shorter than minVoicedFrames.
    final blip = _padded(_chirpPcm(800, startFreq: 300, endFreq: 900), 4000);
    await expectLater(
      enrollment.saveFromRecording(VocalWord.aqua, blip),
      throwsA(isA<EnrollmentException>()),
    );
    expect(enrollment.hasEnrollment(VocalWord.aqua), isFalse);
  });

  test('PerUserEnrolledTemplateSource serves enrolled words and falls back '
      'per-word, with invalidate() picking up new enrollments', () async {
    final fallbackFrames = MfccExtractor.extract(
        _chirpPcm(3200, startFreq: 2000, endFreq: 2600));
    final fallback = _FixedTemplateSource(fallbackFrames);
    final source = PerUserEnrolledTemplateSource(
        enrollment: enrollment, fallback: fallback);

    // Nothing enrolled: fallback template comes through.
    final before = await source.templateFor(VocalWord.terra);
    expect(before.mfccFrames, same(fallbackFrames));

    // Enroll terra, invalidate, and the enrolled frames replace it.
    final take = _padded(_chirpPcm(4800, startFreq: 300, endFreq: 900), 8000);
    final frameCount = await enrollment.saveFromRecording(VocalWord.terra, take);
    source.invalidate();
    final after = await source.templateFor(VocalWord.terra);
    expect(after.mfccFrames.length, frameCount);
    expect(after.checkpointFrameIndices, [frameCount - 1]);

    // Other words still fall back.
    final other = await source.templateFor(VocalWord.aer);
    expect(other.mfccFrames, same(fallbackFrames));
  });
}

class _FixedTemplateSource implements VocalTemplateSource {
  _FixedTemplateSource(this.frames);

  final List<List<double>> frames;

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async => VocalTemplate(
        word: word,
        mfccFrames: frames,
        checkpointFrameIndices: [frames.length - 1],
        checkpointLabels: [word.name],
      );
}
