// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_discovery.dart — LAN pairing for Commune/Trade sessions.
//
// Reuses the same advertise/discover/connect primitives the battle lobby
// uses (lib/protocol/lan_discovery.dart, lan_socket_transport.dart) but on
// a distinct service type (kRunewrightTradeServiceType) so a device
// browsing for a duel never lists a trade-only peer and vice versa. This is
// a thin, trade-specific wrapper rather than a reuse of
// lib/battle/networking/match_discovery.dart's LanMatchDiscovery -- that
// class carries duel-specific concepts (DeviceCapabilities/ramTierCap) that
// don't apply here, and lib/trade/ should not depend on lib/battle/.

import 'dart:async';

import 'package:nsd/nsd.dart' as nsd;

import '../protocol/lan_discovery.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';

/// A trade peer found during discovery, with a lazily-evaluated connection
/// factory -- mirrors DiscoveredPeer's shape (match_discovery.dart) without
/// the duel-specific capabilities field.
class DiscoveredTradePeer {
  DiscoveredTradePeer({
    required this.displayName,
    required Future<Transport> Function() connect,
  }) : _connect = connect;

  final String displayName;
  final Future<Transport> Function() _connect;

  Future<Transport> connect() => _connect();
}

/// Advertise/discover/connect for Commune/Trade pairing, over LAN sockets +
/// mDNS on [kRunewrightTradeServiceType]. Mirrors LanMatchDiscovery's
/// structure (match_discovery.dart) at a smaller scope.
class TradeDiscovery {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  LanListener? _listener;
  final _peerController = StreamController<DiscoveredTradePeer>.broadcast();

  Future<void> startAdvertising({String displayName = 'Runewright Trade'}) async {
    _listener = await LanSocketTransport.bind();
    _registration = await advertiseDuelHost(
      port: _listener!.port,
      displayName: displayName,
      serviceType: kRunewrightTradeServiceType,
    );
  }

  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await stopAdvertisingDuelHost(_registration!);
      _registration = null;
    }
    await _listener?.close();
    _listener = null;
  }

  /// Returns a broadcast stream emitting peers as they are discovered.
  Future<Stream<DiscoveredTradePeer>> startDiscovering() async {
    _discovery = await discoverDuelHosts(serviceType: kRunewrightTradeServiceType);
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        _peerController.add(DiscoveredTradePeer(
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
