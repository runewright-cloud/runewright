// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_import.dart — attacker-controlled image bytes in, safe canonical
// re-encoded bytes out. Decode/resize/re-encode runs off the UI isolate
// (Flutter's `compute`), wrapped in a wall-clock timeout on the caller side.
//
// Format note: the umbrella custom-art prompt specifies "canonical WebP."
// The `image` pub package (the P1-accepted dependency) only DECODES WebP --
// its installed 4.8.0 source has lib/src/formats/webp_decoder.dart but no
// webp_encoder.dart. Re-encoding to WebP would need a second package or a
// native binary dependency, so P1 canonicalizes to JPEG instead: same caps,
// same hashing, same "small bounded raster" goal, just a different
// container. Called out in the P1 report and docs/M4_findings.md, not
// silently substituted.

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class SpellArtImportException implements Exception {
  SpellArtImportException(this.message);
  final String message;
  @override
  String toString() => 'SpellArtImportException: $message';
}

class SpellArtBytes {
  const SpellArtBytes({
    required this.full,
    required this.thumb,
    required this.artHashHex,
  });

  final Uint8List full;
  final Uint8List thumb;

  /// Hex SHA-256 of [full], "0x"-prefixed to match this codebase's hex
  /// convention (commitmentHex, spellHashHex) -- though this hash has
  /// nothing to do with Poseidon2 or the circuit; it is a plain integrity/
  /// dedup check over opaque cosmetic bytes.
  final String artHashHex;
}

/// Pre-decode caps -- checked before any pixel decode runs.
const int kSpellArtMaxImportBytes = 8 * 1024 * 1024;
const int kSpellArtMaxImportDimension = 4096;

/// Re-encode targets. See this file's header for why JPEG, not WebP.
const int kSpellArtFullCanvasPx = 512;
const int kSpellArtThumbCanvasPx = 256;
const int kSpellArtFullByteCeiling = 256 * 1024;
const int kSpellArtThumbByteCeiling = 32 * 1024;

const Duration _kDecodeTimeout = Duration(seconds: 20);

/// Validates, decodes, downscales, and re-encodes [sourceBytes] (raw file
/// bytes from an image picker) into the two canonical sizes this app stores.
///
/// Treats [sourceBytes] as hostile: enforces the byte-size cap before any
/// decode, runs the actual decode/encode on a background isolate via
/// [compute] (so a slow or malicious image never blocks the UI thread), and
/// wraps that with a wall-clock timeout. Throws [SpellArtImportException]
/// with a user-facing message on any failure -- callers should treat that as
/// "couldn't import this image," never let it propagate as a crash.
Future<SpellArtBytes> importSpellArt(Uint8List sourceBytes) async {
  if (sourceBytes.length > kSpellArtMaxImportBytes) {
    throw SpellArtImportException(
      'That image is too large (max ${kSpellArtMaxImportBytes ~/ (1024 * 1024)} MB).',
    );
  }

  final (full, thumb) = await compute(_decodeAndEncode, sourceBytes).timeout(
    _kDecodeTimeout,
    onTimeout: () => throw SpellArtImportException('That image took too long to process.'),
  );

  final hash = await Sha256().hash(full);
  final hex = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return SpellArtBytes(full: full, thumb: thumb, artHashHex: '0x$hex');
}

/// Runs on a background isolate (via [compute]). Pure and synchronous so it
/// can cross the isolate boundary cleanly; exceptions thrown here propagate
/// back to the caller's Future.
(Uint8List, Uint8List) _decodeAndEncode(Uint8List sourceBytes) {
  final decoder = img.findDecoderForData(sourceBytes);
  if (decoder == null) {
    throw SpellArtImportException('Unrecognized image format (PNG, JPEG, or WebP only).');
  }

  // Header-only parse (e.g. PNG IHDR) -- reads declared dimensions without
  // inflating pixel data, so a compression-bomb file is rejected before the
  // expensive full decode below.
  final info = decoder.startDecode(sourceBytes);
  if (info == null) {
    throw SpellArtImportException('Could not read that image.');
  }
  if (info.width > kSpellArtMaxImportDimension || info.height > kSpellArtMaxImportDimension) {
    throw SpellArtImportException(
      'That image is too large (max $kSpellArtMaxImportDimension'
      '×$kSpellArtMaxImportDimension pixels).',
    );
  }

  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw SpellArtImportException('Could not decode that image.');
  }

  final full = _encodeCanonical(decoded, kSpellArtFullCanvasPx, kSpellArtFullByteCeiling);
  final thumb = _encodeCanonical(decoded, kSpellArtThumbCanvasPx, kSpellArtThumbByteCeiling);
  return (full, thumb);
}

/// Center-crops [src] to square, resizes to [canvasPx]x[canvasPx], strips
/// metadata, and JPEG-encodes it, backing off quality until it fits under
/// [byteCeiling].
Uint8List _encodeCanonical(img.Image src, int canvasPx, int byteCeiling) {
  final side = src.width < src.height ? src.width : src.height;
  final cropped = img.copyCrop(
    src,
    x: (src.width - side) ~/ 2,
    y: (src.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized = img.copyResize(
    cropped,
    width: canvasPx,
    height: canvasPx,
    interpolation: img.Interpolation.average,
  );
  // copyCrop/copyResize carry the source Image's EXIF forward (intentionally,
  // so orientation-aware resizing works) -- explicitly clear it here so no
  // source metadata (camera make/model, GPS, timestamps) survives into the
  // stored art.
  resized.exif = img.ExifData();

  const qualitySteps = [90, 80, 65, 50, 35];
  for (final quality in qualitySteps) {
    final bytes = img.encodeJpg(resized, quality: quality);
    if (bytes.length <= byteCeiling) return bytes;
  }
  // Even the lowest quality step didn't fit -- return it anyway. The ceiling
  // is a soft target for typical photos, not a hard invariant enforced by
  // further downscaling; P1 art is cosmetic, not a hard-size guarantee.
  return img.encodeJpg(resized, quality: qualitySteps.last);
}
