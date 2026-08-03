// SPDX-License-Identifier: GPL-3.0-or-later
//
// Smoke test: confirms RustLib loads on Linux desktop and poseidon2Hash2
// round-trips through the real FFI bridge (not a fake). Run with
// `flutter test`, not `dart test` -- needs the Flutter test binding.

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ffi/identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('poseidon2Hash2(0, 0) matches the known circuit-verified value', () async {
    final result = await poseidon2Hash2('0x0', '0x0');
    expect(result, '0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1');
  });
}
