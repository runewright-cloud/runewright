// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_engine_version_test.dart — the deterministic battle-engine epoch
// (lib/battle/engine/battle_engine_version.dart) must actually gate a match.
//
// The gap: commit e0010e1 changed simultaneous free-move runs from
// device-relative order to ascending canonical owner pubkey. Same wire bytes,
// same proofs, same VK — so `kBattleProtocolVersion` and the proof's
// `ruleset_version` both pass — while a patched and an unpatched client
// compute different canonical BattleStates from identical inputs. The old
// symptom was a state-hash mismatch mid-duel, indistinguishable from cheating.
//
// These tests drive the real `runDuelSetup` against a hand-rolled peer that
// declares a different engine epoch, exactly as an unpatched build would.
// The peer sends real frames through a real BattleSession — no mocks — so a
// regression that drops the gate fails here rather than on someone's phone.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/battle_engine_version.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/battle/networking/battle_wire.dart';
import 'package:rune_duel/battle/networking/duel_setup.dart';
import 'package:rune_duel/battle/networking/match_discovery.dart'
    show DeviceCapabilities, kBattleProtocolVersion;
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;
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
  }) async {
    final spell = SpellAsset(
      id: 'spell-$idSuffix',
      createdAt: DateTime.utc(2026, 8, 17),
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
      createdAt: DateTime.utc(2026, 8, 17),
      entries: [ChapterEntry(spellId: spell.id)],
      artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
    );
  }

  /// Runs the handshake far enough to answer `runDuelSetup`'s first two
  /// exchanges (matchId nonce, capabilities) as a peer whose build declares
  /// [engineVersion] — the "unpatched client" this gate exists to refuse.
  ///
  /// Optionally continues into step 3 as the host, pinning [configEngine] in
  /// the config it authors, so the config-pin gate can be driven separately
  /// from the capabilities gate.
  Future<String> fakePeer(
    InMemoryTransport transport, {
    required int engineVersion,
    bool actAsHost = false,
    int? configEngine,
  }) async {
    final session = BattleSession(transport, Uint8List(16));
    await session.exchangeMatchIdNonce(Uint8List(16));
    await session.exchangeCapabilities(
      DeviceCapabilities(ramTierCap: 24, battleEngineVersion: engineVersion),
    );
    if (actAsHost) {
      // Deliberately NOT sendHostMatchConfig: that awaits an ack the real side
      // will never send once it aborts. Just put the config on the wire.
      session.send(
        BattleMsgType.matchConfig,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              MatchConfig(battleEngineVersion: configEngine!).toJson(),
            ),
          ),
        ),
      );
    }
    // The forfeit reason the real side sends before it throws — the wire-level
    // evidence of WHICH gate refused.
    return session.peerForfeit;
  }

  test('peers on the same battle engine version complete the handshake and '
      'pin that version into the match config', () async {
    final hostIdentity = await Identity.ephemeral();
    final guestIdentity = await Identity.ephemeral();
    final hostChapter = await makeChapter(
      idSuffix: 'a1',
      ownerPubkeyHex: await hostIdentity.ownerPubkeyHex(),
    );
    final guestChapter = await makeChapter(
      idSuffix: 'b1',
      ownerPubkeyHex: await guestIdentity.ownerPubkeyHex(),
    );

    final (transportHost, transportGuest) = InMemoryTransport.pair();
    final results = await Future.wait([
      runDuelSetup(
        transport: transportHost,
        role: DuelRole.host,
        localIdentity: hostIdentity,
        localChapter: hostChapter,
        hostConfig: const MatchConfig(),
      ),
      runDuelSetup(
        transport: transportGuest,
        role: DuelRole.guest,
        localIdentity: guestIdentity,
        localChapter: guestChapter,
        hostConfig: const MatchConfig(),
      ),
    ]);

    // Both sides agree on the epoch, and it is the build's own constant —
    // not defaulted away, not inherited from the proof epoch.
    expect(results[0].effectiveConfig.battleEngineVersion, kBattleEngineVersion);
    expect(results[1].effectiveConfig.battleEngineVersion, kBattleEngineVersion);
    expect(
      results[0].state.toCanonicalBytes(),
      equals(results[1].state.toCanonicalBytes()),
    );

    await transportHost.disconnect();
    await transportGuest.disconnect();
  });

  test('a peer declaring a different battle engine version is refused before '
      'any state exists', () async {
    final localIdentity = await Identity.ephemeral();
    final chapter = await makeChapter(
      idSuffix: 'a2',
      ownerPubkeyHex: await localIdentity.ownerPubkeyHex(),
    );

    final (transportLocal, transportPeer) = InMemoryTransport.pair();
    // Order matters: runDuelSetup subscribes its frame reader synchronously
    // and only then yields, so the fake peer must be started AFTER it or
    // InMemoryTransport's broadcast stream drops the first nonce frame and
    // both sides wait forever (the same trap duel_setup.dart's leading yield
    // documents).
    final local = runDuelSetup(
      transport: transportLocal,
      role: DuelRole.host,
      localIdentity: localIdentity,
      localChapter: chapter,
      hostConfig: const MatchConfig(),
    );
    final forfeitReason = fakePeer(
      transportPeer,
      engineVersion: kBattleEngineVersion + 1,
    );

    await expectLater(
      local,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('battle engine version mismatch'),
            contains('local=$kBattleEngineVersion'),
            contains('peer=${kBattleEngineVersion + 1}'),
            // Distinguishable from the proof epoch's failure, which is a
            // per-cast forfeit reading "ruleset_version" — see
            // ruleset_version_bind_test.dart.
            isNot(contains('ruleset')),
          ),
        ),
      ),
    );
    expect(await forfeitReason, 'battle_engine_mismatch');

    await transportLocal.disconnect();
    await transportPeer.disconnect();
  });

  test('a peer that predates the field declares nothing and is refused', () async {
    final localIdentity = await Identity.ephemeral();
    final chapter = await makeChapter(
      idSuffix: 'a3',
      ownerPubkeyHex: await localIdentity.ownerPubkeyHex(),
    );

    final (transportLocal, transportPeer) = InMemoryTransport.pair();
    // An unpatched build omits the key entirely; fromJson must read that as
    // "undeclared", never as agreement with whatever we happen to run.
    expect(
      DeviceCapabilities.fromJson(const {
        'ramTierCap': 24,
        'battleProtocolVersion': kBattleProtocolVersion,
      }).battleEngineVersion,
      kUndeclaredBattleEngineVersion,
    );
    final local = runDuelSetup(
      transport: transportLocal,
      role: DuelRole.guest,
      localIdentity: localIdentity,
      localChapter: chapter,
      hostConfig: const MatchConfig(),
    );
    final forfeitReason = fakePeer(
      transportPeer,
      engineVersion: kUndeclaredBattleEngineVersion,
    );

    await expectLater(
      local,
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('battle engine version mismatch'),
      )),
    );
    expect(await forfeitReason, 'battle_engine_mismatch');

    await transportLocal.disconnect();
    await transportPeer.disconnect();
  });

  test('a host config pinning an engine version this build does not implement '
      'is refused by the guest', () async {
    final localIdentity = await Identity.ephemeral();
    final chapter = await makeChapter(
      idSuffix: 'a4',
      ownerPubkeyHex: await localIdentity.ownerPubkeyHex(),
    );

    final (transportLocal, transportPeer) = InMemoryTransport.pair();
    // Capabilities agree — this peer's *build* is fine — but the config it
    // authors pins semantics we do not implement. The guest adopts host
    // configs wholesale (DECISION 3), so this is the one thing the
    // capabilities gate structurally cannot catch.
    final local = runDuelSetup(
      transport: transportLocal,
      role: DuelRole.guest,
      localIdentity: localIdentity,
      localChapter: chapter,
      hostConfig: const MatchConfig(),
    );
    final forfeitReason = fakePeer(
      transportPeer,
      engineVersion: kBattleEngineVersion,
      actAsHost: true,
      configEngine: kBattleEngineVersion + 7,
    );

    await expectLater(
      local,
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('match config pins battle engine version'),
          contains('${kBattleEngineVersion + 7}'),
          contains('this build implements $kBattleEngineVersion'),
        ),
      )),
    );
    expect(await forfeitReason, 'battle_engine_mismatch');

    await transportLocal.disconnect();
    await transportPeer.disconnect();
  });

  // The Mutable Leylines Summon-and-Armor-rekeying epoch. Pinned as a literal
  // pair rather than as `kBattleEngineVersion - 1` so a future bump has to come
  // back here and say what it broke, instead of silently re-pointing this at
  // the new neighbour. (The previous occupants of this group were v13 <-> v14,
  // the partial-formula affinity correction, and v12 <-> v13, a Mutable Leyline
  // reinterpreting incantation formulas at all.)
  //
  // This bump is a good illustration of why the gate is separate from the other
  // two: the wire is identical, and the proofs and the VK are untouched. What
  // changes is what a build DOES with a mutable config. A v14 build reads a
  // creature's abilities and an armor's keywords off the FIXED four-element
  // pattern tables; a v15 build reads them off dictionaries derived from the
  // leyline's tradition (audit R-8). One summon whose certified sequence
  // contains a keyed window is enough to diverge — the minion ability mask and
  // the avatar's armor are both hashed into the canonical state.
  //
  // Ordinary play is bit-identical across the bump — an ordinary lexicon
  // derives nothing and reads the same fixed tables — which is exactly why the
  // refusal cannot be conditional on the leyline: the handshake settles the
  // config, and by the time a mutable one is agreed there is no safe way to
  // discover the peer reads its patterns differently.
  group('v14 <-> v15 (Summon and Armor rekeying)', () {
    test('this build declares engine v15', () {
      expect(kBattleEngineVersion, 15,
          reason: 'a Mutable Leyline now rekeys which four-element pattern '
              'names which SummonAbility and which four-element run names '
              'which ArmorKeyword, so two builds handed one mutable config '
              'summon different creatures from one certified trajectory. '
              'docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E '
              '(Summon and Armor rekeying), R-8');
      expect(kBattleProtocolVersion, 7,
          reason: 'no framing changed — the new state is derived on both '
              'devices from values they already exchange');
      expect(kRulesetVersion, 3,
          reason: 'no proof semantics changed — the circuit is untouched');
    });

    test('a v14 peer is refused by the capabilities gate', () async {
      // The previous epoch is now the incompatible one: a v14 build reads the
      // fixed summon/armor pattern tables, so handed a mutable config it grants
      // a creature different abilities and an armor different keywords from the
      // same certified bytes.
      final localIdentity = await Identity.ephemeral();
      final chapter = await makeChapter(
        idSuffix: 'a14',
        ownerPubkeyHex: await localIdentity.ownerPubkeyHex(),
      );

      final (transportLocal, transportPeer) = InMemoryTransport.pair();
      final local = runDuelSetup(
        transport: transportLocal,
        role: DuelRole.host,
        localIdentity: localIdentity,
        localChapter: chapter,
        hostConfig: const MatchConfig(),
      );
      final forfeitReason = fakePeer(transportPeer, engineVersion: 14);

      await expectLater(
        local,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('battle engine version mismatch'),
            contains('local=15'),
            contains('peer=14'),
          ),
        )),
      );

      expect(await forfeitReason, 'battle_engine_mismatch');

      await transportLocal.disconnect();
      await transportPeer.disconnect();
    });

    test('a host config pinned to v14 is refused as well', () async {
      const v14Config = MatchConfig(battleEngineVersion: 14);
      expect(const MatchConfig().matches(v14Config), isFalse);
      expect(v14Config.battleEngineVersion, isNot(kBattleEngineVersion));
    });
  });

  group('the engine epoch is independent of the proof epoch', () {
    test('they are separate fields with separate constants', () {
      const config = MatchConfig();
      expect(config.rulesetVersion, kRulesetVersion);
      expect(config.battleEngineVersion, kBattleEngineVersion);
      // The whole point: a battle-only change moves one and not the other, so
      // no spell needs re-proving and no VK is invalidated.
      expect(kRulesetVersion, 3, reason: 'the CA/proof epoch must not have '
          'been repurposed for battle-engine semantics');
    });

    test('config agreement rejects a mismatch in either one, separately', () {
      const ours = MatchConfig();
      expect(ours.matches(const MatchConfig()), isTrue);
      expect(
        ours.matches(const MatchConfig(rulesetVersion: kRulesetVersion + 1)),
        isFalse,
        reason: 'proof-epoch agreement must still work exactly as before',
      );
      expect(
        ours.matches(
          const MatchConfig(battleEngineVersion: kBattleEngineVersion + 1),
        ),
        isFalse,
      );
    });

    test('an engine bump does not touch the proof epoch a config carries', () {
      const bumped = MatchConfig(battleEngineVersion: kBattleEngineVersion + 1);
      expect(bumped.rulesetVersion, kRulesetVersion);
    });

    test('the pinned epoch survives a JSON round trip', () {
      const config = MatchConfig(battleEngineVersion: 4);
      expect(MatchConfig.fromJson(config.toJson()).battleEngineVersion, 4);
      // A config from a peer that predates the field reads as undeclared, not
      // as our own value — the same discipline as DeviceCapabilities.
      expect(
        MatchConfig.fromJson(const {'playerHp': 24}).battleEngineVersion,
        kUndeclaredBattleEngineVersion,
      );
      // ...while the proof epoch keeps its existing lenient default, which is
      // safe there because the VK enforces it per cast.
      expect(
        MatchConfig.fromJson(const {'playerHp': 24}).rulesetVersion,
        kRulesetVersion,
      );
    });
  });
}
