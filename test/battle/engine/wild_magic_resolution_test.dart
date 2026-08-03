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
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// The commitment every fixture spell uses: bytes 0x01…0x20. The seed words
/// below were searched against exactly this commitment at the T each fixture
/// spell declares — change T and they stop landing on their row.
final Uint8List _commitment = Uint8List.fromList(List.generate(32, (i) => i + 1));

String get _commitmentHex =>
    '0x${_commitment.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

/// Seed words whose hash of (_commitment, T=5, word) contains exactly one
/// trigger pattern. Recomputing these means re-running the search; the first
/// group of tests pins the effect each must produce.
const _seedRow1 = 'w35'; // one run of exactly three '0'
const _seedRow2 = 'w34'; // one run of exactly three '1'
const _seedRow3 = 'w23'; // one ascending run 0123
const _seedQuiet = 'w0'; // no trigger at all — at T=5 and at T=20

/// The same, for the four-element fixture spell at T=20.
const _seedRow1AtT20 = 'w281';

/// A structurally real proof blob: `[4 BE field count][count × 32-byte fields]`
/// in the ABI order ProofIntake documents. Not a valid SNARK — solo mode never
/// verifies one — but byte-exact where the parser reads.
Uint8List _proofBytes({
  required int t,
  int tier = 24,
  List<int> trajectory = _kFireTrajectory,
  List<int> supremeFlags = const [],
  int segmentCount = 1,
  int dotCount = 1,
}) {
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
      tier: 24,
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
      communitySeed: seed,
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
      expect(ctx.state.wildMagic.phoenixPlayerIds, contains('local'));
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
    test('promotes at end of turn, then refills HP and mana each turn', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.pendingStatuesquePlayerIds.add('local');
      ctx.local.hp = 5;
      ctx.local.mana = 0;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.state.wildMagic.statuesquePlayerIds, {'local'});
      expect(ctx.local.hp, 24, reason: 'refilled the turn it latched');
      expect(ctx.local.mana, ctx.local.maxMana);

      ctx.local.hp = 3;
      await ctx.loop.runTurn(TurnInput(action: PassAction()));
      expect(ctx.local.hp, 24);
    });

    test('breaks on a voluntary move', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.statuesquePlayerIds.add('local');
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: [HexCoord(ctx.local.position.q, ctx.local.position.r - 1)],
      ));
      expect(ctx.state.wildMagic.statuesquePlayerIds, isEmpty);
    });

    test('breaks on a cast', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.statuesquePlayerIds.add('local');
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _fireSpell(),
          targetHex: ctx.local.position,
        ),
      ));
      expect(ctx.state.wildMagic.statuesquePlayerIds, isEmpty);
    });

    test('a Meditate does NOT break it', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.statuesquePlayerIds.add('local');
      await ctx.loop.runTurn(TurnInput(action: MeditateAction()));
      expect(ctx.state.wildMagic.statuesquePlayerIds, {'local'});
    });
  });

  group('Phoenix through a real turn', () {
    test('a wizard who would die rises at 1 HP, once', () async {
      final ctx = _setup(seed: _seedQuiet);
      ctx.state.wildMagic.phoenixPlayerIds.add('local');
      ctx.local.hp = 0;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.hp, 1);
      expect(ctx.state.wildMagic.phoenixPlayerIds, isEmpty,
          reason: 'one-shot, consumed');
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
        ctx.state.wildMagic.ripplingFizzlePct = start;
        for (var i = 0; i < 5; i++) {
          await ctx.loop.runTurn(TurnInput(
            action: SpellCastAction(
              spell: _fireSpell(),
              targetHex: ctx.local.position,
            ),
          ));
        }
        expect(ctx.state.wildMagic.ripplingFizzlePct, inInclusiveRange(0, 100));
      }
    });

    test('a doubled spell does NOT re-fire its wild magic (A7, invariant 7)',
        () async {
      // 0% fizzle → every cast doubles. If the doubling could reach the
      // wild-magic seam, Burning Hot would arm twice from one cast.
      final ctx = _setup(seed: _seedRow1);
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
