// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_resolver.dart — the single seam between "what sound does this
// spell play" and "here are the bytes." Mirrors spell_art_resolver.dart:
// SpellAsset/SightingAsset store only a pointer (spellHashHex/id into
// SpellSoundStore for an imported/synced clip, or soundPackId into
// kSpellSoundPack for a built-in clip), and every caller goes through here
// rather than branching on soundSource itself.
//
// Where this breaks from the art resolver: art's "no art set" case falls
// back to a commitment-derived coat of arms rendered on the fly. Sound has
// no equivalent renderer, so "no sound set" (docs/SPELL_SOUND_PACK_PLAN.md
// D-6) instead picks a built-in pack clip -- deterministically, from the
// spell's own identity and dominant formula element, so the same spell
// always sounds the same and different spells (usually) don't.

import 'dart:typed_data';

import 'sighting_asset.dart';
import 'spell_asset.dart';
import 'spell_sound_pack.dart' show SpellSoundPackEntry, kSpellSoundPack, loadPackSound;
import 'spell_sound_store.dart';

const List<String> _kElements = ['fire', 'air', 'water', 'earth', 'neutral'];

/// The element (fire/air/water/earth) occurring most often in [formula], or
/// 'neutral' if [formula] is empty or names no recognised element. Local
/// copy of spell_art_pack_screen.dart's suggestedElementFor, defaulting to
/// 'neutral' rather than null -- D-6 always needs a concrete element to pick
/// a pack clip with, whereas the art picker's null means "open on All".
String elementForSoundDefault(List<String> formula) {
  final counts = <String, int>{};
  for (final raw in formula) {
    final e = raw.toLowerCase();
    if (_kElements.contains(e) && e != 'neutral') counts[e] = (counts[e] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'neutral';
  final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return sorted.first.key;
}

/// A small FNV-1a-style hash over [s], used only to deterministically pick
/// among equally-valid default pack clips. Not cryptographic, not the
/// circuit's Poseidon2 -- just needs to be stable across runs, which Dart's
/// built-in String.hashCode is not guaranteed to be (CLAUDE.md invariant 1:
/// never reimplement the circuit's own hash; this reimplements nothing
/// circuit-related, it's a pure UI-variety picker).
int _stableHash(String s) {
  var hash = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The built-in pack clip [formula]/[identity] deterministically defaults to
/// when no explicit sound has been chosen (D-6), or null if the pack has no
/// 'spell'-category clip for the resolved element at all (should not happen
/// with the shipped pack, which covers every element).
SpellSoundPackEntry? defaultPackSoundFor({required List<String> formula, required String identity}) {
  final element = elementForSoundDefault(formula);
  var candidates = kSpellSoundPack.where((e) => e.category == 'spell' && e.element == element).toList();
  if (candidates.isEmpty) {
    // Every source formula produces SOME element via elementForSoundDefault,
    // but a future pack revision could in principle drop coverage for one --
    // fall back to the full spell-category list rather than returning null,
    // so a spell is never silently mute.
    candidates = kSpellSoundPack.where((e) => e.category == 'spell').toList();
  }
  if (candidates.isEmpty) return null;
  final index = _stableHash(identity) % candidates.length;
  return candidates[index];
}

/// Resolves the sound bytes for [spell], or null if it has none and no
/// default could be picked (only possible if the pack ships with zero
/// 'spell'-category clips).
Future<Uint8List?> resolveSpellSound(SpellAsset spell) async {
  if (spell.soundHash != null) {
    if (spell.soundSource == SpellSoundSource.builtIn) {
      final packId = spell.soundPackId;
      if (packId == null) return null;
      return loadPackSound(packId);
    }
    if (spell.spellHashHex.isEmpty) return null;
    return SpellSoundStore.load(spell.spellHashHex);
  }
  final entry = defaultPackSoundFor(formula: spell.formula, identity: spell.commitmentHex);
  if (entry == null) return null;
  return loadPackSound(entry.id);
}

/// Resolves the sound bytes for a sighted opponent spell. Mirrors
/// [resolveSpellSound]; [SightingAsset.id] is the store key for synced
/// bytes, same convention as its art (sync_art_session.dart).
Future<Uint8List?> resolveSightingSound(SightingAsset sighting) async {
  if (sighting.soundHash != null) {
    if (sighting.soundSource == SpellSoundSource.builtIn) {
      final packId = sighting.soundPackId;
      if (packId == null) return null;
      return loadPackSound(packId);
    }
    return SpellSoundStore.load(sighting.id);
  }
  final entry = defaultPackSoundFor(formula: sighting.formula, identity: sighting.commitmentHex);
  if (entry == null) return null;
  return loadPackSound(entry.id);
}
