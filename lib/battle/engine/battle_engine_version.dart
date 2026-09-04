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
// v5 (2026-08-24, M4.22) — a caster's own proof-backed immediate cast resolves
// and is priced from the semantics reconstructed from **its own proof bytes**,
// not from the authored `SpellAsset.formula`/`manaCost` stored beside them.
//
// Under v1–v4 an immediate cast had two semantic authorities. The caster's own
// cast is never in `certifiedPeerCasts` (only `_verifyPeerSpellCast` writes
// that map), so `DeterministicResolution.resolveActions` found no
// `CertifiedCast` for it and every consumer fell through to the authored wire
// fields: `elementSequence(spell)` for resolution and counter-charm matching,
// `wireBaseManaCost(spell)` for the price. The VERIFIER resolved the same cast
// from `PeerCastVerifier.semanticsOf` over verified public outputs. Between
// honest clients those are supposed to be the same list — an assumption that
// was load-bearing and unenforced.
//
// `assets/basic_spells/basic_windhound.json` broke it. `inscribeSpell` takes
// `formula`, `supremeTags` and `manaCost` as caller-supplied arguments and
// never checks them against the proof it just generated, so a stale UI
// `FormulaTracker` shipped: 12 authored elements over a proof attesting three
// (fire, water, water). The caster charged itself 83 and the verifier charged
// it 25, `WizardAvatar.mana` diverged at byte 56 of `toCanonicalBytes`, and a
// Pixel 6 ↔ Linux pair forfeited "state hash mismatch on turn 3" every time
// that spell was cast.
//
// v5 branches on ownership, the way the Mystery declaration path already did:
// our own cast parses its own proof (`certifiedFromProofBytes` — semantic
// reconstruction, NOT verification: this device authored the bytes), a peer's
// keeps reading what real `PeerCastVerifier` verification derived. Same proof
// bytes now mean the same element sequence and the same base cost on both
// devices, whatever the authored fields say.
//
// The gate has to fire, on the usual test. **The same wire transcript** — same
// `0x01` action bytes, same proofs, same VK — yields a different canonical
// `BattleState` on either side of the change for any spell whose authored
// fields have drifted from its proof: a v4 build resolves the authored
// trajectory locally, a v5 build the certified one, and mana, chain state, the
// summoned creature's whole stat block and everything downstream diverge. Note
// the v4 canonical state for such a transcript was never well-defined — v4's
// two peers already disagreed, which was the bug — so like v3 this supplies a
// rule rather than changing one. The gate still has to fire, or a mixed pair
// desyncs mid-match instead of being refused at the handshake.
//
// The shipped Windhound was ALSO regenerated from its own proof in the same
// change. That half is pure content and needs no epoch: it changes generated
// input data, not how an identical transcript is interpreted. The epoch is for
// the engine half, which does.
//
// Deliberately NOT included: `isSummon` and `summonPersonality` remain authored
// and unbound (M4.19). They are wire fields both devices read identically, so
// they were never a contributor here, and deriving them is a separate defect
// with a separate fix. No proof semantics participate and no framing changes,
// so `kRulesetVersion` stays 3 and `kBattleProtocolVersion` stays 5. See
// docs/M4_findings.md M4.22.
//
// v6 (2026-08-26, Aetherial Armor slice 5) — a certified Aetherial Armor is
// canonical battle state, and its four numerical bonuses are deterministic
// gameplay.
//
// Slices 1–4.6 built the armor derivation, its persistence, the `armorLoadout`
// (0x1F) setup frame and two-sided certification, then deliberately stopped: as
// of v5 both devices agreed on an armor's complete semantics and applied none
// of them. This closes that gap. `DuelSetupResult.localArmor`/`peerArmor` — the
// already-certified `CertifiedArmor`s, re-derived from nothing — are seated on
// the two `WizardAvatar`s by `buildDuelBattleState`'s existing pubkey ordering,
// and four bonuses go live:
//
//   * Fire  -> `+meleeBonus` on the one wizard melee path
//              (`DeterministicResolution.applyHaymaker`), composing with the
//              Air haymaker's distance bonus.
//   * Air   -> `+moveSpeedBonus` inside `WizardAvatar.effectiveMoveSpeed`.
//   * Water -> `+spellRangeBonus` inside `WizardAvatar.effectiveSpellRange`.
//   * Earth -> `+armorHpBonus` folded into starting HP, and into the one other
//              path that assigns a full pool (the Statuesque wild-magic heal).
//
// Air and Water go into the two *effective-stat* getters, which are the single
// authoritative definitions of those stats, so every consumer inherits them —
// including Dash (`effectiveMoveSpeed * 2`, so base 2 + Air 1 dashes 6),
// Watery Inertia's `1..range` scatter, and the wild-magic random-target radius.
// That breadth is the ruling, not an oversight: there is no "base excluding
// armor" reading anywhere.
//
// Armor keywords are canonical and hashed but **inert** — no keyword touches
// gameplay in v6, and `WizardAvatar.isFlying` still derives solely from the
// Flying status effect, so a certified Flying armor leaves it false.
//
// The gate has to fire, on the usual test. Canonical `BattleState` bytes gain a
// per-avatar armor record (presence, T, slot cost, the four element counts, the
// four bonuses, a keyword bitmask, the certified element sequence), so the same
// wire transcript hashes differently under v5 and v6 the moment either side
// wears anything — and even with no armor worn, the added presence byte moves
// every hash. Beyond the bytes, v5 and v6 resolve an armored match differently
// in HP, damage, reach and movement. A mixed pair must be refused at the
// handshake rather than desync on turn 1.
//
// No proof semantics change and no framing changes — armor is certified at
// setup and never re-read — so `kRulesetVersion` stays 3 and
// `kBattleProtocolVersion` stays 7. See docs/AETHERIAL_ARMOR.md §9.
//
// v7 (2026-08-27, Aetherial Armor slice 6) — two certified armor keywords stop
// being inert: **Charger** (`FAFA`) and **Muddy** (`WEWE`).
//
// Neither grows a mechanic. Each ORs itself into an EXISTING capability getter
// on `WizardAvatar`, and the existing haymaker code downstream is unchanged:
//
//   * Charger -> `hasHaymakerDistanceBonus`, so the wearer's punch gains the
//     Air haymaker's `tilesWalked ~/ 2` — measured, rounded, dashed and
//     ordered against the Fire melee bonus exactly as that mechanic already
//     defines. It composes additively with `meleeBonus`: 1 + Fire + distance.
//   * Muddy   -> `hasHaymakerSlow`, so the wearer's punch applies the Earth
//     haymaker's existing `speedDown -1` for 2 turns, with its existing target
//     eligibility, magnitude, duration, status representation and stacking.
//
// A wearer who also holds the corresponding status effect is not doubled: both
// sources feed one boolean, and `applyHaymaker` reads that boolean once.
//
// The other five keywords (`flying`, `cleave`, `moltenCarapace`, `stealthy`,
// `anchored`) stay inert, and Morphic stays unbuilt. `WizardAvatar.isFlying`
// still derives solely from the Flying status effect.
//
// The gate has to fire because this is a deterministic behaviour change with
// NO serialization change to announce it: canonical `BattleState` bytes are
// byte-identical to v6 for the same state — the keyword bitmask that carries
// Charger and Muddy shipped in v6 — so a v6 device and a v7 device would agree
// on the opening hash and then diverge the first time an armored wizard threw
// a punch. That is precisely the shape the epoch exists to refuse: same bytes,
// different meaning.
//
// No proof semantics change and no framing changes — the keywords were already
// certified, hashed and agreed in v6 — so `kRulesetVersion` stays 3 and
// `kBattleProtocolVersion` stays 7. See docs/AETHERIAL_ARMOR.md §11.
//
// v8 (2026-09-02, Wild Magic vNext slice 2A) — Wild Magic is rekeyed from the
// spell's GRID to the spell's certified BEHAVIOUR, and from the community seed
// STRING to the canonical leyline configuration hash.
//
// v1's seed hash was `commitment || uint8(T) || utf8(normalizedSeed)`. v2's is
// a fully length-delimited preimage over four semantic inputs and nothing else:
//
//   uint8(len) || utf8("Runewright/WildMagic") || uint16be(2)
//     || casterPubkey[32] || uint16be(n) || trajectoryBytes[n]
//     || uint64be(certifiedBaseManaCost) || leylineConfigHash[32]
//
// Three consequences, each of them a deliberate rule change
// (docs/WILD_MAGIC_PLAN_VNEXT.md §1-§6):
//
//   * **Wild Magic is now caster-keyed.** The same spell in two hands has two
//     different Wild Magics, and a loaned spell fires the BORROWER's. The
//     caster is the authenticated `WizardAvatar.ownerPubkeyHex`, resolved in
//     exactly one place (`TurnLoop._casterOwnerPubkeyHex`).
//   * **The grid commitment and T leave the derivation.** §3 refuses to publish
//     a grid fingerprint that could seed an offline dictionary attack on a
//     private rune, and §5 makes two inscriptions Wild-Magic-EQUIVALENT when
//     their certified trajectory and rounded certified base cost agree. T still
//     reaches the hash through `certifiedBaseManaCost`'s 1.05^T, which is the
//     only channel §5 permits.
//   * **The leyline enters as a struct hash**, not a seed word, so a numbered
//     leyline and its ordinary namesake are different magical traditions.
//
// Trigger scanning (rows 1-3, maximal runs, longest-occurrence brackets) and
// affinity eligibility (tally completed formulas, every tied affinity stays
// eligible) are UNCHANGED — §9's independent-per-affinity roll is still an open
// playtest question, and the hash is deliberately structured so answering it
// later changes the trigger producer without touching the preimage.
//
// The gate has to fire, and on the strongest possible version of the usual
// test: a v7 device and a v8 device compute different Wild Magic for the same
// spell from the same proof, so they diverge the first turn any spell carries a
// trigger — and, because triggers are ~3% of spells, they would often agree for
// several turns first and then desync mid-match with no visible cause.
//
// No proof semantics change and no framing changes — the preimage is built
// entirely from values both devices already derive from the proof they already
// exchange, and nothing new crosses the wire — so `kRulesetVersion` stays 3 and
// `kBattleProtocolVersion` stays 7. See docs/WILD_MAGIC_PLAN_VNEXT.md §16.
//
// There is deliberately no v0 build. Nothing has shipped, so pretending an
// earlier epoch was ever negotiated would be fiction; 0 is reserved as the
// sentinel for a peer that predates this field entirely and therefore declares
// nothing (see [DeviceCapabilities.battleEngineVersion] and
// `MatchConfig.fromJson`). A peer that declares 0 is refused for the honest
// reason: it cannot tell us what rules it runs.

// v11 (2026-09-03, Wild Magic vNext slice 6) — Chasm now has occupied-tile
// behaviour. The chasm opens regardless of who is standing on it (unchanged),
// but every living body the new cells invalidate is now involuntarily
// displaced to the nearest legal solid position, ties broken from the
// trigger's own RNG stream. Before v11 the ground simply vanished and left
// people standing in it.
//
// This is a pure resolution-semantics change: a v10 device leaves a wizard in
// the hole while a v11 device moves them, so the two boards — and therefore
// the per-turn canonical state hash — diverge the first time any chasm opens
// under a body. It also consumes additional draws from the trigger's RNG
// stream, so a *later* effect in the same firing would draw differently even
// where the displacement itself is invisible. Nothing crosses the wire that
// did not before and the circuit is untouched, so `kBattleProtocolVersion`
// stays 7 and `kRulesetVersion` stays 3.
//
// v12 (2026-09-03, Wild Magic vNext slice 7) — Wild Magic becomes a PHASE of a
// simultaneous resolution batch instead of a per-cast interleave, and multiple
// triggers of one effect kind in one batch COALESCE into a single world event.
//
// Three rule changes, all consensus-visible:
//
//   * **Phase ordering (R3).** Within one resolution batch (Quick / Normal /
//     Sluggish are separate batches, R1) the order is now
//     `all admission → all coalesced wild magic → all formula effects`, not
//     "each cast's wild magic, then that cast's effects, then the next cast".
//     So caster B's Zephyr now moves people before caster A's fireball lands.
//     This supersedes design v4.0 §1250's per-spell reading, which cannot
//     survive N-player play.
//   * **Liveness at admission (R2).** A caster killed by an earlier cast in the
//     SAME batch used to be skipped entirely. Their cast is now admitted before
//     any effect resolves, so both its wild magic and its ordinary spell
//     resolve. (A caster killed by an earlier BATCH still never acts.)
//   * **Coalescing.** One effect kind fires at most ONCE per batch, at
//     `max(contributing brackets)`. Two Zephyrs are one gale, two Chasms are
//     one axis, two Mountains select ≤3 walls per wizard between them, two
//     Spontaneous Combustions queue one forced cast per living wizard, and two
//     Burning Hots in one batch take the hotter rather than their sum (R4/R5).
//     The Mountains and Spontaneous Combustion cases were bounds the applicator
//     stated per LIVING WIZARD and enforced only per firing — pre-existing bugs
//     at phase scope, fixed as a consequence of the boundary rather than by a
//     special case.
//
// Coalescing is strictly BATCH-scoped, and `WildMagicState` is unchanged: two
// Burning Hots in separate batches of one turn are two world events and still
// stack additively on the round they both arm, exactly as before. The
// persistent-state primitives must not be the thing that decides which events
// were simultaneous — only `coalesceWildMagicTriggers` knows what a batch is.
//
// The RNG derivation moves with it. A coalesced event cannot be keyed on a
// caster or on `_consumeWildMagicNonce`'s encounter-order counter — either
// would let the order triggers were met in change what the world does — so the
// applicator's stream is now
//
//   SHA-256(entropy ‖ matchId? ‖ uint32be(turn) ‖ uint8(batchCode)
//           ‖ uint8(0x0C) ‖ uint8(effectCode) ‖ uint8(effectiveBracketSteps))
//
// under a NEW domain tag 0x0C, with `batchCode` and `effectCode` explicitly
// pinned maps rather than Dart enum `.index` (see `kResolutionBatchCode` and
// `kWildMagicEffectCode`). Tag 0x09 survives as the per-player wild-magic tag
// used by the forced-cast drain and the bookmark burn; nothing in the
// applicator reads it any more.
//
// The gate has to fire: a v11 and a v12 device resolve the same two casts in a
// different order, roll different axes for the same Chasm, and disagree about
// whether a dead caster's spell happened at all — so they diverge the first
// turn any spell carries a trigger. Nothing crosses the wire that did not
// before and the circuit is untouched, so `kBattleProtocolVersion` stays 7 and
// `kRulesetVersion` stays 3. See docs/WILD_MAGIC_PLAN_VNEXT.md slice 7 and
// docs/WILD_MAGIC_SLICE7_REVIEW.md.
//
//
// v13 (2026-09-03, Mutable Leylines slice D) — a Mutable Leyline reinterprets
// incantation formulas. Two things become leyline-dependent that were fixed
// constants before:
//
//   * the STRUCTURAL grammar length — 3 ordinarily, 4-6 under a mutable leyline
//     (LEYLINE_SEED_PLAN.md §16). Everything that cuts a certified trajectory
//     into formulas now takes it from `IncantationLexicon.formulaLength`;
//   * what a complete formula MEANS — the fixed `effectKindFromPair` table
//     ordinarily, the leyline's derived codebook under a mutable one, where a
//     formula may also mean NOTHING (`IncantationNoise`, audit §6).
//
// A v12 and a v13 device handed the same mutable `MatchConfig` cut the same
// certified trajectory into different chunks and resolve different effects from
// them, so they diverge on the first cast. That is exactly what this gate is
// for. Ordinary play is bit-identical across the bump — ordinary interpretation
// is total, no codebook is derived, and the replay corpus moved by zero bytes —
// but "the honest inputs are unchanged" is not the test, and a leyline is a
// match input either build may be handed.
//
// What did NOT move, and must not: the certified trajectory itself
// (`FormulaTracker`'s three commit rules are length-independent, so the flat
// committed sequence is leyline-invariant), `behaviouralKinKey`, kin stacking,
// heraldic identity, the Wild Magic v2 preimage layout, and intrinsic base mana
// cost as a function of MEANING. Base cost still counts every complete
// structural chunk, noise included (§7.4: *"leylines change interpretation, not
// intrinsic certified cost"*); it moves with `formulaLength` alone, which is
// already a different `leylineConfigHash`.
//
// Nothing crosses the wire that did not before — `LeylineConfig` has carried
// `mutableMagic` and `formulaLength` since Slice 1 — and the circuit is
// untouched, so `kBattleProtocolVersion` stays 7 and `kRulesetVersion` stays 3.
// See docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice D.
//
/// The deterministic battle-engine consensus epoch this build implements.
///
/// The single canonical definition — [MatchConfig.battleEngineVersion] and
/// [DeviceCapabilities.battleEngineVersion] both default to it rather than
/// restating a literal, exactly as `MatchConfig.rulesetVersion` derives from
/// `kRulesetVersion`. See this file's header for what forces a bump.
const int kBattleEngineVersion = 13;

/// What a peer that predates the engine-version gate implicitly declares: it
/// omits the field, and an omitted field cannot be read as agreement.
///
/// Never a legal value for a build to *claim* — [kBattleEngineVersion] starts
/// at 1 precisely so "didn't say" and "said v1" can never collide.
const int kUndeclaredBattleEngineVersion = 0;
