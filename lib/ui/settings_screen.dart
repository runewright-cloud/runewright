// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings_screen.dart — SettingsScreen: app-wide settings.
//
//   - Avatar — the character sprite the player's wizard wears on the
//     battlefield (docs/AVATAR_PICKER_PLAN.md). The most concrete and least
//     consequential control on the page, so it leads.
//   - The vocal recognition strictness dial (2026-07-22 playtest ask) — also
//     exposed directly in PracticeScreen's Vocal tab so it's adjustable without
//     leaving practice; both read/write the same persisted VocalTuning, so
//     changing it in either place updates the other on next open.
//   - The leyline seed word — the community word folded into every spell's
//     wild-magic hash. Deliberately a first-class control, not a buried
//     setting: rotating it is the ratified answer to a grinder warping a local
//     meta (docs/WILD_MAGIC_PLAN.md §2.6/§7.5), and that only works if changing
//     it is easy and obvious.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../battle/models/wild_magic_effect.dart'
    show kDefaultCommunitySeed, normalizeCommunitySeed;
import '../identity/identity.dart';
import '../practice/vocal_tuning.dart';
import '../spells/library_backup_io.dart';
import 'avatars/avatar_picker_screen.dart';
import 'avatars/avatar_sprites.dart';
import 'about_screen.dart';
import 'manuscript_theme.dart' show kIlluminationGold;
import 'onboarding/onboarding_landing_screen.dart';
import 'widgets/vocal_strictness_slider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  VocalTuning? _tuning;
  final _seedController = TextEditingController();

  /// The player's saved avatar id, or null before it loads / if unset (falls
  /// back to the deterministic default — see AvatarAssignment).
  String? _avatarId;
  ui.Image? _portraitAtlas;

  /// The last SAVED raw seed, so the Save button only offers itself when the
  /// field actually differs and the "this changes every spell" warning only
  /// fires on a real rotation.
  String _savedSeed = kDefaultCommunitySeed;

  bool _exportingLibrary = false;
  bool _importingLibrary = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tuning = await VocalTuning.load();
    if (!mounted) return;
    setState(() => _tuning = tuning);
    unawaited(_loadSeed());
    unawaited(_loadAvatar());
  }

  /// Loaded separately, never blocking, same reason as [_loadSeed]: secure
  /// storage has no platform channel under `flutter test`. Also kicks off
  /// the portrait atlas decode, which fails the same soft way as everywhere
  /// else this atlas is loaded — a missing/corrupt pack just leaves the
  /// thumbnail on its placeholder.
  Future<void> _loadAvatar() async {
    String? avatarId;
    try {
      avatarId = await Identity.loadAvatarId();
    } catch (_) {
      avatarId = null;
    }
    if (mounted) setState(() => _avatarId = avatarId);

    try {
      final image = await AvatarPortraitAtlas.load();
      if (mounted) setState(() => _portraitAtlas = image);
    } catch (_) {
      // Placeholder thumbnail stands in — see _AvatarCard.
    }
  }

  Future<void> _changeAvatar() async {
    final chosen = await pickAvatar(context, currentAvatarId: _avatarId);
    if (chosen == null) return;
    await Identity.saveAvatarId(chosen);
    if (!mounted) return;
    setState(() => _avatarId = chosen);
  }

  /// Loaded separately from [_tuning], and never allowed to block the screen:
  /// secure storage has no platform channel under `flutter test`, so awaiting
  /// it in [_load] would leave the whole settings page stuck on its spinner.
  /// A failure here just leaves the default seed in the field.
  Future<void> _loadSeed() async {
    String seed;
    try {
      seed = await Identity.loadCommunitySeed() ?? kDefaultCommunitySeed;
    } catch (_) {
      seed = kDefaultCommunitySeed;
    }
    if (!mounted) return;
    setState(() {
      _savedSeed = seed;
      _seedController.text = seed;
    });
  }

  /// Rotating the seed word gives every spell in the library different wild
  /// magic. That is a meta reset, not a preference, so it is confirmed —
  /// but deliberately with one tap, because a rotation nobody bothers to
  /// perform is not a defence (§2.6).
  Future<void> _saveSeed() async {
    final raw = _seedController.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change your leyline seed word?'),
        content: Text(
          'Every spell in your library will find different wild magic under '
          '"${normalizeCommunitySeed(raw)}". Their ordinary effects are '
          'unchanged, so your spellbook stays valid anywhere.\n\n'
          'Both duelists must speak the same word to duel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change it'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Identity.saveCommunitySeed(raw);
    if (!mounted) return;
    setState(() => _savedSeed = raw);
  }

  /// Saves a snapshot of every spell (crafted and loaned-in), chapter,
  /// sighting, loan grant, and discovered recipe to a file the player
  /// chooses via the platform's save/share sheet.
  Future<void> _exportLibrary() async {
    setState(() => _exportingLibrary = true);
    try {
      final path = await exportLibraryToFile();
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Library backup saved to $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _exportingLibrary = false);
    }
  }

  /// Picks a library backup file and additively merges it in -- nothing
  /// already on this device is overwritten or deleted; only records this
  /// device doesn't already have are added (see library_backup.dart).
  Future<void> _importLibrary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import a library backup?'),
        content: const Text(
          "This adds spells, chapters, sightings, loans, and recipes from the "
          "chosen file that you don't already have. Nothing already on this "
          "device is changed or removed.\n\n"
          "Spells from someone else's library import fine, but stay bound to "
          "their Runekey -- you won't be able to cast them, since only spells "
          "bound to your own key pass battle's ownership check.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Choose File…'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _importingLibrary = true);
    try {
      final summary = await importLibraryFromFile();
      if (!mounted || summary == null) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import complete'),
          content: Text(
            summary.addedNothing
                ? 'Nothing new -- everything in that file is already in your library.'
                : 'Added: ${summary.spellsAdded} spell(s), ${summary.chaptersAdded} '
                    'chapter(s), ${summary.sightingsAdded} sighting(s), '
                    '${summary.permissionsAdded} loan grant(s), ${summary.recipesAdded} '
                    'recipe(s).\n\n'
                    'Skipped as already known: ${summary.spellsSkipped} spell(s), '
                    '${summary.chaptersSkipped} chapter(s), ${summary.sightingsSkipped} '
                    'sighting(s), ${summary.permissionsSkipped} loan grant(s).',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _importingLibrary = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tuning = _tuning;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: tuning == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _AvatarThumbnail(
                          avatarId: _avatarId,
                          atlas: _portraitAtlas,
                        ),
                      ),
                    ),
                    title: const Text('Avatar'),
                    subtitle: Text(_avatarLabel(_avatarId)),
                    trailing: TextButton(
                      onPressed: () => unawaited(_changeAvatar()),
                      child: const Text('Change'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: VocalStrictnessSlider(
                      strictness: tuning.strictness,
                      onChanged: (v) =>
                          setState(() => _tuning = VocalTuning(v)),
                      onChangeEnd: (v) => unawaited(VocalTuning(v).save()),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Leyline Seed Word',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Your community’s word. Spells find different '
                          'wild magic under different traditions; both '
                          'duelists must use the same word.',
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _seedController,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 6),
                        // Show the normalized form so "Rivendell!" visibly
                        // becoming "rivendell" is never a surprise.
                        Text(
                          'Reads as: ${normalizeCommunitySeed(_seedController.text)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed:
                                _seedController.text.trim() == _savedSeed
                                    ? null
                                    : () => unawaited(_saveSeed()),
                            child: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Library Backup',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'A complete copy of your spells, chapters, sightings, '
                          'loans, and recipes. Importing only adds what you '
                          "don't already have -- it never overwrites anything.",
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _exportingLibrary ? null : () => unawaited(_exportLibrary()),
                                child: Text(_exportingLibrary ? 'Exporting…' : 'Export'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _importingLibrary ? null : () => unawaited(_importLibrary()),
                                child: Text(_importingLibrary ? 'Importing…' : 'Import'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Credits & Licences'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AboutScreen(initialTab: 1)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: const Text('DEBUG: Reset Identity'),
                    onTap: () async {
                      await Identity.deleteOnDevice();
                      if (!context.mounted) return;
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                            builder: (_) => const OnboardingLandingScreen()),
                        (route) => false,
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

String _avatarLabel(String? avatarId) {
  if (avatarId == null || avatarId.isEmpty) return 'Default';
  return avatarArtById(avatarId)?.name ?? 'Default';
}

/// The settings-row thumbnail: the saved avatar's portrait, or a neutral
/// placeholder while the atlas is loading, unset, or unrecognised. Never
/// throws on a missing atlas — same "null means placeholder" contract as
/// every other avatar-atlas consumer.
class _AvatarThumbnail extends StatelessWidget {
  const _AvatarThumbnail({required this.avatarId, required this.atlas});

  final String? avatarId;
  final ui.Image? atlas;

  @override
  Widget build(BuildContext context) {
    final atlasImage = atlas;
    final art = avatarId == null ? null : avatarArtById(avatarId!);
    if (atlasImage == null || art == null) {
      return Container(
        color: kIlluminationGold.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: const Icon(Icons.person_outline, size: 24),
      );
    }
    return CustomPaint(painter: _ThumbnailPainter(atlas: atlasImage, rect: art.portraitRect));
  }
}

class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter({required this.atlas, required this.rect});

  final ui.Image atlas;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    canvas.drawImageRect(atlas, rect, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _ThumbnailPainter oldDelegate) =>
      oldDelegate.atlas != atlas || oldDelegate.rect != rect;
}
