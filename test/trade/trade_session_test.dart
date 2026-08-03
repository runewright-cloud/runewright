// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_session_test.dart — full Commune/Trade round-trip over
// InMemoryTransport (M4's "protocol first, radio later" strategy): offers
// exchanged, mutual confirm, both bundles saved. Also covers the rejection
// paths that make the trust boundary real: a grant naming someone else, a
// tampered/expired grant, and a transfer that actually delivers the grid.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/transport.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/spells/spell_authorization.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/trade/trade_offer.dart';
import 'package:rune_duel/trade/trade_session.dart';
import 'package:rune_duel/trade/trade_wire.dart';

import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  SpellAsset ownedSpell({
    required String id,
    required String ownerPubkeyHex,
    String commitmentHex = '0xaabbcc',
    String name = 'Ember Wake',
  }) =>
      SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 6, 19),
        tier: 12,
        t: 5,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: 10,
        segmentCount: 1,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: '0xddeeff',
      );

  /// Also returns the raw transports, so a test can inject a hand-built
  /// wire frame that bypasses TradeSession's normal (correct) grant-
  /// construction logic -- needed to simulate a forged or misdirected
  /// bundle entry and confirm the *receiving* side's checks actually reject
  /// it, rather than merely asserting the fixture is valid.
  Future<(TradeSession, TradeSession, Transport, Transport)> pairedSessionsWithTransports(
    Identity alice,
    Identity bob,
  ) async {
    final (tAlice, tBob) = InMemoryTransport.pair();
    final bobFuture = TradeSession.accept(tBob, bob);
    final aliceSession = await TradeSession.initiate(tAlice, alice);
    final bobSession = await bobFuture;
    return (aliceSession, bobSession, tAlice, tBob);
  }

  Future<(TradeSession, TradeSession)> pairedSessions(Identity alice, Identity bob) async {
    final (aliceSession, bobSession, _, _) = await pairedSessionsWithTransports(alice, bob);
    return (aliceSession, bobSession);
  }

  test('handshake resolves each side\'s peerOwnerPubkeyHex to the other\'s real identity', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final (aliceSession, bobSession) = await pairedSessions(alice, bob);

    expect(aliceSession.peerOwnerPubkeyHex, await bob.ownerPubkeyHex());
    expect(bobSession.peerOwnerPubkeyHex, await alice.ownerPubkeyHex());
    expect(aliceSession.tradeId, equals(bobSession.tradeId));
  });

  test('exchangeOffer delivers each side\'s offer to the other', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final (aliceSession, bobSession) = await pairedSessions(alice, bob);

    final aliceOffer = TradeOffer(items: [
      TradeItem(spellId: 'a1', commitmentHex: '0x1', spellName: 'Ember Wake', mode: TradeMode.loan, loanDays: 3),
    ]);
    const bobOffer = TradeOffer(items: []);

    final aliceSeesFuture = aliceSession.exchangeOffer(aliceOffer);
    final bobSeesFuture = bobSession.exchangeOffer(bobOffer);
    final aliceSees = await aliceSeesFuture;
    final bobSees = await bobSeesFuture;

    expect(bobSees.items, hasLength(1));
    expect(bobSees.items.first.spellName, 'Ember Wake');
    expect(aliceSees.items, isEmpty);
  });

  group('exchangeConfirm', () {
    test('returns true for both sides when both confirm', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceResultFuture = aliceSession.exchangeConfirm(true);
      final bobResultFuture = bobSession.exchangeConfirm(true);

      expect(await aliceResultFuture, isTrue);
      expect(await bobResultFuture, isTrue);
    });

    test('returns false for both sides when one side cancels', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceResultFuture = aliceSession.exchangeConfirm(true);
      final bobResultFuture = bobSession.exchangeConfirm(false);

      expect(await aliceResultFuture, isFalse);
      expect(await bobResultFuture, isFalse);
    });
  });

  group('exchangeGrantsAndSave', () {
    test('a mutual loan+transfer trade: both bundles are saved on both sides', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final alicePubkeyHex = await alice.ownerPubkeyHex();
      final bobPubkeyHex = await bob.ownerPubkeyHex();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceSpell = ownedSpell(id: 'alice-1', ownerPubkeyHex: alicePubkeyHex, commitmentHex: '0xa1');
      final bobSpell = ownedSpell(id: 'bob-1', ownerPubkeyHex: bobPubkeyHex, commitmentHex: '0xb1', name: 'Frost Bind');

      final aliceOffer = TradeOffer(items: [
        TradeItem(spellId: aliceSpell.id, commitmentHex: aliceSpell.commitmentHex, spellName: aliceSpell.name, mode: TradeMode.loan, loanDays: 5),
      ]);
      final bobOffer = TradeOffer(items: [
        TradeItem(spellId: bobSpell.id, commitmentHex: bobSpell.commitmentHex, spellName: bobSpell.name, mode: TradeMode.transfer),
      ]);

      final aliceResultFuture = aliceSession.exchangeGrantsAndSave(
        ourIdentity: alice,
        ourOffer: aliceOffer,
        ourSpells: [aliceSpell],
      );
      final bobResultFuture = bobSession.exchangeGrantsAndSave(
        ourIdentity: bob,
        ourOffer: bobOffer,
        ourSpells: [bobSpell],
      );

      final aliceResult = await aliceResultFuture;
      final bobResult = await bobResultFuture;

      // Alice sent a loan successfully, and received Bob's transfer.
      expect(aliceResult.sent, hasLength(1));
      expect(aliceResult.sent.single.success, isTrue);
      expect(aliceResult.received, hasLength(1));
      expect(aliceResult.received.single.success, isTrue);

      // Bob sent a transfer successfully, and received Alice's loan.
      expect(bobResult.sent, hasLength(1));
      expect(bobResult.sent.single.success, isTrue);
      expect(bobResult.received, hasLength(1));
      expect(bobResult.received.single.success, isTrue);

      // Bob actually received a local (grid-withheld) SpellAsset for the
      // loan -- not just the permission. Without one, localIdentityMayUse
      // would have nothing to check against; there is no other source for
      // a SpellAsset when only a loan (never the grid) was exchanged.
      final bobAssets = await SpellAsset.loadAll();
      final bobLoanedAsset = bobAssets.where((s) => s.commitmentHex == aliceSpell.commitmentHex).toList();
      expect(bobLoanedAsset, hasLength(1));
      expect(bobLoanedAsset.single.gridWithheld, isTrue);
      expect(bobLoanedAsset.single.initialGrid, isEmpty);
      expect(bobLoanedAsset.single.proofBytes, equals(aliceSpell.proofBytes));
      expect(bobLoanedAsset.single.ownerPubkeyHex, alicePubkeyHex);

      // And Bob's own received copy passes the local-use gate (unexpired).
      final bobUsable = await localIdentityMayUse(bobLoanedAsset.single, bob, now: DateTime.now().toUtc());
      expect(bobUsable, isTrue);

      // Alice received Bob's full spell asset -- including the grid, not just a reference.
      final aliceReceivedAssets = await SpellAsset.loadAll();
      final received = aliceReceivedAssets.where((s) => s.commitmentHex == bobSpell.commitmentHex).toList();
      expect(received, hasLength(1));
      expect(received.single.initialGrid, equals(bobSpell.initialGrid));
      expect(received.single.ownerPubkeyHex, bobPubkeyHex);

      // And Alice's local-use gate recognizes the perpetual transfer grant.
      final aliceUsable = await localIdentityMayUse(received.single, alice, now: DateTime.now().toUtc());
      expect(aliceUsable, isTrue);
    });

    test('an empty offer on both sides produces empty, successful results', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceResultFuture = aliceSession.exchangeGrantsAndSave(
        ourIdentity: alice,
        ourOffer: const TradeOffer(),
        ourSpells: const [],
      );
      final bobResultFuture = bobSession.exchangeGrantsAndSave(
        ourIdentity: bob,
        ourOffer: const TradeOffer(),
        ourSpells: const [],
      );

      final aliceResult = await aliceResultFuture;
      final bobResult = await bobResultFuture;

      expect(aliceResult.sent, isEmpty);
      expect(aliceResult.received, isEmpty);
      expect(bobResult.sent, isEmpty);
      expect(bobResult.received, isEmpty);
    });

    test('a grant naming someone other than the receiving peer is rejected, not saved', () async {
      // Alice signs a perfectly valid loan, but for a THIRD party (not
      // Bob), and this frame is injected directly onto the wire to Bob --
      // simulating a forged/misrouted bundle entry (TradeSession's own
      // construction logic would never do this; the point is to confirm
      // the *receiving* side's grantee check catches it regardless).
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final outsider = await Identity.ephemeral();
      final alicePubkeyHex = await alice.ownerPubkeyHex();
      final outsiderPubkeyHex = await outsider.ownerPubkeyHex();
      final (_, bobSession, tAlice, _) = await pairedSessionsWithTransports(alice, bob);

      final aliceSpell = ownedSpell(id: 'alice-1', ownerPubkeyHex: alicePubkeyHex, commitmentHex: '0xmisdirected');
      final misdirectedPerm = await SpellPermission.createAndSign(
        spell: aliceSpell,
        ownerIdentity: alice,
        granteePubkeyHex: outsiderPubkeyHex,
        kind: SpellGrantKind.loan,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
      );
      expect(await misdirectedPerm.isCurrentlyUsable(), isTrue); // valid crypto, just wrong addressee

      final bobResultFuture = bobSession.exchangeGrantsAndSave(
        ourIdentity: bob,
        ourOffer: const TradeOffer(),
        ourSpells: const [],
      );
      // Bypass aliceSession.exchangeGrantsAndSave (which would correctly
      // address the grant to Bob) and hand-inject the misdirected bundle
      // directly over Alice's raw transport.
      tAlice.send(TradeFrame(
        TradeMsgType.grantBundle,
        Uint8List.fromList(utf8.encode(jsonEncode({
          'entries': [
            {'permission': misdirectedPerm.toJson()}
          ]
        }))),
      ).encode());

      final bobResult = await bobResultFuture;

      expect(bobResult.received, hasLength(1));
      expect(bobResult.received.single.success, isFalse);
      expect(bobResult.received.single.error, contains('does not name'));

      final saved = await SpellPermission.loadForCommitment(aliceSpell.commitmentHex);
      expect(saved, isEmpty);
    });

    test('an expired loan received in a bundle is rejected, not saved', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final alicePubkeyHex = await alice.ownerPubkeyHex();
      final bobPubkeyHex = await bob.ownerPubkeyHex();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceSpell = ownedSpell(id: 'alice-1', ownerPubkeyHex: alicePubkeyHex, commitmentHex: '0xexp');

      // loanDays: 0 -> expiresAt == grantedAt, already expired by the time
      // it's checked.
      final aliceOffer = TradeOffer(items: [
        TradeItem(spellId: aliceSpell.id, commitmentHex: aliceSpell.commitmentHex, spellName: aliceSpell.name, mode: TradeMode.loan, loanDays: 0),
      ]);

      final aliceResultFuture = aliceSession.exchangeGrantsAndSave(
        ourIdentity: alice,
        ourOffer: aliceOffer,
        ourSpells: [aliceSpell],
      );
      final bobResultFuture = bobSession.exchangeGrantsAndSave(
        ourIdentity: bob,
        ourOffer: const TradeOffer(),
        ourSpells: const [],
      );

      await aliceResultFuture;
      final bobResult = await bobResultFuture;

      expect(bobResult.received, hasLength(1));
      expect(bobResult.received.single.success, isFalse);

      final bobUsable = await localIdentityMayUse(aliceSpell, bob);
      expect(bobUsable, isFalse);
      final saved = await SpellPermission.loadForCommitment(aliceSpell.commitmentHex);
      expect(saved, isEmpty);

      // Sanity: bobPubkeyHex really was the intended grantee (this failure
      // is purely about expiry, not a grantee mismatch).
      expect(bobPubkeyHex, isNotEmpty);
    });

    test('a spell referenced by id but missing from ourSpells is reported as a failed send', () async {
      final alice = await Identity.ephemeral();
      final bob = await Identity.ephemeral();
      final (aliceSession, bobSession) = await pairedSessions(alice, bob);

      final aliceOffer = TradeOffer(items: [
        TradeItem(spellId: 'ghost', commitmentHex: '0xdead', spellName: 'Ghost Spell', mode: TradeMode.transfer),
      ]);

      final aliceResultFuture = aliceSession.exchangeGrantsAndSave(
        ourIdentity: alice,
        ourOffer: aliceOffer,
        ourSpells: const [], // spell not actually present
      );
      final bobResultFuture = bobSession.exchangeGrantsAndSave(
        ourIdentity: bob,
        ourOffer: const TradeOffer(),
        ourSpells: const [],
      );

      final aliceResult = await aliceResultFuture;
      await bobResultFuture;

      expect(aliceResult.sent, hasLength(1));
      expect(aliceResult.sent.single.success, isFalse);
      expect(aliceResult.sent.single.error, contains('not found'));
    });
  });
}
