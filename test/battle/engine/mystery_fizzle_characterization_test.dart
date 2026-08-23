// SPDX-License-Identifier: GPL-3.0-or-later
//
// mystery_fizzle_characterization_test.dart — the immediate-Mystery
// mana-fizzle propagation gap.
//
// ## The rule these tests measure against
//
//   A committed cast whose price exceeds the caster's mana at canonical
//   Phase-5 settlement FIZZLES: the mana is refunded (never deducted), the
//   spell produces no effects, and the caster's chain regresses. The turn is
//   still spent. (docs/VOCAL_RECALL_PLAN.md §4 / §9.5; the flag is
//   SpellCastAction.fizzledForMana, set by TurnLoop._markFizzledForMana and
//   read at deterministic_resolution.dart's `enhancements.fizzle` gate.)
//
// ## What this file characterizes, and does NOT fix
//
// `TurnLoop._verifyMysteryAction` rebuilds an immediate (delay=0)
// MysterySpellCastAction as a fresh SpellCastAction, copying spell, target,
// isPotent, isVelocity and recall — but NOT `fizzledForMana`. Settlement runs
// BEFORE that conversion (`_settleCommittedCasts` at Phase 5 open, the
// conversion a few lines later), so the flag is set on an object that is then
// discarded, and the cast reaches resolution with fizzle == false.
//
// These tests pin the CURRENT behaviour, bug included, so the eventual repair
// has something to invert. Every expectation below marked BUG is what the code
// does today and what the fix must change; every other expectation is a
// control that must keep passing.
//
// Noted but untouched in docs/M4_findings.md's M4.10b section.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/pending_delayed_spell.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

/// base = 5×segmentCount + dotCount = 5×3 + 2 = 17, × 1.05^t (t=4) × 1.5^0
/// (one complete formula) = 20.66 → 21. `wireBaseManaCost` and
/// `PeerCastVerifier.certifiedBaseManaCost` run the same arithmetic over the
/// same inputs, so both devices reach 21 and nothing here is confounded.
const int _kBaseCost = 21;

/// Comfortably below [_kBaseCost]: every "unaffordable" case starts here, and
/// the shortfall is large enough that no modifier could close it.
const int _kPoorMana = 5;

void main() {
  group('immediate Mystery — the fizzle flag is lost in conversion', () {
    test('BUG: an unaffordable immediate Mystery cast resolves anyway',
        () async {
      final r = await _runPairedMysteryTurn(casterMana: _kPoorMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue,
          reason: 'both devices convert identically, so this is a rules bug, '
              'not a desync');

      // 1. Settlement DID decide the cast was unaffordable: the flag is set on
      //    the action object the caller still holds, and no mana was taken.
      expect(r.localActionFizzled, isTrue,
          reason: '_markFizzledForMana ran on the MysterySpellCastAction');
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'fizzle refunds — nothing was deducted');
      expect(r.b.casterMana, equals(_kPoorMana));

      // 2. ...and the cast resolved regardless. This is the bug.
      // 24 → 20: the fire formula's full damage, exactly as if the caster
      // had been able to pay for it.
      expect(r.a.opponentHp, equals(_kStartHp - 4),
          reason: 'BUG: a canonically fizzled cast dealt damage');
      expect(r.b.opponentHp, equals(r.a.opponentHp));

      // 3. Chain built instead of regressing — the second consequence of the
      //    lost flag, and the one that pays forward into later turns. The
      //    length is 2 (not 1) because _updateChainState advances once per
      //    committed fire element beyond the first, which is exactly what the
      //    affordable control below also produces.
      expect(r.a.casterChainLengths[SpellAffinity.fire], equals(2),
          reason: 'BUG: a fizzle must _regressChain, not build one');
      expect(r.b.casterChainLengths[SpellAffinity.fire], equals(2));
    });

    test('control: the same unaffordable spell cast NORMALLY does fizzle',
        () async {
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        useMystery: false,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana), reason: 'refunded');
      expect(r.a.opponentHp, equals(_kStartHp),
          reason: 'no effects: the flag survived to the resolution gate');
      expect(r.a.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0),
          reason: 'fizzle regresses the chain');
    });

    test('control: an AFFORDABLE immediate Mystery cast pays and resolves',
        () async {
      final r = await _runPairedMysteryTurn(casterMana: _kStartMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      expect(r.a.opponentHp, lessThan(_kStartHp));
      // Identical to the unaffordable case above — which is the point: today
      // the two are indistinguishable downstream of the conversion.
      expect(r.a.casterChainLengths[SpellAffinity.fire], equals(2));
    });

    test('BUG applies to a PEER-owned immediate Mystery cast too', () async {
      // player_b is now the caster, so device A sees the bug on its peer path
      // (_certifiedPeerCastSettlement → _markFizzledForMana on the decoded
      // MysterySpellCastAction) and device B on its local path. Same loss site
      // either way: the conversion runs on both actions.
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        casterIsB: true,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      // `caster` is player_b here; device A reached this verdict through
      // _certifiedPeerCastSettlement, device B through _localCastSettlement.
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'peer settlement refunded on the verifier\'s device');
      expect(r.b.casterMana, equals(_kPoorMana));
      expect(r.a.opponentHp, lessThan(_kStartHp),
          reason: 'BUG: the peer\'s fizzled Mystery cast dealt damage');
      expect(r.b.opponentHp, equals(r.a.opponentHp));
    });
  });

  group('delayed Mystery — the declaration turn', () {
    test('BUG: an unaffordable delayed Mystery declaration still queues',
        () async {
      // A non-immediate MysterySpellCastAction passes through
      // _verifyMysteryAction UNCHANGED, so the flag survives on the object —
      // but resolveActions' MysterySpellCastAction case never reads it. The
      // pending spell is queued, and a delayed fire is not charged again.
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        delay: 1,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana), reason: 'refunded');
      expect(r.a.pendingDelayedCount, equals(1),
          reason: 'BUG: a fizzled declaration was still queued');
      expect(r.b.pendingDelayedCount, equals(1));
      // The declaration itself never damages anyone — that is the mechanic,
      // not the fizzle.
      expect(r.a.opponentHp, equals(_kStartHp));
    });

    test('BUG: the fizzled declaration then FIRES on the delay turn', () async {
      // The follow-through. A delayed fire is never re-priced (settlement
      // happens on the declaration turn only), so a declaration that fizzled
      // for mana yields a fully-effective free cast one turn later.
      final r = await _runDelayedMysteryFire(casterMana: _kPoorMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.declarationFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'never charged, on either turn');
      expect(r.a.pendingDelayedCount, equals(0), reason: 'it fired');
      expect(r.a.opponentHp, lessThan(_kStartHp),
          reason: 'BUG: a fizzled declaration dealt full damage a turn later');
      expect(r.b.opponentHp, equals(r.a.opponentHp));
    });

    test('control: an affordable delayed declaration fires for the same damage',
        () async {
      final r = await _runDelayedMysteryFire(casterMana: _kStartMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.declarationFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      expect(r.a.pendingDelayedCount, equals(0));
      expect(r.a.opponentHp, lessThan(_kStartHp));
    });

    test('control: an affordable delayed Mystery declaration queues and pays',
        () async {
      final r = await _runPairedMysteryTurn(
        casterMana: _kStartMana,
        delay: 1,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      expect(r.a.pendingDelayedCount, equals(1));
    });
  });

  group('out-of-range: a non-mana fizzle path, for comparison', () {
    test('control: an out-of-range immediate Mystery cast IS suppressed',
        () async {
      // outOfRange is recomputed at the resolution gate from preMovRange, not
      // carried on the action — so it is immune to the conversion and shows
      // the gate itself works. Mana is still charged (the cast was affordable).
      final r = await _runPairedMysteryTurn(
        casterMana: _kStartMana,
        casterRange: 1,
        targetFar: true,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost),
          reason: 'an out-of-range cast is paid for, unlike a mana fizzle');
      expect(r.a.opponentHp, equals(_kStartHp));
      expect(r.a.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0));
    });
  });
}

// ── Fixture ──────────────────────────────────────────────────────────────────

const _kSegmentCount = 3;
const _kDotCount = 2;
const _kStartMana = 500;
const _kStartHp = 24;

const _kCasterHome = HexCoord(0, 0);
const _kOpponentHome = HexCoord(1, 0);

/// Three tiles from [_kCasterHome] — out of reach for a `baseSpellRange: 1`
/// caster, and empty, so nothing but the range check decides the outcome.
const _kFarTile = HexCoord(3, 0);

typedef _Side = ({
  int casterMana,
  int casterHp,
  int opponentMana,
  int opponentHp,
  Map<SpellAffinity, int> casterChainLengths,
  int pendingDelayedCount,
});

typedef _PairedResult = ({
  _Side a,
  _Side b,
  bool localActionFizzled,
  bool canonicalMatches,
  Object? error,
});

/// Runs ONE turn on two genuinely separate [TurnLoop]s wired by
/// [TurnSessionPair]. The caster casts (through Mystery unless [useMystery] is
/// false) at the opponent; the other player passes.
///
/// [_Side.caster*] always names the CASTER's avatar and [_Side.opponent*] the
/// target, regardless of [casterIsB], so every assertion above reads the same
/// way on both ownership arrangements.
Future<_PairedResult> _runPairedMysteryTurn({
  required int casterMana,
  bool useMystery = true,
  bool casterIsB = false,
  int delay = 0,
  int casterRange = 3,
  bool targetFar = false,
}) async {
  final casterId = casterIsB ? 'player_b' : 'player_a';
  final opponentId = casterIsB ? 'player_a' : 'player_b';
  final opponentHome = casterIsB ? _kCasterHome : _kOpponentHome;

  BattleState build() => _makeState(
        casterId: casterId,
        casterMana: casterMana,
        casterRange: casterRange,
      );

  final state1 = build();
  final state2 = build();

  final pair = TurnSessionPair();
  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  final loop1 = TurnLoop(
    state: state1,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    meleeTargetPicker: (_) async => null,
  );
  final loop2 = TurnLoop(
    state: state2,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    meleeTargetPicker: (_) async => null,
  );

  final spell = _fireSpell(id: 'mystery-ember', commitmentFill: 0xab);
  (casterIsB ? loop2 : loop1).localChapterCommitments = [spell.commitmentHex];

  final target = targetFar ? _kFarTile : opponentHome;

  // The action the CASTER declares. Held in a variable so the test can read
  // `fizzledForMana` back off it after the turn: settlement mutates this very
  // object, and the conversion then builds a different one.
  final TurnAction castAction;
  if (useMystery) {
    final nonce = Uint8List.fromList(List.filled(16, 0x77));
    final commitment = await PendingDelayedSpell.commitmentHash(
      target: target,
      delay: delay,
      nonce: nonce,
    );
    castAction = MysterySpellCastAction(
      spell: spell,
      mysteryCommitment: commitment,
      immediateTarget: delay == 0 ? target : null,
      immediateNonce: delay == 0 ? nonce : null,
    );
  } else {
    castAction = SpellCastAction(spell: spell, targetHex: target);
  }

  Object? error;
  try {
    await Future.wait([
      loop1.runTurn(TurnInput(
        action: casterIsB ? PassAction() : castAction,
      )),
      loop2.runTurn(TurnInput(
        action: casterIsB ? castAction : PassAction(),
      )),
    ], eagerError: false).timeout(const Duration(seconds: 20));
  } catch (e) {
    error = e;
  }

  _Side sideOf(BattleState s) {
    final caster = _av(s, casterId);
    final opponent = _av(s, opponentId);
    return (
      casterMana: caster.mana,
      casterHp: caster.hp,
      opponentMana: opponent.mana,
      opponentHp: opponent.hp,
      casterChainLengths: Map.of(caster.chainLengths),
      pendingDelayedCount: s.pendingDelayedSpells.length,
    );
  }

  return (
    a: sideOf(state1),
    b: sideOf(state2),
    localActionFizzled: switch (castAction) {
      SpellCastAction(:final fizzledForMana) => fizzledForMana,
      MysterySpellCastAction(:final fizzledForMana) => fizzledForMana,
      _ => false,
    },
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
    error: error,
  );
}

typedef _DelayedResult = ({
  _Side a,
  _Side b,
  bool declarationFizzled,
  bool canonicalMatches,
  Object? error,
});

/// Two turns: player_a declares a Mystery cast with delay 1, then reveals it.
/// player_b passes throughout. Same two-TurnLoop lockstep as above.
Future<_DelayedResult> _runDelayedMysteryFire({required int casterMana}) async {
  final state1 = _makeState(
    casterId: 'player_a',
    casterMana: casterMana,
    casterRange: 3,
  );
  final state2 = _makeState(
    casterId: 'player_a',
    casterMana: casterMana,
    casterRange: 3,
  );

  final pair = TurnSessionPair();
  Future<bool> alwaysOk(Uint8List vk, Uint8List proof) async => true;

  final loop1 = TurnLoop(
    state: state1,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    meleeTargetPicker: (_) async => null,
  );
  final loop2 = TurnLoop(
    state: state2,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
    meleeTargetPicker: (_) async => null,
  );

  final spell = _fireSpell(id: 'mystery-ember', commitmentFill: 0xab);
  loop1.localChapterCommitments = [spell.commitmentHex];

  const delay = 1;
  final nonce = Uint8List.fromList(List.filled(16, 0x77));
  final commitment = await PendingDelayedSpell.commitmentHash(
    target: _kOpponentHome,
    delay: delay,
    nonce: nonce,
  );
  final declaration = MysterySpellCastAction(
    spell: spell,
    mysteryCommitment: commitment,
  );

  Object? error;
  try {
    // Turn 1 — declare. Settlement runs here and here only.
    await Future.wait([
      loop1.runTurn(TurnInput(action: declaration)),
      loop2.runTurn(TurnInput(action: PassAction())),
    ], eagerError: false).timeout(const Duration(seconds: 20));

    final pendingId = state1.pendingDelayedSpells.singleOrNull?.id ?? '';
    pair.reset();

    // Turn 2 — the delay elapses and the spell fires. Nothing is priced.
    await Future.wait([
      loop1.runTurn(TurnInput(
        action: PassAction(),
        delayedSpellReveals: [
          DelayedSpellReveal(
            pendingSpellId: pendingId,
            targetTile: _kOpponentHome,
            delay: delay,
            nonce: nonce,
          ),
        ],
      )),
      loop2.runTurn(TurnInput(action: PassAction())),
    ], eagerError: false).timeout(const Duration(seconds: 20));
  } catch (e) {
    error = e;
  }

  _Side sideOf(BattleState s) {
    final caster = _av(s, 'player_a');
    final opponent = _av(s, 'player_b');
    return (
      casterMana: caster.mana,
      casterHp: caster.hp,
      opponentMana: opponent.mana,
      opponentHp: opponent.hp,
      casterChainLengths: Map.of(caster.chainLengths),
      pendingDelayedCount: s.pendingDelayedSpells.length,
    );
  }

  return (
    a: sideOf(state1),
    b: sideOf(state2),
    declarationFizzled: declaration.fizzledForMana,
    canonicalMatches:
        _bytesEqual(state1.toCanonicalBytes(), state2.toCanonicalBytes()),
    error: error,
  );
}

WizardAvatar _av(BattleState s, String id) =>
    s.avatars.firstWhere((a) => a.playerId == id);

/// Four supreme activations — `fire, fire, fire, earth`: one complete fire
/// formula (the damage) plus one earth residual. See [_kBaseCost].
///
/// **The earth generation is load-bearing, not decoration.** A Mystery cast is
/// itself a cast-time enhancement claim, and `PeerCastVerifier` requires each
/// claim to be backed by this spell's own certified supreme-dominance zone —
/// earth for Mystery (`TrajectoryParser.certifiedSupremeTags`). A pure-fire
/// grid makes the peer forfeit on `unbacked_enhancement_claim` before any of
/// this is reachable.
SpellAsset _fireSpell({required String id, required int commitmentFill}) {
  const activations = 4;
  const t = activations;
  final tier = tierForSteps(t)!;
  final commitmentBytes = Uint8List.fromList(List.filled(32, commitmentFill));
  final commitmentHex =
      '0x${commitmentBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  return SpellAsset(
    id: id,
    createdAt: DateTime.utc(2026, 8, 22),
    tier: tier,
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    manaCost: _kBaseCost,
    segmentCount: _kSegmentCount,
    dotCount: _kDotCount,
    initialGrid: const [],
    proofBytes:
        _syntheticProof(tier: tier, t: t, commitmentBytes: commitmentBytes),
    name: 'Mystery Ember',
    commitmentHex: commitmentHex,
    spellHashHex: '',
    formula: const ['fire', 'fire', 'fire', 'earth'],
  );
}

/// `[4 BE bytes: field count N][N × 32-byte fields][proof body]` — the wire
/// shape ProofIntake parses. Copied from
/// mana_charge_window_characterization_test.dart; see it for the field map.
Uint8List _syntheticProof({
  required int tier,
  required int t,
  required Uint8List commitmentBytes,
}) {
  final count = 10 + 2 * tier;
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);
  void setField(int i, int v) => data.setUint32(4 + i * 32 + 28, v, Endian.big);

  data.setUint32(0, count, Endian.big);
  setField(0, t);
  setField(2, 3); // ruleset_version
  bytes.setRange(4 + 3 * 32, 4 + 3 * 32 + 32, commitmentBytes);
  for (var gen = 0; gen < t; gen++) {
    // Rule indices (lib/engine/ca_run.dart): 1 = fire, 4 = earth. The last
    // generation is earth so the Mystery claim has a certified backing zone.
    setField(8 + gen, gen == t - 1 ? 4 : 1);
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

BattleState _makeState({
  required String casterId,
  required int casterMana,
  required int casterRange,
}) {
  final battlefield = Battlefield();
  battlefield.occupancy['player_a'] = _kCasterHome;
  battlefield.occupancy['player_b'] = _kOpponentHome;

  WizardAvatar avatar({
    required String id,
    required String pubkeyFill,
    required HexCoord position,
    required String teamId,
  }) =>
      WizardAvatar(
        playerId: id,
        ownerPubkeyHex: '0x${pubkeyFill * 32}',
        hp: _kStartHp,
        mana: id == casterId ? casterMana : _kStartMana,
        maxMana: 999,
        position: position,
        teamId: teamId,
        baseSpellRange: id == casterId ? casterRange : 3,
      );

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      avatar(
        id: 'player_a',
        pubkeyFill: '00',
        position: _kCasterHome,
        teamId: 'team_a',
      ),
      avatar(
        id: 'player_b',
        pubkeyFill: '11',
        position: _kOpponentHome,
        teamId: 'team_b',
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
