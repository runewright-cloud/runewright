// SPDX-License-Identifier: GPL-3.0-or-later
//
// restore_file_screen.dart — onboarding wiring around the existing M4
// backup import (`lib/identity/backup_io.dart`). This screen owns no
// crypto or file-format logic, only the passphrase prompt and error
// surfacing around `importIdentityFromFile`.

import 'package:flutter/material.dart';

import '../../identity/backup.dart';
import '../../identity/backup_format.dart';
import '../../identity/backup_io.dart';
import '../../identity/identity.dart';
import '../manuscript_theme.dart';

class RestoreFileScreen extends StatefulWidget {
  const RestoreFileScreen({super.key, required this.onRestored});

  /// Called once a backup file has been successfully decrypted and the
  /// on-device identity overwritten.
  final void Function(Identity identity) onRestored;

  @override
  State<RestoreFileScreen> createState() => _RestoreFileScreenState();
}

class _RestoreFileScreenState extends State<RestoreFileScreen> {
  final _passphraseController = TextEditingController();
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _chooseAndRestore() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final passphrase = _passphraseController.text.isEmpty ? null : _passphraseController.text;
      final identity = await importIdentityFromFile(
        passphrase: passphrase,
        confirmOverwrite: true,
      );
      if (identity == null) {
        // Player cancelled the file picker -- not an error.
        return;
      }
      widget.onRestored(identity);
    } on WrongPassphraseException {
      setState(() => _error = 'Wrong passphrase — or this backup needs one. Try again.');
    } on BackupFormatException catch (e) {
      setState(() => _error = 'That doesn\'t look like a Runewright identity backup (${e.message}).');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ParchmentScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ManuscriptBackButton(),
          const SizedBox(height: 4),
          Text('RESTORE FROM BACKUP FILE', textAlign: TextAlign.center, style: manuscriptHeaderStyle(fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            'Choose the encrypted key file you saved earlier. This replaces any '
            'Runekey on this device.',
            textAlign: TextAlign.center,
            style: manuscriptBodyStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _passphraseController,
            obscureText: true,
            style: manuscriptBodyStyle(fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Passphrase (leave blank if unencrypted)',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: manuscriptBodyStyle(fontSize: 13, color: kRubricRed)),
          ],
          const SizedBox(height: 20),
          IlluminatedButton(
            label: _working ? 'WORKING…' : 'CHOOSE FILE & RESTORE',
            onTap: _working ? null : _chooseAndRestore,
          ),
        ],
      ),
    );
  }
}
