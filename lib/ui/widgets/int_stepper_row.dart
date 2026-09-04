// SPDX-License-Identifier: GPL-3.0-or-later
//
// int_stepper_row.dart — a labeled +/- stepper for a bounded int value.
// Extracted from solo_practice_settings_screen.dart (its HP and grid-radius
// steppers were identical apart from label/bounds) so the LAN duel host
// settings screen can reuse it (LAN_BATTLE_WIREUP_PLAN.md §3.3).

import 'package:flutter/material.dart';

import '../manuscript_theme.dart';

/// Fits two digits at the 28pt serif this row uses. See [IntStepperRow
/// .valueWidth] for why a wider value is opt-in rather than the default.
const double _kDefaultValueWidth = 48;

class IntStepperRow extends StatelessWidget {
  const IntStepperRow({
    super.key,
    required this.label,
    this.caption,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.valueWidth = _kDefaultValueWidth,
  });

  final String label;
  final String? caption;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  /// Width of the number between the two buttons.
  ///
  /// [_kDefaultValueWidth] fits the one- and two-digit values every original
  /// caller has (HP tops out at 48, grid radius at 6, formula length at 6).
  /// A three-digit value does not fit it and WRAPS — "500" renders as "50"
  /// over "0" — so a caller with a wider range must say so. Widening the
  /// default instead would re-space every existing stepper on two settings
  /// screens for the sake of one control, which is a worse trade.
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: manuscriptCaptionStyle()),
        if (caption != null) ...[
          const SizedBox(height: 2),
          Text(
            caption!,
            style: manuscriptCaptionStyle(color: kInkMutedColor.withValues(alpha: 0.7)),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              icon: Icons.remove,
              onTap: value > min ? () => onChanged(value - step) : null,
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: valueWidth,
              child: Text(
                '$value',
                maxLines: 1,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 24),
            _StepButton(
              icon: Icons.add,
              onTap: value < max ? () => onChanged(value + step) : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          border: Border.all(
            color: enabled
                ? kInkColor.withValues(alpha: 0.4)
                : kInkMutedColor.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? kInkColor : kInkMutedColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
