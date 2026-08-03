// SPDX-License-Identifier: GPL-3.0-or-later
//
// backup_io.dart — platform file save/pick glue for identity backups.
//
// One plugin (`file_picker`) covers both directions: `saveFile(bytes:)`
// hands the export to the platform's save/share sheet without needing a
// writable filesystem path (Android scoped storage), and
// `pickFiles(withData: true)` reads an imported file's bytes the same way.
// This is UI-adjacent glue, not independently unit-tested -- the core
// encode/decode/crypto logic it wraps (`backup.dart`) is.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'backup.dart';
import 'identity.dart';

/// Exports [identity] via the platform's save/share sheet. Returns the
/// chosen path, or null if the player cancelled.
Future<String?> exportIdentityToFile(
  Identity identity, {
  String? passphrase,
  bool acknowledgedPlaintextRisk = false,
}) async {
  final backupText = await exportIdentityBackup(
    identity,
    passphrase: passphrase,
    acknowledgedPlaintextRisk: acknowledgedPlaintextRisk,
  );
  return FilePicker.saveFile(
    dialogTitle: 'Save Runewright identity backup',
    fileName: 'runewright_identity_backup.txt',
    bytes: Uint8List.fromList(utf8.encode(backupText)),
  );
}

/// Lets the player pick a backup file and imports it, **overwriting** the
/// current on-device identity. Returns null if the player cancelled the
/// picker. The caller's UI is responsible for confirming the destructive
/// overwrite with the player before passing `confirmOverwrite: true`.
Future<Identity?> importIdentityFromFile({
  String? passphrase,
  required bool confirmOverwrite,
}) async {
  final result = await FilePicker.pickFiles(
    dialogTitle: 'Select a Runewright identity backup',
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;

  final bytes = result.files.single.bytes;
  if (bytes == null) {
    throw StateError('file_picker returned no data for the selected file (withData: true should prevent this)');
  }
  return importIdentityBackup(
    utf8.decode(bytes),
    passphrase: passphrase,
    confirmOverwrite: confirmOverwrite,
  );
}
