// SPDX-License-Identifier: GPL-3.0-or-later
//
// chain_discount_test.dart — Chain Casting Discount system (design doc
// §Chain Discount System, simplified 2026-07-26: single active chain, no
// hybrid discount/advancement, summons build/spend the chain like any other
// spell). Two layers, matching docs/CHAIN_DISCOUNT_PLAN.md §5:
//
//   1. Direct EffectApplicator.apply() tests (mirrors
//      effect_applicator_test.dart's style) for the Fire-Water Chain
//      Interaction effect itself — in particular that every flavor except
//      Water's transfer affects whoever occupies the TARGET tile, not
//      automatically the caster (a real pre-existing bug this pass fixed).
//   2. Full TurnLoop.runTurn() tests (mirrors dash_meditate_melee_test.dart /
//      summon_cast_test.dart's style, via SoloBattleSession — no peer, no
//      proof verification, exercises the local trusted-wire-formula path)
//      for the discount formula, advancement, regression, and the potent
//      Air-flavor chainSurcharge end-to-end.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── EffectApplicator-level helpers (direct, no TurnLoop) ──────────────────────

WizardAvatar _bareAvatar(String id, HexCoord pos) => WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: id,
      baseSpellRange: 3,
    );

BattleState _bareState(List<WizardAvatar> avatars, {int radius = 6}) {
  final battlefield = Battlefield(radius: radius);
  for (final a in avatars) {
    battlefield.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: avatars,
    teams: const [],
    battlefield: battlefield,
    tileEffects: const {},
  );
}

ApplyContext _chainCtx({
  required BattleState state,
  required WizardAvatar caster,
  required ChainInteractionEffect effect,
  required HexCoord targetTile,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: effect.affinity,
        effectKind: EffectKind.chainInteraction,
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: Random(7),
    );

// ── TurnLoop-level helpers (full commit-reveal pipeline) ──────────────────────

/// [manaCost] is the spell's *base* price — what TurnLoop charges before any
/// chain/enhancement modifier. The engine derives that from geometry rather
/// than reading `SpellAsset.manaCost` (see TurnLoop._wireBaseManaCost: the
/// stored field can't be trusted, because the opponent's device recomputes
/// the same number from the proof and the two must agree). So the fixture
/// encodes the price the way the engine reads it: `t: 0` removes the 1.05^T
/// growth and `dotCount: manaCost` makes `5*seg + dot` land exactly on it.
///
/// The one factor that can't be neutralised is 1.5^(formulas - 1) — it is
/// intrinsic to the spell now. A 2-formula (hybrid) spell therefore has a
/// base price of 1.5 × [manaCost]; [_fullPrice] computes it for assertions.
SpellAsset _spell({
  required List<String> formula,
  int manaCost = 1000,
  bool isSummon = false,
}) {
  final key = '${formula.join('-')}-$manaCost-$isSummon-${identityHashCode(formula)}';
  return SpellAsset(
    id: key,
    createdAt: DateTime.utc(2026, 7, 26),
    tier: 12,
    t: 0,
    ownerPubkeyHex: '0x${'0' * 64}',
    manaCost: manaCost,
    segmentCount: 0,
    dotCount: manaCost,
    initialGrid: List<int>.filled(469, 0)..[234] = 1,
    proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo mode
    name: 'Test Spell',
    commitmentHex: '0x${key.hashCode.toRadixString(16)}',
    spellHashHex: '0x${key.hashCode.toRadixString(16)}2',
    formula: formula,
    isSummon: isSummon,
  );
}

/// The undiscounted price of a [_spell]: base × 1.5^(complete formulas − 1).
int _fullPrice(SpellAsset spell) {
  final effectCount = max(0, spell.formula.length ~/ 3 - 1);
  return (spell.dotCount * pow(1.5, effectCount)).round();
}

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _setup({
  HexCoord? localPos,
  HexCoord? dummyPos,
  int radius = 8,
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
    mana: 9999,
    maxMana: 9999,
    position: lp,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 9999,
    maxMana: 9999,
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
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    meleeTargetPicker: (candidates) async => null,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  // ── Layer 1: EffectApplicator._applyChainInteraction directly ─────────────

  group('Chain Interaction targets the tile, not the caster', () {
    test('Fire flavor (chainFast) lands on an enemy target, not the caster', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final enemy = _bareAvatar('enemy', const HexCoord(1, 0));
      final state = _bareState([caster, enemy]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.fire,
          chainAccumulationMultiplier: 2.0,
          durationTurns: 2,
        ),
        targetTile: enemy.position,
      ));

      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainFast),
        isTrue,
        reason: 'the enemy standing on the target tile gets the buff',
      );
      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainFast),
        isFalse,
        reason: 'the caster is not auto-affected just for casting the spell',
      );
    });

    test('Earth flavor (chainSlow) lands on a self-targeted caster', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final state = _bareState([caster]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.earth,
          chainAccumulationMultiplier: 0.5,
          durationTurns: 3,
        ),
        targetTile: caster.position, // self-cast
      ));

      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainSlow),
        isTrue,
      );
    });

    test('an empty target tile is a no-op (nothing to affect)', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final state = _bareState([caster]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.fire,
          chainAccumulationMultiplier: 2.0,
          durationTurns: 2,
        ),
        targetTile: const HexCoord(3, 3), // nobody standing there
      ));

      expect(caster.activeStatusEffects, isEmpty);
    });

    test('Air base bracket clears the enemy target\'s chain, no surcharge', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final enemy = _bareAvatar('enemy', const HexCoord(1, 0));
      enemy.activeChainElement = SpellAffinity.water;
      enemy.chainLengths[SpellAffinity.water] = 10; // length 5
      final state = _bareState([caster, enemy]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.air,
          setAllChainsToNegative: true,
          negativeValue: 0, // base bracket
        ),
        targetTile: enemy.position,
      ));

      expect(enemy.activeChainElement, isNull);
      expect(enemy.chainLengths, isEmpty);
      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainSurcharge),
        isFalse,
        reason: 'only the potent bracket curses the next cast',
      );
    });

    test('Air potent bracket clears AND curses the enemy target, not the caster', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final enemy = _bareAvatar('enemy', const HexCoord(1, 0));
      enemy.activeChainElement = SpellAffinity.water;
      enemy.chainLengths[SpellAffinity.water] = 10;
      final state = _bareState([caster, enemy]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.air,
          setAllChainsToNegative: true,
          negativeValue: -1, // potent bracket
        ),
        targetTile: enemy.position,
      ));

      expect(enemy.activeChainElement, isNull);
      expect(enemy.chainLengths, isEmpty);
      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainSurcharge),
        isTrue,
      );
      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainSurcharge),
        isFalse,
        reason: 'the curse lands on the target tile\'s occupant, not the caster',
      );
    });

    test('Water flavor: caster gains the target\'s chain state (half-credit units)', () {
      final caster = _bareAvatar('caster', const HexCoord(0, 0));
      final enemy = _bareAvatar('enemy', const HexCoord(1, 0));
      enemy.activeChainElement = SpellAffinity.fire;
      enemy.chainLengths[SpellAffinity.fire] = 6; // length 3
      final state = _bareState([caster, enemy]);

      EffectApplicator.apply(_chainCtx(
        state: state,
        caster: caster,
        effect: const ChainInteractionEffect(
          affinity: SpellAffinity.water,
          transferChainFromTarget: true,
          chainTransferBonus: 1, // potent: +1 whole cast = +2 half-credits
        ),
        targetTile: enemy.position,
      ));

      expect(caster.activeChainElement, SpellAffinity.fire);
      expect(caster.chainLengths[SpellAffinity.fire], 8); // 6 + 2 half-credits
      expect(caster.chainLength, 4);
    });
  });

  // ── Layer 2: full TurnLoop.runTurn() ───────────────────────────────────────

  group('Discount formula (design doc table, pre-cast chain length)', () {
    test('pure repeated casts follow 0.9^L exactly, at lengths 0..10', () async {
      final ctx = _setup();
      const baseCost = 1000;
      final spell = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: baseCost);

      // discount uses the length BEFORE this cast: cast i (0-indexed) prices
      // at length i, so 11 casts exercise lengths 0 (full price) through 10
      // (65% off) inclusive. Expected cost is computed via the same formula
      // the implementation uses (0.9^L, ceil'd) rather than hand-typed
      // decimals -- 0.9 has no exact binary representation, so pow(0.9, n)
      // can round a hair above or below the decimal value, occasionally
      // shifting which integer ceil() lands on (e.g. length 3 ceils to 730,
      // not the naively-expected 729). The oracle here is "matches the
      // documented formula," not "matches hand arithmetic".
      for (var length = 0; length <= 10; length++) {
        final before = ctx.local.mana;
        await ctx.loop.runTurn(TurnInput(
          action: SpellCastAction(spell: spell, targetHex: ctx.dummy.position),
        ));
        final paid = before - ctx.local.mana;
        final expected = (baseCost * pow(0.9, length)).ceil();
        expect(paid, expected, reason: 'cast #${length + 1} (pre-cast length $length)');
      }
      // Sanity-check against the design doc's literal table entries (~10%,
      // ~27%, ~41%, ~65% discount at lengths 1, 3, 5, 10 respectively).
      expect((baseCost * pow(0.9, 1)).ceil(), closeTo(900, 5));
      expect((baseCost * pow(0.9, 3)).ceil(), closeTo(729, 5));
      expect((baseCost * pow(0.9, 5)).ceil(), closeTo(590, 5));
      expect((baseCost * pow(0.9, 10)).ceil(), closeTo(349, 5));

      expect(ctx.local.activeChainElement, SpellAffinity.fire);
      expect(ctx.local.chainLength, 11);
    });
  });

  group('Hybrid casts', () {
    test('a hybrid spell pays full price and breaks an existing chain', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);
      final hybrid = _spell(
        formula: const ['fire', 'fire', 'fire', 'water', 'fire', 'fire'],
        manaCost: 1000,
      );

      // Build a fire chain to length 2 first.
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 2);

      final before = ctx.local.mana;
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: hybrid, targetHex: ctx.dummy.position)));
      // Its own full price, not pureFire's: the hybrid carries two complete
      // formulas, so its base is 1.5x. The point under test is that no chain
      // discount is applied to it, despite the length-2 fire chain.
      expect(before - ctx.local.mana, _fullPrice(hybrid),
          reason: 'hybrid spells are never discount-eligible');
      expect(ctx.local.activeChainElement, isNull);
      expect(ctx.local.chainLengths, isEmpty);
    });
  });

  group('Off-affinity pure cast', () {
    test('switching elements breaks the old chain and starts fresh at full price', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);
      final pureWater = _spell(formula: const ['water', 'water', 'water'], manaCost: 1000);

      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 2);

      final before = ctx.local.mana;
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureWater, targetHex: ctx.dummy.position)));
      expect(before - ctx.local.mana, 1000, reason: 'no discount on the switching cast itself');
      expect(ctx.local.activeChainElement, SpellAffinity.water);
      expect(ctx.local.chainLength, 1);
    });
  });

  group('Regression (inaction)', () {
    test('Pass/Dash/Meditate regress the chain by 2, floored at 0', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);

      // Build to length 3.
      for (var i = 0; i < 3; i++) {
        await ctx.loop.runTurn(
            TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      }
      expect(ctx.local.chainLength, 3);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.chainLength, 1, reason: 'regress by 2: 3 -> 1');

      await ctx.loop.runTurn(TurnInput(action: DashAction(), movePath: const []));
      expect(ctx.local.activeChainElement, isNull, reason: 'floors at 0, not negative');
      expect(ctx.local.chainLengths, isEmpty);

      // Regressing an already-empty chain is a no-op, not an error.
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.local.activeChainElement, isNull);
    });
  });

  group('chainFast / chainSlow accumulation rate', () {
    test('chainFast doubles the advancement of the next matching cast', () async {
      final ctx = _setup();
      // Self-targeted Fire-flavor Chain Interaction: establishes a fire
      // chain at length 1 (first cast always starts fresh) AND buffs the
      // caster's own accumulation rate for their next matching cast.
      final fireFlavor =
          _spell(formula: const ['fire', 'fire', 'water'], manaCost: 1);
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);

      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: fireFlavor, targetHex: ctx.local.position)));
      expect(ctx.local.activeChainElement, SpellAffinity.fire);
      expect(ctx.local.chainLength, 1);
      expect(
        ctx.local.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainFast),
        isTrue,
      );

      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 3, reason: '2 credits base doubled to 4 -> length (2+4)/2=3');
    });

    test('chainSlow halves the advancement, so it takes two casts to gain one length', () async {
      final ctx = _setup();
      final earthFlavor =
          _spell(formula: const ['earth', 'fire', 'water'], manaCost: 1);
      final pureEarth = _spell(formula: const ['earth', 'earth', 'earth'], manaCost: 1000);

      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: earthFlavor, targetHex: ctx.local.position)));
      expect(ctx.local.chainLength, 1);
      expect(
        ctx.local.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.chainSlow),
        isTrue,
      );

      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: pureEarth, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 1,
          reason: '2 credits + 1 (half-rate) = 3 credits, still length 1');

      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: pureEarth, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 2, reason: '3 + 1 = 4 credits -> length 2');
    });
  });

  group('Air-flavor chainSurcharge end-to-end', () {
    test(
        'a self-targeted potent cast curses the caster\'s own next cast, '
        'then chain building resumes normally', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);
      final potentAir =
          _spell(formula: const ['air', 'fire', 'water'], manaCost: 1);

      // Build an unrelated fire chain first, to prove the surcharge
      // overrides whatever chain is active rather than reading it.
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 2);

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: potentAir,
          targetHex: ctx.local.position, // self-cast
          isPotent: true,
        ),
      ));
      // The cast clears the chain the effect touched, then this same cast's
      // own pureAffinity (air) establishes a fresh chain (R3/R4's normal
      // advancement runs on every cast, independent of the curse).
      expect(ctx.local.activeChainElement, SpellAffinity.air);
      expect(ctx.local.chainLength, 1);
      expect(
        ctx.local.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.chainSurcharge),
        isTrue,
      );

      final before = ctx.local.mana;
      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      final paid = before - ctx.local.mana;
      // Charged as if chain length were -1, REGARDLESS of the real (air,
      // length 1) chain active at cast time: ceil(1000 / 0.9) = 1112.
      expect(paid, 1112);
      expect(
        ctx.local.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.chainSurcharge),
        isFalse,
        reason: 'consumed by the cast it curses',
      );
      // Chain building resumes normally starting with this same cast: it's
      // pure fire, so it breaks the (air) chain and starts a fresh fire one.
      expect(ctx.local.activeChainElement, SpellAffinity.fire);
      expect(ctx.local.chainLength, 1);
    });
  });

  group('Summon casts build/spend the chain like any other spell', () {
    test('a single-affinity summon advances a matching chain', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);
      // 3 fire activations, no residual -- CreatureSpec.fromElements derives
      // a pure fire affinity (design doc Summons: most-common element).
      final fireSummon = _spell(
        formula: const ['fire', 'fire', 'fire'],
        manaCost: 1000,
        isSummon: true,
      );

      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 1);

      final before = ctx.local.mana;
      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: fireSummon, targetHex: ctx.local.position)));
      expect(before - ctx.local.mana, 900, reason: 'summon takes the discount too (length 1 -> 0.9x)');
      expect(ctx.local.activeChainElement, SpellAffinity.fire);
      expect(ctx.local.chainLength, 2);
    });

    test('a summon of a different element breaks an existing chain', () async {
      final ctx = _setup();
      final pureFire = _spell(formula: const ['fire', 'fire', 'fire'], manaCost: 1000);
      final waterSummon = _spell(
        formula: const ['water', 'water', 'water'],
        manaCost: 1000,
        isSummon: true,
      );

      await ctx.loop
          .runTurn(TurnInput(action: SpellCastAction(spell: pureFire, targetHex: ctx.dummy.position)));
      expect(ctx.local.chainLength, 1);

      await ctx.loop.runTurn(
          TurnInput(action: SpellCastAction(spell: waterSummon, targetHex: ctx.local.position)));
      expect(ctx.local.activeChainElement, SpellAffinity.water);
      expect(ctx.local.chainLength, 1);
    });
  });
}
