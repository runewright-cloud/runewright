// SPDX-License-Identifier: GPL-3.0-or-later
//
// fake_secure_storage.dart — in-memory mock for flutter_secure_storage's
// platform channel, for tests run via plain `flutter test` (no real device,
// so the native Keystore/Keychain/libsecret backends aren't reachable;
// flutter_secure_storage_linux in particular is a native-only plugin with
// no Dart fallback, never registered under the headless test engine).
// Backs only the methods Identity actually calls (write/read/delete).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _kChannelName = 'plugins.it_nomads.com/flutter_secure_storage';

/// Installs an in-memory fake for the secure-storage channel. Call once per
/// test (or in `setUp`); each call starts with an empty store.
void installFakeSecureStorage() {
  final store = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel(_kChannelName),
    (call) async {
      switch (call.method) {
        case 'write':
          store[call.arguments['key'] as String] = call.arguments['value'] as String;
          return null;
        case 'read':
          return store[call.arguments['key'] as String];
        case 'delete':
          store.remove(call.arguments['key'] as String);
          return null;
        case 'containsKey':
          return store.containsKey(call.arguments['key'] as String);
        default:
          throw UnimplementedError('fake_secure_storage: unhandled method ${call.method}');
      }
    },
  );
}
