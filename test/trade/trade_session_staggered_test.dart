// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_session_staggered_test.dart — the two peers act SECONDS APART, the
// way two humans actually use this feature.
//
// Found via a real two-device bug report (2026-07-28, Linux laptop + Pixel 6
// over a phone hotspot): both sides submitted their offer and one side hung
// forever on "Waiting for their offer". The hang followed *submission order*
// -- whoever pressed Submit second hung -- not host/guest role, and not
// network conditions (the devices were a foot apart on a private hotspot).
//
// Root cause: TradeFrameReader's controller is a *broadcast* controller, and
// a broadcast stream silently discards events delivered while it has no
// subscriber. TradeSession only subscribed inside exchangeOffer/
// exchangeConfirm, so the first player's frame arrived while the other
// device was still sitting in its offer-builder UI with nothing listening --
// and was dropped. The second player then awaited a frame that no longer
// existed.
//
// The pre-existing trade_session_test.dart could never have caught this: it
// calls both sides' exchangeOffer in the same event-loop turn, so both are
// subscribed before either frame is delivered. The delay below is the whole
// point of this file -- if these tests are ever "tidied" by removing it,
// they stop testing anything.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/trade/trade_offer.dart';
import 'package:rune_duel/trade/trade_session.dart';

import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Real loopback TCP, not InMemoryTransport -- the reported bug was on
  /// real sockets and this keeps the transport honest.
  Future<(TradeSession, TradeSession)> pairedOverSockets() async {
    final listener = await LanSocketTransport.bind(address: InternetAddress.loopbackIPv4);
    final clientFuture = LanSocketTransport.connectTo('127.0.0.1', listener.port);
    final serverTransport = await listener.acceptOnce();
    final clientTransport = await clientFuture;

    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final bobFuture = TradeSession.accept(serverTransport, bob);
    final aliceSession = await TradeSession.initiate(clientTransport, alice);
    return (aliceSession, await bobFuture);
  }

  /// Long enough that the first frame is delivered (and, before the fix,
  /// dropped) well before the second side subscribes.
  const humanGap = Duration(milliseconds: 300);

  test('the player who submits their offer SECOND still receives the first '
      'player\'s offer', () async {
    final (aliceSession, bobSession) = await pairedOverSockets();

    final aliceOffer = TradeOffer(items: [
      TradeItem(
        spellId: 'a1',
        commitmentHex: '0xaabb',
        spellName: 'Ember Wake',
        mode: TradeMode.loan,
        loanDays: 3,
      ),
    ]);

    // Alice submits first; Bob is still building his offer.
    final aliceSees = aliceSession.exchangeOffer(aliceOffer);
    await Future<void>.delayed(humanGap);
    final bobSees = bobSession.exchangeOffer(const TradeOffer(items: []));

    // Bob is the one that hung before the fix.
    final bobResult = await bobSees.timeout(const Duration(seconds: 5));
    expect(bobResult.items, hasLength(1));
    expect(bobResult.items.first.spellName, 'Ember Wake');

    final aliceResult = await aliceSees.timeout(const Duration(seconds: 5));
    expect(aliceResult.items, isEmpty);
  });

  test('the player who confirms SECOND still sees the first player\'s '
      'confirmation', () async {
    final (aliceSession, bobSession) = await pairedOverSockets();

    // Get both past the offer stage first (staggered here too).
    final aliceOffer = aliceSession.exchangeOffer(const TradeOffer(items: []));
    await Future<void>.delayed(humanGap);
    final bobOffer = bobSession.exchangeOffer(const TradeOffer(items: []));
    await aliceOffer.timeout(const Duration(seconds: 5));
    await bobOffer.timeout(const Duration(seconds: 5));

    // Same staggered shape on the confirm gate -- two humans deciding
    // independently, seconds apart.
    final aliceConfirm = aliceSession.exchangeConfirm(true);
    await Future<void>.delayed(humanGap);
    final bobConfirm = bobSession.exchangeConfirm(true);

    expect(await bobConfirm.timeout(const Duration(seconds: 5)), isTrue);
    expect(await aliceConfirm.timeout(const Duration(seconds: 5)), isTrue);
  });

  test('a cancel from the player who decides FIRST is not lost', () async {
    final (aliceSession, bobSession) = await pairedOverSockets();

    final aliceOffer = aliceSession.exchangeOffer(const TradeOffer(items: []));
    await Future<void>.delayed(humanGap);
    final bobOffer = bobSession.exchangeOffer(const TradeOffer(items: []));
    await aliceOffer.timeout(const Duration(seconds: 5));
    await bobOffer.timeout(const Duration(seconds: 5));

    // Alice cancels while Bob is still reading the offer. Bob must learn
    // about it rather than confirming into a trade that is already off.
    final aliceDecision = aliceSession.exchangeConfirm(false);
    await Future<void>.delayed(humanGap);
    final bobDecision = bobSession.exchangeConfirm(true);

    expect(await bobDecision.timeout(const Duration(seconds: 5)), isFalse,
        reason: 'Bob confirmed, but Alice cancelled first — no grants may be exchanged');
    expect(await aliceDecision.timeout(const Duration(seconds: 5)), isFalse);
  });

  test('closing the session releases an in-flight await instead of hanging '
      '(trade_screen.dart\'s Cancel button)', () async {
    final (aliceSession, bobSession) = await pairedOverSockets();

    // Alice waits on an offer Bob will never send.
    final aliceSees = aliceSession.exchangeOffer(const TradeOffer(items: []));
    await Future<void>.delayed(humanGap);

    await aliceSession.close();

    await expectLater(
      aliceSees.timeout(const Duration(seconds: 5)),
      throwsA(isA<StateError>()),
    );
    await bobSession.close();
  });
}
