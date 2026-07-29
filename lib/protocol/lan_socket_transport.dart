// SPDX-License-Identifier: GPL-3.0-or-later
//
// lan_socket_transport.dart — Transport adapter over dart:io TCP sockets.
//
// Design doc "Pluggable transport layer": this is Adapter 1's wire half
// (cross-platform LAN sockets; mDNS discovery is a separate, later piece --
// see lan_discovery.dart). Chosen first per the M4 plan because it's both
// the cross-platform-safe choice (sockets interoperate with a future iOS
// port; Wi-Fi Direct/Nearby do not) and the only adapter testable on
// localhost without a second physical device.
//
// Stream framing: TCP is a byte stream, not message-delimited -- a single
// logical message can arrive split across multiple `Socket` read events, or
// two messages can coalesce into one. This adapter does NOT try to solve
// that itself; it doesn't need to. `MatchSession` already routes every
// incoming chunk through `wire.dart`'s `FrameReader`, which is a generic,
// transport-agnostic byte-stream reassembler built specifically to handle
// partial/coalesced reads (see its doc comment). A `Socket` is already a
// `Stream<Uint8List>`, so this adapter is a thin pass-through -- the
// correctness work lives in one place (`FrameReader`), not duplicated per
// transport. This is "fix the interface, not the protocol": MatchSession
// needs zero changes to run over real sockets.

import 'dart:async';
import 'dart:io';

import 'transport.dart';

class LanSocketTransport implements Transport {
  LanSocketTransport._(this._socket);

  final Socket _socket;

  /// Binds a listening socket. Split from accepting a connection (see
  /// [LanListener.acceptOnce]) so the caller learns the bound port -- needed
  /// to hand to a peer (or, in tests, to `connectTo`) -- without already
  /// having to know who's connecting.
  ///
  /// [port] defaults to 0 (let the OS assign a free port). [address]
  /// defaults to all IPv4 interfaces; pass `InternetAddress.loopbackIPv4` to
  /// restrict to localhost (used by the protocol tests).
  static Future<LanListener> bind({int port = 0, InternetAddress? address}) async {
    final server = await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port);
    return LanListener._(server);
  }

  /// Connects to a peer already listening at [host]:[port].
  static Future<LanSocketTransport> connectTo(String host, int port) async {
    final socket = await Socket.connect(host, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return LanSocketTransport._(socket);
  }

  // advertise/discover/connect are unused here, same as InMemoryTransport:
  // connection setup happens via bind()+LanListener.acceptOnce() / connectTo()
  // above (a Transport instance represents an already-connected channel,
  // mirroring InMemoryTransport.pair()). mDNS-based discovery is a separate
  // piece (lan_discovery.dart) that gives `connect(peerId)` something real
  // to do; until it's wired in, these are deliberate no-ops, not missing
  // pieces.

  @override
  Future<void> advertise() async {}

  @override
  Future<void> discover() async {}

  @override
  Future<void> connect(String peerId) async {}

  @override
  void send(List<int> bytes) => _socket.add(bytes);

  @override
  Stream<List<int>> get onReceive => _socket;

  @override
  Future<void> disconnect() async {
    await _socket.close();
  }
}

/// A bound, listening socket awaiting its one peer connection. Comment
/// above explains why `bind` (this) and `acceptOnce` (below) are split.
class LanListener {
  LanListener._(this._server);

  final ServerSocket _server;

  /// The OS-assigned (or explicitly requested) port -- known immediately
  /// after [LanSocketTransport.bind], before any connection arrives.
  int get port => _server.port;

  /// Waits for the first incoming connection, then stops listening. A 1:1
  /// duel transport, not a multi-peer server (multi-player networking is
  /// out of scope -- CLAUDE.md).
  Future<LanSocketTransport> acceptOnce() async {
    final completer = Completer<LanSocketTransport>();
    late final StreamSubscription<Socket> sub;
    sub = _server.listen((socket) {
      sub.cancel();
      _server.close();
      socket.setOption(SocketOption.tcpNoDelay, true);
      completer.complete(LanSocketTransport._(socket));
    });
    return completer.future;
  }

  /// Stops listening before any connection arrives (e.g. the caller gave
  /// up waiting, or is tearing down). Harmless to call after [acceptOnce]
  /// has already completed and closed the server itself.
  Future<void> close() => _server.close();
}
