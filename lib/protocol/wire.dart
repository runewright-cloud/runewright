// SPDX-License-Identifier: GPL-3.0-or-later
//
// wire.dart — minimal binary message framing for the match protocol.
//
// Each frame: [1 byte type][4 byte BE payload length][payload]. Deliberately
// not JSON -- every payload here is binary (pubkeys, proof bytes, nonces,
// signatures) and this project never base64-round-trips Field/key bytes
// where a raw length-prefixed frame will do.

import 'dart:async';
import 'dart:typed_data';

enum MsgType {
  hello(0x01),
  helloAck(0x02),
  proofPresentation(0x03),
  challenge(0x04),
  challengeResponse(0x05),
  accept(0x06),
  reject(0x07);

  const MsgType(this.byte);
  final int byte;

  static MsgType fromByte(int b) =>
      MsgType.values.firstWhere((t) => t.byte == b, orElse: () => throw ArgumentError('unknown MsgType byte $b'));
}

class Frame {
  Frame(this.type, this.payload);

  final MsgType type;
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

/// Reassembles a byte stream (as delivered by a `Transport`) into discrete
/// `Frame`s. A `Transport.onReceive` event need not align to one frame --
/// this buffers across chunk boundaries.
class FrameReader {
  final _buffer = BytesBuilder();
  // Broadcast: `accept()`'s handshake wait uses `.first` to peel off the
  // initial Hello frame, then the owning MatchSession attaches its own
  // listener for everything after -- both must be able to subscribe.
  final _framesController = StreamController<Frame>.broadcast();

  Stream<Frame> get frames => _framesController.stream;

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
      final type = MsgType.fromByte(bytes[0]);
      final payload = Uint8List.sublistView(bytes, 5, frameLen);
      _framesController.add(Frame(type, payload));
      bytes = Uint8List.sublistView(bytes, frameLen);
    }
    _buffer.clear();
    _buffer.add(bytes);
  }

  Future<void> close() => _framesController.close();
}

/// Length-prefixed concatenation of byte fields, used to build the
/// ownership-challenge digest input unambiguously regardless of any
/// individual field's length (see `match_session.dart`).
Uint8List lengthPrefixedConcat(List<List<int>> fields) {
  final out = BytesBuilder();
  for (final field in fields) {
    final lenBytes = ByteData(4)..setUint32(0, field.length, Endian.big);
    out.add(lenBytes.buffer.asUint8List());
    out.add(field);
  }
  return out.toBytes();
}

/// Inverse of [lengthPrefixedConcat]: splits a buffer encoded as
/// `fieldCount` length-prefixed fields back into its parts.
List<Uint8List> lengthPrefixedSplit(Uint8List bytes, int fieldCount) {
  final fields = <Uint8List>[];
  var offset = 0;
  for (var i = 0; i < fieldCount; i++) {
    final len = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
    offset += 4;
    fields.add(Uint8List.sublistView(bytes, offset, offset + len));
    offset += len;
  }
  return fields;
}
