// SPDX-License-Identifier: GPL-3.0-or-later
//
// dev_flags.dart — TEMPORARY playtest switches. DELETE THIS FILE before any
// release, and delete the code paths that read it (grep for the constant
// names; every read site carries a `DEV FLAG` comment).
//
// Nothing here is a feature. Each constant deliberately weakens a check that
// exists for a reason, to make a specific kind of manual testing possible.
// They are compile-time consts so that flipping one is a rebuild, never a
// runtime toggle a shipped binary could reach.

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
const bool kAllowProoflessSpells = true;
