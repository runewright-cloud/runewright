// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_enrollment.dart — VocalEnrollment: persistence and audio
// processing for per-user voice templates (Practice Mode).
//
// Why this exists (2026-07-16): the MFCC+DTW metric's absolute costs are
// uncalibratable across speakers, but its *ranking* across the closed
// 5-word vocabulary is reliable when the reference templates are the same
// voice as the query — measured 5/5 correct argmin with >= 1.0 margins
// same-voice vs 2/5 cross-voice (see docs/M4_findings.md, 2026-07-16
// entry). So the player records each word once, and those recordings
// replace the Piper renders as the scoring references. The Piper renders
// remain the *pronunciation model* the player hears and imitates.
//
// Storage: <app documents>/practice_enrollment/<word>.json, same schema as
// the bundled assets/practice_templates/*.json ({"frames": [[13 doubles]]})
// so PerUserEnrolledTemplateSource can treat both identically. Local-only,
// never leaves the device, consensus-invisible.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'mfcc.dart';
import 'vocal_slot.dart';

/// Thrown when an enrollment recording can't yield a usable template
/// (too quiet, too short). The message is user-presentable.
class EnrollmentException implements Exception {
  const EnrollmentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Persistence + processing for per-user vocal templates. [baseDir] is
/// injectable for tests; production callers use [VocalEnrollment.open],
/// which anchors it under the app documents directory (same pattern as
/// lib/spells/*).
class VocalEnrollment {
  VocalEnrollment(this.baseDir);

  final Directory baseDir;

  static Future<VocalEnrollment> open() async {
    final docs = await getApplicationDocumentsDirectory();
    return VocalEnrollment(Directory('${docs.path}/practice_enrollment'));
  }

  /// A recording must keep at least this many voiced MFCC frames (~10ms
  /// each) after trimming to count as a real utterance.
  static const int minVoicedFrames = 20;

  /// Upper guard on a single take's voiced length (~2 s). A take longer than
  /// this is almost never one briskly-spoken word — it's a held button that
  /// caught breath/hesitation/a second rep (the 230-frame `finitus` that
  /// poisoned scoring on 2026-07-22). Rejected with actionable feedback
  /// rather than silently stored as a bad reference. See docs/M4_findings.md.
  static const int maxVoicedFrames = 200;

  /// Frames kept as padding on each side of the detected voiced span.
  static const int trimPaddingFrames = 3;

  /// Attunements per word suggested to a player, in-world terminology for
  /// stored takes. Advisory — nothing refuses a cast below it, and the
  /// practice gate stays at the lower [minTakesForPractice].
  ///
  /// INFERRED, not measured, and the distinction matters. The somatic side has
  /// a real multi-rep corpus and a sweep behind its number
  /// (GestureEnrollment.suggestedReps, 4). Vocal has no equivalent: the
  /// fixtures under test/practice/fixtures/voices are one utterance per word
  /// per synthetic voice, so there is nothing to sweep take count against. 4
  /// carries over because the two sides are the *same* recognizer —
  /// min-distance DTW against a set of per-user exemplars, accepted on a cap
  /// and a runner-up margin — so the shape of the curve should be the shape of
  /// the curve. Re-derive this against a real multi-take voice corpus when one
  /// exists; until then treat it as a well-reasoned default, not a result.
  ///
  /// Record roughly the SAME number for every word. Min-distance argmin across
  /// the vocabulary is biased toward whichever word has more exemplars — 8
  /// takes of one word against 2 of another makes the first systematically
  /// closer, which costs mana on a word the player said correctly.
  static const int suggestedTakes = 4;

  /// Rolling window of exemplar takes kept per word. NOT a ceiling on how much
  /// a player may attune: appending past it drops the oldest take (FIFO), so
  /// "record another" is always allowed and always refreshes the set toward
  /// how they say the word now.
  ///
  /// Raised 5 → 8 (2026-08-06) so the window sits meaningfully above
  /// [suggestedTakes] rather than one take above it — a player who keeps
  /// practising should be able to accumulate, not immediately start evicting.
  /// The bound is runtime, not quality: scoring is min-distance over this set,
  /// so a recited formula costs `words * 6 slots * takes` DTW pairs — 192 at
  /// the cap for a four-word incantation, against the somatic path's already-
  /// accepted 100 per cast.
  static const int maxTakes = 8;

  /// Takes per word a player needs before a practice drill means anything.
  ///
  /// Below this the scorer falls back to (or leans on) the bundled Piper
  /// voice, which can tell "an attempt happened" from "silence" but is weak at
  /// telling the player's OWN words apart — so a drill run against it would
  /// report mistakes the player did not make and hide ones they did. Two takes
  /// is the point where min-distance scoring has some of the speaker's natural
  /// variation to match against, and it is cheap to reach (two holds per word
  /// on the Attune Spell Components page).
  ///
  /// The library's Practice entry point gates on [isPracticeReady] and diverts
  /// to Attune Spell Components until this is met — see library_screen.dart's
  /// `_openPracticeForSpell`.
  static const int minTakesForPractice = 2;

  /// Whether every slot has at least [minTakesForPractice] takes.
  bool isPracticeReady() =>
      VocalSlot.values.every((w) => takeCount(w) >= minTakesForPractice);

  /// Where [word]'s takes are WRITTEN — always the current slot key.
  File _fileFor(VocalSlot word) =>
      File('${baseDir.path}/${word.storageKey}.json');

  /// Where [word]'s takes are READ from: the current file if it exists,
  /// otherwise the pre-§8 Latin filename.
  ///
  /// Enrollment used to be keyed by the fixed Latin word (`terra.json`);
  /// slots renamed those to `earth.json` (VOCAL_RECALL_PLAN.md §8). Reading
  /// through the legacy name means a player who enrolled before the rename
  /// keeps their recordings instead of silently falling back to the Piper
  /// voice — a fallback that would cost them mana under recall scoring
  /// without ever telling them why.
  ///
  /// Read path only: the next [_writeTakes] moves them to the current name.
  /// `finitus` is not migrated — that slot no longer exists.
  File _readFileFor(VocalSlot word) {
    final current = _fileFor(word);
    if (current.existsSync()) return current;
    for (final entry in VocalSlot.legacyStorageKeys.entries) {
      if (entry.value != word) continue;
      final legacy = File('${baseDir.path}/${entry.key}.json');
      if (legacy.existsSync()) return legacy;
    }
    return current;
  }

  bool hasEnrollment(VocalSlot word) => _readFileFor(word).existsSync();

  Set<VocalSlot> enrolledWords() =>
      VocalSlot.values.where(hasEnrollment).toSet();

  int takeCount(VocalSlot word) => _readTakes(word).length;

  /// All enrolled exemplar takes for [word] (each a sequence of MFCC frames),
  /// or an empty list if none. Reads the multi-take format and transparently
  /// migrates the legacy single-`frames` format as a one-element set.
  Future<List<List<List<double>>>?> loadTakes(VocalSlot word) async {
    final takes = _readTakes(word);
    return takes.isEmpty ? null : takes;
  }

  /// Back-compat: the FIRST enrolled take's frames (or null). Retained for
  /// callers/tests that predate multi-take; new code uses [loadTakes].
  Future<List<List<double>>?> loadFrames(VocalSlot word) async {
    final takes = _readTakes(word);
    return takes.isEmpty ? null : takes.first;
  }

  List<List<List<double>>> _readTakes(VocalSlot word) {
    final file = _readFileFor(word);
    if (!file.existsSync()) return const [];
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    List<List<double>> frames(List raw) => raw
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    if (json['takes'] is List) {
      return [for (final t in json['takes'] as List) frames(t as List)];
    }
    // Legacy single-take format {"frames": [...]}.
    if (json['frames'] is List) return [frames(json['frames'] as List)];
    return const [];
  }

  Future<void> _writeTakes(
      VocalSlot word, List<List<List<double>>> takes,
      {String? label}) async {
    await baseDir.create(recursive: true);
    await _fileFor(word).writeAsString(jsonEncode({
      'label': ?label,
      'takes': takes,
    }));
  }

  /// The WORD these takes were recorded for, or null for a file written
  /// before labels existed (or by the pre-§8 enrollment screen).
  ///
  /// This is what makes re-keying safe without cross-file atomicity (§8.8). A
  /// vocabulary swap touches several files plus the profile, so a crash
  /// part-way could leave a slot whose stored audio is for one word while the
  /// profile now names another. Recording the word IN the file makes that
  /// state DETECTABLE: [PerUserEnrolledTemplateSource] compares the two and
  /// falls back to the bundled default rather than silently scoring a player
  /// against audio of a word they no longer say — which would cost them mana
  /// for no reason they could see.
  String? labelFor(VocalSlot word) {
    final file = _readFileFor(word);
    if (!file.existsSync()) return null;
    try {
      final json =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final label = json['label'];
      return label is String && label.isNotEmpty ? label : null;
    } catch (_) {
      return null;
    }
  }

  /// Copies [slots] from [staging] into this enrollment.
  ///
  /// The commit half of an atomic re-key: takes are recorded into a staging
  /// enrollment first and only adopted once EVERY changed slot has them, so a
  /// player never duels with half an old vocabulary and half a new one.
  Future<void> adoptFrom(
    VocalEnrollment staging,
    Map<VocalSlot, String> labels,
  ) async {
    for (final entry in labels.entries) {
      final takes = staging._readTakes(entry.key);
      if (takes.isEmpty) continue;
      await _writeTakes(entry.key, takes, label: entry.value);
    }
  }

  /// Trims leading/trailing silence from [pcm] (PCM-16 LE mono, 16 kHz),
  /// extracts MFCC frames, validates the result, and APPENDS it as a new
  /// exemplar take for [word] (FIFO past [maxTakes]). Returns the saved
  /// take's frame count and the new total take count.
  ///
  /// Throws [EnrollmentException] when the recording is too quiet/short or
  /// too long to be a usable single-word reference.
  Future<({int frameCount, int takeCount})> saveFromRecording(
      VocalSlot word, Uint8List pcm, {String? label}) async {
    final trimmed = trimSilence(pcm);
    final frames = MfccExtractor.extract(trimmed);
    if (frames.length < minVoicedFrames) {
      throw const EnrollmentException(
          'Recording was too quiet or too short — say the word clearly, '
          'a little louder, and try again.');
    }
    if (frames.length > maxVoicedFrames) {
      throw const EnrollmentException(
          'That was too long for one word — hold, say the word once briskly, '
          'then release. Try again.');
    }
    final takes = _readTakes(word).toList()..add(frames);
    while (takes.length > maxTakes) {
      takes.removeAt(0); // FIFO: drop the oldest take
    }
    await _writeTakes(word, takes, label: label ?? labelFor(word));
    return (frameCount: frames.length, takeCount: takes.length);
  }

  /// Removes the take at [index] for [word]; deletes the word's file when no
  /// takes remain. No-op if the index is out of range.
  Future<void> removeTake(VocalSlot word, int index) async {
    final takes = _readTakes(word).toList();
    if (index < 0 || index >= takes.length) return;
    takes.removeAt(index);
    if (takes.isEmpty) {
      await _deleteFilesFor(word);
    } else {
      await _writeTakes(word, takes);
    }
  }

  /// Removes ALL takes for [word] (deletes its file). No-op if unenrolled.
  Future<void> clearWord(VocalSlot word) => _deleteFilesFor(word);

  /// Deletes every file [word]'s takes could live in — the current slot key
  /// AND any pre-§8 Latin name. Deleting only the current name would leave a
  /// legacy file that [_readFileFor] then resurrects, so a "cleared" word
  /// would come back with stale takes on the next read.
  Future<void> _deleteFilesFor(VocalSlot word) async {
    final files = <File>[
      _fileFor(word),
      for (final entry in VocalSlot.legacyStorageKeys.entries)
        if (entry.value == word) File('${baseDir.path}/${entry.key}.json'),
    ];
    for (final file in files) {
      if (file.existsSync()) await file.delete();
    }
  }

  Future<void> clearAll() async {
    if (baseDir.existsSync()) await baseDir.delete(recursive: true);
  }

  /// Cuts [pcm] down to its voiced span: per-10ms-hop RMS, voiced =
  /// above max(absolute epsilon, 10% of peak RMS), first-to-last voiced
  /// hop plus [trimPaddingFrames] padding. Returns an empty buffer when
  /// nothing voiced was found.
  static Uint8List trimSilence(Uint8List pcm) {
    const hop = 160; // 10ms at 16 kHz, matches MfccExtractor's stride
    final bd = ByteData.sublistView(pcm);
    final totalSamples = pcm.length ~/ 2;
    final hopCount = totalSamples ~/ hop;
    if (hopCount == 0) return Uint8List(0);

    final rms = List<double>.generate(hopCount, (i) {
      var sum = 0.0;
      for (int s = i * hop; s < (i + 1) * hop; s++) {
        final v = bd.getInt16(s * 2, Endian.little) / 32768.0;
        sum += v * v;
      }
      return math.sqrt(sum / hop);
    });

    final peak = rms.reduce(math.max);
    final threshold = math.max(0.004, peak * 0.1);
    int first = -1, last = -1;
    for (int i = 0; i < hopCount; i++) {
      if (rms[i] >= threshold) {
        if (first < 0) first = i;
        last = i;
      }
    }
    if (first < 0) return Uint8List(0);

    final startHop = math.max(0, first - trimPaddingFrames);
    final endHop = math.min(hopCount, last + 1 + trimPaddingFrames);
    return Uint8List.sublistView(pcm, startHop * hop * 2, endHop * hop * 2);
  }
}
