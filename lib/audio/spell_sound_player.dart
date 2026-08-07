// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_player.dart — plays a spell's resolution sound (bytes already
// resolved by spell_sound_resolver.dart) through a small pool of
// audioplayers instances (docs/SPELL_SOUND_PACK_PLAN.md E-1/E-4).
//
// Instances are created lazily, exactly like practice_screen.dart's
// _player getter: constructing an AudioPlayer spins up a native audio
// session, which is a hard failure under `flutter test` (no audioplayers
// plugin) for any test that never plays a clip. A pool (not one shared
// player) so two clips that overlap slightly (e.g. a spell's own sound and
// a fizzle played back-to-back at the tail of one reveal, or two spells
// resolving close together) don't cut each other off.

import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'spell_sound_settings.dart';

/// Fixed fraction of the global volume applied to imported/synced clips,
/// which cannot be loudness-normalized (D-4) -- a conservative gain rather
/// than true normalization, since measuring loudness would require a
/// decoder this app doesn't have.
const double kUnnormalizedSoundGain = 0.7;

class SpellSoundPlayer {
  SpellSoundPlayer({int poolSize = 3}) : _poolSize = poolSize;

  final int _poolSize;
  final List<AudioPlayer> _pool = [];
  int _nextIndex = 0;

  AudioPlayer _next() {
    if (_pool.length < _poolSize) {
      final player = AudioPlayer(playerId: 'spell_sound_${_pool.length}');
      _pool.add(player);
      return player;
    }
    final player = _pool[_nextIndex];
    _nextIndex = (_nextIndex + 1) % _poolSize;
    return player;
  }

  /// Plays [bytes] at a volume derived from [settings] and whether the clip
  /// is [normalized] (a built-in pack clip, loudness-matched at build time)
  /// or not (an imported/synced clip -- see [kUnnormalizedSoundGain]).
  /// No-ops silently on [settings.muted] or a zero-length clip -- a playback
  /// failure here must never interrupt the battle reveal it's decorating.
  Future<void> play(Uint8List bytes, {required SpellSoundSettings settings, required bool normalized}) async {
    if (bytes.isEmpty) return;
    final volume = settings.effectiveVolume * (normalized ? 1.0 : kUnnormalizedSoundGain);
    if (volume <= 0.0) return;
    try {
      await _next().play(BytesSource(bytes, mimeType: 'audio/ogg'), volume: volume);
    } catch (_) {
      // Playback is cosmetic -- a codec hiccup on one clip must not surface
      // as a battle-flow error. See E-5's note that this is only exercised
      // for real on-device; under flutter test this branch typically fires
      // via mocked plugin failures instead.
    }
  }

  /// Stops every pooled player -- called at the end of a reveal sequence and
  /// on dispose (E-3), since a long clip would otherwise outlive its 2s card
  /// and bleed into the next phase (Finding 3).
  Future<void> stopAll() async {
    for (final player in _pool) {
      try {
        await player.stop();
      } catch (_) {
        // Best-effort -- see [play]'s catch.
      }
    }
  }

  Future<void> dispose() async {
    for (final player in _pool) {
      await player.dispose();
    }
    _pool.clear();
  }
}
