// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings_screen.dart — SettingsScreen: app-wide settings.
//
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

import 'package:flutter/material.dart';

import '../battle/models/wild_magic_effect.dart'
    show kDefaultCommunitySeed, normalizeCommunitySeed;
import '../identity/identity.dart';
import '../practice/vocal_tuning.dart';
import 'credits_screen.dart';
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

  /// The last SAVED raw seed, so the Save button only offers itself when the
  /// field actually differs and the "this changes every spell" warning only
  /// fires on a real rotation.
  String _savedSeed = kDefaultCommunitySeed;

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
                  child: ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Credits & Licences'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CreditsScreen()),
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
