// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_session_test.dart — M4 protocol layer tests, over the in-memory
// loopback transport (no sockets, no radio, no second device -- the M4
// brief's "protocol first, radio later" testing strategy). Run with
// `flutter test` (needs the real FFI bridge for owner_pubkey/Poseidon2 and
// the Flutter test binding cryptography relies on for secure randomness).
//
// See match_session_socket_test.dart for the identical suite run over real
// localhost sockets -- the same test bodies live in match_session_suite.dart
// and are run against both transports unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';

import 'match_session_suite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  runMatchSessionTests('in-memory', () async => InMemoryTransport.pair());
}
