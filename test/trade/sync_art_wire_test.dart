// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_wire_test.dart — SyncArtMsgType byte-range isolation + frame framing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/protocol/wire.dart' as proof_wire;
import 'package:rune_duel/trade/sync_art_wire.dart';
import 'package:rune_duel/trade/trade_wire.dart';

void main() {
  test('SyncArtMsgType bytes do not overlap MsgType (proof exchange)', () {
    final proofBytes = proof_wire.MsgType.values.map((t) => t.byte).toSet();
    final syncArtBytes = SyncArtMsgType.values.map((t) => t.byte).toSet();
    expect(proofBytes.intersection(syncArtBytes), isEmpty);
  });

  test('SyncArtMsgType bytes do not overlap BattleMsgType', () {
    final battleBytes = BattleMsgType.values.map((t) => t.byte).toSet();
    final syncArtBytes = SyncArtMsgType.values.map((t) => t.byte).toSet();
    expect(battleBytes.intersection(syncArtBytes), isEmpty);
  });

  test('SyncArtMsgType bytes do not overlap TradeMsgType', () {
    final tradeBytes = TradeMsgType.values.map((t) => t.byte).toSet();
    final syncArtBytes = SyncArtMsgType.values.map((t) => t.byte).toSet();
    expect(tradeBytes.intersection(syncArtBytes), isEmpty);
  });

  test('every SyncArtMsgType byte is unique', () {
    final bytes = SyncArtMsgType.values.map((t) => t.byte).toList();
    expect(bytes.toSet().length, bytes.length);
  });

  test('SyncArtFrame encode/decode round-trips a single frame', () async {
    final frame = SyncArtFrame(SyncArtMsgType.wantlist, Uint8List.fromList([1, 2, 3, 4, 5]));
    final encoded = frame.encode();

    final reader = SyncArtFrameReader();
    final received = <SyncArtFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(encoded);
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, SyncArtMsgType.wantlist);
    expect(received.first.payload, equals([1, 2, 3, 4, 5]));
  });

  test('SyncArtFrameReader reassembles a frame split across multiple chunks', () async {
    final frame =
        SyncArtFrame(SyncArtMsgType.artBundle, Uint8List.fromList(List.generate(50, (i) => i)));
    final encoded = frame.encode();

    final reader = SyncArtFrameReader();
    final received = <SyncArtFrame>[];
    reader.frames.listen(received.add);

    // Split arbitrarily mid-header and mid-payload.
    reader.addChunk(encoded.sublist(0, 3));
    reader.addChunk(encoded.sublist(3, 10));
    reader.addChunk(encoded.sublist(10));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, SyncArtMsgType.artBundle);
    expect(received.first.payload, equals(frame.payload));
  });

  test('SyncArtFrameReader handles two coalesced frames in one chunk', () async {
    final a = SyncArtFrame(SyncArtMsgType.syncHello, Uint8List(0));
    final b = SyncArtFrame(SyncArtMsgType.syncHelloAck, Uint8List(0));
    final coalesced = Uint8List.fromList([...a.encode(), ...b.encode()]);

    final reader = SyncArtFrameReader();
    final received = <SyncArtFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(coalesced);
    await Future<void>.delayed(Duration.zero);

    expect(received.map((f) => f.type).toList(),
        equals([SyncArtMsgType.syncHello, SyncArtMsgType.syncHelloAck]));
  });

  test('fromByte throws on an unknown byte', () {
    expect(() => SyncArtMsgType.fromByte(0xFF), throwsArgumentError);
  });
}
