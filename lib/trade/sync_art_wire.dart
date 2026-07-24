// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_wire.dart — framing for the Commune/Sync Art protocol layer.
//
// Type bytes 0x60–0x6F; intentionally non-overlapping with the
// proof-exchange MsgType bytes (0x01–0x07, lib/protocol/wire.dart), the
// battle protocol's BattleMsgType bytes (0x10–0x4F, battle_wire.dart), and
// the Commune/Trade protocol's TradeMsgType bytes (0x50–0x5F,
// lib/trade/trade_wire.dart). Framing format is identical:
// [1 byte type][4 byte BE length][payload]. SyncArtFrameReader reimplements
// FrameReader against SyncArtMsgType, matching TradeFrameReader's convention
// rather than genericizing wire.dart and mixing concerns.
//
// Like the trade wire (and unlike the battle wire's raw-binary preference),
// sync-art payloads are UTF-8 JSON: low-frequency, small messages, and every
// payload object here already has toJson()/fromJson() (see
// sync_art_session.dart) — encoding as JSON avoids a second serialization
// scheme for no benefit.

import 'dart:async';
import 'dart:typed_data';

enum SyncArtMsgType {
  // Pairing handshake (mirrors trade's tradeHello/tradeHelloAck)
  syncHello(0x60),
  syncHelloAck(0x61),

  // Reconciliation (see sync_art_session.dart)
  wantlist(0x62),
  artBundle(0x63),
  syncDone(0x64);

  const SyncArtMsgType(this.byte);
  final int byte;

  static SyncArtMsgType fromByte(int b) => SyncArtMsgType.values.firstWhere(
        (t) => t.byte == b,
        orElse: () => throw ArgumentError('unknown SyncArtMsgType byte 0x${b.toRadixString(16)}'),
      );
}

class SyncArtFrame {
  SyncArtFrame(this.type, this.payload);

  final SyncArtMsgType type;
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

/// Reassembles a byte stream into discrete [SyncArtFrame]s.
///
/// Identical to FrameReader in wire.dart but typed to [SyncArtMsgType].
/// Broadcast stream so multiple callers can subscribe simultaneously.
class SyncArtFrameReader {
  final _buffer = BytesBuilder();
  final _controller = StreamController<SyncArtFrame>.broadcast();

  Stream<SyncArtFrame> get frames => _controller.stream;

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
      final type = SyncArtMsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _controller.add(SyncArtFrame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  Future<void> close() => _controller.close();
}
