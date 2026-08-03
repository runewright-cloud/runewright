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

// ── Artifact loadout ──────────────────────────────────────────────────────────

// NOTE: the Air-typed slot is the Rod of Wind (design v3.0 §Artifacts): a
// one-shot consumable that adds +1 effective radius to the next spell's effects
// (and one size rung to a summoned minion). It replaced the v2.4 "absorption /
// deflection rod" whose status-nullify role now survives only through the
// *summoned* deflectionTotem (Water-Earth/Earth). `deflectionRod` is kept below
// only as a read-time JSON alias for any chapter persisted under the old name.
enum ArtifactKind { manaGem, bookmark, rodOfSpreading, counterCharm }

class ArtifactEntry {
  const ArtifactEntry({
    required this.kind,
    this.targetCommitmentHex,
    this.targetSpellName,
  });

  final ArtifactKind kind;

  /// [counterCharm] only: Poseidon2(packed_grid) of the attuned spell's grid.
  /// Null means the charm is unbound (added to the chapter but not yet
  /// attuned to a spell — see [ChapterAsset.bindFirstUnboundCounterCharm]).
  /// Once bound, triggers on the first cast of a spell with this grid
  /// commitment by any wizard in the match, including the charm's own owner.
  final String? targetCommitmentHex;

  /// [counterCharm] only: display-only name recorded at binding time.
  /// May become stale if the spell is later renamed or deleted.
  final String? targetSpellName;

  bool get isUnboundCounterCharm =>
      kind == ArtifactKind.counterCharm && targetCommitmentHex == null;

  ArtifactEntry copyWith({
    String? targetCommitmentHex,
    String? targetSpellName,
  }) =>
      ArtifactEntry(
        kind: kind,
        targetCommitmentHex: targetCommitmentHex ?? this.targetCommitmentHex,
        targetSpellName: targetSpellName ?? this.targetSpellName,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (targetCommitmentHex != null)
          'targetCommitmentHex': targetCommitmentHex,
        if (targetSpellName != null) 'targetSpellName': targetSpellName,
      };

  static ArtifactEntry fromJson(Map<String, dynamic> json) => ArtifactEntry(
        kind: _kindFromName(json['kind'] as String),
        targetCommitmentHex: json['targetCommitmentHex'] as String?,
        targetSpellName: json['targetSpellName'] as String?,
      );

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

  int get unboundCounterCharmCount =>
      artifacts.where((a) => a.isUnboundCounterCharm).length;

  /// Binds the first unbound counter charm in [artifacts] to [commitmentHex]
  /// / [spellName]. Returns the updated chapter, or `null` if there is no
  /// unbound charm to bind (caller shows "No unbound charms available.").
  ChapterAsset? bindFirstUnboundCounterCharm({
    required String commitmentHex,
    required String spellName,
  }) {
    final idx = artifacts.indexWhere((a) => a.isUnboundCounterCharm);
    if (idx < 0) return null;
    final updated = List<ArtifactEntry>.from(artifacts);
    updated[idx] = updated[idx].copyWith(
      targetCommitmentHex: commitmentHex,
      targetSpellName: spellName,
    );
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
}
