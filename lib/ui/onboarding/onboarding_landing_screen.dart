// SPDX-License-Identifier: GPL-3.0-or-later
//
// onboarding_landing_screen.dart — first-boot identity bootstrap: the four
// paths from docs/step1_identity_onboarding_brief.md. Shown only when
// `Identity.exists()` is false; on every path's completion the onboarding
// stack is cleared and the player lands on the (pre-existing) MenuScreen.

import 'package:flutter/material.dart';

import '../../identity/identity.dart';
import '../../identity/seed_derivation.dart';
import '../manuscript_theme.dart';
import '../menu_screen.dart';
import 'backup_prompt_screen.dart';
import 'restore_file_screen.dart';
import 'roll_entry_screen.dart';

/// Clears the entire onboarding stack and lands on the main menu. Takes the
/// caller's own [context] rather than being bound to any particular
/// screen's lifetime -- onboarding screens further down the flow get
/// pushReplaced as the player progresses, which would unmount a State whose
/// own context a closure had captured (see git history for the bug this
/// fixed: an auto-create's "Continue" button threw "widget has been
/// unmounted" because its callback was a stale OnboardingLandingScreen
/// method, not a context passed in fresh at call time).
void goToMenu(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const MenuScreen()),
    (route) => false,
  );
}

class OnboardingLandingScreen extends StatefulWidget {
  const OnboardingLandingScreen({super.key});

  @override
  State<OnboardingLandingScreen> createState() => _OnboardingLandingScreenState();
}

class _OnboardingLandingScreenState extends State<OnboardingLandingScreen> {
  bool _busy = false;
  final _nameController = TextEditingController();
  bool _nameEntered = false;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() {
      final entered = _nameController.text.trim().isNotEmpty;
      if (entered != _nameEntered) setState(() => _nameEntered = entered);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createAuto() async {
    setState(() => _busy = true);
    try {
      await Identity.saveWizardName(_nameController.text.trim());
      final identity = await Identity.loadOrCreate();
      if (!mounted) return;
      // push (not pushReplacement) so this landing screen stays underneath
      // -- BackupPromptScreen's Back button needs somewhere to pop to if
      // the player realizes they tapped the wrong option.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BackupPromptScreen(
            identity: identity,
            source: BackupPromptSource.auto,
            onDone: goToMenu,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _createFromRolls() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RollEntryScreen(
          mode: RollEntryMode.create,
          onComplete: (rolls) async {
            await Identity.saveWizardName(_nameController.text.trim());
            final seed = await deriveSeedFromRolls(rolls);
            final identity = await Identity.overwriteWithSeed(seed);
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => BackupPromptScreen(
                  identity: identity,
                  source: BackupPromptSource.rolls,
                  rolls: rolls,
                  onDone: goToMenu,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _restoreFromFile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RestoreFileScreen(onRestored: (_) => goToMenu(context)),
      ),
    );
  }

  void _restoreFromRolls() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RollEntryScreen(
          mode: RollEntryMode.restore,
          onComplete: (rolls) async {
            final seed = await deriveSeedFromRolls(rolls);
            await Identity.overwriteWithSeed(seed);
            // Restoring means the player already has a backup -- that's how
            // they got these rolls -- so there's no post-restore backup
            // prompt, straight to the menu.
            if (!mounted) return;
            goToMenu(context);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canForge = !_busy && _nameEntered;
    return ParchmentScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text('FORGE YOUR RUNEKEY', textAlign: TextAlign.center, style: manuscriptHeaderStyle(fontSize: 28)),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            style: manuscriptBodyStyle(fontSize: 16),
            decoration: InputDecoration(
              labelText: 'Wizard Name',
              labelStyle: manuscriptCaptionStyle(),
              hintText: 'Enter your wizard name',
              hintStyle: manuscriptCaptionStyle(),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: kInkColor, width: 1),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: kInkColor, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your Runekey is your wizard identity — generated and kept only on '
            'this device, never on a server. Choose how to forge or restore it.',
            textAlign: TextAlign.center,
            style: manuscriptBodyStyle(fontSize: 14),
          ),
          const SizedBox(height: 32),
          IlluminatedButton(
            label: 'CREATE NEW (QUICK)',
            onTap: canForge ? _createAuto : null,
          ),
          const SizedBox(height: 4),
          Text(
            'A random key, generated instantly by your device.',
            textAlign: TextAlign.center,
            style: manuscriptCaptionStyle(),
          ),
          const SizedBox(height: 16),
          IlluminatedButton(
            label: 'CREATE NEW (THE RITE OF FOUR-AND-TWENTY)',
            onTap: canForge ? _createFromRolls : null,
          ),
          const SizedBox(height: 4),
          Text(
            'Roll a d20 24 times and hand-forge your key — recordable on a paper sigil.',
            textAlign: TextAlign.center,
            style: manuscriptCaptionStyle(),
          ),
          const SizedBox(height: 16),
          IlluminatedButton(
            label: 'RESTORE FROM BACKUP FILE',
            primary: false,
            onTap: _busy ? null : _restoreFromFile,
          ),
          const SizedBox(height: 16),
          IlluminatedButton(
            label: 'RESTORE FROM ROLLS',
            primary: false,
            onTap: _busy ? null : _restoreFromRolls,
          ),
        ],
      ),
    );
  }
}
