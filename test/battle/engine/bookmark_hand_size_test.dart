// SPDX-License-Identifier: GPL-3.0-or-later
//
// bookmark_hand_size_test.dart — hand size is derived from bookmark
// accoutrements (WizardAvatar.bookmarkCount + 1), not a fixed MatchConfig
// value, and reacts mid-battle when an effect creates or destroys a bookmark
// (TurnLoop._reconcileHandSize). Exercises the real cast pipeline end-to-end
// via SoloBattleSession (see rod_of_wind_test.dart for the pattern),
// so the formula-to-effect resolution (ArtifactsInteractionEffect, Water-
// Earth per effect_kind.dart) is real, not stubbed.

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

void main() {
  // Air-flavored Artifacts Interaction (Water-Earth pair, see
  // effect_kind.dart's effectKindFromPair) summons 1 bookmark on whoever
  // occupies the target tile; Fire-flavored burns 1 random non-core
  // accoutrement. Both resolve locally straight off SpellAsset.formula (no
  // peer, no proof verification) — see TurnLoop._parsedFormulas.
  SpellAsset formulaSpell(
    String id,
    List<String> formula, {
    int fillByte = 1,
  }) =>
      SpellAsset(
        id: id,
        createdAt: DateTime.utc(2026, 7, 28),
        tier: 12,
        t: 1,
        ownerPubkeyHex: '0x${'0' * 64}',
        manaCost: 0,
        segmentCount: 0,
        dotCount: 0,
        initialGrid: const [],
        proofBytes: Uint8List.fromList([1, 2, 3]),
        name: id,
        commitmentHex:
            '0x${Uint8List.fromList(List.filled(32, fillByte)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
        spellHashHex: '',
        formula: formula,
      );

  ({BattleState state, TurnLoop loop, WizardAvatar local}) setup({
    required List<Accoutrement> accoutrements,
    required List<SpellAsset> chapter,
  }) {
    final bf = Battlefield(radius: 6);
    const id = 'local';
    final local = WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: const HexCoord(0, 3),
      teamId: 'solo',
      baseSpellRange: 3,
      accoutrements: accoutrements,
    );
    bf.occupancy[id] = local.position;
    final state = BattleState(
      config: const MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 1),
      avatars: [local],
      teams: [const Team(id: 'solo', playerIds: [id])],
      battlefield: bf,
    );
    final sortedChapter = List<SpellAsset>.from(chapter)
      ..sort((a, b) => a.commitmentHex.compareTo(b.commitmentHex));
    final loop = TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: id,
    )
      ..localChapterSpells = sortedChapter
      ..localChapterCommitments = sortedChapter.map((s) => s.commitmentHex).toList();
    return (state: state, loop: loop, local: local);
  }

  test('an Air Artifacts Interaction cast that summons a bookmark grows the '
      'hand by 1 in the same turn (handSize == bookmarkCount + 1)', () async {
    // 1 bookmark to start (hand size 2). 4 identical grow-formula copies so
    // whichever 2 the random opening deal picks are functionally the same
    // cast — the test only cares about cardinalities, not which copy lands
    // in hand.
    final chapter = List.generate(
      4,
      (i) => formulaSpell('grow$i', const ['air', 'water', 'earth'], fillByte: i + 1),
    );
    final ctx = setup(
      accoutrements: [
        const Accoutrement(id: 'bm0', kind: AccoutrementKind.bookmark),
      ],
      chapter: chapter,
    );

    await ctx.loop.runTurn(TurnInput(action: PassAction()));
    expect(ctx.loop.localSpellDraw!.hand, hasLength(2));
    expect(ctx.loop.localSpellDraw!.remaining, hasLength(2));
    expect(ctx.local.bookmarkCount, 1);

    final toCast = ctx.loop.localSpellDraw!.hand.first;
    await ctx.loop.runTurn(TurnInput(
      action: SpellCastAction(spell: toCast, targetHex: ctx.local.position),
    ));

    expect(ctx.local.bookmarkCount, 2, reason: 'the Air effect summoned 1 bookmark');
    // Normal refill (cast leaves a slot, refilled from the 2-card deck)
    // keeps hand at 2; the NEW bookmark then draws one more from the
    // now-1-card deck, growing the hand to 3 in the same turn.
    expect(ctx.loop.localSpellDraw!.hand, hasLength(3));
    expect(ctx.loop.localSpellDraw!.remaining, isEmpty);
  });

  test('a Fire Artifacts Interaction cast that burns the caster\'s only '
      'bookmark shrinks the hand by 1 in the same turn, and the dropped '
      'slot\'s spell returns to the deck', () async {
    // 2 bookmarks, no other non-core accoutrements, so the Fire burn (which
    // picks a random non-core accoutrement) is guaranteed to hit a bookmark.
    // handSize 3 == chapter size 3, so the opening deal is fully
    // deterministic (all 3 always in hand, no draw-order dependence).
    final chapter = List.generate(
      3,
      (i) => formulaSpell('burn$i', const ['fire', 'water', 'earth'], fillByte: i + 1),
    );
    final ctx = setup(
      accoutrements: [
        const Accoutrement(id: 'bm0', kind: AccoutrementKind.bookmark),
        const Accoutrement(id: 'bm1', kind: AccoutrementKind.bookmark),
      ],
      chapter: chapter,
    );

    await ctx.loop.runTurn(TurnInput(action: PassAction()));
    expect(ctx.loop.localSpellDraw!.hand, hasLength(3));
    expect(ctx.loop.localSpellDraw!.remaining, isEmpty);
    expect(ctx.local.bookmarkCount, 2);

    final toCast = ctx.loop.localSpellDraw!.hand.first;
    final untouched = ctx.loop.localSpellDraw!.hand
        .where((s) => s.commitmentHex != toCast.commitmentHex)
        .toSet();
    await ctx.loop.runTurn(TurnInput(
      action: SpellCastAction(spell: toCast, targetHex: ctx.local.position),
    ));

    expect(ctx.local.bookmarkCount, 1, reason: 'the Fire effect burned 1 bookmark');
    // Normal cast leaves the hand at 2 (deck was already empty, so no
    // refill); the lost bookmark then drops one more slot, shrinking the
    // hand to 1.
    expect(ctx.loop.localSpellDraw!.hand, hasLength(1));
    expect(ctx.loop.localSpellDraw!.remaining, hasLength(1));
    // The dropped slot's spell rejoined the deck rather than being burned.
    final remainingHexes = {
      for (final s in ctx.loop.localSpellDraw!.remaining) s.commitmentHex,
    };
    final untouchedHexes = untouched.map((s) => s.commitmentHex).toSet();
    expect(untouchedHexes.union(remainingHexes), untouchedHexes,
        reason: 'the surviving hand card plus the returned card should '
            'together be exactly the 2 non-cast spells');
    expect({...ctx.loop.localSpellDraw!.hand.map((s) => s.commitmentHex), ...remainingHexes},
        untouchedHexes,
        reason: 'no spell should be lost — hand ∪ remaining == the 2 uncast spells');
  });
}
