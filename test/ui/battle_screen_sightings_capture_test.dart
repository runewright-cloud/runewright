// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_screen_sightings_capture_test.dart — SIGHTINGS_PLAN.md §6.2.
// Exercises sightingsFromResolved (the pure derivation _recordSightings
// wraps for disk I/O) directly, plus a round trip through SightingAsset.record
// to confirm a repeat opponent cast upserts rather than duplicates.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/sighting_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/battle_screen.dart';

import '../spells/fake_path_provider.dart';

void main() {
  const localPlayerId = 'player_local';
  const opponentPlayerId = 'player_opponent';
  final opponentPubkeyHex = '0x${'ab' * 32}';

  SpellAsset spell({String commitmentHex = '', String name = 'Ember Wake'}) => SpellAsset(
        id: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        tier: 24,
        t: 3,
        ownerPubkeyHex: '',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: name,
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: const ['fire', 'fire', 'fire'],
      );

  ResolvedSpellEvent event({required String casterId, required SpellAsset spell}) =>
      ResolvedSpellEvent(
        spell: spell,
        casterId: casterId,
        targetHex: const HexCoord(0, 0),
        isSummon: false,
      );

  WizardAvatar avatar({
    required String playerId,
    required String ownerPubkeyHex,
  }) =>
      WizardAvatar(
        playerId: playerId,
        ownerPubkeyHex: ownerPubkeyHex,
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: const HexCoord(0, 0),
        teamId: playerId,
        baseSpellRange: 3,
      );

  test('excludes the local player\'s own cast', () {
    final avatars = [
      avatar(playerId: localPlayerId, ownerPubkeyHex: '0x${'11' * 32}'),
      avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex),
    ];
    final resolved = [
      event(casterId: localPlayerId, spell: spell(commitmentHex: '0x${'cd' * 32}')),
    ];

    final captures = sightingsFromResolved(resolved, localPlayerId, avatars, const {});
    expect(captures, isEmpty);
  });

  test('captures an opponent cast with the certified base mana cost', () {
    final avatars = [
      avatar(playerId: localPlayerId, ownerPubkeyHex: '0x${'11' * 32}'),
      avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex),
    ];
    final commitmentHex = '0x${'cd' * 32}';
    final resolved = [
      event(
        casterId: opponentPlayerId,
        spell: spell(commitmentHex: commitmentHex, name: 'Ember Wake'),
      ),
    ];

    final captures = sightingsFromResolved(
      resolved,
      localPlayerId,
      avatars,
      {commitmentHex: 42},
    );

    expect(captures, hasLength(1));
    final capture = captures.single;
    expect(capture.opponentPubkeyHex, equals(opponentPubkeyHex));
    expect(capture.commitmentHex, equals(commitmentHex));
    expect(capture.spellName, equals('Ember Wake'));
    expect(capture.formula, equals(['fire', 'fire', 'fire']));
    expect(capture.t, equals(3));
    expect(capture.tier, equals(24));
    expect(capture.manaCost, equals(42));
  });

  test('defaults manaCost to 0 when the commitment is missing from certifiedBaseManaCosts', () {
    final avatars = [avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex)];
    final commitmentHex = '0x${'cd' * 32}';
    final resolved = [event(casterId: opponentPlayerId, spell: spell(commitmentHex: commitmentHex))];

    final captures = sightingsFromResolved(resolved, localPlayerId, avatars, const {});
    expect(captures.single.manaCost, equals(0));
  });

  test('excludes a cast with no commitmentHex', () {
    final avatars = [avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex)];
    final resolved = [event(casterId: opponentPlayerId, spell: spell(commitmentHex: ''))];

    expect(sightingsFromResolved(resolved, localPlayerId, avatars, const {}), isEmpty);
  });

  test('excludes a cast whose caster avatar cannot be found', () {
    final avatars = [avatar(playerId: localPlayerId, ownerPubkeyHex: '0x${'11' * 32}')];
    final resolved = [
      event(casterId: 'someone_not_in_avatars', spell: spell(commitmentHex: '0x${'cd' * 32}')),
    ];

    expect(sightingsFromResolved(resolved, localPlayerId, avatars, const {}), isEmpty);
  });

  test('excludes a cast from the all-zero solo/practice sentinel pubkey', () {
    final avatars = [
      avatar(playerId: opponentPlayerId, ownerPubkeyHex: '0x${'0' * 64}'),
    ];
    final resolved = [
      event(casterId: opponentPlayerId, spell: spell(commitmentHex: '0x${'cd' * 32}')),
    ];

    expect(sightingsFromResolved(resolved, localPlayerId, avatars, const {}), isEmpty);
  });

  test('excludes a cast from an avatar with an empty ownerPubkeyHex', () {
    final avatars = [avatar(playerId: opponentPlayerId, ownerPubkeyHex: '')];
    final resolved = [
      event(casterId: opponentPlayerId, spell: spell(commitmentHex: '0x${'cd' * 32}')),
    ];

    expect(sightingsFromResolved(resolved, localPlayerId, avatars, const {}), isEmpty);
  });

  test('a mixed turn keeps only the opponent cast', () {
    final avatars = [
      avatar(playerId: localPlayerId, ownerPubkeyHex: '0x${'11' * 32}'),
      avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex),
    ];
    final opponentCommitment = '0x${'cd' * 32}';
    final resolved = [
      event(casterId: localPlayerId, spell: spell(commitmentHex: '0x${'ee' * 32}')),
      event(casterId: opponentPlayerId, spell: spell(commitmentHex: opponentCommitment)),
    ];

    final captures = sightingsFromResolved(resolved, localPlayerId, avatars, const {});
    expect(captures, hasLength(1));
    expect(captures.single.commitmentHex, equals(opponentCommitment));
  });

  group('persistence round trip via SightingAsset.record', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await installFakePathProvider();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('a repeat opponent cast upserts (timesSeen == 2, firstSeen unchanged)', () async {
      final avatars = [avatar(playerId: opponentPlayerId, ownerPubkeyHex: opponentPubkeyHex)];
      final commitmentHex = '0x${'cd' * 32}';
      final resolved = [
        event(casterId: opponentPlayerId, spell: spell(commitmentHex: commitmentHex)),
      ];

      Future<void> persistTurn() async {
        for (final capture
            in sightingsFromResolved(resolved, localPlayerId, avatars, {commitmentHex: 7})) {
          await SightingAsset.record(
            opponentPubkeyHex: capture.opponentPubkeyHex,
            commitmentHex: capture.commitmentHex,
            spellName: capture.spellName,
            formula: capture.formula,
            t: capture.t,
            tier: capture.tier,
            manaCost: capture.manaCost,
          );
        }
      }

      await persistTurn();
      final firstLoad = await SightingAsset.loadAll();
      expect(firstLoad, hasLength(1));
      expect(firstLoad.single.timesSeen, equals(1));
      final firstSeen = firstLoad.single.firstSeen;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await persistTurn();

      final all = await SightingAsset.loadAll();
      expect(all, hasLength(1), reason: 'repeat cast upserts, never duplicates');
      expect(all.single.timesSeen, equals(2));
      expect(all.single.firstSeen, equals(firstSeen));
    });
  });
}
