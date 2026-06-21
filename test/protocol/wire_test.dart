// SPDX-License-Identifier: GPL-3.0-or-later
//
// wire_test.dart — directed stress tests for FrameReader's byte-stream
// reassembly. The M4 plan flagged this explicitly: TCP delivers a byte
// stream, not message boundaries, so a frame can arrive split across many
// reads or two frames can coalesce into one. Localhost sockets are fast
// enough that match_session_socket_test.dart's tests may never actually
// trigger either case in practice -- these tests force both, independent of
// real transport timing, so the framing logic is verified directly rather
// than incidentally.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/protocol/wire.dart';

void main() {
  group('FrameReader', () {
    test('a single frame delivered in one chunk decodes correctly', () async {
      final reader = FrameReader();
      final received = <Frame>[];
      reader.frames.listen(received.add);

      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      reader.addChunk(Frame(MsgType.hello, payload).encode());
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.type, MsgType.hello);
      expect(received.single.payload, payload);
    });

    test('a frame split byte-by-byte across many chunks still decodes correctly', () async {
      final reader = FrameReader();
      final received = <Frame>[];
      reader.frames.listen(received.add);

      final payload = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final encoded = Frame(MsgType.proofPresentation, payload).encode();

      // The worst case: one byte per chunk, exercising every possible
      // partial-header and partial-payload boundary.
      for (final byte in encoded) {
        reader.addChunk([byte]);
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.type, MsgType.proofPresentation);
      expect(received.single.payload, payload);
    });

    test('two frames coalesced into a single chunk both decode, in order', () async {
      final reader = FrameReader();
      final received = <Frame>[];
      reader.frames.listen(received.add);

      final frame1 = Frame(MsgType.challenge, Uint8List.fromList(List.filled(32, 0xAA)));
      final frame2 = Frame(MsgType.challengeResponse, Uint8List.fromList(List.filled(64, 0xBB)));
      final coalesced = Uint8List.fromList([...frame1.encode(), ...frame2.encode()]);

      reader.addChunk(coalesced);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0].type, MsgType.challenge);
      expect(received[0].payload, frame1.payload);
      expect(received[1].type, MsgType.challengeResponse);
      expect(received[1].payload, frame2.payload);
    });

    test('three frames, arbitrarily re-chunked at every boundary, all decode in order', () async {
      final frames = [
        Frame(MsgType.hello, Uint8List.fromList(List.filled(16, 1))),
        Frame(MsgType.proofPresentation, Uint8List.fromList(List.generate(97, (i) => i))),
        Frame(MsgType.accept, Uint8List(0)),
      ];
      final allBytes = Uint8List.fromList(frames.expand((f) => f.encode()).toList());

      // Frame layout here: frame1 = bytes [0,21) (header [0,5), payload
      // [5,21)); frame2 = [21,123) (header [21,26), payload [26,123));
      // frame3 = [123,128) (header only, empty payload). Split points below
      // deliberately land mid-header and mid-payload for each frame, plus a
      // zero-length chunk (tests the "point > prev" no-op guard), rather
      // than one byte at a time -- covering the "coalesced + split" mixed
      // case in one pass.
      final splitPoints = [0, 1, 3, 3, 17, 21, 25, 90, 123, 125, allBytes.length];
      final reader = FrameReader();
      final received = <Frame>[];
      reader.frames.listen(received.add);

      var prev = 0;
      for (final point in splitPoints) {
        if (point > prev) {
          reader.addChunk(Uint8List.sublistView(allBytes, prev, point));
        }
        prev = point;
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(3));
      for (var i = 0; i < frames.length; i++) {
        expect(received[i].type, frames[i].type);
        expect(received[i].payload, frames[i].payload);
      }
    });
  });
}
