// SPDX-License-Identifier: GPL-3.0-or-later
//
// transport.dart — the pluggable transport seam.
//
// runewright_design_v2_4.md "Pluggable transport layer": all game/netcode
// talks to this interface only, never to a transport SDK directly. M4 ships
// one concrete adapter (LAN sockets + mDNS); this interface is what makes
// the protocol layer testable over an in-memory channel before any adapter
// exists, and keeps the transport swappable afterward (BLE, Nearby
// Connections, Wi-Fi Direct are future adapters behind the same seam).

/// A bidirectional byte-stream connection to exactly one peer.
///
/// Implementations: `InMemoryTransport` (testing), a future LAN-socket
/// adapter (M4 build-out), and eventually BLE / Nearby / Wi-Fi Direct.
abstract class Transport {
  /// Begin advertising this device as connectable to nearby peers.
  Future<void> advertise();

  /// Begin discovering nearby advertising peers.
  Future<void> discover();

  /// Connect to a previously discovered peer.
  Future<void> connect(String peerId);

  /// Send raw bytes to the connected peer.
  void send(List<int> bytes);

  /// Raw byte messages received from the connected peer, in send order.
  Stream<List<int>> get onReceive;

  Future<void> disconnect();
}
