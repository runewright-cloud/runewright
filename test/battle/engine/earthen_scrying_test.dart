// SPDX-License-Identifier: GPL-3.0-or-later
//
// earthen_scrying_test.dart — Divination (Air-Water), Earth flavor: the
// Earthen Scrying Pool. Formula ['earth', 'air', 'water'].
//
// The flavor's ability was rewritten (2026-08-03) once the Illusions mechanic
// settled: "Identify Illusions and See Through Clouds" is now two concrete,
// engine-side effects carried by StatusEffectId.scryingSight —
//
//   1. Immunity to the clouds' adjacent-only targeting restriction, in BOTH
//      orders: a cloud already on the bearer (the lingering
//      cloudBoundTargeting status) is stripped on cast, and a cloud that
//      arrives afterwards can neither impose the status nor bind the cast
//      (TurnLoop._cloudBoundToAdjacent).
//   2. An ENEMY illusion adjacent to the bearer is dispelled on sight — all
//      four Illusions flavors: wizard decoys, illusory creatures (the Fire
//      clone and the Air convert), and terrain copies.
//
// Applicator-level tests below pin the grant + dispel rules directly; the
// TurnLoop group pins the two paths that only exist in the loop (the
// DustCloud tick and cast-range enforcement) end to end through a real turn.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/illusion.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _us = 'us';
const _them = 'them';

WizardAvatar _avatar(String id, HexCoord pos, {required String teamId}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: teamId,
      baseSpellRange: 3,
    );

BattleState _state(
  List<WizardAvatar> avatars, {
  int radius = 6,
  List<WizardIllusionSet>? wizardIllusions,
  Map<HexCoord, TileEffect>? tileEffects,
  Map<HexCoord, String>? illusionTerrainTiles,
  List<Minion>? minions,
  List<CloudObject>? clouds,
}) {
  final battlefield = Battlefield(radius: radius);
  for (final a in avatars) {
    battlefield.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: avatars,
    teams: [
      Team(id: _us, playerIds: [
        for (final a in avatars.where((a) => a.teamId == _us)) a.playerId,
      ]),
      Team(id: _them, playerIds: [
        for (final a in avatars.where((a) => a.teamId == _them)) a.playerId,
      ]),
    ],
    battlefield: battlefield,
    wizardIllusions: wizardIllusions,
    tileEffects: tileEffects,
    illusionTerrainTiles: illusionTerrainTiles,
    minions: minions,
    clouds: clouds,
  );
}

/// Casts an Earthen Scrying Pool at [targetTile] on behalf of [caster].
void _castScrying(
  BattleState state,
  WizardAvatar caster,
  HexCoord targetTile, {
  int durationTurns = 2,
}) {
  EffectApplicator.apply(ApplyContext(
    descriptor: EffectDescriptor(
      affinity: SpellAffinity.earth,
      effectKind: EffectKind.divination,
      spellEffect: DivinationEffect(
        affinity: SpellAffinity.earth,
        durationTurns: durationTurns,
        grantsScryingSight: true,
      ),
    ),
    targetTile: targetTile,
    caster: caster,
    state: state,
    rng: Random(7),
  ));
}

bool _hasScryingSight(WizardAvatar av) => av.activeStatusEffects
    .any((fx) => fx.effectTypeId == StatusEffectId.scryingSight);

Minion _minion(
  String id, {
  required String teamId,
  required HexCoord position,
  bool isIllusion = false,
}) =>
    Minion(
      id: id,
      ownerId: teamId,
      teamId: teamId,
      position: position,
      affinity: SpellAffinity.fire,
      stats: const MinionStats(
          maxHp: 6, damage: 1, moveSpeed: 1, attackRange: 1),
      elementSequence: const [],
      isIllusion: isIllusion,
    );

// ── TurnLoop harness (SoloBattleSession, mirrors multiplier_cycles_test) ──────

SpellAsset _spell(List<String> formula) => SpellAsset(
      id: 'scry-${formula.join()}',
      createdAt: DateTime.utc(2026, 8, 3),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo
      name: 'Test ${formula.join('-')}',
      commitmentHex: '0x${formula.join().hashCode.toRadixString(16)}',
      spellHashHex: '0x${formula.join().hashCode.toRadixString(16)}2',
      formula: formula,
    );

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
    _loopSetup({
  required HexCoord localPos,
  required HexCoord dummyPos,
  int radius = 6,
  List<WizardIllusionSet>? wizardIllusions,
  List<CloudObject>? clouds,
}) {
  const localId = 'local';
  const dummyId = 'dummy';

  final local = _avatar(localId, localPos, teamId: 'solo');
  final dummy = _avatar(dummyId, dummyPos, teamId: 'foe');

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      const Team(id: 'solo', playerIds: [localId]),
      const Team(id: 'foe', playerIds: [dummyId]),
    ],
    battlefield: battlefield,
    wizardIllusions: wizardIllusions,
    clouds: clouds,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
  );
  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  // ── The grant ─────────────────────────────────────────────────────────────

  group('Earthen Scrying Pool grants scryingSight', () {
    test('to whoever occupies the target tile, not automatically the caster',
        () {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: _us);
      final ally = _avatar('ally', const HexCoord(1, 0), teamId: _us);
      final state = _state([caster, ally]);

      _castScrying(state, caster, ally.position);

      expect(_hasScryingSight(ally), isTrue);
      expect(_hasScryingSight(caster), isFalse,
          reason: 'the effect targets the tile — self-buffing means targeting '
              'your own tile');
    });

    test('for durationTurns (2, or 3 when Potent)', () {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: _us);
      final state = _state([caster]);

      _castScrying(state, caster, caster.position, durationTurns: 3);

      final fx = caster.activeStatusEffects
          .firstWhere((f) => f.effectTypeId == StatusEffectId.scryingSight);
      expect(fx.remainingTurns, 3);
    });
  });

  // ── Cloud immunity, cloud-first ───────────────────────────────────────────

  group('cloud-blindness immunity holds when the cloud came FIRST', () {
    test('a lingering cloudBoundTargeting status is stripped on cast', () {
      final caster = _avatar('caster', const HexCoord(0, 0), teamId: _us);
      caster.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.cloudBoundTargeting,
        remainingTurns: 2,
      ));
      final state = _state([caster]);

      _castScrying(state, caster, caster.position);

      expect(
        caster.activeStatusEffects
            .where((fx) =>
                fx.effectTypeId == StatusEffectId.cloudBoundTargeting),
        isEmpty,
        reason: 'the dust restriction the bearer walked in with must not '
            'outlive the scrying that made them immune to it',
      );
      expect(_hasScryingSight(caster), isTrue);
    });
  });

  // ── Dispel: wizard decoys ─────────────────────────────────────────────────

  group('dispel on sight — wizard decoys (Water flavor)', () {
    test('adjacent enemy decoys pop; distant ones and allied ones do not', () {
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: _them);
      final ally = _avatar('ally', const HexCoord(0, 3), teamId: _us);
      final state = _state(
        [scryer, foe, ally],
        wizardIllusions: [
          WizardIllusionSet(ownerId: 'foe', decoyPositions: [
            const HexCoord(1, 0), // adjacent to the scryer — dispelled
            const HexCoord(4, 1), // far away — survives
          ]),
          WizardIllusionSet(ownerId: 'ally', decoyPositions: [
            const HexCoord(0, 1), // adjacent, but same team — survives
          ]),
        ],
      );

      _castScrying(state, scryer, scryer.position);

      final foeSet =
          state.wizardIllusions.firstWhere((s) => s.ownerId == 'foe');
      expect(foeSet.decoyPositions, [const HexCoord(4, 1)]);
      final allySet =
          state.wizardIllusions.firstWhere((s) => s.ownerId == 'ally');
      expect(allySet.decoyPositions, [const HexCoord(0, 1)],
          reason: 'a scryer never dispels their own side\'s illusions');
    });

    test('an enemy set whose last decoy is dispelled is dropped entirely', () {
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: _them);
      final state = _state(
        [scryer, foe],
        wizardIllusions: [
          WizardIllusionSet(
              ownerId: 'foe', decoyPositions: [const HexCoord(1, 0)]),
        ],
      );

      _castScrying(state, scryer, scryer.position);

      expect(state.wizardIllusions, isEmpty);
    });
  });

  // ── Dispel: illusory creatures ────────────────────────────────────────────

  group('dispel on sight — illusory creatures (Fire clone / Air convert)', () {
    test('an adjacent enemy illusion is unmade; a real one is untouched', () {
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final state = _state(
        [scryer],
        minions: [
          _minion('phantom',
              teamId: _them, position: const HexCoord(1, 0), isIllusion: true),
          _minion('real', teamId: _them, position: const HexCoord(0, 1)),
          _minion('ours',
              teamId: _us, position: const HexCoord(-1, 0), isIllusion: true),
          _minion('far',
              teamId: _them, position: const HexCoord(3, 0), isIllusion: true),
        ],
      );

      _castScrying(state, scryer, scryer.position);

      expect(state.minions.map((m) => m.id), unorderedEquals(['real', 'ours', 'far']),
          reason: 'only the adjacent ENEMY illusion is dispelled');
    });

    test('a dispelled illusion is removed outright, not killed', () {
      // Removal (rather than hp = 0) is what keeps Minion.onDeath — Morphic\'s
      // reform into a real creature — from firing for something that was
      // never real.
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final phantom = _minion('phantom',
          teamId: _them, position: const HexCoord(1, 0), isIllusion: true);
      final state = _state([scryer], minions: [phantom]);

      _castScrying(state, scryer, scryer.position);

      expect(state.minions, isEmpty);
      expect(phantom.hp, greaterThan(0),
          reason: 'it left the field intact — no death was ever processed');
    });
  });

  // ── Dispel: terrain copies ────────────────────────────────────────────────

  group('dispel on sight — terrain copies (Earth flavor)', () {
    test('an adjacent enemy copy and the terrain it faked both go', () {
      const enemyCopy = HexCoord(1, 0); // adjacent to the scryer
      const allyCopy = HexCoord(0, 1); // adjacent, but ours
      const farCopy = HexCoord(3, 0);
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: _them);
      final ally = _avatar('ally', const HexCoord(0, 4), teamId: _us);
      final state = _state(
        [scryer, foe, ally],
        tileEffects: {
          enemyCopy: const ImpassableTile(),
          allyCopy: const ImpassableTile(),
          farCopy: const ImpassableTile(),
        },
        illusionTerrainTiles: {
          enemyCopy: 'foe',
          allyCopy: 'ally',
          farCopy: 'foe',
        },
      );

      _castScrying(state, scryer, scryer.position);

      expect(state.illusionTerrainTiles.keys, unorderedEquals([allyCopy, farCopy]));
      expect(state.tileEffects.containsKey(enemyCopy), isFalse,
          reason: 'the fake terrain goes with the illusion that projected it');
      expect(state.tileEffects.containsKey(allyCopy), isTrue);
      expect(state.tileEffects.containsKey(farCopy), isTrue);
    });
  });

  // ── The sweep itself ──────────────────────────────────────────────────────

  group('dispelIllusionsNearScryers', () {
    test('is a no-op when nobody has scrying sight', () {
      final av = _avatar('av', const HexCoord(0, 0), teamId: _us);
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: _them);
      final state = _state(
        [av, foe],
        wizardIllusions: [
          WizardIllusionSet(
              ownerId: 'foe', decoyPositions: [const HexCoord(1, 0)]),
        ],
      );

      EffectApplicator.dispelIllusionsNearScryers(state);

      expect(state.wizardIllusions.single.decoyPositions, hasLength(1));
    });

    test('ignores a dormant scrying sight (Water-Air statusDormant)', () {
      final scryer = _avatar('scryer', const HexCoord(0, 0), teamId: _us);
      final foe = _avatar('foe', const HexCoord(4, 0), teamId: _them);
      scryer.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.scryingSight,
        remainingTurns: 2,
        isDormant: true,
      ));
      final state = _state(
        [scryer, foe],
        wizardIllusions: [
          WizardIllusionSet(
              ownerId: 'foe', decoyPositions: [const HexCoord(1, 0)]),
        ],
      );

      EffectApplicator.dispelIllusionsNearScryers(state);

      expect(state.wizardIllusions.single.decoyPositions, hasLength(1));
    });
  });

  // ── End to end through a real turn ────────────────────────────────────────

  group('through TurnLoop', () {
    test('the real formula ["earth","air","water"] grants the status', () async {
      // Pins the recipe wiring, not just the applicator: effect_resolver maps
      // (earth, air+water) to a grantsScryingSight DivinationEffect.
      final ctx = _loopSetup(
        localPos: const HexCoord(0, 1),
        dummyPos: const HexCoord(0, -1),
      );

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(['earth', 'air', 'water']),
          targetHex: ctx.local.position, // self-target
          isPotent: true, // 3 turns, so it survives this turn's status tick
        ),
      ));

      expect(_hasScryingSight(ctx.local), isTrue);
      expect(_hasScryingSight(ctx.dummy), isFalse);
    });

    test('walking up to an enemy decoy dispels it mid-turn', () async {
      final ctx = _loopSetup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(4, 0),
        wizardIllusions: [
          WizardIllusionSet(
              ownerId: 'dummy', decoyPositions: [const HexCoord(3, 0)]),
        ],
      );
      ctx.local.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.scryingSight,
        remainingTurns: 3,
      ));

      // Base move speed 2: (0,0) -> (2,0), ending adjacent to the decoy.
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
      ));

      expect(ctx.local.position, const HexCoord(2, 0));
      expect(ctx.state.wizardIllusions, isEmpty,
          reason: 'the decoy is dispelled the moment the scryer arrives');
    });

    test('a Dust Cloud cannot stick its restriction on a scryer', () async {
      // Cloud centred on (1,0), radius 1: the local avatar starts inside it
      // and walks out, which is exactly when DustCloud lingers its
      // adjacent-only restriction on whoever left.
      Future<WizardAvatar> runLeavingDustCloud({required bool scrying}) async {
        final ctx = _loopSetup(
          localPos: const HexCoord(1, 0),
          dummyPos: const HexCoord(-4, 0),
          clouds: [
            CloudObject(
              id: 'dust',
              position: const HexCoord(1, 0),
              kind: const DustCloud(),
              remainingTurns: 5,
              ownerId: 'dummy',
            ),
          ],
        );
        if (scrying) {
          ctx.local.activeStatusEffects.add(StatusEffect(
            effectTypeId: StatusEffectId.scryingSight,
            remainingTurns: 3,
          ));
        }
        await ctx.loop.runTurn(TurnInput(
          action: PassAction(),
          movePath: const [HexCoord(2, 0), HexCoord(3, 0)],
        ));
        return ctx.local;
      }

      final unprotected = await runLeavingDustCloud(scrying: false);
      expect(
        unprotected.activeStatusEffects
            .map((fx) => fx.effectTypeId)
            .toList(),
        contains(StatusEffectId.cloudBoundTargeting),
        reason: 'control: leaving a Dust Cloud normally lingers the restriction',
      );

      final protected = await runLeavingDustCloud(scrying: true);
      expect(
        protected.activeStatusEffects.map((fx) => fx.effectTypeId).toList(),
        isNot(contains(StatusEffectId.cloudBoundTargeting)),
      );
    });

    test('a scryer standing in a cloud still casts at full range', () async {
      // Without the immunity, standing in a cloud clamps casting to adjacent
      // tiles and a longer cast fizzles outright (mana already spent).
      Future<int> damageDealtAtRange({required bool scrying}) async {
        final ctx = _loopSetup(
          localPos: const HexCoord(0, 1),
          dummyPos: const HexCoord(0, -1), // distance 2
          clouds: [
            CloudObject(
              id: 'fog',
              position: const HexCoord(0, 1),
              kind: const WaterCloud(),
              remainingTurns: 5,
              ownerId: 'dummy',
              radius: 1,
            ),
          ],
        );
        if (scrying) {
          ctx.local.activeStatusEffects.add(StatusEffect(
            effectTypeId: StatusEffectId.scryingSight,
            remainingTurns: 3,
          ));
        }
        final startHp = ctx.dummy.hp;
        await ctx.loop.runTurn(TurnInput(
          action: SpellCastAction(
            spell: _spell(['earth', 'fire', 'fire']), // traversal damage, 2
            targetHex: ctx.dummy.position,
          ),
        ));
        return startHp - ctx.dummy.hp;
      }

      expect(await damageDealtAtRange(scrying: false), 0,
          reason: 'control: the cloud binds the cast to adjacent tiles, so a '
              'range-2 cast fizzles');
      expect(await damageDealtAtRange(scrying: true), 2,
          reason: 'the Earthen Scrying Pool bearer sees through the cloud');
    });
  });
}
