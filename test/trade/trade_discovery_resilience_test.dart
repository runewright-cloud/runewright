// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_discovery_resilience_test.dart — TradeDiscovery must keep hosting
// usable even when `nsd` (mDNS) itself is unavailable.
//
// Mirrors match_discovery_resilience_test.dart's rationale: `nsd` has no
// Linux desktop backend at all (lan_discovery.dart's header comment), so on
// this dev machine trade hosting/joining hit the same "MissingPluginException
// on channel com.haberey/nsd" that the battle lobby hit before its own
// try/catch was added (2026-07-20). trade_screen.dart's manual-IP fallback
// (the trade counterpart to battle_lobby_screen.dart's _connectManual) needs
// TradeDiscovery.startAdvertising to soft-fail the same way LanMatchDiscovery
// does, or hosting a trade becomes impossible on any platform/network where
// mDNS doesn't work.
//
// The flutter_test harness has NO platform channel implementations registered
// by default -- the same situation as `nsd` on Linux desktop -- so this test
// naturally exercises the "mDNS unavailable" path without a real device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';
import 'package:rune_duel/trade/trade_discovery.dart';

void main() {
  test(
      'startAdvertising succeeds and yields a connectable listener even '
      'when mDNS advertise itself fails (no platform nsd backend)', () async {
    final discovery = TradeDiscovery();
    addTearDown(discovery.dispose);

    // Must not throw: a purely cosmetic mDNS-advertise failure (nsd
    // unavailable) must never make hosting itself impossible.
    await discovery.startAdvertising();

    final port = discovery.listeningPort;
    expect(port, isNotNull, reason: 'the listening socket must bind '
        'regardless of whether mDNS advertise succeeded');

    // The underlying socket must be genuinely connectable — this is the
    // manual-IP fallback path (trade_screen.dart's _connectManual), fully
    // decoupled from nsd.
    final acceptFuture = discovery.acceptConnection();
    final clientTransport =
        await LanSocketTransport.connectTo(InternetAddress.loopbackIPv4.address, port!);
    final serverTransport = await acceptFuture;

    // Prove the connection actually carries bytes both ways.
    final received = serverTransport.onReceive.first;
    clientTransport.send([1, 2, 3]);
    expect(await received, equals([1, 2, 3]));

    await clientTransport.disconnect();
    await serverTransport.disconnect();
  });

  test(
      'startDiscovering throws a clean, catchable error when mDNS discovery '
      'itself is unavailable (never hangs)', () async {
    final discovery = TradeDiscovery();
    addTearDown(discovery.dispose);

    // In this harness (as on real Linux desktop) nsd has no backend, so this
    // must reject rather than hang — trade_screen.dart's try/catch depends
    // on it to populate the manual-IP fallback UI.
    await expectLater(discovery.startDiscovering(), throwsA(anything));
  });
}
