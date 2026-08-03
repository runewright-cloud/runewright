// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_io.dart — platform file-pick glue for custom spell art import.
//
// Mirrors lib/identity/backup_io.dart's pattern: file_picker's
// `pickFiles(withData: true)` reads the chosen file's bytes without needing
// a platform-specific path. Picking is kept separate from the decode/
// re-encode work in spell_art_import.dart so a caller can show a progress
// indicator around just the (potentially slow) import step, not the
// unbounded time the player spends in the native file-choose UI. This file
// is UI-adjacent glue, not independently unit-tested.

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Lets the player pick an image file (PNG/JPEG/WebP) and returns its raw
/// bytes, unvalidated. Returns null if the player cancelled the picker.
/// Pass the result to [importSpellArt] (spell_art_import.dart) to validate/
/// decode/re-encode it.
Future<Uint8List?> pickSpellArtFile() async {
  final result = await FilePicker.pickFiles(
    dialogTitle: 'Select custom spell art',
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  return result.files.single.bytes;
}
