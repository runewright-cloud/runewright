// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_pack_screen.dart — lets a player choose a built-in clip for a
// spell's resolution sound instead of importing their own, mirroring
// spell_art_pack_screen.dart's picker (filter by element/subject, preview
// before committing). Only 'spell'-category clips are offered here --
// 'ambient' entries are not a spell's own sound (spell_sound_pack.dart).
// Tapping a tile plays it; the preview dialog offers a replay button since
// there's no static thumbnail to look at.

import 'package:flutter/material.dart';

import '../audio/spell_sound_player.dart';
import '../audio/spell_sound_settings.dart';
import '../spells/spell_sound_pack.dart';
import 'about_screen.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

// Mirrors spell_art_pack_screen.dart's private elemental palette -- kept as
// a separate copy for the same reason that file's comment gives: each picker
// screen owns its own small copy rather than sharing private widgets/consts
// across files with independent lifecycles.
const _kFireColor = Color(0xFFB84040);
const _kAirColor = Color(0xFF6E93B8);
const _kWaterColor = Color(0xFF2B4D8C);
const _kEarthColor = Color(0xFF8B6228);

const List<String> _kElements = ['fire', 'air', 'water', 'earth'];

Color _elementColor(String? element) => switch (element) {
      'fire' => _kFireColor,
      'air' => _kAirColor,
      'water' => _kWaterColor,
      'earth' => _kEarthColor,
      _ => kIlluminationGold,
    };

String _elementLabel(String? element) => switch (element) {
      'fire' => 'Fire',
      'air' => 'Air',
      'water' => 'Water',
      'earth' => 'Earth',
      _ => 'All',
    };

/// Pushes [SpellSoundPackScreen] and returns the chosen
/// [SpellSoundPackEntry.id], or null if the player backed out without
/// choosing.
Future<String?> pickSpellSoundPackClip(BuildContext context, {String? suggestedElement}) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => SpellSoundPackScreen(suggestedElement: suggestedElement)),
  );
}

class SpellSoundPackScreen extends StatefulWidget {
  const SpellSoundPackScreen({super.key, this.suggestedElement});

  /// Pre-selects this element's filter chip on open. Null opens on "All".
  final String? suggestedElement;

  @override
  State<SpellSoundPackScreen> createState() => _SpellSoundPackScreenState();
}

class _SpellSoundPackScreenState extends State<SpellSoundPackScreen> {
  String? _element;
  String? _subject;
  final _player = SpellSoundPlayer(poolSize: 1);
  SpellSoundSettings _settings = const SpellSoundSettings();

  static final List<SpellSoundPackEntry> _clips =
      kSpellSoundPack.where((e) => e.category == 'spell').toList();
  static final List<String> _subjects = {for (final e in _clips) e.subject}.toList()..sort();

  @override
  void initState() {
    super.initState();
    _element = widget.suggestedElement;
    // Best-effort: preview playback respects the player's saved volume/mute
    // once loaded, but a preview shown before that resolves is better than
    // one that blocks on it.
    SpellSoundSettings.load().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  List<SpellSoundPackEntry> get _filtered => _clips
      .where((e) => _element == null || e.element == _element)
      .where((e) => _subject == null || e.subject == _subject)
      .toList();

  Future<void> _play(SpellSoundPackEntry entry) async {
    final bytes = await loadPackSound(entry.id);
    if (bytes == null) return;
    // Pack clips are loudness-normalized at build time (kSpellSoundLicence
    // .modifications) -- same treatment resolveSpellSound's real playback
    // gives them.
    await _player.play(bytes, settings: _settings, normalized: true);
  }

  Future<void> _openPreview(SpellSoundPackEntry entry) async {
    final chosen = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SoundPreviewDialog(entry: entry, onPlay: () => _play(entry)),
    );
    if (chosen == true && mounted) {
      Navigator.pop(context, entry.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kParchmentColor,
        foregroundColor: kInkColor,
        elevation: 0,
        title: Text('Choose Sound', style: manuscriptHeaderStyle(fontSize: 20)),
      ),
      body: SafeScreenBody(
        child: Column(
          children: [
            _ElementFilterRow(
              selected: _element,
              onSelected: (e) => setState(() => _element = e),
            ),
            _SubjectFilterRow(
              subjects: _subjects,
              selected: _subject,
              onChanged: (s) => setState(() => _subject = s),
            ),
            const Divider(height: 1, color: kParchmentPanelColor),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'No clips match this filter.',
                        style: manuscriptBodyStyle(color: kInkMutedColor),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        return _SoundTile(
                          entry: entry,
                          onPlay: () => _play(entry),
                          onTap: () => _openPreview(entry),
                        );
                      },
                    ),
            ),
            _AttributionFooter(),
          ],
        ),
      ),
    );
  }
}

class _ElementFilterRow extends StatelessWidget {
  const _ElementFilterRow({required this.selected, required this.onSelected});

  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final options = <String?>[null, ..._kElements];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final option = options[i];
          final isSelected = option == selected;
          final color = _elementColor(option);
          return ChoiceChip(
            label: Text(_elementLabel(option)),
            selected: isSelected,
            onSelected: (_) => onSelected(option),
            selectedColor: color.withValues(alpha: 0.22),
            backgroundColor: kParchmentPanelColor,
            side: BorderSide(color: isSelected ? color : kInkMutedColor.withValues(alpha: 0.4)),
            labelStyle: TextStyle(
              fontFamily: 'serif',
              color: isSelected ? color : kInkColor,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          );
        },
      ),
    );
  }
}

class _SubjectFilterRow extends StatelessWidget {
  const _SubjectFilterRow({
    required this.subjects,
    required this.selected,
    required this.onChanged,
  });

  final List<String> subjects;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text('Subject: ', style: manuscriptCaptionStyle(color: kInkColor)),
          Expanded(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: selected,
              underline: Container(height: 1, color: kInkMutedColor.withValues(alpha: 0.4)),
              style: manuscriptBodyStyle(fontSize: 14),
              items: [
                const DropdownMenuItem(value: null, child: Text('All')),
                for (final s in subjects) DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _SoundTile extends StatelessWidget {
  const _SoundTile({required this.entry, required this.onPlay, required this.onTap});

  final SpellSoundPackEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _elementColor(entry.element);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow),
              color: color,
              onPressed: onPlay,
              tooltip: 'Play',
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.subject, style: manuscriptBodyStyle(fontSize: 14)),
                  Text(
                    '${_elementLabel(entry.element)} · ${(entry.durationMs / 1000).toStringAsFixed(1)}s',
                    style: manuscriptCaptionStyle(color: kInkMutedColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoundPreviewDialog extends StatelessWidget {
  const _SoundPreviewDialog({required this.entry, required this.onPlay});

  final SpellSoundPackEntry entry;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final color = _elementColor(entry.element);
    return Dialog(
      backgroundColor: kParchmentColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 56,
              icon: const Icon(Icons.play_circle_fill),
              color: color,
              onPressed: onPlay,
              tooltip: 'Play',
            ),
            Text(entry.subject, style: manuscriptBodyStyle(fontSize: 15)),
            const SizedBox(height: 4),
            Text(_elementLabel(entry.element), style: manuscriptCaptionStyle(color: color)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Cancel', style: manuscriptBodyStyle(color: kInkMutedColor)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('Choose',
                      style: manuscriptBodyStyle(color: kIlluminationGold)
                          .copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Persistent attribution line -- CC BY-SA 4.0 §3(a) requires attribution;
/// mirrors spell_art_pack_screen.dart's footer for the sound pack's licence.
class _AttributionFooter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AboutScreen(initialTab: 1)),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: kParchmentPanelColor,
        child: Text(
          '${kSpellSoundLicence.name} by ${kSpellSoundLicence.author}, '
          '${kSpellSoundLicence.licence} — adapted. Tap for full credits.',
          style: manuscriptCaptionStyle(color: kInkMutedColor),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
