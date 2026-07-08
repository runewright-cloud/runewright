// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_screen.dart — the player's grimoire: four tabs covering spells they
// have inscribed (Craftings), spells observed from opponents (Sightings),
// spells loaned by allies (Loans), and battle-ready spell bundles (Chapters).
// Only Craftings and Chapters hold real data today; the other two are
// placeholders for upcoming protocol features (CLAUDE.md scope).

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/ca_rules.dart';
import '../engine/ca_run.dart' show advanceDominance;
import '../engine/formula.dart';
import '../engine/hex_grid.dart';
import '../engine/stepper.dart' show CAStep;
import '../identity/identity.dart';
import '../identity/key_packing.dart';
import '../battle/models/effect_kind.dart' show formulaEffectLabels;
import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import '../main.dart' show GameScreen;
import 'manuscript_theme.dart';
import 'sigil_painter.dart';
import 'spell_card_painter.dart';
import 'spell_test_lab_screen.dart' show kTestSpellNamePrefix;

// Replays spell.initialGrid for spell.t generations and collects the zone
// names of any elements that achieved supreme dominance. Fast (Dart CA only,
// no proving). Used to migrate spells inscribed before supremeTags tracking
// was added.
Set<String> _deriveSupremeTags(SpellAsset spell) {
  if (spell.initialGrid.isEmpty) return {};
  var grid = HexGrid.fromPackedState(spell.initialGrid, 12);
  var rule = CARules.neutral;
  final tags = <String>{};
  for (int gen = 0; gen < spell.t; gen++) {
    final next = CAStep.step(grid, rule);
    final dom = advanceDominance(rule, next);
    if (dom.isSupreme) {
      final zone = FormulaTracker.zoneFor(dom.dominant);
      if (zone != null) tags.add(zone.name);
    }
    grid = next;
    rule = dom.rule;
  }
  return tags;
}

// Shared across embellishment dialog and chapter detail view.
const _kEmbellishLabel = {
  'fire': 'Potency',
  'air': 'Velocity',
  'water': 'Efficiency',
  'earth': 'Mystery',
};
const _kEmbellishColor = {
  'fire': Color(0xFFB84040),
  'air': Color(0xFF5588BB),
  'water': Color(0xFF3399AA),
  'earth': Color(0xFF7A6040),
};

const _kArtifactLabel = {
  ArtifactKind.manaGem: 'Mana Gem',
  ArtifactKind.bookmark: 'Bookmark',
  ArtifactKind.deflectionRod: 'Deflection Rod',
  ArtifactKind.counterCharm: 'Counter Charm',
};

const _kArtifactIcon = {
  ArtifactKind.manaGem: Icons.diamond_outlined,
  ArtifactKind.bookmark: Icons.bookmark_outlined,
  ArtifactKind.deflectionRod: Icons.shield_outlined,
  ArtifactKind.counterCharm: Icons.block,
};

// ── LibraryScreen ─────────────────────────────────────────────────────────────

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _selectedChapterId;
  List<ChapterAsset> _chapters = [];

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  Future<void> _loadChapters() async {
    final chapters = await ChapterAsset.loadAll();
    final activeId = await ChapterAsset.loadActiveChapterId();
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      if (activeId != null && chapters.any((c) => c.id == activeId)) {
        _selectedChapterId = activeId;
      } else if (chapters.length == 1) {
        _selectedChapterId = chapters[0].id;
      } else if (_selectedChapterId != null &&
          !chapters.any((c) => c.id == _selectedChapterId)) {
        _selectedChapterId = null;
      }
    });
  }

  void _onChapterSelected(String id) {
    if (_chapters.length <= 1) return;
    final newId = _selectedChapterId == id ? null : id;
    setState(() => _selectedChapterId = newId);
    ChapterAsset.saveActiveChapterId(newId);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        backgroundColor: kParchmentColor,
        appBar: AppBar(
          backgroundColor: kInkColor,
          foregroundColor: kParchmentColor,
          elevation: 0,
          title: Text(
            'LIBRARY',
            style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
          ),
          bottom: TabBar(
            labelStyle: const TextStyle(
              fontFamily: 'serif',
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontFamily: 'serif',
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w400,
            ),
            labelColor: kIlluminationGold,
            unselectedLabelColor: kParchmentColor.withValues(alpha: 0.6),
            indicatorColor: kIlluminationGold,
            indicatorWeight: 2,
            tabs: const [
              Tab(text: 'CRAFTINGS'),
              Tab(text: 'SIGHTINGS'),
              Tab(text: 'LOANS'),
              Tab(text: 'CHAPTERS'),
              Tab(text: 'TESTS'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _CraftingsTab(
              selectedChapterId: _selectedChapterId,
              onChaptersChanged: _loadChapters,
            ),
            const _PlaceholderTab(
              icon: Icons.visibility_outlined,
              title: 'Sightings',
              description:
                  'Spells your opponents have cast against you will be recorded here. '
                  'Face a challenger to begin your record.',
            ),
            const _PlaceholderTab(
              icon: Icons.handshake_outlined,
              title: 'Loans',
              description:
                  'Spells leased to you by other wizards will appear here. '
                  'They are bound to your Runekey, and you may add them to chapters and cast them in battle, '
                  'but you may not view their workings nor lend them to others yourself. '
                  'Some loans such as between a master and apprentice will cease to function with time unless renewed.',
            ),
            _ChaptersTab(
              chapters: _chapters,
              selectedChapterId: _selectedChapterId,
              onChapterSelected: _onChapterSelected,
              onChaptersChanged: _loadChapters,
            ),
            _TestsTab(
              selectedChapterId: _selectedChapterId,
              onChaptersChanged: _loadChapters,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Craftings tab ─────────────────────────────────────────────────────────────

class _CraftingsTab extends StatefulWidget {
  const _CraftingsTab({
    required this.selectedChapterId,
    required this.onChaptersChanged,
  });

  final String? selectedChapterId;
  final VoidCallback onChaptersChanged;

  @override
  State<_CraftingsTab> createState() => _CraftingsTabState();
}

class _CraftingsTabState extends State<_CraftingsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late Future<List<SpellAsset>> _spellsFuture;
  String? _wizardName;
  Uint8List? _creatorKeyBytes;

  @override
  void initState() {
    super.initState();
    _spellsFuture = _purgeLegacyAndLoad();
    _loadIdentity();
  }

  // Deletes spells inscribed before RULESET_VERSION 3 geometry outputs
  // (identified by segmentCount == -1 in fromJson sentinel). These have
  // mana costs computed under the old cell-count formula and are incompatible
  // with the new 5×seg + dot formula.
  Future<List<SpellAsset>> _purgeLegacyAndLoad() async {
    final all = await SpellAsset.loadAll();
    for (final s in all) {
      if (s.segmentCount < 0) await s.delete();
    }
    return SpellAsset.loadAll();
  }

  Future<void> _loadIdentity() async {
    final identity = await Identity.loadOrCreate();
    final name = await Identity.loadWizardName();
    final pubkeyHex = await identity.ownerPubkeyHex();
    if (!mounted) return;
    setState(() {
      _wizardName = name;
      _creatorKeyBytes = fieldHexToLeBytes(pubkeyHex, 32);
    });
  }

  void _reload() => setState(() => _spellsFuture = SpellAsset.loadAll());

  void _viewSpell(SpellAsset spell) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(loadedSpell: spell)),
    );
  }

  Future<void> _deleteSpell(SpellAsset spell) async {
    await spell.delete();
    _reload();
  }

  Future<void> _addToChapter(SpellAsset spell) async {
    final chapterId = widget.selectedChapterId;
    if (chapterId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a chapter in the Chapters tab first.')),
        );
      }
      return;
    }

    // Spells inscribed before supremeTags tracking was added have an empty
    // list. Derive and persist the tags now so subsequent adds are free.
    var effectiveSpell = spell;
    if (spell.supremeTags.isEmpty && spell.initialGrid.isNotEmpty) {
      final derived = _deriveSupremeTags(spell);
      if (derived.isNotEmpty) {
        effectiveSpell = spell.withSupremeTags(derived.toList());
        await effectiveSpell.save();
        _reload();
      }
    }

    final chapter = await ChapterAsset.loadById(chapterId);
    if (chapter == null || !mounted) return;

    // Reject if any existing chapter entry shares the same grid commitment.
    if (effectiveSpell.commitmentHex.isNotEmpty) {
      final allSpells = await SpellAsset.loadAll();
      final byId = {for (final s in allSpells) s.id: s};
      final chapterCommitments = chapter.entries
          .map((e) => byId[e.spellId]?.commitmentHex)
          .whereType<String>()
          .toSet();
      if (chapterCommitments.contains(effectiveSpell.commitmentHex)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Chapter already contains a spell with these runes.'),
            ),
          );
        }
        return;
      }
    }

    String? finalEmbellishment;
    if (effectiveSpell.supremeTags.isNotEmpty && mounted) {
      final result = await showDialog<String>(
        context: context,
        builder: (_) => _EmbellishmentDialog(
          availableTags: Set<String>.from(effectiveSpell.supremeTags),
        ),
      );
      if (!mounted) return;
      if (result == null) return; // user cancelled
      finalEmbellishment = result.isEmpty ? null : result;
    }

    final updated = chapter.withEntry(
      ChapterEntry(spellId: effectiveSpell.id, embellishment: finalEmbellishment),
    );
    await updated.save();
    widget.onChaptersChanged();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${effectiveSpell.name}" added to ${chapter.name}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<SpellAsset>>(
      future: _spellsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: kIlluminationGold),
          );
        }
        if (snap.hasError) {
          return _ErrorBody(
            message: 'Could not load your grimoire.\n${snap.error}',
            onRetry: _reload,
          );
        }
        final spells = snap.data ?? [];
        if (spells.isEmpty) {
          return _EmptyBody(
            icon: Icons.auto_awesome_outlined,
            message: 'Your grimoire is empty.\nInscribe your first spell from Rune Craft.',
          );
        }
        final kinCount = <String, int>{};
        for (final s in spells) {
          if (s.commitmentHex.isNotEmpty) {
            kinCount[s.commitmentHex] = (kinCount[s.commitmentHex] ?? 0) + 1;
          }
        }
        return RefreshIndicator(
          color: kIlluminationGold,
          backgroundColor: kParchmentColor,
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: spells.length,
            itemBuilder: (context, i) {
              final spell = spells[i];
              final siblings =
                  spell.commitmentHex.isNotEmpty ? (kinCount[spell.commitmentHex] ?? 1) : 1;
              return _SpellCard(
                spell: spell,
                kinSiblings: siblings,
                wizardName: _wizardName,
                creatorKeyBytes: _creatorKeyBytes,
                onView: () => _viewSpell(spell),
                onDelete: () => _deleteSpell(spell),
                onAddToChapter: () => _addToChapter(spell),
              );
            },
          ),
        );
      },
    );
  }
}

// ── Tests tab ──────────────────────────────────────────────────────────────────
//
// Lists only spells fabricated by the Spell Test Lab (kTestSpellNamePrefix).
// Test spells never derive supremeTags (their grid is all-zero — see
// spell_test_lab_screen.dart) so, unlike Craftings, adding one never pops the
// embellishment dialog; that lets "add all" batch straight through.

class _TestsTab extends StatefulWidget {
  const _TestsTab({
    required this.selectedChapterId,
    required this.onChaptersChanged,
  });

  final String? selectedChapterId;
  final VoidCallback onChaptersChanged;

  @override
  State<_TestsTab> createState() => _TestsTabState();
}

class _TestsTabState extends State<_TestsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late Future<List<SpellAsset>> _spellsFuture;

  @override
  void initState() {
    super.initState();
    _spellsFuture = _loadTestSpells();
  }

  Future<List<SpellAsset>> _loadTestSpells() async {
    final all = await SpellAsset.loadAll();
    return all.where((s) => s.name.startsWith(kTestSpellNamePrefix)).toList();
  }

  void _reload() => setState(() => _spellsFuture = _loadTestSpells());

  void _viewSpell(SpellAsset spell) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(loadedSpell: spell)),
    );
  }

  Future<void> _deleteSpell(SpellAsset spell) async {
    await spell.delete();
    _reload();
  }

  /// Adds every spell in [spells] to the selected chapter as a single batch:
  /// one chapter load, one save, skipping any whose grid commitment is
  /// already present (matching Craftings' per-spell dedup rule). Passing a
  /// one-element list is how the per-card "add" button reuses this.
  Future<void> _addAllToChapter(List<SpellAsset> spells) async {
    final chapterId = widget.selectedChapterId;
    if (chapterId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a chapter in the Chapters tab first.')),
      );
      return;
    }
    var chapter = await ChapterAsset.loadById(chapterId);
    if (chapter == null || !mounted) return;

    final allSpells = await SpellAsset.loadAll();
    final byId = {for (final s in allSpells) s.id: s};
    final seenCommitments = chapter.entries
        .map((e) => byId[e.spellId]?.commitmentHex)
        .whereType<String>()
        .toSet();

    var added = 0;
    var skipped = 0;
    for (final spell in spells) {
      if (spell.commitmentHex.isNotEmpty && seenCommitments.contains(spell.commitmentHex)) {
        skipped++;
        continue;
      }
      chapter = chapter!.withEntry(ChapterEntry(spellId: spell.id));
      if (spell.commitmentHex.isNotEmpty) seenCommitments.add(spell.commitmentHex);
      added++;
    }
    if (added > 0) {
      await chapter!.save();
      widget.onChaptersChanged();
    }
    if (!mounted) return;
    final chapterName = chapter!.name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0
            ? '${spells.length == 1 ? 'That spell is' : 'All ${spells.length} spells are'} already in "$chapterName".'
            : 'Added $added test spell${added == 1 ? '' : 's'} to "$chapterName"'
                '${skipped > 0 ? ' ($skipped already present)' : ''}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<SpellAsset>>(
      future: _spellsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: kIlluminationGold),
          );
        }
        if (snap.hasError) {
          return _ErrorBody(
            message: 'Could not load test spells.\n${snap.error}',
            onRetry: _reload,
          );
        }
        final spells = snap.data ?? [];
        if (spells.isEmpty) {
          return const _EmptyBody(
            icon: Icons.science_outlined,
            message: 'No test spells yet.\nBuild some in the Spell Test Lab.',
          );
        }
        return RefreshIndicator(
          color: kIlluminationGold,
          backgroundColor: kParchmentColor,
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: spells.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    height: 40,
                    child: OutlinedButton.icon(
                      onPressed: () => _addAllToChapter(spells),
                      icon: const Icon(Icons.playlist_add, size: 18),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kIlluminationGold,
                        side: const BorderSide(color: kIlluminationGold, width: 2),
                      ),
                      label: Text('ADD ALL ${spells.length} TO CHAPTER'),
                    ),
                  ),
                );
              }
              final spell = spells[i - 1];
              return _SpellCard(
                spell: spell,
                kinSiblings: 1,
                onView: () => _viewSpell(spell),
                onDelete: () => _deleteSpell(spell),
                onAddToChapter: () => _addAllToChapter([spell]),
              );
            },
          ),
        );
      },
    );
  }
}

// ── SpellCard ─────────────────────────────────────────────────────────────────

class _SpellCard extends StatelessWidget {
  const _SpellCard({
    required this.spell,
    required this.kinSiblings,
    required this.onDelete,
    required this.onAddToChapter,
    required this.onView,
    this.wizardName,
    this.creatorKeyBytes,
  });

  final SpellAsset spell;
  final int kinSiblings;
  final VoidCallback onDelete;
  final VoidCallback onAddToChapter;
  final VoidCallback onView;
  final String? wizardName;
  final Uint8List? creatorKeyBytes;

  bool get _isKin => kinSiblings > 1;

  String get _displayName =>
      spell.name.isNotEmpty ? spell.name : 'Unnamed Spell';

  String get _meta => 'Gen ${spell.t}  ·  ♦ ${spell.manaCost}';

  String get _formulaText {
    if (spell.formula.isEmpty) return '';
    final labels = formulaEffectLabels(spell.formula);
    if (labels.isEmpty) return '';
    return labels.join('  ·  ');
  }

  String get _date {
    final d = spell.createdAt;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  void _onMenuSelected(BuildContext context, String action) {
    if (action == 'view') {
      onView();
    } else if (action == 'delete') {
      showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete Spell'),
          content: Text('Delete "${spell.name}"? This cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: kRubricRed),
              child: const Text('Delete'),
            ),
          ],
        ),
      ).then((ok) {
        if (ok == true) onDelete();
      });
    } else if (action == 'add') {
      onAddToChapter();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentPanelColor,
          border: Border.all(
            color: _isKin
                ? kIlluminationGold.withValues(alpha: 0.5)
                : kInkColor.withValues(alpha: 0.15),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft:    Radius.circular(3),
                bottomLeft: Radius.circular(3),
              ),
              child: SpellCardWidget(spell: spell, size: 84),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _displayName,
                            style: const TextStyle(
                              fontFamily: 'serif',
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: kInkColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        if (_isKin) _KinBadge(count: kinSiblings),
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            size: 18,
                            color: kInkColor.withValues(alpha: 0.45),
                          ),
                          onSelected: (v) => _onMenuSelected(context, v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'view', child: Text('View')),
                            PopupMenuItem(value: 'add', child: Text('Add to Chapter')),
                            PopupMenuItem(value: 'delete', child: Text('Delete Spell')),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _meta,
                      style: manuscriptCaptionStyle(color: kInkColor.withValues(alpha: 0.7))
                          .copyWith(fontStyle: FontStyle.normal),
                    ),
                    if (_formulaText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formulaText,
                        style: manuscriptCaptionStyle(color: kInkColor.withValues(alpha: 0.55))
                            .copyWith(fontStyle: FontStyle.normal, fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(_date, style: manuscriptCaptionStyle()),
                    if (creatorKeyBytes != null ||
                        (wizardName != null && wizardName!.isNotEmpty)) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (creatorKeyBytes != null)
                            SigilWidget(keyBytes: creatorKeyBytes!, size: 36, saturation: 2.5),
                          if (creatorKeyBytes != null) const SizedBox(width: 6),
                          if (wizardName != null && wizardName!.isNotEmpty)
                            Text(
                              wizardName!,
                              style: manuscriptCaptionStyle(
                                color: kInkColor.withValues(alpha: 0.6),
                              ).copyWith(fontStyle: FontStyle.normal),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KinBadge extends StatelessWidget {
  const _KinBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: kIlluminationGold, width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        'KIN ×$count',
        style: const TextStyle(
          fontFamily: 'serif',
          fontSize: 10,
          letterSpacing: 1,
          color: kIlluminationGold,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Chapters tab ──────────────────────────────────────────────────────────────

class _ChaptersTab extends StatefulWidget {
  const _ChaptersTab({
    required this.chapters,
    required this.selectedChapterId,
    required this.onChapterSelected,
    required this.onChaptersChanged,
  });

  final List<ChapterAsset> chapters;
  final String? selectedChapterId;
  final void Function(String) onChapterSelected;
  final VoidCallback onChaptersChanged;

  @override
  State<_ChaptersTab> createState() => _ChaptersTabState();
}

class _ChaptersTabState extends State<_ChaptersTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _openChapter(ChapterAsset chapter) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ChapterDetailScreen(
          chapter: chapter,
          initiallyActive: chapter.id == widget.selectedChapterId,
          onSetActive: () => widget.onChapterSelected(chapter.id),
          onChapterChanged: widget.onChaptersChanged,
        ),
      ),
    );
  }

  Future<void> _createChapter() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameInputDialog(
        title: 'New Chapter',
        hint: 'Chapter name',
        confirmLabel: 'Create',
      ),
    );
    if (name == null || !mounted) return;
    final chapter = ChapterAsset(
      id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now().toUtc(),
    );
    await chapter.save();
    widget.onChaptersChanged();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final chapters = widget.chapters;
    return Column(
      children: [
        Expanded(
          child: chapters.isEmpty
              ? _EmptyBody(
                  icon: Icons.collections_bookmark_outlined,
                  message:
                      'No chapters yet.\nCreate one to bundle spells for battle.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  itemCount: chapters.length,
                  itemBuilder: (_, i) {
                    final c = chapters[i];
                    return _ChapterTile(
                      chapter: c,
                      isSelected: c.id == widget.selectedChapterId,
                      onTap: () => _openChapter(c),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create New Chapter'),
              onPressed: _createChapter,
              style: OutlinedButton.styleFrom(
                foregroundColor: kInkColor,
                side: BorderSide(color: kInkColor.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontFamily: 'serif',
                  letterSpacing: 1,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.chapter,
    required this.isSelected,
    required this.onTap,
  });

  final ChapterAsset chapter;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: kParchmentPanelColor,
            border: Border.all(
              color: isSelected
                  ? kIlluminationGold.withValues(alpha: 0.8)
                  : kInkColor.withValues(alpha: 0.15),
              width: isSelected ? 1.5 : 1.0,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.brightness_1,
                    size: 8,
                    color: kIlluminationGold,
                  ),
                ),
              Expanded(
                child: Text(
                  chapter.name,
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 16,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: kInkColor,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${chapter.entries.length} spell${chapter.entries.length == 1 ? '' : 's'}',
                    style: manuscriptCaptionStyle(),
                  ),
                  if (chapter.artifacts.isNotEmpty)
                    Text(
                      '${chapter.artifacts.length} artifact${chapter.artifacts.length == 1 ? '' : 's'}',
                      style: manuscriptCaptionStyle(),
                    ),
                ],
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: kIlluminationGold),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text(
                    'ACTIVE',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 9,
                      letterSpacing: 1.5,
                      color: kIlluminationGold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chapter detail screen ─────────────────────────────────────────────────────

class _ChapterDetailScreen extends StatefulWidget {
  const _ChapterDetailScreen({
    required this.chapter,
    required this.initiallyActive,
    required this.onSetActive,
    required this.onChapterChanged,
  });

  final ChapterAsset chapter;
  final bool initiallyActive;
  final VoidCallback onSetActive;
  final VoidCallback onChapterChanged;

  @override
  State<_ChapterDetailScreen> createState() => _ChapterDetailScreenState();
}

class _ChapterDetailScreenState extends State<_ChapterDetailScreen> {
  late ChapterAsset _chapter;
  late bool _isActive;
  // Parallel to _chapter.entries; null means the spell was deleted from library.
  List<SpellAsset?>? _spells;

  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    _isActive = widget.initiallyActive;
    _loadSpells();
  }

  Future<void> _loadSpells() async {
    final all = await SpellAsset.loadAll();
    if (!mounted) return;
    final byId = {for (final s in all) s.id: s};
    setState(() {
      _spells = _chapter.entries.map((e) => byId[e.spellId]).toList();
    });
  }

  void _setActive() {
    widget.onSetActive();
    setState(() => _isActive = true);
  }

  Future<void> _removeEntry(int index) async {
    final spellName = _spells?[index]?.name;
    final label = spellName != null ? '"$spellName"' : 'this spell';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove from Chapter'),
        content: Text('Remove $label from "${_chapter.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final updated = _chapter.withoutEntryAt(index);
    await updated.save();
    setState(() => _chapter = updated);
    await _loadSpells();
    widget.onChapterChanged();
  }

  Future<void> _addArtifact() async {
    final kind = await showDialog<ArtifactKind>(
      context: context,
      builder: (_) => const _AddArtifactDialog(),
    );
    if (kind == null || !mounted) return;

    if (kind == ArtifactKind.counterCharm) {
      await _addCounterCharm();
      return;
    }
    final updated = _chapter.withArtifact(ArtifactEntry(kind: kind));
    await updated.save();
    if (!mounted) return;
    setState(() => _chapter = updated);
    widget.onChapterChanged();
  }

  Future<void> _addCounterCharm() async {
    final spell = await showDialog<SpellAsset>(
      context: context,
      builder: (_) => const _CounterCharmAttunementDialog(),
    );
    if (spell == null || !mounted) return;
    final entry = ArtifactEntry(
      kind: ArtifactKind.counterCharm,
      targetCommitmentHex: spell.commitmentHex,
      targetSpellName: spell.name.isNotEmpty ? spell.name : 'Unnamed Spell',
    );
    final updated = _chapter.withArtifact(entry);
    await updated.save();
    if (!mounted) return;
    setState(() => _chapter = updated);
    widget.onChapterChanged();
  }

  Future<void> _incrementArtifact(ArtifactKind kind) async {
    final updated = _chapter.withArtifact(ArtifactEntry(kind: kind));
    await updated.save();
    setState(() => _chapter = updated);
    widget.onChapterChanged();
  }

  Future<void> _decrementArtifact(ArtifactKind kind) async {
    final idx = _chapter.artifacts.lastIndexWhere((a) => a.kind == kind);
    if (idx < 0) return;
    final updated = _chapter.withoutArtifactAt(idx);
    await updated.save();
    setState(() => _chapter = updated);
    widget.onChapterChanged();
  }

  Future<void> _removeCounterCharm(int index) async {
    final charm = _chapter.artifacts[index];
    final targetName = charm.targetSpellName ?? 'this spell';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Counter Charm'),
        content: Text('Remove the charm attuned to "$targetName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final updated = _chapter.withoutArtifactAt(index);
    await updated.save();
    setState(() => _chapter = updated);
    widget.onChapterChanged();
  }

  Widget _buildBody(List<SpellAsset?> spells) {
    // Group non-CC artifacts by kind; collect CC indices for individual display.
    final kindCounts = <ArtifactKind, int>{};
    final counterCharmIndices = <int>[];
    for (int i = 0; i < _chapter.artifacts.length; i++) {
      final a = _chapter.artifacts[i];
      if (a.kind == ArtifactKind.counterCharm) {
        counterCharmIndices.add(i);
      } else {
        kindCounts[a.kind] = (kindCounts[a.kind] ?? 0) + 1;
      }
    }

    const groupedKinds = [
      ArtifactKind.manaGem,
      ArtifactKind.bookmark,
      ArtifactKind.deflectionRod,
    ];
    final slotsRemaining = _chapter.artifactSlotsRemaining;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _ArtifactSectionHeader(
          remaining: slotsRemaining,
          onAdd: slotsRemaining > 0 ? _addArtifact : null,
        ),
        const SizedBox(height: 6),
        for (final kind in groupedKinds)
          if ((kindCounts[kind] ?? 0) > 0)
            _ArtifactGroupTile(
              kind: kind,
              count: kindCounts[kind]!,
              canIncrement: slotsRemaining > 0,
              onDecrement: () => _decrementArtifact(kind),
              onIncrement: () => _incrementArtifact(kind),
            ),
        for (final idx in counterCharmIndices)
          _CounterCharmTile(
            artifact: _chapter.artifacts[idx],
            onRemove: () => _removeCounterCharm(idx),
          ),
        if (counterCharmIndices.isNotEmpty && slotsRemaining > 0)
          _AddCounterCharmButton(onAdd: _addCounterCharm),
        if (_chapter.artifacts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('No artifacts equipped.', style: manuscriptCaptionStyle()),
          ),
        const SizedBox(height: 16),
        const _SectionDivider(label: 'SPELLS'),
        const SizedBox(height: 8),
        if (_chapter.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No spells in this chapter yet.\nAdd spells from your Craftings.',
              style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
              textAlign: TextAlign.center,
            ),
          )
        else
          for (int i = 0; i < _chapter.entries.length; i++)
            _ChapterSpellTile(
              entry: _chapter.entries[i],
              spell: spells[i],
              onRemove: () => _removeEntry(i),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final spells = _spells;
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        title: Text(
          _chapter.name,
          style: manuscriptHeaderStyle(fontSize: 18, color: kParchmentColor),
        ),
        actions: [
          if (_isActive)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  'ACTIVE',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 11,
                    letterSpacing: 2,
                    color: kIlluminationGold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _setActive,
              child: const Text(
                'Set as Active',
                style: TextStyle(
                  fontFamily: 'serif',
                  color: kIlluminationGold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
      body: spells == null
          ? const Center(child: CircularProgressIndicator(color: kIlluminationGold))
          : _buildBody(spells),
    );
  }
}

class _ChapterSpellTile extends StatelessWidget {
  const _ChapterSpellTile({
    required this.entry,
    required this.spell,
    required this.onRemove,
  });

  final ChapterEntry entry;
  final SpellAsset? spell;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = spell?.name.isNotEmpty == true ? spell!.name : 'Unnamed Spell';
    final meta = spell != null ? 'Gen ${spell!.t}  ·  ♦ ${spell!.manaCost}' : '';
    final embLabel = entry.embellishment != null
        ? _kEmbellishLabel[entry.embellishment]
        : null;
    final embColor = entry.embellishment != null
        ? _kEmbellishColor[entry.embellishment]
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentPanelColor,
          border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            spell == null ? 'Deleted Spell' : name,
                            style: TextStyle(
                              fontFamily: 'serif',
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: spell == null
                                  ? kInkMutedColor
                                  : kInkColor,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        if (embLabel != null && embColor != null)
                          Container(
                            margin: const EdgeInsets.only(right: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: embColor.withValues(alpha: 0.7)),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              embLabel.toUpperCase(),
                              style: TextStyle(
                                fontFamily: 'serif',
                                fontSize: 9,
                                letterSpacing: 1.2,
                                color: embColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        style: manuscriptCaptionStyle(
                                color: kInkColor.withValues(alpha: 0.6))
                            .copyWith(fontStyle: FontStyle.normal),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  size: 18,
                  color: kInkColor.withValues(alpha: 0.45),
                ),
                onSelected: (_) => onRemove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove from Chapter'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Artifact section widgets ──────────────────────────────────────────────────

class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Divider(
            color: kInkColor.withValues(alpha: 0.15),
            thickness: 1,
            endIndent: 8,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'serif',
            fontSize: 10,
            letterSpacing: 2,
            color: kInkMutedColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        Expanded(
          child: Divider(
            color: kInkColor.withValues(alpha: 0.15),
            thickness: 1,
            indent: 8,
          ),
        ),
      ],
    );
  }
}

class _ArtifactSectionHeader extends StatelessWidget {
  const _ArtifactSectionHeader({required this.remaining, this.onAdd});

  final int remaining;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final Color countColor;
    if (remaining == 0) {
      countColor = kRubricRed;
    } else if (remaining <= 3) {
      countColor = kIlluminationGold;
    } else {
      countColor = kInkColor;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ARTIFACTS',
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                ),
              ),
              Row(
                children: [
                  Text('Artifact Slots Remaining: ', style: manuscriptCaptionStyle()),
                  Text(
                    '$remaining',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: countColor,
                    ),
                  ),
                  Text(
                    ' / ${ChapterAsset.maxArtifactSlots}',
                    style: manuscriptCaptionStyle(),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (onAdd != null)
          TextButton.icon(
            icon: const Icon(Icons.add, size: 15),
            label: const Text('Add'),
            onPressed: onAdd,
            style: TextButton.styleFrom(
              foregroundColor: kInkColor,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontFamily: 'serif',
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
      ],
    );
  }
}

class _ArtifactGroupTile extends StatelessWidget {
  const _ArtifactGroupTile({
    required this.kind,
    required this.count,
    required this.canIncrement,
    required this.onDecrement,
    required this.onIncrement,
  });

  final ArtifactKind kind;
  final int count;
  final bool canIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    final label = _kArtifactLabel[kind] ?? kind.name;
    final icon = _kArtifactIcon[kind] ?? Icons.category_outlined;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentPanelColor,
          border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(icon, size: 16, color: kInkColor.withValues(alpha: 0.55)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: kInkColor,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.remove, size: 16),
                onPressed: onDecrement,
                visualDensity: VisualDensity.compact,
                color: kInkColor.withValues(alpha: 0.7),
                tooltip: 'Remove one',
              ),
              SizedBox(
                width: 26,
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'serif',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: kInkColor,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 16),
                onPressed: canIncrement ? onIncrement : null,
                visualDensity: VisualDensity.compact,
                color: canIncrement
                    ? kInkColor.withValues(alpha: 0.7)
                    : kInkMutedColor.withValues(alpha: 0.3),
                tooltip: canIncrement ? 'Add one' : 'No slots remaining',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CounterCharmTile extends StatelessWidget {
  const _CounterCharmTile({required this.artifact, required this.onRemove});

  final ArtifactEntry artifact;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentPanelColor,
          border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Icon(Icons.block, size: 16, color: kInkColor.withValues(alpha: 0.55)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Counter Charm',
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: kInkColor,
                        letterSpacing: 0.3,
                      ),
                    ),
                    if (artifact.targetSpellName != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Attuned to: ${artifact.targetSpellName}',
                        style: manuscriptCaptionStyle(
                          color: kInkColor.withValues(alpha: 0.6),
                        ).copyWith(fontStyle: FontStyle.normal),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.close,
                  size: 16,
                  color: kInkColor.withValues(alpha: 0.45),
                ),
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove charm',
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddCounterCharmButton extends StatelessWidget {
  const _AddCounterCharmButton({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.add, size: 15),
        label: const Text('Add Counter Charm'),
        onPressed: onAdd,
        style: OutlinedButton.styleFrom(
          foregroundColor: kInkColor,
          side: BorderSide(color: kInkColor.withValues(alpha: 0.3)),
          padding: const EdgeInsets.symmetric(vertical: 10),
          textStyle: const TextStyle(
            fontFamily: 'serif',
            letterSpacing: 0.5,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

// ── Add artifact dialog ───────────────────────────────────────────────────────

class _AddArtifactDialog extends StatelessWidget {
  const _AddArtifactDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Add Artifact',
        style: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ArtifactOption(
              icon: Icons.diamond_outlined,
              label: 'Mana Gem',
              description: '+100 mana pool · +10 regen per turn',
              onTap: () => Navigator.pop(context, ArtifactKind.manaGem),
            ),
            _ArtifactOption(
              icon: Icons.bookmark_outlined,
              label: 'Bookmark',
              description: 'Expand hand size; auto-retargets on use',
              onTap: () => Navigator.pop(context, ArtifactKind.bookmark),
            ),
            _ArtifactOption(
              icon: Icons.shield_outlined,
              label: 'Deflection Rod',
              description: 'Nullify one turn of an incoming status effect',
              onTap: () => Navigator.pop(context, ArtifactKind.deflectionRod),
            ),
            _ArtifactOption(
              icon: Icons.block,
              label: 'Counter Charm',
              description:
                  'Attune to a spell — counter it whenever your opponent casts it',
              onTap: () => Navigator.pop(context, ArtifactKind.counterCharm),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ArtifactOption extends StatelessWidget {
  const _ArtifactOption({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: kParchmentPanelColor,
            border: Border.all(color: kInkColor.withValues(alpha: 0.2)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: kInkColor.withValues(alpha: 0.7)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'serif',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: kInkColor,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 12,
                        color: kInkColor.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Counter Charm attunement dialog ───────────────────────────────────────────

class _CounterCharmAttunementDialog extends StatefulWidget {
  const _CounterCharmAttunementDialog();

  @override
  State<_CounterCharmAttunementDialog> createState() =>
      _CounterCharmAttunementDialogState();
}

class _CounterCharmAttunementDialogState
    extends State<_CounterCharmAttunementDialog> {
  late Future<List<SpellAsset>> _spellsFuture;

  @override
  void initState() {
    super.initState();
    _spellsFuture = SpellAsset.loadAll();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Attune Counter Charm',
        style: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<List<SpellAsset>>(
          future: _spellsFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(
                  child: CircularProgressIndicator(color: kIlluminationGold),
                ),
              );
            }
            final spells = snap.data ?? [];
            return ListView(
              shrinkWrap: true,
              children: [
                _AttunementSectionLabel(label: 'CRAFTINGS'),
                if (spells.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(
                      'No spells inscribed yet.',
                      style: manuscriptCaptionStyle(),
                    ),
                  )
                else
                  for (final spell in spells)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      title: Text(
                        spell.name.isNotEmpty ? spell.name : 'Unnamed Spell',
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 14,
                          color: kInkColor,
                        ),
                      ),
                      subtitle: Text(
                        'Gen ${spell.t}  ·  ♦ ${spell.manaCost}',
                        style: manuscriptCaptionStyle()
                            .copyWith(fontStyle: FontStyle.normal),
                      ),
                      onTap: () => Navigator.pop(context, spell),
                    ),
                _AttunementSectionLabel(label: 'SIGHTINGS'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                  child: Text(
                    'Sightings will appear here after facing challengers.',
                    style: manuscriptCaptionStyle(),
                  ),
                ),
                _AttunementSectionLabel(label: 'LOANS'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                  child: Text(
                    'Loaned spells will appear here.',
                    style: manuscriptCaptionStyle(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _AttunementSectionLabel extends StatelessWidget {
  const _AttunementSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'serif',
          fontSize: 10,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
          color: kInkMutedColor,
        ),
      ),
    );
  }
}

// ── Embellishment dialog ──────────────────────────────────────────────────────

class _EmbellishmentDialog extends StatelessWidget {
  const _EmbellishmentDialog({required this.availableTags});

  final Set<String> availableTags;

  static const _descs = {
    'fire': 'Increase the power of your spell.',
    'air': 'Increase spell range by 2.',
    'water': 'Reduce mana cost by a third.',
    'earth': 'Delay casting 1 to 3 turns, the delay time and target are secret.',
  };
  static const _tags = ['fire', 'air', 'water', 'earth'];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Add Embellishment?',
        style: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tag in _tags)
            _EmbellishOption(
              label: _kEmbellishLabel[tag]!,
              description: _descs[tag]!,
              enabled: availableTags.contains(tag),
              color: _kEmbellishColor[tag]!,
              onTap: () => Navigator.pop(context, tag),
            ),
          const SizedBox(height: 4),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Add Without'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _EmbellishOption extends StatelessWidget {
  const _EmbellishOption({
    required this.label,
    required this.description,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? color : kInkMutedColor.withValues(alpha: 0.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: enabled ? color.withValues(alpha: 0.05) : Colors.transparent,
            border: Border.all(color: fg),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: fg,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 12,
                        color: enabled
                            ? kInkColor.withValues(alpha: 0.7)
                            : kInkMutedColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: kInkMutedColor.withValues(alpha: 0.4),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Name input dialog (shared) ────────────────────────────────────────────────

class _NameInputDialog extends StatefulWidget {
  const _NameInputDialog({
    required this.title,
    this.hint = '',
    this.confirmLabel = 'OK',
  });

  final String title;
  final String hint;
  final String confirmLabel;

  @override
  State<_NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<_NameInputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        textCapitalization: TextCapitalization.words,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

// ── Placeholder tab (Sightings / Loans) ──────────────────────────────────────

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: kInkMutedColor),
            const SizedBox(height: 20),
            Text(
              title.toUpperCase(),
              style: manuscriptHeaderStyle(fontSize: 16, color: kInkMutedColor),
            ),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared utility bodies ─────────────────────────────────────────────────────

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: kInkMutedColor),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: manuscriptBodyStyle(fontSize: 14, color: kInkMutedColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: kRubricRed),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: manuscriptBodyStyle(fontSize: 14, color: kRubricRed),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: kInkColor),
              child: const Text(
                'Try again',
                style: TextStyle(fontFamily: 'serif', letterSpacing: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
