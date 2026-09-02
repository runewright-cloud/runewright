// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_resolution_test.dart — wild magic driven end-to-end through
// TurnLoop (docs/WILD_MAGIC_PLAN.md §12, "engine tests").
//
// These exercise the LOCAL cast path: a synthetic but structurally real proof
// blob goes through ProofIntake.parseOwn → TrajectoryParser → WildMagic, the
// same chain the peer path uses on certified outputs. The seed words below are
// chosen so the resulting hash lands on a specific row; they are computed
// fixtures, not arbitrary strings (see the `fires the row we expect` guards).

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/inscribe.dart' show tierForSteps;
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// The commitment every fixture spell uses: bytes 0x01…0x20. Wild Magic v2 does
/// not hash it (WILD_MAGIC_PLAN_VNEXT.md §3) — it is here because `SpellAsset`
/// and the proof ABI both need one, and it no longer participates in any seed
/// search.
final Uint8List _commitment = Uint8List.fromList(List.generate(32, (i) => i + 1));

String get _commitmentHex =>
    '0x${_commitment.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// Seed words whose Wild Magic v2 hash contains exactly one trigger pattern for
/// the fixture spells below. Recomputing these means re-running the search; the
/// first group of tests pins the effect each must produce.
///
/// What they are searched AGAINST changed with v2. The key is now
/// `(caster, certified trajectory, certified base mana cost, leyline)`, so each
/// seed is pinned to a specific fixture SPELL rather than to a commitment and a
/// T — and [_seedRow1] has to satisfy two spells at once, because the summon
/// test below fires the same row off a pure-EARTH trajectory:
///
///   caster                   0x00…00 (the solo avatar's ownerPubkeyHex)
///   certified trajectory     [fire, fire, fire] — and [earth × 3] for row 1
///   certified base mana cost 8   = round((5×1 + 1) × 1.05^5)
///   leyline                  LeylineConfig.ordinary(seed)
const _seedRow1 = 'w19'; // one run of exactly three '0' — fire AND earth
const _seedRow2 = 'w24'; // one run of exactly three '1'
const _seedRow3 = 'w459'; // one ascending run 0123
const _seedQuiet = 'w0'; // no trigger at all — for every fixture here

/// The same, for the four-element fixture spell: trajectory
/// `[fire×3, air×3, water×3, earth×3]` at certified base cost
/// 54 = round((5×1 + 1) × 1.05^20 × 1.5^3).
const _seedRow1AtT20 = 'w122';

/// A structurally real proof blob: `[4 BE field count][count × 32-byte fields]`
/// in the ABI order ProofIntake documents. Not a valid SNARK — solo mode never
/// verifies one — but byte-exact where the parser reads.
Uint8List _proofBytes({
  required int t,
  // Defaults to the tier a real inscription of this T would have used, so the
  // blob's field count matches what the verifier derives from T. A fixed 24
  // here paired with a low T describes a spell that cannot exist.
  int? tier,
  List<int> trajectory = _kFireTrajectory,
  List<int> supremeFlags = const [],
  int segmentCount = 1,
  int dotCount = 1,
}) {
  tier ??= tierForSteps(t)!;
  final count = 10 + 2 * tier;
  final out = Uint8List(4 + count * 32);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, count, Endian.big);

  void setSmall(int index, int value) {
    // Big-endian field; small integers live in the last 8 bytes.
    ByteData.sublistView(out, 4 + index * 32 + 24, 4 + index * 32 + 32)
        .setUint64(0, value, Endian.big);
  }

  void setBytes(int index, Uint8List value) {
    out.setRange(4 + index * 32, 4 + index * 32 + 32, value);
  }

  setSmall(0, t); // T
  setSmall(1, 0); // owner_pubkey
  setSmall(2, 3); // ruleset_version
  setBytes(3, _commitment); // commitment
  for (var i = 0; i < 4; i++) {
    setSmall(4 + i, 0); // border_activations
  }
  for (var g = 0; g < tier; g++) {
    setSmall(8 + g, g < trajectory.length ? trajectory[g] : 0);
  }
  for (var g = 0; g < tier; g++) {
    setSmall(8 + tier + g, g < supremeFlags.length ? supremeFlags[g] : 0);
  }
  setSmall(8 + 2 * tier, segmentCount);
  setSmall(8 + 2 * tier + 1, dotCount);
  return out;
}

/// Fire, neutral, fire, neutral, fire.
///
/// FormulaTracker only commits an activation on a LEAD CHANGE, a supreme
/// generation, or a cadence pulse — so three consecutive fire generations
/// commit only ONE activation, not three. Interleaving neutrals resets
/// `lastDominant`, making each fire a fresh lead change. Three activations =
/// one complete formula. (Element indices: 1=fire, 2=air, 3=water, 4=earth.)
const _kFireTrajectory = [1, 0, 1, 0, 1];

/// A pure-fire spell (one fire formula), so eligibility resolves to the Fire
/// column alone.
SpellAsset _fireSpell({
  int t = 5,
  List<int> trajectory = _kFireTrajectory,
  List<String> formula = const ['fire', 'fire', 'fire'],
  bool isSummon = false,
}) =>
    SpellAsset(
      id: 'wm',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      tier: tierForSteps(t)!,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 6,
      segmentCount: 1,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: _proofBytes(t: t, trajectory: trajectory),
      name: 'Wild Test',
      commitmentHex: _commitmentHex,
      spellHashHex: '0x${'b' * 64}',
      formula: formula,
      isSummon: isSummon,
      summonPersonality: 'aggressive',
    );

/// A four-element spell: three activations each of fire, air, water and earth,
/// so every element leads exactly one formula and all four tie for
/// eligibility — the "wild magic specialist" archetype that fires a whole row.
SpellAsset _balancedSpell() => _fireSpell(
      t: 20,
      trajectory: const [
        1, 0, 1, 0, 1,
        2, 0, 2, 0, 2,
        3, 0, 3, 0, 3,
        4, 0, 4, 0, 4,
      ],
      formula: const [
        'fire', 'fire', 'fire',
        'air', 'air', 'air',
        'water', 'water', 'water',
        'earth', 'earth', 'earth',
      ],
    );

typedef _Ctx = ({BattleState state, TurnLoop loop, WizardAvatar local});

_Ctx _setup({String seed = _seedRow1, int radius = 6}) {
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
  );
  bf.occupancy[id] = local.position;
  final state = BattleState(
    config: MatchConfig(
      playerHp: 24,
      gridRadius: radius,
      maxPlayers: 1,
      leyline: LeylineConfig.ordinary(seed),
    ),
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

void main() {
  group('the seed fixtures land on the rows they claim', () {
    test('row 1 seed fires Burning Hot on a pure-fire spell', () async {
      final ctx = _setup(seed: _seedRow1);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.burningHot),
      );
    });

    test('row 2 seed fires Spontaneous Combustion on a pure-fire spell', () async {
      final ctx = _setup(seed: _seedRow2);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.spontaneousCombustion),
      );
    });

    test(
        'row 2 drains the forced cast it queued: the victim really casts from '
        'hand, mid-resolution', () async {
      // The rest of the row-2 test above only proves the EVENT was emitted.
      // This one closes the loop the event opens: the applicator queues, then
      // `_fireWildMagic` awaits `_drainForcedCasts` → `ForcedCast.run` →
      // `TurnLoop.resolveForcedCast` → `_applySpell` — a re-entry that leaves
      // deterministic resolution, crosses the ForcedCastHost seam, and comes
      // back in. Nothing else in the suite covers it end to end:
      // `forced_cast_test.dart` drives the sequence against a fake host, and
      // the test above gives the wizard no hand, so every player is skipped
      // before a spell is ever chosen.
      final ctx = _setup(seed: _seedRow2);
      // A summon in the chapter, so "the forced cast resolved" is a creature
      // on the board rather than damage on a tile the roll happened to pick.
      //
      // Its commitment must DIFFER from the trigger spell's: chapter membership
      // is keyed on commitmentHex, and sharing one would make the trigger cast
      // look like a cast of chapter position 0 and empty the very hand slot the
      // forced cast reaches for. Proof bytes are empty because a forced cast
      // fires no wild magic and resolves off the wire formula.
      final forced = SpellAsset(
        id: 'forced-summon',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        tier: 12,
        t: 5,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 1,
        segmentCount: 1,
        dotCount: 1,
        initialGrid: List<int>.filled(469, 0)..[234] = 1,
        proofBytes: Uint8List(0),
        name: 'Forced Summon',
        commitmentHex: '0x${'c' * 64}',
        spellHashHex: '0x${'d' * 64}',
        formula: const ['earth', 'earth', 'earth'],
        isSummon: true,
        summonPersonality: 'aggressive',
      );
      ctx.loop
        ..localChapterSpells = [forced]
        ..localChapterCommitments = [forced.commitmentHex];

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          // Deliberately NOT the chaptered spell: the trigger cast must not
          // consume the hand slot the forced cast is going to reach for.
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));

      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.spontaneousCombustion),
      );
      expect(ctx.state.minions, isNotEmpty,
          reason: 'the forced free cast must have reached _applySpell');
      expect(ctx.state.minions.first.ownerId, 'local');
      // A8: the free cast neither builds the chain nor leaves hand state
      // spent — only the trigger cast's own chain update may show.
      expect(ctx.loop.drawScheduleFor('local')!.hand, [0],
          reason: 'a forced cast is not consumed from hand');
    });

    test('row 3 seed fires Phoenix on a pure-fire spell', () async {
      final ctx = _setup(seed: _seedRow3);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.phoenix),
      );
      // Armed for the two rounds AFTER this one (Slice 4), so it is scheduled
      // rather than active on the round that fired it.
      expect(ctx.state.wildMagic.phoenixWindows, contains('local'));
      expect(
        ctx.state.wildMagic
            .phoenixAvailableFor('local', ctx.state.turnNumber),
        isFalse,
      );
      expect(
        ctx.state.wildMagic
            .phoenixAvailableFor('local', ctx.state.turnNumber + 1),
        isTrue,
      );
    });

    test('the quiet seed fires nothing', () async {
      final ctx = _setup(seed: _seedQuiet);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.loop.lastWildMagicEvents, isEmpty);
    });
  });

  group('eligibility at the turn-loop seam', () {
    test('a four-way-balanced spell fires ALL FOUR of the row, in enum order',
        () async {
      final ctx = _setup(seed: _seedRow1AtT20);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _balancedSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect).toList(),
        [
          WildMagicEffectKind.burningHot, // fire
          WildMagicEffectKind.mountains, // earth
          WildMagicEffectKind.manaFlood, // water
          WildMagicEffectKind.zephyr, // air
        ],
      );
    });

    test('a zero-formula (void) spell fires nothing under ANY seed', () async {
      for (final seed in [_seedRow1, _seedRow2, _seedRow3]) {
        final ctx = _setup(seed: seed);
        await ctx.loop.runTurn(TurnInput(
          action: SpellCastAction(
            // All-neutral trajectory → no activations → no formulas.
            spell: _fireSpell(trajectory: const [0, 0, 0], formula: const []),
            targetHex: ctx.local.position,
          ),
        ));
        expect(ctx.loop.lastWildMagicEvents, isEmpty, reason: seed);
      }
    });
  });

  group('A1 / A2 — which casts fire wild magic', () {
    test('A2: a SUMMON cast still fires its wild magic', () async {
      // Pure EARTH, not fire: CreatureSpec gives a creature maxHp == the count
      // of earth activations, so a pure-fire summon spawns at 0 HP and is
      // reaped the same turn. Earth also puts this spell on the Mountains
      // column of the same row.
      final ctx = _setup(seed: _seedRow1);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(
            trajectory: const [4, 0, 4, 0, 4],
            formula: const ['earth', 'earth', 'earth'],
            isSummon: true,
          ),
          targetHex: ctx.local.position,
        ),
      ));
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.mountains),
      );
      expect(ctx.state.minions, isNotEmpty, reason: 'and still summons');
    });

    test('A1: a Pass fires nothing', () async {
      final ctx = _setup(seed: _seedRow1);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.lastWildMagicEvents, isEmpty);
    });

    test('events are cleared between turns', () async {
      final ctx = _setup(seed: _seedRow1);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.loop.lastWildMagicEvents, isNotEmpty);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.loop.lastWildMagicEvents, isEmpty);
    });
  });

  group('Burning Hot through a real turn', () {
    test('arms next turn and is spent when that turn passes', () async {
      final ctx = _setup(seed: _seedRow1);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      final armedTurn = ctx.state.turnNumber + 1;
      expect(ctx.state.wildMagic.spellDamageBonusFor(armedTurn), 1);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.turnNumber, armedTurn);
      expect(ctx.state.wildMagic.spellDamageBonusFor(ctx.state.turnNumber), 1);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.wildMagic.spellDamageBonusFor(ctx.state.turnNumber), 0);
    });
  });

  group('expiring terrain', () {
    test('Mountains walls expire on their scheduled turn, not before', () async {
      // Force Mountains by hand rather than hunting a seed: the applicator is
      // already covered, what matters here is TurnLoop's Phase 6 sweep.
      final ctx = _setup(seed: _seedQuiet);
      const walled = HexCoord(1, 1);
      ctx.state.tileEffects[walled] = const ImpassableTile();
      ctx.state.expiringTiles[walled] = ctx.state.turnNumber + 2;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.tileEffects.containsKey(walled), isTrue,
          reason: 'still one turn to run');

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.tileEffects.containsKey(walled), isFalse);
      expect(ctx.state.expiringTiles.containsKey(walled), isFalse);
    });

    test('permanent spell terrain is never swept', () async {
      final ctx = _setup(seed: _seedQuiet);
      const lava = HexCoord(1, 1);
      ctx.state.tileEffects[lava] = const FloorIsLava();
      for (var i = 0; i < 4; i++) {
        await ctx.loop.runTurn(TurnInput(action: PassAction()));
      }
      expect(ctx.state.tileEffects[lava], isA<FloorIsLava>());
    });
  });

  group('Statuesque latch', () {
    test('refills HP and mana at the START of each covered round', () async {
      // Armed on turn 0 → covers turns 1 and 2. The heal moved from end of
      // turn to round start in Slice 4, so the refill is already in place
      // before the round's actions run.
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0);
      ctx.local.hp = 5;
      ctx.local.mana = 0;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.wildMagic.statuesqueActiveFor('local', ctx.state.turnNumber),
        isTrue,
      );
      expect(ctx.local.hp, 24, reason: 'refilled at the start of turn 1');
      expect(ctx.local.mana, ctx.local.maxMana);

      ctx.local.hp = 3;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.hp, 24, reason: 'and again at the start of turn 2');

      // Turn 3 is past the window: swept at the round boundary, no heal.
      ctx.local.hp = 3;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.hp, 3);
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('breaks on a voluntary move', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0);
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [HexCoord(ctx.local.position.q, ctx.local.position.r - 1)],
      ));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('breaks on a cast', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0);
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('a Meditate DOES break it (Slice 4 rule change)', () async {
      // Was the loophole: under the old cast-or-move-only reading a wizard
      // could meditate to full mana every round from behind an unbreakable
      // heal. Any voluntary action but Pass now ends it.
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0);
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.state.wildMagic.statuesqueWindows, isEmpty);
    });

    test('a Pass leaves it standing', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.armStatuesque('local', triggerTurn: 0);
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(
        ctx.state.wildMagic.statuesqueActiveFor('local', ctx.state.turnNumber),
        isTrue,
      );
    });
  });

  group('Phoenix through a real turn', () {
    test('a wizard who would die rises at 1 HP, once', () async {
      final ctx = _setup(seed: _seedQuiet);
      // Armed on turn 0 → available on turns 1 and 2.
      ctx.state.wildMagic.armPhoenix('local', triggerTurn: 0);
      ctx.local.hp = 0;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.hp, 1);
      expect(ctx.state.wildMagic.phoenixWindows, isEmpty,
          reason: 'one-shot, consumed immediately');
      expect(
        ctx.loop.lastWildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.phoenix),
      );

      // Second death is final.
      ctx.local.hp = 0;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.hp, 0);
    });
  });

  group('Rippling Reflections', () {
    test('a fizzle or a double happens, and the odds drift by 10', () async {
      final ctx = _setup(seed: _seedQuiet);
      // Armed on turn 0 so its one-round window covers turn 1, the turn the
      // cast below runs on.
      ctx.state.wildMagic.armRippling(triggerTurn: 0);
      ctx.state.wildMagic.ripplingFizzlePct = 50;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.ripplingFizzlePct, anyOf(40, 60));
    });

    test('the drift clamps to [0, 100]', () async {
      for (final start in [0, 100]) {
        final ctx = _setup(seed: _seedQuiet);
        for (var i = 0; i < 5; i++) {
          // Re-armed before each turn: the window is one round long now, so a
          // five-turn drift walk has to re-arm to stay active. The percentage
          // is re-pinned after arming because a swept Rippling leaves no
          // drifted counter behind for the next arming to inherit.
          ctx.state.wildMagic
              .armRippling(triggerTurn: ctx.state.turnNumber);
          ctx.state.wildMagic.ripplingFizzlePct = start;
          await ctx.loop.runTurn(TurnInput(
            action: SpellCastAction(
              spell: _fireSpell(),
              targetHex: ctx.local.position,
            ),
          ));
          expect(
            ctx.state.wildMagic.ripplingFizzlePct,
            inInclusiveRange(0, 100),
          );
        }
      }
    });

    test('a doubled spell does NOT re-fire its wild magic (A7, invariant 7)',
        () async {
      // 0% fizzle → every cast doubles. If the doubling could reach the
      // wild-magic seam, Burning Hot would arm twice from one cast.
      final ctx = _setup(seed: _seedRow1);
      ctx.state.wildMagic.armRippling(triggerTurn: 0);
      ctx.state.wildMagic.ripplingFizzlePct = 0;
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      final burningHots = ctx.loop.lastWildMagicEvents
          .where((e) => e.effect == WildMagicEffectKind.burningHot)
          .length;
      expect(burningHots, 1);
      expect(ctx.state.wildMagic.spellDamageBonusFor(ctx.state.turnNumber + 1), 1);
    });
  });

  group('flying and terrain', () {
    test('a flying wizard walks straight over a chasm', () async {
      final ctx = _setup(seed: _seedQuiet);
      final start = ctx.local.position;
      final mid = HexCoord(start.q, start.r - 1);
      final end = HexCoord(start.q, start.r - 2);
      ctx.state.tileEffects[mid] = const ChasmTile();

      ctx.local.activeStatusEffects.add(
        StatusEffect(
          effectTypeId: StatusEffectId.flying,
          remainingTurns: 3,
          modifiers: const {},
        ),
      );

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [mid, end],
      ));
      expect(ctx.local.position, end);
    });

    test('a grounded wizard is stopped by a chasm', () async {
      final ctx = _setup(seed: _seedQuiet);
      final start = ctx.local.position;
      final mid = HexCoord(start.q, start.r - 1);
      final end = HexCoord(start.q, start.r - 2);
      ctx.state.tileEffects[mid] = const ChasmTile();

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [mid, end],
      ));
      expect(ctx.local.position, start);
    });

    test('stepping onto ice slides you until the ice runs out', () async {
      final ctx = _setup(seed: _seedQuiet);
      final start = ctx.local.position; // (0, 3)
      // Ice from r=2 up to r=0, then bare ground at r=-1.
      for (var r = 2; r >= 0; r--) {
        ctx.state.tileEffects[HexCoord(0, r)] = const IceTile();
      }

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [HexCoord(start.q, start.r - 1)], // one declared step onto ice
      ));
      // Entered (0,2) heading -r, slid free through (0,1) to (0,0), stopped
      // because (0,-1) is not ice.
      expect(ctx.local.position, const HexCoord(0, 0));
      expect(ctx.state.battlefield.occupancy['local'], const HexCoord(0, 0));
    });

    test('a flying wizard does not slide on ice', () async {
      final ctx = _setup(seed: _seedQuiet);
      final start = ctx.local.position;
      for (var r = 2; r >= 0; r--) {
        ctx.state.tileEffects[HexCoord(0, r)] = const IceTile();
      }
      ctx.local.activeStatusEffects.add(
        StatusEffect(
          effectTypeId: StatusEffectId.flying,
          remainingTurns: 3,
          modifiers: const {},
        ),
      );

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [HexCoord(start.q, start.r - 1)],
      ));
      expect(ctx.local.position, HexCoord(start.q, start.r - 1));
    });

    test('a slide stops at the board edge rather than running off', () async {
      final ctx = _setup(seed: _seedQuiet, radius: 4);
      ctx.local.position = const HexCoord(0, 3);
      ctx.state.battlefield.occupancy['local'] = ctx.local.position;
      // Ice all the way to the far edge.
      for (var r = 2; r >= -4; r--) {
        ctx.state.tileEffects[HexCoord(0, r)] = const IceTile();
      }

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [const HexCoord(0, 2)],
      ));
      expect(ctx.local.position, const HexCoord(0, -4));
      expect(ctx.state.battlefield.isInBounds(ctx.local.position), isTrue);
    });
  });

  group('state-hash coverage', () {
    test('a wild-magic firing changes the canonical bytes', () async {
      final quiet = _setup(seed: _seedQuiet);
      await quiet.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: quiet.local.position,
        ),
      ));

      final loud = _setup(seed: _seedRow1);
      await loud.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: loud.local.position,
        ),
      ));

      expect(
        loud.state.toCanonicalBytes(),
        isNot(quiet.state.toCanonicalBytes()),
      );
    });
  });
}
