// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_settings.dart — persisted global volume + mute for spell
// sound playback (docs/SPELL_SOUND_PACK_PLAN.md E-4). A plain JSON file in
// the app documents directory, same pattern as recipe_book.dart -- this is
// a cosmetic preference, not identity material, so it doesn't belong in
// Identity's secure storage.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Default global volume (E-4: "global volume defaults to 0.6").
const double kDefaultSpellSoundVolume = 0.6;

class SpellSoundSettings {
  const SpellSoundSettings({this.volume = kDefaultSpellSoundVolume, this.muted = false});

  /// 0.0-1.0. Applied to built-in pack clips directly; imported/synced clips
  /// are further scaled by [kUnnormalizedSoundGain] (spell_sound_player.dart)
  /// since they cannot be loudness-normalized (D-4).
  final double volume;

  final bool muted;

  /// Effective volume after mute -- 0.0 when [muted], [volume] otherwise.
  /// Callers should always read through this rather than gating playback on
  /// [muted] separately.
  double get effectiveVolume => muted ? 0.0 : volume;

  SpellSoundSettings withVolume(double volume) =>
      SpellSoundSettings(volume: volume.clamp(0.0, 1.0), muted: muted);

  SpellSoundSettings withMuted(bool muted) => SpellSoundSettings(volume: volume, muted: muted);

  Map<String, dynamic> toJson() => {'volume': volume, 'muted': muted};

  static SpellSoundSettings fromJson(Map<String, dynamic> json) => SpellSoundSettings(
        volume: (json['volume'] as num?)?.toDouble() ?? kDefaultSpellSoundVolume,
        muted: json['muted'] as bool? ?? false,
      );

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/spell_sound_settings.json');
  }

  /// Loads the persisted settings, or the defaults if none have been saved yet.
  static Future<SpellSoundSettings> load() async {
    final file = await _file();
    if (!await file.exists()) return const SpellSoundSettings();
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return fromJson(json);
    } catch (_) {
      // A corrupt settings file is a cosmetic preference, not load-bearing
      // state -- fall back to defaults rather than surfacing an error.
      return const SpellSoundSettings();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(jsonEncode(toJson()));
  }
}
