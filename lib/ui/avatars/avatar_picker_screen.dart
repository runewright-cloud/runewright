// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_picker_screen.dart — lets a player browse the shipped avatar pack
// (docs/AVATAR_PICKER_PLAN.md Phase 5.3) and choose the sprite their wizard
// wears on the battlefield. Mirrors lib/ui/spell_art_pack_screen.dart, this
// repo's established pattern for "browse a built-in asset pack and return an
// id": a Future<String?> push helper, category filter chips, and a
// tap-to-preview dialog before committing. Purely a picker over the
// already-built pack — no hostile bytes, no failure path.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../manuscript_theme.dart';
import 'avatar_sprites.dart';
import '../safe_layout.dart';

/// Pushes [AvatarPickerScreen] and returns the chosen [AvatarArt.id], or null
/// if the player backed out without choosing.
Future<String?> pickAvatar(BuildContext context, {String? currentAvatarId}) {
  return Navigator.push<String>(
    context,
    MaterialPageRoute(
      builder: (_) => AvatarPickerScreen(currentAvatarId: currentAvatarId),
    ),
  );
}

class AvatarPickerScreen extends StatefulWidget {
  const AvatarPickerScreen({
    super.key,
    this.currentAvatarId,
    @visibleForTesting this.portraitAtlas,
    @visibleForTesting this.spriteAtlas,
  });

  /// The player's currently-saved avatar id, if any — pre-selects that tile.
  final String? currentAvatarId;

  /// Test-only injected atlases, so a widget test can drive the real layout
  /// with a fake image instead of decoding the shipped asset (`rootBundle` is
  /// unavailable outside a real app — see wizard_movement_preview_test.dart).
  /// Null in production, where the screen decodes the shipped atlases itself.
  final ui.Image? portraitAtlas;
  final ui.Image? spriteAtlas;

  @override
  State<AvatarPickerScreen> createState() => _AvatarPickerScreenState();
}

class _AvatarPickerScreenState extends State<AvatarPickerScreen> {
  AvatarCategory? _category;
  ui.Image? _portraitAtlas;
  ui.Image? _spriteAtlas;

  @override
  void initState() {
    super.initState();
    _portraitAtlas = widget.portraitAtlas;
    _spriteAtlas = widget.spriteAtlas;
    if (_portraitAtlas == null) {
      AvatarPortraitAtlas.load().then((image) {
        if (mounted) setState(() => _portraitAtlas = image);
      }).catchError((Object e) {
        debugPrint('avatars: portrait atlas load failed — $e');
      });
    }
    if (_spriteAtlas == null) {
      AvatarAtlas.load().then((image) {
        if (mounted) setState(() => _spriteAtlas = image);
      }).catchError((Object e) {
        debugPrint('avatars: sprite atlas load failed — $e');
      });
    }
  }

  List<AvatarArt> get _filtered => selectableAvatars
      .where((a) => _category == null || a.category == _category)
      .toList();

  Future<void> _openPreview(AvatarArt art) async {
    final chosen = await showDialog<bool>(
      context: context,
      builder: (ctx) => _AvatarPreviewDialog(
        art: art,
        portraitAtlas: _portraitAtlas,
        spriteAtlas: _spriteAtlas,
      ),
    );
    if (chosen == true && mounted) {
      Navigator.pop(context, art.id);
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
        title: Text('Choose Avatar', style: manuscriptHeaderStyle(fontSize: 20)),
      ),
      body: SafeScreenBody(
        child: Column(
          children: [
            _CategoryFilterRow(
              selected: _category,
              onSelected: (c) => setState(() => _category = c),
            ),
            const Divider(height: 1, color: kParchmentPanelColor),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'No avatars match this filter.',
                        style: manuscriptBodyStyle(color: kInkMutedColor),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final art = entries[i];
                        return _AvatarTile(
                          art: art,
                          atlas: _portraitAtlas,
                          selected: art.id == widget.currentAvatarId,
                          onTap: () => _openPreview(art),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryFilterRow extends StatelessWidget {
  const _CategoryFilterRow({required this.selected, required this.onSelected});

  final AvatarCategory? selected;
  final ValueChanged<AvatarCategory?> onSelected;

  static const List<AvatarCategory?> _options = [
    null,
    AvatarCategory.heroes,
    AvatarCategory.monsters,
    AvatarCategory.npc,
  ];

  static String _label(AvatarCategory? c) => switch (c) {
        null => 'All',
        AvatarCategory.heroes => 'Heroes',
        AvatarCategory.monsters => 'Monsters',
        AvatarCategory.npc => 'NPCs',
      };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final option = _options[i];
          final isSelected = option == selected;
          return ChoiceChip(
            label: Text(_label(option)),
            selected: isSelected,
            onSelected: (_) => onSelected(option),
            selectedColor: kIlluminationGold.withValues(alpha: 0.22),
            backgroundColor: kParchmentPanelColor,
            side: BorderSide(
              color: isSelected ? kIlluminationGold : kInkMutedColor.withValues(alpha: 0.4),
            ),
            labelStyle: TextStyle(
              fontFamily: 'serif',
              color: isSelected ? kIlluminationGold : kInkColor,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          );
        },
      ),
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.art,
    required this.atlas,
    required this.selected,
    required this.onTap,
  });

  final AvatarArt art;
  final ui.Image? atlas;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? kIlluminationGold : kInkMutedColor.withValues(alpha: 0.4),
                  width: selected ? 3 : 1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              // SizedBox.expand, not a bare CustomPaint: a childless
              // CustomPaint takes `constraints.smallest`, and the Column above
              // (crossAxisAlignment.center by default) passes a LOOSE width
              // down — so a bare one lays out 0 px wide and the portrait
              // silently never appears, while the border and the name caption
              // still render normally.
              child: atlas != null
                  ? SizedBox.expand(
                      child: CustomPaint(
                        painter: _AtlasRectPainter(atlas: atlas!, rect: art.portraitRect),
                      ),
                    )
                  : _placeholder(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            art.name,
            style: manuscriptCaptionStyle(color: kInkColor),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Never lets a missing/undecoded atlas throw — a neutral placeholder card
/// instead, matching [AvatarAtlas.imageOrNull]'s "null means draw a
/// placeholder" contract. Deliberately does NOT repeat the avatar's name —
/// every caller already places a name label directly beside this widget.
Widget _placeholder() => Container(
      color: kParchmentPanelColor,
      alignment: Alignment.center,
      child: Icon(Icons.person_outline, color: kInkMutedColor.withValues(alpha: 0.6)),
    );

/// Draws one atlas source rect into the destination — shared by portrait
/// tiles, the preview portrait, and the preview's walk-sprite strip. This is
/// indexed pixel art, so no smoothing: [FilterQuality.none] +
/// `isAntiAlias = false`, matching how the battlefield already draws these
/// atlases.
///
/// The source rect's aspect ratio is preserved and the result centred
/// (BoxFit.contain), rather than stretched to fill: the grid tile is not
/// square but a portrait cell is, and a face squashed 10% taller than the
/// artist drew it is the kind of wrongness that reads as "cheap" without
/// being obviously a bug.
class _AtlasRectPainter extends CustomPainter {
  _AtlasRectPainter({required this.atlas, required this.rect});

  final ui.Image atlas;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || rect.isEmpty) return;
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    final scale = (size.width / rect.width) < (size.height / rect.height)
        ? size.width / rect.width
        : size.height / rect.height;
    final dstWidth = rect.width * scale;
    final dstHeight = rect.height * scale;
    final dst = Rect.fromLTWH(
      (size.width - dstWidth) / 2,
      (size.height - dstHeight) / 2,
      dstWidth,
      dstHeight,
    );
    canvas.drawImageRect(atlas, rect, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _AtlasRectPainter oldDelegate) =>
      oldDelegate.atlas != atlas || oldDelegate.rect != rect;
}

class _AvatarPreviewDialog extends StatelessWidget {
  const _AvatarPreviewDialog({
    required this.art,
    required this.portraitAtlas,
    required this.spriteAtlas,
  });

  final AvatarArt art;
  final ui.Image? portraitAtlas;
  final ui.Image? spriteAtlas;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kParchmentColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 160,
                height: 160,
                child: portraitAtlas != null
                    ? CustomPaint(
                        painter: _AtlasRectPainter(atlas: portraitAtlas!, rect: art.portraitRect),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(art.name, style: manuscriptBodyStyle(fontSize: 16)),
            const SizedBox(height: 12),
            // The sprite strip matters: the portrait is the browsing handle,
            // but the walk sprite is what the player stares at for a whole
            // duel, and for several monsters the two read very differently.
            SizedBox(
              height: kAvatarFrameHeight * 3.5,
              child: spriteAtlas != null
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final facing in AvatarFacing.values)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: SizedBox(
                              width: kAvatarFrameWidth * 3.5,
                              height: kAvatarFrameHeight * 3.5,
                              child: CustomPaint(
                                painter: _AtlasRectPainter(
                                  atlas: spriteAtlas!,
                                  rect: art.frameRect(facing, AvatarPose.stand),
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
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
                  child: Text(
                    'Choose',
                    style: manuscriptBodyStyle(color: kIlluminationGold)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
