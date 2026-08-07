// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_import.dart — attacker-controlled Ogg Vorbis bytes in, a
// validated pointer out. Unlike spell_art_import.dart, there is no
// canonicalization step here: there is no Dart audio encoder
// (docs/SPELL_SOUND_PACK_PLAN.md D-3), so imported bytes reach a platform
// codec essentially as supplied. The validation gate below is what carries
// the weight the art path's re-encode carries instead -- a pure-Dart Ogg
// page walk plus a Vorbis identification-header parse, all header-only, no
// sample ever decoded. See D-1 for the full reject list.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SpellSoundImportException implements Exception {
  SpellSoundImportException(this.message);
  final String message;
  @override
  String toString() => 'SpellSoundImportException: $message';
}

class SpellSoundBytes {
  const SpellSoundBytes({
    required this.bytes,
    required this.soundHashHex,
    required this.durationMs,
    required this.sampleRate,
    required this.channels,
  });

  /// The raw, unmodified Ogg Vorbis bytes -- stored as-is (see this file's
  /// header for why there is no re-encode step).
  final Uint8List bytes;

  /// Hex SHA-256 of [bytes], "0x"-prefixed to match this codebase's hex
  /// convention (spell_art_import.dart's artHashHex).
  final String soundHashHex;

  final int durationMs;
  final int sampleRate;
  final int channels;
}

/// Pre-parse cap -- checked before any header parsing runs (D-1: "byte cap
/// before anything else").
const int kSpellSoundMaxImportBytes = 256 * 1024;

/// Post-parse cap on the clip's own declared duration.
const int kSpellSoundMaxDurationMs = 6 * 1000;

const int kSpellSoundMaxChannels = 2;

/// Validates [sourceBytes] as an Ogg Vorbis file (magic bytes, container
/// structure, codec identification, channel count, duration -- all read from
/// headers, no sample ever decoded) and returns a pointer to the
/// unmodified bytes plus their hash. Throws [SpellSoundImportException] with
/// a player-facing message on any failure.
///
/// Deliberately synchronous and off the isolate boundary: unlike image
/// import, the input is capped at [kSpellSoundMaxImportBytes] (256 KB) and
/// this is a header walk, not a pixel decode -- there is no expensive work
/// to move off the UI thread.
Future<SpellSoundBytes> importSpellSound(Uint8List sourceBytes) async {
  if (sourceBytes.length > kSpellSoundMaxImportBytes) {
    throw SpellSoundImportException(
      'That sound is too large (max ${kSpellSoundMaxImportBytes ~/ 1024} KB).',
    );
  }

  final info = _parseOggVorbis(sourceBytes);
  if (info.durationMs > kSpellSoundMaxDurationMs) {
    throw SpellSoundImportException(
      'That sound is too long (max ${kSpellSoundMaxDurationMs ~/ 1000}s).',
    );
  }

  final hash = await Sha256().hash(sourceBytes);
  final hex = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return SpellSoundBytes(
    bytes: sourceBytes,
    soundHashHex: '0x$hex',
    durationMs: info.durationMs,
    sampleRate: info.sampleRate,
    channels: info.channels,
  );
}

class _OggVorbisInfo {
  const _OggVorbisInfo({required this.sampleRate, required this.channels, required this.durationMs});
  final int sampleRate;
  final int channels;
  final int durationMs;
}

const List<int> _kOggCapture = [0x4F, 0x67, 0x67, 0x53]; // "OggS"
const List<int> _kVorbisMagic = [0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]; // "vorbis"
const int _kOggPageHeaderSize = 27; // fixed portion, before the segment table

/// Walks every Ogg page in [bytes] header-only: reads the page framing (never
/// decodes a payload sample), pulls sample rate/channel count from the first
/// page's Vorbis identification header, and takes the clip's duration from
/// the last page carrying a valid (non-sentinel) granule position. Never
/// dispatches on a file extension or trusts anything but the bytes
/// themselves -- callers may hand this a renamed non-Ogg file.
_OggVorbisInfo _parseOggVorbis(Uint8List bytes) {
  if (bytes.length < _kOggPageHeaderSize || !_matchesAt(bytes, 0, _kOggCapture)) {
    throw SpellSoundImportException('Not an Ogg file.');
  }

  final data = ByteData.sublistView(bytes);
  var offset = 0;
  var sampleRate = 0;
  var channels = 0;
  var sawIdentificationHeader = false;
  int? lastValidGranule;

  while (offset < bytes.length) {
    if (offset + _kOggPageHeaderSize > bytes.length) {
      throw SpellSoundImportException('That file is truncated.');
    }
    if (!_matchesAt(bytes, offset, _kOggCapture)) {
      throw SpellSoundImportException('That file is corrupt (bad Ogg page).');
    }

    final granule = data.getInt64(offset + 6, Endian.little);
    final pageSegments = bytes[offset + 26];
    final segmentTableStart = offset + _kOggPageHeaderSize;
    if (segmentTableStart + pageSegments > bytes.length) {
      throw SpellSoundImportException('That file is truncated.');
    }

    var payloadSize = 0;
    for (var i = 0; i < pageSegments; i++) {
      payloadSize += bytes[segmentTableStart + i];
    }
    final payloadStart = segmentTableStart + pageSegments;
    if (payloadStart + payloadSize > bytes.length) {
      throw SpellSoundImportException('That file is truncated.');
    }

    if (!sawIdentificationHeader) {
      final header = _parseIdentificationHeader(bytes, payloadStart, payloadSize);
      sampleRate = header.sampleRate;
      channels = header.channels;
      sawIdentificationHeader = true;
    }

    // -1 (all bits set) is Ogg's "no packet completes on this page" sentinel
    // -- skip it rather than let it corrupt the running duration. Any other
    // negative value is not a valid granule position at all; skipping it too
    // means a maliciously-crafted "negative duration" page can never produce
    // one -- worst case, no page yields a usable granule and duration
    // resolution fails below with a clear error instead of a bogus value.
    if (granule >= 0) lastValidGranule = granule;

    offset = payloadStart + payloadSize;
  }

  if (!sawIdentificationHeader) {
    throw SpellSoundImportException('Not a Vorbis stream.');
  }
  if (lastValidGranule == null) {
    throw SpellSoundImportException('Could not determine that sound\'s duration.');
  }
  if (sampleRate <= 0) {
    throw SpellSoundImportException('That file is corrupt (invalid sample rate).');
  }

  final durationMs = (lastValidGranule * 1000) ~/ sampleRate;
  return _OggVorbisInfo(sampleRate: sampleRate, channels: channels, durationMs: durationMs);
}

class _IdentificationHeader {
  const _IdentificationHeader({required this.sampleRate, required this.channels});
  final int sampleRate;
  final int channels;
}

/// Parses the Vorbis identification header, which per spec is always the
/// entire payload of an Ogg stream's first page. 30 bytes: 1 (packet type)
/// + 6 ("vorbis") + 4 (version) + 1 (channels) + 4 (sample rate) + 12
/// (bitrate max/nominal/min) + 1 (blocksize) + 1 (framing flag).
_IdentificationHeader _parseIdentificationHeader(Uint8List bytes, int start, int length) {
  if (length < 30) {
    throw SpellSoundImportException('Not a Vorbis stream.');
  }
  if (bytes[start] != 0x01 || !_matchesAt(bytes, start + 1, _kVorbisMagic)) {
    throw SpellSoundImportException('Not a Vorbis stream.');
  }
  final data = ByteData.sublistView(bytes);
  final channels = bytes[start + 11];
  final sampleRate = data.getUint32(start + 12, Endian.little);
  final framingFlag = bytes[start + 29];
  if (framingFlag & 0x01 == 0) {
    throw SpellSoundImportException('That file is corrupt (bad Vorbis header).');
  }
  if (channels > kSpellSoundMaxChannels) {
    throw SpellSoundImportException('That sound has too many channels (max $kSpellSoundMaxChannels).');
  }
  if (channels == 0) {
    throw SpellSoundImportException('That file is corrupt (zero channels).');
  }
  return _IdentificationHeader(sampleRate: sampleRate, channels: channels);
}

bool _matchesAt(Uint8List bytes, int offset, List<int> pattern) {
  if (offset + pattern.length > bytes.length) return false;
  for (var i = 0; i < pattern.length; i++) {
    if (bytes[offset + i] != pattern[i]) return false;
  }
  return true;
}
