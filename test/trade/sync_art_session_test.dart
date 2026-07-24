// SPDX-License-Identifier: GPL-3.0-or-later
//
// sync_art_session_test.dart — full Commune/Sync Art round-trip over
// InMemoryTransport: both sides fulfill each other's want-list in one
// sync() call, no-op when there's nothing to offer or the requester is
// already current, and a tampered art payload is rejected rather than
// saved.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/transport.dart';
import 'package:rune_duel/spells/sighting_asset.dart';
import 'package:rune_duel/spells/spell_art_store.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/trade/sync_art_session.dart';
import 'package:rune_duel/trade/sync_art_wire.dart';

import '../spells/fake_path_provider.dart';

Future<String> _sha256Hex(Uint8List bytes) async {
  final hash = await Sha256().hash(bytes);
  return '0x${hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

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

  const commitmentHex = '0xaabbcc';

  SpellAsset ownedSpell({
    required String id,
    required String ownerPubkeyHex,
    String commitmentHex = commitmentHex,
    int t = 5,
    String name = 'Ember Wake',
    String? artHash,
  }) =>
      SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 6, 19),
        tier: 12,
        t: t,
        ownerPubkeyHex: ownerPubkeyHex,
        manaCost: 10,
        segmentCount: 1,
        dotCount: 0,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: '0x$id',
        artHash: artHash,
        artSource: artHash != null ? SpellArtSource.localImport : null,
      );

  Future<(SyncArtSession, SyncArtSession)> pairedSessions(Identity alice, Identity bob) async {
    final (tAlice, tBob) = InMemoryTransport.pair();
    final bobFuture = SyncArtSession.accept(tBob, bob);
    final aliceSession = await SyncArtSession.initiate(tAlice, alice);
    final bobSession = await bobFuture;
    return (aliceSession, bobSession);
  }

  Future<(SyncArtSession, SyncArtSession, Transport, Transport)> pairedSessionsWithTransports(
    Identity alice,
    Identity bob,
  ) async {
    final (tAlice, tBob) = InMemoryTransport.pair();
    final bobFuture = SyncArtSession.accept(tBob, bob);
    final aliceSession = await SyncArtSession.initiate(tAlice, alice);
    final bobSession = await bobFuture;
    return (aliceSession, bobSession, tAlice, tBob);
  }

  test('handshake resolves each side\'s peerOwnerPubkeyHex to the other\'s real identity',
      () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final (aliceSession, bobSession) = await pairedSessions(alice, bob);

    expect(aliceSession.peerOwnerPubkeyHex, await bob.ownerPubkeyHex());
    expect(bobSession.peerOwnerPubkeyHex, await alice.ownerPubkeyHex());
  });

  test('sync() delivers art from the true owner to a sighter, and saves it locally', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final bobPubkeyHex = await bob.ownerPubkeyHex();

    // Bob owns the spell natively and has custom art for it.
    final fullBytes = Uint8List.fromList(List.generate(64, (i) => i));
    final thumbBytes = Uint8List.fromList(List.generate(32, (i) => i));
    final artHash = await _sha256Hex(fullBytes);
    final bobSpell = ownedSpell(id: 'bob1', ownerPubkeyHex: bobPubkeyHex, artHash: artHash);
    await bobSpell.save();
    await SpellArtStore.save(bobSpell.spellHashHex, full: fullBytes, thumb: thumbBytes);

    // Alice sighted Bob casting it — she has the sighting, but no art yet.
    final aliceSighting = await SightingAsset.record(
      opponentPubkeyHex: bobPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 12,
      manaCost: 10,
    );
    expect(aliceSighting.artHash, isNull);

    final (aliceSession, bobSession) = await pairedSessions(alice, bob);
    final aliceResultFuture = aliceSession.sync(ourIdentity: alice);
    final bobResultFuture = bobSession.sync(ourIdentity: bob);
    final aliceResult = await aliceResultFuture;
    final bobResult = await bobResultFuture;

    expect(bobResult.sent, hasLength(1));
    expect(bobResult.sent.single.success, isTrue);
    expect(bobResult.sent.single.commitmentHex, equals(commitmentHex));

    expect(aliceResult.received, hasLength(1));
    expect(aliceResult.received.single.success, isTrue);

    final reloaded = (await SightingAsset.loadAll()).single;
    expect(reloaded.artHash, equals(artHash));
    expect(reloaded.artSource, equals(SpellArtSource.synced));

    final savedFull = await SpellArtStore.loadFull(reloaded.id);
    expect(savedFull, equals(fullBytes));
  });

  test('sync() is bidirectional in a single call', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final alicePubkeyHex = await alice.ownerPubkeyHex();
    final bobPubkeyHex = await bob.ownerPubkeyHex();

    const aliceCommitment = '0xa1a1a1';
    const bobCommitment = '0xb2b2b2';

    // Alice owns aliceCommitment with art; Bob has sighted it.
    final aliceFull = Uint8List.fromList(List.generate(10, (i) => i + 1));
    final aliceThumb = Uint8List.fromList(List.generate(5, (i) => i + 1));
    final aliceArtHash = await _sha256Hex(aliceFull);
    final aliceSpell = ownedSpell(
      id: 'alice1',
      ownerPubkeyHex: alicePubkeyHex,
      commitmentHex: aliceCommitment,
      artHash: aliceArtHash,
    );
    await aliceSpell.save();
    await SpellArtStore.save(aliceSpell.spellHashHex, full: aliceFull, thumb: aliceThumb);
    await SightingAsset.record(
      opponentPubkeyHex: alicePubkeyHex,
      commitmentHex: aliceCommitment,
      spellName: 'Ember Wake',
      t: 5,
      tier: 12,
      manaCost: 10,
    );

    // Bob owns bobCommitment with art; Alice has sighted it.
    final bobFull = Uint8List.fromList(List.generate(20, (i) => i + 2));
    final bobThumb = Uint8List.fromList(List.generate(6, (i) => i + 2));
    final bobArtHash = await _sha256Hex(bobFull);
    final bobSpell = ownedSpell(
      id: 'bob1',
      ownerPubkeyHex: bobPubkeyHex,
      commitmentHex: bobCommitment,
      artHash: bobArtHash,
    );
    await bobSpell.save();
    await SpellArtStore.save(bobSpell.spellHashHex, full: bobFull, thumb: bobThumb);
    await SightingAsset.record(
      opponentPubkeyHex: bobPubkeyHex,
      commitmentHex: bobCommitment,
      spellName: 'Frost Bolt',
      t: 5,
      tier: 12,
      manaCost: 10,
    );

    final (aliceSession, bobSession) = await pairedSessions(alice, bob);
    final aliceResultFuture = aliceSession.sync(ourIdentity: alice);
    final bobResultFuture = bobSession.sync(ourIdentity: bob);
    final aliceResult = await aliceResultFuture;
    final bobResult = await bobResultFuture;

    // Alice sent her art to Bob (who sighted aliceCommitment as Alice's).
    expect(aliceResult.sent.where((r) => r.success), hasLength(1));
    // Bob sent his art to Alice (who sighted bobCommitment as Bob's).
    expect(bobResult.sent.where((r) => r.success), hasLength(1));
    expect(aliceResult.received.where((r) => r.success), hasLength(1));
    expect(bobResult.received.where((r) => r.success), hasLength(1));

    final all = await SightingAsset.loadAll();
    final aliceSighting = all.firstWhere((s) => s.opponentPubkeyHex == alicePubkeyHex);
    final bobSighting = all.firstWhere((s) => s.opponentPubkeyHex == bobPubkeyHex);
    expect(aliceSighting.artHash, equals(aliceArtHash));
    expect(bobSighting.artHash, equals(bobArtHash));
  });

  test('sync() is a no-op when the owner has no art for the sighted commitment', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final bobPubkeyHex = await bob.ownerPubkeyHex();

    // Bob owns the spell but has never set custom art.
    await ownedSpell(id: 'bob1', ownerPubkeyHex: bobPubkeyHex).save();
    await SightingAsset.record(
      opponentPubkeyHex: bobPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 12,
      manaCost: 10,
    );

    final (aliceSession, bobSession) = await pairedSessions(alice, bob);
    final aliceResultFuture = aliceSession.sync(ourIdentity: alice);
    final bobResultFuture = bobSession.sync(ourIdentity: bob);
    final aliceResult = await aliceResultFuture;
    final bobResult = await bobResultFuture;

    expect(bobResult.sent, isEmpty);
    expect(aliceResult.received, isEmpty);

    final reloaded = (await SightingAsset.loadAll()).single;
    expect(reloaded.artHash, isNull);
  });

  test('sync() does not re-send art the requester already has', () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final bobPubkeyHex = await bob.ownerPubkeyHex();

    final fullBytes = Uint8List.fromList(List.generate(8, (i) => i));
    final thumbBytes = Uint8List.fromList(List.generate(4, (i) => i));
    final artHash = await _sha256Hex(fullBytes);
    final bobSpell = ownedSpell(id: 'bob1', ownerPubkeyHex: bobPubkeyHex, artHash: artHash);
    await bobSpell.save();
    await SpellArtStore.save(bobSpell.spellHashHex, full: fullBytes, thumb: thumbBytes);

    // Alice already has this exact art synced from a previous session.
    final aliceSighting = await SightingAsset.record(
      opponentPubkeyHex: bobPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 12,
      manaCost: 10,
    );
    await aliceSighting.withArt(hash: artHash).save();

    final (aliceSession, bobSession) = await pairedSessions(alice, bob);
    final aliceResultFuture = aliceSession.sync(ourIdentity: alice);
    final bobResultFuture = bobSession.sync(ourIdentity: bob);
    final aliceResult = await aliceResultFuture;
    final bobResult = await bobResultFuture;

    expect(bobResult.sent, isEmpty, reason: 'requester already reported the current artHash');
    expect(aliceResult.received, isEmpty);
  });

  test('a tampered art payload (bytes do not hash to the claimed artHash) is rejected, not saved',
      () async {
    final alice = await Identity.ephemeral();
    final bob = await Identity.ephemeral();
    final bobPubkeyHex = await bob.ownerPubkeyHex();

    await SightingAsset.record(
      opponentPubkeyHex: bobPubkeyHex,
      commitmentHex: commitmentHex,
      spellName: 'Ember Wake',
      t: 5,
      tier: 12,
      manaCost: 10,
    );

    final (aliceSession, bobSession, _, tBob) = await pairedSessionsWithTransports(alice, bob);

    // Don't run Bob's real sync() at all -- script his side manually over
    // the raw transport so the sequence is deterministic (mirrors
    // trade_session_test.dart's rationale for pairedSessionsWithTransports:
    // bypass the normal, correct bundle-construction logic to confirm the
    // RECEIVING side's checks actually reject a forged payload).
    final aliceWantlistFuture = bobSession.framesOfType(SyncArtMsgType.wantlist).first;
    final aliceResultFuture = aliceSession.sync(ourIdentity: alice);

    // Round 1: Bob replies with an empty want-list so Alice's round 1 completes.
    await aliceWantlistFuture;
    tBob.send(
      SyncArtFrame(SyncArtMsgType.wantlist, Uint8List.fromList(utf8.encode(jsonEncode({'items': []}))))
          .encode(),
    );

    // Round 2: Bob sends a forged artBundle whose bytes don't hash to the
    // claimed artHash.
    final forged = jsonEncode({
      'items': [
        {
          'commitmentHex': commitmentHex,
          'artHash': '0x00', // deliberately wrong for the bytes below
          'spellName': 'Forged',
          'fullBase64': base64Encode(Uint8List.fromList([9, 9, 9])),
          'thumbBase64': base64Encode(Uint8List.fromList([9, 9])),
        }
      ],
    });
    tBob.send(SyncArtFrame(SyncArtMsgType.artBundle, Uint8List.fromList(utf8.encode(forged))).encode());

    final aliceResult = await aliceResultFuture;
    expect(aliceResult.received, hasLength(1));
    expect(aliceResult.received.single.success, isFalse);
    expect(aliceResult.received.single.error, contains('integrity'));

    final reloaded = (await SightingAsset.loadAll()).single;
    expect(reloaded.artHash, isNull, reason: 'a failed integrity check must not save anything');
  });
}
