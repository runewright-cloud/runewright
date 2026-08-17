// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_engine_version.dart — kBattleEngineVersion: the deterministic
// battle-engine consensus epoch.
//
// ## Why this is not `kRulesetVersion`, and not `kBattleProtocolVersion`
//
// Three independent things can make two builds unable to duel, and folding
// them into one number makes every one of them lie:
//
//   `kRulesetVersion` (spells/inscribe.dart) — **proof/circuit semantics.**
//   What the CA does, what a proof certifies, which verification key accepts
//   it. It is a circuit global, baked into each tier's VK, and bumping it
//   invalidates every spell ever inscribed: they must be re-proven. Enforced
//   per cast, against the `ruleset_version` a peer's proof attests
//   (TurnLoop's `ruleset_version_mismatch` forfeit).
//
//   `kBattleProtocolVersion` (battle/networking/match_discovery.dart) —
//   **wire framing.** Which `BattleMsgType`s exist and what their payload
//   bytes mean. Bumped when a message shape changes such that an older client
//   would misread or block on the bytes.
//
//   `kBattleEngineVersion` (here) — **deterministic engine consensus.** The
//   rules both devices independently run to compute the same canonical
//   `BattleState` from the same match inputs: phase order, the order
//   simultaneous actions serialize in, how seeded RNG is bound to actors, what
//   each effect does. Nothing about it is certified by a proof and nothing
//   about it changes a byte on the wire — which is exactly why neither of the
//   other two gates can see it.
//
// The gap this closes is real and was live. Commit e0010e1 (M4.18) changed
// simultaneous free-move runs from device-relative order (local wizard first)
// to ascending canonical owner pubkey. Same messages, same proofs, same VK —
// so both existing gates pass — but a patched and an unpatched client walk the
// two runs in different orders and compute different states. The old symptom
// was a state-hash mismatch on the turn it happened, reported as a broken
// duel, with no way to tell "your opponent is on an old build" from "someone
// is cheating". This turns that into a refusal at the handshake.
//
// ## Bump this whenever a consensus-visible engine rule changes
//
// The test is not "did a rule change" but "could two builds now compute a
// different canonical `BattleState` from identical inputs". Ordering of
// simultaneous actions, RNG seeding/assignment, effect resolution, phase
// sequencing, and anything hashed by `BattleState.toCanonicalBytes` all
// qualify. Presentation, UI, animation, and event playback do not.
//
// Bumping is cheap by design — no VK is invalidated, no spell needs
// re-proving, nothing on disk is rewritten. It costs exactly one thing: two
// builds on either side of the bump refuse to duel each other, which is the
// entire point. Be liberal with it, the way `RULESET_VERSION` discipline is
// meant to be but cannot afford to be.
//
// ## Version history
//
// v1 (2026-08-17) — the first declared engine epoch, i.e. the engine as of
// e0010e1: simultaneous free-move runs serialize by ascending canonical owner
// pubkey (`compareCanonicalPubkeyHex`), not local-first.
//
// There is deliberately no v0 build. Nothing has shipped, so pretending an
// earlier epoch was ever negotiated would be fiction; 0 is reserved as the
// sentinel for a peer that predates this field entirely and therefore declares
// nothing (see [DeviceCapabilities.battleEngineVersion] and
// `MatchConfig.fromJson`). A peer that declares 0 is refused for the honest
// reason: it cannot tell us what rules it runs.

/// The deterministic battle-engine consensus epoch this build implements.
///
/// The single canonical definition — [MatchConfig.battleEngineVersion] and
/// [DeviceCapabilities.battleEngineVersion] both default to it rather than
/// restating a literal, exactly as `MatchConfig.rulesetVersion` derives from
/// `kRulesetVersion`. See this file's header for what forces a bump.
const int kBattleEngineVersion = 1;

/// What a peer that predates the engine-version gate implicitly declares: it
/// omits the field, and an omitted field cannot be read as agreement.
///
/// Never a legal value for a build to *claim* — [kBattleEngineVersion] starts
/// at 1 precisely so "didn't say" and "said v1" can never collide.
const int kUndeclaredBattleEngineVersion = 0;
