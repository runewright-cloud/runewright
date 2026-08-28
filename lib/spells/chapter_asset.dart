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
// deflection rod" whose status-nullify role survives as AccoutrementKind.
// absorptionRod (summon-only, no loadout slot). `deflectionRod` is kept below
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
    this.armorSpellId,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final List<ChapterEntry> entries;
  final List<ArtifactEntry> artifacts;

  /// [SpellAsset.id] of the Aetherial Armor worn with this chapter, or null
  /// for a chapter with no armor (including every chapter persisted before
  /// armor existed).
  ///
  /// Armor is a chapter binding of its own rather than an [ArtifactEntry]
  /// because it behaves nothing like one: it costs a variable number of
  /// artifact slots (`ceil(T/4)`), it is permanent equipment rather than
  /// something activated or consumed, it carries a proof-backed inscription,
  /// and at most one may be worn — which is exactly what a single nullable
  /// field enforces structurally, with no validation to forget.
  ///
  /// Stored as an ID, not an embedded [SpellAsset]: a second copy of the asset
  /// would go stale against the library the moment the spell was renamed, and
  /// would double every proof's bytes in the chapter file. The trade-off is
  /// that this class cannot resolve the armor itself — see [artifactSlotsUsed]
  /// and lib/spells/chapter_armor.dart.
  final String? armorSpellId;

  bool get hasArmor => armorSpellId != null;

  /// Ordinary artifacts, which cost one slot each. Armor is not among them.
  int get ordinaryArtifactCount => artifacts.length;

  /// Total artifact slots consumed: one per ordinary artifact plus the armor's
  /// [armorSlotCost], which is `ceil(T/4)` and therefore not knowable from the
  /// chapter alone.
  ///
  /// [armorSlotCost] must be supplied by a caller that has resolved
  /// [armorSpellId] to its [SpellAsset] — required, not defaulted to 0, so a
  /// caller cannot silently under-count a chapter's armor and let it slip past
  /// the 12-slot budget. It is ignored entirely when [hasArmor] is false.
  /// lib/spells/chapter_armor.dart is the seam that does the resolving.
  int artifactSlotsUsed({required int armorSlotCost}) =>
      artifacts.length + (hasArmor ? armorSlotCost : 0);

  int artifactSlotsRemaining({required int armorSlotCost}) =>
      maxArtifactSlots - artifactSlotsUsed(armorSlotCost: armorSlotCost);

  /// Binds [spellId] as this chapter's armor, replacing any current binding —
  /// which is what releases the outgoing armor's slots.
  ///
  /// Deliberately unvalidated: whether [spellId] names an armor at all, and
  /// whether it fits the remaining budget, both need the [SpellAsset] this
  /// class cannot see. Prefer `bindArmor` in lib/spells/chapter_armor.dart,
  /// which checks both and calls this.
  ChapterAsset withArmor(String spellId) => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: entries,
        artifacts: artifacts,
        armorSpellId: spellId,
      );

  /// Removes the armor binding, immediately freeing its slots. Note this is
  /// the one copy path below that deliberately does NOT carry [armorSpellId].
  ChapterAsset withoutArmor() => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: entries,
        artifacts: artifacts,
        armorSpellId: null,
      );

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
      armorSpellId: armorSpellId,
    );
  }

  /// Returns a copy of this chapter renamed to [newName], keeping the same
  /// [id] — and therefore the same active-chapter selection and, if this
  /// chapter is a master's loan, the same loan identity.
  ChapterAsset rename(String newName) => ChapterAsset(
        id: id,
        name: newName,
        createdAt: createdAt,
        entries: entries,
        artifacts: artifacts,
        armorSpellId: armorSpellId,
      );

  /// Returns a new, independent chapter named [newName] with a fresh [id]
  /// and [createdAt], carrying over this chapter's spells and artifacts.
  /// Backs "Duplicate Chapter": players keep a chapter they like untouched
  /// and experiment on the copy instead. The copy is always a normal,
  /// editable chapter even when this one is a master's read-only loan
  /// (MASTER_APPRENTICE_PLAN.md §8) — loan status is tracked externally by
  /// chapter id, and the copy gets a new one.
  ChapterAsset copyAsNew(String newName) => ChapterAsset(
        id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
        name: newName,
        createdAt: DateTime.now().toUtc(),
        entries: entries,
        artifacts: artifacts,
        armorSpellId: armorSpellId,
      );

  ChapterAsset withEntry(ChapterEntry entry) => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: [...entries, entry],
        artifacts: artifacts,
        armorSpellId: armorSpellId,
      );

  ChapterAsset withoutEntryAt(int index) {
    final updated = List<ChapterEntry>.from(entries)..removeAt(index);
    return ChapterAsset(
      id: id,
      name: name,
      createdAt: createdAt,
      entries: updated,
      artifacts: artifacts,
      armorSpellId: armorSpellId,
    );
  }

  ChapterAsset withArtifact(ArtifactEntry artifact) => ChapterAsset(
        id: id,
        name: name,
        createdAt: createdAt,
        entries: entries,
        artifacts: [...artifacts, artifact],
        armorSpellId: armorSpellId,
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
      armorSpellId: armorSpellId,
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
      armorSpellId: armorSpellId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'artifacts': artifacts.map((a) => a.toJson()).toList(),
        // Omitted entirely when absent, so a chapter with no armor serialises
        // byte-identically to how it did before armor existed.
        if (armorSpellId != null) 'armorSpellId': armorSpellId,
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
        // Absent in every chapter persisted before armor existed: those load
        // as no-armor chapters.
        armorSpellId: json['armorSpellId'] as String?,
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
  /// out of every persisted chapter — and clears [armorSpellId] on any chapter
  /// wearing it as armor — saving only the chapters that actually changed.
  ///
  /// The armor half matters for more than tidiness: a dangling armor binding
  /// would keep consuming its `ceil(T/4)` slots forever, since the only thing
  /// that knows the cost is the [SpellAsset] that was just deleted. Called whenever a spell is deleted (crafted or loaned — both
  /// are [SpellAsset]s, and a [ChapterEntry] always points at a
  /// [SpellAsset.id] regardless of which tab it was added from) so a chapter
  /// never carries a dangling reference; previously this was only masked at
  /// battle-resolve time by [Chapter.fromChapterAsset]'s silent drop.
  static Future<void> removeSpellFromAllChapters(String spellId) async {
    for (final chapter in await loadAll()) {
      final hasEntry = chapter.entries.any((e) => e.spellId == spellId);
      final wornAsArmor = chapter.armorSpellId == spellId;
      if (!hasEntry && !wornAsArmor) continue;
      var updated = chapter;
      while (true) {
        final i = updated.entries.indexWhere((e) => e.spellId == spellId);
        if (i < 0) break;
        updated = updated.withoutEntryAt(i);
      }
      if (wornAsArmor) updated = updated.withoutArmor();
      await updated.save();
    }
  }
}
