// SPDX-License-Identifier: GPL-3.0-or-later
//
// in_memory_transport.dart — loopback Transport for protocol tests.
//
// Two instances wired directly together: no sockets, no radio, no second
// process. This is the fastest possible test loop for the protocol layer
// (faster even than localhost TCP) and needs no physical device -- the
// M4 brief's "protocol first, radio later" testing strategy.

import 'dart:async';

import 'transport.dart';

class InMemoryTransport implements Transport {
  InMemoryTransport._();

  final _incoming = StreamController<List<int>>.broadcast();
  InMemoryTransport? _peer;

  /// Creates two ends of one loopback connection, already wired together.
  static (InMemoryTransport, InMemoryTransport) pair() {
    final a = InMemoryTransport._();
    final b = InMemoryTransport._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  Future<void> advertise() async {}

  @override
  Future<void> discover() async {}

  @override
  Future<void> connect(String peerId) async {}

  @override
  void send(List<int> bytes) {
    final peer = _peer;
    if (peer == null || peer._incoming.isClosed) return;
    // Defensive copy: a real wire never lets the sender mutate bytes the
    // receiver hasn't read yet.
    peer._incoming.add(List<int>.from(bytes));
  }

  @override
  Stream<List<int>> get onReceive => _incoming.stream;

  @override
  Future<void> disconnect() async {
    await _incoming.close();
  }
}
