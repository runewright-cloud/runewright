// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_session_socket_test.dart — the identical MatchSession protocol
// suite (match_session_suite.dart), run over real localhost TCP sockets
// instead of the in-memory transport. This is the M4 plan's abstraction-
// integrity checkpoint: MatchSession itself is completely unchanged --
// only the transport pair factory differs from match_session_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';
import 'package:rune_duel/protocol/transport.dart';

import 'match_session_suite.dart';

Future<(Transport, Transport)> _localhostPair() async {
  final listener = await LanSocketTransport.bind(address: InternetAddress.loopbackIPv4);
  final acceptFuture = listener.acceptOnce();
  final client = await LanSocketTransport.connectTo('127.0.0.1', listener.port);
  final server = await acceptFuture;
  return (client, server);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  runMatchSessionTests('localhost sockets', _localhostPair);
}
