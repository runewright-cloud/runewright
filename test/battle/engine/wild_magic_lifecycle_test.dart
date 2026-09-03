// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_lifecycle_test.dart — the bounded lifetimes of the row-3
// persistents (Slice 4).
//
// The ratified timing rule, which every group below is a reading of:
//
//     An effect triggering during round R arms beginning with round R+1, never
//     affects anything still resolving inside R, and a two-round effect is
//     active during R+1 and R+2 and gone before the first voluntary action of
//     R+3.
//
// The clock is `BattleState.turnNumber`, and `TurnLoop.runTurn` bumps it once
// at the top — so a test that wants "round N" runs N turns.
//
// These are BOUNDARY tests. Where a group could assert only "it works during
// the window", it asserts the round before and the round after as well: an
// off-by-one in an inclusive/exclusive bound is the failure this whole slice
// was designed to make impossible, and a test that only checks the middle of a
// window cannot see one.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/forced_cast.dart' show ForcedCastPick;
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/pending_delayed_spell.dart';
import 'package:rune_duel/battle/models/wild_magic_state.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

final Uint8List _commitment =
    Uint8List.fromList(List.generate(32, (i) => i + 1));

String get _commitmentHex =>
    '0x${_commitment.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// A structurally real proof blob — see wild_magic_resolution_test.dart, whose
/// builder this mirrors. Not a valid SNARK; solo mode never verifies one.
Uint8List _proofBytes({required int t, List<int> trajectory = const [1, 0, 1, 0, 1]}) {
  final tier = tierForSteps(t)!;
  final count = 10 + 2 * tier;
  final out = Uint8List(4 + count * 32);
  ByteData.sublistView(out).setUint32(0, count, Endian.big);
  void setSmall(int index, int value) {
    ByteData.sublistView(out, 4 + index * 32 + 24, 4 + index * 32 + 32)
        .setUint64(0, value, Endian.big);
  }

  setSmall(0, t);
  setSmall(1, 0);
  setSmall(2, 3);
  out.setRange(4 + 3 * 32, 4 + 4 * 32, _commitment);
  for (var g = 0; g < tier; g++) {
    setSmall(8 + g, g < trajectory.length ? trajectory[g] : 0);
  }
  setSmall(8 + 2 * tier, 1);
  setSmall(8 + 2 * tier + 1, 1);
  return out;
}

SpellAsset _spell({String id = 'wm', int t = 5}) => SpellAsset(
      id: id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      tier: tierForSteps(t)!,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 6,
      segmentCount: 1,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: _proofBytes(t: t),
      name: 'Lifecycle Fixture',
      commitmentHex: _commitmentHex,
      spellHashHex: '0x${'b' * 64}',
      formula: const ['fire', 'fire', 'fire'],
    );

typedef _Ctx = ({BattleState state, TurnLoop loop, WizardAvatar local});

/// A one-wizard solo match. [accoutrements] seats artifacts for the activation
/// break test.
_Ctx _setup({
  int radius = 6,
  List<Accoutrement> accoutrements = const [],
}) {
  final bf = Battlefield(radius: radius);
  const id = 'local';
  final local = WizardAvatar(
    playerId: id,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 500,
    maxMana: 500,
    position: const HexCoord(0, 3),
    teamId: 'solo',
    baseSpellRange: 3,
    accoutrements: accoutrements,
  );
  bf.occupancy[id] = local.position;
  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 1),
    avatars: [local],
    teams: [Team(id: 'solo', playerIds: const [id])],
    battlefield: bf,
  );
  return (
    state: state,
    loop: TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: id,
    ),
    local: local,
  );
}

Future<void> _pass(_Ctx ctx) =>
    ctx.loop.runTurn(TurnInput(action: PassAction()));

// ── Phoenix ───────────────────────────────────────────────────────────────────

void main() {
  group('Phoenix is bounded to R+1..R+2', () {
    test('a trigger during R does not protect during R', () async {
      final ctx = _setup();
      await _pass(ctx); // now on round 1
      // Armed DURING round 1, i.e. triggerTurn == the round in progress.
      ctx.state.wildMagic
          .armPhoenix('local', triggerTurn: ctx.state.turnNumber);
      expect(
        ctx.state.wildMagic
            .phoenixAvailableFor('local', ctx.state.turnNumber),
        isFalse,
      );

      // A death still inside round 1 is final.
      ctx.local.hp = 0;
      ctx.loop.applyPhoenixSavesForTesting();
      expect(ctx.local.hp, 0, reason: 'the save has not begun yet');
    });

    test('protects during R+1 and clears on use', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armPhoenix('local', triggerTurn: 0);
      ctx.local.hp = 0;
      await _pass(ctx); // round 1
      expect(ctx.local.hp, 1);
      expect(ctx.state.wildMagic.phoenixWindows, isEmpty,
          reason: 'consumption clears immediately');
    });

    test('protects during R+2', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armPhoenix('local', triggerTurn: 0);
      await _pass(ctx); // round 1, alive, save untouched
      expect(ctx.state.wildMagic.phoenixWindows, isNotEmpty);

      ctx.local.hp = 0;
      await _pass(ctx); // round 2
      expect(ctx.local.hp, 1);
    });

    test('is absent in R+3', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armPhoenix('local', triggerTurn: 0);
      await _pass(ctx); // 1
      await _pass(ctx); // 2
      expect(ctx.state.wildMagic.phoenixWindows, isNotEmpty,
          reason: 'still armed at the end of its last covered round');

      ctx.local.hp = 0;
      await _pass(ctx); // 3 — swept at the round boundary
      expect(ctx.local.hp, 0, reason: 'the window is over');
      expect(ctx.state.wildMagic.phoenixWindows, isEmpty);
    });

    test('a retrigger cannot shorten an existing window', () {
      final wild = WildMagicState();
      wild.armPhoenix('a', triggerTurn: 10); // 11..12
      wild.armPhoenix('a', triggerTurn: 5); // 6..7 — earlier, must not win
      expect(wild.phoenixWindows['a']!.activeFromTurn, 6,
          reason: 'the union starts at the earlier of the two');
      expect(wild.phoenixWindows['a']!.expiresAfterTurn, 12,
          reason: 'and keeps the LATER expiry');

      // And the ordinary direction: a later retrigger extends.
      wild.armPhoenix('a', triggerTurn: 20);
      expect(wild.phoenixWindows['a']!.expiresAfterTurn, 22);
    });

    test('one wizard has at most one save, however many times it fires', () {
      final wild = WildMagicState();
      wild.armPhoenix('a', triggerTurn: 0);
      wild.armPhoenix('a', triggerTurn: 0);
      wild.armPhoenix('a', triggerTurn: 0);
      expect(wild.phoenixWindows, hasLength(1));
      expect(wild.consumePhoenixSave('a', 1), isTrue);
      expect(wild.consumePhoenixSave('a', 1), isFalse,
          reason: 'three firings did not buy three lives');
    });
  });

  // ── Statuesque ──────────────────────────────────────────────────────────────

  group('Statuesque is bounded to R+1..R+2 and heals at round start', () {
    test('does not heal during the trigger round', () async {
      final ctx = _setup();
      await _pass(ctx); // round 1
      ctx.state.wildMagic
          .armStatuesque('local', triggerTurn: ctx.state.turnNumber);
      ctx.local.hp = 5;
      // Nothing else happens this round; the heal is a round-start event.
      expect(ctx.local.hp, 5);
      expect(
        ctx.state.wildMagic
            .statuesqueActiveFor('local', ctx.state.turnNumber),
        isFalse,
      );
    });

    test('heals at the start of R+1 and again at the start of R+2, then '
        'stops in R+3', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0); // 1..2

      ctx.local
        ..hp = 5
        ..mana = 0;
      await _pass(ctx); // 1
      expect(ctx.local.hp, 24);
      expect(ctx.local.mana, ctx.local.maxMana);

      ctx.local.hp = 5;
      await _pass(ctx); // 2
      expect(ctx.local.hp, 24);

      ctx.local.hp = 5;
      await _pass(ctx); // 3
      expect(ctx.local.hp, 5, reason: 'the window ended before round 3 began');
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('a retrigger cannot shorten an existing window', () {
      final wild = WildMagicState();
      wild.armStatuesque('a', triggerTurn: 10); // 11..12
      wild.armStatuesque('a', triggerTurn: 5); // 6..7
      expect(wild.statuesqueWindows['a']!.activeFromTurn, 6);
      expect(wild.statuesqueWindows['a']!.expiresAfterTurn, 12);
    });
  });

  group('Statuesque breaks on any voluntary action but Pass', () {
    // The classification itself, exhaustively over the sealed TurnAction
    // hierarchy. Adding a TurnAction subclass breaks `breaksStatuesque`'s
    // compile, and this pins the answers it gives today.
    test('Pass does not break it; every other declared action does', () {
      expect(breaksStatuesque(PassAction()), isFalse);
      expect(breaksStatuesque(DashAction()), isTrue);
      expect(breaksStatuesque(MeditateAction()), isTrue);
      expect(
        breaksStatuesque(
          SpellCastAction(spell: _spell(), targetHex: const HexCoord(0, 0)),
        ),
        isTrue,
      );
      expect(
        breaksStatuesque(
          MysterySpellCastAction(
            spell: _spell(),
            mysteryCommitment: Uint8List(32),
          ),
        ),
        isTrue,
      );
    });

    Future<_Ctx> armed({List<Accoutrement> accoutrements = const []}) async {
      final ctx = _setup(accoutrements: accoutrements);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0); // 1..2
      return ctx;
    }

    test('Pass leaves it standing', () async {
      final ctx = await armed();
      await _pass(ctx);
      expect(ctx.state.wildMagic.statuesqueWindows, isNotEmpty);
    });

    test('an ordinary cast breaks it', () async {
      final ctx = await armed();
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
      expect(
        ctx.loop.debugStatuesqueBreakCountsForTesting,
        containsPair(StatuesqueBreakCause.declaredAction, 1),
      );
    });

    test('movement breaks it', () async {
      final ctx = await armed();
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [HexCoord(ctx.local.position.q, ctx.local.position.r - 1)],
      ));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
      expect(
        ctx.loop.debugStatuesqueBreakCountsForTesting,
        containsPair(StatuesqueBreakCause.declaredMovement, 1),
      );
    });

    test('Dash breaks it', () async {
      final ctx = await armed();
      await ctx.loop.runTurn(TurnInput(action: DashAction()));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('Meditate breaks it', () async {
      final ctx = await armed();
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('move-phase Meditate breaks it', () async {
      final ctx = await armed();
      await ctx.loop
          .runTurn(TurnInput(action: PassAction(), meditateInMove: true));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
      expect(
        ctx.loop.debugStatuesqueBreakCountsForTesting,
        containsPair(StatuesqueBreakCause.moveePhaseMeditate, 1),
      );
    });

    test('melee breaks it', () async {
      final ctx = await armed();
      // Driven through the resolver directly: the melee prompt is a
      // commit-reveal round, and what this asserts is that a declared punch
      // reaches the breaker at all.
      ctx.loop.applyHaymakerForTesting('local', ctx.local.position);
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
      expect(
        ctx.loop.debugStatuesqueBreakCountsForTesting,
        containsPair(StatuesqueBreakCause.melee, 1),
      );
    });

    test('artifact activation breaks it', () async {
      final ctx = await armed(
        // Mutable: burning the gem removes it from the wizard's list.
        accoutrements: [
          const Accoutrement(id: 'gem', kind: AccoutrementKind.manaGem),
        ],
      );
      ctx.loop.applyArtifactActivationForTesting(
          'local', AccoutrementKind.manaGem);
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
      expect(
        ctx.loop.debugStatuesqueBreakCountsForTesting,
        containsPair(StatuesqueBreakCause.artifactActivation, 1),
      );
    });

    test('a forced cast does NOT break it', () async {
      final ctx = await armed();
      await ctx.loop.resolveForcedCast(
        ForcedCastPick(playerId: 'local', position: 0, spell: _spell()),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i + 2))),
      );
      expect(ctx.state.wildMagic.statuesqueWindows, isNotEmpty,
          reason: 'a cast the wizard did not choose is not them acting');
      expect(ctx.loop.debugStatuesqueBreakCountsForTesting, isEmpty);
    });

    test('involuntary displacement does NOT break it', () async {
      final ctx = await armed();
      // Knockback/conveyor/slide all move the avatar without a declared path.
      // Modelled here as the engine relocating them outright, which is what
      // those paths do — no declared move, so no break.
      ctx.local.position = HexCoord(ctx.local.position.q, ctx.local.position.r - 1);
      ctx.state.battlefield.occupancy['local'] = ctx.local.position;
      await _pass(ctx);
      expect(ctx.state.wildMagic.statuesqueWindows, isNotEmpty);
      expect(ctx.loop.debugStatuesqueBreakCountsForTesting, isEmpty);
    });
  });

  // ── Rippling Reflections ────────────────────────────────────────────────────

  group('Rippling Reflections is bounded to R+1', () {
    test('a trigger during R does not affect R', () {
      final wild = WildMagicState();
      wild.armRippling(triggerTurn: 4);
      expect(wild.ripplingFizzlePctOn(4), isNull);
      expect(wild.ripplingFizzlePctOn(5), 50);
      expect(wild.ripplingFizzlePctOn(6), isNull);
    });

    test('applies throughout R+1 and is gone in R+2', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armRippling(triggerTurn: 0); // covers turn 1
      ctx.state.wildMagic.ripplingFizzlePct = 100; // certain fizzle

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(),
          targetHex: ctx.local.position,
        ),
      ));
      // A certain fizzle drifts the counter 10 toward doubling — proof the
      // coin was rolled at all on turn 1.
      expect(ctx.state.wildMagic.ripplingFizzlePct, 90);

      await _pass(ctx); // turn 2 — swept at the round boundary
      expect(ctx.state.wildMagic.ripplingWindow, isNull);
      expect(ctx.state.wildMagic.ripplingFizzlePct, isNull,
          reason: 'a spent effect leaves no drifted counter behind');
    });

    test('the drift arithmetic and clamp are unchanged', () {
      final wild = WildMagicState()..armRippling(triggerTurn: 0);
      expect(wild.ripplingFizzlePct, 50, reason: 'still starts at 50');

      wild.driftRippling(1, 10);
      expect(wild.ripplingFizzlePct, 60);
      wild.driftRippling(1, -10);
      expect(wild.ripplingFizzlePct, 50);

      wild.ripplingFizzlePct = 5;
      wild.driftRippling(1, -10);
      expect(wild.ripplingFizzlePct, 0, reason: 'clamped at 0');
      wild.ripplingFizzlePct = 95;
      wild.driftRippling(1, 10);
      expect(wild.ripplingFizzlePct, 100, reason: 'clamped at 100');
    });

    test('drift on a round the window does not cover is a no-op', () {
      final wild = WildMagicState()..armRippling(triggerTurn: 0); // covers 1
      wild.driftRippling(5, 10);
      expect(wild.ripplingFizzlePct, 50);
    });

    test('a retrigger extends but never shortens, and does not reset the '
        'drifted counter', () {
      final wild = WildMagicState()..armRippling(triggerTurn: 10); // 11..11
      wild.driftRippling(11, 10);
      expect(wild.ripplingFizzlePct, 60);

      wild.armRippling(triggerTurn: 5); // 6..6 — earlier, must not shorten
      expect(wild.ripplingWindow!.expiresAfterTurn, 11);
      expect(wild.ripplingFizzlePct, 60, reason: 'no reset to 50');

      wild.armRippling(triggerTurn: 20); // extends
      expect(wild.ripplingWindow!.expiresAfterTurn, 21);
      expect(wild.ripplingFizzlePct, 60);
    });

    test('there is no multiplicative stacking — two firings are one effect',
        () {
      final wild = WildMagicState()
        ..armRippling(triggerTurn: 0)
        ..armRippling(triggerTurn: 0);
      expect(wild.ripplingFizzlePctOn(1), 50);
    });
  });

  // ── Scattered Gusts ─────────────────────────────────────────────────────────

  group('Scattered Gusts is per wizard and consumed by one voluntary cast', () {
    test('is tracked independently per player', () {
      final wild = WildMagicState()
        ..armScatteredGusts('a', triggerTurn: 0)
        ..armScatteredGusts('b', triggerTurn: 3);
      expect(wild.scatteredGustsArmedFrom, {'a': 1, 'b': 4});
      expect(wild.scatteredGustPendingFor('a', 1), isTrue);
      expect(wild.scatteredGustPendingFor('b', 1), isFalse);
    });

    test('a trigger during R cannot be consumed in R', () {
      final wild = WildMagicState()..armScatteredGusts('a', triggerTurn: 7);
      expect(wild.scatteredGustPendingFor('a', 7), isFalse);
      expect(wild.consumeScatteredGust('a', 7), isFalse);
      expect(wild.scatteredGustsArmedFrom, contains('a'),
          reason: 'and the failed consume left it pending');
      expect(wild.consumeScatteredGust('a', 8), isTrue);
    });

    test('consuming clears only that caster', () {
      final wild = WildMagicState()
        ..armScatteredGusts('a', triggerTurn: 0)
        ..armScatteredGusts('b', triggerTurn: 0);
      expect(wild.consumeScatteredGust('a', 1), isTrue);
      expect(wild.scatteredGustsArmedFrom.keys, ['b']);
      expect(wild.scatteredGustPendingFor('b', 1), isTrue);
    });

    test('a second cast does not redeal again without a retrigger', () {
      final wild = WildMagicState()..armScatteredGusts('a', triggerTurn: 0);
      expect(wild.consumeScatteredGust('a', 1), isTrue);
      expect(wild.consumeScatteredGust('a', 1), isFalse);
      expect(wild.consumeScatteredGust('a', 2), isFalse);

      wild.armScatteredGusts('a', triggerTurn: 2);
      expect(wild.consumeScatteredGust('a', 3), isTrue);
    });

    test('it stays pending across rounds until a qualifying cast', () {
      final wild = WildMagicState()..armScatteredGusts('a', triggerTurn: 0);
      for (final turn in [1, 2, 3, 4, 5, 50]) {
        expect(wild.scatteredGustPendingFor('a', turn), isTrue,
            reason: 'no time-based expiry');
      }
      expect(wild.consumeScatteredGust('a', 50), isTrue);
    });

    test('a retrigger keeps the earlier arming turn', () {
      final wild = WildMagicState()
        ..armScatteredGusts('a', triggerTurn: 10)
        ..armScatteredGusts('a', triggerTurn: 2);
      expect(wild.scatteredGustsArmedFrom['a'], 3);
    });

    test('a forced cast does not consume it', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armScatteredGusts('local', triggerTurn: 0);
      await _pass(ctx); // round 1 — pending

      await ctx.loop.resolveForcedCast(
        ForcedCastPick(playerId: 'local', position: 0, spell: _spell()),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i + 2))),
      );
      expect(ctx.state.wildMagic.scatteredGustPendingFor('local', 1), isTrue,
          reason: 'a free cast (A8) leaves the Gust standing');
    });

    test('non-spell voluntary actions do not consume it', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armScatteredGusts('local', triggerTurn: 0);
      for (final action in <TurnAction>[
        PassAction(),
        DashAction(),
        MeditateAction(),
      ]) {
        await ctx.loop.runTurn(TurnInput(action: action));
        expect(
          ctx.state.wildMagic.scatteredGustsArmedFrom,
          contains('local'),
          reason: '$action must not spend a Gust',
        );
      }
    });

    test('a voluntary cast consumes exactly one', () async {
      final ctx = _setup();
      ctx.state.wildMagic.armScatteredGusts('local', triggerTurn: 0);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, isEmpty);
    });
  });

  // ── Delayed casts: declaration is the voluntary act ─────────────────────────

  group('a delayed Mystery is voluntary at DECLARATION, not at fire', () {
    // The invariant: voluntary effects follow fresh player intent, never the
    // engine's automatic realization of an earlier promise. A delayed fire
    // re-enters resolution wearing a SpellCastAction, so the two are
    // indistinguishable by type — `SpellCastAction.isDelayedRealization` is
    // the engine's own distinction, and both effects below read it.

    const target = HexCoord(0, 1);
    const delay = 2;
    final nonce = Uint8List.fromList(List.generate(16, (i) => i));

    Future<Uint8List> commitment() =>
        PendingDelayedSpell.commitmentHash(
          target: target,
          delay: delay,
          nonce: nonce,
        );

    Future<void> declare(_Ctx ctx, Uint8List c) => ctx.loop.runTurn(TurnInput(
          action: MysterySpellCastAction(
            spell: _spell(),
            mysteryCommitment: c,
          ),
        ));

    Future<void> fire(_Ctx ctx) => ctx.loop.runTurn(TurnInput(
          action: PassAction(),
          delayedSpellReveals: [
            DelayedSpellReveal(
              pendingSpellId: ctx.state.pendingDelayedSpells.single.id,
              targetTile: target,
              delay: delay,
              nonce: nonce,
            ),
          ],
        ));

    test('the classifier itself: a fresh cast breaks, a realization does not',
        () {
      expect(
        breaksStatuesque(
          SpellCastAction(spell: _spell(), targetHex: target),
        ),
        isTrue,
      );
      expect(
        breaksStatuesque(
          SpellCastAction(
            spell: _spell(),
            targetHex: target,
            isDelayedRealization: true,
          ),
        ),
        isFalse,
      );
    });

    test('Statuesque: declaring a Mystery while it is active BREAKS it',
        () async {
      final ctx = _setup();
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0); // 1..2
      await declare(ctx, await commitment()); // turn 1
      expect(ctx.state.pendingDelayedSpells, hasLength(1),
          reason: 'fixture check: the declaration really was stashed');
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty,
          reason: 'the declaration is the wizard choosing to cast');
    });

    test('Statuesque: a Mystery declared BEFORE it armed does not break it '
        'when it fires', () async {
      final ctx = _setup();
      await declare(ctx, await commitment()); // turn 1 — nothing armed yet
      expect(ctx.state.pendingDelayedSpells, hasLength(1));

      // Armed after the declaration, covering turns 2 and 3 — so it is live on
      // turn 3, the turn the promise comes due.
      ctx.state.wildMagic
          .armStatuesque('local', triggerTurn: ctx.state.turnNumber);
      await _pass(ctx); // turn 2
      expect(ctx.state.wildMagic.statuesqueWindows, isNotEmpty);

      await fire(ctx); // turn 3 — the delayed fire
      expect(ctx.state.pendingDelayedSpells, isEmpty,
          reason: 'fixture check: it really fired');
      expect(ctx.state.wildMagic.statuesqueWindows, isNotEmpty,
          reason: 'the engine keeping an old promise is not a fresh choice');
      expect(ctx.loop.debugStatuesqueBreakCountsForTesting, isEmpty);
    });

    test('Scattered Gusts: declaring a Mystery consumes the pending Gust',
        () async {
      final ctx = _setup();
      ctx.state.wildMagic.armScatteredGusts('local', triggerTurn: 0);
      await declare(ctx, await commitment()); // turn 1
      expect(ctx.state.pendingDelayedSpells, hasLength(1));
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, isEmpty,
          reason: 'the declaration IS the next voluntary spell cast');
    });

    test('Scattered Gusts: a Mystery declared BEFORE it armed does not consume '
        'when it fires', () async {
      final ctx = _setup();
      await declare(ctx, await commitment()); // turn 1 — nothing armed yet
      ctx.state.wildMagic
          .armScatteredGusts('local', triggerTurn: ctx.state.turnNumber);

      await _pass(ctx); // turn 2 — pending, a Pass spends nothing
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, contains('local'));

      await fire(ctx); // turn 3 — the delayed fire
      expect(ctx.state.pendingDelayedSpells, isEmpty);
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, contains('local'),
          reason: 'an automatic realization is not a voluntary cast');

      // And the wizard's next real cast still spends it.
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, isEmpty);
    });

    test('a Gust armed on the declaration turn is not spent by that '
        'declaration', () async {
      // The same round-boundary rule the ordinary cast path follows: armed
      // during R, spendable from R+1.
      final ctx = _setup();
      await _pass(ctx); // turn 1
      // Armed AS IF it had fired during turn 2 — the very round the
      // declaration below runs on — so it is not yet spendable that round.
      ctx.state.wildMagic
          .armScatteredGusts('local', triggerTurn: ctx.state.turnNumber + 1);
      await declare(ctx, await commitment()); // turn 2
      expect(ctx.state.wildMagic.scatteredGustsArmedFrom, contains('local'));
    });
  });

  // ── Windows, and the state they live in ─────────────────────────────────────

  group('WildMagicWindow', () {
    test('bounds are inclusive at both ends', () {
      const w = WildMagicWindow(activeFromTurn: 3, expiresAfterTurn: 5);
      expect(w.isActiveOn(2), isFalse);
      expect(w.isActiveOn(3), isTrue);
      expect(w.isActiveOn(5), isTrue);
      expect(w.isActiveOn(6), isFalse);
      expect(w.hasExpiredBy(5), isFalse);
      expect(w.hasExpiredBy(6), isTrue);
      expect(w.isScheduledOn(2), isTrue);
      expect(w.isScheduledOn(3), isFalse);
    });

    test('armedOn starts on the NEXT round and covers `rounds` of them', () {
      final one = WildMagicWindow.armedOn(7, rounds: 1);
      expect(one.activeFromTurn, 8);
      expect(one.expiresAfterTurn, 8);

      final two = WildMagicWindow.armedOn(7, rounds: 2);
      expect(two.activeFromTurn, 8);
      expect(two.expiresAfterTurn, 9);
    });

    test('merge takes the earliest start and the latest end', () {
      const a = WildMagicWindow(activeFromTurn: 3, expiresAfterTurn: 5);
      const b = WildMagicWindow(activeFromTurn: 4, expiresAfterTurn: 9);
      expect(a.mergedWith(b), b.mergedWith(a));
      expect(a.mergedWith(b).activeFromTurn, 3);
      expect(a.mergedWith(b).expiresAfterTurn, 9);
    });
  });

  group('the round-start sweep', () {
    test('drops expired windows and keeps live ones', () {
      final wild = WildMagicState()
        ..armPhoenix('a', triggerTurn: 0) // 1..2
        ..armStatuesque('a', triggerTurn: 0) // 1..2
        ..armRippling(triggerTurn: 0); // 1..1

      wild.sweepExpired(2, isAlive: (_) => true);
      expect(wild.phoenixWindows, isNotEmpty);
      expect(wild.statuesqueWindows, isNotEmpty);
      expect(wild.ripplingWindow, isNull, reason: 'one round only');

      wild.sweepExpired(3, isAlive: (_) => true);
      expect(wild.phoenixWindows, isEmpty);
      expect(wild.statuesqueWindows, isEmpty);
    });

    test('keeps a dead wizard\'s Phoenix but drops their Statuesque and Gust',
        () {
      final wild = WildMagicState()
        ..armPhoenix('a', triggerTurn: 0)
        ..armStatuesque('a', triggerTurn: 0)
        ..armScatteredGusts('a', triggerTurn: 0);

      wild.sweepExpired(1, isAlive: (_) => false);
      expect(wild.phoenixWindows, contains('a'),
          reason: 'a dead wizard is exactly who a Phoenix has yet to save');
      expect(wild.statuesqueWindows, isEmpty);
      expect(wild.scatteredGustsArmedFrom, isEmpty);
    });

    test('Scattered Gusts has no time-based expiry', () {
      final wild = WildMagicState()..armScatteredGusts('a', triggerTurn: 0);
      wild.sweepExpired(500, isAlive: (_) => true);
      expect(wild.scatteredGustsArmedFrom, contains('a'));
    });
  });

  group('Burning Hot stacking', () {
    test('still arms for exactly the next round', () {
      final wild = WildMagicState()..armSpellDamageBonus(5, 2);
      expect(wild.spellDamageBonusFor(4), 0);
      expect(wild.spellDamageBonusFor(5), 2);
      expect(wild.spellDamageBonusFor(6), 0);
    });

    // UNCHANGED BY SLICE 7, deliberately. R5's "they do not add together" is a
    // rule about ONE SIMULTANEOUS BATCH, and it is enforced upstream by
    // `coalesceWildMagicTriggers`: a batch arms Burning Hot exactly once, at
    // the strongest contributing bracket. This primitive stays additive because
    // it cannot see a batch — two armings reaching it really are two separate
    // world events (a Quick one and a Normal one), and those stack as they
    // always did. See wild_magic_phase_test.dart for both halves driven through
    // the engine.
    test('still sums two armings for the same round', () {
      final wild = WildMagicState()
        ..armSpellDamageBonus(5, 2)
        ..armSpellDamageBonus(5, 3);
      expect(wild.spellDamageBonusFor(5), 5);
    });

    test('a stale arming is REPLACED, not combined', () {
      // A previous round's Burning Hot has expired; it must not leak its
      // amount forward into the new round. Slice 7 deliberately did not
      // revisit this.
      final wild = WildMagicState()
        ..armSpellDamageBonus(5, 9)
        ..armSpellDamageBonus(6, 1);
      expect(wild.spellDamageBonusFor(5), 0);
      expect(wild.spellDamageBonusFor(6), 1);
    });
  });
}
