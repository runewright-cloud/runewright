// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/backup.dart';
import 'package:rune_duel/identity/backup_format.dart';
import 'package:rune_duel/identity/identity.dart';

import 'fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    installFakeSecureStorage();
  });

  test('plaintext round-trip: export then import recovers the same key', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, acknowledgedPlaintextRisk: true);

    final restored = await importIdentityBackup(backupText, confirmOverwrite: true);

    expect(restored.publicKeyBytes, original.publicKeyBytes);
    expect(restored.keyHiHex, original.keyHiHex);
    expect(restored.keyLoHex, original.keyLoHex);
  });

  test('plaintext export without acknowledging the risk throws', () async {
    final identity = await Identity.ephemeral();
    expect(
      () => exportIdentityBackup(identity),
      throwsA(isA<PlaintextExportNotAcknowledgedException>()),
    );
  });

  test('encrypted round-trip with the correct passphrase recovers the same key', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, passphrase: 'correct horse battery staple');

    final restored = await importIdentityBackup(
      backupText,
      passphrase: 'correct horse battery staple',
      confirmOverwrite: true,
    );

    expect(restored.publicKeyBytes, original.publicKeyBytes);
  });

  test('wrong passphrase is rejected', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, passphrase: 'correct horse battery staple');

    expect(
      () => importIdentityBackup(backupText, passphrase: 'wrong guess', confirmOverwrite: true),
      throwsA(isA<WrongPassphraseException>()),
    );
  });

  test('missing passphrase on an encrypted backup is rejected', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, passphrase: 'correct horse battery staple');

    expect(
      () => importIdentityBackup(backupText, confirmOverwrite: true),
      throwsA(isA<WrongPassphraseException>()),
    );
  });

  test('malformed file (not a backup at all) is rejected cleanly', () async {
    expect(
      () => importIdentityBackup('not a backup file', confirmOverwrite: true),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('unknown format version is rejected cleanly', () async {
    final payload = encodePlaintextPayload(List.filled(32, 7));
    // Flip the version byte (index 4, right after the 4-byte magic) to an
    // unrecognized value.
    final tampered = Uint8List.fromList(payload);
    tampered[4] = 0x99;
    final text = armor(tampered);

    expect(
      () => importIdentityBackup(text, confirmOverwrite: true),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('truncated/corrupt payload is rejected cleanly, not a crash', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, acknowledgedPlaintextRisk: true);
    final truncated = backupText.substring(0, backupText.length - 20);

    expect(
      () => importIdentityBackup(truncated, confirmOverwrite: true),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('import without confirmOverwrite is refused and does not touch the stored identity', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, acknowledgedPlaintextRisk: true);

    // ignore: missing_required_param -- deliberately omitted to prove the default-less, required gate
    expect(
      () => importIdentityBackup(backupText, confirmOverwrite: false),
      throwsA(isA<ImportNotConfirmedException>()),
    );

    // Confirms nothing was written: a fresh loadOrCreate() still creates a
    // brand-new identity rather than finding the refused import's key.
    final stillNothingStored = await Identity.loadOrCreate();
    expect(stillNothingStored.publicKeyBytes, isNot(original.publicKeyBytes));
  });

  test('import-overwrites-confirmed: a subsequent loadOrCreate sees the imported identity', () async {
    final original = await Identity.ephemeral();
    final backupText = await exportIdentityBackup(original, acknowledgedPlaintextRisk: true);

    await importIdentityBackup(backupText, confirmOverwrite: true);

    final loaded = await Identity.loadOrCreate();
    expect(loaded.publicKeyBytes, original.publicKeyBytes);
  });
}
