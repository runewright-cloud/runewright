// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_numerical_effects_test.dart — the four Aetherial Armor bonuses, and
// the two live keywords, driven through the real engine
// (docs/AETHERIAL_ARMOR.md §9 and §11).
//
//   Fire    -> wizard melee damage    (DeterministicResolution.applyHaymaker)
//   Air     -> movement               (TurnLoop's per-turn `speeds` snapshot)
//   Water   -> spell range            (cast enforcement, Turbulent, forced cast)
//   Earth   -> starting HP            (and the Statuesque full-heal)
//   Charger -> hasHaymakerDistanceBonus, i.e. the EXISTING Air-haymaker
//              distance mechanic, unchanged                      (engine v7)
//   Muddy   -> hasHaymakerSlow, i.e. the EXISTING Earth-haymaker slow,
//              unchanged                                         (engine v7)
//
// The keyword groups are written as paired comparisons against the pre-armor
// STATUS source wherever a number could be argued about: the claim slice 6
// makes is not "Charger deals +1" but "Charger buys into the mechanic that
// already existed", and only an equality against that mechanic can say so.
//
// Every test asserts a BEHAVIOURAL difference — damage actually dealt, tiles
// actually walked, where a spell actually landed — never that a field is set.
// That is the lesson `penetrating` taught by shipping broken with a green test
// that only checked a flag (see line_of_sight_test.dart's header).
//
// Deliberately driven through TurnLoop rather than by calling the resolution
// seam directly wherever a snapshot sits between the stat and its use: the
// movement budget is the obvious one, since `resolveAvatarMovement` falls back
// to `av.effectiveMoveSpeed` when the map has no entry, and a test that took
// the fallback would pass while the real path stayed unarmored.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/forced_cast.dart' show ForcedCastPick;
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../models/certified_armor_fixture.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _kStartHp = 24;

WizardAvatar _avatar(
  String id,
  HexCoord pos, {
  required String teamId,
  CertifiedArmor? armor,
  int range = 3,
  int hp = _kStartHp,
}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: hp + (armor?.armorHpBonus ?? 0),
      mana: 1000,
      maxMana: 1000,
      position: pos,
      teamId: teamId,
      baseSpellRange: range,
      armor: armor,
    );

BattleState _state(
  List<WizardAvatar> avatars, {
  int radius = 8,
  String communitySeed = '',
}) {
  final bf = Battlefield(radius: radius);
  for (final a in avatars) {
    bf.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(
      playerHp: _kStartHp,
      gridRadius: radius,
      maxPlayers: 2,
      leyline: LeylineConfig.ordinary(communitySeed),
    ),
    avatars: List.of(avatars),
    teams: [
      for (final id in {for (final a in avatars) a.teamId})
        Team(
          id: id,
          playerIds: [
            for (final a in avatars)
              if (a.teamId == id) a.playerId,
          ],
        ),
    ],
    battlefield: bf,
  );
}

TurnLoop _loop(
  BattleState state,
  String localId, {
  MeleeTargetPicker? meleePicker,
}) =>
    TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: localId,
      meleeTargetPicker: meleePicker ?? ((_) async => null),
    );

/// A one-formula Firey Blast: radius 0, so "where did it land" is exactly
/// "who lost hp", and its damage is a pure spell number the melee bonus must
/// not touch.
SpellAsset _blast() => SpellAsset(
      id: 'sp_blast',
      createdAt: DateTime.utc(2026, 8, 26),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: 'FireyBlast',
      commitmentHex: '0x${'a' * 64}',
      spellHashHex: '0x${'b' * 64}',
      formula: const ['fire', 'fire', 'fire'],
    );

/// Earth-Earth-Water: a tile modification, so the tile it lands on is directly
/// readable out of `state.tileEffects`.
SpellAsset _tileSpell() => SpellAsset(
      id: 'sp_tile',
      createdAt: DateTime.utc(2026, 8, 26),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([4, 5, 6]),
      name: 'ShiftingGround',
      commitmentHex: '0x${'c' * 64}',
      spellHashHex: '0x${'d' * 64}',
      formula: const ['earth', 'earth', 'water'],
    );

Minion _minion(String ownerId, String teamId, HexCoord pos, {int damage = 1}) =>
    Minion(
      id: 'm_$ownerId',
      ownerId: ownerId,
      teamId: teamId,
      position: pos,
      affinity: SpellAffinity.earth,
      stats: MinionStats(
        maxHp: 20,
        damage: damage,
        moveSpeed: 1,
        attackRange: 1,
      ),
      elementSequence: const [],
    );

/// One melee punch at [target], through the real Phase-4b commit-reveal round.
Future<void> _punch(
  BattleState state,
  String actorId,
  HexCoord target, {
  TurnInput? input,
}) async {
  final loop = _loop(state, actorId, meleePicker: (_) async => target);
  await loop.runTurn(input ?? TurnInput(action: PassAction()));
}

void main() {
  // ── Fire ────────────────────────────────────────────────────────────────

  group('Fire -> wizard melee', () {
    test('an unarmored haymaker still deals exactly 1', () async {
      final actor = _avatar('actor', const HexCoord(0, 0), teamId: 'a');
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
      await _punch(_state([actor, foe]), 'actor', foe.position);
      expect(foe.hp, _kStartHp - 1,
          reason: 'the baseline the bonus is measured against');
    });

    test('a Fire armor raises wizard-vs-wizard punch damage', () async {
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kFireArmorCodes));
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
      expect(actor.armor!.meleeBonus, 1);

      await _punch(_state([actor, foe]), 'actor', foe.position);
      expect(foe.hp, _kStartHp - 2, reason: '1 base + 1 armor');
    });

    test('a Fire armor raises wizard-vs-minion punch damage', () async {
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kFireArmorCodes));
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: 'b');
      final state = _state([actor, foe]);
      final target = _minion('foe', 'b', const HexCoord(1, 0));
      state.minions.add(target);

      await _punch(state, 'actor', target.position);
      expect(target.hp, 20 - 2,
          reason: 'the bonus rides the punch, not the victim\'s type');
    });

    test('the bonus is applied exactly once, not per pass over the tile',
        () async {
      // A +3 melee bonus makes a double application (7) unmistakable against
      // the correct 4 — a +1 bonus could not tell 2 from 3 as clearly.
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('F', 18)));
      expect(actor.armor!.meleeBonus, 3);
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');

      await _punch(_state([actor, foe]), 'actor', foe.position);
      expect(foe.hp, _kStartHp - 4, reason: '1 base + 3 armor, once');
    });

    test('a punch that hits a wizard AND a minion pays the bonus to each once',
        () async {
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kFireArmorCodes));
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
      final state = _state([actor, foe]);
      final stacked = _minion('foe', 'b', const HexCoord(1, 0));
      state.minions.add(stacked);

      await _punch(state, 'actor', const HexCoord(1, 0));
      expect(foe.hp, _kStartHp - 2);
      expect(stacked.hp, 20 - 2);
    });

    test('it does NOT change spell damage', () async {
      Future<int> damageDealt({CertifiedArmor? armor}) async {
        final caster =
            _avatar('caster', const HexCoord(0, 0), teamId: 'a', armor: armor);
        final foe = _avatar('foe', const HexCoord(2, 0), teamId: 'b');
        final state = _state([caster, foe]);
        await _loop(state, 'caster').runTurn(TurnInput(
          action: SpellCastAction(spell: _blast(), targetHex: foe.position),
        ));
        return _kStartHp - foe.hp;
      }

      final bare = await damageDealt();
      final armored = await damageDealt(armor: armorOf(runOfCode('F', 18)));
      expect(bare, greaterThan(0), reason: 'fixture check: the blast lands');
      expect(armored, bare,
          reason: 'Fire armor is a MELEE bonus; a +3 melee armor that also '
              'moved spell damage would be a second, undeclared effect');
    });

    test('it does NOT change a minion-initiated attack', () async {
      // The armor is on the minion's OWNER. A creature strike is priced from
      // its own stats in _creatureAttack and never touches the wearer's melee.
      final owner = _avatar('owner', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('F', 18)));
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: 'b');
      final state = _state([owner, foe]);
      state.minions.add(_minion('owner', 'a', const HexCoord(3, 0)));

      await _loop(state, 'owner').runTurn(TurnInput(action: PassAction()));
      expect(foe.hp, _kStartHp - 1,
          reason: 'the creature\'s own damage stat, unmodified by its owner\'s '
              'armor');
    });

    test('it composes additively with the Haymaker distance bonus', () async {
      Future<int> punchDamage({CertifiedArmor? armor}) async {
        final actor = _avatar('actor', const HexCoord(0, 0),
            teamId: 'a', armor: armor);
        actor.activeStatusEffects.add(StatusEffect(
          effectTypeId: StatusEffectId.haymakerDistanceBonus,
          remainingTurns: 5,
        ));
        final foe = _avatar('foe', const HexCoord(5, 0), teamId: 'b');
        final state = _state([actor, foe]);
        // Dash for a budget of 4, walk all four tiles, end adjacent to the
        // foe: tilesMoved 4 -> +2 damage from the Air haymaker.
        await _punch(
          state,
          'actor',
          foe.position,
          input: TurnInput(action: DashAction(), movePath: const [
            HexCoord(1, 0),
            HexCoord(2, 0),
            HexCoord(3, 0),
            HexCoord(4, 0),
          ]),
        );
        expect(actor.position, const HexCoord(4, 0),
            reason: 'fixture check: the walk landed adjacent to the foe');
        return _kStartHp - foe.hp;
      }

      expect(await punchDamage(), 3, reason: '1 base + 2 distance');
      expect(await punchDamage(armor: armorOf(kFireArmorCodes)), 4,
          reason: '1 base + 1 armor + 2 distance — the two bonuses add, '
              'neither replaces the other');
    });
  });

  // ── Air ─────────────────────────────────────────────────────────────────

  group('Air -> movement', () {
    test('an unarmored wizard still walks 2 tiles of a longer path', () async {
      final av = _avatar('w', const HexCoord(0, 0), teamId: 'a');
      final state = _state([av]);
      await _loop(state, 'w').runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0), HexCoord(3, 0)],
      ));
      expect(av.position, const HexCoord(2, 0), reason: 'base budget 2');
    });

    test('base 2 + Air 1 walks 3', () async {
      // Drives the whole TurnLoop turn, so the budget consumed is the one out
      // of TurnLoop's `speeds` map — not resolveAvatarMovement's
      // `?? av.effectiveMoveSpeed` fallback, which a direct call would take.
      final av = _avatar('w', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kAirArmorCodes));
      expect(av.effectiveMoveSpeed, 3);
      final state = _state([av]);

      await _loop(state, 'w').runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0), HexCoord(3, 0)],
      ));
      expect(av.position, const HexCoord(3, 0),
          reason: 'the third step is the armor\'s');
    });

    test('the fourth step is still refused — the budget is 3, not unlimited',
        () async {
      final av = _avatar('w', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kAirArmorCodes));
      final state = _state([av]);
      await _loop(state, 'w').runTurn(TurnInput(
        action: PassAction(),
        movePath: const [
          HexCoord(1, 0),
          HexCoord(2, 0),
          HexCoord(3, 0),
          HexCoord(4, 0),
        ],
      ));
      expect(av.position, const HexCoord(3, 0));
    });

    test('base 2 + Air 1 dashes 6', () async {
      // The intended composition: the snapshot is
      // `effectiveMoveSpeed * (isDashing ? 2 : 1)`, so the armor is doubled
      // along with the rest of the stat. (2 + 1) * 2 = 6, not 2 * 2 + 1 = 5.
      final av = _avatar('w', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kAirArmorCodes));
      final state = _state([av]);

      await _loop(state, 'w').runTurn(TurnInput(
        action: DashAction(),
        movePath: const [
          HexCoord(1, 0),
          HexCoord(2, 0),
          HexCoord(3, 0),
          HexCoord(4, 0),
          HexCoord(5, 0),
          HexCoord(6, 0),
        ],
      ));
      expect(av.position, const HexCoord(6, 0));
    });

    test('an unarmored dash is still 4, so the 6 above is the armor', () async {
      final av = _avatar('w', const HexCoord(0, 0), teamId: 'a');
      final state = _state([av]);
      await _loop(state, 'w').runTurn(TurnInput(
        action: DashAction(),
        movePath: const [
          HexCoord(1, 0),
          HexCoord(2, 0),
          HexCoord(3, 0),
          HexCoord(4, 0),
          HexCoord(5, 0),
          HexCoord(6, 0),
        ],
      ));
      expect(av.position, const HexCoord(4, 0));
    });
  });

  // ── Water ───────────────────────────────────────────────────────────────

  group('Water -> spell range', () {
    test('a cast beyond base range lands once a Water armor is worn', () async {
      final caster = _avatar('caster', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('W', 10)));
      expect(caster.effectiveSpellRange, 5, reason: 'base 3 + armor 2');
      final foe = _avatar('foe', const HexCoord(5, 0), teamId: 'b');
      final state = _state([caster, foe]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: foe.position),
      ));
      expect(foe.hp, lessThan(_kStartHp),
          reason: 'engine-side range enforcement must read the armored stat');
    });

    test('without the armor the same cast is refused', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      final foe = _avatar('foe', const HexCoord(5, 0), teamId: 'b');
      final state = _state([caster, foe]);

      final loop = _loop(state, 'caster');
      await loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: foe.position),
      ));
      expect(foe.hp, _kStartHp);
      expect(loop.lastResolvedSpells, isEmpty);
    });

    test('one tile past the armored reach still fails', () async {
      final caster = _avatar('caster', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('W', 10)));
      final foe = _avatar('foe', const HexCoord(6, 0), teamId: 'b');
      final state = _state([caster, foe]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: foe.position),
      ));
      expect(foe.hp, _kStartHp,
          reason: 'the armor moves the boundary, it does not remove it');
    });

    test('Turbulent scatters over the ARMORED range', () async {
      // Watery Inertia re-rolls the distance 1..effectiveSpellRange. A Water
      // armor therefore widens the scatter — intended, and deliberately not
      // special-cased.
      final caster = _avatar('caster', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('W', 10)));
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.turbulent,
        remainingTurns: 40,
      ));
      final state = _state([caster, _avatar('foe', const HexCoord(1, 0), teamId: 'b')]);
      final loop = _loop(state, 'caster');

      final distances = <int>{};
      for (var i = 0; i < 25; i++) {
        await loop.runTurn(TurnInput(
          action: SpellCastAction(
            spell: _blast(),
            targetHex: const HexCoord(1, 0),
          ),
        ));
        distances.add(hexDistance(
          const HexCoord(0, 0),
          loop.lastResolvedSpells.single.targetHex,
        ));
      }

      expect(distances.every((d) => d >= 1 && d <= 5), isTrue,
          reason: 'the roll is 1..effectiveSpellRange = 5, got $distances');
      expect(distances.any((d) => d > 3), isTrue,
          reason: 'a roll past the unarmored range 3 is the armor showing up '
              'in the scatter, got $distances');
    });

    test('an unarmored turbulent caster never scatters past 3', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: 'a');
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.turbulent,
        remainingTurns: 40,
      ));
      final state = _state([caster, _avatar('foe', const HexCoord(1, 0), teamId: 'b')]);
      final loop = _loop(state, 'caster');

      final distances = <int>{};
      for (var i = 0; i < 25; i++) {
        await loop.runTurn(TurnInput(
          action: SpellCastAction(
            spell: _blast(),
            targetHex: const HexCoord(1, 0),
          ),
        ));
        distances.add(hexDistance(
          const HexCoord(0, 0),
          loop.lastResolvedSpells.single.targetHex,
        ));
      }
      expect(distances.every((d) => d <= 3), isTrue,
          reason: 'fixture check for the test above: got $distances');
    });

    test('a forced cast\'s random target pool widens with the armor', () async {
      // TurnLoop._randomTileInRange builds its candidate list from
      // effectiveSpellRange, so wild magic's forced cast can land further out
      // on an armored wizard. Also intended, also not special-cased.
      Future<Set<int>> forcedTargetDistances({CertifiedArmor? armor}) async {
        final av = _avatar('w', const HexCoord(0, 0), teamId: 'a', armor: armor);
        final state = _state([av]);
        final loop = _loop(state, 'w');
        final distances = <int>{};
        for (var seed = 0; seed < 40; seed++) {
          state.tileEffects.clear();
          await loop.resolveForcedCast(
            ForcedCastPick(playerId: 'w', position: 0, spell: _tileSpell()),
            HashRng(Uint8List(32)..[0] = seed),
          );
          for (final hex in state.tileEffects.keys) {
            distances.add(hexDistance(const HexCoord(0, 0), hex));
          }
        }
        return distances;
      }

      final bare = await forcedTargetDistances();
      final armored =
          await forcedTargetDistances(armor: armorOf(runOfCode('W', 10)));

      expect(bare, isNotEmpty, reason: 'fixture check: the forced cast lands');
      expect(bare.every((d) => d <= 3), isTrue,
          reason: 'unarmored, the pool is 1..3, got $bare');
      expect(armored.any((d) => d > 3), isTrue,
          reason: 'armored, the pool reaches 5 — got $armored');
    });
  });

  // ── Earth ───────────────────────────────────────────────────────────────

  group('Earth -> HP', () {
    test('Statuesque restores config.playerHp + armorHpBonus', () async {
      final av = _avatar('w', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('E', 12)));
      expect(av.armor!.armorHpBonus, 8);
      expect(av.hp, _kStartHp + 8, reason: 'fixture check: started full');

      final state = _state([av]);
      // Armed on turn 0 so the window covers turns 1-2; the heal now lands at
      // the START of turn 1 rather than at end of turn (Slice 4).
      state.wildMagic.armStatuesque('w', triggerTurn: 0);
      av.hp = 3;

      await _loop(state, 'w').runTurn(TurnInput(action: PassAction()));

      expect(state.wildMagic.statuesqueActiveFor('w', state.turnNumber), isTrue);
      expect(av.hp, _kStartHp + 8,
          reason: 'restoring to the bare config value would make Statuesque a '
              'silent downgrade for an armored wizard');
    });

    test('Statuesque on an unarmored wizard is unchanged', () async {
      final av = _avatar('w', const HexCoord(0, 0), teamId: 'a');
      final state = _state([av]);
      state.wildMagic.armStatuesque('w', triggerTurn: 0);
      av.hp = 3;

      await _loop(state, 'w').runTurn(TurnInput(action: PassAction()));
      expect(av.hp, _kStartHp);
    });

    test('HP above the starting pool is not clamped back down', () async {
      // Ordinary wizard healing is uncapped and stays that way: this slice
      // introduces no max-HP and no healing cap, so a wizard sitting above
      // their starting total must still be there after a full turn.
      final av = _avatar('w', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(runOfCode('E', 12)));
      final state = _state([av]);
      av.hp = _kStartHp + 8 + 10;

      await _loop(state, 'w').runTurn(TurnInput(action: PassAction()));
      expect(av.hp, _kStartHp + 8 + 10);
    });

    test('an unarmored wizard over their pool is likewise untouched', () async {
      final av = _avatar('w', const HexCoord(0, 0), teamId: 'a');
      final state = _state([av]);
      av.hp = _kStartHp + 10;

      await _loop(state, 'w').runTurn(TurnInput(action: PassAction()));
      expect(av.hp, _kStartHp + 10);
    });

    test('damage flows through one pool — there is no separate armor HP',
        () async {
      final actor = _avatar('actor', const HexCoord(0, 0), teamId: 'a');
      final foe = _avatar('foe', const HexCoord(1, 0),
          teamId: 'b', armor: armorOf(runOfCode('E', 12)));
      expect(foe.hp, _kStartHp + 8);

      await _punch(_state([actor, foe]), 'actor', foe.position);
      expect(foe.hp, _kStartHp + 8 - 1,
          reason: 'one pool: the punch comes off the total, not off an armor '
              'bar that would have to be tracked separately');
      expect(foe.armor!.armorHpBonus, 8,
          reason: 'and the armor still reports what it granted — provenance '
              'survives damage');
    });
  });

  // ── Charger and Muddy (engine v7) ───────────────────────────────────────
  //
  // Two certified keywords stop being inert. Neither adds a mechanic: each ORs
  // itself into an existing `WizardAvatar` capability getter, and everything
  // downstream is the haymaker code that was already there.

  group('Charger -> the existing haymaker distance bonus', () {
    /// One punch thrown from (0,0) at a foe [foeAt] tiles away along +q, after
    /// walking [path]. Returns the damage the foe took.
    Future<int> punchAfterWalk({
      required int foeAt,
      List<HexCoord> path = const [],
      CertifiedArmor? armor,
      bool dash = false,
      bool statusBonus = false,
    }) async {
      final actor =
          _avatar('actor', const HexCoord(0, 0), teamId: 'a', armor: armor);
      if (statusBonus) {
        actor.activeStatusEffects.add(StatusEffect(
          effectTypeId: StatusEffectId.haymakerDistanceBonus,
          remainingTurns: 5,
        ));
      }
      final foe = _avatar('foe', HexCoord(foeAt, 0), teamId: 'b');
      final state = _state([actor, foe]);
      await _punch(
        state,
        'actor',
        foe.position,
        input: TurnInput(
          action: dash ? DashAction() : PassAction(),
          movePath: path,
        ),
      );
      expect(hexDistance(actor.position, foe.position), 1,
          reason: 'fixture check: the walk has to end adjacent or no punch '
              'lands at all');
      return _kStartHp - foe.hp;
    }

    const twoTiles = [HexCoord(1, 0), HexCoord(2, 0)];

    test('a Charger armor earns the distance bonus a bare wizard does not',
        () async {
      expect(
        await punchAfterWalk(foeAt: 3, path: twoTiles),
        1,
        reason: 'no armor, no status: base melee only',
      );
      expect(
        await punchAfterWalk(foeAt: 3, path: twoTiles, armor: armorOf('FAFA')),
        2,
        reason: '1 base + 2 tiles walked ~/ 2',
      );
    });

    test('an armor without Charger earns nothing extra', () async {
      // Four airs: a real armor, a real (movement) bonus, no Charger. It walks
      // the same two tiles and must punch for the bare 1.
      final armor = armorOf(kAirArmorCodes);
      expect(armor.hasKeyword(ArmorKeyword.charger), isFalse);
      expect(await punchAfterWalk(foeAt: 3, path: twoTiles, armor: armor), 1);
    });

    test('it is the SAME number the status source produces', () async {
      // The claim of the whole slice, in one assertion: armor Charger and the
      // pre-existing buff are indistinguishable downstream, so the mechanic
      // was reused rather than reimplemented.
      for (final walk in [
        (foeAt: 2, path: <HexCoord>[HexCoord(1, 0)]), // 1 tile  -> +0
        (foeAt: 3, path: twoTiles), // 2 tiles -> +1
      ]) {
        final viaStatus = await punchAfterWalk(
            foeAt: walk.foeAt, path: walk.path, statusBonus: true);
        final viaArmor = await punchAfterWalk(
            foeAt: walk.foeAt, path: walk.path, armor: armorOf('FAFA'));
        expect(viaArmor, viaStatus,
            reason: '${walk.path.length} tiles: armor and status must agree');
      }
    });

    test('it rounds down, exactly as the existing mechanic does', () async {
      // Three tiles is 1, not 2 and not 1.5 — `tilesMoved ~/ 2` unchanged.
      expect(
        await punchAfterWalk(
          foeAt: 4,
          path: const [HexCoord(1, 0), HexCoord(2, 0), HexCoord(3, 0)],
          armor: armorOf('FAFA'),
          dash: true,
        ),
        2,
        reason: '1 base + (3 ~/ 2)',
      );
    });

    test('zero movement adds nothing', () async {
      expect(
        await punchAfterWalk(foeAt: 1, armor: armorOf('FAFA')),
        1,
        reason: 'standing still is 0 tiles walked, so the punch is bare',
      );
    });

    test('a Dash means a longer walk, not a different rule', () async {
      // Dash doubles the budget; the distance bonus reads the resulting path
      // length like any other. Four tiles under a dash is +2, and the status
      // source produces the same 4-tile answer.
      expect(
        await punchAfterWalk(
          foeAt: 5,
          path: const [
            HexCoord(1, 0),
            HexCoord(2, 0),
            HexCoord(3, 0),
            HexCoord(4, 0),
          ],
          armor: armorOf('FAFA'),
          dash: true,
        ),
        3,
        reason: '1 base + (4 ~/ 2)',
      );
      expect(
        await punchAfterWalk(
          foeAt: 5,
          path: const [
            HexCoord(1, 0),
            HexCoord(2, 0),
            HexCoord(3, 0),
            HexCoord(4, 0),
          ],
          statusBonus: true,
          dash: true,
        ),
        3,
        reason: 'and the status source says the same, as it must',
      );
    });

    test('armor and status together apply it once, not twice', () async {
      expect(
        await punchAfterWalk(
          foeAt: 3,
          path: twoTiles,
          armor: armorOf('FAFA'),
          statusBonus: true,
        ),
        2,
        reason: 'two sources feed one boolean; the bonus is added once',
      );
    });

    test('it composes with the Fire melee bonus, each exactly once', () async {
      // FAFAFF: four fires (melee +1) and the Charger pattern, no Cleave (that
      // needs four CONSECUTIVE fires).
      final armor = armorOf('FAFAFF');
      expect(armor.meleeBonus, 1);
      expect(armor.keywords, {ArmorKeyword.charger});
      expect(
        await punchAfterWalk(foeAt: 3, path: twoTiles, armor: armor),
        3,
        reason: '1 base + 1 Fire + 1 distance — three contributions, one each',
      );
    });

    test('it reaches a minion punch through the same one path', () async {
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf('FAFA'));
      final foe = _avatar('foe', const HexCoord(6, 0), teamId: 'b');
      final minion = _minion('foe', 'b', const HexCoord(3, 0));
      final state = _state([actor, foe])..minions.add(minion);
      await _punch(
        state,
        'actor',
        minion.position,
        input: TurnInput(action: PassAction(), movePath: twoTiles),
      );
      expect(minion.hp, minion.stats.maxHp - 2,
          reason: '1 base + 1 distance, on the same single melee path');
    });
  });

  group('Muddy -> the existing haymaker slow', () {
    /// One punch at an adjacent foe. Returns the foe, for status inspection.
    Future<WizardAvatar> punchFoe({
      CertifiedArmor? armor,
      bool statusSlow = false,
    }) async {
      final actor =
          _avatar('actor', const HexCoord(0, 0), teamId: 'a', armor: armor);
      if (statusSlow) {
        actor.activeStatusEffects.add(StatusEffect(
          effectTypeId: StatusEffectId.haymakerSlow,
          remainingTurns: 5,
        ));
      }
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
      await _punch(_state([actor, foe]), 'actor', foe.position);
      return foe;
    }

    List<StatusEffect> slows(WizardAvatar av) => av.activeStatusEffects
        .where((fx) => fx.effectTypeId == StatusEffectId.speedDown)
        .toList();

    test('a Muddy armor slows what it punches', () async {
      final foe = await punchFoe(armor: armorOf('WEWE'));
      expect(slows(foe), hasLength(1));
      expect(foe.effectiveMoveSpeed, 1,
          reason: 'base 2 with a -1 slow on it');
    });

    test('an armor without Muddy slows nothing', () async {
      final foe = await punchFoe(armor: armorOf(kFireArmorCodes));
      expect(slows(foe), isEmpty);
      expect(foe.effectiveMoveSpeed, 2);
    });

    test('an unarmored punch still slows nothing', () async {
      expect(slows(await punchFoe()), isEmpty);
    });

    test('magnitude and duration are the status source\'s, unchanged',
        () async {
      final viaStatus = slows(await punchFoe(statusSlow: true)).single;
      final viaArmor = slows(await punchFoe(armor: armorOf('WEWE'))).single;
      expect(viaArmor.modifiers, viaStatus.modifiers,
          reason: 'same speedDelta — the armor reuses the mechanic');
      expect(viaArmor.remainingTurns, viaStatus.remainingTurns,
          reason: 'same duration, ticked the same way by the same turn');
      expect(viaArmor.effectTypeId, StatusEffectId.speedDown,
          reason: 'and the same status representation, not an armor-specific '
              'one');
    });

    test('armor and status together apply it once, not twice', () async {
      final both =
          slows(await punchFoe(armor: armorOf('WEWE'), statusSlow: true));
      final armorOnly = slows(await punchFoe(armor: armorOf('WEWE')));
      expect(both, hasLength(1),
          reason: 'one boolean, one branch, one application');
      expect(both.single.remainingTurns, armorOnly.single.remainingTurns);
      expect(both.single.modifiers, armorOnly.single.modifiers);
    });

    test('Fire + Charger + Muddy coexist without interfering', () async {
      // FAFAFFWEWE: fire 4 (melee +1), the Charger and Muddy patterns, two
      // earths (HP +2) that ride along because Muddy's pattern contains them.
      final armor = armorOf('FAFAFFWEWE');
      expect(armor.meleeBonus, 1);
      expect(armor.keywords, {ArmorKeyword.charger, ArmorKeyword.muddy});

      final actor =
          _avatar('actor', const HexCoord(0, 0), teamId: 'a', armor: armor);
      final foe = _avatar('foe', const HexCoord(3, 0), teamId: 'b');
      final state = _state([actor, foe]);
      await _punch(
        state,
        'actor',
        foe.position,
        input: TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
        ),
      );
      expect(_kStartHp - foe.hp, 3,
          reason: '1 base + 1 Fire + 1 distance, each exactly once');
      expect(
        foe.activeStatusEffects
            .where((fx) => fx.effectTypeId == StatusEffectId.speedDown),
        hasLength(1),
        reason: 'and Muddy lands its one slow alongside them',
      );
      expect(actor.hp, _kStartHp + 2,
          reason: 'the two earths in WEWE are a real Earth rung, untouched by '
              'any of this');
    });
  });

  group('the other five keywords stay inert in the engine', () {
    test('Cleave does not splash to a second body on the punched tile',
        () async {
      // Two bodies adjacent to the actor: the punched foe, and a minion on a
      // DIFFERENT tile. Cleave, if it were live, is the keyword that would
      // reach the second one.
      final actor = _avatar('actor', const HexCoord(0, 0),
          teamId: 'a', armor: armorOf(kFireArmorCodes));
      expect(actor.armor!.hasKeyword(ArmorKeyword.cleave), isTrue);
      final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
      final bystander = _minion('foe', 'b', const HexCoord(0, 1));
      final state = _state([actor, foe])..minions.add(bystander);

      await _punch(state, 'actor', foe.position);

      expect(_kStartHp - foe.hp, 2, reason: '1 base + 1 Fire, nothing more');
      expect(bystander.hp, bystander.stats.maxHp,
          reason: 'the neighbouring body is untouched — Cleave is inert');
    });

    test('Flying, Molten Carapace, Stealthy and Anchored change no punch',
        () async {
      // Each of these armors reaches no ladder rung (or only rungs unrelated
      // to melee), so if any of them were wired to anything the punch or the
      // target's status list would move. Neither may.
      for (final codes in const ['AAAA', 'EFEF', 'AWAW', 'EEEE']) {
        final actor =
            _avatar('actor', const HexCoord(0, 0), teamId: 'a', armor: armorOf(codes));
        final foe = _avatar('foe', const HexCoord(1, 0), teamId: 'b');
        final before = foe.hp;
        await _punch(_state([actor, foe]), 'actor', foe.position);
        expect(before - foe.hp, 1 + actor.armor!.meleeBonus,
            reason: '$codes: base melee plus its Fire rung and nothing else');
        expect(foe.activeStatusEffects, isEmpty,
            reason: '$codes: no keyword may leave a status behind');
        expect(actor.isFlying, isFalse, reason: '$codes: still not flying');
      }
    });
  });
}
