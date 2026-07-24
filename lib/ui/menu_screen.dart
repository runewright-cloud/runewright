import 'dart:typed_data';

import 'package:flutter/material.dart' hide Element;
import '../identity/identity.dart';
import '../identity/key_packing.dart';
import '../main.dart';
import 'battle_lobby_screen.dart';
import 'commune_screen.dart';
import 'library_screen.dart';
import 'onboarding/onboarding_landing_screen.dart';
import 'practice_screen.dart';
import 'settings_screen.dart';
import 'sigil_painter.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F0E8),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 32),
                const Text(
                  'RUNE WRIGHT',
                  style: TextStyle(
                    color: Color(0xFF2C1810),
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                ),
                const SizedBox(height: 20),
                FutureBuilder<(Uint8List?, String?)>(
                  future: () async {
                    try {
                      final id = await Identity.loadOrCreate();
                      final name = await Identity.loadWizardName();
                      final hex = await id.ownerPubkeyHex();
                      return (fieldHexToLeBytes(hex, 32), name);
                    } catch (_) {
                      return (null, null);
                    }
                  }(),
                  builder: (context, snap) {
                    final keyBytes = snap.data?.$1;
                    final wizardName = snap.data?.$2;
                    return Column(
                      children: [
                        if (keyBytes != null)
                          SigilWidget(keyBytes: keyBytes, size: 98)
                        else
                          const SizedBox(width: 98, height: 98),
                        const SizedBox(height: 10),
                        Text(
                          wizardName ?? '',
                          style: const TextStyle(
                            fontFamily: 'serif',
                            fontSize: 16,
                            letterSpacing: 3,
                            color: Color(0xFF2C1810),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 32),
                _MenuButton(
                  label: 'Battle',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BattleLobbyScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'Rune Craft',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const GameScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'Library',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LibraryScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'Commune',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CommuneScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'Practice',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PracticeScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'About',
                  onTap: null,
                ),
                _MenuButton(
                  label: 'Settings',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
                const SizedBox(height: 24),
                // TEMPORARY -- remove once onboarding is reachable some other way.
                _MenuButton(
                  label: 'DEBUG: View Onboarding',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OnboardingLandingScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'DEBUG: Reset Identity',
                  onTap: () async {
                    await Identity.deleteOnDevice();
                    if (!context.mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                          builder: (_) => const OnboardingLandingScreen()),
                      (route) => false,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _MenuButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: 240,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: enabled
                ? const Color(0xFF2C1810)
                : const Color(0xFF9A9488),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(
                color: enabled
                    ? const Color(0xFF2C1810)
                    : const Color(0xFF9A9488),
                width: 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 18,
              letterSpacing: 3,
              fontWeight: FontWeight.w300,
              color: enabled
                  ? const Color(0xFF2C1810)
                  : const Color(0xFF9A9488),
            ),
          ),
        ),
      ),
    );
  }
}
