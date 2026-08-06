// SPDX-License-Identifier: GPL-3.0-or-later
//
// turbulent_range_test.dart — Watery Inertia (Range Modification, Water):
// StatusEffectId.turbulent, wired 2026-08-06.
//
// Design v4.0 §303: "next spell fires in intended direction but range
// randomized 1–max, 4[5] turns". Two rulings, 2026-08-06: the status persists
// for its full duration (it is NOT consumed by the first cast), and *max* is
// the caster's own effectiveSpellRange, so a roll can carry the spell PAST the
// tile it was aimed at as well as leave it short.
//
// Every test here asserts a BEHAVIOURAL difference — where damage actually
// lands — never that the status chip exists. That is the whole lesson of
// `penetrating` shipping broken: its only test checked a field was set (see
// line_of_sight_test.dart's header, and M4_findings §"How it hid").

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show Battlefield, hexDistance;
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
  int range = 6,
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

/// A one-formula Firey Blast — radius 0, so exactly one tile takes the hit and
/// "where did it land" is directly observable as "who lost hp".
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

void _makeTurbulent(WizardAvatar av, {int turns = 40}) {
  av.activeStatusEffects.add(
    StatusEffect(effectTypeId: StatusEffectId.turbulent, remainingTurns: turns),
  );
}

/// Casts at [target] once and returns the hex the spell actually resolved on.
///
/// Read off [TurnLoop.lastResolvedSpells] because that is the same value the
/// engine handed to `_applySpell` and the same one the UI's card reveal blooms
/// from — one number, not a UI mirror that could drift from the engine.
Future<HexCoord> _castAt(TurnLoop loop, HexCoord target) async {
  await loop.runTurn(TurnInput(
    action: SpellCastAction(spell: _blast(), targetHex: target),
  ));
  return loop.lastResolvedSpells.single.targetHex;
}

/// [casts] consecutive casts at the same declared tile, one per turn, on one
/// long-lived loop — so this also exercises the status surviving from turn to
/// turn rather than a fresh fixture each time.
Future<List<HexCoord>> _castRepeatedly(
  TurnLoop loop,
  HexCoord target,
  int casts,
) async {
  final landings = <HexCoord>[];
  for (var i = 0; i < casts; i++) {
    landings.add(await _castAt(loop, target));
  }
  return landings;
}

void main() {
  // ── The roll ──────────────────────────────────────────────────────────────

  group('turbulent range', () {
    test('a caster WITHOUT it lands exactly where they aimed, every time',
        () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);
      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(5, 0), 8);

      expect(landings, everyElement(const HexCoord(5, 0)),
          reason: 'the roll must be free for a caster who is not turbulent — '
              'no silent drift on the ordinary path');
    });

    test('a turbulent caster lands at a rolled distance, not the declared one',
        () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);

      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(5, 0), 25);
      final distances =
          landings.map((h) => hexDistance(const HexCoord(0, 0), h)).toSet();

      expect(distances.length, greaterThan(1),
          reason: '25 casts that all flew the same distance means the roll '
              'is not happening (or is seeded identically every turn)');
      expect(distances.every((d) => d >= 1 && d <= 6), isTrue,
          reason: 'the roll is 1..effectiveSpellRange, got $distances');
    });

    test('the declared DIRECTION survives — only the distance is thrown off',
        () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);

      // Declared straight down the +q axis, so "same direction" is exactly
      // "r stayed 0" — no rounding slop to argue about.
      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(5, 0), 25);

      expect(landings.every((h) => h.r == 0 && h.q > 0), isTrue,
          reason: 'a turbulent spell is thrown long or short, never sideways: '
              '$landings');
    });

    test('it can sail PAST the declared tile, not only fall short', () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      // Declared at distance 1 with range 6: five of the six rolls overshoot.
      final state = _state([caster, _avatar('foe', const HexCoord(1, 0), teamId: 'b')]);

      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(1, 0), 25);
      final overshot = landings
          .where((h) => hexDistance(const HexCoord(0, 0), h) > 1)
          .toList();

      expect(overshot, isNotEmpty,
          reason: 'max is the CASTER\'S range, not the declared distance — a '
              'roll above the declared distance must fly past the target '
              '(ruling 2026-08-06), got $landings');
    });

    test('it can also fall short of the declared tile', () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final state = _state([caster, _avatar('foe', const HexCoord(6, 0), teamId: 'b')]);

      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(6, 0), 25);
      final short = landings
          .where((h) => hexDistance(const HexCoord(0, 0), h) < 6)
          .toList();

      expect(short, isNotEmpty, reason: 'got $landings');
    });

    test('an overshoot never leaves the battlefield', () async {
      // Caster one tile inside the rim of a radius-2 field, aiming outward:
      // most of the 1..6 rolls would land off the edge if nothing walked them
      // back in.
      final caster = _avatar('caster', const HexCoord(-1, 0));
      _makeTurbulent(caster);
      final state = _state(
        [caster, _avatar('foe', const HexCoord(1, 0), teamId: 'b')],
        radius: 2,
      );

      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(1, 0), 25);

      expect(landings.every(state.battlefield.isInBounds), isTrue,
          reason: 'an off-board roll must be walked back onto the field, not '
              'resolved into the void: $landings');
    });

    test('a self-targeted cast has no direction to be thrown along', () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);

      // Three casts, not more: a Firey Blast on your own tile is 4 damage to
      // yourself, and a dead caster stops producing resolution events.
      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(0, 0), 3);

      expect(landings, everyElement(const HexCoord(0, 0)),
          reason: 'a cast on your own tile still lands on your own tile');
    });
  });

  // ── Duration ruling ───────────────────────────────────────────────────────

  group('turbulent persists', () {
    test('the SECOND and later casts are still randomised', () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);

      final landings =
          await _castRepeatedly(_loop(state, 'caster'), const HexCoord(5, 0), 25);
      // Drop the first cast: if the status were consumed on use, everything
      // after it would sit on the declared tile.
      final later = landings.skip(1);

      expect(later.any((h) => h != const HexCoord(5, 0)), isTrue,
          reason: 'Watery Inertia randomises every cast for its full 4[5] '
              'turns; it is not spent by the first one (ruling 2026-08-06)');
    });

    test('it stops once the status expires', () async {
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster, turns: 2);
      final state = _state([caster, _avatar('foe', const HexCoord(5, 0), teamId: 'b')]);
      final loop = _loop(state, 'caster');

      // Burn the duration, then keep casting: once it has ticked away every
      // cast must be back on the declared tile.
      await _castRepeatedly(loop, const HexCoord(5, 0), 3);
      final after = await _castRepeatedly(loop, const HexCoord(5, 0), 8);

      expect(after, everyElement(const HexCoord(5, 0)),
          reason: 'a 2-turn Watery Inertia must not randomise turn 12');
    });
  });

  // ── The effect actually lands on the rolled tile ──────────────────────────

  group('damage follows the roll', () {
    test('only the wizard on the ROLLED tile is hit — not the declared target',
        () async {
      // Bystanders on every tile from distance 2 out to 6, all on one team so
      // none of them melee each other, none adjacent to the caster so the
      // melee round never fires at all.
      final caster = _avatar('caster', const HexCoord(0, 0));
      _makeTurbulent(caster);
      final line = <HexCoord, WizardAvatar>{
        for (var d = 2; d <= 6; d++)
          HexCoord(d, 0): _avatar('foe$d', HexCoord(d, 0), teamId: 'b'),
      };
      final state = _state([caster, ...line.values]);
      final loop = _loop(state, 'caster');

      // One cast, declared at the far end of the line.
      final landed = await _castAt(loop, const HexCoord(6, 0));

      for (final entry in line.entries) {
        final expectHit = entry.key == landed;
        expect(
          entry.value.hp < 24,
          expectHit,
          reason: expectHit
              ? 'the spell resolved on ${entry.key} — that wizard must take '
                  'the damage'
              : 'the spell resolved on $landed, so ${entry.key} must be '
                  'untouched (the declared tile is NOT special once the roll '
                  'has moved the spell)',
        );
      }
    });
  });
}
