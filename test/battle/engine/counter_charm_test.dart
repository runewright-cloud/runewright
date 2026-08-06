// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm_test.dart — the trajectory counter charm
// (docs/COUNTER_CHARM_KINSHIP_PLAN.md Phase 2). A charm is attuned to an
// elemental TRAJECTORY, not to one spell's grid: it fires against any cast
// whose certified element sequence opens with that trajectory, by ANY wizard
// including its own owner (settled decision: "any source", not
// opponent-only), cancels formulas for as long as the two sequences stay in
// lockstep, and is then consumed.
//
// Covers:
//   - a charm counters its OWNER's own cast (the distinguishing "any source"
//     behavior — see TurnLoop._findCounteringCharm's doc comment);
//   - a charm counters an OPPONENT's cast with a matching trajectory;
//   - a charm attuned to a DIFFERENT trajectory does not fire, and neither
//     does an UNATTUNED one — no false positives;
//   - a PARTIAL match cancels only the leading formulas and lets the rest of
//     the cast resolve (§2.3) — the genuinely new engine behaviour;
//   - the charm's owner pays full mana on every trigger (§2.4), and a charm
//     its owner cannot afford does not fire and is not consumed;
//   - once consumed, a second matching cast resolves normally — the core
//     "first time only" invariant (CLAUDE.md §10/§11 pairing: this is the
//     negative vector for "counters exactly once");
//   - when two charms match, the LONGEST match wins and ties break by the
//     fixed scan order (avatar playerId, then accoutrement id) — the property
//     that keeps two devices resolving the same turn in lockstep agreement;
//   - the charm trajectory and counterCharmRevealed are both part of
//     BattleState.toCanonicalBytes(), so the outcome is visible to the
//     lockstep hash check, not just local state.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/counter_charm.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

SpellAsset _spell({
  required String commitmentHex,
  String name = 'Test Spell',
  int t = 1,
  List<String> formula = const ['fire'],
  bool isSummon = false,
}) =>
    SpellAsset(
      id: 'sp-$commitmentHex',
      createdAt: DateTime.utc(2026, 7, 24),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List(0),
      name: name,
      commitmentHex: commitmentHex,
      spellHashHex: '0x${'b' * 64}',
      formula: formula,
      isSummon: isSummon,
    );

/// Single-avatar solo setup (no peer) — for a caster countering their own cast.
({BattleState state, TurnLoop loop, WizardAvatar local}) _soloSetup({
  List<Accoutrement> accoutrements = const [],
  AccoutrementKind? Function()? declare,
}) {
  const id = 'local';
  final local = WizardAvatar(
    playerId: id,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: const HexCoord(0, 0),
    teamId: 'solo',
    baseSpellRange: 6,
    accoutrements: List.of(accoutrements),
  );
  final bf = Battlefield(radius: 6);
  bf.occupancy[id] = local.position;
  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 1),
    avatars: [local],
    teams: [Team(id: 'solo', playerIds: const [id])],
    battlefield: bf,
  );
  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: id,
    artifactActivationPicker: (_) async => declare?.call(),
  );
  return (state: state, loop: loop, local: local);
}

/// Two-avatar setup with the dummy scripted to auto-cast [_kDummyCommitmentHex]
/// at [localId]'s position every turn — for opponent-sourced counter checks.
({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _duoSetup({
  String localId = 'local',
  String dummyId = 'dummy',
  List<Accoutrement> localAccoutrements = const [],
  List<Accoutrement> dummyAccoutrements = const [],
  List<String> dummyCastFormula = const ['fire', 'fire', 'fire'],
}) {
  const radius = 8;
  final localPos = const HexCoord(0, 0);
  final dummyPos = const HexCoord(0, 5);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: localPos,
    teamId: 'solo',
    baseSpellRange: 6,
    accoutrements: List.of(localAccoutrements),
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 6,
    accoutrements: List.of(dummyAccoutrements),
  );

  final state = BattleState(
    config: const MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: [localId]),
      Team(id: 'foe', playerIds: [dummyId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(
      state: state,
      dummyAutoCast: true,
      dummyCastTarget: localPos,
      dummyCastFormula: dummyCastFormula,
    ),
    localPlayerId: localId,
  );
  return (state: state, loop: loop, local: local, dummy: dummy);
}

Accoutrement _charm(String id, {List<BorderZone>? trajectory}) => Accoutrement(
      id: id,
      kind: AccoutrementKind.counterCharm,
      charmTrajectory: trajectory,
    );

const _fff = [BorderZone.fire, BorderZone.fire, BorderZone.fire];
const _www = [BorderZone.water, BorderZone.water, BorderZone.water];

/// The dummy's scripted cast trajectory (SoloBattleSession.dummyCastFormula's
/// default), as BorderZones.
const _dummyTrajectory = _fff;

void main() {
  group('a charm counters its own owner\'s cast', () {
    test('the spell never resolves and the charm is consumed', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);
      final manaBefore = ctx.local.mana;

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells, hasLength(1));
      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.wasCountered, isTrue);
      expect(ev.counteredFormulas, 1);
      expect(ev.casterId, 'local');
      expect(ev.counterCharmOwnerId, 'local');

      final charm = ctx.local.accoutrements.single;
      expect(charm.counterCharmRevealed, isTrue);

      // §2.4: the charm's owner pays its full cost on every trigger. Here the
      // owner is also the caster, so the drop covers the cast too — assert on
      // the charm's own share rather than the exact total.
      expect(manaBefore - ctx.local.mana,
          greaterThanOrEqualTo(counterCharmManaCost(_fff)));
    });
  });

  group('a charm counters an opponent\'s cast', () {
    test('the dummy\'s scripted cast is nullified by the local player\'s charm',
        () async {
      final ctx = _duoSetup(
        localAccoutrements: [_charm('c1', trajectory: _dummyTrajectory)],
      );
      final manaBefore = ctx.local.mana;

      // Local passes; the dummy auto-casts fire/fire/fire at localPos.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      final dummyEvents = ctx.loop.lastResolvedSpells.where((e) => e.casterId == 'dummy');
      expect(dummyEvents, hasLength(1));
      expect(dummyEvents.single.wasCountered, isTrue);
      expect(dummyEvents.single.counterCharmOwnerId, 'local');
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isTrue);
      // Local cast nothing this turn, so the only mana it lost is the charm's.
      expect(manaBefore - ctx.local.mana, counterCharmManaCost(_dummyTrajectory));
    });
  });

  group('a charm that does not match does not fire', () {
    test('a different trajectory leaves the cast alone', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _www)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells, hasLength(1));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse);
      expect(ctx.loop.lastResolvedSpells.single.counteredFormulas, 0);
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse);
    });

    test('an unattuned charm can never fire', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1')]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse);
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse);
    });

    test('a matching prefix shorter than one whole formula does not trigger',
        () async {
      // Two elements agree, three are needed (§2.2).
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'water']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse);
      expect(ctx.loop.lastResolvedSpells.single.counteredFormulas, 0);
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse);
    });
  });

  // The genuinely new engine behaviour (§2.3, Phase 2 "Partial counter"): the
  // cast DOES reach _applySpell, with a prefix of its formulas suppressed.
  group('a partial match cancels only the leading formulas', () {
    test('one formula of a two-formula spell is cancelled; the cast resolves',
        () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(
            commitmentHex: grid,
            formula: const ['fire', 'fire', 'fire', 'water', 'water', 'water'],
          ),
          targetHex: ctx.local.position,
        ),
      ));

      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.counteredFormulas, 1);
      expect(ev.wasCountered, isFalse,
          reason: 'the second formula survived, so the cast really happened — '
              'wasCountered must stay reserved for a FULL counter, which is '
              'what keeps "no wild magic on a countered cast" (A1) true');
      expect(ev.counterCharmOwnerId, 'local');
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isTrue);
    });

    test('countering continues in lockstep across formulas and stops at the '
        'first divergence', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [
        _charm('c1', trajectory: const [...
          _fff, BorderZone.water, BorderZone.water, BorderZone.water]),
      ]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(
            commitmentHex: grid,
            formula: const [
              'fire', 'fire', 'fire',
              'water', 'water', 'water',
              'earth', 'earth', 'earth',
            ],
          ),
          targetHex: ctx.local.position,
        ),
      ));

      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.counteredFormulas, 2, reason: 'both matching formulas cancelled');
      expect(ev.wasCountered, isFalse, reason: 'the earth formula survived');
    });

    test('a charm matching every formula is a FULL counter', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [
        _charm('c1', trajectory: const [...
          _fff, BorderZone.water, BorderZone.water, BorderZone.water]),
      ]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(
            commitmentHex: grid,
            formula: const ['fire', 'fire', 'fire', 'water', 'water', 'water'],
          ),
          targetHex: ctx.local.position,
        ),
      ));

      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.wasCountered, isTrue);
      expect(ev.counteredFormulas, 2);
    });
  });

  // §5 "Summons": a summon reads its element sequence as stat contributors
  // rather than as effects, so a charm cancels the leading contributors —
  // 3 per matched formula. The creature arrives smaller, or not at all.
  group('a partial counter shrinks a summon instead of cancelling an effect', () {
    test('a matched leading formula is dropped from the creature\'s sequence',
        () async {
      final grid = '0x${'11' * 32}';
      const full = ['fire', 'fire', 'fire', 'earth', 'earth', 'earth'];

      // Baseline: the same summon with no charm at all.
      final plain = _soloSetup();
      await plain.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: full, isSummon: true),
          targetHex: const HexCoord(1, 0),
        ),
      ));
      final plainMinion = plain.state.minions.single;

      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: full, isSummon: true),
          targetHex: const HexCoord(1, 0),
        ),
      ));

      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.counteredFormulas, 1);
      expect(ev.wasCountered, isFalse, reason: 'the earth formula survived');
      expect(ctx.state.minions, hasLength(1),
          reason: 'a partly-countered summon still arrives');
      expect(ctx.state.minions.single.elementSequence,
          const [BorderZone.earth, BorderZone.earth, BorderZone.earth],
          reason: 'built from the surviving three earths only');
      expect(ctx.state.minions.single.elementSequence,
          isNot(plainMinion.elementSequence));
    });

    test('a charm matching the whole sequence leaves no creature at all',
        () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(
            commitmentHex: grid,
            formula: const ['fire', 'fire', 'fire'],
            isSummon: true,
          ),
          targetHex: const HexCoord(1, 0),
        ),
      ));

      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isTrue);
      expect(ctx.state.minions, isEmpty);
    });
  });

  group('mana (§2.4)', () {
    test('a charm its owner cannot afford does not fire and is not consumed',
        () async {
      final ctx = _duoSetup(
        localAccoutrements: [_charm('c1', trajectory: _dummyTrajectory)],
      );
      ctx.local.mana = counterCharmManaCost(_dummyTrajectory) - 1;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      final dummyEvents =
          ctx.loop.lastResolvedSpells.where((e) => e.casterId == 'dummy');
      expect(dummyEvents.single.wasCountered, isFalse);
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse,
          reason: 'a charm that could not pay stays charged for a turn it can');
    });

    test('cost is triangular in formulas', () {
      expect(counterCharmManaCost(_fff), 10);
      expect(
        counterCharmManaCost(const [..._fff, ..._www]),
        30,
      );
      expect(
        counterCharmManaCost(const [..._fff, ..._www, ..._fff]),
        60,
      );
    });
  });

  group('a charm counters exactly once', () {
    test('a second matching cast resolves normally', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', trajectory: _fff)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isTrue,
          reason: 'first cast is countered');

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse,
          reason: 'the charm was already consumed by the first cast — '
              'a second matching cast is no longer countered');
    });
  });

  group('two matching charms: deterministic pick', () {
    test('ties break by the fixed scan order, not by who cast', () async {
      final ctx = _duoSetup(
        localId: 'aaa_local',
        dummyId: 'zzz_dummy',
        localAccoutrements: [_charm('c1', trajectory: _dummyTrajectory)],
        dummyAccoutrements: [_charm('c2', trajectory: _dummyTrajectory)],
      );

      // The dummy (playerId sorts LAST) casts; the local player (sorts
      // FIRST) still "wins" the charm pick even though it isn't the caster —
      // proving the pick order is fixed by avatar/accoutrement id, not by
      // who cast the spell.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      final countered = ctx.loop.lastResolvedSpells.where((e) => e.wasCountered);
      expect(countered, hasLength(1));
      expect(countered.single.counterCharmOwnerId, 'aaa_local');
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isTrue);
      expect(ctx.dummy.accoutrements.single.counterCharmRevealed, isFalse,
          reason: 'only one charm consumed per countered cast');
    });

    test('the LONGEST match wins over the scan order', () async {
      // Local sorts first but matches only one formula; the dummy's charm
      // matches both. The dummy's charm should fire.
      final ctx = _duoSetup(
        localId: 'aaa_local',
        dummyId: 'zzz_dummy',
        dummyCastFormula: const ['fire', 'fire', 'fire', 'water', 'water', 'water'],
        localAccoutrements: [_charm('c1', trajectory: _fff)],
        dummyAccoutrements: [
          _charm('c2', trajectory: const [..._fff, ..._www]),
        ],
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      final ev = ctx.loop.lastResolvedSpells
          .firstWhere((e) => e.casterId == 'zzz_dummy');
      expect(ev.counteredFormulas, 2);
      expect(ev.counterCharmOwnerId, 'zzz_dummy');
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse);
      expect(ctx.dummy.accoutrements.single.counterCharmRevealed, isTrue);
    });
  });

  // The Phase-0 gate (docs/ARTIFACT_SYSTEM_PLAN.md §2.2). Spending ANY
  // artifact drops the spender's OWN charms for that turn — not the caster's.
  // The tension is meant to be internal to the charm holder: "do I want that
  // 100 mana badly enough to open a window this turn?"
  group('a charm does not fire on a turn its owner spent an artifact', () {
    test('the cast resolves, the charm survives, and it fires the next turn',
        () async {
      final grid = '0x${'11' * 32}';
      AccoutrementKind? next = AccoutrementKind.manaGem;
      final ctx = _soloSetup(
        accoutrements: [
          _charm('c1', trajectory: _fff),
          const Accoutrement(id: 'g1', kind: AccoutrementKind.manaGem),
        ],
        declare: () => next,
      );

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse,
          reason: 'the gem burst opened this wizard’s own guard for the turn');
      final charm = ctx.local.accoutrements
          .firstWhere((a) => a.kind == AccoutrementKind.counterCharm);
      expect(charm.counterCharmRevealed, isFalse,
          reason: 'a charm that never fired is not spent');

      // Same trajectory, next turn, nothing declared: the guard is back up.
      next = null;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(commitmentHex: grid, formula: const ['fire', 'fire', 'fire']),
          targetHex: ctx.local.position,
        ),
      ));

      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isTrue);
      expect(
        ctx.local.accoutrements
            .firstWhere((a) => a.kind == AccoutrementKind.counterCharm)
            .counterCharmRevealed,
        isTrue,
      );
    });
  });

  group('the charm is part of the canonical state', () {
    BattleState stateWith({
      bool revealed = false,
      List<BorderZone>? trajectory = _fff,
    }) {
      final local = WizardAvatar(
        playerId: 'p',
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: const HexCoord(0, 0),
        teamId: 'solo',
        baseSpellRange: 6,
        accoutrements: [
          Accoutrement(
            id: 'c1',
            kind: AccoutrementKind.counterCharm,
            charmTrajectory: trajectory,
            counterCharmRevealed: revealed,
          ),
        ],
      );
      final bf = Battlefield(radius: 6);
      bf.occupancy['p'] = local.position;
      return BattleState(
        config: MatchConfig(gridRadius: 6),
        avatars: [local],
        teams: const [],
        battlefield: bf,
      );
    }

    test('two identical (unrevealed) states hash the same', () {
      expect(stateWith().toCanonicalBytes(), stateWith().toCanonicalBytes());
    });

    test('revealed vs unrevealed changes the hash', () {
      expect(stateWith().toCanonicalBytes(),
          isNot(stateWith(revealed: true).toCanonicalBytes()));
    });

    test('the trajectory changes the hash — it decides which formulas get '
        'cancelled, so a divergence here changes resolution', () {
      expect(stateWith().toCanonicalBytes(),
          isNot(stateWith(trajectory: _www).toCanonicalBytes()));
      expect(stateWith().toCanonicalBytes(),
          isNot(stateWith(trajectory: null).toCanonicalBytes()));
    });
  });
}
