// SPDX-License-Identifier: GPL-3.0-or-later
//
// hold_to_record_control.dart — HoldToRecordButton: the one shared
// press-and-hold capture-window control for somatic gestures.
//
// SOMATIC_GESTURE_PLAN.md §7: segmentation is part of the sensor path.
// Enrollment and the (future, flag-gated) live cast seam MUST use the same
// press-delimited window — if enrollment is press-delimited but live
// capture uses a different window shape, templates are cut differently
// than live queries and every DTW distance is skewed. This widget is that
// one control; do not build a second capture-window mechanism elsewhere.
//
// A press-and-hold also bounds a variable-duration gesture to exactly when
// the player performs it, which is a cleaner DTW segment than a fixed
// timer would give (unlike vocal's fixed _voiceCaptureWindow — gestures
// vary in duration, incantation words don't need to).
//
// Uses GestureDetector's onLongPress* family, which already imposes
// Flutter's default long-press delay (~500ms) before onLongPressStart
// fires — a free debounce against accidental taps triggering a capture.

import 'package:flutter/material.dart';

class HoldToRecordButton extends StatefulWidget {
  const HoldToRecordButton({
    super.key,
    required this.label,
    required this.onHoldStart,
    required this.onHoldEnd,
    this.onHoldCancel,
    this.enabled = true,
    this.icon,
  });

  final String label;

  /// Fired when the press-and-hold begins (after the long-press delay).
  /// This is the capture window's open edge.
  final VoidCallback onHoldStart;

  /// Fired on release — the capture window's close edge. The caller reads
  /// whatever was buffered between onHoldStart and this call.
  final VoidCallback onHoldEnd;

  /// Fired if the press is cancelled (e.g. dragged off the button) instead
  /// of released normally — the caller should discard the buffer, not save
  /// it, since the gesture wasn't completed as performed.
  final VoidCallback? onHoldCancel;

  final bool enabled;
  final IconData? icon;

  @override
  State<HoldToRecordButton> createState() => _HoldToRecordButtonState();
}

class _HoldToRecordButtonState extends State<HoldToRecordButton> {
  bool _holding = false;

  void _start(_) {
    if (!widget.enabled) return;
    setState(() => _holding = true);
    widget.onHoldStart();
  }

  void _end(_) {
    if (!_holding) return;
    setState(() => _holding = false);
    widget.onHoldEnd();
  }

  void _cancel() {
    if (!_holding) return;
    setState(() => _holding = false);
    widget.onHoldCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: widget.enabled ? _start : null,
      onLongPressEnd: widget.enabled ? _end : null,
      onLongPressCancel: widget.enabled ? _cancel : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: !widget.enabled
              ? Colors.grey.shade300
              : _holding
                  ? Colors.red.shade400
                  : Colors.blueGrey.shade600,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _holding ? Icons.fiber_manual_record : (widget.icon ?? Icons.pan_tool_alt),
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              _holding ? 'Recording…' : widget.label,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
