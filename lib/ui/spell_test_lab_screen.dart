// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_test_lab_screen.dart — temporary testing mechanic for spell effects.
//
// Lets you combine any of the 64 (affinity × effect kind) formula triplets
// into a zero-mana, unproven "[TEST] " spell — no CA run, no circuit, no
// proof — saved as a normal SpellAsset so it shows up in the Library and can
// be added to any chapter through the existing UI. From here you can also
// launch a Test Battle whose dummy opponent casts a Firey Blast at a fixed
// tile every turn (see SoloBattleSession.dummyAutoCast), so you can walk a
// custom spell's effects into an incoming hit. Both are test-only: regular
// Solo Practice and the regular spell library are untouched.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../battle/models/effect_kind.dart';
import '../battle/models/match_config.dart';
import '../battle/models/solo_battle_setup.dart';
import '../battle/networking/solo_battle_session.dart';
import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import 'battle_screen.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

/// Prefix marking a spell as fabricated by this screen (zero cost, unproven).
const String kTestSpellNamePrefix = '[TEST] ';

/// Inverse of effectKindFromPair — the ordered (type1, type2) zone pair that
/// selects each EffectKind, mirroring the comments in effect_kind.dart.
const Map<EffectKind, (BorderZone, BorderZone)> _kEffectKindZones = {
  EffectKind.damage: (BorderZone.fire, BorderZone.fire),
  EffectKind.barrier: (BorderZone.earth, BorderZone.earth),
  EffectKind.reflections: (BorderZone.water, BorderZone.water),
  EffectKind.speedManipulation: (BorderZone.air, BorderZone.air),
  EffectKind.statusEffectInteraction: (BorderZone.fire, BorderZone.earth),
  EffectKind.chainInteraction: (BorderZone.fire, BorderZone.water),
  EffectKind.spellInteraction: (BorderZone.fire, BorderZone.air),
  EffectKind.fuelTransmutation: (BorderZone.earth, BorderZone.fire),
  EffectKind.tileModification: (BorderZone.earth, BorderZone.water),
  EffectKind.rangeModification: (BorderZone.earth, BorderZone.air),
  EffectKind.clouds: (BorderZone.water, BorderZone.fire),
  EffectKind.artifactsInteraction: (BorderZone.water, BorderZone.earth),
  EffectKind.illusions: (BorderZone.water, BorderZone.air),
  EffectKind.multiplierCycles: (BorderZone.air, BorderZone.fire),
  EffectKind.haymakerInteraction: (BorderZone.air, BorderZone.earth),
  EffectKind.divination: (BorderZone.air, BorderZone.water),
};

class _EffectSlot {
  _EffectSlot({this.kind = EffectKind.damage}) : affinity = SpellAffinity.fire;
  SpellAffinity affinity;
  EffectKind kind;
}

List<String> _formulaFor(List<_EffectSlot> slots) {
  final formula = <String>[];
  for (final s in slots) {
    final (z1, z2) = _kEffectKindZones[s.kind]!;
    formula.addAll([s.affinity.name, z1.name, z2.name]);
  }
  return formula;
}

class SpellTestLabScreen extends StatefulWidget {
  const SpellTestLabScreen({super.key});

  @override
  State<SpellTestLabScreen> createState() => _SpellTestLabScreenState();
}

class _SpellTestLabScreenState extends State<SpellTestLabScreen> {
  final _nameController = TextEditingController();
  final List<_EffectSlot> _slots = [_EffectSlot()];
  List<SpellAsset> _testSpells = [];
  bool _loadingSpells = true;

  List<ChapterAsset> _chapters = [];
  ChapterAsset? _selectedChapter;
  bool _loadingChapters = true;

  int _hp = 24;
  int _gridRadius = 4;
  static const _hpMin = 8;
  static const _hpMax = 48;
  static const _hpStep = 4;
  static const _gridRadiusMin = 2;
  static const _gridRadiusMax = 6;

  @override
  void initState() {
    super.initState();
    _reloadTestSpells();
    _loadChapters();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _reloadTestSpells() async {
    final all = await SpellAsset.loadAll();
    if (!mounted) return;
    setState(() {
      _testSpells = all
          .where((s) => s.name.startsWith(kTestSpellNamePrefix))
          .toList();
      _loadingSpells = false;
    });
  }

  Future<void> _loadChapters() async {
    final chapters = await ChapterAsset.loadAll();
    final activeId = await ChapterAsset.loadActiveChapterId();
    if (!mounted) return;
    ChapterAsset? active;
    if (activeId != null) {
      final matches = chapters.where((c) => c.id == activeId);
      if (matches.isNotEmpty) active = matches.first;
    }
    active ??= chapters.length == 1 ? chapters[0] : null;
    setState(() {
      _chapters = chapters;
      _selectedChapter = active;
      _loadingChapters = false;
    });
  }

  // ── Spell builder ────────────────────────────────────────────────────────

  void _addSlot() => setState(() => _slots.add(_EffectSlot()));

  void _removeSlot(int i) => setState(() => _slots.removeAt(i));

  /// Builds and persists a zero-cost, unproven test [SpellAsset] with the
  /// given [id]/[name]/[formula]. Shared by the manual builder and
  /// [_seedOneSpellPerEffect]. [t] defaults to two generations per formula
  /// triplet, matching the manual builder's convention.
  Future<void> _persistTestSpell({
    required String id,
    required String name,
    required List<String> formula,
    int? t,
  }) async {
    // Not a real Poseidon2 grid commitment (CLAUDE.md invariant 1 forbids
    // reimplementing that) — just an opaque, display/dedup-only placeholder
    // key, since this spell never runs through the circuit.
    final commitmentHex =
        '0x${sha256.convert(utf8.encode('test-spell|$id|${formula.join(",")}')).toString()}';
    final spellHashHex =
        '0x${sha256.convert(utf8.encode('$commitmentHex|$id')).toString()}';

    final spell = SpellAsset(
      id: id,
      createdAt: DateTime.now(),
      tier: 12,
      t: (t ?? (formula.length ~/ 3) * 2).clamp(1, 12),
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0),
      proofBytes: Uint8List(0),
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: spellHashHex,
      formula: formula,
    );
    await spell.save();
  }

  Future<void> _saveTestSpell() async {
    if (_slots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one effect first.')),
      );
      return;
    }
    final rawName = _nameController.text.trim();
    final name =
        '$kTestSpellNamePrefix${rawName.isEmpty ? 'Untitled' : rawName}';
    await _persistTestSpell(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      formula: _formulaFor(_slots),
    );
    if (!mounted) return;
    setState(() {
      _nameController.clear();
      _slots
        ..clear()
        ..add(_EffectSlot());
    });
    await _reloadTestSpells();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$name" — add it to a chapter in the Library.'),
      ),
    );
  }

  /// Fixed, deterministic id per (affinity, effect kind) pairing — makes
  /// reseeding idempotent (skips pairings already seeded) instead of piling
  /// up duplicates.
  String _seedIdFor(SpellAffinity affinity, EffectKind kind) =>
      'testlab_seed_${affinity.name}_${kind.name}';

  /// Seeds one isolated test spell per (affinity × effect kind) pairing — all
  /// 4 × 16 = 64 of them — each a single-triplet formula using that effect's
  /// own zone pair with the given affinity substituted in, named
  /// `"$Affinity $Effect"`. Skips any pairing that's already been seeded (or
  /// manually recreated under the same id).
  Future<void> _seedAllElementEffectPairings() async {
    final all = await SpellAsset.loadAll();
    final existingIds = all.map((s) => s.id).toSet();
    var seeded = 0;
    for (final affinity in SpellAffinity.values) {
      for (final kind in EffectKind.values) {
        final id = _seedIdFor(affinity, kind);
        if (existingIds.contains(id)) continue;
        final (z1, z2) = _kEffectKindZones[kind]!;
        await _persistTestSpell(
          id: id,
          name:
              '$kTestSpellNamePrefix${kAffinityLabel[affinity]} ${kEffectKindLabel[kind]}',
          formula: [affinity.name, z1.name, z2.name],
        );
        seeded++;
      }
    }
    if (!mounted) return;
    await _reloadTestSpells();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          seeded == 0
              ? 'All 64 element × effect test spells already exist.'
              : 'Seeded $seeded test spell${seeded == 1 ? '' : 's'} — every element × effect pairing.',
        ),
      ),
    );
  }

  Future<void> _deleteTestSpell(SpellAsset spell) async {
    await spell.delete();
    await _reloadTestSpells();
  }

  // ── Test battle ──────────────────────────────────────────────────────────

  void _beginTestBattle() {
    final chapter = _selectedChapter;
    if (chapter == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No Chapter Selected')));
      return;
    }
    const localId = 'local';
    final config = MatchConfig(
      playerHp: _hp,
      gridRadius: _gridRadius,
      maxPlayers: 2,
    );
    final setup = buildSoloBattleState(chapter, config, localId: localId);
    final dummyPos = setup.dummyPosition;
    // "Two squares south" — south is +r at constant q on this hex layout
    // (battlefield_painter's axialToPixel: dy increases with r at q=0), i.e.
    // toward the local player's side of the field.
    final target = HexCoord(dummyPos.q, dummyPos.r + 2);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BattleScreen(
          state: setup.state,
          localPlayerId: localId,
          chapter: chapter,
          session: SoloBattleSession(
            state: setup.state,
            dummyAutoCast: true,
            dummyCastTarget: target,
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text(
          'SPELL TEST LAB',
          style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
        ),
      ),
      body: SafeScreenBody(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          children: [
            Text(
              'Temporary testing mechanic — combine any effects into a free, '
              'unproven test spell. Test battles pit you against a dummy that '
              'casts a free Firey Blast every turn.',
              style: manuscriptCaptionStyle(),
            ),
            const SizedBox(height: 20),
            Text('BUILD A TEST SPELL', style: manuscriptCaptionStyle()),
            const SizedBox(height: 10),
            TextField(
              controller: _nameController,
              style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 16,
                color: kInkColor,
              ),
              decoration: const InputDecoration(
                hintText: 'Spell name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            for (int i = 0; i < _slots.length; i++) _buildSlotRow(i),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addSlot,
                icon: const Icon(Icons.add, color: kIlluminationGold),
                label: const Text(
                  'Add Effect',
                  style: TextStyle(color: kIlluminationGold),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _slots.isEmpty
                  ? 'No effects yet.'
                  : 'Preview: ${_slots.map((s) => '${kAffinityLabel[s.affinity]} ${kEffectKindLabel[s.kind]}').join(' → ')}',
              style: manuscriptCaptionStyle(),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _saveTestSpell,
                style: OutlinedButton.styleFrom(
                  foregroundColor: kIlluminationGold,
                  side: const BorderSide(color: kIlluminationGold, width: 2),
                ),
                child: const Text(
                  'SAVE TEST SPELL',
                  style: TextStyle(letterSpacing: 2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Divider(color: kInkColor.withValues(alpha: 0.12)),
            const SizedBox(height: 16),
            Text('YOUR TEST SPELLS', style: manuscriptCaptionStyle()),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _seedAllElementEffectPairings,
                icon: const Icon(Icons.auto_fix_high, color: kIlluminationGold),
                label: const Text(
                  'Seed all pairings (64)',
                  style: TextStyle(color: kIlluminationGold),
                ),
              ),
            ),
            const SizedBox(height: 4),
            _buildTestSpellList(),
            const SizedBox(height: 24),
            Divider(color: kInkColor.withValues(alpha: 0.12)),
            const SizedBox(height: 16),
            Text('BEGIN TEST BATTLE', style: manuscriptCaptionStyle()),
            const SizedBox(height: 10),
            _buildChapterPicker(),
            const SizedBox(height: 16),
            _buildStepper(
              label: 'STARTING HP',
              value: _hp,
              onDec: _hp > _hpMin ? () => setState(() => _hp -= _hpStep) : null,
              onInc: _hp < _hpMax ? () => setState(() => _hp += _hpStep) : null,
            ),
            const SizedBox(height: 20),
            _buildStepper(
              label: 'GRID SIZE',
              value: _gridRadius,
              onDec: _gridRadius > _gridRadiusMin
                  ? () => setState(() => _gridRadius--)
                  : null,
              onInc: _gridRadius < _gridRadiusMax
                  ? () => setState(() => _gridRadius++)
                  : null,
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: _beginTestBattle,
                style: OutlinedButton.styleFrom(
                  foregroundColor: kRubricRed,
                  side: const BorderSide(color: kRubricRed, width: 2),
                ),
                child: const Text(
                  'BEGIN TEST BATTLE',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 16,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlotRow(int i) {
    final slot = _slots[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<SpellAffinity>(
                value: slot.affinity,
                isExpanded: true,
                items: [
                  for (final a in SpellAffinity.values)
                    DropdownMenuItem(value: a, child: Text(kAffinityLabel[a]!)),
                ],
                onChanged: (v) => setState(() => slot.affinity = v!),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<EffectKind>(
                value: slot.kind,
                isExpanded: true,
                items: [
                  for (final k in EffectKind.values)
                    DropdownMenuItem(
                      value: k,
                      child: Text(kEffectKindLabel[k]!),
                    ),
                ],
                onChanged: (v) => setState(() => slot.kind = v!),
              ),
            ),
          ),
          IconButton(
            onPressed: _slots.length > 1 ? () => _removeSlot(i) : null,
            icon: const Icon(Icons.close, size: 18),
            color: kInkMutedColor,
          ),
        ],
      ),
    );
  }

  Widget _buildTestSpellList() {
    if (_loadingSpells) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Loading...',
          style: TextStyle(fontFamily: 'serif', color: kInkMutedColor),
        ),
      );
    }
    if (_testSpells.isEmpty) {
      return Text('No test spells yet.', style: manuscriptCaptionStyle());
    }
    return Column(
      children: [
        for (final spell in _testSpells)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: kParchmentPanelColor,
              border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    spell.name.substring(kTestSpellNamePrefix.length),
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 15,
                      color: kInkColor,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _deleteTestSpell(spell),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: kRubricRed,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildChapterPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: _loadingChapters
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'Loading...',
                style: TextStyle(fontFamily: 'serif', color: kInkMutedColor),
              ),
            )
          : DropdownButtonHideUnderline(
              child: DropdownButton<ChapterAsset?>(
                value: _selectedChapter,
                isExpanded: true,
                dropdownColor: kParchmentPanelColor,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 16,
                  color: kInkColor,
                ),
                items: [
                  const DropdownMenuItem<ChapterAsset?>(
                    value: null,
                    child: Text(
                      'Select Chapter',
                      style: TextStyle(
                        fontFamily: 'serif',
                        color: kInkMutedColor,
                      ),
                    ),
                  ),
                  for (final c in _chapters)
                    DropdownMenuItem<ChapterAsset?>(
                      value: c,
                      child: Text(c.name),
                    ),
                ],
                onChanged: (c) => setState(() => _selectedChapter = c),
              ),
            ),
    );
  }

  Widget _buildStepper({
    required String label,
    required int value,
    required VoidCallback? onDec,
    required VoidCallback? onInc,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: manuscriptCaptionStyle()),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(onPressed: onDec, icon: const Icon(Icons.remove)),
            SizedBox(
              width: 40,
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                ),
              ),
            ),
            IconButton(onPressed: onInc, icon: const Icon(Icons.add)),
          ],
        ),
      ],
    );
  }
}
