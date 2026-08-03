// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_diagnostics.dart — VocalDiagnostics: opt-in capture of practice
// attempt clips as WAV files, for offline threshold calibration against the
// player's real voice (see test/practice/vocal_calibration.dart).
//
// Why (2026-07-22): the streaming scorer's operating point (floor/margin/
// debounce) was calibrated against Piper synthetic voices and stalls/cross-
// confuses on a real human enrollment. Fixing that needs real attempt
// recordings scored against the real enrollment templates. This writes those
// recordings, labelled by target word, to
//   <app documents>/practice_diagnostics/<word>_<epochMs>.wav
// so they can be pulled (adb shell run-as com.runeduel.rune_duel \
//   tar cf - app_flutter/practice_diagnostics | ...) and fed to the harness.
//
// Local-only, consensus-invisible, off by default — this is a dev/calibration
// tool, not a shipping feature. Same PCM-16 mono 16 kHz convention as
// enrollment and the bundled templates.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../sorcerer/mfcc.dart';
import '../sorcerer/vocal_score.dart';

class VocalDiagnostics {
  VocalDiagnostics(this.baseDir);

  final Directory baseDir;

  static Future<VocalDiagnostics> open() async {
    final docs = await getApplicationDocumentsDirectory();
    return VocalDiagnostics(Directory('${docs.path}/practice_diagnostics'));
  }

  /// Count of saved attempt clips per word (for the UI's rep counter).
  Map<VocalWord, int> attemptCounts() {
    final counts = {for (final w in VocalWord.values) w: 0};
    if (!baseDir.existsSync()) return counts;
    for (final f in baseDir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.wav')) continue;
      final name = f.uri.pathSegments.last.split('_').first;
      final word =
          VocalWord.values.where((w) => w.name == name).firstOrNull;
      if (word != null) counts[word] = counts[word]! + 1;
    }
    return counts;
  }

  /// Writes [pcm] (PCM-16 LE mono, 16 kHz — the raw capture, NOT trimmed:
  /// the harness runs the real scorer which does its own gating) as a WAV
  /// labelled by [word]. Returns the file written.
  Future<File> saveAttempt(VocalWord word, Uint8List pcm) async {
    await baseDir.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final file = File('${baseDir.path}/${word.name}_$ts.wav');
    await file.writeAsBytes(_wrapWav(pcm, MfccExtractor.sampleRate));
    return file;
  }

  Future<void> clearAll() async {
    if (baseDir.existsSync()) await baseDir.delete(recursive: true);
  }

  /// Minimal canonical RIFF/WAVE header for mono PCM-16 [pcm] at [sampleRate].
  static Uint8List _wrapWav(Uint8List pcm, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final dataLen = pcm.length;
    final out = BytesBuilder();
    void str(String s) => out.add(s.codeUnits);
    void u32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    void u16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      out.add(b.buffer.asUint8List());
    }

    str('RIFF');
    u32(36 + dataLen);
    str('WAVE');
    str('fmt ');
    u32(16); // PCM fmt chunk size
    u16(1); // audio format = PCM
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bitsPerSample);
    str('data');
    u32(dataLen);
    out.add(pcm);
    return out.toBytes();
  }
}
