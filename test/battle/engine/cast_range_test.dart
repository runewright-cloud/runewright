// SPDX-License-Identifier: GPL-3.0-or-later
//
// cast_range_test.dart — spell range is enforced by the engine, not by the
// caster's UI (2026-08-06).
//
// battle_screen's `_maxCastRange` only decides what a human player's own
// client lets them tap. A modified client — or the Solo Practice dummy, which
// encodes its cast straight onto the wire — never passes through it, so until
// TurnLoop checked the distance itself a peer could declare a target clean
// across the field and `effectiveSpellRange` was advisory. Same trust-boundary
// reasoning that gave the cloud adjacency rule its engine-side twin
// (`_cloudBoundToAdjacent`), and the same failure mode as B-1's mana costs:
// the honest client enforces a rule the cheating one simply skips.
//
// These tests reach TurnLoop directly with the action a cheating client would
// put on the wire — that is the whole point; a test that went through the UI
// gate would prove nothing.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(
  String id,
  HexCoord pos, {
  String teamId = 'a',
  int range = 3,
}) =>
    WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 1000,
      maxMana: 1000,
      position: pos,
      teamId: teamId,
      baseSpellRange: range,
    );

BattleState _state(List<WizardAvatar> avatars, {int radius = 6}) {
  final bf = Battlefield(radius: radius);
  for (final a in avatars) {
    bf.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: List.of(avatars),
    teams: [
      for (final a in avatars) Team(id: a.teamId, playerIds: [a.playerId]),
    ],
    battlefield: bf,
  );
}

/// A one-formula Firey Blast: 4 damage, radius 0. "Did the cast resolve" is
/// then simply "did the target lose hp".
SpellAsset _blast() => SpellAsset(
      id: 'sp_blast',
      createdAt: DateTime.utc(2026, 8, 6),
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

TurnLoop _loop(BattleState state, String localId) => TurnLoop(
      state: state,
      session: SoloBattleSession(state: state),
      localPlayerId: localId,
    );

void _addRange(WizardAvatar av, int delta) {
  av.activeStatusEffects.add(StatusEffect(
    effectTypeId: delta > 0 ? StatusEffectId.rangeUp : StatusEffectId.rangeDown,
    remainingTurns: 5,
    modifiers: {'rangeDelta': delta},
  ));
}

void main() {
  group('cast range is enforced by the engine', () {
    test('a cast past the caster\'s reach does nothing at all', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(5, 0), teamId: 'b');
      final state = _state([caster, victim]);
      final loop = _loop(state, 'caster');

      await loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, 24,
          reason: 'range 3, target 5 hexes out — the engine must not resolve '
              'a cast the caster could never legally have declared');
      expect(loop.lastResolvedSpells, isEmpty,
          reason: 'an out-of-range cast fails entirely, exactly like one that '
              'ignored a cloud\'s adjacent-only restriction');
    });

    test('a cast at exactly maximum range still resolves', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(3, 0), teamId: 'b');
      final state = _state([caster, victim]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, lessThan(24),
          reason: 'the bound is <= range, not < range — an off-by-one here '
              'silently shortens every wizard in the game');
    });

    test('one hex past maximum range is the first tile that fails', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state([caster, victim]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, 24);
    });
  });

  // The reason Earthen and Airy Inertia are worth having at all: before this,
  // effectiveSpellRange was read only by the caster's own UI, so a rangeDown
  // laid on a PEER changed nothing about what that peer could actually cast.
  group('range modifiers move the boundary', () {
    test('Earthen Inertia (rangeDown) really shortens a cast', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      _addRange(caster, -1);
      final victim = _avatar('victim', const HexCoord(3, 0), teamId: 'b');
      final state = _state([caster, victim]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, 24,
          reason: 'range 3 − 1 = 2, so a target 3 hexes out is now beyond '
              'reach; this is the whole point of the effect');
    });

    test('Airy Inertia (rangeUp) really lengthens one', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      _addRange(caster, 1);
      final victim = _avatar('victim', const HexCoord(4, 0), teamId: 'b');
      final state = _state([caster, victim]);

      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, lessThan(24),
          reason: 'range 3 + 1 = 4 — the bound must read effectiveSpellRange, '
              'not baseSpellRange');
    });
  });

  // Movement resolves in Phase 3, before action resolution, but the player
  // declared their target in Phase 1 from where they were standing THEN. A
  // check measured from the post-move tile would fizzle the perfectly legal
  // cast of anyone who walked away from their target afterwards.
  group('measured from where the caster declared', () {
    test('walking away from the target does not invalidate the cast',
        () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(3, 0), teamId: 'b');
      final state = _state([caster, victim]);

      // Declared at distance 3 (legal), then retreats two hexes the other way
      // — five hexes from the target by the time the spell resolves.
      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
        movePath: const [HexCoord(-1, 0), HexCoord(-2, 0)],
      ));

      expect(caster.position, const HexCoord(-2, 0), reason: 'the walk happened');
      expect(victim.hp, lessThan(24),
          reason: 'the cast was legal when it was declared — measuring from '
              'the post-move tile would have wrongly killed it');
    });

    test('walking CLOSER does not legalise an out-of-range declaration',
        () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(5, 0), teamId: 'b');
      final state = _state([caster, victim]);

      // Declared 5 hexes out with range 3 — illegal at declaration time.
      // Closing to within 3 afterwards must not launder it, or the exploit
      // just becomes "declare far, then walk".
      await _loop(state, 'caster').runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
      ));

      expect(caster.position, const HexCoord(2, 0));
      expect(victim.hp, 24);
    });
  });

  // Ruling 2026-08-06: targeting is valid so long as it was valid at the time
  // the cast was completed. The origin was already read that way; these pin
  // the other half — the REACH is read as of the same moment.
  group('judged as of when the cast was completed', () {
    test('a rangeDown landing in the same action phase does not clip a cast '
        'already declared', () async {
      // The dummy casts an Earthen Inertia (Earth affinity, Earth-Air zones =
      // Range Modification) onto the caster's own tile every turn, so the
      // caster picks up rangeDown 3 → 2 during the very action phase their own
      // max-range cast is resolving in.
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(3, 0), teamId: 'b');
      final state = _state([caster, victim]);
      final loop = TurnLoop(
        state: state,
        session: SoloBattleSession(
          state: state,
          dummyAutoCast: true,
          dummyCastTarget: caster.position,
          dummyCastFormula: const ['earth', 'earth', 'air'],
        ),
        localPlayerId: 'caster',
      );

      await loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(
        caster.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.rangeDown),
        isTrue,
        reason: 'fixture check: the dummy really did land an Earthen Inertia',
      );
      expect(victim.hp, lessThan(24),
          reason: 'the cast was declared at exactly range 3 in Phase 1, before '
              'anything had clipped it. Reading effectiveSpellRange at '
              'resolution instead of the Phase 2 snapshot would fizzle it '
              'retroactively');
    });

    test('the clip applies from the NEXT turn onward', () async {
      final caster = _avatar('caster', const HexCoord(0, 0), range: 3);
      final victim = _avatar('victim', const HexCoord(3, 0), teamId: 'b');
      final state = _state([caster, victim]);
      final loop = TurnLoop(
        state: state,
        session: SoloBattleSession(
          state: state,
          dummyAutoCast: true,
          dummyCastTarget: caster.position,
          dummyCastFormula: const ['earth', 'earth', 'air'],
        ),
        localPlayerId: 'caster',
      );

      await loop.runTurn(TurnInput(action: PassAction()));
      final hpAfterSetup = victim.hp;

      // Turn 2: rangeDown is on the caster from the start, so range is 2 and
      // the same distance-3 cast is now genuinely illegal.
      await loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _blast(), targetHex: victim.position),
      ));

      expect(victim.hp, hpAfterSetup,
          reason: 'the snapshot is per-turn, not a permanent exemption — once '
              'the rangeDown is up at commit time it really does shorten you');
    });
  });
}
