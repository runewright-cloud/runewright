// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_asset_integrity.dart — does a persisted spell's authored metadata
// agree with its own proof?
//
// ## Why this exists (M4.22)
//
// `inscribeSpell` takes `formula`, `supremeTags` and `manaCost` as
// CALLER-SUPPLIED arguments and never checks them against the proof it has
// just generated and self-verified. main.dart passes the live UI
// `FormulaTracker`, so a stale tracker is persisted verbatim and ships. That
// is how `assets/basic_spells/basic_windhound.json` came to claim a 12-element
// trajectory for a proof that attests three (docs/M4_findings.md §M4.22).
//
// Those three fields are pure presentation *if* they agree with the proof, and
// a lockstep hazard the moment they do not: a peer derives the same facts from
// the verified public outputs, so an asset that lies about itself makes the two
// devices resolve one cast two ways. Engine v5 removes the gameplay
// consequence by resolving a local cast from its own proof bytes too; this file
// is the other half — the one that stops bad content being minted and shipped.
//
// ## Where it is used
//
//   * `scripts/export_basic_spells.dart` — refuses to export a mismatched
//     asset, so no future regeneration can ship one again.
//   * `test/spells/spell_asset_integrity_test.dart` — pins that every shipped
//     proof-backed basic is clean, and that the pre-fix Windhound was not.
//   * `scripts/audit_spell_assets.dart` — audits (and optionally repairs) a
//     whole on-device library.
//
// ## Deliberately Flutter-free
//
// Takes primitives rather than a [SpellAsset] because `SpellAsset` reaches
// `path_provider` and therefore `dart:ui`, and `dart run` cannot load that —
// the exporter is a plain `dart:io` script and must stay one. Callers holding
// a real asset unpack its fields; callers holding raw JSON use
// [auditSpellJson].
//
// ## What it does NOT check
//
// `isSummon` and `summonPersonality` are authored and unbound under the
// current epoch — that is M4.19, a separate defect with a separate fix, and
// deriving them here would quietly pre-empt it. Nothing in this file reads
// them. The grid, `t`, the commitment and the proof bytes are the asset's
// IDENTITY: they are compared, never rewritten.

import 'dart:convert' show base64Decode;
import 'dart:math' show max, pow;
import 'dart:typed_data';

import '../battle/engine/proof_outputs.dart';
import '../battle/engine/trajectory_parser.dart' show TrajectoryParser;

/// The three circuit tiers, smallest first — CLAUDE.md hard invariant 6.
///
/// A deliberate second copy of `kInscribeTiers` (lib/spells/inscribe.dart),
/// which cannot be imported here without dragging in Flutter. The duplication
/// is paired with an enforcing test the way this repo pairs every constraint
/// with its negative vector: `spell_asset_integrity_test.dart` asserts
/// [tierForProof] agrees with `tierForSteps` for every T in 1..48. If you
/// change the tier set, that test fails until both copies move.
const List<int> _kTiers = [12, 24, 48];

/// The tier a proof for [t] generations was generated at — the smallest tier
/// covering it, exactly as `inscribeSpell` chose at proving time and as
/// `PeerCastVerifier.certifyOwnProof` re-derives it.
///
/// Falls back to [declaredTier] for a T outside the supported range, matching
/// `certifyOwnProof`'s `tierForSpell(spell.t) ?? spell.tier`. Getting this
/// wrong is not a soft failure: the public-input count is `10 + 2*tier_max`, so
/// the trajectory arrays are read at the wrong offsets and every derived field
/// is garbage.
int tierForProof(int t, int declaredTier) {
  if (t >= 1) {
    for (final tier in _kTiers) {
      if (t <= tier) return tier;
    }
  }
  return declaredTier;
}

/// The semantics an asset's own proof bytes attest, in the shape the asset
/// stores them.
///
/// Every field is a pure function of the proof's public outputs, derived by the
/// same code the peer's verifier runs — [TrajectoryParser] over [parseProofOutputs]
/// outputs. That is what makes a comparison against the authored fields
/// meaningful rather than circular.
class DerivedSpellSemantics {
  const DerivedSpellSemantics({
    required this.formula,
    required this.supremeTags,
    required this.manaCost,
    required this.segmentCount,
    required this.dotCount,
    required this.t,
    required this.commitmentHex,
  });

  /// Certified analog of `SpellAsset.formula`: the full flat committed
  /// activation sequence, residuals included, as lowercase zone names — the
  /// same list `TrajectoryParser.certifiedElementSequence` hands resolution.
  final List<String> formula;

  /// Certified analog of `SpellAsset.supremeTags`, lowercase and SORTED, so a
  /// comparison is order-insensitive by construction (the authored field is
  /// written from a `Set`).
  final List<String> supremeTags;

  /// Certified analog of `SpellAsset.manaCost`: `5×segmentCount + dotCount`
  /// grown by `1.05^T × 1.5^effectCount`, effectCount being one less than the
  /// number of COMPLETE formulas.
  ///
  /// The same three operations in the same order as
  /// `PeerCastVerifier.certifiedBaseManaCost` and
  /// `DeterministicResolution.wireBaseManaCost` — recomputed here rather than
  /// called because both of those live behind Flutter imports. The integrity
  /// test pins that all three agree on every shipped asset.
  final int manaCost;

  /// Identity fields, for comparison only. Never rewritten by a repair.
  final int segmentCount;
  final int dotCount;
  final int t;
  final String commitmentHex;
}

/// One authored field that disagrees with the proof.
class SpellSemanticMismatch {
  const SpellSemanticMismatch({
    required this.field,
    required this.authored,
    required this.derived,
    this.isIdentity = false,
  });

  /// `formula`, `supremeTags`, `manaCost`, or one of the identity fields.
  final String field;
  final String authored;
  final String derived;

  /// True for `t` / `commitmentHex` / `segmentCount` / `dotCount` — fields a
  /// repair must NOT rewrite. An identity mismatch means the proof does not
  /// belong to this asset at all, which is a different and worse problem than
  /// stale prose; a caller should stop rather than "fix" it.
  final bool isIdentity;

  @override
  String toString() => '$field: authored=$authored derived=$derived'
      '${isIdentity ? ' [IDENTITY — do not rewrite]' : ''}';
}

/// Proof bytes were present but could not be parsed — a real defect, unlike a
/// spell with no proof at all.
class SpellSemanticsUnavailable implements Exception {
  SpellSemanticsUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'SpellSemanticsUnavailable: $reason';
}

/// Re-derive a spell's semantics from its own proof bytes.
///
/// Returns null when [proofBytes] is empty — a `kAllowProoflessSpells` Test Lab
/// spell has nothing to derive from, and that is a legitimate state, not a
/// defect. Throws [SpellSemanticsUnavailable] when bytes are present but do not
/// parse, because that one IS a defect.
DerivedSpellSemantics? deriveSpellSemantics({
  required Uint8List proofBytes,
  required int t,
  required int declaredTier,
}) {
  if (proofBytes.isEmpty) return null;
  final tier = tierForProof(t, declaredTier);
  final VerifiedSpellOutputs outputs;
  try {
    outputs = parseProofOutputs(proofBytes, tier);
  } on ProofIntakeException catch (e) {
    throw SpellSemanticsUnavailable(
      'proof bytes do not parse at tier $tier: $e',
    );
  }

  final formulas = TrajectoryParser.parse(outputs).formulas;
  final base = 5 * outputs.segmentCount + outputs.dotCount;
  final effectCount = max(0, formulas.length - 1);

  return DerivedSpellSemantics(
    formula: TrajectoryParser.certifiedElementSequence(outputs)
        .map((z) => z.name)
        .toList(growable: false),
    supremeTags: TrajectoryParser.certifiedSupremeTags(outputs).toList()..sort(),
    manaCost: (base * pow(1.05, outputs.t) * pow(1.5, effectCount)).round(),
    segmentCount: outputs.segmentCount,
    dotCount: outputs.dotCount,
    t: outputs.t,
    commitmentHex: outputs.commitmentHex,
  );
}

/// Every authored field that this spell's own proof contradicts.
///
/// Empty means the spell is self-consistent: a peer deriving its semantics from
/// the verified proof gets exactly what this device already has stored. A
/// proofless spell audits clean — there is nothing to compare against.
List<SpellSemanticMismatch> auditSpellSemantics({
  required Uint8List proofBytes,
  required int t,
  required int declaredTier,
  required String commitmentHex,
  required int segmentCount,
  required int dotCount,
  required List<String> formula,
  required List<String> supremeTags,
  required int manaCost,
}) {
  final derived = deriveSpellSemantics(
    proofBytes: proofBytes,
    t: t,
    declaredTier: declaredTier,
  );
  if (derived == null) return const [];

  final out = <SpellSemanticMismatch>[];

  void identity(String field, Object authored, Object expected) {
    if (authored.toString() != expected.toString()) {
      out.add(SpellSemanticMismatch(
        field: field,
        authored: authored.toString(),
        derived: expected.toString(),
        isIdentity: true,
      ));
    }
  }

  // Identity first: if this is not this grid's proof, nothing below means
  // anything.
  identity('t', t, derived.t);
  identity('commitmentHex', normHex(commitmentHex), normHex(derived.commitmentHex));
  identity('segmentCount', segmentCount, derived.segmentCount);
  identity('dotCount', dotCount, derived.dotCount);

  final authoredFormula =
      formula.map((e) => e.toLowerCase()).toList(growable: false);
  if (!_listEq(authoredFormula, derived.formula)) {
    out.add(SpellSemanticMismatch(
      field: 'formula',
      authored: '[${authoredFormula.join(", ")}] (${authoredFormula.length})',
      derived: '[${derived.formula.join(", ")}] (${derived.formula.length})',
    ));
  }

  // Set comparison: the authored field is written from a `Set`, so its order
  // carries no meaning and must not be reported as a mismatch.
  final authoredTags =
      supremeTags.map((e) => e.toLowerCase()).toSet().toList()..sort();
  if (!_listEq(authoredTags, derived.supremeTags)) {
    out.add(SpellSemanticMismatch(
      field: 'supremeTags',
      authored: '{${authoredTags.join(", ")}}',
      derived: '{${derived.supremeTags.join(", ")}}',
    ));
  }

  if (manaCost != derived.manaCost) {
    out.add(SpellSemanticMismatch(
      field: 'manaCost',
      authored: '$manaCost',
      derived: '${derived.manaCost}',
    ));
  }

  return out;
}

/// [auditSpellSemantics] over a decoded `SpellAsset.toJson()` map.
///
/// For callers that have the JSON but cannot construct a [SpellAsset] — the
/// exporter script, which must run under plain `dart run`.
List<SpellSemanticMismatch> auditSpellJson(Map<String, dynamic> json) =>
    auditSpellSemantics(
      proofBytes: base64Decode(json['proofBytesBase64'] as String? ?? ''),
      t: json['t'] as int,
      declaredTier: json['tier'] as int,
      commitmentHex: (json['commitmentHex'] as String?) ?? '',
      segmentCount: (json['segmentCount'] as int?) ?? -1,
      dotCount: (json['dotCount'] as int?) ?? -1,
      formula: (json['formula'] as List<dynamic>? ?? const []).cast<String>(),
      supremeTags:
          (json['supremeTags'] as List<dynamic>? ?? const []).cast<String>(),
      manaCost: json['manaCost'] as int,
    );

/// Rewrite the three derivable fields of a decoded asset map from its own
/// proof, leaving grid, `t`, commitment, proof bytes, spell identity and the
/// summon declaration untouched.
///
/// Throws [SpellSemanticsUnavailable] if the proof is missing, unparseable, or
/// disagrees with the asset's IDENTITY — a repair may correct stale prose, but
/// an asset carrying someone else's proof is not something to paper over.
Map<String, dynamic> repairSpellJson(Map<String, dynamic> json) {
  final derived = deriveSpellSemantics(
    proofBytes: base64Decode(json['proofBytesBase64'] as String? ?? ''),
    t: json['t'] as int,
    declaredTier: json['tier'] as int,
  );
  if (derived == null) {
    throw SpellSemanticsUnavailable('no proof bytes to re-derive from');
  }
  final identityFaults =
      auditSpellJson(json).where((m) => m.isIdentity).toList();
  if (identityFaults.isNotEmpty) {
    throw SpellSemanticsUnavailable(
      'refusing to repair: proof does not match this asset '
      '(${identityFaults.join("; ")})',
    );
  }
  return Map<String, dynamic>.from(json)
    ..['formula'] = derived.formula
    ..['supremeTags'] = derived.supremeTags
    ..['manaCost'] = derived.manaCost;
}

/// Zero-padded, lowercase, `0x`-less form of a field-element hex string.
String normHex(String hex) {
  var s = hex.startsWith('0x') || hex.startsWith('0X') ? hex.substring(2) : hex;
  s = s.toLowerCase();
  if (s.length < 64) s = s.padLeft(64, '0');
  return s;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
