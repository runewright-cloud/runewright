// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_wire.dart — framing for the Commune/Trade protocol layer.
//
// Type bytes 0x50–0x5F; intentionally non-overlapping with the
// proof-exchange MsgType bytes (0x01–0x07, lib/protocol/wire.dart) and the
// battle protocol's BattleMsgType bytes (0x10–0x4F, battle_wire.dart).
// Framing format is identical: [1 byte type][4 byte BE length][payload].
// TradeFrameReader reimplements FrameReader against TradeMsgType, matching
// the existing convention (see battle_wire.dart's BattleFrameReader) rather
// than genericizing wire.dart and mixing concerns.
//
// Unlike the battle wire (raw binary payloads), trade payloads are UTF-8
// JSON: trade is a low-frequency, small-message protocol and every payload
// object here already has toJson()/fromJson() (SpellPermission, SpellAsset,
// TradeOffer) -- encoding as JSON avoids a second serialization scheme for
// no benefit.
//
// Broadcast, not request/response: like BattleSession (and unlike
// MatchSession's strict single-Completer request/response), both trade
// peers can send simultaneously (offers, confirms) -- see trade_session.dart.

import 'dart:async';
import 'dart:typed_data';

enum TradeMsgType {
  // Pairing handshake
  tradeHello(0x50),
  tradeHelloAck(0x51),

  // Offer exchange (advisory preview -- see trade_session.dart)
  offer(0x52),

  // Mutual agreement gate
  confirm(0x53),
  cancel(0x54),

  // Grant delivery (post mutual-confirm)
  grantBundle(0x55),
  bundleAck(0x56);

  const TradeMsgType(this.byte);
  final int byte;

  static TradeMsgType fromByte(int b) => TradeMsgType.values.firstWhere(
        (t) => t.byte == b,
        orElse: () => throw ArgumentError('unknown TradeMsgType byte 0x${b.toRadixString(16)}'),
      );
}

class TradeFrame {
  TradeFrame(this.type, this.payload);

  final TradeMsgType type;
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

/// Reassembles a byte stream into discrete [TradeFrame]s.
///
/// Identical to FrameReader in wire.dart but typed to [TradeMsgType].
/// Broadcast stream so multiple callers can subscribe simultaneously.
class TradeFrameReader {
  final _buffer = BytesBuilder();
  final _controller = StreamController<TradeFrame>.broadcast();

  Stream<TradeFrame> get frames => _controller.stream;

  void addChunk(List<int> chunk) {
    // A late chunk after close (the socket's onDone/onError closes this
    // reader -- see trade_session.dart) would otherwise throw on _drain's
    // _controller.add.
    if (_controller.isClosed) return;
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
      final type = TradeMsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _controller.add(TradeFrame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  Future<void> close() => _controller.close();
}
