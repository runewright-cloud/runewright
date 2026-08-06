// SPDX-License-Identifier: GPL-3.0-or-later
//
// component_toggles.dart — the Vocal / Somatic / Simultaneous switches, shared
// by the duel host settings screen and its solo-practice mirror.
//
// Shared rather than duplicated because the three flags interact: the
// simultaneous switch is meaningless with neither component on, and its
// warning copy is ratified prose (docs/SPELL_COMPONENTS_PLAN.md §5.1) that must
// not drift between the two surfaces. The two screens differ only in whether
// they offer the simultaneous switch at all — solo has one caster, so there is
// nothing to be simultaneous with.

import 'package:flutter/material.dart';

import '../manuscript_theme.dart';

/// Ratified warning shown when simultaneous casting is switched on
/// (SPELL_COMPONENTS_PLAN.md §5.1). The problem it warns about is acoustic,
/// not mechanical: two people chanting a metre apart put each other's words
/// into each other's microphones.
const String kSimultaneousCastingWarning =
    'When using this mode all players will be saying weird things and doing '
    'weird things simultaneously. Not recommended unless you are wizards of '
    'singular focus, have plenty of room to spread out, and are wearing '
    'headsets.';

class ComponentToggles extends StatelessWidget {
  const ComponentToggles({
    super.key,
    required this.vocalComponents,
    required this.somaticComponents,
    required this.simultaneousCasting,
    required this.onVocalChanged,
    required this.onSomaticChanged,
    required this.onSimultaneousChanged,
    this.showSimultaneous = true,
  });

  final bool vocalComponents;
  final bool somaticComponents;
  final bool simultaneousCasting;
  final ValueChanged<bool> onVocalChanged;
  final ValueChanged<bool> onSomaticChanged;
  final ValueChanged<bool> onSimultaneousChanged;

  /// False on the solo surface: one caster cannot cast simultaneously with
  /// anyone, so offering the switch would only invite the question.
  final bool showSimultaneous;

  bool get _componentsEnabled => vocalComponents || somaticComponents;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ToggleRow(
          label: 'VOCAL COMPONENTS',
          caption: 'Speak the incantation aloud to cast',
          value: vocalComponents,
          onChanged: onVocalChanged,
        ),
        const SizedBox(height: 20),
        _ToggleRow(
          label: 'SOMATIC COMPONENTS',
          caption: 'Gesticulate while casting; the gesture chooses '
              'the enhancement',
          value: somaticComponents,
          onChanged: onSomaticChanged,
        ),
        if (showSimultaneous) ...[
          const SizedBox(height: 20),
          _ToggleRow(
            label: 'SIMULTANEOUS CASTING',
            caption: _componentsEnabled
                ? 'Everyone performs at once, instead of taking turns '
                    'clockwise'
                : 'Needs a component to be enabled first',
            // Nothing to order without components to perform, so the switch
            // has nothing to do — matching MatchConfig.sequentialCasting,
            // which is gated the same way and for the same reason.
            enabled: _componentsEnabled,
            value: simultaneousCasting,
            onChanged: (v) async {
              if (!v) {
                onSimultaneousChanged(false);
                return;
              }
              final confirmed = await _confirmSimultaneous(context);
              if (confirmed) onSimultaneousChanged(true);
            },
          ),
        ],
      ],
    );
  }

  /// Warns before switching simultaneous casting on. Turning it back OFF is
  /// never gated — returning to the recommended default should not need a
  /// dialog.
  Future<bool> _confirmSimultaneous(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kParchmentColor,
        title: Text(
          'SIMULTANEOUS CASTING',
          style: manuscriptHeaderStyle(fontSize: 16),
        ),
        content: Text(
          kSimultaneousCastingWarning,
          style: manuscriptCaptionStyle(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCEL', style: manuscriptCaptionStyle()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'PROCEED',
              style: TextStyle(
                fontFamily: 'serif',
                letterSpacing: 2,
                color: kIlluminationGold,
              ),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.caption,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final dim = enabled ? 1.0 : 0.4;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: manuscriptCaptionStyle(
                  color: kInkColor.withValues(alpha: dim),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: manuscriptCaptionStyle(
                  color: kInkMutedColor.withValues(alpha: 0.7 * dim),
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: kIlluminationGold,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
