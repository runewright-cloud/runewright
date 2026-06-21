// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_asset.dart — the persisted record of an inscribed spell: the proof
// binding a CA simulation to the player's Runekey, plus just enough
// metadata to eventually list in a library. The library UI itself is out
// of scope (CLAUDE.md: "Spellbook/bestiary UI... do not build") -- this is
// the "minimal persistence" half of the in-scope tracer bullet (inscribe a
// grid -> generate a proof -> persist it -> verify it), so [loadAll] exists
// and is tested even though no screen calls it yet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class SpellAsset {
  SpellAsset({
    required this.id,
    required this.createdAt,
    required this.tier,
    required this.t,
    required this.ownerPubkeyHex,
    required this.manaCost,
    required this.initialGrid,
    required this.proofBytes,
  });

  /// Unique within a device install -- a microsecond timestamp is more than
  /// sufficient for a single-player, button-press-cadence action (not a
  /// distributed identifier).
  final String id;
  final DateTime createdAt;

  /// Which of the three circuit tiers (12/24/48) this proof was generated
  /// against -- needed to pick the matching VK if this spell is ever
  /// re-verified.
  final int tier;

  /// Number of CA generations simulated (1 <= t <= tier).
  final int t;

  /// `owner_pubkey` hex, as bound into the proof's public inputs --
  /// CIRCUIT_IO.md CIRCUIT_IO 5/6.
  final String ownerPubkeyHex;

  final int manaCost;

  /// The 469-cell packed initial grid state (see HexGrid.packGridState) --
  /// kept alongside the proof so a future library UI can render a thumbnail
  /// without re-deriving it from the proof's opaque commitment.
  final List<int> initialGrid;

  /// Raw proof bytes in the noir-rs wire format (public inputs + proof,
  /// see TimedProofResult) -- self-contained, opaque to this app
  /// (CLAUDE.md hard invariant 1: never reimplement the circuit's crypto).
  final Uint8List proofBytes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'tier': tier,
        't': t,
        'ownerPubkeyHex': ownerPubkeyHex,
        'manaCost': manaCost,
        'initialGrid': initialGrid,
        'proofBytesBase64': base64Encode(proofBytes),
      };

  static SpellAsset fromJson(Map<String, dynamic> json) => SpellAsset(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        tier: json['tier'] as int,
        t: json['t'] as int,
        ownerPubkeyHex: json['ownerPubkeyHex'] as String,
        manaCost: json['manaCost'] as int,
        initialGrid: (json['initialGrid'] as List).cast<int>(),
        proofBytes: base64Decode(json['proofBytesBase64'] as String),
      );

  static Future<Directory> _spellsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/spells');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Persists this spell as `<app documents>/spells/<id>.json`. Returns the
  /// written file.
  Future<File> save() async {
    final dir = await _spellsDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  /// Loads every persisted spell, newest first. Not called by any screen
  /// yet (the library UI is a later milestone) -- exists so the read path
  /// is exercised by tests rather than written blind.
  static Future<List<SpellAsset>> loadAll() async {
    final dir = await _spellsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final assets = <SpellAsset>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      assets.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    assets.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return assets;
  }
}
