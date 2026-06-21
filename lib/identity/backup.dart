// SPDX-License-Identifier: GPL-3.0-or-later
//
// backup.dart — manual export/import of the on-device identity.
//
// Design decision (Soren): no server, full player autonomy. The player
// exports a backup file (handed to whatever share/save sheet the platform
// offers) and imports one to restore an identity on a new device or after
// reinstall. CLAUDE.md hard invariant 7 ("no recovery backdoor") is about
// *this app* never phoning home for recovery -- it doesn't forbid a
// player-initiated, player-controlled local export. The player choosing to
// copy their own key to their own cloud is their call, not this app's.
//
// Encryption is on by default (a leaked backup file is a leaked private
// key otherwise); plaintext export is allowed but requires the caller to
// have shown an explicit warning first (`acknowledgedPlaintextRisk`).
//
// Key rotation note: importing a *different* key than the one currently on
// this device is, semantically, a key rotation event. Any in-flight
// delegations (master/apprentice loans, scrolls) bound to the old
// owner_pubkey are not re-signed by this code -- that's a later-layer
// concern (delegation system doesn't exist yet) and is flagged here, not
// silently forgotten. See docs/M4_findings.md.

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_format.dart';
import 'identity.dart';

class WrongPassphraseException implements Exception {
  @override
  String toString() => 'WrongPassphraseException: passphrase did not decrypt this backup';
}

class PlaintextExportNotAcknowledgedException implements Exception {
  @override
  String toString() =>
      'PlaintextExportNotAcknowledgedException: plaintext export requires acknowledgedPlaintextRisk: true';
}

class ImportNotConfirmedException implements Exception {
  @override
  String toString() =>
      'ImportNotConfirmedException: importing overwrites the current on-device identity; '
      'requires confirmOverwrite: true';
}

final _xchacha = Xchacha20.poly1305Aead();
final _secureRandom = Random.secure();

Uint8List _randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _secureRandom.nextInt(256)));

/// Exports [identity] as PEM-armored backup text.
///
/// If [passphrase] is non-null, the seed is encrypted (Argon2id ->
/// XChaCha20-Poly1305) before encoding. If [passphrase] is null, the export
/// is **plaintext** and the caller must pass `acknowledgedPlaintextRisk:
/// true` -- the UI is responsible for showing the "anyone who gets this
/// file owns your identity" warning before that flag is ever true.
Future<String> exportIdentityBackup(
  Identity identity, {
  String? passphrase,
  bool acknowledgedPlaintextRisk = false,
}) async {
  final seed = await identity.exportSeedBytes();

  if (passphrase == null) {
    if (!acknowledgedPlaintextRisk) {
      throw PlaintextExportNotAcknowledgedException();
    }
    return armor(encodePlaintextPayload(seed));
  }

  final kdf = Argon2id(
    memory: kArgon2idMemoryKib,
    iterations: kArgon2idIterations,
    parallelism: kArgon2idParallelism,
    hashLength: 32,
  );
  final salt = _randomBytes(16);
  final secretKey = await kdf.deriveKeyFromPassword(password: passphrase, nonce: salt);

  final nonce = _xchacha.newNonce();
  final secretBox = await _xchacha.encrypt(seed, secretKey: secretKey, nonce: nonce);

  final payload = encodeEncryptedPayload(
    memoryKib: kArgon2idMemoryKib,
    iterations: kArgon2idIterations,
    parallelism: kArgon2idParallelism,
    salt: salt,
    nonce: secretBox.nonce,
    mac: secretBox.mac.bytes,
    ciphertext: secretBox.cipherText,
  );
  return armor(payload);
}

/// Parses and (if encrypted) decrypts [armoredText], then **overwrites**
/// the on-device identity. Destructive: requires `confirmOverwrite: true`,
/// so the caller's UI must have already warned the player ("this replaces
/// your current wizard identity") before this can do anything.
///
/// Throws [BackupFormatException] for an unrecognized/malformed file,
/// [WrongPassphraseException] for a missing/bad passphrase on an encrypted
/// backup, and [ImportNotConfirmedException] if the destructive action
/// wasn't confirmed.
Future<Identity> importIdentityBackup(
  String armoredText, {
  String? passphrase,
  required bool confirmOverwrite,
}) async {
  if (!confirmOverwrite) {
    throw ImportNotConfirmedException();
  }

  final payload = unarmor(armoredText);
  final decoded = decodePayload(payload);

  final Uint8List seed;
  if (!decoded.isEncrypted) {
    seed = decoded.seedBytes!;
  } else {
    if (passphrase == null) {
      throw WrongPassphraseException();
    }
    final kdf = Argon2id(
      memory: decoded.kdfMemoryKib!,
      iterations: decoded.kdfIterations!,
      parallelism: decoded.kdfParallelism!,
      hashLength: 32,
    );
    final secretKey = await kdf.deriveKeyFromPassword(password: passphrase, nonce: decoded.salt!);
    final secretBox = SecretBox(decoded.ciphertext!, nonce: decoded.nonce!, mac: Mac(decoded.mac!));
    try {
      seed = Uint8List.fromList(await _xchacha.decrypt(secretBox, secretKey: secretKey));
    } on SecretBoxAuthenticationError {
      throw WrongPassphraseException();
    }
  }

  if (seed.length != 32) {
    throw BackupFormatException('malformed backup: decrypted seed is ${seed.length} bytes, expected 32');
  }

  return Identity.overwriteWithSeed(seed);
}
