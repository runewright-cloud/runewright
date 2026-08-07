// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_sound_import.dart';

/// Builds one raw Ogg page: capture pattern, header fields, a single-segment
/// lacing table (fine for the small payloads these tests need -- payloads
/// under 255 bytes never need continuation segments), and the payload.
Uint8List _oggPage({
  required Uint8List payload,
  required int granule,
  int serial = 1,
  int seq = 0,
  bool bos = false,
  bool eos = false,
}) {
  final out = BytesBuilder();
  out.add([0x4F, 0x67, 0x67, 0x53]); // "OggS"
  out.addByte(0); // stream structure version
  var headerType = 0;
  if (bos) headerType |= 0x02;
  if (eos) headerType |= 0x04;
  out.addByte(headerType);
  final granuleBytes = ByteData(8)..setInt64(0, granule, Endian.little);
  out.add(granuleBytes.buffer.asUint8List());
  final serialBytes = ByteData(4)..setUint32(0, serial, Endian.little);
  out.add(serialBytes.buffer.asUint8List());
  final seqBytes = ByteData(4)..setUint32(0, seq, Endian.little);
  out.add(seqBytes.buffer.asUint8List());
  out.add([0, 0, 0, 0]); // CRC -- unchecked by this app's parser

  final segments = <int>[];
  var remaining = payload.length;
  while (remaining >= 255) {
    segments.add(255);
    remaining -= 255;
  }
  segments.add(remaining);
  out.addByte(segments.length);
  out.add(segments);
  out.add(payload);
  return out.toBytes();
}

/// A well-formed 30-byte Vorbis identification header packet.
Uint8List _vorbisIdHeader({int channels = 1, int sampleRate = 44100}) {
  final bytes = Uint8List(30);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x01;
  bytes.setRange(1, 7, 'vorbis'.codeUnits);
  data.setUint32(7, 0, Endian.little);
  bytes[11] = channels;
  data.setUint32(12, sampleRate, Endian.little);
  data.setInt32(16, -1, Endian.little);
  data.setInt32(20, -1, Endian.little);
  data.setInt32(24, -1, Endian.little);
  bytes[28] = 0;
  bytes[29] = 0x01; // framing flag
  return bytes;
}

/// A minimal but structurally valid two-page Ogg Vorbis stream: an
/// identification-header page, then a page whose granule position encodes
/// [granule] samples at [sampleRate].
Uint8List _minimalVorbisFile({
  int channels = 1,
  int sampleRate = 44100,
  required int granule,
}) {
  final page0 = _oggPage(payload: _vorbisIdHeader(channels: channels, sampleRate: sampleRate), granule: 0, seq: 0, bos: true);
  final page1 = _oggPage(payload: Uint8List.fromList([0]), granule: granule, seq: 1, eos: true);
  return Uint8List.fromList([...page0, ...page1]);
}

void main() {
  test('rejects source bytes over the pre-parse byte cap without parsing', () async {
    final oversized = Uint8List(kSpellSoundMaxImportBytes + 1);
    await expectLater(importSpellSound(oversized), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects garbage bytes (not Ogg)', () async {
    final garbage = Uint8List.fromList(List.generate(64, (i) => i));
    await expectLater(importSpellSound(garbage), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects RIFF/WAVE bytes wearing an .ogg extension (Finding 1 attack)', () async {
    // "RIFF....WAVE" -- the exact container shape 65 of the 75 pack source
    // files actually are, per docs/SPELL_SOUND_PACK_PLAN.md Finding 1.
    final fakeWav = Uint8List.fromList([
      0x52, 0x49, 0x46, 0x46, // RIFF
      0x24, 0x00, 0x00, 0x00,
      0x57, 0x41, 0x56, 0x45, // WAVE
      ...List.filled(20, 0),
    ]);
    await expectLater(importSpellSound(fakeWav), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects a truncated file', () async {
    final valid = _minimalVorbisFile(granule: 44100);
    final truncated = valid.sublist(0, valid.length - 5);
    await expectLater(importSpellSound(truncated), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects an Ogg container carrying a non-Vorbis codec', () async {
    final fakeOpusHeader = Uint8List(30);
    fakeOpusHeader.setRange(0, 8, 'OpusHead'.codeUnits);
    final page0 = _oggPage(payload: fakeOpusHeader, granule: 0, bos: true, eos: true);
    await expectLater(importSpellSound(page0), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects more than 2 channels', () async {
    final eightChannel = _minimalVorbisFile(channels: 8, granule: 44100);
    await expectLater(importSpellSound(eightChannel), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects a duration over the 6s cap', () async {
    // 300,000 samples at 44100 Hz ≈ 6.8s.
    final tooLong = _minimalVorbisFile(sampleRate: 44100, granule: 300000);
    await expectLater(importSpellSound(tooLong), throwsA(isA<SpellSoundImportException>()));
  });

  test('rejects a stream whose granule positions never resolve to a duration '
      '(the "negative duration" attack: every page uses -1, so the parser never '
      'lets a negative or nonsensical value produce a duration in the first place)',
      () async {
    final page0 = _oggPage(payload: _vorbisIdHeader(), granule: -1, bos: true);
    final page1 = _oggPage(payload: Uint8List.fromList([0]), granule: -1, seq: 1, eos: true);
    final neverResolves = Uint8List.fromList([...page0, ...page1]);
    await expectLater(importSpellSound(neverResolves), throwsA(isA<SpellSoundImportException>()));
  });

  test('accepts a well-formed minimal Vorbis stream and reports correct fields', () async {
    // 22050 samples at 44100 Hz = 0.5s.
    final valid = _minimalVorbisFile(channels: 2, sampleRate: 44100, granule: 22050);
    final result = await importSpellSound(valid);

    expect(result.channels, equals(2));
    expect(result.sampleRate, equals(44100));
    expect(result.durationMs, equals(500));
    expect(result.soundHashHex, startsWith('0x'));
    expect(result.soundHashHex.length, equals(66));
  });

  test('same source bytes hash identically across two imports (dedup-friendly)', () async {
    final source = _minimalVorbisFile(granule: 44100);
    final first = await importSpellSound(source);
    final second = await importSpellSound(source);
    expect(first.soundHashHex, equals(second.soundHashHex));
  });

  test('accepts a real transcoded pack file', () async {
    final file = File('assets/sound_pack/spells/zap.ogg');
    final bytes = await file.readAsBytes();
    final result = await importSpellSound(bytes);

    expect(result.channels, equals(1));
    expect(result.sampleRate, equals(44100));
    expect(result.durationMs, greaterThan(0));
    expect(result.durationMs, lessThanOrEqualTo(kSpellSoundMaxDurationMs));
  });
}
