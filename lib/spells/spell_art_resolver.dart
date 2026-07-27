// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_resolver.dart — the single seam between "a spell has custom art"
// and "here are the bytes." docs/SPELL_ART_PACK_PLAN.md's design principle is
// reference locally, materialise at the edges: SpellAsset stores only a
// pointer (spellHashHex into SpellArtStore for an imported image, or
// artPackId into kPainterlyPack for a built-in icon), and every renderer or
// network path that needs real bytes goes through here rather than branching
// on artSource itself. Adding a third source later (P2 opponent-advertised
// art, if it ever needs its own storage) is a change to this file alone.

import 'dart:typed_data';

import 'spell_art_pack.dart' show loadPackArt;
import 'spell_art_store.dart';
import 'spell_asset.dart';

/// Resolves the full-size art bytes for [spell], or null if it has none
/// (callers should fall back to the commitmentHex-derived coat of arms).
Future<Uint8List?> resolveSpellArtFull(SpellAsset spell) => _resolve(spell, full: true);

/// Resolves the thumbnail art bytes for [spell], or null if it has none.
Future<Uint8List?> resolveSpellArtThumb(SpellAsset spell) => _resolve(spell, full: false);

Future<Uint8List?> _resolve(SpellAsset spell, {required bool full}) {
  if (spell.artHash == null) return Future.value(null);
  if (spell.artSource == SpellArtSource.builtIn) {
    final packId = spell.artPackId;
    if (packId == null) return Future.value(null);
    // Pack art is one 256px file for both roles -- see plan §4 B-1.
    return loadPackArt(packId);
  }
  if (spell.spellHashHex.isEmpty) return Future.value(null);
  return full
      ? SpellArtStore.loadFull(spell.spellHashHex)
      : SpellArtStore.loadThumb(spell.spellHashHex);
}
