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

import 'package:rune_duel/battle/engine/commit_reveal.dart';
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

/// A [SoloBattleSession] with the joint turn entropy **pinned**, so every deal,
/// draw and redeal below is bit-identical from run to run.
///
/// Solo mode normally derives each turn's entropy from `Random.secure()`
/// (`SoloBattleSession.exchangeNonce` mints a fresh nonce), which makes any
/// assertion about *which* card was drawn a coin flip. The trick here is the
/// one `turn_session_pair.dart` already uses: choose `theirNonce` so that
/// `ourNonce XOR theirNonce` is always [entropy] — exactly what
/// [CommitRevealEntropy.revealAndCombine] returns once the commit checks out.
///
/// Nothing about the engine's RNG *consumption* changes; only the seed it is
/// handed stops being random.
class _PinnedEntropySession extends SoloBattleSession {
  _PinnedEntropySession({required super.state, required this.entropy});

  final Uint8List entropy;

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    final theirNonce = Uint8List.fromList([
      for (var i = 0; i < 32; i++) ourNonce[i] ^ entropy[i],
    ]);
    return (
      theirNonce: theirNonce,
      theirCommit: await CommitRevealEntropy.commit(theirNonce),
    );
  }

  @override
  Future<Uint8List> refreshEntropy(String reason) async =>
      Uint8List.fromList(entropy);
}

typedef _Ctx = ({
  BattleState state,
  TurnLoop loop,
  WizardAvatar local,
  WizardAvatar dummy,
});

/// [pinnedEntropy] swaps the secure-random solo session for
/// [_PinnedEntropySession] and pins the commit salts too, making the whole turn
/// reproducible. [bookmarks] sets the local wizard's hand size
/// (handSize == bookmarkCount + 1 — see `TurnLoop._dealOpeningHandsIfNeeded`).
_Ctx _setup({
  int radius = 6,
  int range = 6,
  Uint8List? pinnedEntropy,
  int bookmarks = 0,
}) {
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
    accoutrements: [
      for (var i = 0; i < bookmarks; i++)
        Accoutrement(id: 'bm$i', kind: AccoutrementKind.bookmark),
    ],
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
      session: pinnedEntropy == null
          ? SoloBattleSession(state: state)
          : _PinnedEntropySession(state: state, entropy: pinnedEntropy),
      localPlayerId: localId,
      // Pinned alongside the entropy: these salts seed the action-phase RNG,
      // so leaving them on Random.secure() would keep part of the turn
      // unreproducible even with the joint entropy fixed.
      commitNonceSource: pinnedEntropy == null
          ? null
          : (length) => Uint8List.fromList(
                List<int>.generate(length, (i) => (i * 7 + 3) & 0xFF),
              ),
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
  //
  // What the redraw actually does (`TurnLoop._redrawHand` →
  // `DrawSchedule.redrawHand` / `SpellDraw.redrawHand`):
  //
  //   1. every card in hand is returned to `remaining` (a `removeSlot(0)` loop,
  //      which also clears its withered flag);
  //   2. the eligible population is therefore the WHOLE chapter minus only the
  //      positions permanently cast out of it — old hand included;
  //   3. `handSize` cards are drawn back out of that pool one at a time,
  //      `remainingPool.removeAt(rng.nextInt(remainingPool.length))`;
  //   4. the seed is `_playerPhaseSeed(turn entropy, matchId, turnNumber, 0x05,
  //      playerId, drawNonce)` — the only RNG seam involved, and it rides on the
  //      turn's joint entropy, which `_PinnedEntropySession` pins here.
  //
  // NOTE ON WHAT IS *NOT* ASSERTED: an earlier version of this group asserted
  // that the redealt hand DIFFERS from the hand dealt without the flag. That is
  // mathematically invalid — a correct whole-deck redeal draws uniformly from a
  // pool that still contains the old hand, so reproducing it is a legal outcome
  // (1-in-6 with the six-card chapter below, which is exactly how often the
  // assertion failed). The invariant that actually characterises the effect is
  // that old-hand cards are RETURNED TO AND DRAWABLE FROM the pool, and that is
  // proved below by saturation rather than by luck.

  group('Scattered Gusts redraws the caster\'s hand on every cast', () {
    /// Pinned joint entropy — see [_PinnedEntropySession]. Any 32 fixed bytes
    /// do; nothing below depends on *which* positions this particular seed
    /// happens to produce.
    final entropy = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 11 + 5) & 0xFF),
    );

    /// A chapter of [size] distinguishable cards.
    List<SpellAsset> chapter(int size) => [
          for (var i = 0; i < size; i++)
            _spell(id: 'card$i', formula: const ['fire', 'fire', 'fire']),
        ];

    Future<_Ctx> run({
      required bool gusts,
      int chapterSize = 6,
      int bookmarks = 0,
    }) async {
      final ctx = _setup(pinnedEntropy: entropy, bookmarks: bookmarks);
      final cards = chapter(chapterSize);
      ctx.loop
        ..localChapterSpells = cards
        ..localChapterCommitments = [for (final c in cards) c.commitmentHex];
      // Armed on turn 0 so the Gust is pending from turn 1 — the turn the
      // cast below runs on. A Gust armed on the CURRENT turn is deliberately
      // not consumable by that turn's casts (Slice 4).
      if (gusts) {
        ctx.state.wildMagic.armScatteredGusts('local', triggerTurn: 0);
      }
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

    test('with the flag, the redeal conserves the deck and keeps the public '
        'schedule and the private contents in agreement', () async {
      final ctx = await run(gusts: true);
      final schedule = ctx.loop.drawScheduleFor('local')!;

      // Hand size is preserved: Gusts re-deals the SAME number of cards
      // (`_redrawHand`'s `handSize ?? schedule.hand.length`).
      expect(schedule.hand.length, 1, reason: 'bookmarkCount 0 → handSize 1');
      expect(schedule.remaining.length, 5);

      // Conservation — nothing fabricated, duplicated or lost. Every chapter
      // position is accounted for exactly once across hand ∪ remaining, and
      // nothing was permanently used (the cast spell was not in the chapter).
      final all = [...schedule.hand, ...schedule.remaining];
      expect(all.toSet(), {0, 1, 2, 3, 4, 5});
      expect(all.length, 6, reason: 'no position may appear twice');
      expect(ctx.loop.usedChapterPositions('local'), isEmpty);

      // The public schedule and the private contents are redrawn from the SAME
      // seed, so they must still agree about which card is in the slot — the
      // invariant `_redrawHand` exists to hold (see its doc comment).
      final position = schedule.hand.single;
      // Positions index the CANONICAL (commitmentHex-sorted) chapter, which is
      // what `_dealOpeningHandsIfNeeded` and BookCommitment both derive from —
      // not the order the chapter was handed to the loop in.
      final canonical = List<String>.from(ctx.loop.localChapterCommitments!)
        ..sort();
      expect(ctx.loop.localSpellDraw!.hand.length, 1);
      expect(
        ctx.loop.localSpellDraw!.hand.single.commitmentHex,
        canonical[position],
        reason: 'schedule position and SpellDraw contents must not diverge',
      );
    });

    test('the previous hand is returned to the pool and is drawable from it — '
        'a four-card chapter dealt into a three-card hand must redraw at '
        'least two of the three cards it just gave back', () async {
      // SATURATION, not luck. Two bookmarks → handSize 3; the chapter is 4. So
      // at redeal time the pool is 4 if (and only if) the old hand went back
      // into it, and 1 if it did not:
      //
      //   correct              → pool 4, deal 3. |old ∩ new| ≥ 3 + 3 − 4 = 2,
      //                          forced by pigeonhole for EVERY RNG outcome.
      //   old hand excluded    → pool 1, `dealSize` clamps to 1, the hand
      //                          shrinks to one card, |old ∩ new| = 0.
      //   old hand returned    → pool 1 at draw time, same shrunken hand, even
      //   only after the draw    though the returned cards do reappear in
      //                          `remaining` afterwards.
      //
      // Both the hand-size and the intersection assertion therefore separate a
      // whole-deck redeal from a "refill from everything except the old hand"
      // one, with zero dependence on which cards the RNG actually picked. (The
      // third case is why simply checking `hand ∪ remaining` is not enough: a
      // deck that conserves every card can still have excluded the old hand
      // from the draw.)
      final before = await run(gusts: false, chapterSize: 4, bookmarks: 2);
      final oldHand = before.loop.drawScheduleFor('local')!.hand.toSet();
      expect(oldHand.length, 3, reason: 'bookmarkCount 2 → handSize 3');

      final after = await run(gusts: true, chapterSize: 4, bookmarks: 2);
      final newHand = after.loop.drawScheduleFor('local')!.hand;

      expect(
        after.loop.drawScheduleFor('local')!.remaining.length + newHand.length,
        4,
        reason: 'the whole chapter is still accounted for',
      );
      expect(newHand.toSet().length, 3,
          reason: 'three distinct positions — nothing duplicated');
      expect(
        newHand.length,
        3,
        reason: 'a pool that excluded the old hand could only have dealt 1',
      );
      expect(
        newHand.toSet().intersection(oldHand).length,
        greaterThanOrEqualTo(2),
        reason: 'cards from the previous hand must be eligible for the redeal',
      );

      // AND, as it happens, under this pinned entropy the redeal reproduces the
      // old hand EXACTLY — same three positions, same order. That is not a
      // failure and nothing here treats it as one: it is a live demonstration
      // that a correct whole-deck redeal may legally return the hand it just
      // scattered, which is precisely why the old `isNot(...)` assertion this
      // group used to carry was unsound.
      expect(newHand.toSet(), oldHand,
          reason: 'identical is a legal outcome of a whole-deck redeal');
    });

    test('the flag is what moves the hand — with the entropy pinned, the '
        'redeal is observable rather than inferred', () async {
      // This is the one assertion that shows the Gusts branch actually EXECUTED
      // (`deterministic_resolution.dart`'s `consumeScatteredGust` →
      // `host.redrawHand`) rather than the pending Gust being read and ignored.
      //
      // It is NOT the old, unsound "a redeal must change the hand" claim. Both
      // runs below share one pinned joint entropy, so each hand is a fixed
      // function of a fixed seed and this comparison has no run-to-run variance
      // at all — it is a characterisation of what this seed does, not a
      // probabilistic argument. The saturated test above deliberately shows the
      // opposite outcome (an identical redeal) being equally correct.
      final off = await run(gusts: false);
      final on = await run(gusts: true);
      expect(off.loop.drawScheduleFor('local')!.hand, [0]);
      expect(on.loop.drawScheduleFor('local')!.hand, [2]);
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
      // 100% fizzle, ACTIVE on the current round: armed on turnNumber - 1, so
      // its one-round window covers turnNumber itself. (resolveForcedCast is
      // called directly here, without runTurn, so the clock does not advance —
      // arming it "now" would leave it merely scheduled and the exemption
      // below would pass vacuously.)
      ctx.state.wildMagic
          .armRippling(triggerTurn: ctx.state.turnNumber - 1);
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
      expect(
          ctx.state.wildMagic.ripplingFizzlePctOn(ctx.state.turnNumber), 100,
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
