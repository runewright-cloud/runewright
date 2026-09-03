// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_state.dart — WildMagicState: the persistent, match-scoped state
// wild-magic effects write to (docs/WILD_MAGIC_PLAN.md §7.3).
//
// Lives on BattleState as `wildMagic`. EVERY field here is consensus state and
// is encoded in BattleState.toCanonicalBytes — every collection sorted, because
// Dart Set/Map iteration is insertion-ordered and two clients that add the same
// players in different orders would otherwise produce different bytes from
// identical game state (§7.4, the top desync risk in this system).
//
// Nothing here is per-turn scratch: anything that should not survive the turn
// belongs in TurnLoop's per-turn event lists instead.
//
// ── The ratified timing rule (Slice 4) ────────────────────────────────────────
//
//     An effect that triggers during round R arms beginning with round R+1.
//     It must not affect any later action or resolution still inside round R.
//     A two-round effect is active during R+1 and R+2, and is gone before the
//     first voluntary action of R+3.
//
// The clock is `BattleState.turnNumber` — the simultaneous combat round, and
// deliberately the ONLY round counter. `TurnLoop.runTurn` increments it once at
// the top, so `state.turnNumber` reads R for the whole of round R, and an
// effect armed during R stores `activeFromTurn = R + 1`.
//
// Every window is expressed as [WildMagicWindow], an INCLUSIVE
// `activeFromTurn .. expiresAfterTurn` pair, rather than as a bare "turn + 2"
// whose inclusivity you have to reconstruct from its readers. Two consequences
// worth stating:
//
//   * There is no pending→active promotion step and no pending set. A window
//     that does not contain the current round is simply not active, so "the
//     cast that fired it cannot break/benefit from it this round" falls out of
//     the representation instead of being maintained by a second collection.
//     (This replaced `pendingStatuesquePlayerIds`, which existed only to
//     express that delay.)
//   * Re-arming takes the UNION of the two windows — earliest start, latest
//     end — so a retrigger can lengthen protection and can never shorten it,
//     whichever order the two triggers land in.
//
// Expiry is swept once per round at a single boundary
// (`DeterministicResolution.resolveWildMagicRoundStart`), so an expired window
// never lingers in the state hash. Every read here ALSO bounds-checks the
// round, so correctness does not depend on the sweep having run — the sweep is
// about canonical cleanliness, the check is about behaviour.

import 'dart:math' show max, min;

/// An inclusive round window: active on every round from [activeFromTurn]
/// through [expiresAfterTurn].
///
/// A one-round effect has `activeFromTurn == expiresAfterTurn`.
class WildMagicWindow {
  const WildMagicWindow({
    required this.activeFromTurn,
    required this.expiresAfterTurn,
  });

  /// The window an effect triggering on [triggerTurn] arms: it starts on the
  /// NEXT round and covers [rounds] of them.
  ///
  /// The `+ 1` lives here, in one place, so no call site can get the
  /// "arms next round" rule off by one.
  factory WildMagicWindow.armedOn(int triggerTurn, {required int rounds}) {
    assert(rounds >= 1, 'a window must cover at least one round');
    return WildMagicWindow(
      activeFromTurn: triggerTurn + 1,
      expiresAfterTurn: triggerTurn + rounds,
    );
  }

  /// First round on which the effect applies. Inclusive.
  final int activeFromTurn;

  /// Last round on which the effect applies. Inclusive — the effect is gone
  /// from `expiresAfterTurn + 1` onward.
  final int expiresAfterTurn;

  /// True on every round the effect is in force.
  bool isActiveOn(int turn) =>
      turn >= activeFromTurn && turn <= expiresAfterTurn;

  /// True while the effect is armed but has not started yet — round R for a
  /// window armed during R.
  bool isScheduledOn(int turn) => turn < activeFromTurn;

  /// True once the window is spent. The round-start sweep drops these.
  bool hasExpiredBy(int turn) => turn > expiresAfterTurn;

  /// The union of two windows: earliest start, latest end.
  ///
  /// The one merge rule for every re-arm. A later trigger extends the end and
  /// leaves the earlier start alone, so protection can only ever grow — taking
  /// the later start instead would open a hole in the middle, and taking the
  /// earlier end would shorten a window a player has already been promised.
  WildMagicWindow mergedWith(WildMagicWindow other) => WildMagicWindow(
        activeFromTurn: min(activeFromTurn, other.activeFromTurn),
        expiresAfterTurn: max(expiresAfterTurn, other.expiresAfterTurn),
      );

  @override
  bool operator ==(Object other) =>
      other is WildMagicWindow &&
      other.activeFromTurn == activeFromTurn &&
      other.expiresAfterTurn == expiresAfterTurn;

  @override
  int get hashCode => Object.hash(activeFromTurn, expiresAfterTurn);

  @override
  String toString() => 'turns $activeFromTurn..$expiresAfterTurn';
}

class WildMagicState {
  WildMagicState();

  // ── Round counts (docs/WILD_MAGIC_PLAN_VNEXT.md §12, §13) ─────────────────

  /// Phoenix and Statuesque both cover the two rounds after the one they fire
  /// on; Rippling Reflections covers exactly one. None of the three scales
  /// with `bracketSteps` — bracket scaling is a strength axis for the effects
  /// that have one, not a duration axis for these.
  static const int kPhoenixRounds = 2;
  static const int kStatuesqueRounds = 2;
  static const int kRipplingRounds = 1;

  // ── Burning Hot (row 1, Fire) ─────────────────────────────────────────────
  //
  // Already next-round-armed and one round long — the reference implementation
  // of the timing rule above, and unchanged by Slice 4.

  /// +N damage added to every spell damage effect, on one specific turn.
  /// Active iff `state.turnNumber == spellDamageBonusTurn`.
  ///
  /// Applies to EVERY player's spells (symmetry) once per damage effect — so a
  /// three-formula spell gets it three times.
  ///
  /// Stacks by SUMMING when two SEPARATE Burning Hot world events target the
  /// same turn. Two triggers of one simultaneous batch are not two events —
  /// they coalesce upstream and arm once. See [armSpellDamageBonus].
  int spellDamageBonusAmount = 0;

  /// The turn [spellDamageBonusAmount] applies on. -1 = never.
  int spellDamageBonusTurn = -1;

  /// The bonus damage in force on [turnNumber]; 0 when Burning Hot is not
  /// active. The single read path — don't compare the turn fields elsewhere.
  int spellDamageBonusFor(int turnNumber) =>
      turnNumber == spellDamageBonusTurn ? spellDamageBonusAmount : 0;

  /// Arms Burning Hot for [turn] with [amount] bonus damage, stacking onto an
  /// existing arming for the same turn and replacing a stale one.
  ///
  /// ── Why this still SUMS after slice 7 ─────────────────────────────────────
  /// Slice 7's R5 ruling — "multiple Burning Hot triggers within one
  /// simultaneous batch produce one event at the strongest bracket, they do not
  /// add together" — is enforced ONE LAYER UP, by
  /// `coalesceWildMagicTriggers`. A batch collapses its Burning Hot triggers
  /// into a single world event at `max(contributing brackets)` and calls this
  /// method exactly ONCE, so within a batch there is nothing left to sum.
  ///
  /// **This primitive must not decide which events were simultaneous**, and
  /// that is the whole reason it was left additive. Quick, Normal and Sluggish
  /// are separate simultaneous-resolution boundaries (slice 7 R1), so a Quick
  /// Burning Hot and a Normal one on the same turn are two genuinely separate
  /// world events that happen to arm the same future round — and two separate
  /// events stack, exactly as they did before slice 7. A `max` here would have
  /// silently merged them, which is a rule about batching expressed in a class
  /// that cannot see a batch.
  ///
  /// A stale arming (a DIFFERENT [turn]) is replaced, not combined: Burning Hot
  /// from a previous round has expired. Slice 7 did not revisit that.
  void armSpellDamageBonus(int turn, int amount) {
    if (spellDamageBonusTurn == turn) {
      spellDamageBonusAmount += amount;
    } else {
      spellDamageBonusTurn = turn;
      spellDamageBonusAmount = amount;
    }
  }

  // ── Phoenix (row 3, Fire) ─────────────────────────────────────────────────

  /// playerId → the rounds during which that wizard will respawn at 1 HP
  /// instead of dying.
  ///
  /// At most ONE save per wizard: the map holds a window, not a count, so a
  /// second Phoenix extends the window a wizard already has rather than
  /// granting them a second life. The entry is removed the moment the save is
  /// spent ([consumePhoenixSave]) and swept when the window runs out.
  final Map<String, WildMagicWindow> phoenixWindows = {};

  /// Grants [playerId] a Phoenix save for the two rounds after [triggerTurn],
  /// extending — never shortening — one they already hold.
  void armPhoenix(String playerId, {required int triggerTurn}) => _arm(
        phoenixWindows,
        playerId,
        WildMagicWindow.armedOn(triggerTurn, rounds: kPhoenixRounds),
      );

  /// Whether [playerId] has a save available on round [turn].
  bool phoenixAvailableFor(String playerId, int turn) =>
      phoenixWindows[playerId]?.isActiveOn(turn) ?? false;

  /// Spends [playerId]'s save if one is available on [turn], returning whether
  /// it was. Clears the entry immediately — a spent Phoenix is gone even if
  /// rounds remained on its window.
  bool consumePhoenixSave(String playerId, int turn) {
    if (!phoenixAvailableFor(playerId, turn)) return false;
    phoenixWindows.remove(playerId);
    return true;
  }

  // ── Statuesque (row 3, Earth) ─────────────────────────────────────────────

  /// playerId → the rounds during which that wizard is refilled to full HP and
  /// mana at the START of the round.
  ///
  /// Broken — removed outright — the moment its holder takes any voluntary
  /// action other than Pass ([breakStatuesque]; the classification lives in
  /// `statuesque_break.dart`). There is no pending set: a window armed during
  /// R does not contain R, so the cast that fired it cannot break it.
  final Map<String, WildMagicWindow> statuesqueWindows = {};

  void armStatuesque(String playerId, {required int triggerTurn}) => _arm(
        statuesqueWindows,
        playerId,
        WildMagicWindow.armedOn(triggerTurn, rounds: kStatuesqueRounds),
      );

  bool statuesqueActiveFor(String playerId, int turn) =>
      statuesqueWindows[playerId]?.isActiveOn(turn) ?? false;

  /// Ends [playerId]'s Statuesque outright, active or merely scheduled.
  ///
  /// Both are dropped: a wizard who acts during the round that armed it has
  /// broken the stillness the effect describes before it ever took hold, and
  /// leaving the scheduled window to mature would have them freeze next round
  /// for an action they took this one.
  void breakStatuesque(String playerId) => statuesqueWindows.remove(playerId);

  // ── Rippling Reflections (row 3, Water) ───────────────────────────────────

  /// The rounds during which every spell either fizzles or resolves twice.
  /// Null = not present. One shared window for the whole match, per the
  /// design's "every spell".
  WildMagicWindow? ripplingWindow;

  /// The current fizzle probability in percent, clamped [0, 100], drifting ±10
  /// per outcome. Null exactly when [ripplingWindow] is null — the two are one
  /// piece of state in two fields, and [_assertRipplingConsistent] holds them
  /// together.
  ///
  /// There is no third outcome: while active, every spell either fizzles or
  /// resolves twice.
  int? ripplingFizzlePct;

  /// Arms Rippling Reflections for the round after [triggerTurn].
  ///
  /// The percentage is only seeded when the effect is not already present:
  /// a second firing must NOT reset a drifted counter, or a player who keeps
  /// casting the spell that carries it would re-arm it at 50 forever. The
  /// window still merges, so a retrigger extends the lifetime.
  void armRippling({required int triggerTurn}) {
    final armed =
        WildMagicWindow.armedOn(triggerTurn, rounds: kRipplingRounds);
    final existing = ripplingWindow;
    ripplingWindow = existing == null ? armed : existing.mergedWith(armed);
    ripplingFizzlePct ??= 50;
    _assertRipplingConsistent();
  }

  /// The fizzle percentage in force on [turn], or null when Rippling
  /// Reflections is not active that round. The single read path — do not test
  /// [ripplingFizzlePct] for null on its own, which cannot tell "active" from
  /// "scheduled for next round".
  int? ripplingFizzlePctOn(int turn) =>
      (ripplingWindow?.isActiveOn(turn) ?? false) ? ripplingFizzlePct : null;

  /// Records a drift outcome. A no-op unless the effect is active on [turn],
  /// so a spell resolving on a round Rippling does not cover cannot nudge the
  /// counter it is not subject to.
  void driftRippling(int turn, int delta) {
    if (!(ripplingWindow?.isActiveOn(turn) ?? false)) return;
    ripplingFizzlePct = (ripplingFizzlePct! + delta).clamp(0, 100);
  }

  void _assertRipplingConsistent() {
    assert(
      (ripplingWindow == null) == (ripplingFizzlePct == null),
      'ripplingWindow and ripplingFizzlePct are one piece of state: both set '
      'or both null (window=$ripplingWindow, pct=$ripplingFizzlePct)',
    );
  }

  // ── Scattered Gusts (row 3, Air) ──────────────────────────────────────────

  /// playerId → the first round on which that wizard's next voluntary spell
  /// cast blows their bookmarks loose and re-deals their hand.
  ///
  /// Per wizard, not global: each affected wizard carries their own pending
  /// Gust until they themselves cast, and one wizard spending theirs leaves
  /// everyone else's standing. There is no time-based expiry — a Gust waits
  /// as many rounds as it takes.
  ///
  /// Consumed by exactly one redeal ([consumeScatteredGust]) and only by a
  /// VOLUNTARY cast: a forced free cast (Spontaneous Combustion, A8) and every
  /// non-spell action leave it pending.
  final Map<String, int> scatteredGustsArmedFrom = {};

  /// Arms a Gust for [playerId] from the round after [triggerTurn].
  ///
  /// Re-arming keeps the EARLIER arming turn, matching every other merge here
  /// in never moving a boundary against the state that already existed.
  void armScatteredGusts(String playerId, {required int triggerTurn}) {
    final armedFrom = triggerTurn + 1;
    final existing = scatteredGustsArmedFrom[playerId];
    scatteredGustsArmedFrom[playerId] =
        existing == null ? armedFrom : min(existing, armedFrom);
  }

  /// Whether [playerId] has a Gust that a voluntary cast on [turn] would
  /// consume.
  bool scatteredGustPendingFor(String playerId, int turn) {
    final from = scatteredGustsArmedFrom[playerId];
    return from != null && turn >= from;
  }

  /// Spends [playerId]'s Gust if one is pending on [turn], returning whether
  /// it was. Clears that wizard's entry only.
  bool consumeScatteredGust(String playerId, int turn) {
    if (!scatteredGustPendingFor(playerId, turn)) return false;
    scatteredGustsArmedFrom.remove(playerId);
    return true;
  }

  // ── The round boundary ────────────────────────────────────────────────────

  /// Drops every window that has run out by round [turn], and every entry
  /// belonging to a player [isAlive] reports as gone.
  ///
  /// THE single expiry point — called once per round from
  /// `DeterministicResolution.resolveWildMagicRoundStart`, before any
  /// voluntary action of that round. Expiry is a round-boundary event rather
  /// than a lazy check at each query so that two devices drop the same entries
  /// at the same instant and the canonical bytes never carry a spent window.
  ///
  /// Phoenix entries for the DEAD are kept: a dead wizard is exactly who a
  /// Phoenix has yet to save. Statuesque entries for the dead are dropped —
  /// they can no longer break the latch by acting, and an immortal entry in
  /// the state hash is pure noise. Gusts likewise: a dead wizard casts nothing.
  void sweepExpired(int turn, {required bool Function(String playerId) isAlive}) {
    phoenixWindows.removeWhere((_, w) => w.hasExpiredBy(turn));
    statuesqueWindows
        .removeWhere((id, w) => w.hasExpiredBy(turn) || !isAlive(id));
    scatteredGustsArmedFrom.removeWhere((id, _) => !isAlive(id));
    if (ripplingWindow?.hasExpiredBy(turn) ?? false) {
      // Both halves, together: a spent effect leaves no drifted counter behind
      // for the next arming to inherit. A fresh Rippling starts at 50.
      ripplingWindow = null;
      ripplingFizzlePct = null;
    }
    _assertRipplingConsistent();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static void _arm(
    Map<String, WildMagicWindow> windows,
    String playerId,
    WildMagicWindow armed,
  ) {
    final existing = windows[playerId];
    windows[playerId] = existing == null ? armed : existing.mergedWith(armed);
  }
}
