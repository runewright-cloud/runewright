// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_pack_test.dart — the built-in art pack's golden-vector equivalent
// (docs/SPELL_ART_PACK_PLAN.md §8): every entry in the generated catalogue must load
// from the real asset bundle and match its own recorded hash/length exactly. If the
// generator and the shipped .webp files ever drift (stale regeneration, a hand-edit,
// a merge conflict resolved wrong), this is what catches it -- not a passing build.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_pack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const validElements = {'neutral', 'fire', 'air', 'water', 'earth'};

  test('catalogue is non-empty', () {
    expect(kPainterlyPack, isNotEmpty);
  });

  test('every id is unique', () {
    final ids = kPainterlyPack.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('every entry has a valid element', () {
    for (final entry in kPainterlyPack) {
      expect(validElements, contains(entry.element),
          reason: '${entry.id} has element ${entry.element}');
    }
  });

  test('every entry has a level in 1..3', () {
    for (final entry in kPainterlyPack) {
      expect(entry.level, inInclusiveRange(1, 3), reason: entry.id);
    }
  });

  test('every asset loads from the bundle and matches its recorded sha256/length', () async {
    for (final entry in kPainterlyPack) {
      final data = await rootBundle.load(entry.asset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      expect(bytes.length, entry.bytes, reason: '${entry.id}: byte length mismatch');
      final digest = sha256.convert(bytes).toString();
      expect(digest, entry.sha256, reason: '${entry.id}: sha256 mismatch');
    }
  });

  test('loadPackArt returns the matching entry\'s bytes', () async {
    final entry = kPainterlyPack.first;
    final bytes = await loadPackArt(entry.id);
    expect(bytes, isNotNull);
    expect(bytes!.length, entry.bytes);
  });

  test('loadPackArt returns null for an unknown id', () async {
    final bytes = await loadPackArt('does-not-exist-in-any-pack');
    expect(bytes, isNull);
  });

  test('manifest.json matches the generated Dart catalogue exactly', () async {
    final manifestString =
        await rootBundle.loadString('assets/art_pack/painterly/manifest.json');
    final manifest = jsonDecode(manifestString) as Map<String, dynamic>;
    final icons = manifest['icons'] as List<dynamic>;

    expect(icons.length, kPainterlyPack.length);

    final byId = {for (final e in kPainterlyPack) e.id: e};
    for (final raw in icons) {
      final json = raw as Map<String, dynamic>;
      final entry = byId[json['id'] as String];
      expect(entry, isNotNull, reason: '${json['id']} in manifest.json but not in kPainterlyPack');
      expect(entry!.asset, json['asset']);
      expect(entry.subject, json['subject']);
      expect(entry.colour, json['colour']);
      expect(entry.level, json['level']);
      expect(entry.element, json['element']);
      expect(entry.sha256, json['sha256']);
      expect(entry.bytes, json['bytes']);
    }

    expect(kPainterlyLicence.licence, manifest['licence']);
    expect(kPainterlyLicence.licenceUrl, manifest['licenceUrl']);
    expect(kPainterlyLicence.author, manifest['author']);
    expect(kPainterlyLicence.modifications, manifest['modifications']);
  });

  test('kPainterlyLicence renders the attribution footer text', () {
    // Attribution is a licence condition, not a nicety (CC BY-SA 4.0 §3(a)) -- this
    // guards against someone later stripping the credit line from the UI by making
    // the underlying data it must render on impossible to omit silently.
    expect(kPainterlyLicence.author, contains('J. W. Bjerk'));
    expect(kPainterlyLicence.licence, equals('CC BY-SA 4.0'));
    expect(kPainterlyLicence.modifications, isNotEmpty);
  });
}
