// SPDX-License-Identifier: GPL-3.0-or-later
//
// setup_ready_barrier_test.dart — the setup-finalization barrier
// (docs/AETHERIAL_ARMOR.md §3d).
//
// Setup validation is asymmetric in time: certification of the peer's armor
// happens on one device while the other, whose own armor is fine, has nothing
// left to check. Before the barrier, that side FINISHED setup and entered a
// battle screen for a match its opponent had already refused. The barrier
// makes readiness mutual — each side declares "everything passed" and waits
// for the other's declaration before any state exists.
//
// Every wait is bounded. The failure this guards against is a hang, and a hang
// must fail loudly in seconds rather than stall the suite.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/networking/battle_session.dart'
    show BattleSession, PeerForfeitException;
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/battle/networking/duel_setup.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../identity/fake_secure_storage.dart';
import '../../spells/fake_path_provider.dart';
import '../engine/certified_cast_fixture.dart' show syntheticProof;

const _bound = Duration(seconds: 5);

/// Accepts or rejects on demand, so one side can be made to reject the other's
/// armor while its own passes — the asymmetry the barrier exists for.
class SwitchableVerifier {
  SwitchableVerifier({this.accept = true});
  bool accept;
  int calls = 0;
  Future<bool> verify(Uint8List vk, Uint8List proof) async {
    calls++;
    return accept;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    installFakeSecureStorage();
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Uint8List ownerBytes(String hex) {
    final v = BigInt.parse(hex.startsWith('0x') ? hex.substring(2) : hex, radix: 16);
    final out = Uint8List(32);
    var n = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (n & BigInt.from(0xff)).toInt();
      n = n >> 8;
    }
    return out;
  }

  Future<SpellAsset> saveArmor({
    required String id,
    required String ownerPubkeyHex,
    int t = 4,
  }) async {
    final armor = SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 25),
      tier: 12,
      t: t,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: syntheticProof(
        tier: 12,
        t: t,
        commitmentBytes: Uint8List(32),
        rulesetVersion: 3,
        elements: List.filled(t, BorderZone.air),
        ownerPubkeyBytes: ownerBytes(ownerPubkeyHex),
      ),
      name: 'Armor $id',
      commitmentHex: '0x${id.padLeft(64, '0')}',
      spellHashHex: '',
      isArmor: true,
    );
    await armor.save();
    return armor;
  }

  Future<ChapterAsset> makeChapter({
    required String idSuffix,
    required String ownerPubkeyHex,
    String? armorSpellId,
  }) async {
    final spell = SpellAsset(
      id: 'spell-$idSuffix',
      createdAt: DateTime.utc(2026, 8, 25),
      tier: 24,
      t: 1,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: Uint8List(0),
      name: 'Spell $idSuffix',
      commitmentHex: '0x${idSuffix.padLeft(64, '0')}',
      spellHashHex: '',
    );
    await spell.save();
    return ChapterAsset(
      id: 'chapter-$idSuffix',
      name: 'Chapter $idSuffix',
      createdAt: DateTime.utc(2026, 8, 25),
      entries: [ChapterEntry(spellId: spell.id)],
      armorSpellId: armorSpellId,
    );
  }

  ({Future<DuelSetupResult> host, Future<DuelSetupResult> guest, Future<void> Function() close})
      startDuel({
    required Identity hostIdentity,
    required Identity guestIdentity,
    required ChapterAsset hostChapter,
    required ChapterAsset guestChapter,
    required SwitchableVerifier hostVerifier,
    required SwitchableVerifier guestVerifier,
  }) {
    Uint8List? vk(int tier) => Uint8List.fromList([tier]);
    final (a, b) = InMemoryTransport.pair();
    final host = runDuelSetup(
      transport: a,
      role: DuelRole.host,
      localIdentity: hostIdentity,
      localChapter: hostChapter,
      hostConfig: const MatchConfig(),
      verifyProof: hostVerifier.verify,
      vkBytesForTier: vk,
    );
    final guest = runDuelSetup(
      transport: b,
      role: DuelRole.guest,
      localIdentity: guestIdentity,
      localChapter: guestChapter,
      hostConfig: const MatchConfig(),
      verifyProof: guestVerifier.verify,
      vkBytesForTier: vk,
    );
    return (
      host: host,
      guest: guest,
      close: () async {
        await a.disconnect();
        await b.disconnect();
      },
    );
  }

  // ── The case the barrier exists for ────────────────────────────────────────

  test('A accepts B\'s armor while B rejects A\'s: NEITHER side returns a '
      'successful setup', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(id: 'ha', ownerPubkeyHex: hostOwner);
    await saveArmor(id: 'ga', ownerPubkeyHex: guestOwner);

    // The host accepts everything it is shown; the guest rejects the host's
    // armor. Nothing is wrong on the host's side of the check — which is
    // exactly why it used to sail through setup alone.
    final hostVerifier = SwitchableVerifier(accept: true);
    final guestVerifier = SwitchableVerifier(accept: false);

    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: hostOwner, armorSpellId: 'ha'),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: guestOwner, armorSpellId: 'ga'),
      hostVerifier: hostVerifier,
      guestVerifier: guestVerifier,
    );

    // B: its own local certification of A's armor failed, and it forfeited.
    await expectLater(
      duel.guest.timeout(_bound),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          allOf(contains('peer armor'), contains('rejected')))),
    );
    // A: blocked at the barrier, woken by B's forfeit, carrying B's reason.
    await expectLater(
      duel.host.timeout(_bound),
      throwsA(isA<PeerForfeitException>().having(
          (e) => e.reason, 'reason', 'armor_certification_failed')),
    );
    // Neither reached a BattleState, so neither can enter a battle screen.
    await duel.close();
  });

  test('the mirror image: A rejects B\'s armor', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(id: 'ha', ownerPubkeyHex: hostOwner);
    await saveArmor(id: 'ga', ownerPubkeyHex: guestOwner);

    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: hostOwner, armorSpellId: 'ha'),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: guestOwner, armorSpellId: 'ga'),
      hostVerifier: SwitchableVerifier(accept: false),
      guestVerifier: SwitchableVerifier(accept: true),
    );

    await expectLater(
      duel.host.timeout(_bound),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      duel.guest.timeout(_bound),
      throwsA(isA<PeerForfeitException>().having(
          (e) => e.reason, 'reason', 'armor_certification_failed')),
    );
    await duel.close();
  });

  // ── Normal setups still pass through the barrier ───────────────────────────

  test('no armor on either side still completes', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: await hostIdentity.ownerPubkeyHex()),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: await guestIdentity.ownerPubkeyHex()),
      hostVerifier: SwitchableVerifier(),
      guestVerifier: SwitchableVerifier(),
    );
    final results = await Future.wait([duel.host, duel.guest]).timeout(_bound);
    expect(results[0].localArmor, isNull);
    expect(results[1].localArmor, isNull);
    await duel.close();
  });

  test('one armor still completes', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(id: 'ha', ownerPubkeyHex: hostOwner);

    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: hostOwner, armorSpellId: 'ha'),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: await guestIdentity.ownerPubkeyHex()),
      hostVerifier: SwitchableVerifier(),
      guestVerifier: SwitchableVerifier(),
    );
    final results = await Future.wait([duel.host, duel.guest]).timeout(_bound);
    expect(results[0].localArmor, isNotNull);
    expect(results[1].peerArmor, isNotNull);
    expect(results[1].localArmor, isNull);
    await duel.close();
  });

  test('two armors still complete', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(id: 'ha', ownerPubkeyHex: hostOwner, t: 4);
    await saveArmor(id: 'ga', ownerPubkeyHex: guestOwner, t: 9);

    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: hostOwner, armorSpellId: 'ha'),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: guestOwner, armorSpellId: 'ga'),
      hostVerifier: SwitchableVerifier(),
      guestVerifier: SwitchableVerifier(),
    );
    final results = await Future.wait([duel.host, duel.guest]).timeout(_bound);

    expect(results[0].localArmor!.t, 4);
    expect(results[0].peerArmor!.t, 9);
    expect(results[1].localArmor!.t, 9);
    expect(results[1].peerArmor!.t, 4);
    // Still the same reading of one proof from both directions.
    expect(results[0].localArmor.toString(), results[1].peerArmor.toString());
    expect(results[1].localArmor.toString(), results[0].peerArmor.toString());
    await duel.close();
  });

  // ── The barrier itself ─────────────────────────────────────────────────────

  test('a successful setup really does exchange the frame', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final duel = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11', ownerPubkeyHex: await hostIdentity.ownerPubkeyHex()),
      guestChapter: await makeChapter(
        idSuffix: '22', ownerPubkeyHex: await guestIdentity.ownerPubkeyHex()),
      hostVerifier: SwitchableVerifier(),
      guestVerifier: SwitchableVerifier(),
    );
    await Future.wait([duel.host, duel.guest]).timeout(_bound);
    await duel.close();
  });

  test('the barrier blocks until the peer is ready, and a forfeit releases it',
      () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    // A is ready; B never will be.
    final blocked = sessionA.exchangeSetupReady();
    sessionB.sendForfeit('armor_certification_failed');

    await expectLater(
      blocked.timeout(_bound),
      throwsA(isA<PeerForfeitException>().having(
          (e) => e.reason, 'reason', 'armor_certification_failed')),
    );

    await a.disconnect();
    await b.disconnect();
  });

  test('two ready sides pass through it', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    await Future.wait([
      sessionA.exchangeSetupReady(),
      sessionB.exchangeSetupReady(),
    ]).timeout(_bound);

    await a.disconnect();
    await b.disconnect();
  });

  test('the frame is empty — it asserts nothing but readiness', () async {
    final (a, b) = InMemoryTransport.pair();
    final sessionA = BattleSession(a, Uint8List(16));
    final sessionB = BattleSession(b, Uint8List(16));

    final seen = sessionB.framesOfType(BattleMsgType.setupReady).first;
    final ready = sessionA.exchangeSetupReady();
    sessionB.send(BattleMsgType.setupReady, Uint8List(0));
    await ready.timeout(_bound);

    expect((await seen.timeout(_bound)).payload, isEmpty);

    await a.disconnect();
    await b.disconnect();
  });
}
