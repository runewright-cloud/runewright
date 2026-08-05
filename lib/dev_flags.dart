// SPDX-License-Identifier: GPL-3.0-or-later
//
// dev_flags.dart — TEMPORARY playtest switches. DELETE THIS FILE once the
// surfaces it gates are gone for good, and delete the code paths that read it
// (grep for the constant names; every read site carries a `DEV FLAG` comment).
//
// Nothing here is a feature. Each constant either deliberately weakens a check
// that exists for a reason, or reveals a developer-only screen, to make a
// specific kind of manual testing possible. They are compile-time consts so
// that flipping one is a rebuild, never a runtime toggle a shipped binary
// could reach.
//
// **Every flag here must be `false` in a build that goes to players.** The
// code behind them stays in the tree — flipping one back on is a one-line
// edit plus a rebuild.

/// Accept a peer's spell cast that carries **no ZK proof at all**.
///
/// Why it exists: the Spell Test Lab fabricates one spell per (affinity ×
/// effect kind) so every effect can be exercised by hand. Those spells never
/// run through the circuit, so `SpellAsset.proofBytes` is empty and
/// TurnLoop._appendSpellProofTail sends no proof tail. In a real duel the
/// opponent's device rejects that and forfeits the match — correct behaviour,
/// but it makes two-device effect testing impossible, and several effects
/// (reflections, counter-charms, scrying, anything needing a real opponent)
/// can't be exercised in solo practice at all.
///
/// What it does NOT do: a spell that *has* proof bytes is still fully
/// verified — proof, commitment binding, duplicate-grid detection,
/// enhancement claims, cast authorization, Merkle membership. Only the
/// empty-proof case is waved through, and only for effect resolution and the
/// mana ledger. See TurnLoop._verifyPeerSpellCast.
///
/// **Both devices must build with the same value.** If one has it on and the
/// other off, the strict device forfeits the moment a test spell is cast —
/// which looks exactly like the freeze it was meant to avoid.
///
/// While this is true, [BattleScreen] shows a permanent "UNVERIFIED PLAY"
/// banner. Do not remove that banner while the flag exists: a duel running
/// without proof checks must never be mistakable for a real one.
const bool kAllowProoflessSpells = false;

/// Show the developer-only surfaces in the menus.
///
/// Three entry points, all hidden together because they exist for the same
/// reason — exercising something by hand that normal play can't reach:
///
///   * **Spell Test Lab** (Battle lobby) — fabricates one proofless spell per
///     (affinity × effect kind) so every effect can be triggered without
///     inscribing and proving a real grid. See [kAllowProoflessSpells]; the
///     lab is close to useless with that flag off, which is why the two ship
///     off together.
///   * **Library › TESTS tab** — lists the spells the lab fabricated. Hiding
///     the tab does not delete them; they stay on disk under the
///     `[TEST] ` name prefix and reappear when this flag goes back on.
///   * **Main menu › "DEBUG: View Onboarding"** — replays the first-launch
///     onboarding flow, which is otherwise reachable only on a fresh install.
///
/// Hiding these is purely a UI gate. The screens, their state, and their
/// tests are all still in the tree and still compile.
const bool kShowDevSurfaces = false;
