// scripts/generate_practice_assets.dart — renders the five Sorcerer-mode
// incantation words through Piper's Italian voice and writes:
//   assets/audio/practice/<word>.wav        — trainer playback clip
//   assets/practice_templates/<word>.json   — MFCC reference frames for
//                                              StreamingPhonemeScorer
//
// Both files come from the SAME Piper render per word — the wav is Piper's
// raw output copied verbatim; the json is that same audio resampled to 16
// kHz and run through MfccExtractor. There is no separate phoneme-driven
// pass and no second render, so the trainer audio and the scoring target
// cannot silently diverge (see lib/practice/latin_phonemes.dart's header for
// why that guarantee matters — e.g. ignis's ɲː palatalization).
//
// Toolchain (not committed to the repo — see docs/M4_findings.md):
//   Piper 2023.11.14-2 (piper_linux_x86_64.tar.gz), self-contained release
//   with bundled espeak-ng + onnxruntime, installed to ~/.piper/piper-bin/.
//   Voice: rhasspy/piper-voices it_IT-paola-medium (medium quality, the
//   better of the two available Italian voices; riccardo is x_low only),
//   installed to ~/.piper/voices/. sha256 of the .onnx is pinned below so a
//   re-fetch can be verified byte-identical.
//
// Run with: dart run scripts/generate_practice_assets.dart
// Requires: ~/.piper/piper-bin/piper and ~/.piper/voices/it_IT-paola-medium.onnx
//   present (see docs/M4_findings.md for the exact install commands).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

const String kExpectedOnnxSha256 =
    '6fc918b5a0ea6137382833dddfa567bffbe6a5060c02043c87192ee59c04210c';

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final piperBin = '$home/.piper/piper-bin/piper';
  final piperLibDir = '$home/.piper/piper-bin';
  final voiceModel = '$home/.piper/voices/it_IT-paola-medium.onnx';

  if (!File(piperBin).existsSync() || !File(voiceModel).existsSync()) {
    stderr.writeln('Piper binary or voice model not found. See '
        'docs/M4_findings.md for install steps. Expected:\n'
        '  $piperBin\n  $voiceModel');
    exitCode = 1;
    return;
  }

  final actualSha = sha256.convert(File(voiceModel).readAsBytesSync()).toString();
  if (actualSha != kExpectedOnnxSha256) {
    stderr.writeln('WARNING: $voiceModel sha256 ($actualSha) does not match '
        'the pinned $kExpectedOnnxSha256 — voice model may have changed.');
  }

  final audioDir = Directory('assets/audio/practice')..createSync(recursive: true);
  final templateDir = Directory('assets/practice_templates')..createSync(recursive: true);

  for (final word in VocalWord.values) {
    stdout.writeln('Rendering ${word.name}...');
    final wavBytes = await _renderWithPiper(
      piperBin: piperBin,
      piperLibDir: piperLibDir,
      voiceModel: voiceModel,
      text: word.name,
    );

    final wavFile = File('${audioDir.path}/${word.name}.wav');
    wavFile.writeAsBytesSync(wavBytes);

    final wav = _WavPcm16.parse(wavBytes);
    final resampled = _resampleLinear(
      wav.samples,
      fromRate: wav.sampleRate,
      toRate: MfccExtractor.sampleRate,
    );
    final pcmBytes = _floatToPcm16Le(resampled);
    final frames = MfccExtractor.extract(pcmBytes);

    final templateFile = File('${templateDir.path}/${word.name}.json');
    templateFile.writeAsStringSync(jsonEncode({
      'word': word.name,
      'sampleRate': MfccExtractor.sampleRate,
      'frames': frames,
    }));

    stdout.writeln('  ${wavFile.path} (${wav.sampleRate} Hz, '
        '${wav.samples.length} samples)');
    stdout.writeln('  ${templateFile.path} (${frames.length} frames)');
  }

  stdout.writeln('Done.');
}

Future<Uint8List> _renderWithPiper({
  required String piperBin,
  required String piperLibDir,
  required String voiceModel,
  required String text,
}) async {
  final tmp = await File(
    '${Directory.systemTemp.path}/practice_asset_${text}_${DateTime.now().microsecondsSinceEpoch}.wav',
  ).create();
  try {
    final process = await Process.start(
      piperBin,
      ['--model', voiceModel, '--output_file', tmp.path],
      environment: {'LD_LIBRARY_PATH': piperLibDir},
    );
    process.stdin.writeln(text);
    await process.stdin.close();
    final exit = await process.exitCode;
    if (exit != 0) {
      final err = await process.stderr.transform(utf8.decoder).join();
      throw ProcessException(piperBin, [], 'piper exited $exit: $err');
    }
    return await tmp.readAsBytes();
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

/// Minimal RIFF/WAVE reader for Piper's own output: PCM, mono, 16-bit.
class _WavPcm16 {
  _WavPcm16({required this.sampleRate, required this.samples});

  final int sampleRate;
  final List<double> samples; // normalised to [-1.0, 1.0]

  static _WavPcm16 parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('not a RIFF/WAVE file');
    }
    int offset = 12;
    int? sampleRate;
    int? bitsPerSample;
    int? numChannels;
    Uint8List? pcm;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final chunkStart = offset + 8;
      if (chunkId == 'fmt ') {
        numChannels = data.getUint16(chunkStart + 2, Endian.little);
        sampleRate = data.getUint32(chunkStart + 4, Endian.little);
        bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
      } else if (chunkId == 'data') {
        pcm = bytes.sublist(chunkStart, chunkStart + chunkSize);
      }
      offset = chunkStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (sampleRate == null || pcm == null) {
      throw const FormatException('missing fmt or data chunk');
    }
    if (numChannels != 1 || bitsPerSample != 16) {
      throw FormatException(
          'expected mono 16-bit PCM, got channels=$numChannels bits=$bitsPerSample');
    }

    final pcmData = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    final samples = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      samples[i] = pcmData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return _WavPcm16(sampleRate: sampleRate, samples: samples);
  }
}

/// Simple linear-interpolation resampler. Adequate for MFCC feature
/// extraction on short offline-generated clips; not intended for
/// broadcast-quality audio (there is no runtime resampling in this
/// pipeline — this only runs once, offline, per asset).
List<double> _resampleLinear(
  List<double> input, {
  required int fromRate,
  required int toRate,
}) {
  if (fromRate == toRate) return input;
  final ratio = fromRate / toRate;
  final outLength = (input.length / ratio).floor();
  return List<double>.generate(outLength, (i) {
    final srcPos = i * ratio;
    final i0 = srcPos.floor();
    final i1 = (i0 + 1).clamp(0, input.length - 1);
    final frac = srcPos - i0;
    return input[i0] * (1 - frac) + input[i1] * frac;
  });
}

Uint8List _floatToPcm16Le(List<double> samples) {
  final bytes = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    final s = (clamped * 32767.0).round();
    bytes.setInt16(i * 2, s, Endian.little);
  }
  return bytes.buffer.asUint8List();
}
