// SPDX-License-Identifier: GPL-3.0-or-later
//
// dash_meditate_melee_test.dart — engine tests for the Main/Move phase
// Dash & Meditate actions and the resolution-phase melee commit-reveal
// round. Uses SoloBattleSession (no peer, no proof verification) the same
// way summon_cast_test.dart and solo_battle_session_dummy_cast_test.dart do
// — it exercises TurnLoop's real commit-reveal + resolution pipeline
// end-to-end, just without network I/O.

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

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _setup({
  HexCoord? localPos,
  HexCoord? dummyPos,
  int radius = 8,
  MeleeTargetPicker? meleePicker,
}) {
  const localId = 'local';
  const dummyId = 'dummy';
  final lp = localPos ?? const HexCoord(0, 0);
  final dp = dummyPos ?? const HexCoord(0, 5);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = lp;
  battlefield.occupancy[dummyId] = dp;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 50,
    maxMana: 100,
    position: lp,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dp,
    teamId: 'foe',
    baseSpellRange: 3,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(),
    localPlayerId: localId,
    meleeTargetPicker: meleePicker ?? (candidates) async => null,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('Dash', () {
    test('doubles movement budget for this turn only', () async {
      final ctx = _setup();
      const path = [HexCoord(1, 0), HexCoord(2, 0), HexCoord(3, 0)];

      await ctx.loop.runTurn(TurnInput(action: DashAction(), movePath: path));

      // Base speed is 2; Dash doubles it to 4, so all 3 declared steps land.
      expect(ctx.local.position, const HexCoord(3, 0));
    });

    test('movement budget reverts to normal the following turn', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: DashAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0), HexCoord(3, 0)],
      ));
      expect(ctx.local.position, const HexCoord(3, 0));

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(4, 0), HexCoord(5, 0), HexCoord(6, 0)],
      ));
      // Base budget 2: only 2 of the 3 declared steps land this time.
      expect(ctx.local.position, const HexCoord(5, 0));
    });
  });

  group('Meditate', () {
    test('main-phase Meditate restores +25 mana', () async {
      final ctx = _setup();
      final before = ctx.local.mana;
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.local.mana, before + 25);
    });

    test('move-phase Meditate restores +25 mana and forces no movement', () async {
      final ctx = _setup();
      final before = ctx.local.mana;
      final startPos = ctx.local.position;
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0)], // must be ignored
        meditateInMove: true,
      ));
      expect(ctx.local.mana, before + 25);
      expect(ctx.local.position, startPos);
    });

    test('main-phase + move-phase Meditate stack to +50', () async {
      final ctx = _setup();
      final before = ctx.local.mana;
      await ctx.loop
          .runTurn(TurnInput(action: MeditateAction(), meditateInMove: true));
      expect(ctx.local.mana, before + 50);
    });

    test('mana gain is clamped to maxMana', () async {
      final ctx = _setup();
      ctx.local.mana = ctx.local.maxMana - 10;
      await ctx.loop
          .runTurn(TurnInput(action: MeditateAction(), meditateInMove: true));
      expect(ctx.local.mana, ctx.local.maxMana);
    });
  });

  group('Melee (resolution-phase commit-reveal)', () {
    test('no prompt / no melee when there is no adjacent hostile target', () async {
      var pickerCalled = false;
      final ctx = _setup(
        // Default positions are 5 tiles apart.
        meleePicker: (candidates) async {
          pickerCalled = true;
          return candidates.first;
        },
      );
      final dummyHpBefore = ctx.dummy.hp;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(pickerCalled, isFalse);
      expect(ctx.dummy.hp, dummyHpBefore);
    });

    test('meleeing an adjacent target deals 1 damage, independent of the main action',
        () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(1, 0),
        meleePicker: (candidates) async => candidates.first,
      );
      final dummyHpBefore = ctx.dummy.hp;
      final manaBefore = ctx.local.mana;
      // Main action is Meditate, not a melee/haymaker — proves the melee
      // round is a genuinely separate decision from the main-phase action.
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.dummy.hp, dummyHpBefore - 1);
      expect(ctx.local.mana, manaBefore + 25);
    });

    test('declining the melee prompt (picker returns null) does no damage', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(1, 0),
        meleePicker: (candidates) async => null,
      );
      final dummyHpBefore = ctx.dummy.hp;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.dummy.hp, dummyHpBefore);
    });

    test('the candidate list offered to the picker is exactly the adjacent hostile tile',
        () async {
      List<HexCoord>? seenCandidates;
      final ctx = _setup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(1, 0),
        meleePicker: (candidates) async {
          seenCandidates = candidates;
          return null;
        },
      );
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(seenCandidates, [const HexCoord(1, 0)]);
    });
  });

  group('Spell resolution order (lastResolvedSpells)', () {
    test(
        'spells resolve in ascending step-count (T) order regardless of commit order',
        () async {
      const localId = 'local';
      const dummyId = 'dummy';
      const localPos = HexCoord(0, 2);
      const dummyPos = HexCoord(0, -2);

      final battlefield = Battlefield(radius: 4);
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
      );

      final state = BattleState(
        config: const MatchConfig(playerHp: 24, gridRadius: 4, maxPlayers: 2),
        avatars: [local, dummy],
        teams: [
          Team(id: 'solo', playerIds: const [localId]),
          Team(id: 'foe', playerIds: const [dummyId]),
        ],
        battlefield: battlefield,
      );

      final loop = TurnLoop(
        state: state,
        session:
            SoloBattleSession(dummyAutoCast: true, dummyCastTarget: localPos),
        localPlayerId: localId,
      );

      // The local spell has a HIGHER step count (T) than the dummy's
      // scripted cast (T=1, hard-coded in
      // SoloBattleSession._encodeDummySpellCast) — it must resolve second
      // regardless of which side's action was committed/decoded first.
      final localSpell = SpellAsset(
        id: 'local-spell',
        createdAt: DateTime.utc(2026, 7, 16),
        tier: 12,
        t: 9,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 1,
        segmentCount: 0,
        dotCount: 1,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List(0),
        name: 'Slow Blast',
        commitmentHex: '0xaaaa',
        spellHashHex: '0xaaaa2',
        formula: const ['fire', 'fire', 'fire'],
      );

      await loop.runTurn(TurnInput(
        action: SpellCastAction(spell: localSpell, targetHex: dummyPos),
      ));

      expect(loop.lastResolvedSpells, hasLength(2));
      expect(loop.lastResolvedSpells[0].casterId, dummyId,
          reason: 'the dummy\'s T=1 cast must resolve first');
      expect(loop.lastResolvedSpells[1].casterId, localId,
          reason: 'the local T=9 cast must resolve second');
    });
  });
}
