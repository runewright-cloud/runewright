// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_outcome.dart — the signed, mutually-agreed record of who won a
// battle. Nothing in the codebase produced this before
// docs/MASTER_APPRENTICE_PLAN.md §4: TurnLoop.runTurn already computes a
// WinCheckResult (battle_state.dart) but nothing signs or persists it, and
// BattleSession.sendMatchEnd has no callers. Ownership-moving actions (a
// graduation-battle settlement) must never trust a one-sided claim of
// victory — this is the two-signature record that closes that gap.
//
// Canonical message discipline mirrors spell_permission.dart: null-byte
// delimited, hex lowercased, every field that matters folded into the
// signed bytes so tampering the JSON on disk breaks verification.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../identity/identity.dart';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

/// Sentinel [MatchOutcome.pactIdHex] for an ordinary (non-graduation) duel —
/// see docs/MASTER_APPRENTICE_PLAN.md §7.2 for the graduation-pact case.
const String kNoGraduationPact = 'none';

/// The agreed facts of how a match ended. Both players independently arrive
/// at byte-identical field values *before* either signs — no round trip is
/// needed to agree on them first, because every field is a pure function of
/// state the per-turn lockstep (`BattleSession.exchangeStateHash`) already
/// guarantees is identical on both devices. In particular [endedAtTurn] is
/// `state.turnNumber` at the moment `checkWinCondition()` returned
/// `isOver`, NOT a wall-clock timestamp — using a shared, already-agreed
/// integer instead of `DateTime.now()` is what lets [BattleSession
/// .exchangeMatchOutcome] be a single simultaneous exchange (like every
/// other per-turn exchange) rather than needing a host-proposes/guest-
/// adopts handshake.
class MatchOutcome {
  const MatchOutcome({
    required this.matchIdHex,
    required this.victorPubkeyHex,
    required this.loserPubkeyHex,
    required this.finalStateHashHex,
    this.pactIdHex = kNoGraduationPact,
    required this.endedAtTurn,
  });

  /// The jointly-derived matchId from `runDuelSetup` (hex) — neither side
  /// unilaterally controls it (see `BattleSession.exchangeMatchIdNonce`).
  final String matchIdHex;

  /// Poseidon2(key_hi, key_lo) of the winning player, as authenticated by
  /// `exchangeIdentityAuth` — never an unverified proof-declared value.
  final String victorPubkeyHex;
  final String loserPubkeyHex;

  /// The last agreed per-turn state hash (`BattleSession.exchangeStateHash`)
  /// — binds this outcome to a specific, lockstep-verified game state.
  final String finalStateHashHex;

  /// docs/MASTER_APPRENTICE_PLAN.md §7.2's GraduationPact id when this
  /// outcome settles a graduation battle; [kNoGraduationPact] otherwise.
  final String pactIdHex;

  /// `BattleState.turnNumber` when the win condition fired — see this
  /// class's doc comment for why this replaces a wall-clock timestamp.
  final int endedAtTurn;

  List<int> get canonicalMessage => _buildMessage(
        matchIdHex: matchIdHex,
        victorPubkeyHex: victorPubkeyHex,
        loserPubkeyHex: loserPubkeyHex,
        finalStateHashHex: finalStateHashHex,
        pactIdHex: pactIdHex,
        endedAtTurn: endedAtTurn,
      );

  static List<int> _buildMessage({
    required String matchIdHex,
    required String victorPubkeyHex,
    required String loserPubkeyHex,
    required String finalStateHashHex,
    required String pactIdHex,
    required int endedAtTurn,
  }) =>
      [
        ...utf8.encode('RUNEWRIGHT_MATCH_OUTCOME_V1\x00'),
        ...utf8.encode(matchIdHex.toLowerCase()),
        0,
        ...utf8.encode(victorPubkeyHex.toLowerCase()),
        0,
        ...utf8.encode(loserPubkeyHex.toLowerCase()),
        0,
        ...utf8.encode(finalStateHashHex.toLowerCase()),
        0,
        ...utf8.encode(pactIdHex.toLowerCase()),
        0,
        ...utf8.encode(endedAtTurn.toString()),
      ];

  /// True iff every field matches [other] — hex fields case-insensitively.
  /// This is what a caller should check before trusting a peer's returned
  /// [SignedMatchOutcome] in [BattleSession.exchangeMatchOutcome]: agreement
  /// on identical bytes is what makes the two independent signatures mean
  /// the same thing.
  bool sameFieldsAs(MatchOutcome other) =>
      _hexEq(matchIdHex, other.matchIdHex) &&
      _hexEq(victorPubkeyHex, other.victorPubkeyHex) &&
      _hexEq(loserPubkeyHex, other.loserPubkeyHex) &&
      _hexEq(finalStateHashHex, other.finalStateHashHex) &&
      pactIdHex.toLowerCase() == other.pactIdHex.toLowerCase() &&
      endedAtTurn == other.endedAtTurn;

  Map<String, dynamic> toJson() => {
        'matchIdHex': matchIdHex,
        'victorPubkeyHex': victorPubkeyHex,
        'loserPubkeyHex': loserPubkeyHex,
        'finalStateHashHex': finalStateHashHex,
        'pactIdHex': pactIdHex,
        'endedAtTurn': endedAtTurn,
      };

  static MatchOutcome fromJson(Map<String, dynamic> json) => MatchOutcome(
        matchIdHex: json['matchIdHex'] as String,
        victorPubkeyHex: json['victorPubkeyHex'] as String,
        loserPubkeyHex: json['loserPubkeyHex'] as String,
        finalStateHashHex: json['finalStateHashHex'] as String,
        pactIdHex: json['pactIdHex'] as String? ?? kNoGraduationPact,
        endedAtTurn: json['endedAtTurn'] as int,
      );
}

/// One side's Ed25519 signature over [outcome]'s canonical message, plus the
/// raw public key needed to verify it without prior key exchange — same
/// self-contained shape as `SpellPermission`'s owner binding.
class SignedMatchOutcome {
  const SignedMatchOutcome({
    required this.outcome,
    required this.signerPubkeyHex,
    required this.rawPubkeyBase64,
    required this.signatureBase64,
  });

  final MatchOutcome outcome;

  /// Poseidon2 owner_pubkey of whoever produced [signatureBase64] — must be
  /// one of [outcome]'s `victorPubkeyHex` / `loserPubkeyHex` for this to mean
  /// anything (checked by [MatchOutcomeRecord.isFullyValid], not here).
  final String signerPubkeyHex;
  final String rawPubkeyBase64;
  final String signatureBase64;

  static Future<SignedMatchOutcome> sign({
    required MatchOutcome outcome,
    required Identity signerIdentity,
  }) async {
    final signerPubkeyHex = await signerIdentity.ownerPubkeyHex();
    final sigBytes = await signerIdentity.sign(outcome.canonicalMessage);
    return SignedMatchOutcome(
      outcome: outcome,
      signerPubkeyHex: signerPubkeyHex,
      rawPubkeyBase64: base64Encode(signerIdentity.publicKeyBytes),
      signatureBase64: base64Encode(sigBytes),
    );
  }

  /// True iff [rawPubkeyBase64] genuinely binds to [signerPubkeyHex] AND the
  /// Ed25519 signature over `outcome.canonicalMessage` verifies. Does NOT
  /// check that [signerPubkeyHex] is actually one of the outcome's two named
  /// parties, nor that the two sides of a pair disagree — see
  /// [MatchOutcomeRecord.isFullyValid] for the combined check callers must use
  /// before trusting a settlement.
  Future<bool> isSignatureValid() async {
    final rawPubKey = base64Decode(rawPubkeyBase64);
    final pubkeyMatches = await Identity.ownerPubkeyMatches(
      presentedPubkeyBytes: rawPubKey,
      claimedOwnerPubkeyHex: signerPubkeyHex,
    );
    if (!pubkeyMatches) return false;
    return Identity.verify(
      message: outcome.canonicalMessage,
      signatureBytes: base64Decode(signatureBase64),
      publicKeyBytes: rawPubKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'outcome': outcome.toJson(),
        'signerPubkeyHex': signerPubkeyHex,
        'rawPubkeyBase64': rawPubkeyBase64,
        'signatureBase64': signatureBase64,
      };

  static SignedMatchOutcome fromJson(Map<String, dynamic> json) => SignedMatchOutcome(
        outcome: MatchOutcome.fromJson(json['outcome'] as Map<String, dynamic>),
        signerPubkeyHex: json['signerPubkeyHex'] as String,
        rawPubkeyBase64: json['rawPubkeyBase64'] as String,
        signatureBase64: json['signatureBase64'] as String,
      );
}

/// The durable, portable artifact: both sides' signatures over an agreed
/// [MatchOutcome]. Persisted file-per-record like `SpellPermission`/
/// `SpellAsset`. This is what a future graduation-battle settlement
/// (MASTER_APPRENTICE_PLAN.md §7.4) and any future ELO/match-history feature
/// both consume.
class MatchOutcomeRecord {
  const MatchOutcomeRecord({required this.outcome, required this.mine, required this.theirs});

  final MatchOutcome outcome;
  final SignedMatchOutcome mine;
  final SignedMatchOutcome theirs;

  /// True iff both signatures verify, both name a party in [outcome], and
  /// name DIFFERENT parties (one victor signature, one loser signature) —
  /// two copies of the same side's signature must never count as agreement.
  Future<bool> isFullyValid() async {
    if (!await mine.isSignatureValid()) return false;
    if (!await theirs.isSignatureValid()) return false;
    final parties = {
      outcome.victorPubkeyHex.toLowerCase(),
      outcome.loserPubkeyHex.toLowerCase(),
    };
    if (!parties.contains(mine.signerPubkeyHex.toLowerCase())) return false;
    if (!parties.contains(theirs.signerPubkeyHex.toLowerCase())) return false;
    if (_hexEq(mine.signerPubkeyHex, theirs.signerPubkeyHex)) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'outcome': outcome.toJson(),
        'mine': mine.toJson(),
        'theirs': theirs.toJson(),
      };

  static MatchOutcomeRecord fromJson(Map<String, dynamic> json) => MatchOutcomeRecord(
        outcome: MatchOutcome.fromJson(json['outcome'] as Map<String, dynamic>),
        mine: SignedMatchOutcome.fromJson(json['mine'] as Map<String, dynamic>),
        theirs: SignedMatchOutcome.fromJson(json['theirs'] as Map<String, dynamic>),
      );

  static Future<Directory> _outcomesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/outcomes');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> save() async {
    final dir = await _outcomesDir();
    final file = File('${dir.path}/${outcome.matchIdHex}.json');
    await file.writeAsString(jsonEncode(toJson()));
    return file;
  }

  static Future<MatchOutcomeRecord?> loadByMatchId(String matchIdHex) async {
    final dir = await _outcomesDir();
    final file = File('${dir.path}/$matchIdHex.json');
    if (!await file.exists()) return null;
    return fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  static Future<List<MatchOutcomeRecord>> loadAll() async {
    final dir = await _outcomesDir();
    final entries = await dir.list().where((e) => e.path.endsWith('.json')).toList();
    final records = <MatchOutcomeRecord>[];
    for (final entry in entries) {
      final contents = await File(entry.path).readAsString();
      records.add(fromJson(jsonDecode(contents) as Map<String, dynamic>));
    }
    return records;
  }
}
