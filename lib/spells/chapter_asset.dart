// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_asset.dart — a persisted bundle of spell references and artifact
// loadout the player intends to carry into battle. Each spell entry optionally
// carries an embellishment derived from a supreme-dominance tag earned during
// inscription. Each artifact slot holds one of four kinds of battle items.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// ── Artifact loadout ──────────────────────────────────────────────────────────

enum ArtifactKind { manaGem, bookmark, deflectionRod, counterCharm }

class ArtifactEntry {
  const ArtifactEntry({
    required this.kind,
    this.targetCommitmentHex,
    this.targetSpellName,
  });

  final ArtifactKind kind;

  /// [counterCharm] only: Poseidon2(packed_grid) of the attuned spell's grid.
  /// Triggers only when the opponent casts a spell with this grid commitment —
  /// your own casts of the same grid are ignored.
  final String? targetCommitmentHex;

  /// [counterCharm] only: display-only name recorded at attunement time.
  /// May become stale if the spell is later renamed or deleted.
  final String? targetSpellName;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (targetCommitmentHex != null)
          'targetCommitmentHex': targetCommitmentHex,
        if (targetSpellName != null) 'targetSpellName': targetSpellName,
      };

  static ArtifactEntry fromJson(Map<String, dynamic> json) => ArtifactEntry(
        kind: ArtifactKind.values.byName(json['kind'] as String),
        targetCommitmentHex: json['targetCommitmentHex'] as String?,
        targetSpellName: json['targetSpellName'] as String?,
      );
}

// ── Spell loadout ─────────────────────────────────────────────────────────────

class ChapterEntry {
  const ChapterEntry({required this.spellId, this.embellishment});

  /// ID of the included spell (matches SpellAsset.id).
  final String spellId;

  /// Zone name ('fire'/'air'/'water'/'earth') of the chosen embellishment,
  /// or null if the spell was added without one.
  final String? embellishment;

  Map<String, dynamic> toJson() => {
        'spellId': spellId,
        if (embellishment != null) 'embellishment': embellishment,
      };

  static ChapterEntry fromJson(Map<String, dynamic> json) => ChapterEntry(
        spellId: json['spellId'] as String,
        embellishment: json['embellishment'] as String?,
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
