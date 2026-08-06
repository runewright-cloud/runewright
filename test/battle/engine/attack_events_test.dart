// SPDX-License-Identifier: GPL-3.0-or-later
//
// attack_events_test.dart — the UI-only attack events (turn_loop.dart's
// [AttackEvent]) that let the battlefield show a blow being struck rather than
// only its consequences.
//
// Two producers, one event type:
//
//   1. Phase 4b — a wizard's haymaker. Always reach 1 (you have to be next to
//      someone to punch them), never elemental.
//   2. Phase 5b — a creature's strike. Carries the creature's own reach and
//      affinity, which is what decides whether the UI swipes a blade across
//      the target or throws something at it.
//
// The events are cosmetic and the engine never reads them back, so what's
// worth pinning here is that they're emitted *at all*, that they carry the
// right reach, and that they're not emitted for a blow that never landed.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Harness ───────────────────────────────────────────────────────────────────

/// Stat derivation (creature_spec.dart), in the terms this file needs:
/// `maxHp = earth`, `damage = fire ~/ 2`, `moveSpeed = air ~/ 2`,
/// `attackRange = water ~/ 3`, and affinity = the most-common element. Every
/// creature here needs at least one earth (a 0-HP creature is reaped the
/// instant it spawns) and three waters to get any reach at all.
SpellAsset _summonSpell(List<String> formula) => SpellAsset(
  id: 'summon-${formula.join()}',
  createdAt: DateTime.utc(2026, 8, 4),
  tier: 12,
  t: 5,
  ownerPubkeyHex: '0x${'0' * 64}',
  manaCost: 1,
  segmentCount: 0,
  dotCount: 1,
  initialGrid: List<int>.filled(469, 0)..[234] = 1,
  proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
  name: 'Test Summon',
  commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
  spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
  formula: formula,
  isSummon: true,
  summonPersonality: 'aggressive',
);

typedef _Ctx = ({
  BattleState state,
  TurnLoop loop,
  WizardAvatar local,
  WizardAvatar dummy,
  List<List<AttackEvent>> summonPlaybacks,
  List<List<AttackEvent>> meleePlaybacks,
});

_Ctx _setup({
  HexCoord localPos = const HexCoord(0, 3),
  HexCoord dummyPos = const HexCoord(0, -3),
  int radius = 6,
  HexCoord? meleeTarget,
}) {
  const localId = 'local';
  const dummyId = 'dummy';

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
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );

  final summonPlaybacks = <List<AttackEvent>>[];
  final meleePlaybacks = <List<AttackEvent>>[];
  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    onSummonMovementResolved: (moves, attacks) async =>
        summonPlaybacks.add(attacks),
    onMeleeResolved: (attacks) async => meleePlaybacks.add(attacks),
    meleeTargetPicker: (candidates) async =>
        meleeTarget != null && candidates.contains(meleeTarget)
        ? meleeTarget
        : null,
  );

  return (
    state: state,
    loop: loop,
    local: local,
    dummy: dummy,
    summonPlaybacks: summonPlaybacks,
    meleePlaybacks: meleePlaybacks,
  );
}

Future<void> _summon(_Ctx ctx, List<String> formula, HexCoord at) =>
    ctx.loop.runTurn(
      TurnInput(
        action: SpellCastAction(spell: _summonSpell(formula), targetHex: at),
      ),
    );

void main() {
  group('creature attacks', () {
    test(
      'a melee creature emits a reach-0 strike at the tile it lunges onto',
      () async {
        // move 1, no damage, range 0 (no water). Spawns adjacent to the dummy,
        // so it has its whole movement point left to spend on the lunge.
        final ctx = _setup();
        await _summon(ctx, const [
          'air',
          'air',
          'earth',
          'earth',
        ], const HexCoord(0, -2));

        final attacks = ctx.summonPlaybacks.single;
        expect(attacks, hasLength(1));
        expect(attacks.single.range, 0);
        expect(attacks.single.isMelee, isTrue);
        expect(attacks.single.to, ctx.dummy.position);
        expect(
          attacks.single.from,
          const HexCoord(0, -2),
          reason:
              'the strike is thrown from the tile the creature stands on, '
              'not from the target tile it briefly steps into',
        );
      },
    );

    test(
      'a creature with reach emits a ranged strike from where it stands',
      () async {
        // Three waters -> range 1; one air -> move 0, so it never budges and
        // strikes from its spawn tile. Reach 1 is still a melee strike.
        final ctx = _setup(localPos: const HexCoord(0, 3));
        await _summon(ctx, const [
          'water',
          'water',
          'water',
          'earth',
        ], const HexCoord(0, -2));

        final attacks = ctx.summonPlaybacks.single;
        expect(attacks, hasLength(1));
        expect(attacks.single.range, 1);
        expect(attacks.single.isMelee, isTrue);
        expect(attacks.single.from, const HexCoord(0, -2));
        expect(attacks.single.to, ctx.dummy.position);
      },
    );

    test('reach 2 is not melee, and carries the creature affinity', () async {
      // Six waters -> range 2, and water is the most-common element so the
      // creature's affinity is water: the UI colours its shot with it.
      final ctx = _setup();
      await _summon(ctx, const [
        'water',
        'water',
        'water',
        'water',
        'water',
        'water',
        'earth',
      ], const HexCoord(0, -1));

      final attacks = ctx.summonPlaybacks.single;
      expect(attacks, hasLength(1));
      expect(attacks.single.range, 2);
      expect(attacks.single.isMelee, isFalse);
      expect(attacks.single.affinity, SpellAffinity.water);
    });

    test('a creature that could not reach its target emits nothing', () async {
      // Range 0 and no movement left: it spawns two tiles out, spends its one
      // movement point closing, and arrives with nothing to strike with.
      final ctx = _setup();
      await _summon(ctx, const [
        'air',
        'air',
        'earth',
        'earth',
      ], const HexCoord(0, -1));

      expect(ctx.summonPlaybacks.single, isEmpty);
    });
  });

  group('wizard haymakers', () {
    test('a declared melee emits a reach-1, elementless strike', () async {
      final ctx = _setup(
        localPos: const HexCoord(0, -2),
        meleeTarget: const HexCoord(0, -3),
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.meleePlaybacks, hasLength(1));
      final strike = ctx.meleePlaybacks.single.single;
      expect(strike.from, const HexCoord(0, -2));
      expect(strike.to, ctx.dummy.position);
      expect(strike.range, 1);
      expect(strike.isMelee, isTrue);
      expect(
        strike.affinity,
        isNull,
        reason: 'a punch has no element for the UI to colour it with',
      );
    });

    test('no melee declared means no playback at all', () async {
      // Adjacent, so the prompt fires — but the picker declines.
      final ctx = _setup(localPos: const HexCoord(0, -2));

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.meleePlaybacks, isEmpty);
      expect(ctx.loop.lastMeleeAttackEvents, isEmpty);
    });
  });
}
