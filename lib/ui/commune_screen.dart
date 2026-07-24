// SPDX-License-Identifier: GPL-3.0-or-later
//
// commune_screen.dart — Commune hub: Trade, Create an Apprenticeship, Sync
// Art. Trade (docs/COMMUNE_TRADE_PLAN.md) and Sync Art
// (lib/trade/sync_art_session.dart) are functional; Create an Apprenticeship
// is visible-but-disabled, matching menu_screen.dart's existing
// About/Settings convention for not-yet-built destinations.

import 'package:flutter/material.dart';

import 'manuscript_theme.dart';
import 'sync_art_screen.dart';
import 'trade_screen.dart';

class CommuneScreen extends StatelessWidget {
  const CommuneScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text('COMMUNE', style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor)),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Meet another wizard to exchange the fruits of your craft.',
                    style: manuscriptCaptionStyle(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  IlluminatedButton(
                    label: 'TRADE',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TradeScreen()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const IlluminatedButton(
                    label: 'CREATE AN APPRENTICESHIP',
                    onTap: null,
                    primary: false,
                  ),
                  const SizedBox(height: 12),
                  IlluminatedButton(
                    label: 'SYNC ART',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SyncArtScreen()),
                    ),
                    primary: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
