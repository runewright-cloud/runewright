// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_wire.dart — framing for the battle protocol layer.
//
// Type bytes 0x10–0x4F; intentionally non-overlapping with the
// proof-exchange MsgType bytes (0x01–0x07) in lib/protocol/wire.dart.
// Framing format is identical: [1 byte type][4 byte BE length][payload].
// BattleFrameReader reimplements FrameReader against BattleMsgType rather
// than modifying wire.dart and mixing concerns.
//
// See docs/BATTLE_PROTOCOL.md §1-§2 for the full message catalogue.

import 'dart:async';
import 'dart:typed_data';

enum BattleMsgType {
  // Session setup (§2)
  capabilities(0x10),
  matchConfig(0x11),
  matchConfigAck(0x12),
  matchConfigReject(0x13),
  bookCommit(0x14),
  bookHash(0x15),    // Option 2: SHA-256(sorted leaf bytes) exchanged at handshake
  bookReveal(0x16),  // Option 2: sorted commitmentHex list sent at match end

  // Commit-reveal entropy (§3)
  nonceCommit(0x20),
  nonceReveal(0x21),
  // Mid-resolution entropy refresh (§3b — interactive spell effects)
  refreshEntropyCommit(0x22),
  refreshEntropyReveal(0x23),

  // Turn loop (§2)
  moveCommit(0x30),
  moveReveal(0x31),
  spellCast(0x32),   // legacy / reserved
  haymaker(0x33),    // legacy / reserved
  stateHash(0x34),
  actionCommit(0x35),
  actionReveal(0x36),
  delayedSpellReveal(0x37),

  // Match control (§2)
  forfeit(0x40),
  matchEnd(0x41);

  const BattleMsgType(this.byte);
  final int byte;

  static BattleMsgType fromByte(int b) => BattleMsgType.values.firstWhere(
        (t) => t.byte == b,
        orElse: () => throw ArgumentError('unknown BattleMsgType byte 0x${b.toRadixString(16)}'),
      );
}

class BattleFrame {
  BattleFrame(this.type, this.payload);

  final BattleMsgType type;
  final Uint8List payload;

  Uint8List encode() {
    final out = BytesBuilder();
    out.addByte(type.byte);
    final lenBytes = ByteData(4)..setUint32(0, payload.length, Endian.big);
    out.add(lenBytes.buffer.asUint8List());
    out.add(payload);
    return out.toBytes();
  }
}

/// Reassembles a byte stream into discrete [BattleFrame]s.
///
/// Identical to FrameReader in wire.dart but typed to [BattleMsgType].
/// Broadcast stream so multiple callers can subscribe simultaneously —
/// required for the bidirectional battle session (unlike MatchSession's
/// strict request/response).
class BattleFrameReader {
  final _buffer = BytesBuilder();
  final _controller = StreamController<BattleFrame>.broadcast();

  Stream<BattleFrame> get frames => _controller.stream;

  void addChunk(List<int> chunk) {
    _buffer.add(chunk);
    _drain();
  }

  void _drain() {
    var bytes = _buffer.toBytes();
    while (true) {
      if (bytes.length < 5) break;
      final len = ByteData.sublistView(bytes, 1, 5).getUint32(0, Endian.big);
      final frameLen = 5 + len;
      if (bytes.length < frameLen) break;
      final type = BattleMsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _controller.add(BattleFrame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  Future<void> close() => _controller.close();
}
