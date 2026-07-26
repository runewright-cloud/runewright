// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm_test.dart — Phase 2 of the counter-charm plan: the
// battle-engine nullification (see CLAUDE.md counter-charm plan / Phase 1
// UI work in library_screen.dart / chapter_asset.dart). A bound counter
// charm nullifies the FIRST cast of its bound grid commitment by ANY wizard
// in the match — including its own owner (settled decision: "any source",
// not opponent-only) — then is consumed (never triggers again).
//
// Covers:
//   - a charm counters its OWNER's own cast (the distinguishing "any
//     source" behavior — see TurnLoop._findCounteringCharm's doc comment);
//   - a charm counters an OPPONENT's cast of the same grid (the traditional
//     case);
//   - a charm bound to a DIFFERENT grid does not fire — no false positives;
//   - once consumed, a second cast of the same grid resolves normally —
//     the core "first time only" invariant (CLAUDE.md §10/§11 pairing: this
//     is the negative vector for "counters exactly once");
//   - when two charms are bound to the same grid, the pick is deterministic
//     (avatar playerId, then accoutrement id) — the property that keeps two
//     devices resolving the same turn in lockstep agreement;
//   - counterCharmRevealed is part of BattleState.toCanonicalBytes(), so the
//     outcome is visible to the lockstep hash check, not just local state.

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

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Mirrors SoloBattleSession._dummyCommitment (private to that file): 32
/// bytes of 0xFE, hex-encoded the same way TurnLoop._decodeAction builds
/// commitmentHex from raw commit bytes. This is the grid the dummy "casts"
/// under dummyAutoCast — never a real Poseidon2 commitment, just a fixed
/// sentinel solo mode never proof-verifies.
final String _kDummyCommitmentHex = '0x${'fe' * 32}';

SpellAsset _spell({
  required String commitmentHex,
  String name = 'Test Spell',
  int t = 1,
  List<String> formula = const ['fire'],
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
    );

/// Single-avatar solo setup (no peer) — for a caster countering their own cast.
({BattleState state, TurnLoop loop, WizardAvatar local}) _soloSetup({
  List<Accoutrement> accoutrements = const [],
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
    ),
    localPlayerId: localId,
  );
  return (state: state, loop: loop, local: local, dummy: dummy);
}

Accoutrement _charm(String id, {String? target}) => Accoutrement(
      id: id,
      kind: AccoutrementKind.counterCharm,
      targetCommitmentHex: target,
    );

void main() {
  group('a charm counters its own owner\'s cast', () {
    test('the spell never resolves and the charm is consumed', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', target: grid)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _spell(commitmentHex: grid), targetHex: ctx.local.position),
      ));

      expect(ctx.loop.lastResolvedSpells, hasLength(1));
      final ev = ctx.loop.lastResolvedSpells.single;
      expect(ev.wasCountered, isTrue);
      expect(ev.casterId, 'local');
      expect(ev.counterCharmOwnerId, 'local');

      final charm = ctx.local.accoutrements.single;
      expect(charm.counterCharmRevealed, isTrue);
    });
  });

  group('a charm counters an opponent\'s cast', () {
    test('the dummy\'s scripted cast is nullified by the local player\'s charm', () async {
      final ctx = _duoSetup(
        localAccoutrements: [_charm('c1', target: _kDummyCommitmentHex)],
      );

      // Local passes; the dummy auto-casts _kDummyCommitmentHex at localPos.
      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      final dummyEvents = ctx.loop.lastResolvedSpells.where((e) => e.casterId == 'dummy');
      expect(dummyEvents, hasLength(1));
      expect(dummyEvents.single.wasCountered, isTrue);
      expect(dummyEvents.single.counterCharmOwnerId, 'local');
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isTrue);
    });
  });

  group('a charm bound to a different grid does not fire', () {
    test('the cast resolves normally and the charm stays unbound-armed', () async {
      final grid = '0x${'11' * 32}';
      final otherGrid = '0x${'22' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', target: otherGrid)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _spell(commitmentHex: grid), targetHex: ctx.local.position),
      ));

      expect(ctx.loop.lastResolvedSpells, hasLength(1));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse);
      expect(ctx.local.accoutrements.single.counterCharmRevealed, isFalse);
    });
  });

  group('a charm counters exactly once', () {
    test('a second cast of the same grid resolves normally', () async {
      final grid = '0x${'11' * 32}';
      final ctx = _soloSetup(accoutrements: [_charm('c1', target: grid)]);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _spell(commitmentHex: grid), targetHex: ctx.local.position),
      ));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isTrue,
          reason: 'first cast is countered');

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _spell(commitmentHex: grid), targetHex: ctx.local.position),
      ));
      expect(ctx.loop.lastResolvedSpells.single.wasCountered, isFalse,
          reason: 'the charm was already consumed by the first cast — '
              'second cast of the same grid is no longer countered');
    });
  });

  group('two charms bound to the same grid: deterministic pick', () {
    test('the lower playerId\'s charm is chosen regardless of who casts', () async {
      final ctx = _duoSetup(
        localId: 'aaa_local',
        dummyId: 'zzz_dummy',
        localAccoutrements: [_charm('c1', target: _kDummyCommitmentHex)],
        dummyAccoutrements: [_charm('c2', target: _kDummyCommitmentHex)],
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
  });

  group('counterCharmRevealed is part of the canonical state', () {
    BattleState stateWith(bool revealed) {
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
            targetCommitmentHex: '0x${'11' * 32}',
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
      expect(stateWith(false).toCanonicalBytes(), stateWith(false).toCanonicalBytes());
    });

    test('revealed vs unrevealed changes the hash', () {
      expect(stateWith(false).toCanonicalBytes(), isNot(stateWith(true).toCanonicalBytes()));
    });
  });
}
