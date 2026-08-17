// SPDX-License-Identifier: GPL-3.0-or-later
//
// action_resolution_characterization_test.dart — the three branches of
// `TurnLoop._resolveActions`'s subtree that had NO coverage at all, pinned
// before that subtree moves behind the deterministic-resolution seam.
//
// This file is not here for completeness. Every other branch reachable from
// `_resolveActions` is already pinned by either the replay corpus
// (`test/battle/replay/`) or a targeted engine test — counter charms, delayed
// fires, chain advance/regress, range and cloud gating, turbulent rolls,
// rippling, the rod, the wither RNG, Bellows multipliers, the summon spawn.
// These three were the gaps, and all three are exactly the kind of thing a
// mechanical extraction can drop silently:
//
//   1. **`_fireSummonMirror`** — a Reflections link mirroring a creature onto
//      its caster. Zero coverage anywhere in the suite, and it draws from the
//      shared action RNG *inside* `_castSummon`, so losing it would shift every
//      later draw in the turn rather than merely losing a minion.
//
//   2. **Scattered Gusts' redraw on cast** — the flag's arming is tested
//      (`wild_magic_effects_test.dart`); the redraw it causes at resolution
//      time is not. It reaches `_drawSchedules` and `localSpellDraw`, which are
//      deliberately outside `toCanonicalBytes()`, so no state hash and no
//      golden can see it stop happening.
//
//   3. **The forced-cast re-entry** — `TurnLoop.resolveForcedCast` calling
//      back into `_applySpell` with the A8 flags. `forced_cast_test.dart`
//      drives `ForcedCast.run` against a fake host, so it never reaches the
//      real `_applySpell`; `wild_magic_resolution_test.dart` fires Spontaneous
//      Combustion but with no hand to draw from, so every player is skipped.
//      This is the one path that leaves the deterministic subtree, crosses a
//      protocol seam, and comes back in — the seam the extraction has to keep
//      intact.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/forced_cast.dart' show ForcedCastPick;
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/reflection_link.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

/// 64 stable hex chars for [seed] — the same string always gives the same
/// commitment, in this run and the next.
String _hexOf(String seed) => seed.codeUnits
    .map((c) => (c & 0xFF).toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

/// A wire-formula spell. Solo mode never verifies a proof, so these resolve off
/// `SpellAsset.formula` — the same trusted-local path `summon_cast_test.dart`
/// uses, and the one `_parsedFormulas` falls back to when `certFormulas` is
/// null.
SpellAsset _spell({
  required String id,
  required List<String> formula,
  bool isSummon = false,
  String summonPersonality = 'aggressive',
}) =>
    SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 8, 17),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      // Never parsed: solo mode does not verify, and every cast below either
      // fires no wild magic or has none to fire.
      proofBytes: Uint8List(0),
      name: id,
      // Derived from the id's own bytes, never `id.hashCode`: Dart seeds string
      // hashing per isolate, so a hashCode-derived commitment gives a DIFFERENT
      // canonical chapter order on every run — and the deal, the draw positions
      // and therefore this test's outcome ride on that order.
      commitmentHex: '0x${_hexOf(id)}',
      spellHashHex: '0x${_hexOf('$id-hash')}',
      formula: formula,
      isSummon: isSummon,
      summonPersonality: summonPersonality,
    );

/// Three earths: `CreatureSpec.fromElements` reads hp 3 / dmg 0 / move 0 and
/// grants no ability (EEEE would make it Big — see the summon-fixture note in
/// docs). A creature that neither moves nor swings keeps these tests about the
/// spawn and the mirror rather than about the AI.
SpellAsset _plainSummon(String id) =>
    _spell(id: id, formula: const ['earth', 'earth', 'earth'], isSummon: true);

typedef _Ctx = ({
  BattleState state,
  TurnLoop loop,
  WizardAvatar local,
  WizardAvatar dummy,
});

_Ctx _setup({int radius = 6, int range = 6}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const lp = HexCoord(0, 3);
  const dp = HexCoord(0, -3);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = lp;
  battlefield.occupancy[dummyId] = dp;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 500,
    maxMana: 500,
    position: lp,
    teamId: 'solo',
    baseSpellRange: range,
  );
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'1' * 64}',
    hp: 24,
    mana: 500,
    maxMana: 500,
    position: dp,
    teamId: 'foe',
    baseSpellRange: range,
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

  return (
    state: state,
    loop: TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: localId,
    ),
    local: local,
    dummy: dummy,
  );
}

void main() {
  // ── 1. summonMirror ───────────────────────────────────────────────────────

  group('Reflections summonMirror (TurnLoop._fireSummonMirror)', () {
    test('a link on the summoner hands its caster an identical creature',
        () async {
      final ctx = _setup();
      // The LINK's caster is the dummy; its target is the wizard who summons.
      // "Whenever the TARGET summons, the CASTER receives one too."
      ctx.state.reflectionLinks.add(
        ReflectionLink(
          id: 'link1',
          casterId: 'dummy',
          targetId: 'local',
          activeTriggers: {ReflectionTrigger.summonMirror},
          remainingTurns: 5,
        ),
      );

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _plainSummon('mirror-summon'),
          targetHex: const HexCoord(0, 2),
        ),
      ));

      expect(ctx.state.minions.length, 2,
          reason: 'the summon plus its mirror');

      final original = ctx.state.minions.firstWhere((m) => m.ownerId == 'local');
      final mirror = ctx.state.minions.firstWhere((m) => m.ownerId == 'dummy');

      // The mirror is a copy in every stat-bearing field, spawned near its own
      // owner rather than near the original's target tile.
      expect(mirror.affinity, original.affinity);
      expect(mirror.stats.maxHp, original.stats.maxHp);
      expect(mirror.elementSequence, original.elementSequence);
      expect(mirror.abilities, original.abilities);
      expect(mirror.personality, original.personality);
      expect(mirror.sizeBonus, original.sizeBonus);
      expect(mirror.teamId, 'foe');
      // Wears the original's card art (Minion.copiedFromMinionId) — the field
      // battle_screen tints on, and the only thing distinguishing the two.
      expect(mirror.copiedFromMinionId, original.id);
      expect(original.copiedFromMinionId, isNull);
    });

    test('no link means no mirror — one creature, and the RNG draw for the '
        'mirror id is never taken', () async {
      final ctx = _setup();
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _plainSummon('lone-summon'),
          targetHex: const HexCoord(0, 2),
        ),
      ));
      expect(ctx.state.minions.length, 1);
      expect(ctx.state.minions.single.ownerId, 'local');
    });

    test('a link pointing the other way does not fire', () async {
      final ctx = _setup();
      // Local is the link's CASTER here, not its target, so its own summon
      // must not mirror anything back to itself.
      ctx.state.reflectionLinks.add(
        ReflectionLink(
          id: 'link2',
          casterId: 'local',
          targetId: 'dummy',
          activeTriggers: {ReflectionTrigger.summonMirror},
          remainingTurns: 5,
        ),
      );
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _plainSummon('wrong-way-summon'),
          targetHex: const HexCoord(0, 2),
        ),
      ));
      expect(ctx.state.minions.length, 1);
    });

    test('a link without the summonMirror trigger does not fire', () async {
      final ctx = _setup();
      ctx.state.reflectionLinks.add(
        ReflectionLink(
          id: 'link3',
          casterId: 'dummy',
          targetId: 'local',
          activeTriggers: {ReflectionTrigger.manaMirror},
          remainingTurns: 5,
        ),
      );
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _plainSummon('untriggered-summon'),
          targetHex: const HexCoord(0, 2),
        ),
      ));
      expect(ctx.state.minions.length, 1);
    });
  });

  // ── 2. Scattered Gusts' redraw at resolution time ─────────────────────────

  group('Scattered Gusts redraws the caster\'s hand on every cast', () {
    /// A chapter of distinguishable cards. Six, so a redraw of a one-card hand
    /// has five other cards to land on and "the hand did not change" is a real
    /// signal rather than a coin flip.
    List<SpellAsset> chapter() => [
          for (var i = 0; i < 6; i++)
            _spell(id: 'card$i', formula: const ['fire', 'fire', 'fire']),
        ];

    Future<_Ctx> run({required bool gusts}) async {
      final ctx = _setup();
      final cards = chapter();
      ctx.loop
        ..localChapterSpells = cards
        ..localChapterCommitments = [for (final c in cards) c.commitmentHex];
      ctx.state.wildMagic.scatteredGusts = gusts;
      // A cast of something NOT in the chapter, so the ordinary refill path
      // (`_advanceDrawState`) never runs and the only thing that can move the
      // hand is the Gusts redraw.
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(
          spell: _spell(id: 'trigger', formula: const ['fire', 'fire', 'fire']),
          targetHex: const HexCoord(0, 2),
        ),
      ));
      return ctx;
    }

    test('without the flag, a cast leaves the dealt hand exactly as dealt',
        () async {
      final ctx = await run(gusts: false);
      final schedule = ctx.loop.drawScheduleFor('local')!;
      expect(schedule.hand.length, 1, reason: 'bookmarkCount 0 → handSize 1');
      expect(schedule.remaining.length, 5);
      expect(
        ctx.loop.localSpellDraw!.hand.single.commitmentHex,
        isNotNull,
      );
    });

    test('with the flag, the same cast re-deals the hand from the whole deck',
        () async {
      final without = await run(gusts: false);
      final with_ = await run(gusts: true);

      // Same size, same deck — only the contents move.
      expect(with_.loop.drawScheduleFor('local')!.hand.length, 1);
      expect(with_.loop.drawScheduleFor('local')!.remaining.length, 5);

      expect(
        with_.loop.drawScheduleFor('local')!.hand,
        isNot(without.loop.drawScheduleFor('local')!.hand),
        reason: 'the Gusts redraw must actually change which position is held',
      );
      // The public schedule and the private contents are redrawn from the SAME
      // seed, so they must still agree about which card is in the slot — the
      // invariant `_redrawHand` exists to hold (see its doc comment).
      final position = with_.loop.drawScheduleFor('local')!.hand.single;
      // Positions index the CANONICAL (commitmentHex-sorted) chapter, which is
      // what `_dealOpeningHandsIfNeeded` and BookCommitment both derive from —
      // not the order the chapter was handed to the loop in.
      final canonical = List<String>.from(with_.loop.localChapterCommitments!)
        ..sort();
      expect(
        with_.loop.localSpellDraw!.hand.single.commitmentHex,
        canonical[position],
        reason: 'schedule position and SpellDraw contents must not diverge',
      );
    });
  });

  // ── 3. Forced-cast re-entry (A8) ──────────────────────────────────────────

  group('TurnLoop.resolveForcedCast re-enters spell application (A8)', () {
    test('a forced free cast really resolves', () async {
      final ctx = _setup();
      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'local',
          position: 0,
          spell: _plainSummon('forced-summon'),
        ),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i))),
      );
      expect(ctx.state.minions.length, 1,
          reason: 'the free cast must reach _applySpell and produce a creature');
      expect(ctx.state.minions.single.ownerId, 'local');
    });

    test('it neither builds nor breaks the chain (skipChainUpdate)', () async {
      final ctx = _setup();
      // A chain already running on a DIFFERENT element: a free cast that built
      // the chain would switch it to earth; one that regressed it would tear it
      // down. Neither may happen.
      ctx.local.activeChainElement = SpellAffinity.fire;
      ctx.local.chainLengths[SpellAffinity.fire] = 4;

      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'local',
          position: 0,
          spell: _plainSummon('chainless-summon'),
        ),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i + 1))),
      );

      expect(ctx.local.activeChainElement, SpellAffinity.fire);
      expect(ctx.local.chainLengths[SpellAffinity.fire], 4);
    });

    test('it is exempt from Rippling Reflections (subjectToRippling: false)',
        () async {
      final ctx = _setup();
      // 100% fizzle. A cast subject to rippling could not possibly resolve, and
      // the coin would drift the counter to 90.
      ctx.state.wildMagic.ripplingFizzlePct = 100;

      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'local',
          position: 0,
          spell: _plainSummon('unrippled-summon'),
        ),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i + 2))),
      );

      expect(ctx.state.minions.length, 1,
          reason: 'a free cast must ignore the rippling coin entirely');
      expect(ctx.state.wildMagic.ripplingFizzlePct, 100,
          reason: 'the coin must not have been rolled, so it must not drift');
    });

    test('it fires no wild magic (fireWildMagic: false, the A8 recursion guard)',
        () async {
      final ctx = _setup();
      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'local',
          position: 0,
          spell: _plainSummon('quiet-summon'),
        ),
        HashRng(Uint8List.fromList(List.generate(32, (i) => i + 3))),
      );
      expect(ctx.loop.lastWildMagicEvents, isEmpty);
    });

    test('a dead or unknown caster is skipped, not crashed on', () async {
      final ctx = _setup();
      ctx.local.hp = 0;
      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'local',
          position: 0,
          spell: _plainSummon('dead-summon'),
        ),
        HashRng(Uint8List(32)),
      );
      await ctx.loop.resolveForcedCast(
        ForcedCastPick(
          playerId: 'nobody',
          position: 0,
          spell: _plainSummon('ghost-summon'),
        ),
        HashRng(Uint8List(32)),
      );
      expect(ctx.state.minions, isEmpty);
    });
  });
}
