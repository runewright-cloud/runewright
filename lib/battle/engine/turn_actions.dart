// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_actions.dart — the declared actions a turn resolves, and the two UI
// event records action resolution emits.
//
// Split out of `turn_loop.dart` for exactly the reason `battle_events.dart`
// was: action resolution now lives behind the deterministic seam
// (`deterministic_resolution.dart`), and it must be able to name a
// `SpellCastAction` without importing the 6k-line file that owns the network
// protocol. Everything here is re-exported from `turn_loop.dart`, so every
// existing `import '.../turn_loop.dart'` naming these keeps compiling.
//
// What did NOT come across: `TurnInput` and `DelayedSpellReveal`. Those are the
// *local player's* declarations on the way in — protocol input, consumed by
// `TurnLoop.runTurn` before anything is trusted — and nothing behind the seam
// ever sees one.

import 'dart:typed_data';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import '../../sorcerer/incantation_recall.dart';
import '../models/effect_descriptor.dart' show SpellAffinity;

/// One player's declared action for this turn.
sealed class TurnAction {}

class SpellCastAction extends TurnAction {
  SpellCastAction({
    required this.spell,
    required this.targetHex,
    this.isPotent = false,
    this.isVelocity = false,
    this.isEfficiency = false,
    this.recall,
    this.conveyorDirection,
    this.delayedOriginHex,
    this.delayedRange,
    this.handIndex,
    this.isDelayedRealization = false,
  });

  final SpellAsset spell;
  final HexCoord targetHex;
  final bool isPotent;
  final bool isVelocity;
  final bool isEfficiency;

  /// The caster's own hand slot this cast came from, when known — the only
  /// duplicate-safe key for building this cast's chapter-membership Merkle
  /// proof (docs/BASIC_SPELLS_PLAN.md §7): a chapter may hold several copies
  /// of the same Basic spell, so `spell.commitmentHex` alone cannot tell
  /// [TurnLoop] WHICH copy's slot to prove. Null falls back to a
  /// commitment-based lookup (BookCommitment.proveMembership), which is only
  /// correct for a chapter with no duplicate of this spell — true for every
  /// non-Basic spell today, and for solo/test construction sites that never
  /// set this.
  final int? handIndex;

  /// What the caster's device heard them recite. Null in Wizard mode.
  ///
  /// Slot indices only, never words (VOCAL_RECALL_PLAN.md §8.10.1). Set by the
  /// caster's device and committed inside the action hash; populated on the
  /// receiving side by decoding the transmitted bytes. The peer scores it by
  /// recomputing the EXPECTED sequence from the certified trajectory, which is
  /// what makes recall verifiable where pronunciation quality never was.
  final IncantationRecall? recall;

  /// Set at commit time when the recall-inflated cost exceeded the caster's
  /// mana: the cast fizzles and the mana is refunded, but the turn is spent
  /// (§4). NOT transmitted — each device computes it from the same certified
  /// cost and the same avatar mana, so both arrive at the same answer.
  bool fizzledForMana = false;

  /// The caster's chosen push direction, if this cast will create a
  /// ConveyorTile (Air-flavor tileModification) and the caster picked one
  /// via the battle_screen.dart direction prompt. Null falls back to a
  /// random direction (EffectApplicator._randomDirection) -- always the case
  /// for Mystery/delayed-fire casts this pass (see turn_loop.dart handoff
  /// notes), and the seam for a future real-time choose-or-timeout mode.
  final HexCoord? conveyorDirection;

  /// Set only when this action is a delayed Mystery reveal firing this turn:
  /// the caster's board position at the original cast turn, used as the
  /// cast-animation launch origin instead of the caster's current position
  /// (which may have moved many turns since). Null for a same-turn cast.
  final HexCoord? delayedOriginHex;

  /// Companion to [delayedOriginHex]: the caster's spell range on the turn
  /// this Mystery cast was declared, carried through from
  /// [PendingDelayedSpell.declaredRange]. The range check reads this instead
  /// of the caster's range now, so a rangeDown landed while the spell was
  /// pending cannot retroactively invalidate it. Null for a same-turn cast,
  /// which uses the turn's pre-movement snapshot instead.
  ///
  /// Local-only, like [delayedOriginHex]: both peers rebuild this action from
  /// their own copy of `state.pendingDelayedSpells`, so it never crosses the
  /// wire.
  final int? delayedRange;

  /// True when this action is the ENGINE firing a previously declared delayed
  /// Mystery, rather than a player declaring a cast this turn.
  ///
  /// Set at exactly one site — `TurnLoop._verifyAndCollectDelayedFires`, the
  /// only place a [PendingDelayedSpell] becomes a [SpellCastAction] — and left
  /// false everywhere else, including the immediate-Mystery rewrite
  /// (`_verifyMysteryAction`), which really is a fresh declaration.
  ///
  /// This is the VOLUNTARY/INVOLUNTARY boundary for everything that keys off
  /// player intent, and it exists because the two are otherwise indistinguishable
  /// by the time they reach resolution: a delayed fire arrives wearing the same
  /// type as a fresh cast. Today two effects read it — Statuesque
  /// (`breaksStatuesque`) and Scattered Gusts — and both take the same view:
  ///
  ///     The wizard's voluntary act was the DECLARATION, on some earlier turn.
  ///     The automatic realization is the engine keeping that promise, not the
  ///     wizard choosing again.
  ///
  /// So a delayed spell declared before an effect armed must not trip it on the
  /// way out, and the declaration itself — a [MysterySpellCastAction] — is what
  /// trips it instead. Do NOT reconstruct this from turn numbers, and do not
  /// infer it from [delayedOriginHex] being non-null: that field exists to place
  /// a cast animation, and something that happens to correlate today is not the
  /// same as something that means this.
  ///
  /// Local-only, like [delayedOriginHex] and [delayedRange] — both devices
  /// rebuild the action from their own `state.pendingDelayedSpells`, so it never
  /// crosses the wire and cannot be claimed by a peer.
  final bool isDelayedRealization;
}

/// Main-phase Dash: doubles the caster's movement budget for this turn's
/// move phase. See turn_loop.dart's header comment for why the flag travels
/// inside the movement commit-reveal rather than the action reveal.
class DashAction extends TurnAction {}

/// Main-phase Meditate: forgo casting for +25 mana. Independent of (and
/// stacks with) a move-phase Meditate — see [TurnInput.meditateInMove].
class MeditateAction extends TurnAction {}

class PassAction extends TurnAction {}

/// A mystery-enhanced spell. Target tile and delay are hidden in
/// [mysteryCommitment] until revealed. If [delay] == 0 the player chose to
/// fire immediately: [immediateTarget] and [immediateNonce] are also set and
/// the spell resolves this turn. Otherwise the spell is held as a
/// [PendingDelayedSpell] and fired by a future [DelayedSpellReveal].
class MysterySpellCastAction extends TurnAction {
  MysterySpellCastAction({
    required this.spell,
    required this.mysteryCommitment,
    this.immediateTarget,
    this.immediateNonce,
    this.isPotent = false,
    this.isVelocity = false,
    this.recall,
    this.handIndex,
  });

  final SpellAsset spell;

  /// SHA-256(encodeCoord(target) ‖ delay_byte ‖ nonce_16). 32 bytes.
  final Uint8List mysteryCommitment;

  /// Non-null iff delay == 0 (fire this turn).
  final HexCoord? immediateTarget;
  final Uint8List? immediateNonce; // 16 bytes

  final bool isPotent;
  final bool isVelocity;

  /// See [SpellCastAction.recall].
  final IncantationRecall? recall;

  /// See [SpellCastAction.fizzledForMana].
  bool fizzledForMana = false;

  /// See [SpellCastAction.handIndex].
  final int? handIndex;

  bool get isImmediate => immediateTarget != null;
}

/// One elemental spell cast resolved this turn — UI-only bookkeeping for the
/// cast animation (orb glows at the caster, flies to the target, bursts).
/// Carries no gameplay effect; [TurnLoop] never reads these back.
class SpellCastEvent {
  const SpellCastEvent({
    required this.casterId,
    required this.fromHex,
    required this.toHex,
    required this.affinity,
  });

  final String casterId;
  final HexCoord fromHex;
  final HexCoord toHex;
  final SpellAffinity affinity;
}

/// One spell resolved this turn, in resolution order — drives the UI's
/// MtG-style card reveal sequence (battle_screen.dart): each entry is shown
/// full-card for 2s, then becomes a thumbnail (neutral tray for incantations,
/// on-grid for summons). [summonMinionId]/[summonPosition] are set only when
/// [isSummon] is true and the summon actually spawned (null for a void/no-op
/// summon cast — no thumbnail to place).
///
/// Counter charms are attuned to an elemental trajectory and cancel a cast
/// FORMULA BY FORMULA while the charm's sequence and the spell's stay in
/// lockstep (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2.2/§2.3), so a counter is no
/// longer all-or-nothing:
///
///   * [counteredFormulas] > 0 means a charm fired and cancelled that many
///     leading formulas. [counterCharmOwnerId] then names who owns the
///     triggered charm, which may equal [casterId] (a charm counters any
///     matching cast, including its own owner's).
///   * [wasCountered] is the FULL-counter case: the charm swallowed every
///     formula, so the cast never resolved at all and this event has empty
///     summon/created-effect fields.
///
/// A partially countered cast resolved for real — it has its created clouds,
/// tiles and minions, and its wild magic fired — it just did less than it
/// would have. UI that means "nothing happened" must test [wasCountered];
/// UI that means "a charm fired" must test [counteredFormulas].
class ResolvedSpellEvent {
  const ResolvedSpellEvent({
    required this.spell,
    required this.casterId,
    required this.targetHex,
    required this.isSummon,
    this.summonMinionId,
    this.summonPosition,
    this.createdCloudIds = const [],
    this.createdTileHexes = const [],
    this.createdMinionIds = const [],
    this.wasCountered = false,
    this.counteredFormulas = 0,
    this.counterCharmOwnerId,
  });

  final SpellAsset spell;
  final String casterId;
  final HexCoord targetHex;
  final bool isSummon;
  final String? summonMinionId;
  final HexCoord? summonPosition;
  final bool wasCountered;

  /// Leading formulas a counter charm cancelled — 0 when no charm fired.
  /// Equal to the spell's whole formula count exactly when [wasCountered].
  final int counteredFormulas;

  final String? counterCharmOwnerId;

  /// Battlefield effects this spell brought into being — purely for the UI's
  /// resolution reveal, which holds them off the field until the spell's card
  /// finishes, then blooms them out of [targetHex]. Computed by a before/after
  /// diff around the spell's application (see
  /// [DeterministicResolution.resolveActions]); not serialized, not
  /// gameplay-authoritative.
  final List<String> createdCloudIds;
  final List<HexCoord> createdTileHexes;
  final List<String> createdMinionIds;
}
