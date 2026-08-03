// SPDX-License-Identifier: GPL-3.0-or-later
//
// sighting_asset.dart — a spell observed cast by an opponent in a real LAN
// duel (docs/SIGHTINGS_PLAN.md). Read-only bestiary data, grouped by
// opponent (ownerPubkeyHex) with the distinct spells (commitmentHex) seen
// from them. Mirrors lib/spells/spell_asset.dart's file-per-record JSON
// persistence pattern.
//
// Never stores the opponent's initial grid — it is never revealed by the
// zero-knowledge proof and must not be fabricated (CLAUDE.md hard
// invariant, SIGHTINGS_PLAN.md §9). Mana cost is the certified BASE cost
// (see turn_loop.dart's _certifiedBaseManaCost), not the per-cast,
// modifier-laden verifiedCost.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'spell_asset.dart';

class SightingAsset {
  const SightingAsset({
    required this.opponentPubkeyHex,
    this.opponentName,
    required this.commitmentHex,
    required this.spellName,
    this.formula = const [],
    required this.t,
    required this.tier,
    required this.manaCost,
    required this.firstSeen,
    required this.lastSeen,
    required this.timesSeen,
    this.artHash,
    this.artSource,
    this.artUpdatedAt,
  });

  /// Poseidon2(caster's pubkey) — the canonical grouping/identity key. Never
  /// spoofable the way a wizard name is (SIGHTINGS_PLAN.md §2).
  final String opponentPubkeyHex;

  /// The caster's wizard name, if a later LAN/handshake change ever plumbs
  /// one through. Null today — no authenticated wizard-name reaches
  /// BattleScreen yet. Never dedupe or group on this field.
  final String? opponentName;

  /// The spell's grid commitment — identity/dedup key for "distinct spells"
  /// under one opponent. Never the name (unauthenticated flavor).
  final String commitmentHex;

  /// The spell's own flavor name, from the wire's name field. '' if the
  /// casting peer predates that wire change. Unauthenticated — cosmetic
  /// only, never trusted as identity.
  final String spellName;

  /// Public effect breakdown (BorderZone enum names), as cast.
  final List<String> formula;

  /// Generation count of the sighted cast.
  final int t;

  final int tier;

  /// Certified BASE mana cost (5×segmentCount + dotCount, grown by
  /// 1.05^T × 1.5^effectCount) — the clean bestiary stat, not the per-cast
  /// modifier-laden cost actually deducted from the caster's pool.
  final int manaCost;

  final DateTime firstSeen;
  final DateTime lastSeen;
  final int timesSeen;

  /// Hex SHA-256 of the synced full-size art bytes (same hashing scheme as
  /// spell_art_import.dart's artHashHex), or null if no art has been synced
  /// for this sighting yet. The bytes themselves live in [SpellArtStore],
  /// keyed by [id] (lib/trade/sync_art_session.dart) — not stored here, same
  /// reasoning as SpellAsset.artHash.
  final String? artHash;

  /// Always [SpellArtSource.synced] when [artHash] is set — art for a
  /// sighting only ever arrives via a Commune/Sync Art session.
  final SpellArtSource? artSource;

  /// When [artHash] was last set. Null iff [artHash] is null.
  final DateTime? artUpdatedAt;

  /// File id for this (opponent, spell) pair — deterministic so a repeat
  /// cast upserts rather than duplicates. Both hexes are already path-safe
  /// (hex digits only) once the `0x` prefix is stripped.
  String get id => _idFor(opponentPubkeyHex, commitmentHex);

  static String _stripHexPrefix(String hex) =>
      hex.startsWith('0x') ? hex.substring(2) : hex;

  static String _idFor(String opponentPubkeyHex, String commitmentHex) =>
      '${_stripHexPrefix(opponentPubkeyHex)}_${_stripHexPrefix(commitmentHex)}';

  Map<String, dynamic> toJson() => {
        'opponentPubkeyHex': opponentPubkeyHex,
        if (opponentName != null) 'opponentName': opponentName,
        'commitmentHex': commitmentHex,
        'spellName': spellName,
        'formula': formula,
        't': t,
        'tier': tier,
        'manaCost': manaCost,
        'firstSeen': firstSeen.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'timesSeen': timesSeen,
        if (artHash != null) 'artHash': artHash,
        if (artSource != null) 'artSource': artSource!.name,
        if (artUpdatedAt != null) 'artUpdatedAt': artUpdatedAt!.toIso8601String(),
      };

  static SightingAsset fromJson(Map<String, dynamic> json) => SightingAsset(
        opponentPubkeyHex: json['opponentPubkeyHex'] as String,
        opponentName: json['opponentName'] as String?,
        commitmentHex: json['commitmentHex'] as String,
        spellName: (json['spellName'] as String?) ?? '',
        formula: (json['formula'] as List<dynamic>? ?? []).cast<String>(),
        t: json['t'] as int,
        tier: json['tier'] as int,
        manaCost: (json['manaCost'] as int?) ?? 0,
        firstSeen: DateTime.parse(json['firstSeen'] as String),
        lastSeen: DateTime.parse(json['lastSeen'] as String),
        timesSeen: (json['timesSeen'] as int?) ?? 1,
        artHash: json['artHash'] as String?,
        artSource: switch (json['artSource'] as String?) {
          null => null,
          final s => SpellArtSource.values.firstWhere((v) => v.name == s,
              orElse: () => SpellArtSource.synced),
        },
        artUpdatedAt: json['artUpdatedAt'] != null
            ? DateTime.parse(json['artUpdatedAt'] as String)
            : null,
      );

  /// Returns a copy with custom-art metadata set to [hash], stamped with the
  /// current time and [SpellArtSource.synced]. The art bytes themselves go to
  /// [SpellArtStore.save] separately (keyed by [id]) — this only updates the
  /// pointer. Mirrors [SpellAsset.withArt].
  SightingAsset withArt({required String hash}) => SightingAsset(
        opponentPubkeyHex: opponentPubkeyHex,
        opponentName: opponentName,
        commitmentHex: commitmentHex,
        spellName: spellName,
        formula: formula,
        t: t,
        tier: tier,
        manaCost: manaCost,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        timesSeen: timesSeen,
        artHash: hash,
        artSource: SpellArtSource.synced,
        artUpdatedAt: DateTime.now().toUtc(),
      );

  /// Returns a copy with custom-art metadata cleared. Does NOT delete the
  /// stored blob; callers pair this with [SpellArtStore.delete].
  SightingAsset withoutArt() => SightingAsset(
        opponentPubkeyHex: opponentPubkeyHex,
        opponentName: opponentName,
        commitmentHex: commitmentHex,
        spellName: spellName,
        formula: formula,
        t: t,
        tier: tier,
        manaCost: manaCost,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        timesSeen: timesSeen,
      );

  static Future<Directory> _sightingsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sightings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Persists this sighting as `<app documents>/sightings/<id>.json`.
  Future<File> save() async {
    final dir = await _sightingsDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  /// Deletes this sighting's persisted JSON file. Silently no-ops if already gone.
  Future<void> delete() async {
    final dir = await _sightingsDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  /// Loads every persisted sighting. Order is unspecified — callers group
  /// by [opponentPubkeyHex] and sort as needed (see library_screen.dart's
  /// Sightings tab).
  static Future<List<SightingAsset>> loadAll() async {
    final dir = await _sightingsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final assets = <SightingAsset>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      assets.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    return assets;
  }

  /// Deletes every sighting recorded for [opponentPubkeyHex] — a future
  /// "forget this rival" action (SIGHTINGS_PLAN.md §3).
  static Future<void> deleteAllForOpponent(String opponentPubkeyHex) async {
    final all = await loadAll();
    for (final s in all) {
      if (s.opponentPubkeyHex == opponentPubkeyHex) await s.delete();
    }
  }

  /// Upsert: records a sighting of [commitmentHex] cast by [opponentPubkeyHex].
  /// If this (opponent, spell) pair was already recorded, advances [lastSeen]
  /// and increments [timesSeen] while preserving [firstSeen] — [formula],
  /// [spellName], [t], [tier], [manaCost] are refreshed from this call's
  /// values when non-empty/non-zero (a later cast may carry fuller data than
  /// an earlier one, e.g. once the spell-name wire change lands), otherwise
  /// the prior value is kept rather than overwritten with a blank. Never
  /// touches [opponentName] on downgrade: a null here does not clear a
  /// previously-recorded name. Also never touches [artHash]/[artSource]/
  /// [artUpdatedAt] — a battle-cast upsert must not erase art a prior
  /// Commune/Sync Art session wrote (lib/trade/sync_art_session.dart).
  static Future<SightingAsset> record({
    required String opponentPubkeyHex,
    String? opponentName,
    required String commitmentHex,
    required String spellName,
    List<String> formula = const [],
    required int t,
    required int tier,
    required int manaCost,
  }) async {
    final id = _idFor(opponentPubkeyHex, commitmentHex);
    final dir = await _sightingsDir();
    final file = File('${dir.path}/$id.json');
    final existing = await file.exists()
        ? fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>)
        : null;
    final now = DateTime.now().toUtc();

    final asset = SightingAsset(
      opponentPubkeyHex: opponentPubkeyHex,
      opponentName: opponentName ?? existing?.opponentName,
      commitmentHex: commitmentHex,
      spellName: spellName.isNotEmpty ? spellName : (existing?.spellName ?? ''),
      formula: formula.isNotEmpty ? formula : (existing?.formula ?? const []),
      t: t,
      tier: tier,
      manaCost: manaCost != 0 ? manaCost : (existing?.manaCost ?? 0),
      firstSeen: existing?.firstSeen ?? now,
      lastSeen: now,
      timesSeen: (existing?.timesSeen ?? 0) + 1,
      artHash: existing?.artHash,
      artSource: existing?.artSource,
      artUpdatedAt: existing?.artUpdatedAt,
    );
    await asset.save();
    return asset;
  }

  /// A lightweight [SpellAsset] view for reusing [SpellCardWidget] and
  /// [formulaEffectLabels] unchanged. The grid is never synthesized — it was
  /// never revealed by the opponent's proof (SIGHTINGS_PLAN.md §9).
  ///
  /// [SpellAsset.spellHashHex] is set to [id] rather than left empty: that
  /// field means nothing crypto-wise here (this is a display-only view, not
  /// a faithful reconstruction — see the already-stubbed [proofBytes]/
  /// [segmentCount] below), but [SpellCardWidget] and [SpellArtStore] key art
  /// purely off it as an opaque store key (spell_card_painter.dart's
  /// `_hasCustomArt`/`_loadThumb`), and Sync Art stores synced art under
  /// [id] (lib/trade/sync_art_session.dart) for exactly this reuse. Do not
  /// "fix" this into a real Poseidon2 hash — there is no proof to derive one
  /// from.
  SpellAsset toDisplaySpell() => SpellAsset(
        id: id,
        createdAt: firstSeen,
        tier: tier,
        t: t,
        ownerPubkeyHex: opponentPubkeyHex,
        manaCost: manaCost,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: spellName,
        commitmentHex: commitmentHex,
        spellHashHex: id,
        formula: formula,
        artHash: artHash,
        artSource: artSource,
        artUpdatedAt: artUpdatedAt,
      );
}
