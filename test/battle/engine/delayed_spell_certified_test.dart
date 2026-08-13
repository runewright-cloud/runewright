// SPDX-License-Identifier: GPL-3.0-or-later
//
// delayed_spell_certified_test.dart — the B-1 trust boundary, extended across
// a Mystery delay.
//
// ## The hole this covers
//
// `_verifyPeerSpellCast` re-derives a peer cast's formulas, element sequence
// and wild-magic triggers from the VERIFIED proof outputs, because nothing
// binds `SpellAsset.formula` to the proof — the commitment is grid-only
// (CLAUDE.md invariant 2), so the wire formula is free text a modified client
// can write anything into.
//
// That certified data used to live only in `runTurn`'s turn-scoped maps. A
// Mystery cast resolves up to three turns after it is declared, by which time
// the maps are cleared, so the fire fell back to `spell.formula`. Both devices
// fell back identically, so the state hash never caught it: **desync-safe but
// not trust-safe**. A peer could prove a cheap grid, attach whatever formulas
// they liked, and have those resolve — provided they routed the cast through a
// Mystery delay.
//
// The fix carries a [CertifiedCast] on the [PendingDelayedSpell]. These tests
// are the negative vectors for it (CLAUDE.md §10/§11 pairing): they FAIL
// against the pre-fix engine, which is the only thing that makes them
// meaningful. See docs/M4_findings.md M4.15.
//
// ## How the lie is observed
//
// `activeChainElement` is consensus state (design doc R3 — chain purity) and
// is derived straight from the resolved formulas, so it reports which source
// resolution actually read:
//
//   certified trajectory : 3 supreme EARTH activations → chain earth
//   wire `formula`       : ['fire', 'fire', 'fire']    → chain fire

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/pending_delayed_spell.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

void main() {
  test(
      'a delayed fire resolves from the CERTIFIED trajectory, not the wire '
      'formula it was declared with', () async {
    final r = await _declareAndFireMystery();

    // The lie was ['fire','fire','fire']; the proof attests earth.
    expect(
      r.chainOnPeerDevice,
      equals(SpellAffinity.earth),
      reason: 'the verifier resolved the delayed fire from the wire formula — '
          'a peer can prove a cheap grid, attach any formulas they like, and '
          'cash them in three turns later',
    );
    expect(
      r.chainOnCasterDevice,
      equals(SpellAffinity.earth),
      reason: 'the caster\'s own device must read the same certified source, '
          'or honest clients diverge on the very cast this fix touches',
    );
    expect(
      r.chainOnPeerDevice,
      isNot(equals(SpellAffinity.fire)),
      reason: 'fire is the wire claim; reading it here is the whole bug',
    );
  });

  test('the certified semantics are captured on the DECLARATION turn',
      () async {
    final r = await _declareAndFireMystery();

    expect(r.pendingCertifiedAffinities, isNotNull,
        reason: 'a pending Mystery with no CertifiedCast has nothing to '
            'resolve from later but the wire formula');
    expect(
      r.pendingCertifiedAffinities,
      everyElement(equals(BorderZone.earth)),
      reason: 'captured from the proof, not from spell.formula',
    );
  });

  test('carrying the certified data does not break lockstep', () async {
    final r = await _declareAndFireMystery();
    expect(r.canonicalMatches, isTrue,
        reason: 'both devices derive the CertifiedCast independently — the '
            'owner from its own proof, the verifier from the outputs it '
            'verified — so it must never be a source of divergence');
  });
}

// ── Harness ───────────────────────────────────────────────────────────────────

typedef _Result = ({
  SpellAffinity? chainOnCasterDevice,
  SpellAffinity? chainOnPeerDevice,
  List<BorderZone>? pendingCertifiedAffinities,
  bool canonicalMatches,
});

/// player_a declares a Mystery spell on turn 1 and fires it on turn 2;
/// player_b passes throughout. Runs two real TurnLoops in lockstep.
Future<_Result> _declareAndFireMystery() async {
  final stateCaster = makeDuelState();
  final statePeer = makeDuelState();

  final pair = TurnSessionPair();
  final loopCaster = TurnLoop(
    state: stateCaster,
    session: pair.sessionA,
    localPlayerId: 'player_a',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
  );
  final loopPeer = TurnLoop(
    state: statePeer,
    session: pair.sessionB,
    localPlayerId: 'player_b',
    verifyProof: alwaysOk,
    vkBytes: Uint8List(0),
  );

  final spell = forgedSpell();
  loopCaster.localChapterCommitments = [spell.commitmentHex];

  const targetTile = HexCoord(1, 0);
  const delay = 1;
  final nonce = Uint8List.fromList(List.generate(16, (i) => i));
  final commitment = await PendingDelayedSpell.commitmentHash(
    target: targetTile,
    delay: delay,
    nonce: nonce,
  );

  // Turn 1 — declare. The commitment hides the target and the delay; the
  // spell itself (and its wire formula) is public from this moment.
  await Future.wait([
    loopCaster.runTurn(TurnInput(
      action: MysterySpellCastAction(
        spell: spell,
        mysteryCommitment: commitment,
      ),
    )),
    loopPeer.runTurn(TurnInput(action: PassAction())),
  ], eagerError: true).timeout(const Duration(seconds: 20));

  // Snapshot what the VERIFIER stored: the attacker's own device is not the
  // interesting side, since an attacker controls it anyway.
  final pending = statePeer.pendingDelayedSpells.singleOrNull;
  final certified = pending?.certified;

  // The exchange slots are one-shot Completers, one set per turn.
  pair.reset();

  // Turn 2 — the delay elapses and the spell fires.
  await Future.wait([
    loopCaster.runTurn(TurnInput(
      action: PassAction(),
      delayedSpellReveals: [
        DelayedSpellReveal(
          pendingSpellId: pending?.id ?? '',
          targetTile: targetTile,
          delay: delay,
          nonce: nonce,
        ),
      ],
    )),
    loopPeer.runTurn(TurnInput(action: PassAction())),
  ], eagerError: true).timeout(const Duration(seconds: 20));

  SpellAffinity? chainOf(BattleState s) =>
      s.avatars.firstWhere((av) => av.playerId == 'player_a').activeChainElement;

  return (
    chainOnCasterDevice: chainOf(stateCaster),
    chainOnPeerDevice: chainOf(statePeer),
    pendingCertifiedAffinities:
        certified?.formulas.map((f) => f.affinity).toList(),
    canonicalMatches: bytesEqual(
      stateCaster.toCanonicalBytes(),
      statePeer.toCanonicalBytes(),
    ),
  );
}
