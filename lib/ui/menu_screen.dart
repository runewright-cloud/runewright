import 'dart:typed_data';

import 'package:flutter/material.dart' hide Element;
import '../apprentice/apprenticeship.dart';
import '../dev_flags.dart' show kShowDevSurfaces;
import '../identity/identity.dart';
import '../identity/key_packing.dart';
import '../main.dart';
import 'about_screen.dart';
import 'apprenticeship_screen.dart';
import 'battle_lobby_screen.dart';
import 'commune_screen.dart';
import 'library_screen.dart';
import 'manuscript_theme.dart' show kIlluminationGold, kRubricRed, kInkColor;
import 'onboarding/onboarding_landing_screen.dart';
import 'vocabulary_screen.dart';
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
                const _ApprenticeshipNag(),
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
                // No Practice entry here on purpose: practice is always a drill
                // of ONE library spell, so it is reached from that spell's card
                // (Library › Practice Incantation) and nowhere else.
                _MenuButton(
                  label: 'Attune Components',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const VocabularyScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'About',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                _MenuButton(
                  label: 'Settings',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
                // DEV FLAG (kShowDevSurfaces -- lib/dev_flags.dart): onboarding
                // is otherwise reachable only on a fresh install.
                if (kShowDevSurfaces) ...[
                  const SizedBox(height: 24),
                  _MenuButton(
                    label: 'DEBUG: View Onboarding',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const OnboardingLandingScreen()),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The apprenticeship days-remaining nag (docs/MASTER_APPRENTICE_PLAN.md §8).
///
/// This is the ONLY reminder that exists — no server, no push channel — so it
/// lives on the first screen the player sees and stays silent until the term
/// is nearly up ([kApprenticeshipNagDays]). Renders nothing at all when there
/// is no mastership, which is the common case; the disk read is one small
/// directory listing.
class _ApprenticeshipNag extends StatefulWidget {
  const _ApprenticeshipNag();

  @override
  State<_ApprenticeshipNag> createState() => _ApprenticeshipNagState();
}

class _ApprenticeshipNagState extends State<_ApprenticeshipNag> {
  ApprenticeshipRecord? _record;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final record = await ApprenticeshipRecord.expiringMastership();
    if (mounted) setState(() => _record = record);
  }

  Future<void> _open() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ApprenticeshipScreen()),
    );
    // A renewal (or an abandonment) on that screen changes what this should
    // say, and there is no other path back here that would refresh it.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    if (record == null) return const SizedBox.shrink();

    final lapsed = record.isLapsed();
    final days = record.daysRemaining();
    final accent = lapsed ? kRubricRed : kIlluminationGold;
    final message = lapsed
        ? 'Your apprenticeship has lapsed. Meet your master to renew it.'
        : 'Your apprenticeship lapses in ${days == 1 ? '1 day' : '$days days'}. '
            'Meet your master to renew it.';

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        width: 300,
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: accent),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.hourglass_bottom, size: 18, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 13,
                      height: 1.3,
                      color: kInkColor,
                    ),
                  ),
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
