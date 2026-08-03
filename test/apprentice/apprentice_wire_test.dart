// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_wire_test.dart — ApprenticeMsgType byte-range isolation +
// frame framing (docs/MASTER_APPRENTICE_PLAN.md §5.3/§5.9).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/apprentice/apprentice_wire.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/protocol/wire.dart' as proof_wire;
import 'package:rune_duel/trade/sync_art_wire.dart';
import 'package:rune_duel/trade/trade_wire.dart';

void main() {
  test('ApprenticeMsgType bytes do not overlap MsgType (proof exchange)', () {
    final proofBytes = proof_wire.MsgType.values.map((t) => t.byte).toSet();
    final apprBytes = ApprenticeMsgType.values.map((t) => t.byte).toSet();
    expect(proofBytes.intersection(apprBytes), isEmpty);
  });

  test('ApprenticeMsgType bytes do not overlap BattleMsgType', () {
    final battleBytes = BattleMsgType.values.map((t) => t.byte).toSet();
    final apprBytes = ApprenticeMsgType.values.map((t) => t.byte).toSet();
    expect(battleBytes.intersection(apprBytes), isEmpty);
  });

  test('ApprenticeMsgType bytes do not overlap TradeMsgType', () {
    final tradeBytes = TradeMsgType.values.map((t) => t.byte).toSet();
    final apprBytes = ApprenticeMsgType.values.map((t) => t.byte).toSet();
    expect(tradeBytes.intersection(apprBytes), isEmpty);
  });

  test('ApprenticeMsgType bytes do not overlap SyncArtMsgType', () {
    final syncBytes = SyncArtMsgType.values.map((t) => t.byte).toSet();
    final apprBytes = ApprenticeMsgType.values.map((t) => t.byte).toSet();
    expect(syncBytes.intersection(apprBytes), isEmpty);
  });

  test('every ApprenticeMsgType byte is unique and inside 0x70-0x7F', () {
    final bytes = ApprenticeMsgType.values.map((t) => t.byte).toList();
    expect(bytes.toSet().length, bytes.length);
    for (final b in bytes) {
      expect(b, greaterThanOrEqualTo(0x70));
      expect(b, lessThanOrEqualTo(0x7F));
    }
  });

  test('ApprenticeFrame encode/decode round-trips a single frame', () async {
    final frame = ApprenticeFrame(ApprenticeMsgType.chapterOffer, Uint8List.fromList([1, 2, 3, 4, 5]));
    final encoded = frame.encode();

    final reader = ApprenticeFrameReader();
    final received = <ApprenticeFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(encoded);
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, ApprenticeMsgType.chapterOffer);
    expect(received.first.payload, equals([1, 2, 3, 4, 5]));
  });

  test('ApprenticeFrameReader reassembles a frame split across multiple chunks', () async {
    final frame =
        ApprenticeFrame(ApprenticeMsgType.chapterBundle, Uint8List.fromList(List.generate(50, (i) => i)));
    final encoded = frame.encode();

    final reader = ApprenticeFrameReader();
    final received = <ApprenticeFrame>[];
    reader.frames.listen(received.add);

    reader.addChunk(encoded.sublist(0, 3));
    reader.addChunk(encoded.sublist(3, 10));
    reader.addChunk(encoded.sublist(10));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.type, ApprenticeMsgType.chapterBundle);
    expect(received.first.payload, equals(frame.payload));
  });

  test('ApprenticeFrameReader handles two coalesced frames in one chunk', () async {
    final a = ApprenticeFrame(ApprenticeMsgType.offerAccept, Uint8List(0));
    final b = ApprenticeFrame(ApprenticeMsgType.offerDecline, Uint8List(0));
    final coalesced = Uint8List.fromList([...a.encode(), ...b.encode()]);

    final reader = ApprenticeFrameReader();
    final received = <ApprenticeFrame>[];
    reader.frames.listen(received.add);
    reader.addChunk(coalesced);
    await Future<void>.delayed(Duration.zero);

    expect(
      received.map((f) => f.type).toList(),
      equals([ApprenticeMsgType.offerAccept, ApprenticeMsgType.offerDecline]),
    );
  });

  test('fromByte throws on an unknown byte', () {
    expect(() => ApprenticeMsgType.fromByte(0xFF), throwsArgumentError);
  });
}
