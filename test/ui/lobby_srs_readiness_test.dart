// SPDX-License-Identifier: GPL-3.0-or-later
//
// lobby_srs_readiness_test.dart — the battle lobby's "this device is not
// ready to duel" warning.
//
// Why it exists: every duel verifies the opponent's proofs, which needs the
// SRS on disk, and a device that has never inscribed a spell does not have
// it. The first duel fetches it — but duels happen in person, on whatever
// network the venue has, and a failure there is a blocking error mid-
// handshake with nothing the player can do. The warning moves that discovery
// to the lobby, where it is still fixable.
//
// The test drives the real readiness check (lib/ffi/srs_cache.dart's
// srsCacheReady) against a faked application-support directory, rather than
// stubbing it — the property under test is precisely that the check reads the
// same path the prover writes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ffi/srs_cache.dart';
import 'package:rune_duel/ui/battle_lobby_screen.dart';

import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Pumps the lobby and lets initState's real file-system check land.
  /// `runAsync`, because the check is real I/O that a fake clock never
  /// advances past.
  Future<void> pumpLobby(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: BattleLobbyScreen()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    await tester.pump();
  }

  testWidgets('a device with no cached SRS is told it is not ready',
      (tester) async {
    await pumpLobby(tester);

    expect(find.text('THIS DEVICE IS NOT READY TO DUEL'), findsOneWidget);
    expect(find.text('PREPARE THIS DEVICE'), findsOneWidget);
    // The size matters: it is why this is an explicit button and not a silent
    // background download.
    expect(find.textContaining(kSrsDownloadSizeApprox), findsOneWidget);
    // The warning must not stand between the player and a duel they may well
    // be able to start — a peer-to-peer duel is still reachable.
    expect(find.text('HOST A DUEL'), findsOneWidget);
    expect(find.text('JOIN A DUEL'), findsOneWidget);
  });

  testWidgets('a device that already has the SRS sees no warning',
      (tester) async {
    // Contents are irrelevant: srsCacheReady is an existence check, and it is
    // sound precisely because the Rust side sizes every download to the
    // tier-48 floor and publishes it atomically.
    //
    // Inside runAsync: this is real file I/O, and a real Future never
    // completes in the fake-async zone a testWidgets body runs in. Awaiting
    // it directly hangs the test until the 10-minute timeout rather than
    // failing, which is a confusing way to learn this.
    await tester.runAsync(() async {
      await File(await srsCachePath()).writeAsBytes([0, 1, 2, 3]);
    });

    await pumpLobby(tester);

    expect(find.text('THIS DEVICE IS NOT READY TO DUEL'), findsNothing);
    expect(find.text('PREPARE THIS DEVICE'), findsNothing);
    expect(find.text('HOST A DUEL'), findsOneWidget);
  });

  test('srsCacheReady tracks the file the prover actually writes', () async {
    final dir = await installFakePathProvider();
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    expect(await srsCacheReady(), isFalse);
    await File(await srsCachePath()).writeAsBytes([7]);
    expect(await srsCacheReady(), isTrue);
  });
}
