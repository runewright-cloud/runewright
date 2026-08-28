// SPDX-License-Identifier: GPL-3.0-or-later
//
// setup_abort_propagation_test.dart — a blocked typed wait must end when the
// peer stops being able to answer it (docs/AETHERIAL_ARMOR.md §3b finding).
//
// Before this, `BattleSession._awaitFrame` ended exactly one way: the frame it
// asked for. A peer that diagnosed a problem, forfeited and stopped therefore
// left us blocked until TCP teardown — and the failure the player then saw was
// "lost contact", which is the one explanation certainly wrong when the peer
// has just told you the real one.
//
// The repair is generic, at the session layer: every typed wait now races the
// shared forfeit and connection-loss signals. These tests are written at that
// layer, not at armor's, because nothing here is about armor.
//
// Every wait has a BOUNDED timeout on purpose. A regression to the old hang
// must fail loudly in seconds rather than stall the suite for 30.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';

const _bound = Duration(seconds: 5);

void main() {
  test('a blocked typed wait ends on a peer forfeit, carrying their reason',
      () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    // A blocks on a frame B will never send.
    final blocked = sessionA.exchangeArmorLoadout(null);
    // B diagnoses something and stops.
    sessionB.sendForfeit('armor_certification_failed');

    await expectLater(
      blocked.timeout(_bound),
      throwsA(isA<PeerForfeitException>()
          .having((e) => e.reason, 'reason', 'armor_certification_failed')),
    );

    await a.disconnect();
    await b.disconnect();
  });

  test('the wake needs no transport teardown', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    final blocked = sessionA.exchangeArmorLoadout(null);
    sessionB.sendForfeit('concede');

    // Nothing is disconnected before this completes — that is the whole point.
    await expectLater(blocked.timeout(_bound), throwsA(isA<PeerForfeitException>()));

    await a.disconnect();
    await b.disconnect();
  });

  test('it is not armor-specific: any setup exchange wakes the same way',
      () async {
    for (final start in <Future<void> Function(BattleSession)>[
      (s) => s.exchangeArmorLoadout(null),
      (s) => s.exchangeArtifactLoadout(const []),
      (s) => s.exchangeBookLeafCount(0),
      (s) => s.exchangeWizardName(''),
      (s) => s.exchangeAvatarId(''),
      (s) => s.exchangeBookCommitment(Uint8List(32)),
    ]) {
      final (a, b) = InMemoryTransport.pair();
      final sessionA = BattleSession(a, Uint8List(16));
      final sessionB = BattleSession(b, Uint8List(16));

      final blocked = start(sessionA);
      sessionB.sendForfeit('auth_failed');

      await expectLater(
        blocked.timeout(_bound),
        throwsA(isA<PeerForfeitException>()
            .having((e) => e.reason, 'reason', 'auth_failed')),
      );

      await a.disconnect();
      await b.disconnect();
    }
  });

  test('a wait STARTED after the forfeit fails immediately, not forever',
      () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    sessionB.sendForfeit('state_hash_mismatch');
    // Let the frame land before anything waits on anything.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await expectLater(
      sessionA.exchangeArtifactLoadout(const []).timeout(_bound),
      throwsA(isA<PeerForfeitException>()
          .having((e) => e.reason, 'reason', 'state_hash_mismatch')),
    );

    await a.disconnect();
    await b.disconnect();
  });

  test('several concurrently blocked waits are all woken by one forfeit',
      () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    // The forfeit frame has exactly one consumer, but any number of blocked
    // waits observe the result.
    final waits = [
      sessionA.exchangeArmorLoadout(null),
      sessionA.exchangeBookLeafCount(0),
      sessionA.exchangeWizardName(''),
    ];
    sessionB.sendForfeit('concede');

    for (final w in waits) {
      await expectLater(w.timeout(_bound), throwsA(isA<PeerForfeitException>()));
    }

    await a.disconnect();
    await b.disconnect();
  });

  // ── Connection loss is a DIFFERENT failure ─────────────────────────────────
  //
  // These use a real loopback socket, not InMemoryTransport: `disconnect()`
  // there closes only its OWN incoming stream, so it cannot model the event
  // that matters here — the peer's socket dying underneath us. This is the
  // same reason peer_connection_lost_test.dart uses LanSocketTransport.

  test('a blocked wait ends distinctly on connection loss', () async {
    final listener = await LanSocketTransport.bind();
    final connecting = LanSocketTransport.connectTo('127.0.0.1', listener.port);
    final transportA = await listener.acceptOnce();
    final transportB = await connecting;
    final sessionA = BattleSession(transportA, Uint8List(16));

    final blocked = sessionA.exchangeArtifactLoadout(const []);
    final expectation = expectLater(
      blocked.timeout(_bound),
      throwsA(isA<PeerConnectionLostException>()),
    );

    // The peer vanishes without diagnosing anything.
    await transportB.disconnect();
    await expectation;

    // Never conflated with a forfeit: only one of the two says WHY, and the
    // two error screens the player sees rest on telling them apart.
    await expectLater(
      blocked.timeout(_bound),
      throwsA(isNot(isA<PeerForfeitException>())),
    );

    await sessionA.close();
    await transportA.disconnect();
  });

  test('a forfeit that arrives before the socket closes wins the diagnosis',
      () async {
    final listener = await LanSocketTransport.bind();
    final connecting = LanSocketTransport.connectTo('127.0.0.1', listener.port);
    final transportA = await listener.acceptOnce();
    final transportB = await connecting;
    final sessionA = BattleSession(transportA, Uint8List(16));
    final sessionB = BattleSession(transportB, Uint8List(16));

    final blocked = sessionA.exchangeArmorLoadout(null);
    // Attach the expectation NOW: the wait fails the instant the forfeit
    // lands, and a future holding an error nobody is listening for yet is
    // reported as an unhandled async error.
    final expectation = expectLater(
      blocked.timeout(_bound),
      throwsA(isA<PeerForfeitException>()
          .having((e) => e.reason, 'reason', 'armor_certification_failed')),
    );

    sessionB.sendForfeit('armor_certification_failed');
    // The normal production sequence: forfeit, then teardown. The first
    // writer wins, and it must be the half that carries a reason.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await transportB.disconnect();
    await expectation;

    await sessionA.close();
    await transportA.disconnect();
  });

  // ── What must NOT have changed ─────────────────────────────────────────────

  group('the existing signals are untouched', () {
    test('peerForfeit still resolves with the transmitted reason', () async {
      final (a, b) = InMemoryTransport.pair();
      final sessionA = BattleSession(a, Uint8List(16));
      final sessionB = BattleSession(b, Uint8List(16));

      sessionB.sendForfeit('duplicate_spell_cast');
      expect(await sessionA.peerForfeit.timeout(_bound), 'duplicate_spell_cast');

      await a.disconnect();
      await b.disconnect();
    });

    test('peerForfeit resolves even with no wait in flight — the per-turn '
        'battle-screen path', () async {
      final (a, b) = InMemoryTransport.pair();
      final sessionA = BattleSession(a, Uint8List(16));
      final sessionB = BattleSession(b, Uint8List(16));

      // battle_screen.dart attaches a `.then` and never blocks on a frame.
      String? seen;
      unawaited(sessionA.peerForfeit.then((r) => seen = r));
      sessionB.sendForfeit('unauthorized_spell');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(seen, 'unauthorized_spell');

      await a.disconnect();
      await b.disconnect();
    });

    // peerConnectionLost's own resolution is pinned by
    // peer_connection_lost_test.dart and is deliberately not re-tested here —
    // this repair races that signal, it does not redesign it.

    test('a normal exchange is unaffected — no forfeit, no loss, no wake',
        () async {
      final (a, b) = InMemoryTransport.pair();
      final sessionA = BattleSession(a, Uint8List(16));
      final sessionB = BattleSession(b, Uint8List(16));

      final results = await Future.wait([
        sessionA.exchangeWizardName('Alice'),
        sessionB.exchangeWizardName('Bob'),
      ]).timeout(_bound);

      expect(results, ['Bob', 'Alice']);

      await a.disconnect();
      await b.disconnect();
    });

    test('a frame arriving normally still cancels cleanly, leaving no stale '
        'claim on the next frame of that type', () async {
      final (a, b) = InMemoryTransport.pair();
      final sessionA = BattleSession(a, Uint8List(16));
      final sessionB = BattleSession(b, Uint8List(16));

      // Two exchanges of the SAME type back to back: if the first wait left a
      // waiter registered, the second would steal or lose a frame.
      final first = await Future.wait([
        sessionA.exchangeWizardName('Alice'),
        sessionB.exchangeWizardName('Bob'),
      ]).timeout(_bound);
      final second = await Future.wait([
        sessionA.exchangeWizardName('Alice2'),
        sessionB.exchangeWizardName('Bob2'),
      ]).timeout(_bound);

      expect(first, ['Bob', 'Alice']);
      expect(second, ['Bob2', 'Alice2']);

      await a.disconnect();
      await b.disconnect();
    });
  });
}
