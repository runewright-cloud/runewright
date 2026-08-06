// SPDX-License-Identifier: GPL-3.0-or-later
//
// pending_delayed_spell_origin_test.dart — A Mystery (delayed) spell's cast
// animation must launch from the tile the wizard was standing on when they
// cast it, not from wherever they've moved to by the time it resolves.
// PendingDelayedSpell.origin captures that cast-time tile; TurnLoop must
// thread it through to the fired SpellCastEvent.fromHex instead of reading
// the (possibly since-moved) live actor.position.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/pending_delayed_spell.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

SpellAsset _testSpell() => SpellAsset(
      id: 'mystery_test',
      createdAt: DateTime(2026),
      tier: 12,
      t: 3,
      ownerPubkeyHex: '0x${'00' * 32}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List(0),
      name: 'Mystery Test Spell',
      commitmentHex: '0x${'ab'.padLeft(64, '0')}',
      spellHashHex: '0x${'ab'.padLeft(64, '0')}',
      formula: const ['fire'],
    );

BattleState _makeState(HexCoord start) {
  final battlefield = Battlefield();
  battlefield.occupancy['player_a'] = start;

  return BattleState(
    config: const MatchConfig(),
    avatars: [
      WizardAvatar(
        playerId: 'player_a',
        ownerPubkeyHex: '0x${'00' * 32}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: start,
        teamId: 'team_a',
        baseSpellRange: 3,
      ),
    ],
    teams: [const Team(id: 'team_a', playerIds: ['player_a'])],
    battlefield: battlefield,
  );
}

void main() {
  test(
      'a fired Mystery spell reports its true cast-time tile as fromHex, '
      'not the caster\'s position at reveal time', () async {
    const castTile = HexCoord(0, 0);
    final state = _makeState(castTile);
    final loop = TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: 'player_a',
    );
    final spell = _testSpell();
    const targetTile = HexCoord(3, 0);
    const delay = 2;
    final nonce = Uint8List.fromList(List.generate(16, (i) => i));

    final commitment = await PendingDelayedSpell.commitmentHash(
      target: targetTile,
      delay: delay,
      nonce: nonce,
    );

    // Turn 1: cast the delayed Mystery spell. No movement this turn, so the
    // recorded origin should equal castTile.
    await loop.runTurn(TurnInput(
      action: MysterySpellCastAction(
        spell: spell,
        mysteryCommitment: commitment,
      ),
    ));

    expect(state.pendingDelayedSpells, hasLength(1));
    final pending = state.pendingDelayedSpells.single;
    expect(pending.origin, equals(castTile),
        reason: 'origin should be the tile the wizard cast from');

    // Turn 2: the wizard walks away from the cast tile while the spell waits.
    await loop.runTurn(TurnInput(
      action: PassAction(),
      movePath: const [HexCoord(1, 0)],
    ));
    expect(state.battlefield.occupancy['player_a'], equals(const HexCoord(1, 0)));

    // Turn 3: delay elapses; reveal and fire. The wizard has moved again,
    // landing far from castTile -- fromHex must still be castTile.
    await loop.runTurn(TurnInput(
      action: PassAction(),
      movePath: const [HexCoord(2, 0)],
      delayedSpellReveals: [
        DelayedSpellReveal(
          pendingSpellId: pending.id,
          targetTile: targetTile,
          delay: delay,
          nonce: nonce,
        ),
      ],
    ));

    expect(state.battlefield.occupancy['player_a'], equals(const HexCoord(2, 0)),
        reason: 'sanity check: the wizard really did move away before reveal');
    expect(state.pendingDelayedSpells, isEmpty,
        reason: 'the pending spell should be consumed once it fires');
    expect(loop.lastCastEvents, hasLength(1));
    final event = loop.lastCastEvents.single;
    expect(event.fromHex, equals(castTile),
        reason: 'the cast animation must launch from the true cast-time tile, '
            'not the caster\'s current (post-move) position');
    expect(event.toHex, equals(targetTile));
  });

  // PendingDelayedSpell.declaredRange is origin's twin: targeting is judged as
  // of when the cast was completed (ruling 2026-08-06), and for a Mystery
  // spell that was the declaration turn — the target tile is committed then
  // and never revisited. A range the caster gains or loses while the spell
  // sits pending must not reach back and change whether it was legal.
  group('declaredRange', () {
    test('a rangeDown landed while the spell is pending does not invalidate it',
        () async {
      final state = _makeState(const HexCoord(0, 0));
      final caster = state.avatars.single;
      final loop = TurnLoop(
        state: state,
        session: SoloBattleSession(state: state),
        localPlayerId: 'player_a',
      );
      const targetTile = HexCoord(3, 0); // exactly range 3
      const delay = 1;
      final nonce = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final commitment = await PendingDelayedSpell.commitmentHash(
        target: targetTile,
        delay: delay,
        nonce: nonce,
      );

      await loop.runTurn(TurnInput(
        action: MysterySpellCastAction(
          spell: _testSpell(),
          mysteryCommitment: commitment,
        ),
      ));
      final pending = state.pendingDelayedSpells.single;
      expect(pending.declaredRange, 3,
          reason: 'captured alongside origin, at the moment of casting');

      // Clipped AFTER declaring — the spell is already committed to its tile.
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.rangeDown,
        remainingTurns: 5,
        modifiers: const {'rangeDelta': -1},
      ));

      await loop.runTurn(TurnInput(
        action: PassAction(),
        delayedSpellReveals: [
          DelayedSpellReveal(
            pendingSpellId: pending.id,
            targetTile: targetTile,
            delay: delay,
            nonce: nonce,
          ),
        ],
      ));

      expect(loop.lastCastEvents, hasLength(1),
          reason: 'range 3 when it was declared, so it fires; judging it '
              'against the caster\'s range NOW (2) would punish the player '
              'for the passage of time');
    });

    test('a rangeDown already up when the spell is declared DOES shorten it',
        () async {
      final state = _makeState(const HexCoord(0, 0));
      state.avatars.single.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.rangeDown,
        remainingTurns: 5,
        modifiers: const {'rangeDelta': -1},
      ));
      final loop = TurnLoop(
        state: state,
        session: SoloBattleSession(state: state),
        localPlayerId: 'player_a',
      );
      const targetTile = HexCoord(3, 0); // range is 2 now — one hex too far
      const delay = 1;
      final nonce = Uint8List.fromList(List.generate(16, (i) => i + 2));
      final commitment = await PendingDelayedSpell.commitmentHash(
        target: targetTile,
        delay: delay,
        nonce: nonce,
      );

      await loop.runTurn(TurnInput(
        action: MysterySpellCastAction(
          spell: _testSpell(),
          mysteryCommitment: commitment,
        ),
      ));
      final pending = state.pendingDelayedSpells.single;
      expect(pending.declaredRange, 2);

      await loop.runTurn(TurnInput(
        action: PassAction(),
        delayedSpellReveals: [
          DelayedSpellReveal(
            pendingSpellId: pending.id,
            targetTile: targetTile,
            delay: delay,
            nonce: nonce,
          ),
        ],
      ));

      expect(loop.lastCastEvents, isEmpty,
          reason: 'a Mystery cast is not a way to launder an illegal target: '
              'the commitment hides the tile, it does not exempt it');
    });
  });
}
