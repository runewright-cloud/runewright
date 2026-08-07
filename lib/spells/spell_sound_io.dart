// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_sound_io.dart — platform file-pick glue for custom spell sound
// import. Mirrors spell_art_io.dart. The `ogg` extension filter narrows the
// native picker dialog only -- it is not what decides validity; the magic-
// byte/container walk in spell_sound_import.dart is what actually decides
// (D-3: a renamed non-Ogg file must still be rejected).

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Lets the player pick an Ogg Vorbis file and returns its raw bytes,
/// unvalidated. Returns null if the player cancelled the picker. Pass the
/// result to [importSpellSound] (spell_sound_import.dart) to validate it.
Future<Uint8List?> pickSpellSoundFile() async {
  final result = await FilePicker.pickFiles(
    dialogTitle: 'Select custom spell sound',
    type: FileType.custom,
    allowedExtensions: ['ogg'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  return result.files.single.bytes;
}
