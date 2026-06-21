// SPDX-License-Identifier: GPL-3.0-or-later
//
// backup_format.dart — the on-the-wire shape of an identity backup.
//
// Self-describing (magic + version) so a future format change fails loudly
// on import rather than corrupt-importing. PEM-style text armor (base64
// between BEGIN/END markers) so the file survives email/messaging channels
// that mangle raw binary.
//
// Binary payload (before armoring):
//   [4B magic "RWIB"][1B version]
//   [1B encrypted flag: 0x00 plaintext, 0x01 encrypted]
//   if plaintext:
//     [1B seed length][seed bytes]
//   if encrypted:
//     [1B kdf id: 0x01 = Argon2id]
//     [4B BE memory (KiB)][4B BE iterations][4B BE parallelism]
//     [1B salt length][salt bytes]
//     [1B nonce length][nonce bytes]      -- XChaCha20-Poly1305AEAD, 24B
//     [1B mac length][mac bytes]          -- Poly1305, 16B
//     [4B BE ciphertext length][ciphertext bytes]
//
// Crypto choices: Argon2id (OWASP-recommended interactive minimum: 19 MiB
// memory, 2 iterations, parallelism 1) deriving a key for
// XChaCha20-Poly1305 AEAD (192-bit nonce -- large enough to pick randomly
// per export with negligible collision risk, unlike plain ChaCha20's 96-bit
// nonce). Both are part of `package:cryptography`, a vetted library --
// nothing here is hand-rolled.

import 'dart:convert';
import 'dart:typed_data';

const _kMagic = [0x52, 0x57, 0x49, 0x42]; // "RWIB"
const _kVersion1 = 0x01;
const _kKdfArgon2id = 0x01;

const kArgon2idMemoryKib = 19456; // OWASP-recommended interactive minimum
const kArgon2idIterations = 2;
const kArgon2idParallelism = 1;

const _kArmorBegin = '-----BEGIN RUNEWRIGHT IDENTITY BACKUP-----';
const _kArmorEnd = '-----END RUNEWRIGHT IDENTITY BACKUP-----';

class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

/// The decoded (but still possibly-encrypted) contents of a backup file.
class DecodedBackup {
  DecodedBackup.plaintext(this.seedBytes)
      : isEncrypted = false,
        kdfMemoryKib = null,
        kdfIterations = null,
        kdfParallelism = null,
        salt = null,
        nonce = null,
        mac = null,
        ciphertext = null;

  DecodedBackup.encrypted({
    required this.kdfMemoryKib,
    required this.kdfIterations,
    required this.kdfParallelism,
    required this.salt,
    required this.nonce,
    required this.mac,
    required this.ciphertext,
  })  : isEncrypted = true,
        seedBytes = null;

  final bool isEncrypted;
  final Uint8List? seedBytes; // present iff !isEncrypted
  final int? kdfMemoryKib;
  final int? kdfIterations;
  final int? kdfParallelism;
  final Uint8List? salt;
  final Uint8List? nonce;
  final Uint8List? mac;
  final Uint8List? ciphertext;
}

class _ByteWriter {
  final _out = BytesBuilder();
  void addByte(int b) => _out.addByte(b);
  void addBytes(List<int> b) => _out.add(b);
  void addU32(int v) => _out.add((ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List());
  void addLengthPrefixedByte(List<int> b) {
    if (b.length > 0xff) throw ArgumentError('field too long for 1-byte length prefix: ${b.length}');
    addByte(b.length);
    addBytes(b);
  }

  Uint8List toBytes() => _out.toBytes();
}

class _ByteReader {
  _ByteReader(this._bytes);
  final Uint8List _bytes;
  int _offset = 0;

  int readByte() {
    if (_offset >= _bytes.length) throw BackupFormatException('unexpected end of backup data');
    return _bytes[_offset++];
  }

  int readU32() {
    if (_offset + 4 > _bytes.length) throw BackupFormatException('unexpected end of backup data');
    final v = ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0, Endian.big);
    _offset += 4;
    return v;
  }

  Uint8List readBytes(int n) {
    if (_offset + n > _bytes.length) throw BackupFormatException('unexpected end of backup data');
    final out = Uint8List.sublistView(_bytes, _offset, _offset + n);
    _offset += n;
    return out;
  }

  Uint8List readLengthPrefixedByte() => readBytes(readByte());

  bool get isAtEnd => _offset >= _bytes.length;
}

/// Builds an unencrypted backup payload from a raw 32-byte Ed25519 seed.
Uint8List encodePlaintextPayload(List<int> seedBytes) {
  final w = _ByteWriter()
    ..addBytes(_kMagic)
    ..addByte(_kVersion1)
    ..addByte(0x00)
    ..addLengthPrefixedByte(seedBytes);
  return w.toBytes();
}

/// Builds an encrypted backup payload around an already-encrypted seed
/// (the caller does the Argon2id + XChaCha20-Poly1305 work in `backup.dart`,
/// which owns the `cryptography` package calls; this module only owns the
/// byte layout).
Uint8List encodeEncryptedPayload({
  required int memoryKib,
  required int iterations,
  required int parallelism,
  required List<int> salt,
  required List<int> nonce,
  required List<int> mac,
  required List<int> ciphertext,
}) {
  final w = _ByteWriter()
    ..addBytes(_kMagic)
    ..addByte(_kVersion1)
    ..addByte(0x01)
    ..addByte(_kKdfArgon2id)
    ..addU32(memoryKib)
    ..addU32(iterations)
    ..addU32(parallelism)
    ..addLengthPrefixedByte(salt)
    ..addLengthPrefixedByte(nonce)
    ..addLengthPrefixedByte(mac)
    ..addU32(ciphertext.length)
    ..addBytes(ciphertext);
  return w.toBytes();
}

DecodedBackup decodePayload(Uint8List bytes) {
  final r = _ByteReader(bytes);
  for (final expected in _kMagic) {
    if (r.isAtEnd || r.readByte() != expected) {
      throw BackupFormatException('not a Runewright identity backup (bad magic)');
    }
  }
  final version = r.readByte();
  if (version != _kVersion1) {
    throw BackupFormatException('unsupported backup format version $version');
  }
  final encrypted = r.readByte();
  if (encrypted == 0x00) {
    final seed = r.readLengthPrefixedByte();
    if (seed.length != 32) {
      throw BackupFormatException('malformed backup: seed is ${seed.length} bytes, expected 32');
    }
    return DecodedBackup.plaintext(seed);
  } else if (encrypted == 0x01) {
    final kdfId = r.readByte();
    if (kdfId != _kKdfArgon2id) {
      throw BackupFormatException('unsupported KDF id $kdfId');
    }
    final memoryKib = r.readU32();
    final iterations = r.readU32();
    final parallelism = r.readU32();
    final salt = r.readLengthPrefixedByte();
    final nonce = r.readLengthPrefixedByte();
    final mac = r.readLengthPrefixedByte();
    final ciphertextLen = r.readU32();
    final ciphertext = r.readBytes(ciphertextLen);
    return DecodedBackup.encrypted(
      kdfMemoryKib: memoryKib,
      kdfIterations: iterations,
      kdfParallelism: parallelism,
      salt: salt,
      nonce: nonce,
      mac: mac,
      ciphertext: ciphertext,
    );
  } else {
    throw BackupFormatException('malformed backup: bad encrypted flag $encrypted');
  }
}

/// Wraps a binary payload in PEM-style text armor.
String armor(Uint8List payload) {
  final b64 = base64.encode(payload);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return [_kArmorBegin, ...lines, _kArmorEnd].join('\n');
}

/// Inverse of [armor]. Throws [BackupFormatException] if the markers are
/// missing -- a clear, specific failure rather than a base64 decode crash.
Uint8List unarmor(String text) {
  final beginIdx = text.indexOf(_kArmorBegin);
  final endIdx = text.indexOf(_kArmorEnd);
  if (beginIdx == -1 || endIdx == -1 || endIdx < beginIdx) {
    throw BackupFormatException('not a Runewright identity backup (missing BEGIN/END markers)');
  }
  final body = text.substring(beginIdx + _kArmorBegin.length, endIdx).trim();
  try {
    return base64.decode(body.replaceAll(RegExp(r'\s+'), ''));
  } on FormatException {
    throw BackupFormatException('not a Runewright identity backup (invalid base64)');
  }
}
