// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_wire_test.dart — TradeMsgType byte-range isolation + frame framing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/protocol/wire.dart' as proof_wire;
import 'package:rune_duel/trade/trade_wire.dart';

void main() {
  test('TradeMsgType bytes do not overlap MsgType (proof exchange)', () {
    final proofBytes = proof_wire.MsgType.values.map((t) => t.byte).toSet();
    final tradeBytes = TradeMsgType.values.map((t) => t.byte).toSet();
    expect(proofBytes.intersection(tradeBytes), isEmpty);
  });

  test('TradeMsgType bytes do not overlap BattleMsgType', () {
    final battleBytes = BattleMsgType.values.map((t) => t.byte).toSet();
    final tradeBytes = TradeMsgType.values.map((t) => t.byte).toSet();
    expect(battleBytes.intersection(tradeBytes), isEmpty);
  });

  test('every TradeMsgType byte is unique', () {
    final bytes = TradeMsgType.values.map((t) => t.byte).toList();
    expect(bytes.toSet().length, bytes.length);
  });

  test('TradeFrame encode/decode round-trips a single frame', () async {
    final frame = TradeFrame(TradeMsgType.offer, Uint8List.fromList([1, 2, 3, 4, 5]));
    final encoded = frame.encode();

    final reader = TradeFrameReader();
    final received = <TradeFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(encoded);
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, TradeMsgType.offer);
    expect(received.first.payload, equals([1, 2, 3, 4, 5]));
  });

  test('TradeFrameReader reassembles a frame split across multiple chunks', () async {
    final frame = TradeFrame(TradeMsgType.grantBundle, Uint8List.fromList(List.generate(50, (i) => i)));
    final encoded = frame.encode();

    final reader = TradeFrameReader();
    final received = <TradeFrame>[];
    reader.frames.listen(received.add);

    // Split arbitrarily mid-header and mid-payload.
    reader.addChunk(encoded.sublist(0, 3));
    reader.addChunk(encoded.sublist(3, 10));
    reader.addChunk(encoded.sublist(10));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, TradeMsgType.grantBundle);
    expect(received.first.payload, equals(frame.payload));
  });

  test('TradeFrameReader handles two coalesced frames in one chunk', () async {
    final a = TradeFrame(TradeMsgType.confirm, Uint8List(0));
    final b = TradeFrame(TradeMsgType.cancel, Uint8List(0));
    final coalesced = Uint8List.fromList([...a.encode(), ...b.encode()]);

    final reader = TradeFrameReader();
    final received = <TradeFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(coalesced);
    await Future<void>.delayed(Duration.zero);

    expect(received.map((f) => f.type).toList(), equals([TradeMsgType.confirm, TradeMsgType.cancel]));
  });

  test('fromByte throws on an unknown byte', () {
    expect(() => TradeMsgType.fromByte(0xFF), throwsArgumentError);
  });
}
