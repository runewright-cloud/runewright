// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_permission.dart — Owner-signed grant authorizing a named runekey to
// include a spell in a chapter and cast it in battle.
//
// Grants are at the grid-commitment level (commitmentHex = Poseidon2(packed_grid)),
// so one permission covers all Kin spells that share the same grid, regardless of T.
//
// Two kinds (see docs/COMMUNE_TRADE_PLAN.md):
//   loan     — day-limited (expiresAt required); the initial grid state is
//              never part of this record. Not re-tradeable by the grantee.
//   transfer — perpetual (expiresAt null); accompanies a full SpellAsset
//              (grid included) sent out-of-band. Carries a provenance chain.
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

/// Whether a [SpellPermission] is a day-limited loan or a perpetual transfer
/// grant. See docs/COMMUNE_TRADE_PLAN.md §2 for why indefinite/revocable
/// loans were ruled out — every loan carries an enforceable expiry instead.
enum SpellGrantKind { loan, transfer }

/// One hop in a transferred spell's custody chain: who held it, and when
/// they received it. Recorded (not yet independently re-verified per hop)
/// so a transfer chain reads as a genuine heirloom history in a future
/// provenance UI. Empty for [SpellGrantKind.loan] grants.
class ProvenanceStep {
  const ProvenanceStep({required this.pubkeyHex, required this.at});

  final String pubkeyHex;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'pubkeyHex': pubkeyHex,
        'at': at.toIso8601String(),
      };

  static ProvenanceStep fromJson(Map<String, dynamic> json) => ProvenanceStep(
        pubkeyHex: json['pubkeyHex'] as String,
        at: DateTime.parse(json['at'] as String),
      );
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
    required this.kind,
    this.expiresAt,
    this.provenance = const [],
  }) {
    if (kind == SpellGrantKind.loan && expiresAt == null) {
      throw ArgumentError('loan grants require a non-null expiresAt');
    }
    if (kind == SpellGrantKind.transfer && expiresAt != null) {
      throw ArgumentError('transfer grants must be perpetual (expiresAt must be null)');
    }
  }

  final String id;
  final DateTime grantedAt;

  /// Poseidon2(packed_grid) — identifies the loaned spell's grid
  /// (CIRCUIT_IO.md §4). A one-to-one GRID identity: this grant covers spells
  /// built on exactly this initial state, and nothing else.
  ///
  /// **Never re-key this to a behavioural kinship key.** Since
  /// docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 3, "Kin" means "does the same
  /// thing", which is deliberately many-to-one — a grant keyed that way would
  /// silently extend to spells with different grids, potentially someone
  /// else's coincidentally-matching spell. That is privilege escalation, not
  /// a display quirk. See spell_identity.dart for the two named concepts.
  ///
  /// This moves to `uniqueSpellId` (SHA-256 of the proof bytes, still
  /// one-to-one) in Phase 4, when deleting the commitment from the circuit
  /// forces it. It is deliberately NOT moving earlier: [canonicalMessage]
  /// covers this field, so re-keying invalidates every outstanding grant's
  /// signature.
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

  /// [SpellGrantKind.loan] or [SpellGrantKind.transfer].
  final SpellGrantKind kind;

  /// Required and enforced client-side for [SpellGrantKind.loan]; always
  /// null for [SpellGrantKind.transfer] (perpetual). Part of the signed
  /// message (see [canonicalMessage]) so a loanee cannot extend their own
  /// loan by editing the stored JSON.
  final DateTime? expiresAt;

  /// Custody chain for [SpellGrantKind.transfer] grants — original creator
  /// first, each subsequent holder appended on re-transfer. Empty for loans.
  final List<ProvenanceStep> provenance;

  // ── Expiry ───────────────────────────────────────────────────────────────

  /// True iff this is an expired loan as of [now] (defaults to the current
  /// UTC time). Always false for [SpellGrantKind.transfer].
  bool isExpired({DateTime? now}) {
    if (kind != SpellGrantKind.loan) return false;
    final clock = now ?? DateTime.now().toUtc();
    return !clock.isBefore(expiresAt!);
  }

  // ── Canonical message ─────────────────────────────────────────────────────

  /// The bytes the owner signs. Null-byte delimited to prevent prefix attacks.
  /// All hex strings are lowercased before encoding for canonical form.
  /// [expiresAt] is included so tampering with it on disk invalidates the
  /// signature — this is what makes the day-limited model enforceable
  /// without a revocation mechanism.
  List<int> get canonicalMessage =>
      _buildMessage(kind, ownerPubkeyHex, commitmentHex, granteePubkeyHex, expiresAt);

  static List<int> _buildMessage(
    SpellGrantKind kind,
    String ownerPubkeyHex,
    String commitmentHex,
    String granteePubkeyHex,
    DateTime? expiresAt,
  ) =>
      [
        ...utf8.encode('RUNEWRIGHT_SPELL_GRANT_V2\x00'),
        ...utf8.encode(kind.name),
        0,
        ...utf8.encode(ownerPubkeyHex.toLowerCase()),
        0,
        ...utf8.encode(commitmentHex.toLowerCase()),
        0,
        ...utf8.encode(granteePubkeyHex.toLowerCase()),
        0,
        ...utf8.encode(expiresAt?.toUtc().toIso8601String() ?? 'never'),
      ];

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Creates and signs a permission for [granteePubkeyHex] to use spells with
  /// [spell.commitmentHex]. Throws [ArgumentError] if [ownerIdentity] is not
  /// the owner of [spell] (their ownerPubkeyHex does not match the spell's),
  /// or if [kind]/[expiresAt] violate the loan-requires-expiry /
  /// transfer-must-be-perpetual invariant.
  static Future<SpellPermission> createAndSign({
    required SpellAsset spell,
    required Identity ownerIdentity,
    required String granteePubkeyHex,
    required SpellGrantKind kind,
    DateTime? expiresAt,
    List<ProvenanceStep> provenance = const [],
  }) async {
    final ownerPubkeyHex = await ownerIdentity.ownerPubkeyHex();
    if (!_hexEq(ownerPubkeyHex, spell.ownerPubkeyHex)) {
      throw ArgumentError('ownerIdentity is not the owner of spell ${spell.id}');
    }
    final msg = _buildMessage(kind, ownerPubkeyHex, spell.commitmentHex, granteePubkeyHex, expiresAt);
    final sigBytes = await ownerIdentity.sign(msg);
    return SpellPermission(
      id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
      grantedAt: DateTime.now().toUtc(),
      commitmentHex: spell.commitmentHex,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerRawPubkeyBase64: base64Encode(ownerIdentity.publicKeyBytes),
      granteePubkeyHex: granteePubkeyHex,
      signatureBase64: base64Encode(sigBytes),
      kind: kind,
      expiresAt: expiresAt,
      provenance: provenance,
    );
  }

  // ── Signature verification ────────────────────────────────────────────────

  /// Returns true iff:
  ///   1. [ownerRawPubkeyBase64] decodes to a key that Poseidon2-hashes to
  ///      [ownerPubkeyHex] (the raw key is genuine for this owner).
  ///   2. The Ed25519 signature over [canonicalMessage] is valid for that key.
  ///
  /// Does NOT check expiry — see [isCurrentlyUsable] for the combined check.
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

  /// True iff the signature is valid AND (for loans) not yet expired as of
  /// [now]. The check every call site should use before trusting a grant.
  Future<bool> isCurrentlyUsable({DateTime? now}) async {
    if (isExpired(now: now)) return false;
    return isSignatureValid();
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
        'kind': kind.name,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        'provenance': provenance.map((p) => p.toJson()).toList(),
      };

  static SpellPermission fromJson(Map<String, dynamic> json) => SpellPermission(
        id: json['id'] as String,
        grantedAt: DateTime.parse(json['grantedAt'] as String),
        commitmentHex: json['commitmentHex'] as String,
        ownerPubkeyHex: json['ownerPubkeyHex'] as String,
        ownerRawPubkeyBase64: json['ownerRawPubkeyBase64'] as String,
        granteePubkeyHex: json['granteePubkeyHex'] as String,
        signatureBase64: json['signatureBase64'] as String,
        kind: SpellGrantKind.values.byName(json['kind'] as String),
        expiresAt: json['expiresAt'] != null ? DateTime.parse(json['expiresAt'] as String) : null,
        provenance: (json['provenance'] as List<dynamic>? ?? [])
            .map((p) => ProvenanceStep.fromJson(p as Map<String, dynamic>))
            .toList(),
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
