// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_semantics_migration_test.dart — M4.22-F1, the on-device repair.
//
// The defect this covers is an UPGRADE defect, and the reason it survived
// M4.22 is that the whole existing test suite (and
// `scripts/audit_spell_assets.dart`) reads the BUNDLE, never device state. A
// corrected bundle is inert on an install that already seeded the spell,
// because `seedBasicSpells` skips per `spellHashHex` and a metadata-only
// repair changes neither the commitment nor T.
//
// So every test here starts by putting a stale asset on the fake device's
// disk and then asserts against what is on that disk afterwards. Asserting
// against the bundle would reproduce exactly the blind spot that let F1 ship.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rune_duel/spells/basic_spell_seed.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_semantics_migration.dart';

import 'fake_path_provider.dart';

/// The authored fields the pre-M4.22 `inscribeSpell` actually wrote for the
/// shipped Basic Windhound: a 12-element trajectory over a proof attesting
/// three, {air, earth} over a certified {fire, water}, and 83 mana against a
/// certified 25 (docs/M4_findings.md §M4.22).
const _staleFormula = <String>[
  'air', 'air', 'air', 'earth', 'earth', 'earth',
  'air', 'air', 'air', 'earth', 'earth', 'earth',
];
const _staleTags = <String>['air', 'earth'];
const _staleManaCost = 83;

Future<File> _spellFile(String id) async {
  final docs = await getApplicationDocumentsDirectory();
  return File('${docs.path}/spells/$id.json');
}

Future<Map<String, dynamic>> _readSpell(String id) async =>
    jsonDecode(await (await _spellFile(id)).readAsString())
        as Map<String, dynamic>;

Future<void> _writeSpell(String id, Map<String, dynamic> json) async =>
    (await _spellFile(id)).writeAsString(jsonEncode(json));

/// Puts the library back the way an install that seeded before M4.22 would
/// have it: the real proof, the stale prose.
Future<Map<String, dynamic>> _staleWindhound() async {
  final json = await _readSpell('basic_windhound');
  final stale = Map<String, dynamic>.from(json)
    ..['formula'] = _staleFormula
    ..['supremeTags'] = _staleTags
    ..['manaCost'] = _staleManaCost;
  await _writeSpell('basic_windhound', stale);
  return json; // the correct one, for comparison
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
    await seedBasicSpells();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // ── 1. The repair itself ─────────────────────────────────────────────────

  test('repairs an installed spell whose prose its own proof contradicts',
      () async {
    final correct = await _staleWindhound();

    final report = await migrateSpellSemantics();
    expect(report.skipped, isFalse);
    expect(report.repaired, 1);
    expect(report.refused, 0);

    final after = await _readSpell('basic_windhound');
    expect((after['formula'] as List).cast<String>(), correct['formula']);
    expect((after['supremeTags'] as List).cast<String>(), correct['supremeTags']);
    expect(after['manaCost'], correct['manaCost']);
  });

  test('a reseed cannot do this — the migration is the only thing that can',
      () async {
    await _staleWindhound();

    // Both existing levers, exactly as a player would reach them.
    await seedBasicSpells();
    await seedBasicSpells(force: true); // Library → "Restore basic spells"

    final after = await _readSpell('basic_windhound');
    expect(
      after['manaCost'],
      _staleManaCost,
      reason: 'if a reseed ever repairs this, F1 is fixed elsewhere and this '
          'migration may be redundant — re-read the findings before deleting it',
    );
  });

  test('rewrites only the three derivable fields', () async {
    final correct = await _staleWindhound();
    final before = await _readSpell('basic_windhound');

    await migrateSpellSemantics();
    final after = await _readSpell('basic_windhound');

    // Identity, the proof, the grid and the summon declaration are the
    // fields a repair must never launder.
    for (final key in const [
      'id',
      'spellHashHex',
      'commitmentHex',
      't',
      'tier',
      'proofBytesBase64',
      'segmentCount',
      'dotCount',
      'isSummon',
      'summonPersonality',
      'ownerPubkeyHex',
      'gridCellsBase64',
      'name',
      'createdAt',
    ]) {
      expect(
        jsonEncode(after[key]),
        jsonEncode(before[key]),
        reason: '$key must survive a repair untouched',
      );
    }

    // And the only keys whose values moved are the three derivable ones.
    final moved = after.keys
        .where((k) => jsonEncode(after[k]) != jsonEncode(before[k]))
        .toSet();
    expect(moved, {'formula', 'supremeTags', 'manaCost'});
    expect(after['formula'], correct['formula']);
  });

  test('an already-consistent library is left byte-identical', () async {
    final file = await _spellFile('basic_windhound');
    final before = await file.readAsString();

    final report = await migrateSpellSemantics();
    expect(report.repaired, 0);
    expect(report.refused, 0);
    expect(await file.readAsString(), before);
  });

  test('repairs an inscribed spell, not just a bundled basic', () async {
    // A spell the player inscribed while the write path was unchecked has the
    // same defect and no reseed reaches it at all.
    final json = await _readSpell('basic_windhound');
    final mine = Map<String, dynamic>.from(json)
      ..['id'] = 'my_own_spell'
      ..['name'] = 'Hand-Inscribed'
      ..['formula'] = _staleFormula
      ..['manaCost'] = _staleManaCost;
    await _writeSpell('my_own_spell', mine);

    final report = await migrateSpellSemantics();
    expect(report.repaired, 1);

    final after = await _readSpell('my_own_spell');
    expect(after['manaCost'], json['manaCost']);
    expect(after['name'], 'Hand-Inscribed');
  });

  // ── 2. What it must refuse ───────────────────────────────────────────────

  test('refuses an asset whose proof contradicts its IDENTITY', () async {
    // Not stale prose — the wrong proof. Rewriting the prose to match would
    // launder it into looking self-consistent.
    final json = await _readSpell('basic_windhound');
    final forged = Map<String, dynamic>.from(json)
      ..['commitmentHex'] =
          '0x00000000000000000000000000000000000000000000000000000000deadbeef'
      ..['manaCost'] = _staleManaCost;
    await _writeSpell('basic_windhound', forged);
    final before = await (await _spellFile('basic_windhound')).readAsString();

    final report = await migrateSpellSemantics();
    expect(report.refused, 1);
    expect(report.repaired, 0);
    expect(
      await (await _spellFile('basic_windhound')).readAsString(),
      before,
      reason: 'a refused asset must be left exactly as found',
    );
  });

  test('counts a proofless asset without touching it', () async {
    final json = await _readSpell('basic_windhound');
    await _writeSpell(
      'basic_windhound',
      Map<String, dynamic>.from(json)..['proofBytesBase64'] = '',
    );

    final report = await migrateSpellSemantics();
    expect(report.proofless, 1);
    expect(report.repaired, 0);
    expect(report.refused, 0);
  });

  test('one unreadable file does not abort the pass', () async {
    final docs = await getApplicationDocumentsDirectory();
    await File('${docs.path}/spells/garbage.json').writeAsString('{not json');
    await _staleWindhound();

    final report = await migrateSpellSemantics();
    expect(report.repaired, 1, reason: 'the rest of the library still migrated');

    final after = await _readSpell('basic_windhound');
    expect(after['manaCost'], isNot(_staleManaCost));
  });

  // ── 3. The version marker ────────────────────────────────────────────────

  test('a second launch is a no-op', () async {
    await migrateSpellSemantics();

    // Something re-staled the asset after the migration ran; the marker must
    // still gate, or every launch pays a full library audit.
    await _staleWindhound();
    final report = await migrateSpellSemantics();

    expect(report.skipped, isTrue);
    expect(report.repaired, 0);
    expect((await _readSpell('basic_windhound'))['manaCost'], _staleManaCost);
  });

  test('force re-runs regardless of the marker', () async {
    await migrateSpellSemantics();
    await _staleWindhound();

    final report = await migrateSpellSemantics(force: true);
    expect(report.skipped, isFalse);
    expect(report.repaired, 1);
    expect((await _readSpell('basic_windhound'))['manaCost'], isNot(_staleManaCost));
  });

  test('a completed pass records the current migration version', () async {
    final report = await migrateSpellSemantics();
    expect(report.skipped, isFalse);

    final docs = await getApplicationDocumentsDirectory();
    final marker = File('${docs.path}/spells/_semantics_migration.txt');
    expect(await marker.exists(), isTrue);
    expect((await marker.readAsString()).trim(),
        '$kSpellSemanticsMigrationVersion');
  });

  test('the marker file is not itself mistaken for a spell', () async {
    await migrateSpellSemantics(force: true);
    final all = await SpellAsset.loadAll();
    expect(all.length, 5);
  });
}
