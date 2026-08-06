// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm_attune_dialog.dart — the trajectory entry surface for a
// counter charm (docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 2, "Entry UI").
//
// This replaced `_bindCounterCharmOnSpell` in library_screen.dart, which hung
// off a spell's overflow menu and could only attach a grid commitment the
// player already owned a spell for. A charm is attuned to BEHAVIOUR now, so
// entry belongs on the charm: you type the trajectory you expect to face,
// whether or not you have ever seen a spell that produces it.

import 'package:flutter/material.dart' hide Element;

import '../engine/border_zone.dart';
import '../spells/counter_charm.dart';
import 'manuscript_theme.dart';

const _kZoneColors = {
  BorderZone.fire: Color(0xFFCC3311),
  BorderZone.air: Color(0xFF6699BB),
  BorderZone.water: Color(0xFF2255AA),
  BorderZone.earth: Color(0xFF7A5C28),
};

const _kZoneNames = {
  BorderZone.fire: 'Fire',
  BorderZone.air: 'Air',
  BorderZone.water: 'Water',
  BorderZone.earth: 'Earth',
};

Color counterCharmZoneColor(BorderZone zone) => _kZoneColors[zone]!;

/// Opens the attunement editor for a counter charm.
///
/// Returns the chosen trajectory, or null if the player backed out. [initial]
/// pre-loads an already-attuned charm's trajectory so re-attuning is an edit
/// rather than a retype.
Future<List<BorderZone>?> showCounterCharmAttuneDialog(
  BuildContext context, {
  List<BorderZone> initial = const [],
}) =>
    showDialog<List<BorderZone>>(
      context: context,
      builder: (_) => _CounterCharmAttuneDialog(initial: initial),
    );

class _CounterCharmAttuneDialog extends StatefulWidget {
  const _CounterCharmAttuneDialog({required this.initial});

  final List<BorderZone> initial;

  @override
  State<_CounterCharmAttuneDialog> createState() =>
      _CounterCharmAttuneDialogState();
}

class _CounterCharmAttuneDialogState extends State<_CounterCharmAttuneDialog> {
  late final List<BorderZone> _trajectory = List.of(widget.initial);

  bool get _isFull =>
      _trajectory.length >= kMaxCharmFormulas * kElementsPerFormula;

  bool get _isValid => isValidCharmTrajectory(_trajectory);

  /// Elements still needed to complete the formula in progress — the entry
  /// rule players actually have to internalise ("charms come in threes").
  int get _toCompleteFormula =>
      (kElementsPerFormula - _trajectory.length % kElementsPerFormula) %
      kElementsPerFormula;

  void _append(BorderZone zone) {
    if (_isFull) return;
    setState(() => _trajectory.add(zone));
  }

  void _backspace() {
    if (_trajectory.isEmpty) return;
    setState(() => _trajectory.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kParchmentPanelColor,
      title: const Text(
        'Attune Counter Charm',
        style: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The charm cancels any spell that opens with this sequence — '
              'formula by formula, for as long as the two agree.',
              style: manuscriptCaptionStyle(
                color: kInkColor.withValues(alpha: 0.7),
              ).copyWith(fontStyle: FontStyle.normal),
            ),
            const SizedBox(height: 14),
            _TrajectoryStrip(trajectory: _trajectory),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final zone in BorderZone.values)
                  _ElementButton(
                    zone: zone,
                    onPressed: _isFull ? null : () => _append(zone),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _trajectory.isEmpty ? null : _backspace,
                  icon: const Icon(Icons.backspace_outlined, size: 15),
                  label: const Text('Undo'),
                  style: TextButton.styleFrom(
                    foregroundColor: kInkColor.withValues(alpha: 0.7),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const Spacer(),
                Text(_statusLine(), style: _statusStyle()),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isValid
              ? () => Navigator.pop(context, List.of(_trajectory))
              : null,
          child: const Text('Attune'),
        ),
      ],
    );
  }

  String _statusLine() {
    if (_trajectory.isEmpty) return 'Choose at least one formula.';
    // A trajectory is always a whole number of formulas, so an incomplete
    // tail is the only invalid state reachable from these buttons.
    if (_toCompleteFormula > 0) {
      return '$_toCompleteFormula more to finish the formula';
    }
    final cost = counterCharmManaCost(_trajectory);
    final formulas = _trajectory.length ~/ kElementsPerFormula;
    return '$formulas formula${formulas == 1 ? "" : "s"}  ·  ♦ $cost per trigger';
  }

  TextStyle _statusStyle() => manuscriptCaptionStyle(
        color: _isValid
            ? kInkColor.withValues(alpha: 0.75)
            : kRubricRed.withValues(alpha: 0.8),
      ).copyWith(fontStyle: FontStyle.normal);
}

// ── Pieces ───────────────────────────────────────────────────────────────────

/// The trajectory so far, grouped into formulas of three with the in-progress
/// formula's empty slots drawn as dashed placeholders — so "charms come in
/// threes" is visible rather than only enforced by the Attune button.
class _TrajectoryStrip extends StatelessWidget {
  const _TrajectoryStrip({required this.trajectory});

  final List<BorderZone> trajectory;

  @override
  Widget build(BuildContext context) {
    final groups = <List<BorderZone?>>[];
    for (var i = 0; i < trajectory.length; i += kElementsPerFormula) {
      final end = i + kElementsPerFormula;
      groups.add([
        ...trajectory.sublist(i, end > trajectory.length ? trajectory.length : end),
        // Pad the trailing partial formula out to three.
        for (var p = trajectory.length; p < end; p++) null,
      ]);
    }
    // Nothing entered yet: show one empty formula so the shape is legible.
    if (groups.isEmpty) groups.add([null, null, null]);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: kInkColor.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (var g = 0; g < groups.length; g++) ...[
            if (g > 0)
              Text('/',
                  style: TextStyle(color: kInkColor.withValues(alpha: 0.35))),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [for (final z in groups[g]) _slot(z)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _slot(BorderZone? zone) {
    final color = zone == null
        ? kInkColor.withValues(alpha: 0.25)
        : counterCharmZoneColor(zone);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: zone == null ? null : color.withValues(alpha: 0.16),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        zone == null ? '—' : _kZoneNames[zone]!,
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 12,
          color: zone == null ? kInkMutedColor : color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ElementButton extends StatelessWidget {
  const _ElementButton({required this.zone, required this.onPressed});

  final BorderZone zone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = counterCharmZoneColor(zone);
    final enabled = onPressed != null;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(
          color: color.withValues(alpha: enabled ? 0.8 : 0.25),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(
        _kZoneNames[zone]!,
        style: const TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w600),
      ),
    );
  }
}
