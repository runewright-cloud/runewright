// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_asset_integrity_test.dart — the M4.22 content gate.
//
// `inscribeSpell` takes `formula`, `supremeTags` and `manaCost` as
// caller-supplied arguments and never checks them against the proof it has just
// generated, so main.dart's live UI `FormulaTracker` is persisted verbatim,
// stale or not. That is how `assets/basic_spells/basic_windhound.json` came to
// ship a 12-element authored trajectory over a proof attesting three
// (docs/M4_findings.md §M4.22).
//
// Engine v5 removes the gameplay consequence — a proof-backed cast is now
// resolved and priced from its own proof bytes on both devices. This file is
// the other half: it pins that the SHIPPED CONTENT is clean, and, just as
// importantly, that the audit which declares it clean can actually fail. A
// checker that passes everything is not a gate.
//
// Pairing every check with the negative vector that fails without it is the
// discipline CLAUDE.md §Working discipline asks for; §1 is the positive corpus
// and §2 is its negative.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, pow;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/engine/proof_outputs.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/spells/basic_spells.dart';
import 'package:rune_duel/spells/inscribe.dart'
    show kInscribeTiers, kMaxInscribableSteps, tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_asset_integrity.dart';

Map<String, dynamic> _rawBasic(String slug) =>
    jsonDecode(File('assets/basic_spells/$slug.json').readAsStringSync())
        as Map<String, dynamic>;

SpellAsset _basic(String slug) => SpellAsset.fromJson(_rawBasic(slug));

List<SpellSemanticMismatch> _audit(SpellAsset s) => auditSpellSemantics(
      proofBytes: s.proofBytes,
      t: s.t,
      declaredTier: s.tier,
      commitmentHex: s.commitmentHex,
      segmentCount: s.segmentCount,
      dotCount: s.dotCount,
      formula: s.formula,
      supremeTags: s.supremeTags,
      manaCost: s.manaCost,
    );

void main() {
  // ── 1. The shipped bundle is self-consistent ─────────────────────────────

  test('every shipped proof-backed basic spell agrees with its own proof', () {
    expect(kBasicSpells, isNotEmpty);
    for (final e in kBasicSpells) {
      final s = _basic(e.slug);
      expect(s.proofBytes, isNotEmpty,
          reason: '${e.slug}: a shipped basic must carry a real proof');
      expect(_audit(s), isEmpty,
          reason: '${e.slug}: authored metadata contradicts its own proof — '
              'run `dart run scripts/audit_spell_assets.dart`');
    }
  });

  test('the corrected Basic Windhound reads fire/water/water at 25 mana', () {
    // The exact case the two-device hardware gate failed on, pinned by value so
    // a regenerated bundle that quietly reverts it cannot pass.
    final s = _basic('basic_windhound');
    expect(s.formula, equals(['fire', 'water', 'water']));
    expect(s.supremeTags..sort(), equals(['fire', 'water']));
    expect(s.manaCost, equals(25));
    // Identity is untouched by the repair: same grid, same T, same proof.
    expect(s.t, equals(23));
    expect(
      s.commitmentHex,
      equals(
        '0x2d587d7e5de727d798b351845299c755fe65c95ef76b9bc0b52bc04aac506194',
      ),
    );
    expect(s.segmentCount, equals(0));
    expect(s.dotCount, equals(8));
  });

  // ── 2. The gate can fail — the negative vector ───────────────────────────

  test('the audit REPORTS the pre-fix Basic Windhound', () {
    // The real shipped proof bytes, with the authored fields exactly as they
    // were before the repair. Reconstructed rather than checked in as a second
    // 27 KB asset: what is under test is the audit, and the only thing that
    // made the old file bad was these three fields.
    final raw = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['manaCost'] = 83
      ..['formula'] = const [
        'air', 'water', 'earth', 'air', 'water', 'fire',
        'air', 'earth', 'water', 'fire', 'air', 'earth',
      ]
      ..['supremeTags'] = const ['air', 'earth'];

    final faults = auditSpellJson(raw);
    expect(faults.map((f) => f.field).toList()..sort(),
        equals(['formula', 'manaCost', 'supremeTags']));
    // None of them is an identity fault: the proof really is this grid's proof.
    // Only the prose had drifted, which is what made the repair legitimate.
    expect(faults.every((f) => !f.isIdentity), isTrue);
    expect(
      faults.firstWhere((f) => f.field == 'manaCost').toString(),
      contains('authored=83 derived=25'),
    );
  });

  test('the audit REPORTS a "Doggy"-shaped mismatch — a certified sequence '
      'that is a strict subsequence of the authored one', () {
    // The second inconsistent asset the library audit found (docs/M4_findings.md
    // §M4.22 "Library audit"). It is not a shipped asset, so its exact bytes
    // cannot be pinned here; its SHAPE can. Doggy over-committed activations —
    // 11 authored against 6 certified — and mispriced itself 70 against 31.
    // A checker that only noticed wholesale replacement would miss it.
    final raw = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['formula'] = const ['fire', 'water', 'water', 'earth', 'earth']
      ..['manaCost'] = 70;

    final faults = auditSpellJson(raw);
    expect(faults.map((f) => f.field).toList()..sort(),
        equals(['formula', 'manaCost']));
    expect(faults.firstWhere((f) => f.field == 'formula').toString(),
        contains('(5) derived=[fire, water, water] (3)'));
  });

  test('an identity mismatch is flagged as identity and refuses repair', () {
    // A proof that is not this asset's proof is not stale prose, and the repair
    // path must not paper over it by rewriting three fields around it.
    final raw = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['segmentCount'] = 99;

    final faults = auditSpellJson(raw);
    expect(faults.where((f) => f.isIdentity).map((f) => f.field),
        contains('segmentCount'));
    expect(() => repairSpellJson(raw), throwsA(isA<SpellSemanticsUnavailable>()));
  });

  test('a proofless spell audits clean rather than failing', () {
    // `kAllowProoflessSpells` Test Lab spells have nothing to derive from. That
    // is a legitimate state, not a defect — reporting it as one would make the
    // export gate unusable the moment the dev flag goes back on.
    final raw = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['proofBytesBase64'] = ''
      ..['formula'] = const ['air', 'air', 'air'];
    expect(auditSpellJson(raw), isEmpty);
    expect(
      deriveSpellSemantics(proofBytes: Uint8List(0), t: 6, declaredTier: 12),
      isNull,
    );
  });

  test('unparseable proof bytes throw rather than audit clean', () {
    final raw = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['proofBytesBase64'] = base64Encode(Uint8List.fromList([1, 2, 3, 4]));
    expect(() => auditSpellJson(raw), throwsA(isA<SpellSemanticsUnavailable>()));
  });

  // ── 3. The repair is lossless where it must be ───────────────────────────

  test('repairSpellJson rewrites exactly three fields', () {
    final before = Map<String, dynamic>.from(_rawBasic('basic_windhound'))
      ..['manaCost'] = 83
      ..['formula'] = const ['air', 'air', 'air']
      ..['supremeTags'] = const ['earth'];
    final after = repairSpellJson(before);

    final changed = after.keys
        .where((k) => jsonEncode(after[k]) != jsonEncode(before[k]))
        .toList()
      ..sort();
    expect(changed, equals(['formula', 'manaCost', 'supremeTags']));

    // Identity, the grid, the proof, and the summon declaration (M4.19 — NOT
    // this slice's business) all survive byte-for-byte.
    for (final k in const [
      'id', 't', 'tier', 'commitmentHex', 'spellHashHex', 'initialGrid',
      'proofBytesBase64', 'ownerPubkeyHex', 'segmentCount', 'dotCount',
      'isSummon', 'summonPersonality', 'name',
    ]) {
      expect(jsonEncode(after[k]), equals(jsonEncode(before[k])),
          reason: '$k must not be rewritten by a repair');
    }
    expect(auditSpellJson(after), isEmpty);
  });

  // ── 4. The three base-cost derivations are one number ────────────────────

  test('the audit, the verifier and the local mirror agree on the base price',
      () {
    // `DerivedSpellSemantics.manaCost` recomputes the base price rather than
    // calling `PeerCastVerifier.certifiedBaseManaCost`, because the verifier
    // lives behind Flutter imports the export script cannot load. That is a
    // deliberate second copy, and this is the test that keeps it honest.
    for (final e in kBasicSpells) {
      final s = _basic(e.slug);
      final outputs = parseProofOutputs(s.proofBytes, tierForSteps(s.t)!);
      final formulas = TrajectoryParser.parse(outputs).formulas;

      final derived = deriveSpellSemantics(
        proofBytes: s.proofBytes,
        t: s.t,
        declaredTier: s.tier,
      )!;
      final verifier =
          PeerCastVerifier.certifiedBaseManaCost(outputs, formulas);
      final byHand = ((5 * outputs.segmentCount + outputs.dotCount) *
              pow(1.05, outputs.t) *
              pow(1.5, max(0, formulas.length - 1)))
          .round();

      expect(derived.manaCost, equals(verifier), reason: e.slug);
      expect(derived.manaCost, equals(byHand), reason: e.slug);
      // And the shipped asset now stores that same number.
      expect(s.manaCost, equals(verifier), reason: e.slug);
    }
  });

  // ── 5. The duplicated tier table cannot drift ────────────────────────────

  test('tierForProof matches tierForSteps across the whole supported range',
      () {
    // `spell_asset_integrity.dart` keeps its own copy of the tier list because
    // it must stay importable from a plain `dart run` script. CLAUDE.md
    // invariant 6 is the rule; this is its enforcement.
    for (var t = 1; t <= kMaxInscribableSteps; t++) {
      expect(tierForProof(t, 12), equals(tierForSteps(t)), reason: 'T=$t');
    }
    expect(kInscribeTiers, equals([12, 24, 48]));
    // Outside the range, the declared tier is the documented fallback — the
    // same `tierForSpell(spell.t) ?? spell.tier` shape `certifyOwnProof` uses.
    expect(tierForProof(0, 24), equals(24));
    expect(tierForProof(kMaxInscribableSteps + 1, 48), equals(48));
  });
}
