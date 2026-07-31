// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_state.dart — WildMagicState: the persistent, match-scoped globals
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

class WildMagicState {
  WildMagicState();

  // ── Burning Hot (row 1, Fire) ─────────────────────────────────────────────

  /// +N damage added to every spell damage effect, on one specific turn.
  /// Active iff `state.turnNumber == spellDamageBonusTurn`.
  ///
  /// Stacks by SUMMING amount when two Burning Hots target the same turn, and
  /// applies to EVERY player's spells (symmetry) once per damage effect — so a
  /// three-formula spell gets it three times.
  int spellDamageBonusAmount = 0;

  /// The turn [spellDamageBonusAmount] applies on. -1 = never.
  int spellDamageBonusTurn = -1;

  /// The bonus damage in force on [turnNumber]; 0 when Burning Hot is not
  /// active. The single read path — don't compare the turn fields elsewhere.
  int spellDamageBonusFor(int turnNumber) =>
      turnNumber == spellDamageBonusTurn ? spellDamageBonusAmount : 0;

  /// Arms Burning Hot for [turn] with [amount] bonus damage, stacking onto an
  /// existing arming for the same turn and replacing a stale one.
  void armSpellDamageBonus(int turn, int amount) {
    if (spellDamageBonusTurn == turn) {
      spellDamageBonusAmount += amount;
    } else {
      spellDamageBonusTurn = turn;
      spellDamageBonusAmount = amount;
    }
  }

  // ── Phoenix (row 3, Fire) ─────────────────────────────────────────────────

  /// playerIds that will respawn at 1 HP instead of dying. One-shot: the id is
  /// consumed on the death it saves.
  final Set<String> phoenixPlayerIds = {};

  // ── Statuesque (row 3, Earth) ─────────────────────────────────────────────

  /// playerIds refilled to full HP + mana at each turn end, removed from the
  /// set the moment they voluntarily move or cast a spell (A6: the latch begins
  /// at the END of the turn it fires, so the triggering cast does not
  /// immediately break it).
  final Set<String> statuesquePlayerIds = {};

  /// Set while the triggering turn is still resolving, so the cast that fired
  /// Statuesque cannot break its own effect. Promoted into
  /// [statuesquePlayerIds] at end of turn.
  final Set<String> pendingStatuesquePlayerIds = {};

  // ── Rippling Reflections (row 3, Water) ───────────────────────────────────

  /// null = inactive. Otherwise the current fizzle probability in percent,
  /// clamped [0, 100], drifting ±10 per outcome. There is no third outcome:
  /// once active, every spell either fizzles or resolves twice.
  ///
  /// One shared counter for the whole match, per the design's "every spell".
  int? ripplingFizzlePct;

  // ── Scattered Gusts (row 3, Air) ──────────────────────────────────────────

  /// Once true, stays true for the rest of the match.
  bool scatteredGusts = false;
}
