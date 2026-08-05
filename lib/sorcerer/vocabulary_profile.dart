// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_profile.dart — the words a player chose for their six slots.
//
// VOCAL_RECALL_PLAN.md §8. This is the ONLY place incantation words exist.
// Everything else in the stack — the recogniser, the scorer, the wire, the
// engine — deals in VocalSlot indices and never sees a word.
//
// Two invariants this type exists to protect (§8.10):
//   1. A vocabulary never leaves its device. There is no toWireBytes here and
//      there must never be one. Serialisation is to LOCAL storage only.
//   2. The peer never renders the caster's labels. Battle UI showing an
//      opponent's incantation would hand over the cipher for free — the whole
//      point is that an opponent must EARN the decode by ear, over casts.
//
// The defaults are Latin, and they are a genuine default rather than a
// suggestion: they ship with Piper-rendered templates, so a player can duel
// without enrolling at all (§8.9 — "default words = play now, custom words =
// enroll first"). Choosing custom words requires enrollment because no
// template exists for a word nobody has ever recorded.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'vocal_slot.dart';

/// The player's chosen word for each slot, plus local persistence.
///
/// Immutable; [withLabel] and [withLabels] return new instances. Re-keying is
/// atomic by construction (§8.8) — a caller assembles the complete new
/// vocabulary and saves it in one write, so a cast can never see a half-swapped
/// mix of old and new words and charge mana penalties nobody earned.
class VocabularyProfile {
  const VocabularyProfile(this._labels);

  final Map<VocalSlot, String> _labels;

  /// The Latin defaults, shipped with bundled Piper templates.
  ///
  /// Sourced from [VocalSlot.defaultWord] so there is
  /// exactly one definition of them (the asset-generation script reads the
  /// slot directly — it cannot import this file, which pulls in Flutter).
  static Map<VocalSlot, String> get defaultLabels =>
      {for (final slot in VocalSlot.values) slot: slot.defaultWord};

  static const VocabularyProfile defaults = VocabularyProfile({});

  /// The word this player speaks for [slot].
  String labelFor(VocalSlot slot) => _labels[slot] ?? slot.defaultWord;

  /// True when every slot still holds its shipped default — i.e. the bundled
  /// Piper templates are a valid fallback and enrollment is optional (§8.9).
  bool get isAllDefault =>
      VocalSlot.values.every((slot) => labelFor(slot) == slot.defaultWord);

  /// True when [slot] still holds its shipped default word. A customised slot
  /// has no bundled template and must be enrolled before it can be recognised.
  bool isDefaultFor(VocalSlot slot) => labelFor(slot) == slot.defaultWord;

  /// Slots the player customised, and so must have enrolled takes for.
  List<VocalSlot> get customisedSlots =>
      VocalSlot.values.where((s) => !isDefaultFor(s)).toList();

  VocabularyProfile withLabel(VocalSlot slot, String label) =>
      VocabularyProfile({..._labels, slot: label});

  VocabularyProfile withLabels(Map<VocalSlot, String> labels) =>
      VocabularyProfile({..._labels, ...labels});

  Map<String, dynamic> toJson() => {
        for (final entry in _labels.entries) entry.key.storageKey: entry.value,
      };

  static VocabularyProfile fromJson(Map<String, dynamic> json) {
    final labels = <VocalSlot, String>{};
    for (final entry in json.entries) {
      final slot = VocalSlot.fromStorageKey(entry.key);
      final value = entry.value;
      // Unknown keys (notably the retired `finitus`) are dropped, not an error
      // — a profile written before §8 is still readable.
      if (slot != null && value is String && value.trim().isNotEmpty) {
        labels[slot] = value.trim();
      }
    }
    return VocabularyProfile(labels);
  }

  // ── Local persistence ─────────────────────────────────────────────────────

  static const String _fileName = 'vocabulary_profile.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Loads the stored profile, falling back to [defaults] when absent or
  /// unreadable. Never throws — a corrupt profile costs the player their
  /// custom words, not their ability to open the app.
  static Future<VocabularyProfile> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return defaults;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return defaults;
      return fromJson(decoded);
    } catch (_) {
      return defaults;
    }
  }

  /// Writes this profile to local storage. One write per re-keying commit —
  /// see the atomicity note on the class.
  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(jsonEncode(toJson()));
  }

  // ── Word validation ───────────────────────────────────────────────────────

  /// Minimum characters for a custom word.
  ///
  /// §8.7 requires a minimum duration / syllable count because one-phoneme
  /// words discriminate badly under DTW. Character count is a cheap proxy
  /// applied at entry; the real check is the recorded-duration guard in
  /// enrollment, which measures what the player actually said.
  static const int minLabelLength = 3;

  /// Why [label] is unusable for a custom slot, or null when it is fine.
  static String? rejectReason(String label) {
    final trimmed = label.trim();
    if (trimmed.length < minLabelLength) {
      return 'Use at least $minLabelLength characters — very short words are '
          'hard to tell apart.';
    }
    return null;
  }

  @override
  String toString() => 'VocabularyProfile(${toJson()})';
}
