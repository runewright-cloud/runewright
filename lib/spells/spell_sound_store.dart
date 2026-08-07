// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_store.dart — on-disk blob store for custom spell sound, keyed
// by spellHashHex (or, for SightingAsset, the sighting's own [id]).
//
// Deliberately kept OUT of SpellAsset's JSON, same reasoning as
// spell_art_store.dart's header comment: inscribeSpell calls
// SpellAsset.loadAll() on every inscription, which parses every persisted
// spell's full JSON. One variant per key here (unlike SpellArtStore's
// full/thumb pair) -- there is no thumbnail concept for audio.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class SpellSoundStore {
  static Future<Directory> _soundDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/spell_sound');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Key is a "0x"-prefixed hex Field string; strip the prefix so it reads as
  // a plain filename. Mirrors SpellArtStore._keyFor.
  static String _keyFor(String key) => key.startsWith('0x') ? key.substring(2) : key;

  /// Persists [bytes] (raw Ogg Vorbis) for [key], overwriting any existing
  /// sound for that key.
  static Future<void> save(String key, Uint8List bytes) async {
    final dir = await _soundDir();
    await File('${dir.path}/${_keyFor(key)}.ogg').writeAsBytes(bytes);
  }

  /// Loads the stored sound bytes for [key], or null if none is stored.
  static Future<Uint8List?> load(String key) async {
    final dir = await _soundDir();
    final file = File('${dir.path}/${_keyFor(key)}.ogg');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Deletes any stored sound for [key]. Silently no-ops if absent.
  static Future<void> delete(String key) async {
    final dir = await _soundDir();
    final file = File('${dir.path}/${_keyFor(key)}.ogg');
    if (await file.exists()) await file.delete();
  }
}
