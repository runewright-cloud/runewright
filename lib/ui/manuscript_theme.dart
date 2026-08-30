// SPDX-License-Identifier: GPL-3.0-or-later
//
// manuscript_theme.dart — the illuminated-manuscript visual language for
// identity onboarding (docs/step1_identity_onboarding_brief.md): warm
// parchment, inky ink, gothic-feeling letterspaced headers, a gold
// "illumination" accent reserved for moments where magic activates (a key
// is forged, a sigil completes).
//
// Deliberately light: a handful of color/style constants and two small
// shared widgets, not a full design system. Specific fonts/assets are a
// later decision (the brief says not to over-invest in fidelity yet) --
// this gives onboarding and any screen built after it a consistent,
// swappable starting point rather than each screen inventing its own
// palette.

import 'package:flutter/material.dart';

import 'safe_layout.dart';

/// Base parchment background -- matches the existing app scaffold color
/// (lib/main.dart, lib/ui/menu_screen.dart) so onboarding doesn't visually
/// clash with what's already shipped.
const Color kParchmentColor = Color(0xFFF5F0E8);

/// A slightly darker parchment tone for cards/panels sitting on top of the
/// base background.
const Color kParchmentPanelColor = Color(0xFFEAE1CC);

/// Primary ink color -- matches the existing app's primary/text color.
const Color kInkColor = Color(0xFF2C1810);

/// Muted ink for secondary/disabled text.
const Color kInkMutedColor = Color(0xFF9A9488);

/// Gold "illumination" accent -- reserved for active/affirmative magic
/// moments (a key forged, a sigil completed), not general UI chrome.
const Color kIlluminationGold = Color(0xFFB8860B);

/// Rubric red -- manuscript-marginalia red, used for warnings.
const Color kRubricRed = Color(0xFF7A1F1F);

/// Gothic-feeling header style: bold, uppercase, letterspaced. Uses the
/// platform serif fallback until a real display face is chosen.
TextStyle manuscriptHeaderStyle({double fontSize = 28, Color color = kInkColor}) {
  return TextStyle(
    fontFamily: 'serif',
    fontSize: fontSize,
    fontWeight: FontWeight.bold,
    letterSpacing: 4,
    color: color,
  );
}

/// Body copy style: serif, ink, no letterspacing exaggeration.
TextStyle manuscriptBodyStyle({double fontSize = 16, Color color = kInkColor}) {
  return TextStyle(
    fontFamily: 'serif',
    fontSize: fontSize,
    height: 1.4,
    color: color,
  );
}

/// Small caption/annotation style.
TextStyle manuscriptCaptionStyle({Color color = kInkMutedColor}) {
  return TextStyle(
    fontFamily: 'serif',
    fontSize: 13,
    fontStyle: FontStyle.italic,
    color: color,
  );
}

/// A parchment-backed [Scaffold] with consistent padding -- the standard
/// frame for an onboarding screen.
class ParchmentScaffold extends StatelessWidget {
  const ParchmentScaffold({super.key, required this.child, this.scrollable = true});

  final Widget child;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: child,
    );
    return Scaffold(
      backgroundColor: kParchmentColor,
      body: SafeScreenBody(
        child: scrollable ? SingleChildScrollView(child: body) : body,
      ),
    );
  }
}

/// A bordered, letterspaced button styled to match the manuscript aesthetic
/// -- the onboarding equivalent of menu_screen.dart's `_MenuButton`, pulled
/// out so onboarding and future screens share one button look.
class IlluminatedButton extends StatelessWidget {
  const IlluminatedButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = true,
  });

  final String label;
  final VoidCallback? onTap;

  /// Primary buttons use the gold illumination accent; secondary buttons
  /// (e.g. "Skip for now") stay plain ink so they don't compete visually.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = !enabled
        ? kInkMutedColor
        : (primary ? kIlluminationGold : kInkColor);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          side: BorderSide(color: color, width: primary ? 2 : 1),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 16,
            letterSpacing: 2,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// A small "‹ Back" link for onboarding screens reached partway through one
/// of the four key generation/recovery paths -- lets a player who tapped
/// the wrong option on the landing screen back out immediately instead of
/// having to complete (or abandon mid-flow) the wrong path.
class ManuscriptBackButton extends StatelessWidget {
  const ManuscriptBackButton({super.key, this.onTap});

  /// Defaults to popping the current route if not overridden.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap ?? () => Navigator.of(context).pop(),
        style: TextButton.styleFrom(
          foregroundColor: kInkColor,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text(
          '‹ Back',
          style: TextStyle(fontFamily: 'serif', fontSize: 15, letterSpacing: 1),
        ),
      ),
    );
  }
}
