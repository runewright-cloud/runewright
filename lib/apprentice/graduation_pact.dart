// SPDX-License-Identifier: GPL-3.0-or-later
//
// graduation_pact.dart — the pre-agreed terms of a graduation battle
// (docs/MASTER_APPRENTICE_PLAN.md §7.2). A battle for stakes needs both
// signatures BEFORE the duel, or the loser can simply deny the terms
// afterwards — this is the artifact that closes that gap, the same role
// `match_outcome.dart` plays for the battle's result. Canonical message,
// off-circuit Ed25519, file-per-record persistence — same discipline as
// every other signed artifact in this codebase.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../battle/models/match_outcome.dart';
import '../identity/identity.dart';
import '../spells/basic_spells.dart' show isBasicSpell;
import '../spells/spell_asset.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

/// Every entry in [stakeCommitments] that does NOT resolve to a natively-
/// owned, non-Basic spell among [localSpells] — the apprentice-side check
/// §7.2 requires before accepting a proposed pact ("do not let a pact
/// promise something that cannot be delivered"). An empty result means
/// every stake is honestly deliverable; a non-empty one is grounds to
/// auto-decline with the specific reason.
List<String> unresolvableStakeCommitments({
  required List<String> stakeCommitments,
  required String apprenticeOwnerPubkeyHex,
  required List<SpellAsset> localSpells,
}) {
  final byCommitment = <String, SpellAsset>{};
  for (final s in localSpells) {
    byCommitment[s.commitmentHex.toLowerCase()] = s;
  }
  final unresolvable = <String>[];
  for (final commitment in stakeCommitments) {
    final spell = byCommitment[commitment.toLowerCase()];
    if (spell == null ||
        isBasicSpell(spell) ||
        !_hexEq(spell.ownerPubkeyHex, apprenticeOwnerPubkeyHex)) {
      unresolvable.add(commitment);
    }
  }
  return unresolvable;
}

/// A fresh 16-byte pact id, hex-encoded — the master generates one per
/// proposed pact (docs/MASTER_APPRENTICE_PLAN.md §7.2).
String generatePactIdHex() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// The unsigned terms both parties will sign. Both commitment lists are
/// sorted (lowercase hex) inside [canonicalMessage] so the two sides always
/// build byte-identical bytes regardless of the order either device
/// happened to collect them in.
class GraduationPact {
  const GraduationPact({
    required this.pactIdHex,
    required this.masterPubkeyHex,
    required this.apprenticePubkeyHex,
    required this.chapterName,
    required this.chapterCommitments,
    required this.stakeCommitments,
    required this.agreedAt,
  });

  final String pactIdHex;
  final String masterPubkeyHex;
  final String apprenticePubkeyHex;

  /// Display name of the loaned chapter at stake — what the apprentice wins.
  final String chapterName;

  /// What the apprentice wins if they win the battle — the apprenticeship's
  /// current `grantedCommitments` snapshot, i.e. the same set a bequest
  /// (§7.1) would convert.
  final List<String> chapterCommitments;

  /// What the master wins if they win the battle — drawn from the master's
  /// `SightingAsset` records of the apprentice (§7.2's stakes picker). May
  /// be empty: an unwagered graduation battle is legal.
  final List<String> stakeCommitments;

  final DateTime agreedAt;

  List<int> get canonicalMessage => _buildMessage(
        pactIdHex: pactIdHex,
        masterPubkeyHex: masterPubkeyHex,
        apprenticePubkeyHex: apprenticePubkeyHex,
        chapterCommitments: chapterCommitments,
        stakeCommitments: stakeCommitments,
        agreedAt: agreedAt,
      );

  static List<int> _buildMessage({
    required String pactIdHex,
    required String masterPubkeyHex,
    required String apprenticePubkeyHex,
    required List<String> chapterCommitments,
    required List<String> stakeCommitments,
    required DateTime agreedAt,
  }) {
    final sortedChapter = chapterCommitments.map((c) => c.toLowerCase()).toList()..sort();
    final sortedStakes = stakeCommitments.map((c) => c.toLowerCase()).toList()..sort();
    const unitSeparator = '\x1F';
    return [
      ...utf8.encode('RUNEWRIGHT_GRADUATION_PACT_V1\x00'),
      ...utf8.encode(pactIdHex.toLowerCase()),
      0,
      ...utf8.encode(masterPubkeyHex.toLowerCase()),
      0,
      ...utf8.encode(apprenticePubkeyHex.toLowerCase()),
      0,
      ...utf8.encode(sortedChapter.join(unitSeparator)),
      0,
      ...utf8.encode(sortedStakes.join(unitSeparator)),
      0,
      ...utf8.encode(agreedAt.toUtc().toIso8601String()),
    ];
  }

  Map<String, dynamic> toJson() => {
        'pactIdHex': pactIdHex,
        'masterPubkeyHex': masterPubkeyHex,
        'apprenticePubkeyHex': apprenticePubkeyHex,
        'chapterName': chapterName,
        'chapterCommitments': chapterCommitments,
        'stakeCommitments': stakeCommitments,
        'agreedAt': agreedAt.toIso8601String(),
      };

  static GraduationPact fromJson(Map<String, dynamic> json) => GraduationPact(
        pactIdHex: json['pactIdHex'] as String,
        masterPubkeyHex: json['masterPubkeyHex'] as String,
        apprenticePubkeyHex: json['apprenticePubkeyHex'] as String,
        chapterName: json['chapterName'] as String,
        chapterCommitments: (json['chapterCommitments'] as List<dynamic>? ?? []).cast<String>(),
        stakeCommitments: (json['stakeCommitments'] as List<dynamic>? ?? []).cast<String>(),
        agreedAt: DateTime.parse(json['agreedAt'] as String),
      );
}

/// [GraduationPact] plus zero, one, or both parties' signatures over its
/// canonical message. Only an [isFullyValid] pact — both signatures present
/// and verified — authorizes a graduation battle or its settlement; a
/// half-signed pact is just a proposal.
class SignedGraduationPact {
  const SignedGraduationPact({
    required this.pact,
    this.masterSignatureBase64,
    this.masterRawPubkeyBase64,
    this.apprenticeSignatureBase64,
    this.apprenticeRawPubkeyBase64,
  });

  final GraduationPact pact;
  final String? masterSignatureBase64;
  final String? masterRawPubkeyBase64;
  final String? apprenticeSignatureBase64;
  final String? apprenticeRawPubkeyBase64;

  bool get isFullySigned =>
      masterSignatureBase64 != null &&
      masterRawPubkeyBase64 != null &&
      apprenticeSignatureBase64 != null &&
      apprenticeRawPubkeyBase64 != null;

  /// The master's initial proposal: [pact] signed only on the master's side.
  static Future<SignedGraduationPact> proposedByMaster({
    required GraduationPact pact,
    required Identity masterIdentity,
  }) async {
    final sig = await masterIdentity.sign(pact.canonicalMessage);
    return SignedGraduationPact(
      pact: pact,
      masterSignatureBase64: base64Encode(sig),
      masterRawPubkeyBase64: base64Encode(masterIdentity.publicKeyBytes),
    );
  }

  /// Returns a copy with the apprentice's signature added — called after
  /// the apprentice reviews and accepts a master-proposed pact. Does NOT
  /// check the master's existing signature; call [isFullyValid] on the
  /// result before trusting it.
  Future<SignedGraduationPact> signedByApprentice({required Identity apprenticeIdentity}) async {
    final sig = await apprenticeIdentity.sign(pact.canonicalMessage);
    return SignedGraduationPact(
      pact: pact,
      masterSignatureBase64: masterSignatureBase64,
      masterRawPubkeyBase64: masterRawPubkeyBase64,
      apprenticeSignatureBase64: base64Encode(sig),
      apprenticeRawPubkeyBase64: base64Encode(apprenticeIdentity.publicKeyBytes),
    );
  }

  Future<bool> isMasterSignatureValid() async {
    final sig = masterSignatureBase64;
    final rawPubkeyB64 = masterRawPubkeyBase64;
    if (sig == null || rawPubkeyB64 == null) return false;
    final rawPubKey = base64Decode(rawPubkeyB64);
    final matches = await Identity.ownerPubkeyMatches(
      presentedPubkeyBytes: rawPubKey,
      claimedOwnerPubkeyHex: pact.masterPubkeyHex,
    );
    if (!matches) return false;
    return Identity.verify(
      message: pact.canonicalMessage,
      signatureBytes: base64Decode(sig),
      publicKeyBytes: rawPubKey,
    );
  }

  Future<bool> isApprenticeSignatureValid() async {
    final sig = apprenticeSignatureBase64;
    final rawPubkeyB64 = apprenticeRawPubkeyBase64;
    if (sig == null || rawPubkeyB64 == null) return false;
    final rawPubKey = base64Decode(rawPubkeyB64);
    final matches = await Identity.ownerPubkeyMatches(
      presentedPubkeyBytes: rawPubKey,
      claimedOwnerPubkeyHex: pact.apprenticePubkeyHex,
    );
    if (!matches) return false;
    return Identity.verify(
      message: pact.canonicalMessage,
      signatureBytes: base64Decode(sig),
      publicKeyBytes: rawPubKey,
    );
  }

  /// True iff both signatures are present AND independently verify against
  /// their claimed party's pubkey. The check every call site must run
  /// before treating a pact as binding — a duel result, a settlement, or
  /// even just displaying "this battle is for real stakes."
  Future<bool> isFullyValid() async {
    if (!isFullySigned) return false;
    if (!await isMasterSignatureValid()) return false;
    if (!await isApprenticeSignatureValid()) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'pact': pact.toJson(),
        if (masterSignatureBase64 != null) 'masterSignatureBase64': masterSignatureBase64,
        if (masterRawPubkeyBase64 != null) 'masterRawPubkeyBase64': masterRawPubkeyBase64,
        if (apprenticeSignatureBase64 != null) 'apprenticeSignatureBase64': apprenticeSignatureBase64,
        if (apprenticeRawPubkeyBase64 != null) 'apprenticeRawPubkeyBase64': apprenticeRawPubkeyBase64,
      };

  static SignedGraduationPact fromJson(Map<String, dynamic> json) => SignedGraduationPact(
        pact: GraduationPact.fromJson(json['pact'] as Map<String, dynamic>),
        masterSignatureBase64: json['masterSignatureBase64'] as String?,
        masterRawPubkeyBase64: json['masterRawPubkeyBase64'] as String?,
        apprenticeSignatureBase64: json['apprenticeSignatureBase64'] as String?,
        apprenticeRawPubkeyBase64: json['apprenticeRawPubkeyBase64'] as String?,
      );

  // ── Persistence ──────────────────────────────────────────────────────────

  static Future<Directory> _pactsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/pacts');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> save() async {
    final dir = await _pactsDir();
    final file = File('${dir.path}/${pact.pactIdHex}.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  static Future<SignedGraduationPact?> loadByPactId(String pactIdHex) async {
    final dir = await _pactsDir();
    final file = File('${dir.path}/$pactIdHex.json');
    if (!await file.exists()) return null;
    return fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  static Future<List<SignedGraduationPact>> loadAll() async {
    final dir = await _pactsDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final pacts = <SignedGraduationPact>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      pacts.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    return pacts;
  }
}

/// Who won the graduation battle a [SignedGraduationPact] staked, as
/// resolved by [resolveGraduationSettlement].
enum GraduationVictor { apprentice, master }

/// The pre-settlement trust gate (docs/MASTER_APPRENTICE_PLAN.md §7.4):
/// "Each side, before emitting or accepting anything, checks: the outcome
/// record's pactIdHex matches the pact; both signatures on the outcome
/// verify against the pact's two pubkeys; the victor is one of the two."
///
/// Returns which party won iff ALL of the following hold, or `null`
/// (settlement must not proceed) otherwise:
///   - [pact] is itself [SignedGraduationPact.isFullyValid] (both parties
///     actually agreed to these terms before the duel);
///   - [outcome] is itself [MatchOutcomeRecord.isFullyValid] (both parties
///     signed the SAME result after the duel);
///   - `outcome.outcome.pactIdHex` names [pact] — an outcome from an
///     unrelated (or ordinary, non-graduation) duel must never settle stakes;
///   - the outcome's victor/loser pair is EXACTLY {master, apprentice} —
///     never a third party.
///
/// This is the one function both `sendBequest`-shaped settlement (apprentice
/// won) and `sendStakeSettlement` (master won) callers must run first; ties
/// the two independently-built signed artifacts (match_outcome.dart,
/// graduation_pact.dart) together into a single go/no-go decision.
Future<GraduationVictor?> resolveGraduationSettlement({
  required SignedGraduationPact pact,
  required MatchOutcomeRecord outcome,
}) async {
  if (!_hexEq(outcome.outcome.pactIdHex, pact.pact.pactIdHex)) return null;
  if (!await pact.isFullyValid()) return null;
  if (!await outcome.isFullyValid()) return null;

  final victorHex = outcome.outcome.victorPubkeyHex;
  final loserHex = outcome.outcome.loserPubkeyHex;
  final isApprenticeVictor = _hexEq(victorHex, pact.pact.apprenticePubkeyHex);
  final isMasterVictor = _hexEq(victorHex, pact.pact.masterPubkeyHex);
  if (!isApprenticeVictor && !isMasterVictor) return null;
  final expectedLoserHex = isApprenticeVictor ? pact.pact.masterPubkeyHex : pact.pact.apprenticePubkeyHex;
  if (!_hexEq(loserHex, expectedLoserHex)) return null;

  return isApprenticeVictor ? GraduationVictor.apprentice : GraduationVictor.master;
}
