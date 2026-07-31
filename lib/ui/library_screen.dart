// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_screen.dart — the player's grimoire: spells they have inscribed
// (Craftings), spells observed from opponents in LAN duels (Sightings),
// spells loaned by allies (Loans), battle-ready spell bundles (Chapters),
// and spells fabricated by the Spell Test Lab (Tests). All five tabs hold
// real, persisted data (docs/SIGHTINGS_PLAN.md).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../identity/identity.dart';
import '../identity/key_packing.dart';
import '../battle/models/creature_spec.dart' show summonSummaryFromFormula;
import '../battle/models/effect_kind.dart' show formulaEffectLabels;
import '../battle/models/minion.dart' show SummonPersonality, kSummonPersonalityLabel;
import '../spells/basic_spell_seed.dart' show seedBasicSpells;
import '../spells/basic_spells.dart' show isBasicSpell;
import '../spells/chapter_asset.dart';
import '../spells/sighting_asset.dart';
import '../spells/spell_art_import.dart';
import '../spells/spell_art_io.dart';
import '../spells/spell_art_store.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';
import '../spells/supreme_tags.dart' show deriveSupremeTags;
import '../main.dart' show GameScreen;
import 'manuscript_theme.dart';
import 'sigil_painter.dart';
import 'spell_art_pack_screen.dart';
import 'spell_card_painter.dart';
import 'spell_test_lab_screen.dart' show kTestSpellNamePrefix;

// ── Custom spell art (P1: own library spells only) ──────────────────────────
//
// Shared by the Craftings and Tests tabs' _SpellCard menu actions. Own-spell
// art is entirely local: pick a file, decode/re-encode it off the UI isolate
// (spell_art_import.dart), stash the bytes in SpellArtStore keyed by
// spellHashHex, and stamp lightweight metadata onto the SpellAsset. No
// networking, no opponent art -- see CLAUDE.md custom-art P1 go-ahead.

/// Runs the pick -> decode/re-encode -> store -> persist pipeline for
/// [spell], showing a non-dismissible progress indicator while the
/// (potentially several-second) decode/re-encode step runs. Any failure
/// (cancelled picker, rejected image, decode timeout) is reported via a
/// snackbar and leaves [spell] untouched -- never crashes, never partially
/// writes (the store write and the SpellAsset save both happen only after
/// import succeeds).
Future<void> _setCustomArtOnSpell(
  BuildContext context,
  SpellAsset spell,
  VoidCallback onReload,
) async {
  final Uint8List? sourceBytes;
  try {
    sourceBytes = await pickSpellArtFile();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open the file picker: $e')));
    }
    return;
  }
  if (sourceBytes == null) return; // player cancelled the picker

  if (context.mounted) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: kIlluminationGold),
      ),
    );
  }

  final SpellArtBytes art;
  try {
    art = await importSpellArt(sourceBytes);
  } on SpellArtImportException catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return;
  }

  await SpellArtStore.save(spell.spellHashHex, full: art.full, thumb: art.thumb);
  await spell.withArt(hash: art.artHashHex, source: SpellArtSource.localImport).save();

  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  onReload();
}

/// Deletes [spell]'s stored art bytes and clears its art metadata, reverting
/// its card to the commitmentHex-derived coat of arms.
Future<void> _clearCustomArtOnSpell(SpellAsset spell, VoidCallback onReload) async {
  await SpellArtStore.delete(spell.spellHashHex);
  await spell.withoutArt().save();
  onReload();
}

/// Entry point for the "Set/Replace Custom Art" menu action
/// (docs/SPELL_ART_PACK_PLAN.md Phase E): offers a choice between the
/// built-in art pack and importing an image, then dispatches to whichever
/// pipeline the player picked. Replaces the old direct jump into the file
/// picker -- [_setCustomArtOnSpell] itself (the import pipeline) is
/// untouched below.
Future<void> _chooseSpellArt(
  BuildContext context,
  SpellAsset spell,
  VoidCallback onReload,
) async {
  final choice = await showModalBottomSheet<_ArtChoice>(
    context: context,
    backgroundColor: kParchmentColor,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined, color: kIlluminationGold),
            title: const Text('Choose from Art Pack'),
            onTap: () => Navigator.pop(ctx, _ArtChoice.pack),
          ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Import an Image…'),
            onTap: () => Navigator.pop(ctx, _ArtChoice.import),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case _ArtChoice.pack:
      await _choosePackArtOnSpell(context, spell, onReload);
    case _ArtChoice.import:
      await _setCustomArtOnSpell(context, spell, onReload);
  }
}

enum _ArtChoice { pack, import }

/// Runs the built-in-pack half of [_chooseSpellArt]: opens the picker
/// (docs/SPELL_ART_PACK_PLAN.md Phase E-2/E-3), and on a selection, clears
/// any previously imported blob (a pack pick supersedes it, mirroring
/// [SpellAsset.withArt]'s symmetric behaviour the other direction) and
/// stamps the pack pointer. No decode, no progress dialog, no failure path
/// -- the bytes are already canonical and already in the asset bundle.
Future<void> _choosePackArtOnSpell(
  BuildContext context,
  SpellAsset spell,
  VoidCallback onReload,
) async {
  final packId = await pickSpellArtPackIcon(
    context,
    suggestedElement: suggestedElementFor(spell.formula),
  );
  if (packId == null) return; // player backed out without choosing
  await SpellArtStore.delete(spell.spellHashHex);
  await spell.withPackArt(packId: packId).save();
  onReload();
}

/// Binds the first unbound counter charm in the chapter [chapterId] to
/// [spell]'s grid commitment. Shared by the Craftings and Tests tabs' menu
/// actions. Reports every outcome (no chapter selected, no runes to bind to,
/// already-attuned duplicate, no unbound charm, success) via a snackbar.
Future<void> _bindCounterCharmOnSpell(
  BuildContext context,
  SpellAsset spell,
  String? chapterId,
  VoidCallback onReload,
) async {
  if (chapterId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Select a chapter in the Chapters tab first.')),
    );
    return;
  }
  if (spell.commitmentHex.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This spell has no runes to attune to.')),
    );
    return;
  }

  final chapter = await ChapterAsset.loadById(chapterId);
  if (chapter == null || !context.mounted) return;

  if (chapter.artifacts.any((a) =>
      a.kind == ArtifactKind.counterCharm &&
      a.targetCommitmentHex == spell.commitmentHex)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('A charm is already attuned to these runes.')),
    );
    return;
  }

  final spellName = spell.name.isNotEmpty ? spell.name : 'Unnamed Spell';
  final updated = chapter.bindFirstUnboundCounterCharm(
    commitmentHex: spell.commitmentHex,
    spellName: spellName,
  );
  if (updated == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No unbound charms available.')),
    );
    return;
  }

  await updated.save();
  onReload();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Counter charm attuned to "$spellName".')),
    );
  }
}

const _kArtifactLabel = {
  ArtifactKind.manaGem: 'Mana Gem',
  ArtifactKind.bookmark: 'Bookmark',
  ArtifactKind.rodOfSpreading: 'Rod of Wind',
  ArtifactKind.counterCharm: 'Counter Charm',
};

const _kArtifactIcon = {
  ArtifactKind.manaGem: Icons.diamond_outlined,
  ArtifactKind.bookmark: Icons.bookmark_outlined,
  ArtifactKind.rodOfSpreading: Icons.open_in_full,
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
  final _craftingsKey = GlobalKey<_CraftingsTabState>();

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  /// Re-adds any of the five shipped Basic spells (docs/BASIC_SPELLS_PLAN.md)
  /// currently missing from the library — the counterpart to letting a
  /// player delete one and have it stay gone on a normal launch.
  Future<void> _restoreBasicSpells() async {
    final restored = await seedBasicSpells(force: true);
    _craftingsKey.currentState?._reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restored == 0
              ? 'All Basic spells are already in your grimoire.'
              : 'Restored $restored Basic spell${restored == 1 ? '' : 's'}.',
        ),
      ),
    );
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
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'restore_basics') _restoreBasicSpells();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'restore_basics',
                  child: Text('Restore basic spells'),
                ),
              ],
            ),
          ],
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
              key: _craftingsKey,
              selectedChapterId: _selectedChapterId,
              onChaptersChanged: _loadChapters,
            ),
            const _SightingsTab(),
            _LoansTab(
              selectedChapterId: _selectedChapterId,
              onChaptersChanged: _loadChapters,
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
    super.key,
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

  void _reload() => setState(() {
    _spellsFuture = SpellAsset.loadAll();
  });

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

  Future<void> _setCustomArt(SpellAsset spell) => _chooseSpellArt(context, spell, _reload);

  Future<void> _clearCustomArt(SpellAsset spell) => _clearCustomArtOnSpell(spell, _reload);

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
      final derived = deriveSupremeTags(spell);
      if (derived.isNotEmpty) {
        effectiveSpell = spell.withSupremeTags(derived.toList());
        await effectiveSpell.save();
        _reload();
      }
    }

    final chapter = await ChapterAsset.loadById(chapterId);
    if (chapter == null || !mounted) return;

    // Reject if any existing chapter entry shares the same grid commitment —
    // UNLESS this is a shipped Basic spell (docs/BASIC_SPELLS_PLAN.md), which
    // may be added any number of times.
    if (effectiveSpell.commitmentHex.isNotEmpty && !isBasicSpell(effectiveSpell)) {
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

    // design doc "Personalities": pick the battlefield-behavior glyph now,
    // at add-to-chapter time, rather than at inscription. Cancelling aborts
    // the add entirely, same as declining to name a spell used to abort
    // inscription.
    String? personality;
    if (effectiveSpell.isSummon) {
      if (!mounted) return;
      personality = await pickSummonPersonality(context, effectiveSpell.name);
      if (personality == null || !mounted) return;
    }

    final updated = chapter.withEntry(
      ChapterEntry(spellId: effectiveSpell.id, summonPersonality: personality),
    );
    await updated.save();
    widget.onChaptersChanged();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${effectiveSpell.name}" added to ${chapter.name}.')),
      );
    }
  }

  Future<void> _bindCounterCharm(SpellAsset spell) => _bindCounterCharmOnSpell(
        context,
        spell,
        widget.selectedChapterId,
        widget.onChaptersChanged,
      );

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
                onBindCounterCharm: () => _bindCounterCharm(spell),
                onSetArt: () => _setCustomArt(spell),
                onClearArt: () => _clearCustomArt(spell),
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
// spell_test_lab_screen.dart), so they're never eligible for a cast-time
// enhancement — irrelevant to adding them to a chapter either way.

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

  void _reload() => setState(() {
    _spellsFuture = _loadTestSpells();
  });

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

  Future<void> _setCustomArt(SpellAsset spell) => _chooseSpellArt(context, spell, _reload);

  Future<void> _clearCustomArt(SpellAsset spell) => _clearCustomArtOnSpell(spell, _reload);

  Future<void> _bindCounterCharm(SpellAsset spell) => _bindCounterCharmOnSpell(
        context,
        spell,
        widget.selectedChapterId,
        widget.onChaptersChanged,
      );

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

    // design doc "Personalities": only the single-spell case (the per-card
    // "add" button reusing this method, per its doc comment) prompts for a
    // personality -- a true batch "Add All" would mean one dialog per
    // summon, which isn't a reasonable flow, so those default to aggressive.
    String? singlePersonality;
    if (spells.length == 1 && spells.single.isSummon) {
      singlePersonality = await pickSummonPersonality(context, spells.single.name);
      if (singlePersonality == null || !mounted) return;
    }

    final allSpells = await SpellAsset.loadAll();
    final byId = {for (final s in allSpells) s.id: s};
    final seenCommitments = chapter.entries
        .map((e) => byId[e.spellId]?.commitmentHex)
        .whereType<String>()
        .toSet();

    var added = 0;
    var skipped = 0;
    for (final spell in spells) {
      if (spell.commitmentHex.isNotEmpty &&
          seenCommitments.contains(spell.commitmentHex) &&
          !isBasicSpell(spell)) {
        skipped++;
        continue;
      }
      chapter = chapter!.withEntry(ChapterEntry(
        spellId: spell.id,
        summonPersonality: spell.isSummon
            ? (singlePersonality ?? SummonPersonality.aggressive.name)
            : null,
      ));
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
                onBindCounterCharm: () => _bindCounterCharm(spell),
                onSetArt: () => _setCustomArt(spell),
                onClearArt: () => _clearCustomArt(spell),
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
    required this.onBindCounterCharm,
    required this.onView,
    required this.onSetArt,
    required this.onClearArt,
    this.wizardName,
    this.creatorKeyBytes,
  });

  final SpellAsset spell;
  final int kinSiblings;
  final VoidCallback onDelete;
  final VoidCallback onAddToChapter;
  final VoidCallback onBindCounterCharm;
  final VoidCallback onView;
  final VoidCallback onSetArt;
  final VoidCallback onClearArt;
  final String? wizardName;
  final Uint8List? creatorKeyBytes;

  bool get _isKin => kinSiblings > 1;

  /// True for one of the five shipped starter spells (docs/BASIC_SPELLS_PLAN.md).
  /// These ship with every install under a dev owner_pubkey that is NOT this
  /// player's — the creator sigil (below) would otherwise falsely imply the
  /// player inscribed it, so it's suppressed and replaced with a plain label.
  bool get _isBasic => isBasicSpell(spell);

  String get _displayName =>
      spell.name.isNotEmpty ? spell.name : 'Unnamed Spell';

  String get _meta => 'Gen ${spell.t}  ·  ♦ ${spell.manaCost}';

  String get _formulaText {
    if (spell.formula.isEmpty) return '';
    if (spell.isSummon) return summonSummaryFromFormula(spell.formula) ?? '';
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
    } else if (action == 'bind_charm') {
      onBindCounterCharm();
    } else if (action == 'set_art') {
      onSetArt();
    } else if (action == 'clear_art') {
      onClearArt();
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
              child: Stack(
                children: [
                  SpellCardWidget(spell: spell, size: 84),
                  if (spell.isSummon)
                    const Positioned(right: 3, bottom: 3, child: _SummonBadge()),
                ],
              ),
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
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'view', child: Text('View')),
                            const PopupMenuItem(value: 'add', child: Text('Add to Chapter')),
                            const PopupMenuItem(
                              value: 'bind_charm',
                              child: Text('Bind to Counter Charm'),
                            ),
                            PopupMenuItem(
                              value: 'set_art',
                              child: Text(spell.artHash == null
                                  ? 'Set Custom Art'
                                  : 'Replace Custom Art'),
                            ),
                            if (spell.artHash != null)
                              const PopupMenuItem(
                                value: 'clear_art',
                                child: Text('Revert to Coat of Arms'),
                              ),
                            const PopupMenuItem(value: 'delete', child: Text('Delete Spell')),
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
                    if (_isBasic) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome_outlined,
                            size: 14,
                            color: kIlluminationGold.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Basic starter spell',
                            style: manuscriptCaptionStyle(
                              color: kInkColor.withValues(alpha: 0.6),
                            ).copyWith(fontStyle: FontStyle.normal),
                          ),
                        ],
                      ),
                    ] else if (creatorKeyBytes != null ||
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

/// Small corner marker distinguishing a summon-mode spell card from an
/// incantation one at a glance (design doc "Summons").
class _SummonBadge extends StatelessWidget {
  const _SummonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: kIlluminationGold.withValues(alpha: 0.7), width: 0.5),
      ),
      child: const Icon(Icons.pets, size: 10, color: kIlluminationGold),
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

    final updated = _chapter.withArtifact(ArtifactEntry(kind: kind));
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

  // For counterCharm, only ever removes an *unbound* charm — a bound charm
  // is removed exclusively via _removeCounterCharm (with its own confirm
  // dialog naming the attuned spell), never by this generic +/- control.
  Future<void> _decrementArtifact(ArtifactKind kind) async {
    final idx = kind == ArtifactKind.counterCharm
        ? _chapter.artifacts.lastIndexWhere((a) => a.isUnboundCounterCharm)
        : _chapter.artifacts.lastIndexWhere((a) => a.kind == kind);
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
    // Group non-CC artifacts by kind; collect bound-CC indices for individual
    // display (unbound CCs are shown as a single grouped count tile, same as
    // the other kinds).
    final kindCounts = <ArtifactKind, int>{};
    final boundCharmIndices = <int>[];
    for (int i = 0; i < _chapter.artifacts.length; i++) {
      final a = _chapter.artifacts[i];
      if (a.kind == ArtifactKind.counterCharm) {
        if (a.targetCommitmentHex != null) boundCharmIndices.add(i);
      } else {
        kindCounts[a.kind] = (kindCounts[a.kind] ?? 0) + 1;
      }
    }
    final unboundCharmCount = _chapter.unboundCounterCharmCount;

    const groupedKinds = [
      ArtifactKind.manaGem,
      ArtifactKind.bookmark,
      ArtifactKind.rodOfSpreading,
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
        if (unboundCharmCount > 0)
          _ArtifactGroupTile(
            kind: ArtifactKind.counterCharm,
            count: unboundCharmCount,
            canIncrement: slotsRemaining > 0,
            onDecrement: () => _decrementArtifact(ArtifactKind.counterCharm),
            onIncrement: () => _incrementArtifact(ArtifactKind.counterCharm),
          ),
        for (final idx in boundCharmIndices)
          _CounterCharmTile(
            artifact: _chapter.artifacts[idx],
            onRemove: () => _removeCounterCharm(idx),
          ),
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
    final spellForCard = spell;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onLongPress: spellForCard == null
            ? null
            : () => showSpellCardFullscreen(context, spellForCard),
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
              icon: Icons.open_in_full,
              label: 'Rod of Wind',
              description: 'Single use: +1 effect radius (or +1 minion size) on your next spell',
              onTap: () => Navigator.pop(context, ArtifactKind.rodOfSpreading),
            ),
            _ArtifactOption(
              icon: Icons.block,
              label: 'Counter Charm',
              description:
                  'Bind it to a spell later, from that spell\'s menu in your library',
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

// ── Summon personality dialog (shared) ────────────────────────────────────────
//
// design doc "Personalities": the battlefield-behavior glyph a summon spell
// fights with is now chosen here, when the spell is added to a Chapter --
// not at inscription (see main.dart's _SpellNameDialog, which used to own
// this picker). Shared by the Craftings and Loans tabs' _addToChapter and
// the Tests tab's _addAllToChapter (single-spell case only).

/// Shows the personality picker for [spellName] and returns the chosen
/// SummonPersonality's enum name, or null if the player cancelled (callers
/// should abort the add-to-chapter entirely in that case, same as declining
/// to name a spell used to abort inscription).
Future<String?> pickSummonPersonality(BuildContext context, String spellName) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SummonPersonalityDialog(spellName: spellName),
  );
}

class _SummonPersonalityDialog extends StatefulWidget {
  const _SummonPersonalityDialog({required this.spellName});

  final String spellName;

  @override
  State<_SummonPersonalityDialog> createState() => _SummonPersonalityDialogState();
}

class _SummonPersonalityDialogState extends State<_SummonPersonalityDialog> {
  SummonPersonality _personality = SummonPersonality.aggressive;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Personality for "${widget.spellName}"'),
      content: Wrap(
        spacing: 6,
        runSpacing: 6,
        // obedient is excluded here: it's a seam only this pass (no
        // manual-control UI exists yet) — see SummonPersonality.obedient's
        // doc comment. Don't let it be picked until that's built.
        children: SummonPersonality.values
            .where((p) => p != SummonPersonality.obedient)
            .map((p) {
          return ChoiceChip(
            label: Text(kSummonPersonalityLabel[p]!),
            selected: _personality == p,
            onSelected: (_) => setState(() => _personality = p),
          );
        }).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_personality.name),
          child: const Text('Add to Chapter'),
        ),
      ],
    );
  }
}

// ── Loans tab ────────────────────────────────────────────────────────────────
//
// Spells another wizard has loaned to this identity via Commune/Trade
// (docs/COMMUNE_TRADE_PLAN.md). Each entry is a SpellAsset with
// [SpellAsset.gridWithheld] set -- the grid was never sent, only proof
// bytes and a day-limited SpellPermission grant -- so this list intentionally
// cannot show a thumbnail derived from the grid, only name/cost/expiry.
// A lightweight tile list, not the full _SpellCard: art/kin/supreme-tag
// features on that widget assume a locally-inscribed, fully-owned spell,
// none of which applies to a loan.

class _LoanEntry {
  const _LoanEntry({required this.spell, required this.permission});
  final SpellAsset spell;
  final SpellPermission permission;
}

bool _loanHexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

class _LoansTab extends StatefulWidget {
  const _LoansTab({required this.selectedChapterId, required this.onChaptersChanged});

  final String? selectedChapterId;
  final VoidCallback onChaptersChanged;

  @override
  State<_LoansTab> createState() => _LoansTabState();
}

class _LoansTabState extends State<_LoansTab> with AutomaticKeepAliveClientMixin {
  late Future<List<_LoanEntry>> _loansFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loansFuture = _loadUsableLoans();
  }

  Future<List<_LoanEntry>> _loadUsableLoans() async {
    final identity = await Identity.loadOrCreate();
    final myPubkeyHex = await identity.ownerPubkeyHex();
    final all = await SpellAsset.loadAll();
    final entries = <_LoanEntry>[];
    for (final spell in all.where((s) => s.gridWithheld)) {
      final perms = await SpellPermission.loadForCommitment(spell.commitmentHex);
      for (final perm in perms) {
        if (perm.kind != SpellGrantKind.loan) continue;
        if (!_loanHexEq(perm.granteePubkeyHex, myPubkeyHex)) continue;
        if (!await perm.isCurrentlyUsable()) continue;
        entries.add(_LoanEntry(spell: spell, permission: perm));
        break;
      }
    }
    return entries;
  }

  void _reload() => setState(() {
    _loansFuture = _loadUsableLoans();
  });

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
    final chapter = await ChapterAsset.loadById(chapterId);
    if (chapter == null || !mounted) return;
    if (chapter.entries.any((e) => e.spellId == spell.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in this chapter.')),
      );
      return;
    }
    // design doc "Personalities": pick the battlefield-behavior glyph now,
    // at add-to-chapter time, rather than at inscription.
    String? personality;
    if (spell.isSummon) {
      personality = await pickSummonPersonality(context, spell.name);
      if (personality == null || !mounted) return;
    }
    final updated = chapter.withEntry(
      ChapterEntry(spellId: spell.id, summonPersonality: personality),
    );
    await updated.save();
    widget.onChaptersChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${spell.name}" added to ${chapter.name}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<_LoanEntry>>(
      future: _loansFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kIlluminationGold));
        }
        final entries = snap.data ?? [];
        if (entries.isEmpty) {
          return const _EmptyBody(
            icon: Icons.handshake_outlined,
            message: 'Spells leased to you by other wizards will appear here.\n'
                'They are bound to your Runekey, and you may add them to chapters and cast them in battle, '
                'but you may not view their workings nor lend them to others yourself.\n'
                'Loans expire with time unless renewed.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: entries.length,
            itemBuilder: (_, i) => _LoanTile(entry: entries[i], onAddToChapter: () => _addToChapter(entries[i].spell)),
          ),
        );
      },
    );
  }
}

class _LoanTile extends StatelessWidget {
  const _LoanTile({required this.entry, required this.onAddToChapter});
  final _LoanEntry entry;
  final VoidCallback onAddToChapter;

  String get _daysRemaining {
    final remaining = entry.permission.expiresAt!.difference(DateTime.now().toUtc());
    if (remaining.inDays <= 0) return 'expires today';
    return '${remaining.inDays}d remaining';
  }

  String get _lenderLabel {
    final hex = entry.permission.ownerPubkeyHex;
    final trimmed = hex.startsWith('0x') ? hex.substring(2) : hex;
    return trimmed.length > 8 ? '0x${trimmed.substring(0, 8)}…' : hex;
  }

  @override
  Widget build(BuildContext context) {
    final name = entry.spell.name.isNotEmpty ? entry.spell.name : 'Unnamed Spell';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        border: Border.all(color: kInkColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.handshake_outlined, size: 22, color: kIlluminationGold),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontFamily: 'serif', fontSize: 15, color: kInkColor)),
                const SizedBox(height: 2),
                Text(
                  'Loaned by $_lenderLabel  ·  ♦ ${entry.spell.manaCost}  ·  $_daysRemaining',
                  style: manuscriptCaptionStyle(),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onAddToChapter,
            child: Text('Add', style: manuscriptCaptionStyle(color: kIlluminationGold)),
          ),
        ],
      ),
    );
  }
}

// ── Sightings tab ────────────────────────────────────────────────────────────
//
// Read-only (SIGHTINGS_PLAN.md §1.2): spells sighted cast against the player
// in a real LAN duel, grouped by opponent. No gameplay hooks, no delete-spell
// / add-to-chapter / custom-art actions — those apply to the player's own
// library, not to what they've observed of someone else's.

class _SightingsTab extends StatefulWidget {
  const _SightingsTab();

  @override
  State<_SightingsTab> createState() => _SightingsTabState();
}

class _SightingsTabState extends State<_SightingsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late Future<List<SightingAsset>> _sightingsFuture;

  @override
  void initState() {
    super.initState();
    _sightingsFuture = SightingAsset.loadAll();
  }

  void _reload() => setState(() {
    _sightingsFuture = SightingAsset.loadAll();
  });

  /// Groups by opponent, each opponent's spells sorted most-recent first.
  Map<String, List<SightingAsset>> _groupByOpponent(List<SightingAsset> all) {
    final grouped = <String, List<SightingAsset>>{};
    for (final s in all) {
      grouped.putIfAbsent(s.opponentPubkeyHex, () => []).add(s);
    }
    for (final spells in grouped.values) {
      spells.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<SightingAsset>>(
      future: _sightingsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: kIlluminationGold),
          );
        }
        if (snap.hasError) {
          return _ErrorBody(
            message: 'Could not load your sightings.\n${snap.error}',
            onRetry: _reload,
          );
        }
        final all = snap.data ?? [];
        if (all.isEmpty) {
          return const _EmptyBody(
            icon: Icons.visibility_outlined,
            message: 'No spells sighted yet.\n'
                'Spells cast against you in a duel will be recorded here.',
          );
        }
        final grouped = _groupByOpponent(all);
        // Most-recent opponent first, using each opponent's own already-sorted
        // (most-recent-first) spell list.
        final opponents = grouped.keys.toList()
          ..sort((a, b) => grouped[b]!.first.lastSeen.compareTo(grouped[a]!.first.lastSeen));

        return RefreshIndicator(
          color: kIlluminationGold,
          backgroundColor: kParchmentColor,
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: opponents.length,
            itemBuilder: (context, i) {
              final opponentPubkeyHex = opponents[i];
              return _OpponentSection(
                opponentPubkeyHex: opponentPubkeyHex,
                sightings: grouped[opponentPubkeyHex]!,
              );
            },
          ),
        );
      },
    );
  }
}

class _OpponentSection extends StatelessWidget {
  const _OpponentSection({required this.opponentPubkeyHex, required this.sightings});

  final String opponentPubkeyHex;
  final List<SightingAsset> sightings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _OpponentHeader(
            opponentPubkeyHex: opponentPubkeyHex,
            opponentName: sightings.first.opponentName,
            spellCount: sightings.length,
          ),
          const SizedBox(height: 8),
          for (final sighting in sightings) _SightingCard(sighting: sighting),
        ],
      ),
    );
  }
}

/// Identity triad header (SIGHTINGS_PLAN.md §2/§5): sigil first, then the
/// wizard name if one is known (nullable — no authenticated name reaches
/// BattleScreen yet), then always the pubkey fingerprint. The fingerprint is
/// the thing that actually disambiguates two same-named wizards, so it's
/// never hidden even when a name is shown, and the name is styled no larger
/// than it — the viewer should trust the sigil/pubkey, not the name.
class _OpponentHeader extends StatelessWidget {
  const _OpponentHeader({
    required this.opponentPubkeyHex,
    required this.opponentName,
    required this.spellCount,
  });

  final String opponentPubkeyHex;
  final String? opponentName;
  final int spellCount;

  String get _fingerprint {
    final trimmed =
        opponentPubkeyHex.startsWith('0x') ? opponentPubkeyHex.substring(2) : opponentPubkeyHex;
    return trimmed.length > 8 ? '0x${trimmed.substring(0, 8)}…' : opponentPubkeyHex;
  }

  String get _spellCountLabel => '$spellCount spell${spellCount == 1 ? '' : 's'} sighted';

  void _copyFullKey(BuildContext context) {
    Clipboard.setData(ClipboardData(text: opponentPubkeyHex));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Runekey copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = opponentName;
    final hasName = name != null && name.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SigilWidget(
          keyBytes: fieldHexToLeBytes(opponentPubkeyHex, 32),
          size: 36,
          saturation: 2.5,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasName ? name : _fingerprint,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              GestureDetector(
                onLongPress: () => _copyFullKey(context),
                child: Text(
                  hasName ? '$_fingerprint  ·  $_spellCountLabel' : _spellCountLabel,
                  style: manuscriptCaptionStyle(color: kInkColor.withValues(alpha: 0.6)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact, read-only spell card (SIGHTINGS_PLAN.md §5) — no menu, no
/// delete/add-to-chapter/art actions. Reuses [SpellCardWidget] and
/// [formulaEffectLabels] via [SightingAsset.toDisplaySpell] so it renders
/// identically to an owned [_SpellCard] apart from those actions. Shows
/// mana cost (the certified BASE cost, §2/§3) alongside the generation
/// count, same `♦` convention as [_SpellCard]/[_LoanTile].
class _SightingCard extends StatelessWidget {
  const _SightingCard({required this.sighting});

  final SightingAsset sighting;

  String get _displayName =>
      sighting.spellName.isNotEmpty ? sighting.spellName : 'Unnamed Spell';

  String get _meta => 'Gen ${sighting.t}  ·  ♦ ${sighting.manaCost}';

  String get _formulaText {
    if (sighting.formula.isEmpty) return '';
    final labels = formulaEffectLabels(sighting.formula);
    if (labels.isEmpty) return '';
    return labels.join('  ·  ');
  }

  String get _lastSeenText {
    final d = sighting.lastSeen.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Last seen ${months[d.month - 1]} ${d.day}, ${d.year}  ·  '
        'seen ×${sighting.timesSeen}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 46),
      child: Container(
        decoration: BoxDecoration(
          color: kParchmentPanelColor,
          border: Border.all(color: kInkColor.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(3),
                bottomLeft: Radius.circular(3),
              ),
              child: SpellCardWidget(spell: sighting.toDisplaySpell(), size: 84),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayName,
                      style: const TextStyle(
                        fontFamily: 'serif',
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: kInkColor,
                        letterSpacing: 0.5,
                      ),
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
                    Text(_lastSeenText, style: manuscriptCaptionStyle()),
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
