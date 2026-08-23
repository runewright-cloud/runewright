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
// v2 (2026-08-19, M4.20) — a forced cast (wild magic's Spontaneous Combustion)
// resolves the PROOF-attested trajectory, not the revealer's authored
// `SpellAsset.formula`. `ForcedCastHost.verifyForcedReveal` now returns the
// `CertifiedCast` it was already computing, `ForcedCastPick` carries it, and
// `TurnLoop.resolveForcedCast` passes it to `applySpell` — the same certified
// arguments an ordinary cast has had since B-1.
//
// This is exactly the case this gate exists for, and it is worth being precise
// about why, because "honest inputs are unchanged" is NOT the test. The
// forced-reveal payload (0x43) is byte-identical before and after; every proof
// verifies the same way; no VK moves. What changes is what a v1 and a v2 build
// COMPUTE from that identical transcript whenever the authored formula and the
// certified trajectory disagree: v1 resolves the authored one, v2 the certified
// one, and the two canonical `BattleState`s diverge. That divergence is
// reachable two ways — a modified client lying about its own formula (the M4.20
// attack), and, without any adversary at all, a spell whose stored `formula`
// field simply does not match its proof, which a v1 build resolves from the
// field and a v2 build from the proof. Either way a mixed pair would desync
// mid-match on a state hash instead of being refused at the handshake, which is
// the failure mode v1 was introduced to abolish.
//
// v3 (2026-08-21, M4.10b) — spell mana settlement moved from asymmetric
// local-Phase-1 / peer-Phase-5 timing to **canonical Phase-5 settlement**.
//
// Under v1/v2 each device charged its OWN player's committed cast at Phase 1,
// the instant the action commit crossed the wire, and the PEER's at Phase 5,
// once the reveal was verified. Neither site could move on its own, so for any
// single cast one device deducted four phases earlier than the other, and
// everything Phases 2–4b did to that caster — a SlowTile draining their mana, a
// Water haymaker stripping the `nextSpellCostDouble` that priced the cast, a
// counter-charm proc destroying a mana gem and clamping their pool, a punch
// that a caster already dead from shortfall HP could not receive — landed on
// opposite sides of the deduction on the two devices.
//
// v3 charges nothing at Phase 1. Both players' committed casts are priced and
// paid for at the start of Phase 5, from the live replicated state, in
// ascending playerId order, before `_applyMoveMeditations` and before any other
// Phase-5 resource mutation (`TurnLoop._settleCommittedCasts`).
//
// **This is the case the gate exists for, and the argument is worth being
// precise about, because "we fixed a desync" is not by itself a reason to
// bump.** The test is whether two builds could compute a different canonical
// `BattleState` from an identical transcript, and here they demonstrably can:
// the same messages, the same proofs, the same VK, and a v2 build resolves a
// SlowTile-drained marginal cast while a v3 build fizzles it. What makes this
// unusual is that the v2 canonical state for such a transcript was never
// well-defined in the first place — v2's two peers already disagreed, which was
// the bug. v3 does not so much change the rule as supply one. The gate still
// has to fire: without it a v2/v3 pair would desync mid-match on a state hash
// instead of being refused at the handshake, which is the failure mode v1 was
// introduced to abolish.
//
// No proof semantics participate and no framing changes, so `kRulesetVersion`
// stays 3 and `kBattleProtocolVersion` stays 5. See docs/M4_findings.md M4.10b.
//
// v4 (2026-08-23, M4.21) — a cast that canonical Phase-5 settlement marked
// `fizzledForMana` can no longer be resurrected by Mystery. Two paths did it:
//
//   * `TurnLoop._verifyMysteryAction` rebuilt an immediate (delay 0) Mystery
//     cast as a fresh `SpellCastAction` and dropped the flag, so the cast
//     resolved at full effect while keeping the mana settlement had refunded.
//     The flag is now carried through the rebuild.
//   * `DeterministicResolution.resolveActions`' non-immediate Mystery branch
//     never read the flag, so an unaffordable declaration still queued a
//     `PendingDelayedSpell` — and a delayed fire is never re-priced, so it
//     landed free a turn later. A fizzled declaration now queues nothing and
//     regresses the chain, exactly as any other mana fizzle does.
//
// Mystery gets no special affordability exception; nothing in the design docs
// ever said it did (VOCAL_RECALL_PLAN.md §4/§9.5,
// `runewright_design_v4_0.md` §791). This was a dropped field and an unread
// one, not a rule.
//
// The gate has to fire, on the usual test: **the same wire transcript** — same
// `0x03` action bytes, same proofs, same VK — yields different canonical
// `BattleState` on either side of the change. A v3 build applies the spell's
// damage, advances the caster's chain and (for the delayed variant) writes a
// `PendingDelayedSpell` into the state; a v4 build suppresses all three. HP,
// `chainLengths` and `pendingDelayedSpells` are all hashed by
// `BattleState.toCanonicalBytes`, so a mixed pair desyncs on the state hash
// mid-match instead of being refused at the handshake — the failure mode v1
// exists to abolish.
//
// Unlike v3, the v3 behaviour here WAS well-defined: both peers agreed, and
// agreed on the wrong answer. That makes this a rules correction rather than a
// rules supply, and it is the reason it needs an epoch rather than a patch
// note — an unpatched client is not merely stale, it can cast for free.
//
// No proof semantics participate (the enhancement-backing check that certifies
// a Mystery claim is untouched) and no framing changes, so `kRulesetVersion`
// stays 3 and `kBattleProtocolVersion` stays 5. See docs/M4_findings.md M4.21.
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
const int kBattleEngineVersion = 4;

/// What a peer that predates the engine-version gate implicitly declares: it
/// omits the field, and an omitted field cannot be read as agreement.
///
/// Never a legal value for a build to *claim* — [kBattleEngineVersion] starts
/// at 1 precisely so "didn't say" and "said v1" can never collide.
const int kUndeclaredBattleEngineVersion = 0;
