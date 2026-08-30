// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_pack_screen.dart — lets a player choose a built-in icon for a
// spell's card art instead of importing their own image
// (docs/SPELL_ART_PACK_PLAN.md Phase E). Filters by element (defaulting to
// whatever the spell's own formula suggests) and subject; tapping a tile
// opens a preview before committing. Purely a picker over the already-built
// asset pack (lib/spells/spell_art_pack.dart) -- it never decodes anything
// player-supplied, so unlike spell_art_import.dart there is no hostile-bytes
// handling, no isolate hop, no failure path to report.

import 'package:flutter/material.dart';

import '../spells/spell_art_pack.dart';
import 'about_screen.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';

// Mirrors spell_card_painter.dart's private elemental palette -- kept as a
// separate copy rather than exported from there, since that file's palette
// is scoped to card-ring rendering and this is a different screen with its
// own lifecycle.
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

/// The element (fire/air/water/earth) occurring most often in [formula], or
/// null if [formula] is empty or names no recognised element -- used to seed
/// the picker's element filter with a sensible default rather than always
/// opening on "All".
String? suggestedElementFor(List<String> formula) {
  final counts = <String, int>{};
  for (final raw in formula) {
    final e = raw.toLowerCase();
    if (_kElements.contains(e)) counts[e] = (counts[e] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return sorted.first.key;
}

/// Pushes [SpellArtPackScreen] and returns the chosen [SpellArtPackEntry.id],
/// or null if the player backed out without choosing.
Future<String?> pickSpellArtPackIcon(BuildContext context, {String? suggestedElement}) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => SpellArtPackScreen(suggestedElement: suggestedElement)),
  );
}

class SpellArtPackScreen extends StatefulWidget {
  const SpellArtPackScreen({super.key, this.suggestedElement});

  /// Pre-selects this element's filter chip on open (see
  /// [suggestedElementFor]). Null opens on "All".
  final String? suggestedElement;

  @override
  State<SpellArtPackScreen> createState() => _SpellArtPackScreenState();
}

class _SpellArtPackScreenState extends State<SpellArtPackScreen> {
  String? _element;
  String? _subject;

  static final List<String> _subjects = {for (final e in kPainterlyPack) e.subject}.toList()
    ..sort();

  @override
  void initState() {
    super.initState();
    _element = widget.suggestedElement;
  }

  List<SpellArtPackEntry> get _filtered => kPainterlyPack
      .where((e) => _element == null || e.element == _element)
      .where((e) => _subject == null || e.subject == _subject)
      .toList();

  Future<void> _openPreview(SpellArtPackEntry entry) async {
    final chosen = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ArtPreviewDialog(entry: entry),
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
        title: Text('Choose Art', style: manuscriptHeaderStyle(fontSize: 20)),
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
                        'No icons match this filter.',
                        style: manuscriptBodyStyle(color: kInkMutedColor),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        return _ArtTile(entry: entry, onTap: () => _openPreview(entry));
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

class _ArtTile extends StatelessWidget {
  const _ArtTile({required this.entry, required this.onTap});

  final SpellArtPackEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: _elementColor(entry.element).withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        // cacheWidth bounds the decoded pixel buffer per tile so a grid of
        // hundreds of 256px source icons doesn't hold hundreds of full-size
        // decoded bitmaps in memory at once (plan §7 E-2).
        child: Image.asset(entry.asset, fit: BoxFit.cover, cacheWidth: 128),
      ),
    );
  }
}

class _ArtPreviewDialog extends StatelessWidget {
  const _ArtPreviewDialog({required this.entry});

  final SpellArtPackEntry entry;

  @override
  Widget build(BuildContext context) {
    final colourLabel = entry.colour == null ? entry.subject : '${entry.subject} · ${entry.colour}';
    return Dialog(
      backgroundColor: kParchmentColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(entry.asset, width: 220, height: 220, fit: BoxFit.cover),
            ),
            const SizedBox(height: 12),
            Text(colourLabel, style: manuscriptBodyStyle(fontSize: 15)),
            const SizedBox(height: 4),
            Text(_elementLabel(entry.element),
                style: manuscriptCaptionStyle(color: _elementColor(entry.element))),
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
/// this is the contextual pointer, the About screen's Credits tab (pushed
/// on tap) is the full resource. Never hardcodes the licence text -- reads from
/// [kPainterlyLicence] so a future licence change (docs/SPELL_ART_PACK_PLAN.md
/// D-1) is a generator change plus a regeneration, not a UI edit.
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
          '${kPainterlyLicence.name} by ${_authorName(kPainterlyLicence.author)}, '
          '${kPainterlyLicence.licence} — modified. Tap for full credits.',
          style: manuscriptCaptionStyle(color: kInkMutedColor),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// The attribution string is "Full Name (handle) -- url ..."; this keeps
/// only the leading name/handle for the compact footer line, matching the
/// plan's example text ("by J.W. Bjerk (eleazzaar)").
String _authorName(String attribution) {
  final dashIndex = attribution.indexOf('--');
  return (dashIndex == -1 ? attribution : attribution.substring(0, dashIndex)).trim();
}
