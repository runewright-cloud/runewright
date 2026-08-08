// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_asset.dart — a persisted bundle of spell references and artifact
// loadout the player intends to carry into battle. The enhancement (Potency/
// Velocity/Efficiency/Mystery) a spell is cast with is chosen at cast time in
// battle, not stored here — see battle_screen.dart's cast-time picker. Each
// artifact slot holds one of four kinds of battle items.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rune_duel/engine/border_zone.dart';

import 'counter_charm.dart';

// ── Artifact loadout ──────────────────────────────────────────────────────────

// NOTE: the Air-typed slot is the Rod of Wind (design v3.0 §Artifacts): a
// one-shot consumable that adds +1 effective radius to the next spell's effects
// (and one size rung to a summoned minion). It replaced the v2.4 "absorption /
// deflection rod" whose status-nullify role now survives only through the
// *summoned* deflectionTotem (Water-Earth/Earth). `deflectionRod` is kept below
// only as a read-time JSON alias for any chapter persisted under the old name.
enum ArtifactKind { manaGem, bookmark, rodOfSpreading, counterCharm }

class ArtifactEntry {
  const ArtifactEntry({required this.kind, this.trajectory});

  final ArtifactKind kind;

  /// [counterCharm] only: the elemental trajectory this charm is attuned to
  /// (docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 2). Any spell whose certified
  /// element sequence opens with this trajectory is countered, formula by
  /// formula, for as long as the two sequences stay in lockstep.
  ///
  /// Null means the charm is unattuned — added to the chapter but not yet
  /// given a trajectory (see [ChapterAsset.attuneFirstUnattunedCounterCharm]).
  /// When set it is always a whole number of formulas, per
  /// [isValidCharmTrajectory]; the display string is derived on demand via
  /// [charmTrajectoryLabel] rather than stored.
  ///
  /// This replaced a `targetCommitmentHex` that bound the charm to one
  /// specific spell's grid. A charm persisted under that scheme loads as
  /// unattuned: the grid commitment says nothing about behaviour, so there is
  /// nothing to migrate it to, and the player re-types a trajectory.
  final List<BorderZone>? trajectory;

  bool get isCounterCharm => kind == ArtifactKind.counterCharm;

  bool get isUnattunedCounterCharm => isCounterCharm && trajectory == null;

  ArtifactEntry copyWith({List<BorderZone>? trajectory}) =>
      ArtifactEntry(kind: kind, trajectory: trajectory ?? this.trajectory);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (trajectory != null)
          'trajectory': charmTrajectoryToNames(trajectory!),
      };

  static ArtifactEntry fromJson(Map<String, dynamic> json) {
    final raw = json['trajectory'] as List<dynamic>?;
    final trajectory =
        raw == null ? null : charmTrajectoryFromNames(raw.cast<String>());
    return ArtifactEntry(
      kind: _kindFromName(json['kind'] as String),
      // A trajectory that survived the name decode but isn't a whole number
      // of formulas can't be matched or priced, so it loads as unattuned
      // rather than as a charm that silently never fires.
      trajectory: trajectory != null && isValidCharmTrajectory(trajectory)
          ? trajectory
          : null,
    );
  }

  /// Reads an [ArtifactKind] name, aliasing the pre-v3.0 `deflectionRod` slot
  /// name onto its replacement [ArtifactKind.rodOfSpreading] so chapters
  /// persisted before the rename still load.
  static ArtifactKind _kindFromName(String name) => switch (name) {
        'deflectionRod' => ArtifactKind.rodOfSpreading,
        _ => ArtifactKind.values.byName(name),
      };
}

// ── Spell loadout ─────────────────────────────────────────────────────────────

class ChapterEntry {
  const ChapterEntry({required this.spellId, this.summonPersonality});

  /// ID of the included spell (matches SpellAsset.id).
  final String spellId;

  /// design doc "Personalities": the battlefield-behavior glyph (a
  /// SummonPersonality enum name) this copy of the spell will fight with,
  /// chosen when it was added to this chapter -- not at inscription, since
  /// the same base spell may be added to several chapters (or, for Basic
  /// spells, added more than once to the same chapter) with a different
  /// personality each time. Null means "use the spell's own
  /// SpellAsset.summonPersonality default" (non-summon entries, or entries
  /// added before this field existed). Ignored entirely when the underlying
  /// spell isn't a summon.
  final String? summonPersonality;

  Map<String, dynamic> toJson() => {
        'spellId': spellId,
        if (summonPersonality != null) 'summonPersonality': summonPersonality,
      };

  static ChapterEntry fromJson(Map<String, dynamic> json) => ChapterEntry(
        spellId: json['spellId'] as String,
        summonPersonality: json['summonPersonality'] as String?,
      );
}

// ── Chapter ───────────────────────────────────────────────────────────────────

class ChapterAsset {
  static const int maxArtifactSlots = 12;

  ChapterAsset({
    required this.id,
    required this.name,
    required this.createdAt,
    this.entries = const [],
    this.artifacts = const [],
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final List<ChapterEntry> entries;
  final List<ArtifactEntry> artifacts;

  int get artifactSlotsRemaining => maxArtifactSlots - artifacts.length;

  int get unattunedCounterCharmCount =>
      artifacts.where((a) => a.isUnattunedCounterCharm).length;

  /// Attunes the first unattuned counter charm in [artifacts] to
  /// [trajectory]. Returns the updated chapter, or `null` if there is no
  /// unattuned charm to attune (caller shows "No unattuned charms
  /// available.") or [trajectory] isn't a whole number of formulas.
  ChapterAsset? attuneFirstUnattunedCounterCharm({
    required List<BorderZone> trajectory,
  }) {
    if (!isValidCharmTrajectory(trajectory)) return null;
    final idx = artifacts.indexWhere((a) => a.isUnattunedCounterCharm);
    if (idx < 0) return null;
    final updated = List<ArtifactEntry>.from(artifacts);
    updated[idx] = updated[idx].copyWith(trajectory: trajectory);
    return ChapterAsset(
      id: id,
      name: name,
      createdAt: createdAt,
      entries: entries,
      artifacts: updated,
    );
  }

  ChapterAsset withEntry(ChapterEntry entry) => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: [...entries, entry],
        artifacts: artifacts,
      );

  ChapterAsset withoutEntryAt(int index) {
    final updated = List<ChapterEntry>.from(entries)..removeAt(index);
    return ChapterAsset(
      id: id,
      name: name,
      createdAt: createdAt,
      entries: updated,
      artifacts: artifacts,
    );
  }

  ChapterAsset withArtifact(ArtifactEntry artifact) => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: entries,
        artifacts: [...artifacts, artifact],
      );

  /// Replaces the artifact at [index] — the re-attune path, now that a charm's
  /// trajectory is typed rather than harvested from a spell and can therefore
  /// be changed without deleting and re-adding the charm.
  ChapterAsset withArtifactAt(int index, ArtifactEntry artifact) {
    final updated = List<ArtifactEntry>.from(artifacts);
    updated[index] = artifact;
    return ChapterAsset(
      id: id,
      name: name,
      createdAt: createdAt,
      entries: entries,
      artifacts: updated,
    );
  }

  ChapterAsset withoutArtifactAt(int index) {
    final updated = List<ArtifactEntry>.from(artifacts)..removeAt(index);
    return ChapterAsset(
      id: id,
      name: name,
      createdAt: createdAt,
      entries: entries,
      artifacts: updated,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'artifacts': artifacts.map((a) => a.toJson()).toList(),
      };

  static ChapterAsset fromJson(Map<String, dynamic> json) => ChapterAsset(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => ChapterEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        artifacts: (json['artifacts'] as List<dynamic>? ?? [])
            .map((a) => ArtifactEntry.fromJson(a as Map<String, dynamic>))
            .toList(),
      );

  static Future<Directory> _chaptersDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/chapters');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> save() async {
    final dir = await _chaptersDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  /// Deletes this chapter's persisted JSON file. Silently no-ops if already
  /// gone. Does NOT clear [loadActiveChapterId] if this happened to be the
  /// active chapter — callers (e.g. apprenticeship abandonment,
  /// docs/MASTER_APPRENTICE_PLAN.md §5.8) are responsible for that.
  Future<void> delete() async {
    final dir = await _chaptersDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  static Future<ChapterAsset?> loadById(String id) async {
    final dir = await _chaptersDir();
    final file = File('${dir.path}/$id.json');
    if (!await file.exists()) return null;
    return fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  static Future<List<ChapterAsset>> loadAll() async {
    final dir = await _chaptersDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final chapters = <ChapterAsset>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      chapters.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    chapters.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return chapters;
  }

  static Future<String?> loadActiveChapterId() async {
    final dir = await _chaptersDir();
    final file = File('${dir.path}/_active.txt');
    if (!await file.exists()) return null;
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  static Future<void> saveActiveChapterId(String? id) async {
    final dir = await _chaptersDir();
    final file = File('${dir.path}/_active.txt');
    if (id == null) {
      if (await file.exists()) await file.delete();
    } else {
      await file.writeAsString(id);
    }
  }

  /// Strips every [ChapterEntry] whose [ChapterEntry.spellId] is [spellId]
  /// out of every persisted chapter, saving only the chapters that actually
  /// changed. Called whenever a spell is deleted (crafted or loaned — both
  /// are [SpellAsset]s, and a [ChapterEntry] always points at a
  /// [SpellAsset.id] regardless of which tab it was added from) so a chapter
  /// never carries a dangling reference; previously this was only masked at
  /// battle-resolve time by [Chapter.fromChapterAsset]'s silent drop.
  static Future<void> removeSpellFromAllChapters(String spellId) async {
    for (final chapter in await loadAll()) {
      final idx = chapter.entries.indexWhere((e) => e.spellId == spellId);
      if (idx < 0) continue;
      var updated = chapter;
      while (true) {
        final i = updated.entries.indexWhere((e) => e.spellId == spellId);
        if (i < 0) break;
        updated = updated.withoutEntryAt(i);
      }
      await updated.save();
    }
  }
}
