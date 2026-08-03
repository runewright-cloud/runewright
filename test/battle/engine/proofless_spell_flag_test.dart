// SPDX-License-Identifier: GPL-3.0-or-later
//
// proofless_spell_flag_test.dart — DEV FLAG (kAllowProoflessSpells,
// lib/dev_flags.dart). Delete this file when the flag goes.
//
// Two things have to hold for the flag to be usable at all:
//
//   1. off (the default, and the shipping behaviour): a peer cast with no
//      proof bytes forfeits the match.
//   2. on: the cast is accepted AND both devices stay in lockstep. That
//      second half is the whole risk — the caster's device deducts mana at
//      commit time, so an opponent that skips verification and returns early
//      would leave `avatar.mana` diverged and trip the state-hash check at
//      the end of the same turn. The bypass would then have swapped a clean
//      forfeit for the exact freeze it was meant to avoid.
//
// The flag is a compile-time const, so these tests drive TurnLoop's
// `allowProoflessSpells` parameter directly rather than the const itself —
// that parameter is what the const feeds, and it defaults to false.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

void main() {
  group('kAllowProoflessSpells', () {
    test('off: a proofless peer cast forfeits the match', () async {
      await expectLater(
        _runCast(allowProofless: false),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('no proof bytes'))),
      );
    });

    test('on: the cast is accepted and both devices agree on the mana ledger',
        () async {
      final r = await _runCast(allowProofless: true);

      expect(r.resolvedOnPeerDevice, equals(1),
          reason: 'the opponent should have resolved the test spell');
      expect(r.casterManaOnCasterDevice, equals(r.casterManaOnPeerDevice),
          reason: 'both devices must charge the caster the same amount — '
              'mana is in the canonical state hash');
      expect(r.casterManaOnCasterDevice, equals(_kStartMana),
          reason: 'an unverified cast is free on both devices — the wire '
              'action carries no geometry for the opponent to price from, so '
              'zero is the only figure the two can agree on');
      expect(r.canonicalMatches, isTrue,
          reason: 'accepting the cast must not desync the match');
    });

    test('on: a spell that DOES carry a proof is still fully verified',
        () async {
      // Proof bytes present but garbage — the flag must not widen into a
      // blanket "skip verification", only the empty-proof case.
      await expectLater(
        _runCast(allowProofless: true, proofBytes: Uint8List.fromList([1, 2, 3])),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('proof rejected'))),
      );
    });
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

const _kStartMana = 500;

typedef _Result = ({
  int casterManaOnCasterDevice,
  int casterManaOnPeerDevice,
  int resolvedOnPeerDevice,
  bool canonicalMatches,
});

/// player_a casts a Spell Test Lab-shaped spell (no proof bytes); player_b
/// passes. player_b is the verifying device — [allowProofless] is what it was
/// built with.
Future<_Result> _runCast({
  required bool allowProofless,
  Uint8List? proofBytes,
}) async {
  final state1 = _makeState();
  final state2 = _makeState();

  final pair = TurnSessionPair();
  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;
  final loop1 = TurnLoop(
    state: state1,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    allowProoflessSpells: allowProofless,
  );
  final loop2 = TurnLoop(
    state: state2,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    allowProoflessSpells: allowProofless,
  );

  final spell = _testLabSpell(proofBytes: proofBytes);
  loop1.localChapterCommitments = [spell.commitmentHex];

  await Future.wait([
    loop1.runTurn(TurnInput(
      action: SpellCastAction(spell: spell, targetHex: const HexCoord(1, 0)),
    )),
    loop2.runTurn(TurnInput(action: PassAction())),
  ], eagerError: true).timeout(const Duration(seconds: 20));

  int manaOf(BattleState s) =>
      s.avatars.firstWhere((av) => av.playerId == 'player_a').mana;


  return (
    casterManaOnCasterDevice: manaOf(state1),
    casterManaOnPeerDevice: manaOf(state2),
    resolvedOnPeerDevice: loop2.lastResolvedSpells.length,
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
  );
}

/// Shaped like what SpellTestLabScreen._persistTestSpell writes: a real
/// formula, a placeholder commitment, and no proof at all.
///
/// Geometry is deliberately NON-zero here, unlike the real Test Lab spells
/// (which write 0/0). A real test spell prices at zero on both devices by
/// accident; this fixture would price at 19 on the caster's device and 0 on
/// the opponent's if the bypass tried to charge, so it pins the free-on-both
/// rule rather than relying on the Test Lab's zeros.
SpellAsset _testLabSpell({Uint8List? proofBytes}) => SpellAsset(
      id: 'testlab_seed_fire_damage',
      createdAt: DateTime.utc(2026, 7, 29),
      tier: 24,
      t: 2,
      ownerPubkeyHex: '0x${'00' * 32}',
      manaCost: 0,
      segmentCount: 3,
      dotCount: 2,
      initialGrid: const [],
      proofBytes: proofBytes ?? Uint8List(0),
      name: '[TEST] Firey Blast',
      commitmentHex: '0x${'ab' * 32}',
      spellHashHex: '0x${'cd' * 32}',
      formula: const ['fire', 'fire', 'fire'],
    );

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

BattleState _makeState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: _kStartMana,
        maxMana: 999,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: _kStartMana,
        maxMana: 999,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
