// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_setup_armor_test.dart — the Aetherial Armor setup trust boundary
// (docs/AETHERIAL_ARMOR.md slice 4).
//
// Two real `runDuelSetup` calls over a paired InMemoryTransport, exactly like
// duel_setup_test.dart, with synthetic proof bytes and an INJECTED fake
// verifier — no FFI, no real proving. What is being pinned is not the crypto
// (that is barretenberg's job and is exercised elsewhere) but the plumbing
// around it: that the peer's bytes actually reach a verifier, that every
// owner/ruleset/tier/budget check refuses a match rather than degrading it,
// and that the local `parseOwn` path and the peer `verifyAndParse` path
// produce the SAME CertifiedArmor from the same proof.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/networking/battle_session.dart'
    show PeerForfeitException;
import 'package:rune_duel/battle/networking/duel_setup.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../identity/fake_secure_storage.dart';
import '../../spells/fake_path_provider.dart';
import '../engine/certified_cast_fixture.dart' show syntheticProof;

/// A verifier that accepts everything and records what it was asked about —
/// so a test can prove the peer's bytes actually reached it.
class RecordingVerifier {
  final calls = <({Uint8List vk, Uint8List proof})>[];
  bool accept = true;

  Future<bool> verify(Uint8List vk, Uint8List proof) async {
    calls.add((vk: vk, proof: proof));
    return accept;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;
  late RecordingVerifier hostVerifier;
  late RecordingVerifier guestVerifier;

  setUp(() async {
    installFakeSecureStorage();
    tempDir = await installFakePathProvider();
    hostVerifier = RecordingVerifier();
    guestVerifier = RecordingVerifier();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // Distinct per tier, so a test can prove WHICH vk the verifier was handed.
  Uint8List vkFor(int tier) => Uint8List.fromList([0xAA, tier]);

  /// An owner_pubkey hex Field as the 32 big-endian bytes the proof carries.
  /// Without this the fixture's owner field is all zeros and every armor is
  /// refused as "another wizard's" — which is the check working, but not the
  /// thing under test.
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

  // ── Fixtures ───────────────────────────────────────────────────────────────

  /// A persisted armor whose proof attests [elements] under [ownerPubkeyHex].
  Future<SpellAsset> saveArmor({
    required String id,
    required String ownerPubkeyHex,
    required List<BorderZone> elements,
    int? t,
    int? storedTier,
    int rulesetVersion = kRulesetVersion,
    bool isArmor = true,
    Uint8List? proofBytes,
  }) async {
    final generations = t ?? elements.length;
    final tier = generations <= 12 ? 12 : (generations <= 24 ? 24 : 48);
    final armor = SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 25),
      tier: storedTier ?? tier,
      t: generations,
      ownerPubkeyHex: ownerPubkeyHex,
      manaCost: 999, // authored nonsense: must never reach the certified armor
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: proofBytes ??
          syntheticProof(
            tier: tier,
            t: generations,
            commitmentBytes: Uint8List(32),
            rulesetVersion: rulesetVersion,
            elements: elements,
            ownerPubkeyBytes: ownerBytes(ownerPubkeyHex),
          ),
      name: 'Armor $id',
      commitmentHex: '0x${id.padLeft(64, '0')}',
      spellHashHex: '',
      formula: List.filled(12, 'earth'), // ditto
      supremeTags: const ['earth'], // ditto
      isArmor: isArmor,
    );
    await armor.save();
    return armor;
  }

  Future<ChapterAsset> makeChapter({
    required String idSuffix,
    required String ownerPubkeyHex,
    List<ArtifactEntry> artifacts = const [],
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
      name: 'Test Spell $idSuffix',
      commitmentHex: '0x${idSuffix.padLeft(64, '0')}',
      spellHashHex: '',
    );
    await spell.save();
    return ChapterAsset(
      id: 'chapter-$idSuffix',
      name: 'Chapter $idSuffix',
      createdAt: DateTime.utc(2026, 8, 25),
      entries: [ChapterEntry(spellId: spell.id)],
      artifacts: artifacts,
      armorSpellId: armorSpellId,
    );
  }

  /// Starts both halves of a duel and returns their futures separately.
  ///
  /// Separately, deliberately: when one side refuses the match mid-handshake
  /// the OTHER side is left blocked in `_awaitFrame` until its transport dies,
  /// so `Future.wait` on the pair never completes. A test asserting a refusal
  /// must await only the refusing side — see [expectAbort]. (This mirrors why
  /// battle_engine_version_test.dart drives its refusals against a hand-rolled
  /// fake peer rather than a second real `runDuelSetup`.)
  ({Future<DuelSetupResult> host, Future<DuelSetupResult> guest, Future<void> Function() close})
      startDuel({
    required Identity hostIdentity,
    required Identity guestIdentity,
    required ChapterAsset hostChapter,
    required ChapterAsset guestChapter,
  }) {
    final (transportHost, transportGuest) = InMemoryTransport.pair();
    final host = runDuelSetup(
      transport: transportHost,
      role: DuelRole.host,
      localIdentity: hostIdentity,
      localChapter: hostChapter,
      hostConfig: const MatchConfig(),
      verifyProof: hostVerifier.verify,
      vkBytesForTier: vkFor,
    );
    final guest = runDuelSetup(
      transport: transportGuest,
      role: DuelRole.guest,
      localIdentity: guestIdentity,
      localChapter: guestChapter,
      hostConfig: const MatchConfig(),
      verifyProof: guestVerifier.verify,
      vkBytesForTier: vkFor,
    );
    return (
      host: host,
      guest: guest,
      close: () async {
        await transportHost.disconnect();
        await transportGuest.disconnect();
      },
    );
  }

  /// Runs a duel expected to SUCCEED on both sides.
  Future<List<DuelSetupResult>> runDuel({
    required Identity hostIdentity,
    required Identity guestIdentity,
    required ChapterAsset hostChapter,
    required ChapterAsset guestChapter,
  }) async {
    final d = startDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: hostChapter,
      guestChapter: guestChapter,
    );
    return Future.wait([d.host, d.guest]);
  }

  /// Asserts that a refusal terminates BOTH sides promptly: the refusing side
  /// with its own local diagnosis, the other with a [PeerForfeitException]
  /// carrying the reason that was actually transmitted.
  ///
  /// The bounded timeout is the regression guard. Before setup aborts woke
  /// blocked typed waits (slice 4.5), the other side sat in `_awaitFrame`
  /// until the socket died — so this shape HUNG, and a reintroduced hang must
  /// fail loudly here rather than stall the suite.
  ///
  /// Crucially, [close] is called only AFTER both futures have settled: the
  /// wake must come from the forfeit frame, not from transport teardown.
  Future<void> expectBoundedRejection(
    ({Future<DuelSetupResult> host, Future<DuelSetupResult> guest, Future<void> Function() close}) duel, {
    required bool refusedByHost,
    required Matcher localMessage,
    String forfeitReason = 'armor_certification_failed',
  }) async {
    const bound = Duration(seconds: 5);
    final refuser = refusedByHost ? duel.host : duel.guest;
    final waiter = refusedByHost ? duel.guest : duel.host;

    await expectLater(
      refuser.timeout(bound),
      throwsA(isA<StateError>().having((e) => e.message, 'message', localMessage)),
    );
    await expectLater(
      waiter.timeout(bound),
      throwsA(isA<PeerForfeitException>()
          .having((e) => e.reason, 'reason', forfeitReason)),
    );
    await duel.close();
  }

  void expectSameArmor(CertifiedArmor? a, CertifiedArmor? b, String why) {
    expect(a?.toString(), b?.toString(), reason: why);
    expect(a?.keywords, b?.keywords, reason: why);
    expect(a?.elementSequence, b?.elementSequence, reason: why);
  }

  // ── The four loadout combinations ──────────────────────────────────────────

  test('no armor on either side: setup completes, both armors null', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
        artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
      ),
    );

    expect(results[0].localArmor, isNull);
    expect(results[0].peerArmor, isNull);
    expect(results[1].localArmor, isNull);
    expect(results[1].peerArmor, isNull);
    // The artifact-only setup is untouched: state still built, loadout still
    // exchanged.
    expect(results[0].state.avatars, hasLength(2));
    // Nothing to verify, so the verifier was never called.
    expect(hostVerifier.calls, isEmpty);
    expect(guestVerifier.calls, isEmpty);
  });

  test('armor on the host only: each side sees it from its own direction',
      () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: List.filled(9, BorderZone.earth), // T=9 -> 3 slots
    );

    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: hostOwner,
        armorSpellId: 'ha',
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
      ),
    );

    expect(results[0].localArmor, isNotNull);
    expect(results[0].peerArmor, isNull);
    expect(results[1].localArmor, isNull);
    expect(results[1].peerArmor, isNotNull);

    // THE ASYMMETRY: the host derived this through parseOwn, the guest through
    // verifyAndParse, and the two readings are identical.
    expectSameArmor(results[0].localArmor, results[1].peerArmor,
        'parseOwn and verifyAndParse must agree on one proof');
    expect(results[0].localArmor!.slotCost, 3);
    expect(results[0].localArmor!.earthCount, 9);
  });

  test('armor on the guest only', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(4, BorderZone.air),
    );

    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: guestOwner,
        armorSpellId: 'ga',
      ),
    );

    expect(results[0].peerArmor, isNotNull);
    expect(results[1].localArmor, isNotNull);
    expectSameArmor(results[1].localArmor, results[0].peerArmor,
        'parseOwn and verifyAndParse must agree on one proof');
    expect(results[0].peerArmor!.keywords, {ArmorKeyword.flying});
  });

  test('armor on both sides: four certifications, two agreements', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: List.filled(4, BorderZone.fire),
    );
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(10, BorderZone.water),
    );

    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: hostOwner,
        armorSpellId: 'ha',
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: guestOwner,
        armorSpellId: 'ga',
      ),
    );

    expectSameArmor(results[0].localArmor, results[1].peerArmor, 'host armor');
    expectSameArmor(results[1].localArmor, results[0].peerArmor, 'guest armor');
    expect(results[0].localArmor!.keywords, {ArmorKeyword.cleave});
    expect(results[1].localArmor!.spellRangeBonus, 2); // 10 water
  });

  // ── The verifier is really used ────────────────────────────────────────────

  test('the peer\'s proof bytes actually pass through the verifier, with the '
      'VK for its declared tier', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    final guestArmor = await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(4, BorderZone.air),
    );

    await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: guestOwner,
        armorSpellId: 'ga',
      ),
    );

    expect(hostVerifier.calls, hasLength(1));
    expect(hostVerifier.calls.single.proof, guestArmor.proofBytes);
    expect(hostVerifier.calls.single.vk, vkFor(12));
    // The guest never verifies its OWN armor — parseOwn skips verification.
    expect(guestVerifier.calls, isEmpty);
  });

  test('a peer proof the verifier rejects aborts the match', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(4, BorderZone.air),
    );
    hostVerifier.accept = false;

    // THE ASYMMETRIC CASE, and why the setup-ready barrier exists (slice 4.6).
    //
    // The host sends its own (empty) envelope before verifying the guest's, so
    // the guest passes the exchange and every check of its own — it has no way
    // to know it has been rejected. Before the barrier it therefore FINISHED
    // setup and walked into a battle screen for a match the host had already
    // abandoned. Now it blocks at the barrier instead, and the host's forfeit
    // wakes it. Neither side returns a result.
    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: guestOwner,
          armorSpellId: 'ga',
        ),
      ),
      refusedByHost: true,
      localMessage: allOf(contains('peer armor'), contains('rejected')),
    );
  });

  // ── Owner binding ──────────────────────────────────────────────────────────

  test('an armor proven under another wizard\'s key is refused — there are no '
      'armor loans', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final strangerIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    // The guest equips an armor whose proof binds the STRANGER's key.
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: await strangerIdentity.ownerPubkeyHex(),
      elements: List.filled(4, BorderZone.air),
    );

    // The guest catches it locally first — its own armor is not its own —
    // which is the earlier and better failure: the bad proof never reaches
    // the wire at all.
    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: guestOwner,
          armorSpellId: 'ga',
        ),
      ),
      refusedByHost: false,
      localMessage: allOf(contains('local armor'), contains('another wizard')),
    );
  });

  // ── Ruleset epoch ──────────────────────────────────────────────────────────

  test('an armor proven under a different ruleset epoch is refused', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(4, BorderZone.air),
      rulesetVersion: kRulesetVersion + 1,
    );

    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: guestOwner,
          armorSpellId: 'ga',
        ),
      ),
      refusedByHost: false,
      localMessage: contains('ruleset version'),
    );
  });

  // ── The 12-slot budget, recomputed from the certified T ────────────────────

  test('artifacts + certified armor cost of exactly 12 is allowed', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: List.filled(9, BorderZone.earth), // 3 slots
    );

    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: hostOwner,
        artifacts: List.generate(
            9, (_) => const ArtifactEntry(kind: ArtifactKind.manaGem)),
        armorSpellId: 'ha',
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
      ),
    );

    expect(results[0].localArmor!.slotCost, 3);
    expect(results[1].peerArmor!.slotCost, 3);
  });

  test('artifacts + certified armor cost over 12 aborts, on both sides',
      () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: List.filled(9, BorderZone.earth), // 3 slots
    );

    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: hostOwner,
          artifacts: List.generate(
              10, (_) => const ArtifactEntry(kind: ArtifactKind.manaGem)),
          armorSpellId: 'ha',
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
        ),
      ),
      refusedByHost: true,
      localMessage: contains('over the 12-slot limit'),
    );
  });

  // ── Authored metadata never reaches the certified armor ────────────────────

  test('the certified armor ignores the asset\'s authored formula, mana cost '
      'and supreme tags', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final guestOwner = await guestIdentity.ownerPubkeyHex();
    // The fixture's authored fields claim twelve earths; the proof attests
    // four airs.
    await saveArmor(
      id: 'ga',
      ownerPubkeyHex: guestOwner,
      elements: List.filled(4, BorderZone.air),
    );

    final results = await runDuel(
      hostIdentity: hostIdentity,
      guestIdentity: guestIdentity,
      hostChapter: await makeChapter(
        idSuffix: '11',
        ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
      ),
      guestChapter: await makeChapter(
        idSuffix: '22',
        ownerPubkeyHex: guestOwner,
        armorSpellId: 'ga',
      ),
    );

    final peer = results[0].peerArmor!;
    expect(peer.airCount, 4);
    expect(peer.earthCount, 0);
    expect(peer.armorHpBonus, 0);
    expect(peer.moveSpeedBonus, 1);
    expect(peer.keywords, {ArmorKeyword.flying});
    expect(peer.slotCost, 1);
  });

  // ── Local-side refusals ────────────────────────────────────────────────────

  test('a chapter equipping a non-armor spell aborts before the wire',
      () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: List.filled(4, BorderZone.air),
      isArmor: false,
    );

    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: hostOwner,
          armorSpellId: 'ha',
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
        ),
      ),
      refusedByHost: true,
      localMessage: contains('not marked as an armor'),
    );
  });

  test('a chapter equipping an armor with no proof aborts', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwner = await hostIdentity.ownerPubkeyHex();
    await saveArmor(
      id: 'ha',
      ownerPubkeyHex: hostOwner,
      elements: const [],
      t: 4,
      proofBytes: Uint8List(0),
    );

    await expectBoundedRejection(
      startDuel(
        hostIdentity: hostIdentity,
        guestIdentity: guestIdentity,
        hostChapter: await makeChapter(
          idSuffix: '11',
          ownerPubkeyHex: hostOwner,
          armorSpellId: 'ha',
        ),
        guestChapter: await makeChapter(
          idSuffix: '22',
          ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
        ),
      ),
      refusedByHost: true,
      localMessage: contains('carries no proof'),
    );
  });
}
