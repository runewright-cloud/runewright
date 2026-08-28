// SPDX-License-Identifier: GPL-3.0-or-later
//
// The armorLoadout frame at the session level: it is exchanged on EVERY duel,
// and "no armor" is a declaration, not a silence.
//
// The uniformity is the whole point. A frame sent only by players who own
// armor would leave the two peers in different handshake states — one blocked
// on a frame the other decided not to send — which is a hang at the venue, not
// an error message. That is why kBattleProtocolVersion went to 6.

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:rune_duel/battle/engine/battle_engine_version.dart'
    show kBattleEngineVersion;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/networking/duel_setup.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../identity/fake_secure_storage.dart';
import '../../spells/fake_path_provider.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/armor_envelope.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/battle/networking/match_discovery.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the setup frames own their bytes, and the protocol version reflects '
      'them', () {
    // v6 added armorLoadout, v7 the setupReady barrier — both mandatory, so
    // both had to move the version a lower client is refused on.
    expect(kBattleProtocolVersion, 7);
    expect(BattleMsgType.armorLoadout.byte, 0x1F);
    expect(BattleMsgType.setupReady.byte, 0x47);
    // Nothing else claims either byte.
    for (final byte in [0x1F, 0x47]) {
      expect(
        BattleMsgType.values.where((t) => t.byte == byte).length,
        1,
        reason: '0x${byte.toRadixString(16)}',
      );
    }
  });

  test('both sides exchange the frame when NEITHER wears armor', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    final results = await Future.wait([
      sessionA.exchangeArmorLoadout(null),
      sessionB.exchangeArmorLoadout(null),
    ]);

    expect(results[0], isNull);
    expect(results[1], isNull);

    await a.disconnect();
    await b.disconnect();
  });

  test('each side receives the OTHER side\'s envelope', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    final proofA = Uint8List.fromList(List.generate(64, (i) => i));
    final proofB = Uint8List.fromList(List.generate(64, (i) => 255 - i));

    final results = await Future.wait([
      sessionA.exchangeArmorLoadout(ArmorEnvelope(tier: 12, proofBytes: proofA)),
      sessionB.exchangeArmorLoadout(ArmorEnvelope(tier: 48, proofBytes: proofB)),
    ]);

    expect(results[0]!.tier, 48);
    expect(results[0]!.proofBytes, proofB);
    expect(results[1]!.tier, 12);
    expect(results[1]!.proofBytes, proofA);

    await a.disconnect();
    await b.disconnect();
  });

  test('one-sided armor still completes for both', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    final results = await Future.wait([
      sessionA.exchangeArmorLoadout(
          ArmorEnvelope(tier: 24, proofBytes: Uint8List.fromList([1, 2, 3]))),
      sessionB.exchangeArmorLoadout(null),
    ]);

    expect(results[0], isNull);
    expect(results[1]!.tier, 24);

    await a.disconnect();
    await b.disconnect();
  });

  // ── The version gate that keeps a v5 peer from meeting a v6 one ────────────

  group('a v5 peer is refused before the new frame sequence can be misread', () {
    setUpAll(() async {
      await RustLib.init();
    });

    late io.Directory tempDir;

    setUp(() async {
      installFakeSecureStorage();
      tempDir = await installFakePathProvider();
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// A peer that answers the nonce and then declares protocol v5 — an
    /// unpatched build. It must be refused at the capabilities gate, which
    /// runs BEFORE any setup frame is exchanged: past that point the two
    /// builds disagree about whether an armorLoadout frame exists, and a v5
    /// client would either block forever waiting for a frame that never comes
    /// or read ours as the start of something else.
    Future<String> fakeV5Peer(InMemoryTransport transport) async {
      final session = BattleSession(transport, Uint8List(16));
      await session.exchangeMatchIdNonce(Uint8List(16));
      await session.exchangeCapabilities(DeviceCapabilities(
        ramTierCap: 24,
        battleProtocolVersion: kBattleProtocolVersion - 1,
        battleEngineVersion: kBattleEngineVersion,
      ));
      // The session consumes the forfeit frame itself, so read the signal it
      // exposes rather than competing for the frame.
      return session.peerForfeit.timeout(const Duration(seconds: 5));
    }

    test('refused at the capabilities gate, with no armor frame sent', () async {
      final identity = await Identity.ephemeral();
      final chapter = ChapterAsset(
        id: 'c-v5',
        name: 'v5 gate',
        createdAt: DateTime.utc(2026, 8, 25),
      );

      final (local, peer) = InMemoryTransport.pair();
      // Order matters: runDuelSetup subscribes synchronously then yields, so
      // the fake peer starts after it (the trap duel_setup.dart documents).
      final setup = runDuelSetup(
        transport: local,
        role: DuelRole.host,
        localIdentity: identity,
        localChapter: chapter,
        hostConfig: const MatchConfig(),
      );
      final armorFrames = <BattleFrame>[];
      final sub = BattleSession(peer, Uint8List(16))
          .framesOfType(BattleMsgType.armorLoadout)
          .listen(armorFrames.add);
      final forfeitReason = fakeV5Peer(peer);

      await expectLater(
        setup,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('battle protocol version mismatch'),
            contains('local=$kBattleProtocolVersion'),
            contains('peer=${kBattleProtocolVersion - 1}'),
          ),
        )),
      );
      expect(await forfeitReason, 'battle_protocol_mismatch');
      expect(armorFrames, isEmpty,
          reason: 'the gate must run before any v6-only frame reaches a v5 peer');

      await sub.cancel();
      await local.disconnect();
      await peer.disconnect();
    });
  });
}
