// SPDX-License-Identifier: GPL-3.0-or-later
//
// basic_spells_test.dart — the shipped starter-spell registry.
//
// Two things are checked: (1) the generated registry (lib/spells/basic_spells.dart)
// agrees with the bundled assets it describes — this is the transcription check
// that fails loudly if scripts/export_basic_spells.dart's output ever drifts from
// what actually ships; (2) isBasicSpell/isBasicGridAndT behave correctly,
// including the hex-normalization edge case (Basic Earthworks' spellHashHex has a
// leading zero byte).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/spell_asset.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the registry lists exactly the five basic spells', () {
    expect(kBasicSpells.length, 5);
    expect(
      kBasicSpells.map((e) => e.slug).toSet(),
      {
        'basic_firebolt',
        'basic_speedboost',
        'basic_manabond',
        'basic_earthworks',
        'basic_windhound',
      },
    );
  });

  test('every bundled asset parses as a SpellAsset matching its registry entry', () async {
    for (final entry in kBasicSpells) {
      final raw = await rootBundle.loadString(entry.assetPath);
      final spell = SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      expect(spell.id, entry.slug, reason: '${entry.slug}: id must equal the slug');
      expect(spell.name, entry.name);
      expect(spell.t, entry.t);
      expect(
        spell.commitmentHex.toLowerCase(),
        entry.commitmentHex.toLowerCase(),
      );
      expect(
        spell.spellHashHex.toLowerCase(),
        entry.spellHashHex.toLowerCase(),
      );
      expect(spell.proofBytes, isNotEmpty, reason: '${entry.slug}: must carry a real proof');
    }
  });

  test('bundled Windhound is a summon; the four elemental basics are not', () async {
    for (final entry in kBasicSpells) {
      final raw = await rootBundle.loadString(entry.assetPath);
      final spell = SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(spell.isSummon, entry.slug == 'basic_windhound');
    }
  });

  group('isBasicSpell / isBasicGridAndT', () {
    Future<SpellAsset> loadBundled(String slug) async {
      final entry = kBasicSpells.firstWhere((e) => e.slug == slug);
      final raw = await rootBundle.loadString(entry.assetPath);
      return SpellAsset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }

    test('every bundled basic spell is recognized as basic', () async {
      for (final entry in kBasicSpells) {
        final spell = await loadBundled(entry.slug);
        expect(isBasicSpell(spell), isTrue, reason: entry.slug);
        expect(isBasicGridAndT(spell.commitmentHex, spell.t), isTrue, reason: entry.slug);
      }
    });

    test('an ordinary spell is not recognized as basic', () {
      final ordinary = SpellAsset(
        id: 'ordinary-1',
        createdAt: DateTime.utc(2026, 7, 27),
        tier: 12,
        t: 5,
        ownerPubkeyHex: '0x${'1' * 64}',
        manaCost: 10,
        segmentCount: 1,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0),
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: 'Some Player Spell',
        commitmentHex: '0xaabbcc',
        spellHashHex: '0xddeeff',
      );
      expect(isBasicSpell(ordinary), isFalse);
      expect(isBasicGridAndT('0xaabbcc', 5), isFalse);
    });

    test('a basic grid commitment at the WRONG T is not recognized', () {
      final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
      expect(isBasicGridAndT(firebolt.commitmentHex, firebolt.t), isTrue);
      expect(isBasicGridAndT(firebolt.commitmentHex, firebolt.t + 1), isFalse);
    });

    test('commitmentHex comparison is case- and prefix-insensitive', () {
      final firebolt = kBasicSpells.firstWhere((e) => e.slug == 'basic_firebolt');
      final noPrefix = firebolt.commitmentHex.substring(2);
      final upper = firebolt.commitmentHex.toUpperCase();

      expect(isBasicGridAndT(noPrefix, firebolt.t), isTrue);
      expect(isBasicGridAndT(upper, firebolt.t), isTrue);
    });

    test('isBasicSpell tolerates a leading-zero-byte spellHashHex', () {
      // Basic Earthworks' spellHashHex begins with a zero byte
      // (0x00ce1c5c...) — the exact case a naive numeric-parse comparison
      // (e.g. BigInt.parse, as spell_authorization.dart's private _hexEq
      // uses) would silently normalize away, masking a real
      // 64-vs-63-hex-digit mismatch elsewhere. _normHex's explicit
      // string-level padLeft is what this test guards.
      final earthworks = kBasicSpells.firstWhere((e) => e.slug == 'basic_earthworks');
      expect(earthworks.spellHashHex.startsWith('0x00'), isTrue);

      final spell = SpellAsset(
        id: 'earthworks-shorthand',
        createdAt: DateTime.utc(2026, 7, 27),
        tier: 12,
        t: earthworks.t,
        ownerPubkeyHex: '0x${'1' * 64}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0),
        proofBytes: Uint8List.fromList([1]),
        name: 'Basic Earthworks',
        commitmentHex: earthworks.commitmentHex.toUpperCase(),
        // Same value with the leading zero byte's hex digits dropped, as a
        // naive BigInt-style parse would render it.
        spellHashHex: earthworks.spellHashHex.substring(4),
      );
      expect(isBasicSpell(spell), isTrue);
    });
  });
}
