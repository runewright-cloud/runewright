// SPDX-License-Identifier: GPL-3.0-or-later
//
// app_root.dart — first-boot router: checks for an existing Runekey
// (side-effect-free `Identity.exists()`) and sends the player either
// straight to the main menu or into the four-path onboarding flow
// (docs/step1_identity_onboarding_brief.md).

import 'package:flutter/material.dart';

import '../identity/identity.dart';
import 'manuscript_theme.dart';
import 'menu_screen.dart';
import 'onboarding/onboarding_landing_screen.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: Identity.exists(),
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
