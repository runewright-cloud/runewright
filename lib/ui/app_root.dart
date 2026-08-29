// SPDX-License-Identifier: GPL-3.0-or-later
//
// app_root.dart — first-boot router: checks for an existing Runekey
// (side-effect-free `Identity.exists()`) and sends the player either
// straight to the main menu or into the four-path onboarding flow
// (docs/step1_identity_onboarding_brief.md).
//
// Also seeds the bundled Basic starter spells (docs/BASIC_SPELLS_PLAN.md) on
// every launch, on BOTH branches — a fresh install and an existing one that
// already has an identity both need the seed to run at least once. Seeding
// is cheap (idempotent, marker-gated — see basic_spell_seed.dart) and runs
// alongside the Identity.exists() check rather than blocking on it, so it
// adds no perceptible delay to the existing spinner. Its failure is
// deliberately swallowed: seeding is a nice-to-have, never a gate on
// routing to the menu or onboarding, and unlike Identity.exists() (secure
// storage) it touches path_provider + the asset bundle, which aren't always
// available (e.g. widget tests with no platform-channel mocks) — letting
// that failure propagate would strand the router on its spinner forever.
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../identity/identity.dart';
import '../spells/basic_spell_seed.dart';
import '../spells/spell_semantics_migration.dart';
import '../spells/wild_magic_preview.dart';
import 'manuscript_theme.dart';
import 'menu_screen.dart';
import 'onboarding/onboarding_landing_screen.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  /// Seeds the bundled basics, then repairs any installed spell whose
  /// authored metadata its own proof contradicts (M4.22-F1). Ordered: the
  /// seed writes bundle assets that are already correct, the migration fixes
  /// the ones that were already on disk. Both are swallowed for the same
  /// reason the seed alone was — neither is a gate on routing.
  Future<void> _seedThenMigrate() async {
    try {
      await seedBasicSpells();
    } catch (_) {
      // Seeding is a nice-to-have; a failure here must not skip the
      // migration, which repairs spells the seed can never reach.
    }
    try {
      await migrateSpellSemantics();
    } catch (_) {
      // Marker unwritten, so the next launch retries.
    }
  }

  Future<bool> _identityExistsAfterSeeding() async {
    unawaited(_seedThenMigrate());
    // Primes the leyline seed word every spell card previews its wild magic
    // under. Same rationale as the seeding above: fire-and-forget, its own
    // failure already swallowed, never a gate on routing.
    unawaited(refreshActiveLeylineSeed());
    return Identity.exists();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _identityExistsAfterSeeding(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ParchmentScaffold(
            scrollable: false,
            child: Center(child: CircularProgressIndicator(color: kInkColor)),
          );
        }
        return snapshot.data! ? const MenuScreen() : const OnboardingLandingScreen();
      },
    );
  }
}
