// SPDX-License-Identifier: GPL-3.0-or-later
//
// artifact_activation_test.dart — Phase 0 artifact activation
// (docs/ARTIFACT_SYSTEM_PLAN.md).
//
// Every test here drives TWO real TurnLoops over a TurnSessionPair, with
// swapped local/peer perspectives, rather than one loop against
// SoloBattleSession. That is deliberate: the whole feature is a new network
// round trip whose declarations must be applied identically on both devices,
// and SoloBattleSession hides divergence by echoing state hashes back.
// Asserting `state1.toCanonicalBytes() == state2.toCanonicalBytes()` after
// each turn is the real test; the per-artifact expectations are the
// readable half.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'turn_session_pair.dart';

void main() {
  group('Phase 0 declaration round trip', () {
    test('both sides settle on the same declarations from either perspective',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      final loopA = _loop(state1, pair.sessionA, 'player_a',
          pick: (_) async => AccoutrementKind.rodOfSpreading);
      final loopB = _loop(state2, pair.sessionB, 'player_b',
          pick: (_) async => AccoutrementKind.bookmark);

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()),
          reason: 'a turn where both players declared activations diverged');

      // Each loop saw its own choice as `local` and the other's as `peer`.
      expect(loopA.lastArtifactActivations.local,
          equals(AccoutrementKind.rodOfSpreading));
      expect(loopA.lastArtifactActivations.peer,
          equals(AccoutrementKind.bookmark));
      expect(loopB.lastArtifactActivations.local,
          equals(AccoutrementKind.bookmark));
      expect(loopB.lastArtifactActivations.peer,
          equals(AccoutrementKind.rodOfSpreading));
    });

    test('declaring nothing is the default and leaves every avatar unflagged',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      // No pickers wired at all — the default declines, which is what every
      // pre-existing test and solo mode relies on.
      final loopA = _loop(state1, pair.sessionA, 'player_a');
      final loopB = _loop(state2, pair.sessionB, 'player_b');

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastArtifactActivations.isEmpty, isTrue);
      expect(loopB.lastArtifactActivations.isEmpty, isTrue);
      for (final av in state1.avatars) {
        expect(av.declaredActivation, isNull);
      }
    });

    test('the picker is offered only the kinds the local wizard actually holds',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      List<AccoutrementKind>? offeredToA;
      List<AccoutrementKind>? offeredToB;

      // player_a holds gems + charms + a rod; player_b holds bookmarks only.
      final loopA = _loop(state1, pair.sessionA, 'player_a', pick: (avail) async {
        offeredToA = avail;
        return null;
      });
      final loopB = _loop(state2, pair.sessionB, 'player_b', pick: (avail) async {
        offeredToB = avail;
        return null;
      });

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      // Counter charms are never offered — they have no voluntary activation.
      expect(offeredToA,
          equals([AccoutrementKind.manaGem, AccoutrementKind.rodOfSpreading]));
      expect(offeredToB, equals([AccoutrementKind.bookmark]));
    });

    test('declarations are turn-scoped: cleared before the next turn opens',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      var turn = 0;
      final loopA = _loop(state1, pair.sessionA, 'player_a',
          pick: (_) async =>
              turn == 1 ? AccoutrementKind.rodOfSpreading : null);
      final loopB = _loop(state2, pair.sessionB, 'player_b');

      turn = 1;
      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);
      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));

      pair.reset();
      turn = 2;
      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastArtifactActivations.local, isNull,
          reason: 'turn 1s declaration must not survive into turn 2');
      for (final av in state1.avatars) {
        expect(av.declaredActivation, isNull);
      }
    });
  });

  // ── Trust boundary (§5) ─────────────────────────────────────────────────
  //
  // A lying peer here is a peer whose client declares something it isn't
  // entitled to. It commits and reveals honestly (the commit-reveal check
  // can't catch this — the liar is consistent with itself), so the ONLY thing
  // standing between it and a free artifact is TurnLoop._validateActivation.
  // Every case must degrade to no-activation, with both devices agreeing.

  group('Phase 0 trust boundary', () {
    test('a declared kind the wizard holds none of is discarded', () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      // player_b holds bookmarks only, but claims a mana gem.
      final loopA = _loop(state1, pair.sessionA, 'player_a');
      final loopB = _loop(state2, pair.sessionB, 'player_b',
          pick: (_) async => AccoutrementKind.manaGem);

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastArtifactActivations.peer, isNull,
          reason: 'the forged gem claim must read as no-activation');
      expect(loopB.lastArtifactActivations.local, isNull);
      // And nothing was consumed.
      expect(_avatar(state1, 'player_b').bookmarkCount, equals(2));
    });

    test('a declared counterCharm is discarded even when charms are held',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      // player_a really does hold counter charms — they are still never a
      // legal declaration, because charms have no voluntary activation and
      // letting one be "spent" would hand the mage slayer a free way to open
      // its own guard.
      final loopA = _loop(state1, pair.sessionA, 'player_a',
          pick: (_) async => AccoutrementKind.counterCharm);
      final loopB = _loop(state2, pair.sessionB, 'player_b');

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastArtifactActivations.local, isNull);
      expect(loopB.lastArtifactActivations.peer, isNull);
      expect(_avatar(state1, 'player_a').activeCounterCharmCount, equals(3));
    });

    test('a summon-only kind (absorption rod) is never a legal declaration',
        () async {
      final state1 = _makeState();
      final state2 = _makeState();
      for (final s in [state1, state2]) {
        _avatar(s, 'player_a').accoutrements.add(const Accoutrement(
            id: 'a_absorb_1', kind: AccoutrementKind.absorptionRod));
      }
      final pair = TurnSessionPair();

      final loopA = _loop(state1, pair.sessionA, 'player_a',
          pick: (_) async => AccoutrementKind.absorptionRod);
      final loopB = _loop(state2, pair.sessionB, 'player_b');

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastArtifactActivations.local, isNull);
      expect(_avatar(state1, 'player_a').absorptionRodCount, equals(1),
          reason: 'the absorption rod keeps its untouched on-hit behaviour');
    });

    test('at most one artifact is spent per player per turn', () async {
      final state1 = _makeState();
      final state2 = _makeState();
      final pair = TurnSessionPair();

      // The wire carries exactly one declaration per player per turn, so a
      // literal double-declare is unreachable; what IS reachable — and what
      // the once-per-turn guard defends — is that a player who declares on
      // consecutive turns spends exactly one artifact each turn, never more.
      final loopA = _loop(state1, pair.sessionA, 'player_a',
          pick: (_) async => AccoutrementKind.manaGem);
      final loopB = _loop(state2, pair.sessionB, 'player_b');

      final before = _avatar(state1, 'player_a').accoutrements.length;
      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);
      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      final afterTurn1 = _avatar(state1, 'player_a').accoutrements.length;

      pair.reset();
      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);
      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      final afterTurn2 = _avatar(state1, 'player_a').accoutrements.length;

      expect(before - afterTurn1, equals(1));
      expect(afterTurn1 - afterTurn2, equals(1));
    });
  });

  // ── Mana gem (§6.2) ─────────────────────────────────────────────────────

  group('Mana gem activation', () {
    test('shrinks the pool by exactly one gem, then grants inside it',
        () async {
      // 2 gems → innate 100 + 200 = 300 pool, half full.
      final ctx = _solo(
        mana: 50,
        maxMana: 300,
        accoutrements: const [
          Accoutrement(id: 'gem_1', kind: AccoutrementKind.manaGem),
          Accoutrement(id: 'gem_2', kind: AccoutrementKind.manaGem),
        ],
        declare: AccoutrementKind.manaGem,
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.manaGemsEquipped, equals(1), reason: 'one gem spent');
      expect(ctx.local.maxMana, equals(200),
          reason: 'maxMana is stored state and must be resynced, not left stale');
      // 50 → +100 burst = 150, then Phase 6 regen from the ONE surviving gem.
      expect(ctx.local.mana, equals(150 + 10));
    });

    test('bursting at full mana is a near-no-op — pure loss, by design',
        () async {
      final ctx = _solo(
        mana: 300,
        maxMana: 300,
        accoutrements: const [
          Accoutrement(id: 'gem_1', kind: AccoutrementKind.manaGem),
          Accoutrement(id: 'gem_2', kind: AccoutrementKind.manaGem),
        ],
        declare: AccoutrementKind.manaGem,
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Pool shrinks FIRST, so the 100 mana granted has nowhere to go: the
      // wizard ends the turn strictly worse off. That is the intended shape —
      // this is an emergency button, not free value.
      expect(ctx.local.maxMana, equals(200));
      expect(ctx.local.mana, equals(200));
    });

    test('current mana is clamped down when it exceeded the new max', () async {
      final ctx = _solo(
        mana: 250,
        maxMana: 300,
        accoutrements: const [
          Accoutrement(id: 'gem_1', kind: AccoutrementKind.manaGem),
          Accoutrement(id: 'gem_2', kind: AccoutrementKind.manaGem),
        ],
        declare: AccoutrementKind.manaGem,
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.maxMana, equals(200));
      expect(ctx.local.mana, equals(200),
          reason: '250 clamped to the new 200 max, then +100 clamped again');
    });

    test('spending the LAST gem is legal and lands on the innate pool',
        () async {
      // The indestructible core gem is gone, so there is no instance to carve
      // out: the last gem is spendable, and the cost is a 100 pool with zero
      // passive regen — self-inflicted, which is exactly the trade.
      final ctx = _solo(
        mana: 50,
        maxMana: 200,
        accoutrements: const [
          Accoutrement(id: 'gem_1', kind: AccoutrementKind.manaGem),
        ],
        declare: AccoutrementKind.manaGem,
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.manaGemsEquipped, equals(0));
      expect(ctx.local.maxMana, equals(100), reason: 'innate pool only');
      expect(ctx.local.manaRegenFor(ctx.state.config), equals(0),
          reason: 'no gems means no passive regen — meditate or go without');
      expect(ctx.local.mana, equals(100), reason: '50 + 100 burst, clamped');
    });
  });

  // ── Rod of Spreading movement passive (§2.8, §3.2) ──────────────────────

  group('Rod of Spreading movement passive', () {
    test(
        '10 rods is a guaranteed +1, effective THIS turn\'s own movement '
        '(amended 2026-07-31 — was next-turn-only)', () async {
      // One roll at min(rods × 10, 100)% — so 10 rods is 100%, which is what
      // makes this assertable without pinning the RNG stream.
      final ctx = _solo(
        accoutrements: [
          for (var i = 0; i < 10; i++)
            Accoutrement(id: 'rod_$i', kind: AccoutrementKind.rodOfSpreading),
        ],
      );

      expect(ctx.local.effectiveMoveSpeed, equals(2), reason: 'base speed');

      // Rolled at Phase 0 (TurnLoop.beginArtifactEntropy), ahead of this same
      // turn's Phase 2 movement sizing — a dedicated commit-reveal separate
      // from the turn's main entropy, specifically so it's knowable before
      // this turn's own move commit. A 3-tile path is unreachable at base
      // speed 2, so successfully walking all 3 tiles proves the bonus was
      // live for THIS turn's move, not a future one.
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [
          HexCoord(1, 0),
          HexCoord(2, 0),
          HexCoord(3, 0),
        ],
      ));
      expect(ctx.local.position, equals(const HexCoord(3, 0)));

      // The one-shot status is consumed/ticked away by this same turn's
      // Phase 6 (it isn't meant to carry into next turn — a fresh roll
      // happens every turn), so speed reads back to base once the turn is
      // fully resolved.
      expect(ctx.local.effectiveMoveSpeed, equals(2));
    });

    test('no rods, no roll — speed is untouched', () async {
      final ctx = _solo();
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.effectiveMoveSpeed, equals(2));
    });
  });

  // ── Bookmark burn (§2.7) ────────────────────────────────────────────────

  group('Bookmark burn', () {
    test(
        'costs a permanent hand slot and re-deals the rest immediately, '
        'this same turn (amended 2026-07-31 — was next-turn-only)',
        () async {
      // Chapter of 4, 2 bookmarks → hand size 3.
      final chapter = _chapter(4);
      final ctx = _solo(
        accoutrements: const [
          Accoutrement(id: 'bm_1', kind: AccoutrementKind.bookmark),
          Accoutrement(id: 'bm_2', kind: AccoutrementKind.bookmark),
        ],
        chapter: chapter,
      );

      // Turn 1 deals the opening hand; the burn is declared on turn 2 so the
      // opening deal and the redraw don't overlap in one turn.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.localSpellDraw!.hand, hasLength(3));
      final handBefore =
          ctx.loop.localSpellDraw!.hand.map((s) => s.commitmentHex).toSet();

      // The redraw resolves at Phase 0, using the dedicated artifact entropy
      // (TurnLoop.beginArtifactEntropy) rather than this turn's main entropy
      // — the new hand is what THIS turn's own action could have been chosen
      // from, not next turn's.
      ctx.declare = AccoutrementKind.bookmark;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.bookmarkCount, equals(1), reason: 'a bookmark is gone');
      expect(ctx.loop.localSpellDraw!.hand, hasLength(2),
          reason: 'handSize == bookmarkCount + 1, and the slot is permanent');
      expect(ctx.loop.localSpellDraw!.remaining, hasLength(2));

      // The whole hand went back to the pool before the redraw, so the new
      // hand is drawn from all 4 — old spells can (and here, must) return.
      // That is what makes the burn a gamble rather than a free upgrade.
      final handAfter =
          ctx.loop.localSpellDraw!.hand.map((s) => s.commitmentHex).toSet();
      expect(handAfter.intersection(handBefore), isNotEmpty);

      // The public position-only schedule agrees with the private contents —
      // the invariant the peer's view depends on.
      expect(ctx.loop.drawScheduleFor('local')!.hand, hasLength(2));
    });

    test('burning the LAST bookmark still redraws the single remaining slot',
        () async {
      final ctx = _solo(
        accoutrements: const [
          Accoutrement(id: 'bm_1', kind: AccoutrementKind.bookmark),
        ],
        chapter: _chapter(4),
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.localSpellDraw!.hand, hasLength(2));

      ctx.declare = AccoutrementKind.bookmark;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.bookmarkCount, equals(0));
      expect(ctx.loop.localSpellDraw!.hand, hasLength(1),
          reason: 'the base non-bookmark slot survives and is reshuffled too');
      expect(ctx.loop.localSpellDraw!.remaining, hasLength(3));
    });
  });

  // ── Counter charm melee proc (§2.3-2.6) ─────────────────────────────────

  group('Counter charm melee proc', () {
    test('a melee by a charm-heavy wizard takes a gem from its victim',
        () async {
      // 20 unspent charms caps the rate at 100%, so the proc is assertable
      // without pinning the melee RNG stream.
      final state1 = _makeMeleeState(attackerCharms: 20);
      final state2 = _makeMeleeState(attackerCharms: 20);
      final pair = TurnSessionPair();

      final loopA = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (c) async => c.first,
      );
      final loopB = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
      );

      expect(_avatar(state1, 'player_b').manaGemsEquipped, equals(2));

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(_avatar(state1, 'player_b').manaGemsEquipped, equals(1),
          reason: 'the proc destroys a gem — permanently (§2.5)');
      expect(_avatar(state1, 'player_b').maxMana, equals(200),
          reason: 'a destroyed gem must resync maxMana, same as a burn');
      expect(loopA.lastCounterCharmProcs, hasLength(1));
      expect(loopA.lastCounterCharmProcs.single.outcome,
          equals(CounterCharmProcKind.gemDestroyed));
    });

    test('a victim with nothing to lose fizzles cleanly, in lockstep',
        () async {
      // No gems, no draw schedule → the roll is still drawn (both devices
      // must consume the shared meleeRng identically) and then nothing
      // happens. The lockstep assertion is the real check here.
      final state1 = _makeMeleeState(attackerCharms: 20, victimGems: 0);
      final state2 = _makeMeleeState(attackerCharms: 20, victimGems: 0);
      final pair = TurnSessionPair();

      final loopA = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (c) async => c.first,
      );
      final loopB = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
      );

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastCounterCharmProcs, isEmpty);
      // The punch itself still landed.
      expect(_avatar(state1, 'player_b').hp, equals(23));
    });

    test('a wizard with no charms never procs', () async {
      final state1 = _makeMeleeState(attackerCharms: 0);
      final state2 = _makeMeleeState(attackerCharms: 0);
      final pair = TurnSessionPair();

      final loopA = TurnLoop(
        state: state1,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        meleeTargetPicker: (c) async => c.first,
      );
      final loopB = TurnLoop(
        state: state2,
        session: pair.sessionB,
        localPlayerId: 'player_b',
      );

      await Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(state1.toCanonicalBytes(), equals(state2.toCanonicalBytes()));
      expect(loopA.lastCounterCharmProcs, isEmpty);
      expect(_avatar(state1, 'player_b').manaGemsEquipped, equals(2));
    });

    test('a SPENT charm stops feeding the proc rate (§2.4)', () {
      // The decay itself is a pure property of activeCounterCharmCount, which
      // is what the rate multiplies — asserting it here keeps the unit honest
      // without needing 20 turns of statistics to observe 60% → 55%.
      final av = _avatar(_makeMeleeState(attackerCharms: 3), 'player_a');
      expect(av.activeCounterCharmCount, equals(3));

      final idx = av.accoutrements
          .indexWhere((a) => a.kind == AccoutrementKind.counterCharm);
      av.accoutrements[idx] =
          av.accoutrements[idx].copyWith(counterCharmRevealed: true);

      expect(av.activeCounterCharmCount, equals(2),
          reason: 'a charm that fired its counter is spent and no longer '
              'contributes to the melee proc');
    });
  });
}

// ── Solo fixture ────────────────────────────────────────────────────────────

/// Mutable holder so a test can change what the picker declares between
/// turns ([declare]) — the bookmark burn needs turn 1 to deal an opening hand
/// before turn 2 burns one.
class _SoloCtx {
  _SoloCtx({required this.state, required this.loop, required this.local});

  final BattleState state;
  final TurnLoop loop;
  final WizardAvatar local;
  AccoutrementKind? declare;
}

/// Single-avatar setup against [SoloBattleSession] — enough for the
/// activations whose whole effect is on the declarer (gem burst, rod passive,
/// bookmark burn), where a second real client would only add noise.
_SoloCtx _solo({
  int mana = 100,
  int maxMana = 100,
  List<Accoutrement> accoutrements = const [],
  List<SpellAsset> chapter = const [],
  AccoutrementKind? declare,
}) {
  const id = 'local';
  final local = WizardAvatar(
    playerId: id,
    ownerPubkeyHex: '0x${'00' * 32}',
    hp: 24,
    mana: mana,
    maxMana: maxMana,
    position: const HexCoord(0, 0),
    teamId: 'solo',
    baseSpellRange: 3,
    accoutrements: List.of(accoutrements),
  );
  final bf = Battlefield(radius: 6);
  bf.occupancy[id] = local.position;
  final state = BattleState(
    config: const MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 1),
    avatars: [local],
    teams: [const Team(id: 'solo', playerIds: [id])],
    battlefield: bf,
  );
  late final _SoloCtx ctx;
  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: id,
    artifactActivationPicker: (_) async => ctx.declare,
  );
  if (chapter.isNotEmpty) {
    final sorted = List<SpellAsset>.from(chapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    loop
      ..localChapterSpells = sorted
      ..localChapterCommitments =
          sorted.map((s) => s.commitmentHex).toList();
  }
  ctx = _SoloCtx(state: state, loop: loop, local: local)..declare = declare;
  return ctx;
}

/// [count] distinct no-op spells, enough to back a real opening deal. Empty
/// formula and zero geometry keep every cast a free whiff, so a redraw test
/// only ever observes hand/deck cardinalities.
List<SpellAsset> _chapter(int count) => [
  for (var i = 0; i < count; i++)
    SpellAsset(
      id: 'ch$i',
      createdAt: DateTime.utc(2026, 7, 31),
      tier: 12,
      t: 1,
      ownerPubkeyHex: '0x${'00' * 32}',
      manaCost: 0,
      segmentCount: 0,
      dotCount: 0,
      initialGrid: const [],
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: 'Chapter $i',
      commitmentHex: '0x${(i + 1).toRadixString(16).padLeft(2, '0') * 32}',
      spellHashHex: '',
      formula: const [],
    ),
];

/// Two adjacent wizards for the melee proc: player_a carries [attackerCharms]
/// counter charms and nothing else, player_b carries [victimGems] mana gems.
BattleState _makeMeleeState({required int attackerCharms, int victimGems = 2}) {
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
        accoutrements: [
          for (var i = 0; i < attackerCharms; i++)
            Accoutrement(
              id: 'a_charm_${i.toString().padLeft(2, '0')}',
              kind: AccoutrementKind.counterCharm,
            ),
        ],
      ),
      WizardAvatar(
        playerId: 'player_b',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        maxMana: 100 + victimGems * 100,
        position: posB,
        teamId: 'team_b',
        baseSpellRange: 3,
        accoutrements: [
          for (var i = 0; i < victimGems; i++)
            Accoutrement(id: 'b_gem_$i', kind: AccoutrementKind.manaGem),
        ],
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}

// ── Helpers ─────────────────────────────────────────────────────────────────

TurnLoop _loop(
  BattleState state,
  PairedSession session,
  String localPlayerId, {
  ArtifactActivationPicker? pick,
}) =>
    TurnLoop(
      state: state,
      session: session,
      localPlayerId: localPlayerId,
      artifactActivationPicker: pick ?? (_) async => null,
    );

WizardAvatar _avatar(BattleState state, String playerId) =>
    state.avatars.firstWhere((av) => av.playerId == playerId);

/// Two adjacent wizards with deliberately asymmetric loadouts:
///   player_a — 2 mana gems, 3 counter charms, 2 rods of spreading
///   player_b — 2 bookmarks
///
/// Accoutrement ids are fixed strings rather than generated, because the
/// engine picks WHICH instance to consume by sorting on id — both devices must
/// build byte-identical loadouts for that choice to agree.
BattleState _makeState() {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  const config = MatchConfig();
  final aAccoutrements = <Accoutrement>[
    const Accoutrement(id: 'a_gem_1', kind: AccoutrementKind.manaGem),
    const Accoutrement(id: 'a_gem_2', kind: AccoutrementKind.manaGem),
    const Accoutrement(id: 'a_charm_1', kind: AccoutrementKind.counterCharm),
    const Accoutrement(id: 'a_charm_2', kind: AccoutrementKind.counterCharm),
    const Accoutrement(id: 'a_charm_3', kind: AccoutrementKind.counterCharm),
    const Accoutrement(id: 'a_rod_1', kind: AccoutrementKind.rodOfSpreading),
    const Accoutrement(id: 'a_rod_2', kind: AccoutrementKind.rodOfSpreading),
  ];
  final bAccoutrements = <Accoutrement>[
    const Accoutrement(id: 'b_mark_1', kind: AccoutrementKind.bookmark),
    const Accoutrement(id: 'b_mark_2', kind: AccoutrementKind.bookmark),
  ];

  return BattleState(
    config: config,
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 50,
        // innate 100 + 2 gems × 100.
        maxMana: 300,
        position: posA,
        teamId: 'team_a',
        baseSpellRange: 3,
        accoutrements: aAccoutrements,
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
        accoutrements: bAccoutrements,
      ),
    ],
    teams: [
      const Team(id: 'team_a', playerIds: ['player_a']),
      const Team(id: 'team_b', playerIds: ['player_b']),
    ],
    battlefield: battlefield,
  );
}
