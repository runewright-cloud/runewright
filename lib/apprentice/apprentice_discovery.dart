// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprentice_discovery.dart — LAN pairing for Master/Apprentice sessions
// (docs/MASTER_APPRENTICE_PLAN.md §5.3).
//
// A thin copy of lib/trade/trade_discovery.dart on a distinct service type
// (kRunewrightApprenticeServiceType) so a device browsing for a duel, trade,
// or sync-art peer never lists an apprenticeship-only peer, and vice versa.
// Kept as its own small class rather than parameterizing TradeDiscovery —
// lib/apprentice/ should not depend on lib/trade/, matching the existing
// discipline that kept trade_discovery.dart from depending on
// lib/battle/networking/match_discovery.dart.
//
// mDNS advertising is best-effort, not load-bearing: `nsd` has no Linux
// desktop backend at all (lan_discovery.dart's header comment), so
// startAdvertising's registration step soft-fails and the listening socket
// stays up regardless -- the pairing screen must fall back to manual IP
// entry, dialing the same socket directly via LanSocketTransport.connectTo.
// A missing manual-IP fallback was one of the three real two-device trade
// bugs fixed on 2026-07-28 (docs/COMMUNE_TRADE_PLAN.md's lineage) — carry it
// over here too.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:nsd/nsd.dart' as nsd;

import '../protocol/lan_discovery.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';

/// An apprenticeship peer found during discovery, with a lazily-evaluated
/// connection factory -- mirrors DiscoveredTradePeer's shape.
class DiscoveredApprenticePeer {
  DiscoveredApprenticePeer({
    required this.displayName,
    required Future<Transport> Function() connect,
  }) : _connect = connect;

  final String displayName;
  final Future<Transport> Function() _connect;

  Future<Transport> connect() => _connect();
}

/// Advertise/discover/connect for Master/Apprentice pairing, over LAN
/// sockets + mDNS on [kRunewrightApprenticeServiceType].
class ApprenticeDiscovery {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  LanListener? _listener;
  final _peerController = StreamController<DiscoveredApprenticePeer>.broadcast();

  Future<void> startAdvertising({String displayName = 'Runewright Apprenticeship'}) async {
    _listener = await LanSocketTransport.bind();
    try {
      _registration = await advertiseDuelHost(
        port: _listener!.port,
        displayName: displayName,
        serviceType: kRunewrightApprenticeServiceType,
      );
    } catch (e) {
      // Soft failure by design (mirrors TradeDiscovery.startAdvertising) --
      // the listening socket above doesn't depend on it; a peer can still
      // reach this host via manual IP entry. Advertise failing must never
      // block hosting.
      debugPrint('mDNS advertise failed (manual IP entry still works): $e');
      _registration = null;
    }
  }

  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await stopAdvertisingDuelHost(_registration!);
      _registration = null;
    }
    await _listener?.close();
    _listener = null;
  }

  /// This device's listening port once [startAdvertising] has bound it, for
  /// display alongside [localAddressHint] so a peer can connect via manual
  /// IP entry when mDNS discovery isn't available on their platform/network.
  int? get listeningPort => _listener?.port;

  /// Best-effort local IPv4 address hint for manual-IP display -- see
  /// [preferredLocalAddress]. Null if undeterminable; display-only, never
  /// blocks anything.
  Future<String?> localAddressHint() async {
    try {
      final addr = await preferredLocalAddress();
      return addr?.address;
    } catch (_) {
      return null;
    }
  }

  /// Returns a broadcast stream emitting peers as they are discovered.
  Future<Stream<DiscoveredApprenticePeer>> startDiscovering() async {
    _discovery = await discoverDuelHosts(serviceType: kRunewrightApprenticeServiceType);
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        _peerController.add(DiscoveredApprenticePeer(
          displayName: service.name ?? 'Unknown Wizard',
          connect: () => connectToDiscoveredService(service),
        ));
      }
    });
    return _peerController.stream;
  }

  Future<void> stopDiscovering() async {
    if (_discovery != null) {
      await stopDiscoveringDuelHosts(_discovery!);
      _discovery = null;
    }
  }

  /// Accept the first incoming connection from an advertising peer (host role).
  Future<Transport> acceptConnection() async {
    final listener = _listener;
    if (listener == null) throw StateError('not advertising — call startAdvertising first');
    return listener.acceptOnce();
  }

  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovering();
    await _peerController.close();
  }
}
