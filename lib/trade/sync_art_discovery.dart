// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_discovery.dart — LAN pairing for Commune/Sync Art sessions.
//
// Reuses the same advertise/discover/connect primitives the battle lobby
// and Commune/Trade use (lib/protocol/lan_discovery.dart,
// lan_socket_transport.dart) but on a distinct service type
// (kRunewrightSyncArtServiceType) so a device browsing for a duel or a trade
// never lists a sync-art-only peer and vice versa. Mirrors
// trade_discovery.dart's TradeDiscovery almost verbatim, at the same small
// scope -- lib/trade/ should not depend on lib/battle/.

import 'dart:async';

import 'package:nsd/nsd.dart' as nsd;

import '../protocol/lan_discovery.dart';
import '../protocol/lan_socket_transport.dart';
import '../protocol/transport.dart';

/// A sync-art peer found during discovery, with a lazily-evaluated
/// connection factory -- mirrors DiscoveredTradePeer's shape
/// (trade_discovery.dart).
class DiscoveredSyncArtPeer {
  DiscoveredSyncArtPeer({
    required this.displayName,
    required Future<Transport> Function() connect,
  }) : _connect = connect;

  final String displayName;
  final Future<Transport> Function() _connect;

  Future<Transport> connect() => _connect();
}

/// Advertise/discover/connect for Commune/Sync Art pairing, over LAN sockets
/// + mDNS on [kRunewrightSyncArtServiceType]. Mirrors TradeDiscovery's
/// structure (trade_discovery.dart).
class SyncArtDiscovery {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  LanListener? _listener;
  final _peerController = StreamController<DiscoveredSyncArtPeer>.broadcast();

  Future<void> startAdvertising({String displayName = 'Runewright Sync Art'}) async {
    _listener = await LanSocketTransport.bind();
    _registration = await advertiseDuelHost(
      port: _listener!.port,
      displayName: displayName,
      serviceType: kRunewrightSyncArtServiceType,
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
  Future<Stream<DiscoveredSyncArtPeer>> startDiscovering() async {
    _discovery = await discoverDuelHosts(serviceType: kRunewrightSyncArtServiceType);
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        _peerController.add(DiscoveredSyncArtPeer(
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
