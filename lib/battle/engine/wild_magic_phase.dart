// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_phase.dart — collect → coalesce → order → resolve, for one
// simultaneous resolution batch (docs/WILD_MAGIC_PLAN_VNEXT.md slice 7).
//
// ── What changed, and why it needed a phase ───────────────────────────────────
//
// Before slice 7 wild magic was INTERLEAVED per cast: caster A's triggers fully
// resolved — terrain placed, bodies teleported, forced casts drained — before
// caster B's action was even examined. That reading of design v4.0 §1250
// ("within a single player's spell: wild magic first, then formula effects")
// cannot survive two casters firing the same effect in one moment: two Zephyrs
// teleported everyone twice, two Mountains raised six walls around each wizard,
// and two Spontaneous Combustions queued two forced casts per living wizard —
// each of them violating a bound that was ratified per FIRING and silently
// enforced nowhere else.
//
// The ratified wider reading (slice 7 R3) is:
//
//     all admission → all coalesced wild magic → all ordinary formula effects
//
// scoped to ONE simultaneous resolution batch (R1). Quick, Normal and Sluggish
// stay separate boundaries: they are temporally distinct groups that merely
// share a turn number, and merging them would make a Sluggish caster's Chasm
// open before a Quick caster's fireball landed.
//
// ── The 12-distinct-cells property, and why this file exists anyway ───────────
//
// `wildMagicEffectFor` is today a total function from 3 rows × 4 elements onto
// 12 DISTINCT effect kinds, and one cast's triggers are the cross product of
// its fired rows × its eligible elements — so within a single cast two triggers
// can never share an effect kind, and coalescing at the per-cast boundary would
// be pure ceremony. Every duplicate reachable today is CROSS-CAST inside one
// batch.
//
// That property is load-bearing and undocumented elsewhere; it stops being true
// the moment Mutable Leylines can remap (row, element) → effect. Which is why
// trigger PRODUCTION ([WildMagicTriggerRecord], built by the caller from
// certified semantics) is kept strictly separate from event COALESCING (here):
// a remap that lands two affinities of one cast on one effect kind then needs
// no new architecture, and the unresolved balanced-affinity policy (§9) plugs
// into the producer without touching this layer.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:rune_duel/battle/models/wild_magic_effect.dart';

// ── Canonical effect codes ────────────────────────────────────────────────────

/// Canonical Wild Magic effect codes.
///
/// **PINNED CONSENSUS ENCODING.** These numbers are two things at once: the
/// phase's resolution order (ascending), and a field of the coalesced event's
/// RNG preimage ([wildMagicEventSeed]).
///
/// Deliberately NOT `WildMagicEffectKind.index`, for the same reason
/// `WildMagic.kElementByte` is not `BorderZone.index`: reordering an enum for
/// any local reason (alphabetizing it, inserting a value) would otherwise
/// silently change both the resolution order and every event's RNG stream on
/// one device and not the other. Never renumber; append only.
///
/// The numbering reproduces today's row-then-element order exactly (row 1 →
/// 2 → 3, and within a row `fire, earth, water, air`), so ratifying it changes
/// no ordering — it only makes the ordering survive a table that becomes
/// mutable.
const Map<WildMagicEffectKind, int> kWildMagicEffectCode = {
  // Row 1 — `000`
  WildMagicEffectKind.burningHot: 0,
  WildMagicEffectKind.mountains: 1,
  WildMagicEffectKind.manaFlood: 2,
  WildMagicEffectKind.zephyr: 3,
  // Row 2 — `111`
  WildMagicEffectKind.spontaneousCombustion: 4,
  WildMagicEffectKind.chasm: 5,
  WildMagicEffectKind.glacier: 6,
  WildMagicEffectKind.updraft: 7,
  // Row 3 — `0123`
  WildMagicEffectKind.phoenix: 8,
  WildMagicEffectKind.statuesque: 9,
  WildMagicEffectKind.ripplingReflections: 10,
  WildMagicEffectKind.scatteredGusts: 11,
};

/// [kWildMagicEffectCode] as a total function. Throws rather than defaulting:
/// an effect kind with no pinned code is a consensus hole, and a silent 0 would
/// collide with Burning Hot.
int wildMagicEffectCode(WildMagicEffectKind effect) {
  final code = kWildMagicEffectCode[effect];
  if (code == null) {
    throw ArgumentError('no canonical wild-magic effect code pinned for $effect');
  }
  return code;
}

// ── Trigger records (production) ──────────────────────────────────────────────

/// One trigger, with the caster whose admitted cast carried it.
///
/// The caster travels with the trigger for ATTRIBUTION ONLY — it names who is
/// blamed on the reveal card. It is deliberately not part of the coalescing key
/// and never reaches [wildMagicEventSeed]: wild magic is symmetric, so who fired
/// it must not be able to change what it does.
class WildMagicTriggerRecord {
  const WildMagicTriggerRecord(this.casterId, this.trigger);

  final String casterId;
  final WildMagicTrigger trigger;

  WildMagicEffectKind get effect => trigger.effect;

  @override
  String toString() => 'WildMagicTriggerRecord($casterId, $trigger)';
}

// ── Coalesced events ──────────────────────────────────────────────────────────

/// One wild-magic WORLD EVENT: everything a batch's triggers of a single effect
/// kind collapse into.
///
/// The unit the applicator resolves, and the unit the player is shown. Two
/// Zephyrs in one batch are ONE gale, not two.
class CoalescedWildMagicEvent {
  CoalescedWildMagicEvent({
    required this.effect,
    required this.effectiveBracketSteps,
    required List<String> contributingCasterIds,
  }) : contributingCasterIds = List.unmodifiable(contributingCasterIds);

  final WildMagicEffectKind effect;

  /// `max` of every contributing trigger's `bracketSteps` (R4/R5).
  ///
  /// Maximum, never a sum: bracket scaling is the design's one power axis, and
  /// two casters who both happen to roll the same effect have not between them
  /// rolled a stronger run than the stronger of them did.
  final int effectiveBracketSteps;

  /// Every caster whose admitted cast contributed a trigger, deduplicated and
  /// sorted by playerId. Attribution for the reveal card — see
  /// [WildMagicTriggerRecord].
  final List<String> contributingCasterIds;

  int get effectCode => wildMagicEffectCode(effect);

  @override
  String toString() =>
      'CoalescedWildMagicEvent(${effect.name}, bracket: $effectiveBracketSteps, '
      'by: $contributingCasterIds)';
}

/// Collapses one batch's triggers into its world events, in canonical
/// resolution order.
///
/// The coalescing key is **the effect kind alone**. Not the caster, the
/// affinity, the spell, the row, the commitment, or arrival order — a world
/// event is identified by what happens to the world, and everything else about
/// how it got there is attribution.
///
/// Three properties this must keep, each pinned by a test:
///
///   * **Contributor order cannot matter.** Records may arrive in any order;
///     the result — including `effectiveBracketSteps` and every event's RNG
///     stream — is identical. (`max` is commutative; the caster list is sorted;
///     ordering is by pinned effect code, never by first appearance.)
///   * **An equal duplicate changes nothing.** A second contributor at the same
///     bracket adds a name to `contributingCasterIds` and nothing else, so it
///     cannot reroll the event.
///   * **Ordering is by [kWildMagicEffectCode]**, ascending — which is today's
///     row-then-element order, expressed so a remapped table cannot move it.
List<CoalescedWildMagicEvent> coalesceWildMagicTriggers(
  Iterable<WildMagicTriggerRecord> records,
) {
  final brackets = <WildMagicEffectKind, int>{};
  final casters = <WildMagicEffectKind, Set<String>>{};
  for (final record in records) {
    final effect = record.effect;
    final steps = record.trigger.bracketSteps;
    final existing = brackets[effect];
    brackets[effect] = existing == null || steps > existing ? steps : existing;
    (casters[effect] ??= <String>{}).add(record.casterId);
  }
  final effects = brackets.keys.toList()
    ..sort((a, b) => wildMagicEffectCode(a).compareTo(wildMagicEffectCode(b)));
  return [
    for (final effect in effects)
      CoalescedWildMagicEvent(
        effect: effect,
        effectiveBracketSteps: brackets[effect]!,
        contributingCasterIds: casters[effect]!.toList()..sort(),
      ),
  ];
}

// ── The coalesced-event RNG ───────────────────────────────────────────────────

/// Domain tag for a COALESCED WILD-MAGIC EVENT's RNG stream.
///
/// New in slice 7 and distinct from every existing tag. `0x09` remains the
/// per-PLAYER wild-magic tag and is now used only by the forced-cast drain and
/// the bookmark burn; nothing in the applicator reads it any more.
const int kWildMagicEventRngDomain = 0x0C;

/// The largest `effectiveBracketSteps` the preimage can encode.
const int kMaxWildMagicBracketSteps = 0xFF;

/// The RNG seed for one coalesced wild-magic event.
///
/// ```
/// preimage = entropy[32]
///          ‖ matchId[N]?                      // when non-null, as _phaseSeed
///          ‖ uint32be(turnNumber)             // 4 bytes
///          ‖ uint8(batchCode)                 // canonical resolution batch
///          ‖ uint8(0x0C)                      // kWildMagicEventRngDomain
///          ‖ uint8(effectCode)                // kWildMagicEffectCode, 0..11
///          ‖ uint8(effectiveBracketSteps)     // range-checked, not truncated
/// seed     = SHA-256(preimage)
/// ```
///
/// ── Why this is not `TurnLoop._playerPhaseSeed` ──────────────────────────────
/// Every other per-thing seed in the engine is
/// `SHA-256(_phaseSeed(entropy, matchId, turn, tag) ‖ playerId ‖ uint32be(nonce))`
/// — keyed on a PLAYER and on an ENCOUNTER-ORDER NONCE, and a coalesced event
/// has neither. It is not one caster's roll (it may have several contributors,
/// or, after a Phoenix save, none), and its stream must not move when the order
/// triggers were encountered in moves. So the fields that made that
/// construction wrong are simply absent, and the preimage is written flat here
/// rather than nested: this is a different key, not a variation on that one.
///
/// It cannot collide with a `_phaseSeed`/`_playerPhaseSeed` preimage — those are
/// respectively 3 bytes shorter after the turn number and prefixed by a 32-byte
/// digest rather than by raw entropy — and the `0x0C` tag separates it from
/// every other domain regardless.
///
/// ── The properties this buys ─────────────────────────────────────────────────
///   * **Same semantic event in the same batch → same RNG.** Every field is a
///     property of the event itself.
///   * **Contributor encounter order cannot matter.** No playerId, no nonce, no
///     counter, no contributor list or hash, no set iteration.
///   * **An equal duplicate trigger does not reroll the event.** A second
///     contributor at the same bracket changes no field of the preimage.
///   * **Different batches in one turn never share a stream** — that is exactly
///     what `batchCode` is for; without it a Quick Chasm and a Normal Chasm on
///     the same turn would open the same axis.
///   * **A stronger bracket DOES change the stream**, deliberately: a Chasm at
///     bracket 2 is a different world event from one at bracket 0, so it is
///     entitled to a different axis. This is a rule, not an accident.
///   * Reads only joint entropy, the match, the turn, the batch and the event's
///     own public identity. No proof bytes, no private state, no UI state, no
///     wall clock, no object identity.
Uint8List wildMagicEventSeed({
  required Uint8List entropy,
  Uint8List? matchId,
  required int turnNumber,
  required int batchCode,
  required int effectCode,
  required int effectiveBracketSteps,
}) {
  if (batchCode < 0 || batchCode > 0xFF) {
    throw ArgumentError('batchCode $batchCode does not fit a uint8');
  }
  if (effectCode < 0 || effectCode > 0xFF) {
    throw ArgumentError('effectCode $effectCode does not fit a uint8');
  }
  // Range-checked rather than masked: a bracket that silently wrapped would
  // give a bracket-256 event the bracket-0 event's stream, which is a fork with
  // nothing to signal it. Unreachable in play (a 259-character run of one hex
  // digit in a 64-character digest), checked because the ENCODER's bound
  // belongs next to the encoder.
  if (effectiveBracketSteps < 0 ||
      effectiveBracketSteps > kMaxWildMagicBracketSteps) {
    throw ArgumentError(
      'effectiveBracketSteps $effectiveBracketSteps is outside the canonical '
      'unsigned 8-bit range',
    );
  }
  final buf = BytesBuilder(copy: false)..add(entropy);
  if (matchId != null) buf.add(matchId);
  buf
    ..addByte((turnNumber >> 24) & 0xFF)
    ..addByte((turnNumber >> 16) & 0xFF)
    ..addByte((turnNumber >> 8) & 0xFF)
    ..addByte(turnNumber & 0xFF)
    ..addByte(batchCode)
    ..addByte(kWildMagicEventRngDomain)
    ..addByte(effectCode)
    ..addByte(effectiveBracketSteps);
  return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
}
