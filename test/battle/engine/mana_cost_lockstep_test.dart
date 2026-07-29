// SPDX-License-Identifier: GPL-3.0-or-later
//
// mana_cost_lockstep_test.dart — the caster's own mana deduction must equal
// the deduction the opponent's device computes from the SNARK-certified
// outputs, or canonical state diverges and _exchangeStateHash forfeits the
// match.
//
// The two paths are structurally different by design: the caster charges
// itself via _spellManaCost (starting from SpellAsset.manaCost, baked at
// inscribe time), the opponent charges the caster via _certifiedManaCost
// (recomputed from the proof's public outputs). They agreed only when a
// spell's activation count was an exact multiple of 3 — the two effectCount
// formulas differ on any residual:
//
//   inscribe/wire : max(0, (activations - 1) ~/ 3)
//   certified     : max(0, completeFormulas - 1)   [= activations ~/ 3 - 1]
//
// so 4 activations gave 1 vs 0, i.e. a 1.5x cost gap on the very same cast.

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
  group('mana cost lockstep', () {
    test('a residual-activation cast charges both devices the same', () async {
      // 4 supreme fire activations = 1 complete formula + 1 residual — the
      // smallest spell that trips the effectCount mismatch.
      final r = await _castAndCompare(activations: 4);
      expect(r.casterManaOnCasterDevice, equals(r.casterManaOnPeerDevice),
          reason: 'the caster charged itself '
              '${r.startMana - r.casterManaOnCasterDevice} mana; the opponent '
              'charged it ${r.startMana - r.casterManaOnPeerDevice}');
      expect(r.canonicalMatches, isTrue,
          reason: 'diverged canonical state — this is the "state hash '
              'mismatch on turn N" banner');
    });

    test('an exact-multiple-of-3 cast charges both devices the same', () async {
      // The case that always worked: 3 activations = 1 formula, no residual.
      final r = await _castAndCompare(activations: 3);
      expect(r.casterManaOnCasterDevice, equals(r.casterManaOnPeerDevice));
      expect(r.canonicalMatches, isTrue);
    });

    test('7 activations (2 formulas + 1 residual) also agree', () async {
      final r = await _castAndCompare(activations: 7);
      expect(r.casterManaOnCasterDevice, equals(r.casterManaOnPeerDevice));
      expect(r.canonicalMatches, isTrue);
    });
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

const _kSegmentCount = 3;
const _kDotCount = 2;
const _kStartMana = 500;

typedef _Result = ({
  int startMana,
  int casterManaOnCasterDevice,
  int casterManaOnPeerDevice,
  bool canonicalMatches,
});

/// player_a casts a spell certified to have [activations] fire activations;
/// player_b passes. Returns what each device thinks player_a's mana is.
Future<_Result> _castAndCompare({required int activations}) async {
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
  );
  final loop2 = TurnLoop(
    state: state2,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
  );

  final spell = _spellWith(activations: activations);
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
    startMana: _kStartMana,
    casterManaOnCasterDevice: manaOf(state1),
    casterManaOnPeerDevice: manaOf(state2),
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
  );
}

/// A spell whose certified trajectory is [activations] supreme fire
/// activations, with `formula` and `manaCost` filled in exactly the way
/// inscription does (main.dart's Inscribe handler) — that agreement is the
/// whole point of the test.
SpellAsset _spellWith({required int activations}) {
  const tier = 24;
  final t = activations;
  final commitmentBytes = Uint8List.fromList(List.filled(32, 0xab));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  // main.dart's inscribe handler: effectCount = max(0, formulas - 1), then
  // (5*seg + dot) * 1.05^steps * 1.5^effectCount, rounded.
  final effectCount = (activations ~/ 3 - 1).clamp(0, 1 << 30);
  var cost = (5 * _kSegmentCount + _kDotCount).toDouble();
  for (var i = 0; i < t; i++) {
    cost *= 1.05;
  }
  for (var i = 0; i < effectCount; i++) {
    cost *= 1.5;
  }

  return SpellAsset(
    id: 'residual-spell',
    createdAt: DateTime.utc(2026, 7, 29),
    tier: tier,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: cost.round(),
    segmentCount: _kSegmentCount,
    dotCount: _kDotCount,
    initialGrid: const [],
    proofBytes: _syntheticProof(
      tier: tier,
      t: t,
      commitmentBytes: commitmentBytes,
      activations: activations,
    ),
    name: 'Residual Ember',
    commitmentHex: commitmentHex,
    spellHashHex: '',
    // FormulaTracker.committed for N supreme fire activations — the same flat
    // sequence TrajectoryParser.certifiedElementSequence replays.
    formula: List.filled(activations, 'fire'),
  );
}

/// `[4 BE bytes: field count N][N × 32-byte fields][proof body]`, the wire
/// shape ProofIntake parses. Field map (proof_intake.dart): 0=T, 1=owner,
/// 2=ruleset, 3=commitment, 4..7=border, 8..8+tier-1=dominance trajectory,
/// 8+tier..=supreme flags, then segmentCount, dotCount.
Uint8List _syntheticProof({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
  required int activations,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);
  void setField(int i, int v) => data.setUint32(4 + i * 32 + 28, v, Endian.big);

  data.setUint32(0, count, Endian.big);
  setField(0, t);
  setField(2, 3); // ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes);
  for (var gen = 0; gen < activations; gen++) {
    setField(8 + gen, 1); // fire dominance
    setField(8 + tier + gen, 1); // supreme → one activation per generation
  }
  setField(8 + 2 * tier, _kSegmentCount);
  setField(8 + 2 * tier + 1, _kDotCount);
  return bytes;
}

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
