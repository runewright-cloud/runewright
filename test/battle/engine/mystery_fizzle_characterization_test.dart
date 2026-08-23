// SPDX-License-Identifier: GPL-3.0-or-later
//
// mystery_fizzle_characterization_test.dart — M4.21: Mystery is not an
// affordability exception.
//
// ## The rule this file enforces
//
//   Once canonical Phase-5 settlement marks a committed cast fizzledForMana,
//   the cast is SPENT and produces no spell consequence. The mana is refunded
//   (never deducted), no effect resolves, the chain regresses, and — for a
//   Mystery declaration — nothing is placed on the battlefield. Later Mystery
//   conversion or delayed-declaration handling must not resurrect it.
//   (docs/VOCAL_RECALL_PLAN.md §4 / §9.5.)
//
// ## What changed in this file, and what did not
//
// These are the SAME nine fixtures that reproduced the bug (commit 577828c,
// and the M4.21 section of docs/M4_findings.md). The five controls are
// untouched — they passed before the fix and pass after, which is what makes
// them controls. The four BUG cases had their expectations INVERTED, from
// "the flag was set and the cast resolved anyway" to "the flag was set and
// nothing happened":
//
//   | case                                 | pre-fix                  | now        |
//   |--------------------------------------|--------------------------|------------|
//   | unaffordable immediate Mystery       | 4 damage, chain 2        | no effect  |
//   | ...peer-owned                        | 4 damage                 | no effect  |
//   | unaffordable delayed declaration     | queued a PendingDelayed  | nothing    |
//   | ...and fired next turn               | 4 damage, unpaid         | never fires|
//
// One test is new: `parity` below casts the same unaffordable spell twice,
// once ordinarily and once through Mystery, and asserts the two produce
// byte-identical canonical state. That is the invariant in its shortest form —
// routing a cast through Mystery changes nothing about what a shortfall costs.
//
// ## The two repairs it covers
//
//   A. TurnLoop._verifyMysteryAction now CARRIES fizzledForMana through the
//      immediate-cast rebuild instead of dropping it. Carried, never
//      recomputed: there is one canonical affordability verdict and it was
//      made at Phase 5.
//   B. DeterministicResolution.resolveActions' non-immediate Mystery branch
//      now reads the flag and declines to queue a PendingDelayedSpell,
//      regressing the chain the same way every other mana fizzle does. There
//      is deliberately NO second affordability check at delayed-fire time.
//
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
  group('immediate Mystery — the fizzle flag survives conversion', () {
    test('an unaffordable immediate Mystery cast produces no consequence',
        () async {
      final r = await _runPairedMysteryTurn(casterMana: _kPoorMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);

      // 1. Settlement decided the cast was unaffordable: the flag is set on
      //    the action object the caller still holds, and no mana was taken.
      expect(r.localActionFizzled, isTrue,
          reason: '_markFizzledForMana ran on the MysterySpellCastAction');
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'fizzle refunds — nothing was deducted');
      expect(r.b.casterMana, equals(_kPoorMana));

      // 2. No HP was paid either. A shortfall converts to HP only under
      //    nextSpellCostDouble, which is not in play here; the plain fizzle
      //    rule costs nothing but the turn.
      expect(r.a.casterHp, equals(_kStartHp));

      // 3. ...and the cast produced nothing. This is the M4.21 fix: the flag
      //    now rides the rebuilt SpellCastAction into the `enhancements.fizzle`
      //    gate, which suppresses the whole resolution.
      expect(r.a.opponentHp, equals(_kStartHp),
          reason: 'a canonically fizzled cast deals no damage');
      expect(r.b.opponentHp, equals(_kStartHp));

      // 4. Chain regressed rather than building — the second consequence of
      //    the flag, and the one that pays forward into later turns.
      expect(r.a.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0),
          reason: 'a fizzle regresses the chain');
      expect(r.b.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0));
    });

    test('control: the same unaffordable spell cast NORMALLY still fizzles',
        () async {
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        useMystery: false,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana), reason: 'refunded');
      expect(r.a.casterHp, equals(_kStartHp));
      expect(r.a.opponentHp, equals(_kStartHp));
      expect(r.a.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0));
    });

    test('parity: ordinary and Mystery shortfalls now cost exactly the same',
        () async {
      // The invariant in its shortest form. Two runs of the same unaffordable
      // spell, one ordinary and one routed through Mystery, compared as whole
      // canonical states rather than field by field — so a consequence nobody
      // thought to assert cannot diverge unnoticed. Pre-fix these differed in
      // HP, chain and (for the delayed variant) pendingDelayedSpells.
      final ordinary = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        useMystery: false,
      );
      final mystery = await _runPairedMysteryTurn(casterMana: _kPoorMana);

      expect(ordinary.error, isNull);
      expect(mystery.error, isNull);
      expect(ordinary.localActionFizzled, isTrue);
      expect(mystery.localActionFizzled, isTrue);
      expect(mystery.a.casterMana, equals(ordinary.a.casterMana));
      expect(mystery.a.casterHp, equals(ordinary.a.casterHp));
      expect(mystery.a.opponentHp, equals(ordinary.a.opponentHp));
      expect(mystery.a.casterChainLengths, equals(ordinary.a.casterChainLengths));
      expect(mystery.a.pendingDelayedCount,
          equals(ordinary.a.pendingDelayedCount));
    });

    test('control: an AFFORDABLE immediate Mystery cast pays and resolves',
        () async {
      final r = await _runPairedMysteryTurn(casterMana: _kStartMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
      // 24 → 20: the fire formula's full damage. Unchanged by M4.21 — the fix
      // must be invisible to a caster who can pay.
      expect(r.a.opponentHp, equals(_kStartHp - 4));
      expect(r.a.casterChainLengths[SpellAffinity.fire], equals(2));
      expect(r.b.casterChainLengths[SpellAffinity.fire], equals(2));
    });

    test('a PEER-owned unaffordable immediate Mystery is suppressed too',
        () async {
      // player_b is the caster, so device A reaches the verdict through
      // _certifiedPeerCastSettlement and device B through
      // _localCastSettlement. The conversion runs on both actions, so the
      // repair has to hold on both — this is the ownership half of the test.
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        casterIsB: true,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      // `caster` is player_b here.
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'peer settlement refunded on the verifier\'s device');
      expect(r.b.casterMana, equals(_kPoorMana));
      expect(r.a.opponentHp, equals(_kStartHp),
          reason: 'the peer\'s fizzled Mystery cast deals no damage');
      expect(r.b.opponentHp, equals(_kStartHp));
    });
  });

  group('delayed Mystery — a fizzled declaration never enters pending state',
      () {
    test('an unaffordable delayed Mystery declaration queues nothing',
        () async {
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        delay: 1,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana), reason: 'refunded');
      expect(r.a.pendingDelayedCount, equals(0),
          reason: 'a fizzled declaration is not placed on the battlefield');
      expect(r.b.pendingDelayedCount, equals(0));
      expect(r.a.opponentHp, equals(_kStartHp));
      // Spent like any other mana fizzle: the chain regresses. Deliberately
      // the ordinary _regressChain, not a Mystery-specific rule.
      expect(r.a.casterChainLengths[SpellAffinity.fire] ?? 0, equals(0));
    });

    test('and therefore no delayed fire happens on the following turn',
        () async {
      // The follow-through, and the reason the declaration-side repair had to
      // exist at all: a delayed fire is never re-priced, so anything that
      // reaches the pending list fires for free. Nothing reaches it.
      final r = await _runDelayedMysteryFire(casterMana: _kPoorMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.declarationFizzled, isTrue);
      expect(r.a.casterMana, equals(_kPoorMana),
          reason: 'never charged, on either turn');
      expect(r.a.pendingDelayedCount, equals(0),
          reason: 'nothing was ever queued, so nothing was left to fire');
      expect(r.a.opponentHp, equals(_kStartHp),
          reason: 'no damage a turn later either');
      expect(r.b.opponentHp, equals(_kStartHp));
    });

    test('control: an affordable delayed declaration still fires normally',
        () async {
      final r = await _runDelayedMysteryFire(casterMana: _kStartMana);

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.declarationFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost),
          reason: 'charged once, at declaration — never re-priced at fire');
      expect(r.a.pendingDelayedCount, equals(0), reason: 'it fired');
      expect(r.a.opponentHp, equals(_kStartHp - 4));
      expect(r.b.opponentHp, equals(_kStartHp - 4));
    });

    test('the skipped declaration does not swallow the other player\'s action',
        () async {
      // Repair B skips the rest of its `case` with a bare `break`. In Dart that
      // targets the switch, not the `for (final (actor, action) in sorted)`
      // around it — but "the language says so" is a weaker guarantee than a
      // fixture, and getting it wrong would silently drop every action sorted
      // after the fizzled one. So: player_a's declaration fizzles while
      // player_b casts for real, and player_b's spell must still land.
      final r = await _runPairedMysteryTurn(
        casterMana: _kPoorMana,
        delay: 1,
        opponentAlsoCasts: true,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isTrue);
      expect(r.a.pendingDelayedCount, equals(0), reason: 'nothing queued');
      expect(r.a.casterHp, equals(_kStartHp - 4),
          reason: 'the OTHER action still resolved — the break broke the '
              'switch, not the loop');
      expect(r.b.casterHp, equals(r.a.casterHp));
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
      expect(r.b.pendingDelayedCount, equals(1));
    });
  });

  group('out-of-range: a non-mana fizzle path, unchanged by M4.21', () {
    test('control: an out-of-range immediate Mystery cast IS suppressed',
        () async {
      // outOfRange is recomputed at the resolution gate from preMovRange, not
      // carried on the action — so it was never exposed to the conversion and
      // is not what M4.21 touched. Mana is still charged: an out-of-range cast
      // is paid for, unlike a mana fizzle.
      final r = await _runPairedMysteryTurn(
        casterMana: _kStartMana,
        casterRange: 1,
        targetFar: true,
      );

      expect(r.error, isNull);
      expect(r.canonicalMatches, isTrue);
      expect(r.localActionFizzled, isFalse);
      expect(r.a.casterMana, equals(_kStartMana - _kBaseCost));
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
  bool opponentAlsoCasts = false,
}) async {
  final casterId = casterIsB ? 'player_b' : 'player_a';
  final opponentId = casterIsB ? 'player_a' : 'player_b';
  final opponentHome = casterIsB ? _kCasterHome : _kOpponentHome;
  final casterHome = casterIsB ? _kOpponentHome : _kCasterHome;

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

  // A DISTINCT commitment: certifiedPeerCasts is keyed by commitmentHex and the
  // commitment is grid-only, so two casts of the same grid in one turn collide.
  final replySpell = _fireSpell(id: 'reply-ember', commitmentFill: 0xcd);
  if (opponentAlsoCasts) {
    (casterIsB ? loop1 : loop2).localChapterCommitments = [
      replySpell.commitmentHex,
    ];
  }

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
    final TurnAction otherAction = opponentAlsoCasts
        ? SpellCastAction(spell: replySpell, targetHex: casterHome)
        : PassAction();
    await Future.wait([
      loop1.runTurn(TurnInput(
        action: casterIsB ? otherAction : castAction,
      )),
      loop2.runTurn(TurnInput(
        action: casterIsB ? castAction : otherAction,
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
