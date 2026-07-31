// SPDX-License-Identifier: GPL-3.0-or-later
//
// illusion_melee_redirect_test.dart — Water-Air Illusions (Water flavor),
// melee-punch path: TurnLoop._redirectIfIllusion.
//
// Behavior as of 2026-07-31: a melee punch that redirects onto an illusion
// decoy destroys the decoy and does NOTHING ELSE — no damage, no position
// change, no haymaker side effect (slow/DoT/status-drain). Previously the
// real wizard was also teleported onto the decoy's tile on a dodge; that was
// removed as a deliberate simplification (a melee dodge has no "chasing the
// illusion's last position" framing the way a formula effect does — see
// EffectApplicator._resolveIllusionRedirect, which keeps the teleport).
//
// TurnLoop._redirectIfIllusion draws from math.Random.secure() (via
// CommitRevealEntropy.generateNonce(), with no test seam to fix the seed),
// so which branch (real hit vs. decoy hit) fires on a given turn can't be
// forced. Tests below run many independent single-turn trials and assert
// invariants against whichever branch that trial actually took, rather than
// pinning the RNG — the standard technique this codebase uses elsewhere for
// unseedable randomness (see artifact_activation_test.dart's saturating
// probabilities for the same problem solved a different way).

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/illusion.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

const _localId = 'local';
const _dummyId = 'dummy';
const _localPos = HexCoord(0, 0);
const _dummyPos = HexCoord(1, 0); // adjacent — a valid melee target

/// Fresh single-turn setup: local punches the adjacent dummy, who carries
/// [decoyCount] illusion decoys. The dummy never melees back (SoloBattleSession
/// default), so only the one punch under test ever touches the shared
/// meleeRng stream.
({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy})
_setup(int decoyCount) {
  final battlefield = Battlefield(radius: 6);
  battlefield.occupancy[_localId] = _localPos;
  battlefield.occupancy[_dummyId] = _dummyPos;

  final local = WizardAvatar(
    playerId: _localId,
    ownerPubkeyHex: '0x${'00' * 32}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: _localPos,
    teamId: 'solo',
    baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: _dummyId,
    ownerPubkeyHex: '0x${'00' * 32}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: _dummyPos,
    teamId: 'foe',
    baseSpellRange: 3,
  );

  final state = BattleState(
    config: const MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      const Team(id: 'solo', playerIds: [_localId]),
      const Team(id: 'foe', playerIds: [_dummyId]),
    ],
    battlefield: battlefield,
    wizardIllusions: [
      WizardIllusionSet(
        ownerId: _dummyId,
        decoyPositions: [
          for (var i = 0; i < decoyCount; i++) HexCoord(5 + i, 5),
        ],
      ),
    ],
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: _localId,
    meleeTargetPicker: (candidates) async => candidates.first,
  );
  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('a melee punch redirected onto an illusion decoy', () {
    test('never moves the real wizard, in either branch, across many trials',
        () async {
      // n=2 keeps both branches genuinely likely (P(real hit) = 1/2) so this
      // exercises the redirect path itself, not just the "only one outcome
      // is reachable" degenerate case.
      for (var trial = 0; trial < 40; trial++) {
        final ctx = _setup(2);
        await ctx.loop.runTurn(TurnInput(action: PassAction()));

        expect(ctx.dummy.position, equals(_dummyPos),
            reason: 'trial $trial: the real wizard must never move, whether '
                'the punch was redirected onto a decoy or landed for real — '
                'the old teleport-onto-the-decoy-tile behavior is gone');

        final decoysLeft = ctx.state.wizardIllusions
                .where((s) => s.ownerId == _dummyId)
                .firstOrNull
                ?.decoyPositions
                .length ??
            0;

        if (decoysLeft < 2) {
          // This trial redirected: the decoy died, and NOTHING else may have
          // happened to the real wizard — no damage, no status effect.
          expect(decoysLeft, equals(1), reason: 'exactly one decoy dies');
          expect(ctx.dummy.hp, equals(24),
              reason: 'trial $trial: a redirected punch deals no damage');
          expect(ctx.dummy.activeStatusEffects, isEmpty,
              reason: 'trial $trial: a redirected punch applies no haymaker '
                  'side effect (nothing to drain/slow/DoT — the punch never '
                  'landed)');
        } else {
          // This trial hit the real wizard: normal haymaker damage, no decoy
          // lost.
          expect(ctx.dummy.hp, equals(23),
              reason: 'trial $trial: the real wizard took the base 1 damage');
        }
      }
    });

    test('a redirected punch never adds Fire haymaker DoT to the real wizard',
        () async {
      // Regression for the bug this change exposed: without the old
      // teleport, a naive DoT sweep that re-queries avatars by tile position
      // (rather than tracking who was actually hit) would otherwise stack
      // DoT onto a wizard whose punch was fully absorbed by a decoy.
      for (var trial = 0; trial < 40; trial++) {
        final ctx = _setup(2);
        // hasHaymakerDot reads the ACTOR's own effects, so the buff goes on
        // the puncher, not the victim.
        ctx.local.activeStatusEffects.add(
          StatusEffect(effectTypeId: 'haymakerDot', remainingTurns: 1),
        );

        await ctx.loop.runTurn(TurnInput(action: PassAction()));

        final decoysLeft = ctx.state.wizardIllusions
                .where((s) => s.ownerId == _dummyId)
                .firstOrNull
                ?.decoyPositions
                .length ??
            0;
        final wasRedirected = decoysLeft < 2;

        final dotStacks = ctx.dummy.activeStatusEffects
            .where((fx) => fx.effectTypeId == 'haymakerDot')
            .toList();

        if (wasRedirected) {
          expect(dotStacks, isEmpty,
              reason: 'trial $trial: a redirected punch must not stack DoT '
                  'onto the real wizard');
        } else {
          expect(dotStacks, hasLength(1),
              reason: 'trial $trial: a punch that actually lands still '
                  'applies Fire haymaker DoT normally');
        }
      }
    });

    test('a decoy hit still kills the decoy immediately', () async {
      // n=2 makes a decoy-hit trial common (P ≈ 1/2); loop until we've
      // actually observed one rather than trusting a single roll.
      var sawDecoyHit = false;
      for (var trial = 0; trial < 40 && !sawDecoyHit; trial++) {
        final ctx = _setup(2);
        await ctx.loop.runTurn(TurnInput(action: PassAction()));
        final decoysLeft = ctx.state.wizardIllusions
                .where((s) => s.ownerId == _dummyId)
                .firstOrNull
                ?.decoyPositions
                .length ??
            0;
        if (decoysLeft < 2) sawDecoyHit = true;
      }
      expect(sawDecoyHit, isTrue,
          reason: 'did not observe a decoy-hit branch in 40 trials at n=2 '
              'decoys — either the RNG changed shape or the redirect chance '
              'itself is broken');
    });
  });
}
