// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_wire.dart — framing for the Master/Apprentice protocol layer
// (docs/MASTER_APPRENTICE_PLAN.md §5.3).
//
// Type bytes 0x70–0x7F; intentionally non-overlapping with proof-exchange
// MsgType (0x01–0x07, lib/protocol/wire.dart), BattleMsgType (0x10–0x4F,
// battle_wire.dart), TradeMsgType (0x50–0x5F, lib/trade/trade_wire.dart), and
// SyncArtMsgType (0x60–0x6F, lib/trade/sync_art_wire.dart). Framing format is
// identical: [1 byte type][4 byte BE length][payload].
//
// Like trade_wire.dart (and unlike the battle wire's raw-binary preference),
// payloads here are UTF-8 JSON — this is a low-frequency, human-gated
// protocol and every payload object already has toJson()/fromJson().

import 'dart:async';
import 'dart:typed_data';

enum ApprenticeMsgType {
  // Pairing handshake (mirrors trade's tradeHello/tradeHelloAck)
  apprHello(0x70),
  apprHelloAck(0x71),

  // Chapter-loan offer
  chapterOffer(0x72),
  offerAccept(0x73),
  offerDecline(0x74),

  // Grant delivery (post-acceptance)
  chapterBundle(0x75),
  bundleAck(0x76),

  // Graduation (docs/MASTER_APPRENTICE_PLAN.md §7)
  graduationOffer(0x77),
  graduationAccept(0x78),
  graduationDecline(0x79),
  settlementBundle(0x7A),
  settlementAck(0x7B);

  const ApprenticeMsgType(this.byte);
  final int byte;

  static ApprenticeMsgType fromByte(int b) => ApprenticeMsgType.values.firstWhere(
        (t) => t.byte == b,
        orElse: () => throw ArgumentError('unknown ApprenticeMsgType byte 0x${b.toRadixString(16)}'),
      );
}

class ApprenticeFrame {
  ApprenticeFrame(this.type, this.payload);

  final ApprenticeMsgType type;
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

/// Reassembles a byte stream into discrete [ApprenticeFrame]s. Identical to
/// TradeFrameReader (trade_wire.dart) but typed to [ApprenticeMsgType].
/// Broadcast stream so multiple callers can subscribe simultaneously — see
/// apprentice_session.dart's `_nextFrame` for why raw subscription alone is
/// NOT safe for this protocol's human-gated steps.
class ApprenticeFrameReader {
  final _buffer = BytesBuilder();
  final _controller = StreamController<ApprenticeFrame>.broadcast();

  Stream<ApprenticeFrame> get frames => _controller.stream;

  void addChunk(List<int> chunk) {
    // A late chunk after close (the socket's onDone/onError closes this
    // reader) would otherwise throw on _drain's _controller.add.
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
      final type = ApprenticeMsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _controller.add(ApprenticeFrame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  Future<void> close() => _controller.close();
}
