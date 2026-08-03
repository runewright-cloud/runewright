// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_strictness_slider.dart — VocalStrictnessSlider: the shared control
// for VocalTuning's dial. Used from both SettingsScreen and PracticeScreen's
// Vocal tab (2026-07-22 ask) so the two surfaces render identically and
// can't drift — only one widget to keep in sync with VocalTuning's mapping.

import 'package:flutter/material.dart';

import '../../practice/vocal_tuning.dart';

class VocalStrictnessSlider extends StatelessWidget {
  const VocalStrictnessSlider({
    super.key,
    required this.strictness,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double strictness;

  /// Fires continuously while dragging — update local UI state only (cheap;
  /// do not persist here, or a drag writes the settings file every frame).
  final ValueChanged<double> onChanged;

  /// Fires once on release — persist here.
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final tuning = VocalTuning(strictness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Vocal recognition strictness',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text(
          'How demanding word recognition is. Lower = more forgiving '
          '(useful when casting is noisy or simultaneous); higher requires '
          'cleaner enunciation. Playtest tip: pick a level, cast a few '
          'words, adjust.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        Row(
          children: [
            const Text('Easy', style: TextStyle(fontSize: 11)),
            Expanded(
              child: Slider(
                value: strictness,
                divisions: 20,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
            const Text('Strict', style: TextStyle(fontSize: 11)),
          ],
        ),
        Text(
          'floor ${tuning.floor.toStringAsFixed(2)}  ·  '
          'margin ${tuning.margin.toStringAsFixed(2)}  ·  '
          'debounce ${tuning.debounceFrames}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ],
    );
  }
}
