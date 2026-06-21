// SPDX-License-Identifier: GPL-3.0-or-later
//
// backup_prompt_screen.dart — shown once after a *new* key is created
// (never after a restore, since restoring means the player already has a
// backup in hand). Per the brief: an auto-generated key has no recordable
// rolls, so only the encrypted file export applies; a Rite-of-Four-and-
// Twenty key gets both the file export and the paper sigil.
//
// The sigil *image* renderer is blocked on `sigil_concept.html`, which
// hasn't been added to the repo yet (docs/step1_identity_onboarding_brief.md
// says Soren will provide it as the geometry/aesthetic spec -- "do not
// invent a different encoding"). Rather than fake a placeholder graphic
// that looks like a finished feature, the rolls source instead offers a
// plain text view of the 24 recorded rolls (in canonical slot order) as a
// stopgap recordable artifact, clearly labeled as pending the real sigil.
//
// Skip friction (Soren decision): the skip path is gated behind an
// explicit checkbox acknowledgment, not just a tap -- "Continue" stays
// disabled until either the file export succeeds or the risk checkbox is
// checked.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../identity/backup_io.dart';
import '../../identity/identity.dart';
import '../manuscript_theme.dart';
import 'roll_entry_screen.dart' show kElementOrder, kSlotsPerElement;

enum BackupPromptSource { auto, rolls }

const String kBackupWarningText =
    "You probably want to backup your Runekey up in a really secure place. "
    "Like for real. No one will ever has access to this other than you and"
    " the people you allow access to it.Losing access to your Runekey (because "
    "you dropped your spellbook in a lake or something) means you'd have to"
    "rebuild all your spells from scratch, even if you back them up. Also, if "
    "someone else gains access to your Runekey... well probably nothing will "
    "happen. But theoretically if it was found by a both mean and motivated"
    " individual they could access spells crafted by you, impersonate you"
    " in narrative interactions, and babies may become unable to distinguish "
    " you from your key thief. etc... You've been warned, there's like a whole "
    "checkbox saying you understand. And I'm pretty sure those are like sacred."
    ;

class BackupPromptScreen extends StatefulWidget {
  const BackupPromptScreen({
    super.key,
    required this.identity,
    required this.source,
    required this.onDone,
    this.rolls,
  });

  final Identity identity;
  final BackupPromptSource source;

  /// Only set when [source] is [BackupPromptSource.rolls].
  final List<int>? rolls;

  /// Called with this screen's own [BuildContext] (not a context captured
  /// by some earlier, possibly-now-unmounted onboarding screen) once the
  /// player is ready to proceed -- see `onboarding_landing_screen.dart`'s
  /// `goToMenu` doc comment for why this takes a context instead of being
  /// a plain [VoidCallback].
  final void Function(BuildContext context) onDone;

  @override
  State<BackupPromptScreen> createState() => _BackupPromptScreenState();
}

class _BackupPromptScreenState extends State<BackupPromptScreen> {
  final _passphraseController = TextEditingController();
  bool _exported = false;
  bool _exporting = false;
  bool _acknowledgedSkipRisk = false;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _exportFile() async {
    if (_passphraseController.text.isEmpty) {
      setState(() => _error = 'Choose a passphrase to encrypt the file.');
      return;
    }
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final path = await exportIdentityToFile(widget.identity, passphrase: _passphraseController.text);
      if (path != null && mounted) {
        setState(() => _exported = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Key file saved.')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showRollsText() {
    final rolls = widget.rolls!;
    final text = rolls.join(', ');
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: kParchmentColor,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('YOUR FOUR-AND-TWENTY ROLLS', style: manuscriptHeaderStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                'The hand-drawable sigil glyph is coming soon. For now, record these '
                '24 values (Fire, then Wind, then Water, then Earth — 6 each, in order) '
                'somewhere safe; re-entering them exactly restores this Runekey.',
                style: manuscriptCaptionStyle(),
              ),
              const SizedBox(height: 12),
              for (var e = 0; e < kElementOrder.length; e++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${kElementOrder[e].name}: '
                    '${rolls.sublist(e * kSlotsPerElement, (e + 1) * kSlotsPerElement).join(", ")}',
                    style: manuscriptBodyStyle(fontSize: 14),
                  ),
                ),
              const SizedBox(height: 16),
              IlluminatedButton(
                label: 'COPY TO CLIPBOARD',
                onTap: () {
                  Clipboard.setData(ClipboardData(text: text));
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRolls = widget.source == BackupPromptSource.rolls;
    final canContinue = _exported || _acknowledgedSkipRisk;
    return ParchmentScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ManuscriptBackButton(),
          const SizedBox(height: 4),
          Text('BACK UP YOUR RUNEKEY', textAlign: TextAlign.center, style: manuscriptHeaderStyle(fontSize: 22)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: kRubricRed),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(kBackupWarningText, style: manuscriptBodyStyle(fontSize: 13, color: kRubricRed)),
          ),
          const SizedBox(height: 20),
          Text(
            isRolls
                ? 'Since you forged this key by hand, you can back it up two ways:'
                : 'This key was generated automatically, so it has no recordable rolls — '
                    'only the encrypted file backup applies.',
            style: manuscriptBodyStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passphraseController,
            obscureText: true,
            style: manuscriptBodyStyle(fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Passphrase to encrypt the key file',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: manuscriptBodyStyle(fontSize: 13, color: kRubricRed)),
          ],
          const SizedBox(height: 12),
          IlluminatedButton(
            label: _exported ? 'KEY FILE SAVED ✓' : (_exporting ? 'SAVING…' : 'EXPORT ENCRYPTED KEY FILE'),
            onTap: _exporting ? null : _exportFile,
          ),
          if (isRolls) ...[
            const SizedBox(height: 12),
            IlluminatedButton(
              label: 'VIEW MY SIGIL ROLLS (IMAGE COMING SOON)',
              primary: false,
              onTap: _showRollsText,
            ),
          ],
          const SizedBox(height: 20),
          CheckboxListTile(
            value: _acknowledgedSkipRisk,
            onChanged: (v) => setState(() => _acknowledgedSkipRisk = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'I understand the risk and choose to continue without backing up now.',
              style: manuscriptBodyStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          IlluminatedButton(
            label: 'CONTINUE',
            onTap: canContinue ? () => widget.onDone(context) : null,
          ),
        ],
      ),
    );
  }
}
