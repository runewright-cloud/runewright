// scripts/export_basic_spells.dart — exports the five authored "Basic *"
// starter spells from a source spell library into assets/basic_spells/, and
// (re)generates the const registry at lib/spells/basic_spells.dart from the
// same data.
//
// The five spells below are selected by spellHashHex (not by name — "starts
// with Basic" is a UI convention, not a stable selector for a build input).
// Each spell's `id` is rewritten from its original microsecond-timestamp id
// to a stable slug (basic_firebolt, etc.) — the id is a purely local
// filename/handle (see SpellAsset.save()), so rewriting it is safe, and a
// stable id is what makes a bundled ChapterEntry(spellId:) portable across
// installs and makes reseeding idempotent. createdAt is normalized to a
// fixed timestamp so re-running this script against an unchanged source
// library produces byte-identical output (no accidental diff noise from
// clock skew). Every other field — proofBytesBase64, ownerPubkeyHex,
// initialGrid, formula, supremeTags, artPackId — is copied through
// unchanged: these are real proofs and must not be re-derived or "cleaned
// up" here (CLAUDE.md invariant 1: never reimplement the circuit's crypto;
// this script only rewrites bookkeeping fields, never proof-adjacent ones).
//
// Run with: dart run scripts/export_basic_spells.dart [--source <dir>]
// Default --source is ~/Documents/spells (the Linux dev machine's app
// documents spells directory).
//
// docs/BASIC_SPELLS_PLAN.md §3 is the design source for this script.

import 'dart:convert';
import 'dart:io';

/// (selector spellHashHex, output slug) pairs, in the shipped display order.
/// spellHashHex is Poseidon2(commitment, T) — see SpellAsset.spellHashHex's
/// header comment — so it uniquely identifies a (grid, T) pair even across
/// re-inscription.
const List<(String, String)> _kSelection = [
  (
    '0x21f89f3db52e62cdd367c8831fc364cff8d8cec40898e44af0549957347bd7f4',
    'basic_firebolt',
  ),
  (
    '0x0e60aba776012bd996ddab4f9e6e313e01ee4a2b31fc3b85e2d969439a5ecffa',
    'basic_speedboost',
  ),
  (
    '0x1e9dabcfe2272e00ebfe2457443f177391c4afc9f218d593b2f8b047b222675a',
    'basic_manabond',
  ),
  (
    '0x00ce1c5cc294a79845004f0464ea13e2d4ed0554506fbe46e37ad00180bcec52',
    'basic_earthworks',
  ),
  (
    '0x1e053eb1afa520784b7c4acfec9c81c98d6b7a32e8aa6f45eab5b486c6172919',
    'basic_windhound',
  ),
];

/// Fixed so re-running this script against unchanged source data produces a
/// byte-identical bundle.
const String _kFixedCreatedAt = '2026-07-27T00:00:00.000000Z';

const int kBasicSpellSetVersion = 1;

String _defaultSourceDir() {
  final home = Platform.environment['HOME'];
  if (home == null) {
    throw StateError('HOME not set; pass --source explicitly');
  }
  return '$home/Documents/spells';
}

void main(List<String> args) {
  var sourceDir = _defaultSourceDir();
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--source' && i + 1 < args.length) {
      sourceDir = args[i + 1];
    }
  }

  final dir = Directory(sourceDir);
  if (!dir.existsSync()) {
    stderr.writeln('Source directory not found: $sourceDir');
    exit(1);
  }

  final bySpellHash = <String, Map<String, dynamic>>{};
  for (final entry in dir.listSync()) {
    if (entry is! File || !entry.path.endsWith('.json')) continue;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final hash = json['spellHashHex'] as String?;
    if (hash != null) bySpellHash[hash] = json;
  }

  final assetsDir = Directory('assets/basic_spells');
  assetsDir.createSync(recursive: true);

  final registryEntries = <String>[];

  for (final (spellHashHex, slug) in _kSelection) {
    final source = bySpellHash[spellHashHex];
    if (source == null) {
      stderr.writeln(
        'Could not find a spell with spellHashHex=$spellHashHex '
        'in $sourceDir — was it deleted or renamed?',
      );
      exit(1);
    }

    final rewritten = Map<String, dynamic>.from(source)
      ..['id'] = slug
      ..['createdAt'] = _kFixedCreatedAt;

    final outFile = File('${assetsDir.path}/$slug.json');
    outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(rewritten),
    );

    final name = rewritten['name'] as String;
    final commitmentHex = rewritten['commitmentHex'] as String;
    final t = rewritten['t'] as int;

    registryEntries.add(
      '  BasicSpellEntry(\n'
      '    slug: \'$slug\',\n'
      '    name: ${jsonEncode(name)},\n'
      '    commitmentHex: \'$commitmentHex\',\n'
      '    spellHashHex: \'$spellHashHex\',\n'
      '    t: $t,\n'
      '  ),',
    );

    stdout.writeln('Wrote ${outFile.path} ($name, T=$t)');
  }

  final registryFile = File('lib/spells/basic_spells.dart');
  registryFile.writeAsStringSync(_registrySource(registryEntries));
  stdout.writeln('Wrote ${registryFile.path}');
}

String _registrySource(List<String> entries) =>
    '''
// SPDX-License-Identifier: GPL-3.0-or-later
//
// basic_spells.dart — GENERATED by scripts/export_basic_spells.dart from the
// authored source library. Do not edit by hand — re-run the script instead
// (see its header and docs/BASIC_SPELLS_PLAN.md §3/§12).
//
// The registry of the five shipped starter spells (docs/BASIC_SPELLS_PLAN.md).
// [isBasicGridAndT] is the ONLY predicate safe to call at a peer-cast trust
// boundary: commitmentHex and t are both proof public inputs (see
// proof_intake.dart's VerifiedSpellOutputs), so checking against verified
// proof outputs never trusts anything the peer merely claims. Do not use
// spellHashHex there — it is a local, off-circuit derivation
// (Poseidon2(commitment, T) via FFI, see SpellAsset.spellHashHex's header)
// and is not itself a proof output.

import 'spell_asset.dart';

/// Bump when the shipped set of basic spells changes (add/remove/replace an
/// entry). Drives re-seeding on existing installs — see basic_spell_seed.dart.
const int kBasicSpellSetVersion = $kBasicSpellSetVersion;

class BasicSpellEntry {
  const BasicSpellEntry({
    required this.slug,
    required this.name,
    required this.commitmentHex,
    required this.spellHashHex,
    required this.t,
  });

  /// Stable identifier used as both the bundled asset's filename stem and
  /// the seeded SpellAsset.id — stable (unlike a microsecond timestamp) so a
  /// bundled ChapterEntry(spellId:) is portable across installs and so
  /// reseeding recognizes an already-persisted basic without relying on
  /// [spellHashHex] scans.
  final String slug;

  final String name;

  /// Poseidon2(packed_grid) — a proof public input (CIRCUIT_IO.md CIRCUIT_IO 4).
  final String commitmentHex;

  /// Poseidon2(commitment, T), computed off-circuit — used only for local
  /// dedup/display, never at a trust boundary (see header comment above).
  final String spellHashHex;

  /// Active generation count this spell's proof was generated with — a
  /// proof public input (proof_intake.dart ABI field [0]).
  final int t;

  String get assetPath => 'assets/basic_spells/\$slug.json';
}

const List<BasicSpellEntry> kBasicSpells = [
${entries.join('\n')}
];

String _normHex(String hex) {
  var s = hex.startsWith('0x') || hex.startsWith('0X') ? hex.substring(2) : hex;
  s = s.toLowerCase();
  if (s.length < 64) s = s.padLeft(64, '0');
  return s;
}

/// True iff (commitmentHex, t) matches one of the shipped basic spells.
///
/// This is the ONLY form of this check safe to call against a peer's cast:
/// both commitmentHex and t must come from VERIFIED proof public inputs
/// (proof_intake.dart's VerifiedSpellOutputs.commitmentHex / .t), never from
/// a wire-decoded SpellAsset, which a peer fully controls.
bool isBasicGridAndT(String commitmentHex, int t) {
  final normed = _normHex(commitmentHex);
  return kBasicSpells.any((e) => _normHex(e.commitmentHex) == normed && e.t == t);
}

/// Convenience for local, already-trusted SpellAssets (e.g. library/chapter
/// UI, where the asset came from this device's own disk, not the wire).
/// Cross-checks spellHashHex in addition to (commitment, T); a mismatch
/// means a corrupted or hand-edited asset, so it is treated as NOT basic.
bool isBasicSpell(SpellAsset spell) {
  if (!isBasicGridAndT(spell.commitmentHex, spell.t)) return false;
  final normed = _normHex(spell.spellHashHex);
  return kBasicSpells.any((e) => _normHex(e.spellHashHex) == normed);
}
''';
