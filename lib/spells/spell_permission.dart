// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_permission.dart — Owner-signed grant authorizing a named runekey to
// include a spell in a chapter and cast it in battle.
//
// Grants are at the grid-commitment level (commitmentHex = Poseidon2(packed_grid)),
// so one permission covers all Kin spells that share the same grid, regardless of T.
//
// Signature scheme: Ed25519 off-circuit (CLAUDE.md hard invariant 5).
// The owner's raw Ed25519 public key bytes are embedded so the verifying peer
// can (a) confirm the key maps to the circuit-level ownerPubkeyHex via Poseidon2
// and (b) verify the Ed25519 signature — without any prior key exchange.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../identity/identity.dart';
import 'spell_asset.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

class SpellPermission {
  SpellPermission({
    required this.id,
    required this.grantedAt,
    required this.commitmentHex,
    required this.ownerPubkeyHex,
    required this.ownerRawPubkeyBase64,
    required this.granteePubkeyHex,
    required this.signatureBase64,
  });

  final String id;
  final DateTime grantedAt;

  /// Poseidon2(packed_grid) — identifies the loaned spell's grid (CIRCUIT_IO.md §4).
  /// Covers all Kin spells sharing this grid commitment.
  final String commitmentHex;

  /// Poseidon2(owner_key_hi, owner_key_lo) — must equal the spell proof's
  /// owner_pubkey public input (CIRCUIT_IO.md §5).
  final String ownerPubkeyHex;

  /// Raw 32-byte Ed25519 public key of the owner, base64-encoded.
  /// Lets the verifying peer confirm this key maps to ownerPubkeyHex via
  /// Poseidon2, and verify the Ed25519 signature — no prior key exchange needed.
  final String ownerRawPubkeyBase64;

  /// Poseidon2(grantee_key_hi, grantee_key_lo) — the circuit-facing pubkey of
  /// the authorized player (matched against the casting player's owner_pubkey
  /// extracted from their spell proof in battle).
  final String granteePubkeyHex;

  /// Ed25519 signature by the owner over [canonicalMessage].
  final String signatureBase64;

  // ── Canonical message ─────────────────────────────────────────────────────

  /// The bytes the owner signs. Null-byte delimited to prevent prefix attacks.
  /// All hex strings are lowercased before encoding for canonical form.
  List<int> get canonicalMessage =>
      _buildMessage(ownerPubkeyHex, commitmentHex, granteePubkeyHex);

  static List<int> _buildMessage(
    String ownerPubkeyHex,
    String commitmentHex,
    String granteePubkeyHex,
  ) =>
      [
        ...utf8.encode('RUNEWRIGHT_SPELL_LOAN_V1\x00'),
        ...utf8.encode(ownerPubkeyHex.toLowerCase()),
        0,
        ...utf8.encode(commitmentHex.toLowerCase()),
        0,
        ...utf8.encode(granteePubkeyHex.toLowerCase()),
      ];

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Creates and signs a permission for [granteePubkeyHex] to use spells with
  /// [spell.commitmentHex]. Throws [ArgumentError] if [ownerIdentity] is not
  /// the owner of [spell] (their ownerPubkeyHex does not match the spell's).
  static Future<SpellPermission> createAndSign({
    required SpellAsset spell,
    required Identity ownerIdentity,
    required String granteePubkeyHex,
  }) async {
    final ownerPubkeyHex = await ownerIdentity.ownerPubkeyHex();
    if (!_hexEq(ownerPubkeyHex, spell.ownerPubkeyHex)) {
      throw ArgumentError('ownerIdentity is not the owner of spell ${spell.id}');
    }
    final msg = _buildMessage(ownerPubkeyHex, spell.commitmentHex, granteePubkeyHex);
    final sigBytes = await ownerIdentity.sign(msg);
    return SpellPermission(
      id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
      grantedAt: DateTime.now().toUtc(),
      commitmentHex: spell.commitmentHex,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerRawPubkeyBase64: base64Encode(ownerIdentity.publicKeyBytes),
      granteePubkeyHex: granteePubkeyHex,
      signatureBase64: base64Encode(sigBytes),
    );
  }

  // ── Signature verification ────────────────────────────────────────────────

  /// Returns true iff:
  ///   1. [ownerRawPubkeyBase64] decodes to a key that Poseidon2-hashes to
  ///      [ownerPubkeyHex] (the raw key is genuine for this owner).
  ///   2. The Ed25519 signature over [canonicalMessage] is valid for that key.
  Future<bool> isSignatureValid() async {
    final rawPubKey = base64Decode(ownerRawPubkeyBase64);
    final pubkeyMatches = await Identity.ownerPubkeyMatches(
      presentedPubkeyBytes: rawPubKey,
      claimedOwnerPubkeyHex: ownerPubkeyHex,
    );
    if (!pubkeyMatches) return false;
    return Identity.verify(
      message: canonicalMessage,
      signatureBytes: base64Decode(signatureBase64),
      publicKeyBytes: rawPubKey,
    );
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'grantedAt': grantedAt.toIso8601String(),
        'commitmentHex': commitmentHex,
        'ownerPubkeyHex': ownerPubkeyHex,
        'ownerRawPubkeyBase64': ownerRawPubkeyBase64,
        'granteePubkeyHex': granteePubkeyHex,
        'signatureBase64': signatureBase64,
      };

  static SpellPermission fromJson(Map<String, dynamic> json) => SpellPermission(
        id: json['id'] as String,
        grantedAt: DateTime.parse(json['grantedAt'] as String),
        commitmentHex: json['commitmentHex'] as String,
        ownerPubkeyHex: json['ownerPubkeyHex'] as String,
        ownerRawPubkeyBase64: json['ownerRawPubkeyBase64'] as String,
        granteePubkeyHex: json['granteePubkeyHex'] as String,
        signatureBase64: json['signatureBase64'] as String,
      );

  // ── Persistence ───────────────────────────────────────────────────────────

  static Future<Directory> _permissionsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/permissions');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> save() async {
    final dir = await _permissionsDir();
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  Future<void> delete() async {
    final dir = await _permissionsDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  static Future<List<SpellPermission>> loadAll() async {
    final dir = await _permissionsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final perms = <SpellPermission>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      perms.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    return perms;
  }

  /// All locally stored permissions whose commitmentHex matches [commitmentHex].
  static Future<List<SpellPermission>> loadForCommitment(String commitmentHex) async {
    final all = await loadAll();
    return all.where((p) => _hexEq(p.commitmentHex, commitmentHex)).toList();
  }
}
