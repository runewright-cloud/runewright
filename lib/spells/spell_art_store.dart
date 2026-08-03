// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_store.dart — on-disk blob store for custom spell art, keyed by
// spellHashHex.
//
// Deliberately kept OUT of SpellAsset's JSON (spell_asset.dart): inscribeSpell
// calls SpellAsset.loadAll() on every inscription to check for a duplicate
// spellHashHex, which parses every persisted spell's full JSON. Inlining
// full-size art bytes there would make that dedup scan read tens of MB per
// inscription on a mature library. SpellAsset keeps only lightweight art
// metadata (artHash/artSource/artUpdatedAt); the bytes live here, loaded only
// when a card is actually rendered.
//
// P1 scope: own spells only. Keyed by spellHashHex alone -- owner is
// implicitly self. P2 will introduce a separate (spellHashHex,
// ownerPubkeyHex)-keyed sighting store for opponent art; this store is not
// reused for that (see the Phase 0 report / CLAUDE.md custom-art thread).

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class SpellArtStore {
  static Future<Directory> _artDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/spell_art');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // spellHashHex is a "0x"-prefixed hex Field string; strip the prefix so it
  // reads as a plain filename.
  static String _keyFor(String spellHashHex) =>
      spellHashHex.startsWith('0x') ? spellHashHex.substring(2) : spellHashHex;

  /// Persists [full] and [thumb] JPEG bytes for [spellHashHex], overwriting
  /// any existing art for that spell.
  static Future<void> save(
    String spellHashHex, {
    required Uint8List full,
    required Uint8List thumb,
  }) async {
    final dir = await _artDir();
    final key = _keyFor(spellHashHex);
    await File('${dir.path}/$key.full.jpg').writeAsBytes(full);
    await File('${dir.path}/$key.thumb.jpg').writeAsBytes(thumb);
  }

  /// Loads the full-size art bytes for [spellHashHex], or null if none is stored.
  static Future<Uint8List?> loadFull(String spellHashHex) => _load(spellHashHex, 'full');

  /// Loads the thumbnail art bytes for [spellHashHex], or null if none is stored.
  static Future<Uint8List?> loadThumb(String spellHashHex) => _load(spellHashHex, 'thumb');

  static Future<Uint8List?> _load(String spellHashHex, String variant) async {
    final dir = await _artDir();
    final file = File('${dir.path}/${_keyFor(spellHashHex)}.$variant.jpg');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Deletes any stored art for [spellHashHex]. Silently no-ops if absent.
  static Future<void> delete(String spellHashHex) async {
    final dir = await _artDir();
    final key = _keyFor(spellHashHex);
    for (final variant in ['full', 'thumb']) {
      final file = File('${dir.path}/$key.$variant.jpg');
      if (await file.exists()) await file.delete();
    }
  }
}
