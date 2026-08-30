// SPDX-License-Identifier: GPL-3.0-or-later
//
// safe_layout.dart — the app-wide policy for keeping screen content out from
// under the Android system bars.
//
// Why this needs to be one shared thing rather than a per-screen judgement
// call: the app targets Android API 36, and Android 15 (API 35) removed the
// edge-to-edge opt-out. Every Runewright screen is therefore laid out BEHIND
// the system navigation bar on a modern device, and `MediaQuery.padding`
// reports how much of it is not ours to draw in.
//
// `Scaffold` only meets us halfway. It strips the TOP padding off `body` when
// an `AppBar` is present (the app bar has already consumed it), but it strips
// the BOTTOM padding only when a `bottomNavigationBar` or
// `persistentFooterButtons` is present. Runewright uses neither, so on every
// screen the body is handed the full window height and anything sitting at its
// bottom edge — an action bar, the last row of a list, a spell hand — is drawn
// underneath the navigation bar.
//
// That is the defect playtesters kept reporting as "the Android bar covers the
// controls". It was first seen on Samsung hardware only because Samsung
// defaults to the taller 3-button navigation bar where Pixel defaults to the
// gesture pill: the same missing inset, roughly twice as wide. Nothing about
// it is Samsung-specific, and nothing here may ever key off a device, a
// manufacturer, or a measured navigation-bar height — the platform reports the
// inset and the platform is the only thing entitled to know its size.

import 'package:flutter/material.dart';

/// Applies Runewright's system-inset policy to a [Scaffold.body].
///
/// Use this instead of a bare [SafeArea] so the reasoning lives in one place
/// and every screen inherits the same behaviour. It is deliberately thin: the
/// value is the single grep-able policy, not the code.
///
/// ```dart
/// Scaffold(
///   appBar: AppBar(...),
///   body: SafeScreenBody(child: ...),
/// )
/// ```
///
/// **There is deliberately no "does this screen have an app bar?" flag.** An
/// earlier draft had one, on the theory that a screen under an [AppBar] should
/// decline the top inset because the app bar already consumed it. Measured, the
/// distinction does not exist: [Scaffold] passes `removeTopPadding: appBar !=
/// null` to its body, so under an app bar `MediaQuery.padding.top` is already
/// zero and `SafeArea(top: true)` adds nothing — body top lands at 96.0 either
/// way on a 40px status bar plus a 56px app bar. The flag could therefore only
/// ever be wrong, never right: a future screen with no app bar that took the
/// default would put its content 40px under the status bar. One always-correct
/// behaviour beats a parameter whose only reachable effect is a bug.
///
/// (Also correct under `extendBodyBehindAppBar: true`, where [Scaffold] keeps
/// the top padding precisely so the body can inset itself. No screen uses it
/// today.)
///
/// Scrolling content stays scrolling — this shortens a scroll view's viewport
/// so its end is reachable, it never squeezes content into a fixed height.
class SafeScreenBody extends StatelessWidget {
  const SafeScreenBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // All four edges: left/right for display cutouts and landscape gesture
    // insets, top for screens with no app bar (a no-op for those that have
    // one), bottom for the navigation bar this whole file exists for.
    return SafeArea(child: child);
  }
}
