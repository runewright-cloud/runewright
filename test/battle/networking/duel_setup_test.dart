// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_setup_test.dart — runDuelSetup (LAN_BATTLE_WIREUP_PLAN.md §3.2): the
// LAN → BattleScreen setup flow. Two real `runDuelSetup` calls (host+guest)
// over a paired InMemoryTransport, mirroring auth_handshake_test.dart's "no
// mocks, protocol first" approach.
//
// Covers the two load-bearing correctness properties the plan flags:
//   1. DECISION 2 (pubkey-sorted roles): both devices must derive an
//      identical BattleState with no host/guest branch.
//   2. The confirmed peer-artifact-loadout risk (duel_battle_setup.dart's doc
//      comment): a stubbed peer loadout diverges the state hash on turn 1 —
//      this test gives host and guest DIFFERENT artifact loadouts specifically
//      to catch a regression back to that stub.
// Also verifies DECISION 3 (host-authoritative config): the guest is handed
// a deliberately different config as its own `hostConfig` argument, proving
// it ends up running the HOST's config, not its own.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/networking/duel_setup.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

import '../../identity/fake_secure_storage.dart';
import '../../spells/fake_path_provider.dart';

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
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<ChapterAsset> makeChapter({
    required String idSuffix,
    required String ownerPubkeyHex,
    required List<ArtifactEntry> artifacts,
  }) async {
    final spell = SpellAsset(
      id: 'spell-$idSuffix',
      createdAt: DateTime.utc(2026, 7, 19),
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
      formula: const [],
    );
    await spell.save();
    return ChapterAsset(
      id: 'chapter-$idSuffix',
      name: 'Chapter $idSuffix',
      createdAt: DateTime.utc(2026, 7, 19),
      entries: [ChapterEntry(spellId: spell.id)],
      artifacts: artifacts,
    );
  }

  test(
      'host and guest derive identical BattleState with pubkey-sorted roles '
      'and each other\'s real artifact loadout', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwnerHex = await hostIdentity.ownerPubkeyHex();
    final guestOwnerHex = await guestIdentity.ownerPubkeyHex();

    // Deliberately different loadouts — the regression this test guards
    // against is a peer avatar built from a stubbed/placeholder loadout
    // instead of what's exchanged over the wire.
    final hostChapter = await makeChapter(
      idSuffix: '11',
      ownerPubkeyHex: hostOwnerHex,
      artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.bookmark),
      ],
    );
    final guestChapter = await makeChapter(
      idSuffix: '22',
      ownerPubkeyHex: guestOwnerHex,
      artifacts: const [
        ArtifactEntry(kind: ArtifactKind.manaGem),
        ArtifactEntry(kind: ArtifactKind.rodOfSpreading),
      ],
    );

    const hostConfig = MatchConfig(playerHp: 32, gridRadius: 5);
    // Deliberately different from hostConfig — proves the guest ends up
    // running the HOST's config (DECISION 3), not whatever it locally passed.
    const guestLocalConfig = MatchConfig(playerHp: 8, gridRadius: 2);

    final (transportHost, transportGuest) = InMemoryTransport.pair();

    final results = await Future.wait([
      runDuelSetup(
        transport: transportHost,
        role: DuelRole.host,
        localIdentity: hostIdentity,
        localChapter: hostChapter,
        hostConfig: hostConfig,
      ),
      runDuelSetup(
        transport: transportGuest,
        role: DuelRole.guest,
        localIdentity: guestIdentity,
        localChapter: guestChapter,
        hostConfig: guestLocalConfig,
      ),
    ]);
    final hostResult = results[0];
    final guestResult = results[1];

    // matchId agreed, non-trivial (not all-zero), identical on both sides.
    expect(hostResult.matchId, equals(guestResult.matchId));
    expect(hostResult.matchId.length, equals(16));
    expect(hostResult.matchId.any((b) => b != 0), isTrue);

    // DECISION 3: guest ends up with the HOST's config, not its own.
    expect(hostResult.effectiveConfig.matches(hostConfig), isTrue);
    expect(guestResult.effectiveConfig.matches(hostConfig), isTrue);

    // Each side's localPlayerId is its own authenticated hex.
    expect(hostResult.localPlayerId, equals(hostOwnerHex));
    expect(guestResult.localPlayerId, equals(guestOwnerHex));

    // Mutual authentication bound the real identities.
    expect(hostResult.peer.ownerPubkeyHex, equals(guestOwnerHex));
    expect(guestResult.peer.ownerPubkeyHex, equals(hostOwnerHex));

    // The load-bearing property: byte-identical canonical state on both
    // devices, with no host/guest branch.
    expect(
      hostResult.state.toCanonicalBytes(),
      equals(guestResult.state.toCanonicalBytes()),
      reason: 'setup diverged between host and guest — check DECISION 2 '
          'pubkey ordering and the artifact-loadout exchange',
    );

    // DECISION 2: the lower (BigInt) owner hex spawns bottom (avatars[0]).
    BigInt parseHex(String h) => BigInt.parse(h.startsWith('0x') ? h.substring(2) : h, radix: 16);
    final expectedBottom =
        parseHex(hostOwnerHex) < parseHex(guestOwnerHex) ? hostOwnerHex : guestOwnerHex;
    expect(hostResult.state.avatars.first.playerId, equals(expectedBottom));

    // Each avatar carries its own real artifact loadout, not a stub, and the
    // mapping is one-for-one (nothing is inserted — the mana pool is innate,
    // there is no auto-added core gem): 3 host artifacts (2 gems + bookmark)
    // vs 2 guest artifacts (gem + rod).
    final hostAvatar =
        hostResult.state.avatars.firstWhere((a) => a.playerId == hostOwnerHex);
    final guestAvatar =
        hostResult.state.avatars.firstWhere((a) => a.playerId == guestOwnerHex);
    expect(hostAvatar.accoutrements, hasLength(3));
    expect(guestAvatar.accoutrements, hasLength(2));
    expect(hostAvatar.ownerPubkeyHex, equals(hostOwnerHex));
    expect(guestAvatar.ownerPubkeyHex, equals(guestOwnerHex));

    await transportHost.disconnect();
    await transportGuest.disconnect();
  });

  test('two independent TurnLoops over the real handshake result stay in '
      'lockstep across turns', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostOwnerHex = await hostIdentity.ownerPubkeyHex();
    final guestOwnerHex = await guestIdentity.ownerPubkeyHex();

    final hostChapter = await makeChapter(
      idSuffix: '33',
      ownerPubkeyHex: hostOwnerHex,
      artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
    );
    final guestChapter = await makeChapter(
      idSuffix: '44',
      ownerPubkeyHex: guestOwnerHex,
      artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
    );

    const hostConfig = MatchConfig();
    final (transportHost, transportGuest) = InMemoryTransport.pair();

    final results = await Future.wait([
      runDuelSetup(
        transport: transportHost,
        role: DuelRole.host,
        localIdentity: hostIdentity,
        localChapter: hostChapter,
        hostConfig: hostConfig,
      ),
      runDuelSetup(
        transport: transportGuest,
        role: DuelRole.guest,
        localIdentity: guestIdentity,
        localChapter: guestChapter,
        hostConfig: hostConfig,
      ),
    ]);
    final hostResult = results[0];
    final guestResult = results[1];

    final loopHost = TurnLoop(
      state: hostResult.state,
      session: hostResult.session,
      localPlayerId: hostResult.localPlayerId,
      matchId: hostResult.matchId,
    );
    final loopGuest = TurnLoop(
      state: guestResult.state,
      session: guestResult.session,
      localPlayerId: guestResult.localPlayerId,
      matchId: guestResult.matchId,
    );

    final input = TurnInput(action: PassAction());

    await Future.wait([loopHost.runTurn(input), loopGuest.runTurn(input)]);
    expect(
      hostResult.state.toCanonicalBytes(),
      equals(guestResult.state.toCanonicalBytes()),
      reason: 'Turn 1: canonical state diverged over the real wire session.',
    );

    await Future.wait([loopHost.runTurn(input), loopGuest.runTurn(input)]);
    expect(
      hostResult.state.toCanonicalBytes(),
      equals(guestResult.state.toCanonicalBytes()),
      reason: 'Turn 2: canonical state diverged over the real wire session.',
    );

    await transportHost.disconnect();
    await transportGuest.disconnect();
  });
}
