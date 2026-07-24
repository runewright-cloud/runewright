// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings_screen.dart — SettingsScreen: app-wide settings. Currently just
// the vocal recognition strictness dial (2026-07-22 playtest ask) — also
// exposed directly in PracticeScreen's Vocal tab so it's adjustable without
// leaving practice; both read/write the same persisted VocalTuning, so
// changing it in either place updates the other on next open.

import 'dart:async';

import 'package:flutter/material.dart';

import '../practice/vocal_tuning.dart';
import 'widgets/vocal_strictness_slider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  VocalTuning? _tuning;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final tuning = await VocalTuning.load();
    if (!mounted) return;
    setState(() => _tuning = tuning);
  }

  @override
  Widget build(BuildContext context) {
    final tuning = _tuning;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: tuning == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
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
            ),
    );
  }
}
