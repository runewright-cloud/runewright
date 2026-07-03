// SPDX-License-Identifier: GPL-3.0-or-later
//
// identity.dart — on-device Ed25519 identity: keypair generation, secure
// storage, and the owner_pubkey binding used by the v2.4 circuit.
//
// CLAUDE.md hard invariant 7: identity is local and self-custodied. Keypair
// generated on first launch, stored on-device, no server, no account, no
// recovery backdoor. Losing the key is the user's risk (CIRCUIT_IO.md
// CIRCUIT_IO 12) -- this module implements bare on-device storage only; a
// deliberate export/backup flow is a separate product decision, not made
// here (flagged to Soren in the M4 plan, not silently decided).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ffi/identity.dart' as ffi;
import 'key_packing.dart';

const _kSeedStorageKey = 'runewright.identity.ed25519_seed_v1';
const _kWizardNameKey = 'runewright.identity.wizard_name_v1';

/// A loaded Ed25519 identity: the keypair plus its circuit-facing encoding.
class Identity {
  Identity._(this._keyPair, this.publicKeyBytes, this.keyHiHex, this.keyLoHex);

  final SimpleKeyPair _keyPair;

  /// Raw 32-byte Ed25519 public key.
  final Uint8List publicKeyBytes;

  /// `key_hi`/`key_lo` Field hex strings -- see key_packing.dart.
  final String keyHiHex;
  final String keyLoHex;

  static final _algorithm = Ed25519();
  static final _storage = FlutterSecureStorage();

  /// Persists the player's chosen wizard name. Not sensitive — stored
  /// alongside the key for convenience. Empty string clears it.
  static Future<void> saveWizardName(String name) async {
    await _storage.write(key: _kWizardNameKey, value: name);
  }

  /// Returns the stored wizard name, or null if none has been set.
  static Future<String?> loadWizardName() async {
    return _storage.read(key: _kWizardNameKey);
  }

  /// Wipes the on-device identity and wizard name — debug / testing use only.
  /// After calling this, [exists] returns false and the app will show
  /// onboarding on next launch (or navigate there manually).
  static Future<void> deleteOnDevice() async {
    await _storage.delete(key: _kSeedStorageKey);
    await _storage.delete(key: _kWizardNameKey);
  }

  /// Read-only boot check: is there already a Runekey on this device? Unlike
  /// [loadOrCreate], this never generates or persists anything -- it's what
  /// the onboarding router uses to decide between "proceed" and "show the
  /// four onboarding paths" without side effects.
  static Future<bool> exists() async {
    return await _storage.read(key: _kSeedStorageKey) != null;
  }

  /// Loads the on-device identity, generating and persisting a new Ed25519
  /// keypair on first launch. There is exactly one identity per device
  /// install -- no accounts, no multi-profile switching (out of scope).
  static Future<Identity> loadOrCreate() async {
    final existingSeedB64 = await _storage.read(key: _kSeedStorageKey);
    final SimpleKeyPair keyPair;
    if (existingSeedB64 != null) {
      final seed = base64Decode(existingSeedB64);
      keyPair = await _algorithm.newKeyPairFromSeed(seed);
    } else {
      keyPair = await _algorithm.newKeyPair();
      final seed = await keyPair.extractPrivateKeyBytes();
      await _storage.write(key: _kSeedStorageKey, value: base64Encode(seed));
    }
    return _fromKeyPair(keyPair);
  }

  /// A freshly generated identity that never touches secure storage --
  /// for protocol tests and any future non-persistent ("guest") flow. Not
  /// what the real game uses (loadOrCreate is, for the bestiary/anti-theft
  /// properties that depend on a stable per-device identity).
  static Future<Identity> ephemeral() async {
    return _fromKeyPair(await _algorithm.newKeyPair());
  }

  static Future<Identity> _fromKeyPair(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    final pubBytes = Uint8List.fromList(publicKey.bytes);
    final split = splitPubkeyToFieldHex(pubBytes);
    return Identity._(keyPair, pubBytes, split.keyHiHex, split.keyLoHex);
  }

  /// Raw 32-byte Ed25519 private seed -- for backup export
  /// (`lib/identity/backup.dart`) only. Treat the result as sensitive.
  Future<Uint8List> exportSeedBytes() async {
    return Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());
  }

  /// Overwrites the on-device identity with [seed] and returns the newly
  /// loaded [Identity]. **Destructive** -- the caller (`backup.dart`'s
  /// import flow) is responsible for confirming this with the user first;
  /// this method does not ask.
  static Future<Identity> overwriteWithSeed(List<int> seed) async {
    await _storage.write(key: _kSeedStorageKey, value: base64Encode(seed));
    return loadOrCreate();
  }

  /// `owner_pubkey = Poseidon2(key_hi, key_lo)` -- the public input this
  /// identity's inscription proofs must be witnessed with (CIRCUIT_IO.md
  /// CIRCUIT_IO 5). Computed via FFI, never reimplemented in Dart
  /// (CLAUDE.md hard invariant 1).
  Future<String> ownerPubkeyHex() => ffi.poseidon2Hash2(keyHiHex, keyLoHex);

  /// Signs [message] with this identity's private key.
  Future<List<int>> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return signature.bytes;
  }

  /// Verifies a signature produced by some peer's [sign], given the raw
  /// 32-byte Ed25519 public key they claim it came from. Static: this
  /// doesn't require a local [Identity] instance, since it checks someone
  /// else's signature against a presented (not locally held) public key.
  static Future<bool> verify({
    required List<int> message,
    required List<int> signatureBytes,
    required List<int> publicKeyBytes,
  }) {
    final publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519);
    return _algorithm.verify(
      message,
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
  }

  /// Recomputes `Poseidon2(split(presentedPubkeyBytes))` and checks it
  /// against a proof's `owner_pubkey` public input -- the cast-time check
  /// CIRCUIT_IO.md CIRCUIT_IO 5 requires of the verifying client: "the
  /// verifying client recomputes Poseidon2(split(presented_key)) and checks
  /// equality." This is what binds a *presented* raw Ed25519 key to a
  /// proof's opaque owner_pubkey hash.
  static Future<bool> ownerPubkeyMatches({
    required List<int> presentedPubkeyBytes,
    required String claimedOwnerPubkeyHex,
  }) async {
    final split = splitPubkeyToFieldHex(presentedPubkeyBytes);
    final recomputed = await ffi.poseidon2Hash2(split.keyHiHex, split.keyLoHex);
    return _fieldHexEquals(recomputed, claimedOwnerPubkeyHex);
  }
}

bool _fieldHexEquals(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}
