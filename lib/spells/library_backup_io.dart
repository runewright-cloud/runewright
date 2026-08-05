// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_backup_io.dart — platform file save/pick glue for library
// backups. Mirrors lib/identity/backup_io.dart's pattern: one plugin
// (`file_picker`) covers both directions without needing a writable
// filesystem path (Android scoped storage). UI-adjacent glue, not
// independently unit-tested -- the encode/decode/merge logic it wraps
// (`library_backup.dart`) is.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'library_backup.dart';

/// Exports the on-device library via the platform's save/share sheet.
/// Returns the chosen path, or null if the player cancelled.
Future<String?> exportLibraryToFile() async {
  final json = await exportLibraryBackup();
  return FilePicker.saveFile(
    dialogTitle: 'Save Runewright library backup',
    fileName: 'runewright_library_backup.json',
    bytes: Uint8List.fromList(utf8.encode(json)),
  );
}

/// Lets the player pick a library backup file and additively imports it
/// (see library_backup.dart -- nothing already on disk is overwritten).
/// Returns null if the player cancelled the picker.
Future<LibraryImportSummary?> importLibraryFromFile() async {
  final result = await FilePicker.pickFiles(
    dialogTitle: 'Select a Runewright library backup',
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;

  final bytes = result.files.single.bytes;
  if (bytes == null) {
    throw StateError('file_picker returned no data for the selected file (withData: true should prevent this)');
  }
  return importLibraryBackup(utf8.decode(bytes));
}
