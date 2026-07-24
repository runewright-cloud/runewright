// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_discovery_resilience_test.dart — LanMatchDiscovery must keep hosting
// usable even when `nsd` (mDNS) itself is unavailable.
//
// Found via a real bug report (2026-07-20): `nsd` has no Linux desktop
// backend at all (lan_discovery.dart's header comment) — confirmed live by
// running the app on `-d linux` and calling discoverDuelHosts()/
// advertiseDuelHost() directly: both threw a clean, catchable
// `NsdError(MissingPluginException(...))`. battle_lobby_screen.dart's
// `_startJoining`/`_startHosting` already had try/catch around these calls,
// but `_startHosting`'s catch treated ANY failure (including a purely
// cosmetic mDNS-advertise failure) as fatal to hosting — so on a platform/
// network where `nsd` doesn't work, hosting itself became impossible even
// though the underlying listening socket (LanSocketTransport, no `nsd`
// dependency) works fine and a peer can still connect via manual IP entry.
//
// The flutter_test harness conveniently has NO platform channel
// implementations registered by default — the same situation as `nsd` on
// Linux desktop — so this test's environment naturally exercises the
// "mDNS unavailable" path without needing a real device or platform mock.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/match_discovery.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';

void main() {
  test(
      'startAdvertising succeeds and yields a connectable listener even '
      'when mDNS advertise itself fails (no platform nsd backend)', () async {
    final discovery = LanMatchDiscovery();
    addTearDown(discovery.dispose);

    // Must not throw: a purely cosmetic mDNS-advertise failure (nsd
    // unavailable) must never make hosting itself impossible.
    await discovery.startAdvertising(caps: DeviceCapabilities.detect());

    final port = discovery.listeningPort;
    expect(port, isNotNull, reason: 'the listening socket must bind '
        'regardless of whether mDNS advertise succeeded');

    // The underlying socket must be genuinely connectable — this is the
    // manual-IP fallback path (battle_lobby_screen.dart's _connectManual),
    // fully decoupled from nsd.
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
    final discovery = LanMatchDiscovery();
    addTearDown(discovery.dispose);

    // In this harness (as on real Linux desktop) nsd has no backend, so this
    // must reject rather than hang — the lobby's try/catch depends on it.
    await expectLater(discovery.startDiscovering(), throwsA(anything));
  });
}
