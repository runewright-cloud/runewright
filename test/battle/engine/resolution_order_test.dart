// SPDX-License-Identifier: GPL-3.0-or-later
//
// resolution_order_test.dart — Phase 5 resolution ordering: Quick and
// Sluggish rank a cast only against the *other casts* that turn, so a
// modifier every caster shares (including the one-caster case) cancels out.
//
// Two independent TurnLoops run concurrently over a paired commit-reveal
// session, so each assertion also proves both clients agree on the order —
// resolution order is lockstep-visible state, not a local presentation
// detail.
//
// The observable is TurnLoop.lastResolvedSpells, which only carries *casts*.
// That means the lone-caster case ("sluggish, and nobody else cast") can't be
// pinned by a position assertion — with one entry there is no order to see,
// and nothing a Pass/Dash/Meditate does is order-sensitive, so the collapse
// makes no difference to canonical state today. What the two-caster cases
// below do pin is the rule that produces it: the modifier ranks a cast only
// against other casts, and cancels when they all share it.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

void main() {
  group('Phase 5 resolution order', () {
    test('a lone sluggish caster still resolves, in lockstep', () async {
      // The scenario from the bug report: sluggish, and the opponent didn't
      // cast. Nothing to rank against, so the cast is simply the whole
      // resolution order — and both clients agree on it.
      final r = await _runTurn(
        aStatus: StatusEffectId.sluggish,
        aCasts: true,
        bCasts: false,
      );
      expect(r.order, equals(['player_a']));
      expect(r.canonicalMatches, isTrue);
    });

    test('a sluggish caster still resolves after a normal caster', () async {
      final r = await _runTurn(
        aStatus: StatusEffectId.sluggish,
        aCasts: true,
        bCasts: true,
      );
      expect(r.order, equals(['player_b', 'player_a']));
      expect(r.canonicalMatches, isTrue);
    });

    test('two sluggish casters cancel out and fall back to T/hash order',
        () async {
      final r = await _runTurn(
        aStatus: StatusEffectId.sluggish,
        bStatus: StatusEffectId.sluggish,
        aCasts: true,
        bCasts: true,
        // player_a's spell has the lower T, so it leads on the fallback.
        aT: 1,
        bT: 5,
      );
      expect(r.order, equals(['player_a', 'player_b']));
      expect(r.canonicalMatches, isTrue);
    });

    test('a quick caster still resolves before a normal caster', () async {
      final r = await _runTurn(
        bStatus: StatusEffectId.quick,
        aCasts: true,
        bCasts: true,
        aT: 1,
        bT: 5,
      );
      expect(r.order, equals(['player_b', 'player_a']),
          reason: 'Quick beats the lower-T tiebreak.');
      expect(r.canonicalMatches, isTrue);
    });

    test('two quick casters cancel out and fall back to T/hash order',
        () async {
      final r = await _runTurn(
        aStatus: StatusEffectId.quick,
        bStatus: StatusEffectId.quick,
        aCasts: true,
        bCasts: true,
        aT: 5,
        bT: 1,
      );
      expect(r.order, equals(['player_b', 'player_a']),
          reason: 'both Quick — the lower-T spell leads on the fallback.');
      expect(r.canonicalMatches, isTrue);
    });
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

typedef _TurnResult = ({List<String> order, bool canonicalMatches});

/// Runs one turn on two paired loops and reports the caster order both
/// clients resolved, from the client that saw both casts.
Future<_TurnResult> _runTurn({
  String? aStatus,
  String? bStatus,
  required bool aCasts,
  required bool bCasts,
  int aT = 1,
  int bT = 1,
}) async {
  final state1 = _makeState();
  final state2 = _makeState();
  for (final s in [state1, state2]) {
    if (aStatus != null) {
      s.avatars
          .firstWhere((av) => av.playerId == 'player_a')
          .activeStatusEffects
          .add(StatusEffect(effectTypeId: aStatus, remainingTurns: 3));
    }
    if (bStatus != null) {
      s.avatars
          .firstWhere((av) => av.playerId == 'player_b')
          .activeStatusEffects
          .add(StatusEffect(effectTypeId: bStatus, remainingTurns: 3));
    }
  }

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

  final spellA = _whiffSpell(fill: 0xaa, t: aT);
  final spellB = _whiffSpell(fill: 0xbb, t: bT);
  if (aCasts) loop1.localChapterCommitments = [spellA.commitmentHex];
  if (bCasts) loop2.localChapterCommitments = [spellB.commitmentHex];

  TurnInput inputFor(bool casts, SpellAsset spell, HexCoord target) => casts
      ? TurnInput(action: SpellCastAction(spell: spell, targetHex: target))
      : TurnInput(action: PassAction());

  await Future.wait([
    loop1.runTurn(inputFor(aCasts, spellA, const HexCoord(1, 0))),
    loop2.runTurn(inputFor(bCasts, spellB, const HexCoord(0, 0))),
  ]).timeout(const Duration(seconds: 20));

  // Either client sees every resolved spell (both decode both actions), so
  // loop1's stream is the full picture; loop2's must agree with it.
  final order1 = loop1.lastResolvedSpells.map((e) => e.casterId).toList();
  final order2 = loop2.lastResolvedSpells.map((e) => e.casterId).toList();
  expect(order2, equals(order1),
      reason: 'the two clients disagreed on resolution order');

  return (
    order: order1,
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
  );
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A cast with no certified effect zones and no wire formula: it resolves
/// (so it appears in lastResolvedSpells with a caster and a position in the
/// order) without touching any state the two clients could disagree about
/// for reasons unrelated to ordering. Mirrors the "whiff" spell in
/// turn_loop_determinism_test.dart.
SpellAsset _whiffSpell({required int fill, required int t}) {
  final commitmentBytes = Uint8List.fromList(List.filled(32, fill));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  return SpellAsset(
    id: 'spell-$fill',
    createdAt: DateTime.utc(2026, 7, 29),
    tier: 24,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: 0,
    segmentCount: 0,
    dotCount: 0,
    initialGrid: const [],
    proofBytes: _syntheticProofFor(tier: 24, t: t, commitmentBytes: commitmentBytes),
    name: 'Whiff $fill',
    commitmentHex: commitmentHex,
    spellHashHex: '',
    formula: const [],
  );
}

/// `[4 BE bytes: field count N][N × 32-byte fields][proof body]` — the wire
/// shape ProofIntake parses. Copied from turn_loop_determinism_test.dart.
Uint8List _syntheticProofFor({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, count, Endian.big);
  data.setUint32(4 + 0 * 32 + 28, t, Endian.big); // field 0: T
  data.setUint32(4 + 2 * 32 + 28, 3, Endian.big); // field 2: ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes); // field 3
  return bytes;
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
        mana: 50,
        maxMana: 100,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        maxMana: 100,
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
