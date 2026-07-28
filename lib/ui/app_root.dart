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
import 'manuscript_theme.dart';
import 'menu_screen.dart';
import 'onboarding/onboarding_landing_screen.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  Future<bool> _identityExistsAfterSeeding() async {
    unawaited(seedBasicSpells().catchError((_) => 0));
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
