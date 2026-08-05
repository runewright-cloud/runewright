// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_enrollment_test.dart — unit tests for VocalEnrollment
// (lib/practice/vocal_enrollment.dart) and PerUserEnrolledTemplateSource's
// enrolled/fallback split, using an injected temp directory (no
// path_provider / Flutter binding needed).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/vocal_enrollment.dart';
import 'package:rune_duel/sorcerer/vocal_template_source.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

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

    expect(enrollment.hasEnrollment(VocalSlot.fire), isFalse);
    final result =
        await enrollment.saveFromRecording(VocalSlot.fire, take);
    expect(result.frameCount,
        greaterThanOrEqualTo(VocalEnrollment.minVoicedFrames));
    expect(result.takeCount, 1);
    expect(enrollment.hasEnrollment(VocalSlot.fire), isTrue);
    expect(enrollment.enrolledWords(), {VocalSlot.fire});

    final frames = await enrollment.loadFrames(VocalSlot.fire);
    expect(frames, isNotNull);
    expect(frames!.length, result.frameCount);
    expect(frames.first.length, MfccExtractor.numCoeffs);

    await enrollment.clearAll();
    expect(enrollment.enrolledWords(), isEmpty);
    expect(await enrollment.loadFrames(VocalSlot.fire), isNull);
  });

  test('saveFromRecording accumulates multiple takes (FIFO past maxTakes)',
      () async {
    final take = _padded(_chirpPcm(4800, startFreq: 300, endFreq: 900), 8000);
    for (int i = 1; i <= VocalEnrollment.maxTakes; i++) {
      final r = await enrollment.saveFromRecording(VocalSlot.fire, take);
      expect(r.takeCount, i);
    }
    expect(enrollment.takeCount(VocalSlot.fire), VocalEnrollment.maxTakes);
    final takes = await enrollment.loadTakes(VocalSlot.fire);
    expect(takes!.length, VocalEnrollment.maxTakes);

    // One more caps at maxTakes (oldest dropped, not appended past the cap).
    final r = await enrollment.saveFromRecording(VocalSlot.fire, take);
    expect(r.takeCount, VocalEnrollment.maxTakes);

    // removeTake drops one; clearing the last deletes the word's enrollment.
    await enrollment.removeTake(VocalSlot.fire, 0);
    expect(enrollment.takeCount(VocalSlot.fire), VocalEnrollment.maxTakes - 1);
  });

  test('an over-long recording throws EnrollmentException', () async {
    // A voiced span well past maxVoicedFrames (~2s): a long chirp.
    final tooLong = _padded(
        _chirpPcm(16000 * 3, startFreq: 300, endFreq: 900), 16000 * 3 + 4000);
    await expectLater(
      enrollment.saveFromRecording(VocalSlot.water, tooLong),
      throwsA(isA<EnrollmentException>()),
    );
    expect(enrollment.hasEnrollment(VocalSlot.water), isFalse);
  });

  test('legacy single-frames format loads as a one-take set', () async {
    // Write the OLD {"frames": [...]} format directly, then read via the new
    // multi-take API — back-compat migration path.
    final frames = MfccExtractor.extract(
        _padded(_chirpPcm(4800, startFreq: 300, endFreq: 900), 8000));
    enrollment.baseDir.createSync(recursive: true);
    File('${enrollment.baseDir.path}/terra.json')
        .writeAsStringSync(jsonEncode({'frames': frames}));
    final takes = await enrollment.loadTakes(VocalSlot.earth);
    expect(takes, isNotNull);
    expect(takes!.length, 1);
    expect(takes.first.length, frames.length);
  });

  test('a too-quiet/too-short recording throws EnrollmentException', () async {
    // All-silence take: trims to nothing.
    await expectLater(
      enrollment.saveFromRecording(VocalSlot.water, Uint8List(16000)),
      throwsA(isA<EnrollmentException>()),
    );
    // A blip far shorter than minVoicedFrames.
    final blip = _padded(_chirpPcm(800, startFreq: 300, endFreq: 900), 4000);
    await expectLater(
      enrollment.saveFromRecording(VocalSlot.water, blip),
      throwsA(isA<EnrollmentException>()),
    );
    expect(enrollment.hasEnrollment(VocalSlot.water), isFalse);
  });

  test('PerUserEnrolledTemplateSource serves enrolled words and falls back '
      'per-word, with invalidate() picking up new enrollments', () async {
    final fallbackFrames = MfccExtractor.extract(
        _chirpPcm(3200, startFreq: 2000, endFreq: 2600));
    final fallback = _FixedTemplateSource(fallbackFrames);
    final source = PerUserEnrolledTemplateSource(
        enrollment: enrollment, fallback: fallback);

    // Nothing enrolled: fallback template comes through.
    final before = await source.templateFor(VocalSlot.earth);
    expect(before.mfccFrames, same(fallbackFrames));

    // Enroll terra, invalidate, and the enrolled frames replace it.
    final take = _padded(_chirpPcm(4800, startFreq: 300, endFreq: 900), 8000);
    final result = await enrollment.saveFromRecording(VocalSlot.earth, take);
    source.invalidate();
    final after = await source.templateFor(VocalSlot.earth);
    expect(after.mfccFrames.length, result.frameCount);
    expect(after.checkpointFrameIndices, [result.frameCount - 1]);

    // Other words still fall back.
    final other = await source.templateFor(VocalSlot.air);
    expect(other.mfccFrames, same(fallbackFrames));
  });
}

class _FixedTemplateSource implements VocalTemplateSource {
  _FixedTemplateSource(this.frames);

  final List<List<double>> frames;

  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async => VocalTemplate(
        word: word,
        mfccFrames: frames,
        checkpointFrameIndices: [frames.length - 1],
        checkpointLabels: [word.name],
      );

  @override
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async =>
      [await templateFor(word)];
}
