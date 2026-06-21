// SPDX-License-Identifier: GPL-3.0-or-later
//
// roll_entry_screen.dart — the Rite of Four-and-Twenty: four hexagons (one
// per element), six d20-roll slots each, 24 slots total. Shared by both the
// create path (player rolls fresh) and the restore path (player re-enters
// rolls recorded on their paper sigil) -- the entry grid is identical,
// only the framing copy and what happens with the finished roll list
// differ (see [RollEntryMode]).
//
// Canonical slot order -- part of the correctness-critical contract in
// docs/step1_identity_onboarding_brief.md ("fixed order, fixed
// representation"): slot index 0-5 = Fire, 6-11 = Wind, 12-17 = Water,
// 18-23 = Earth, each in on-screen reading order within its hexagon. This
// exact order is what gets passed to
// `seed_derivation.dart#deriveSeedFromRolls`. Once the sigil prototype
// lands, its 24 spiral sequence-nodes must be assigned this same index
// order -- changing either side independently breaks recovery.

import 'dart:math' show cos, pi, sin;

import 'package:flutter/material.dart' hide Element;

import '../../engine/border_zone.dart';
import '../../identity/seed_derivation.dart';
import '../manuscript_theme.dart';

enum RollEntryMode { create, restore }

/// The four elements in canonical slot order. Index `i` in the flat
/// 24-roll list belongs to `kElementOrder[i ~/ kSlotsPerElement]`.
const List<BorderZone> kElementOrder = [
  BorderZone.fire,
  BorderZone.air,
  BorderZone.water,
  BorderZone.earth,
];

const int kSlotsPerElement = kRollCount ~/ 4; // 6

const Map<BorderZone, Color> _kElementColor = {
  BorderZone.fire: Color(0xFFCC3311),
  BorderZone.air: Color(0xFF6699BB),
  BorderZone.water: Color(0xFF2255AA),
  BorderZone.earth: Color(0xFF7A5C28),
};

const Map<BorderZone, String> _kElementLabel = {
  BorderZone.fire: 'Fire',
  BorderZone.air: 'Wind',
  BorderZone.water: 'Water',
  BorderZone.earth: 'Earth',
};

class RollEntryScreen extends StatefulWidget {
  const RollEntryScreen({super.key, required this.mode, required this.onComplete});

  final RollEntryMode mode;

  /// Called with the 24 validated rolls once the player confirms. The
  /// caller owns what happens next (derive + store a new key for `create`,
  /// derive + overwrite for `restore`).
  final Future<void> Function(List<int> rolls) onComplete;

  @override
  State<RollEntryScreen> createState() => _RollEntryScreenState();
}

class _RollEntryScreenState extends State<RollEntryScreen> {
  final List<int?> _rolls = List<int?>.filled(kRollCount, null);
  bool _submitting = false;

  int get _filledCount => _rolls.where((r) => r != null).length;
  bool get _isComplete => _filledCount == kRollCount;

  Future<void> _pickValueFor(int slotIndex) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _D20PickerDialog(initial: _rolls[slotIndex]),
    );
    if (value != null) {
      setState(() => _rolls[slotIndex] = value);
    }
  }

  Future<void> _submit() async {
    if (!_isComplete || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onComplete(_rolls.cast<int>());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCreate = widget.mode == RollEntryMode.create;
    return ParchmentScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ManuscriptBackButton(),
          const SizedBox(height: 4),
          Text(
            isCreate ? 'THE RITE OF FOUR-AND-TWENTY' : 'RESTORE FROM YOUR SIGIL',
            textAlign: TextAlign.center,
            style: manuscriptHeaderStyle(fontSize: 22),
          ),
          const SizedBox(height: 12),
          Text(
            isCreate
                ? 'Roll a twenty-sided die 24 times and record each result below — '
                    'six per element. No one, not even this app, can predict a roll '
                    'before you make it.'
                : 'Re-enter the 24 values recorded on your paper sigil, in the same '
                    'order, to rebuild your Runekey exactly.',
            textAlign: TextAlign.center,
            style: manuscriptBodyStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '$_filledCount / $kRollCount recorded',
            textAlign: TextAlign.center,
            style: manuscriptCaptionStyle(),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 16,
            children: [
              for (var e = 0; e < kElementOrder.length; e++)
                _ElementHexagonCluster(
                  element: kElementOrder[e],
                  rolls: _rolls.sublist(e * kSlotsPerElement, (e + 1) * kSlotsPerElement),
                  onTapSlot: (localIndex) => _pickValueFor(e * kSlotsPerElement + localIndex),
                ),
            ],
          ),
          const SizedBox(height: 24),
          IlluminatedButton(
            label: _submitting
                ? 'WORKING…'
                : (isCreate ? 'FORGE RUNEKEY' : 'RESTORE RUNEKEY'),
            onTap: (_isComplete && !_submitting) ? _submit : null,
          ),
        ],
      ),
    );
  }
}

class _ElementHexagonCluster extends StatelessWidget {
  const _ElementHexagonCluster({
    required this.element,
    required this.rolls,
    required this.onTapSlot,
  });

  final BorderZone element;
  final List<int?> rolls;
  final void Function(int localIndex) onTapSlot;

  // The six roll slots sit at the vertices of an actual hexagon (one slot
  // per element rule per CA cell-neighbor count -- a nice thematic echo of
  // the hex-grid CA itself), point-up, with an outline connecting them.
  static const double _hexRadius = 54;
  static const double _slotSize = 34;
  static const double _stackSize = (_hexRadius + _slotSize / 2 + 6) * 2;

  Offset _vertex(int i) {
    final angle = (-90 + 60 * i) * pi / 180;
    return Offset(
      _stackSize / 2 + _hexRadius * cos(angle),
      _stackSize / 2 + _hexRadius * sin(angle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _kElementColor[element]!;
    return Container(
      width: 190,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kParchmentPanelColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _kElementLabel[element]!.toUpperCase(),
            style: TextStyle(
              fontFamily: 'serif',
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              color: color,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: _stackSize,
            height: _stackSize,
            child: Stack(
              children: [
                CustomPaint(
                  size: const Size(_stackSize, _stackSize),
                  painter: _HexagonOutlinePainter(color: color),
                ),
                for (var i = 0; i < rolls.length; i++)
                  Positioned(
                    left: _vertex(i).dx - _slotSize / 2,
                    top: _vertex(i).dy - _slotSize / 2,
                    child: _RollSlot(
                      value: rolls[i],
                      color: color,
                      size: _slotSize,
                      onTap: () => onTapSlot(i),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the point-up hexagon outline connecting the six roll-slot vertices.
class _HexagonOutlinePainter extends CustomPainter {
  const _HexagonOutlinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = (-90 + 60 * i) * pi / 180;
      final point = center + Offset(_ElementHexagonCluster._hexRadius * cos(angle),
          _ElementHexagonCluster._hexRadius * sin(angle));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _HexagonOutlinePainter oldDelegate) => oldDelegate.color != color;
}

class _RollSlot extends StatelessWidget {
  const _RollSlot({required this.value, required this.color, required this.onTap, this.size = 36});

  final int? value;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final filled = value != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? color.withValues(alpha: 0.18) : kParchmentColor,
          border: Border.all(color: filled ? color : kInkMutedColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          filled ? '$value' : '—',
          style: TextStyle(
            fontFamily: 'serif',
            fontWeight: FontWeight.bold,
            color: filled ? kInkColor : kInkMutedColor,
          ),
        ),
      ),
    );
  }
}

class _D20PickerDialog extends StatelessWidget {
  const _D20PickerDialog({required this.initial});

  final int? initial;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kParchmentColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('CHOOSE YOUR ROLL (1–20)', style: manuscriptHeaderStyle(fontSize: 16)),
            const SizedBox(height: 12),
            SizedBox(
              width: 260,
              child: GridView.count(
                crossAxisCount: 5,
                shrinkWrap: true,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (var v = 1; v <= 20; v++)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(v),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: v == initial ? kIlluminationGold.withValues(alpha: 0.3) : kParchmentPanelColor,
                          border: Border.all(color: kInkColor),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('$v', style: const TextStyle(fontFamily: 'serif', color: kInkColor)),
                      ),
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
