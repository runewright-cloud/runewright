// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rune_duel/spells/spell_art_import.dart';

Uint8List _samplePng({int width = 300, int height = 200}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  return img.encodePng(image);
}

void main() {
  test('rejects source bytes over the pre-decode byte cap without decoding', () async {
    final oversized = Uint8List(kSpellArtMaxImportBytes + 1);
    await expectLater(
      importSpellArt(oversized),
      throwsA(isA<SpellArtImportException>()),
    );
  });

  test('rejects unrecognized image bytes', () async {
    final garbage = Uint8List.fromList(List.generate(64, (i) => i));
    await expectLater(
      importSpellArt(garbage),
      throwsA(isA<SpellArtImportException>()),
    );
  });

  test('rejects declared dimensions over the pre-decode cap', () async {
    final oversized = _samplePng(width: kSpellArtMaxImportDimension + 100, height: 10);
    await expectLater(
      importSpellArt(oversized),
      throwsA(isA<SpellArtImportException>()),
    );
  });

  test('valid PNG import re-encodes to the canonical square sizes under the byte ceilings',
      () async {
    final source = _samplePng();
    final result = await importSpellArt(source);

    expect(result.full.length, lessThanOrEqualTo(kSpellArtFullByteCeiling));
    expect(result.thumb.length, lessThanOrEqualTo(kSpellArtThumbByteCeiling));
    expect(result.artHashHex, startsWith('0x'));
    expect(result.artHashHex.length, equals(66)); // '0x' + 64 hex chars (SHA-256)

    final decodedFull = img.decodeImage(result.full)!;
    expect(decodedFull.width, equals(kSpellArtFullCanvasPx));
    expect(decodedFull.height, equals(kSpellArtFullCanvasPx));

    final decodedThumb = img.decodeImage(result.thumb)!;
    expect(decodedThumb.width, equals(kSpellArtThumbCanvasPx));
    expect(decodedThumb.height, equals(kSpellArtThumbCanvasPx));
  });

  test('valid JPEG import round-trips too', () async {
    final image = img.Image(width: 400, height: 400);
    img.fill(image, color: img.ColorRgb8(20, 90, 160));
    final source = img.encodeJpg(image, quality: 95);

    final result = await importSpellArt(source);

    expect(result.full.length, lessThanOrEqualTo(kSpellArtFullByteCeiling));
    expect(result.thumb.length, lessThanOrEqualTo(kSpellArtThumbByteCeiling));
  });

  test('re-encoded bytes strip source EXIF metadata', () async {
    final image = img.Image(width: 300, height: 300);
    img.fill(image, color: img.ColorRgb8(10, 10, 10));
    image.exif.imageIfd['Make'] = 'ExampleCam';
    final source = img.encodeJpg(image);

    final result = await importSpellArt(source);
    final decoded = img.decodeImage(result.full)!;

    expect(decoded.exif.imageIfd.isEmpty, isTrue);
  });

  test('same source image hashes identically across two imports (dedup-friendly)', () async {
    final source = _samplePng();
    final first = await importSpellArt(source);
    final second = await importSpellArt(source);

    expect(first.artHashHex, equals(second.artHashHex));
  });
}
