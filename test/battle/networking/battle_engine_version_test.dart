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

  // The solo/practice armor-seating epoch. Pinned as a literal pair rather
  // than as `kBattleEngineVersion - 1` so a future bump has to come back here
  // and say what it broke, instead of silently re-pointing this at the new
  // neighbour. (The previous occupants of this group were v14 <-> v15, the
  // Mutable Leylines Summon-and-Armor rekeying, and v13 <-> v14, the
  // partial-formula affinity correction.)
  //
  // This bump is an unusual one for the gate, and the reasoning is worth
  // keeping. Nothing a DUEL computes moves at all: `buildDuelBattleState`, the
  // armor envelope and peer verification are untouched, so a v15 and a v16
  // build would in fact agree on every networked match. What moved is
  // `buildSoloBattleState`, which never received the chapter's certified armor
  // and so built its wizard with `armor` null — no melee bonus, no Earth HP, no
  // move or range term, no Charger or Muddy. A v16 build seats it.
  //
  // It is still an engine bump, because this file gates the rules that turn
  // match inputs into a canonical `BattleState`, not merely the ones two
  // devices compare. Handed the same chapter and config, v15 and v16 compute
  // different practice states — different opening HP, and armor is itself
  // hashed per avatar (v6) — so they are different engines whether or not a
  // peer is watching, and a solo replay golden must be able to say which one
  // produced it.
  //
  // A chapter with no equipped armor is bit-identical across the bump: the
  // seat is null on both sides of it. See docs/AETHERIAL_ARMOR.md §14.
  group('v15 <-> v16 (solo/practice armor seating)', () {
    test('this build declares engine v16', () {
      expect(kBattleEngineVersion, 16,
          reason: 'solo/practice construction now seats and applies the '
              'chapter\'s certified Aetherial Armor, so a v15 and a v16 build '
              'compute different practice states — opening HP and the hashed '
              'armor record — from one chapter. docs/AETHERIAL_ARMOR.md §14');
      expect(kBattleProtocolVersion, 7,
          reason: 'no framing changed — there is no peer on this path at all');
      expect(kRulesetVersion, 3,
          reason: 'no proof semantics changed — the circuit is untouched');
    });

    test('a v15 peer is refused by the capabilities gate', () async {
      // The previous epoch is now the incompatible one. A v15 build agrees
      // with v16 about every duel, but the gate is a build-identity check, not
      // a per-match diff: it refuses on the declared epoch rather than trying
      // to prove which subset of the engine a given match would exercise.
      final localIdentity = await Identity.ephemeral();
      final chapter = await makeChapter(
        idSuffix: 'a15',
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
      final forfeitReason = fakePeer(transportPeer, engineVersion: 15);

      await expectLater(
        local,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('battle engine version mismatch'),
            contains('local=16'),
            contains('peer=15'),
          ),
        )),
      );

      expect(await forfeitReason, 'battle_engine_mismatch');

      await transportLocal.disconnect();
      await transportPeer.disconnect();
    });

    test('a host config pinned to v15 is refused as well', () async {
      const v15Config = MatchConfig(battleEngineVersion: 15);
      expect(const MatchConfig().matches(v15Config), isFalse);
      expect(v15Config.battleEngineVersion, isNot(kBattleEngineVersion));
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
