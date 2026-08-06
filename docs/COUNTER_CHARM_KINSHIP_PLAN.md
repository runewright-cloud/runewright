# Trajectory Counter Charms, Behavioural Kinship, and Commitment Removal — Implementation Plan

*Drafted 2026-08-05 on `main`, from a design session with Soren.*

*Decisions in §2 are Soren's and are settled. §3 are rulings made on Soren's behalf —
review before building on them. §8 lists the questions that are still open.*

---

## 0. Build status (2026-08-06)

**Phases 1–3 are BUILT**, on `main`, uncommitted. 1406 tests green.

Soren overrode §7's "do not start before the playtest" on 2026-08-06 — the reason given
was that a trajectory charm is a smoother experience to *playtest*, which the old
bind-to-a-spell-you-already-lost-to flow is not. §7 is left below as written because its
reasoning about **Phase 4** still holds exactly: Phase 4 is the part that could not have
been done in the time, and it remains undone.

| Phase | State |
|---|---|
| 1 — Measurement | `scripts/trajectory_histogram.dart`. Run against a library export from the playtest; the five shipped basics are too small a corpus to set `k` from. |
| 2 — Counter charm redesign | Built. Model, matching, cost, partial counter, entry UI, card treatment. |
| 3 — Kinship redefinition | Built, **behavioural half only** (Soren's call, 2026-08-06). Kin-stacking + arms + salted book reveal moved; permissions and art sync deliberately stay on `commitmentHex` — see §3.3 note below. |
| 4 — Commitment removal | Not started. VK-breaking; unchanged from the plan. |

### Rulings made during the build

These were not in the plan and were decided while implementing. Each is written into the
code's comments at the site it governs.

1. **A full counter takes the OLD code path exactly.** When a charm cancels every formula,
   `_applySpell` is never called — byte-for-byte today's behaviour. Only a *partial*
   counter resolves. This is what settles the wild-magic re-check §5 Phase 2 flagged: A1
   ("no wild magic on a countered cast") still holds for free in the full-counter case,
   and a partially countered cast fires its wild magic because it is a cast that really
   happened. `ResolvedSpellEvent.wasCountered` therefore keeps meaning "nothing
   happened"; the new `counteredFormulas` means "a charm fired."
2. **Cancellation is in WHOLE FORMULAS for summons too.** §5 says "cancel the first 3
   stat contributors", and a charm's trajectory is a whole number of formulas, so a
   partially-agreeing second formula cancels nothing extra. One number covers both cast
   modes, which keeps the mana charge, the UI copy and the canonical state all speaking
   in formulas.
3. **A charm whose owner cannot pay does not fire and is not consumed.** §2.4 charges full
   cost on every trigger; part-paying would make that a soft cost. The charm stays charged
   for a turn its owner can afford, and a shorter charm on the same wizard can fire in its
   place.
4. **When several charms match, the LONGEST match wins**, ties breaking by the pre-existing
   fixed scan order (avatar `playerId`, then accoutrement `id`). Pure function of state, so
   both devices agree. At most one charm fires per cast — charms do not stack.
5. **Chain state reads the FULL spell, not the surviving formulas.** The caster channelled
   the whole thing; the charm interfered with what it produced. Keeps `_updateChainState`
   untouched, and the full-counter path still regresses the chain as before.
6. **`targetSpellName` is deleted, not repurposed.** §5 Phase 2 proposed keeping it as a
   display string for the trajectory; deriving the label (`charmTrajectoryLabel`) instead
   removes a second source of truth that could only ever drift — which is exactly what the
   old field did once a bound spell was renamed.
7. **Charm length is capped at 4 formulas** (`kMaxCharmFormulas`) for the entry UI. Not a
   balance rule — the cost curve is — but the editor needs a finite surface and a malformed
   loadout needs to be rejectable. At 4 formulas a trigger already costs a full innate pool.
8. **A charm persisted under the old grid binding loads as UNATTUNED.** A grid commitment
   says nothing about behaviour, so there is nothing to migrate it to. Players re-type.
   No prompt was added — the chapter editor shows "Not attuned — tap to set a trajectory".

### Deliberately not done

- **Permissions and art sync stay keyed to `commitmentHex`.** §3.3 puts them on
  `hash(proofBytes)`, but that changes `SpellPermission.canonicalMessage` and so
  invalidates every outstanding loan and apprentice grant. The *security* requirement §3.3
  actually states — "permissions must not become behavioural" — is satisfied as-is:
  `commitmentHex` is a grid identity and still one-to-one. The concept split
  (`spell_identity.dart`: `behaviouralKinKey` vs `uniqueSpellId`) is in place, with the
  reasoning recorded at both call sites, so Phase 4 is a re-key and not a redesign.
- **`k` is still 10.** Phase 1's histogram wants playtest data, which does not exist yet.
- **The book Merkle root did not move.** It authenticates per-spell membership and hand
  position, which needs a one-to-one key; only the batch hash + reveal (the duplicate
  check) moved to salted kin leaves. `DuelSetupResult` now carries `localKinLeaves` and
  `peerBookHash` so the post-match reveal — still unwired, as before — has its inputs.

### Follow-ups

- **Two-device LAN pass.** The charm trajectory is inside `BattleState.toCanonicalBytes()`
  and decides which formulas resolve, so a divergence is a desync rather than a display
  bug. Unit tests cover the hash; only hardware proves the wire.
- **On-screen pass** of the attune dialog and the partial-counter banner
  (`flutter run -d linux`).
- **Design doc §269 (Air-Water Divination)** — *"See target's counter charm alignment,
  will turn bookmarks marking those spells red"* — now means "trajectory", not "bound
  spell". Not implemented in the engine, so nothing is broken; the prose wants Soren.
- **`docs/ARTIFACT_SYSTEM_PLAN.md` §2 table** still says the charm "auto-fires on its
  attuned spell *(unchanged)*". Stale.

---

## 1. What this builds

Three changes that look separate but are one idea: **spell identity should be behavioural,
not structural.**

1. **Counter charms are rebound from a specific spell to an elemental trajectory.** The
   player types a trajectory when the charm is created. Any spell whose certified element
   sequence matches the charm's prefix is countered automatically, effect by effect, for as
   long as the two sequences stay in lockstep.
2. **Kinship is redefined** from "same initial grid" to "same certified trajectory and
   per-step mana cost."
3. **The grid commitment is deleted from the circuit**, because once (1) and (2) land,
   nothing needs a stable public function of the grid any more.

### Why the current counter charm needs replacing

Binding a charm to one spell, out of combat, produced three asymmetries Soren has been
dissatisfied with for a while:

- **You must lose to a spell before you can counter it.** A player returning to a local
  meta dominated by a known optimised engine has to sit through it at least once before
  they can bind against it.
- **Mid-combat charm generation is dead weight.** Artifact-summoning effects can mint a
  counter charm during a battle, but a freshly minted charm has nothing to bind to, so it
  can never fire that match.
- **The binding step itself is cumbersome** — a library-screen flow ([library_screen.dart:189](../lib/ui/library_screen.dart#L189))
  that exists only to attach a `targetCommitmentHex`.

### Why the current kinship definition needs replacing

Kinship exists to force players to keep designing rather than settle on one optimum. Keyed
to the grid, it fails at exactly that: a player who finds an efficient engine adds one
throwaway dot that dies in generation 1, moves it a cell over whenever they want a "new"
spell, and pays nothing. The trajectory is unchanged, the CA is unchanged, the commitment
is different, kinship never triggers.

Keyed to trajectory, that exploit is dead — the throwaway dot doesn't alter the trajectory,
so the variants stay kin. To escape kinship a player must change what the spell actually
*does*, which is the behaviour the mechanic was always meant to reward.

---

## 2. Settled decisions (Soren's)

1. **Neutral is not matchable.** Generation 0/neutral never participates in counter-charm
   matching. This needs no code change: `FormulaTracker` already refuses to commit neutral
   or tied generations ("A tie or neutral generation (`zone == null`) never adds anything
   under any branch" — [formula.dart](../lib/engine/formula.dart)), so the committed
   sequence is already 4-valued `BorderZone`s. Matching therefore runs over a 4-symbol
   alphabet: 4³ = 64 distinct three-element prefixes.
2. **Trigger threshold is 3 matching elements**, which is exactly one formula — "Activations
   are grouped into formulas of exactly 3" ([formula.dart](../lib/engine/formula.dart)). A
   3-element charm cancels the leading effect only.
3. **Countering continues in lockstep and stops at the first divergence.** Additional
   effects (or, for a summon, additional stat contributors) keep being cancelled while the
   charm's sequence and the spell's sequence agree.
4. **Full mana cost is paid on every trigger**, regardless of how many effects actually got
   cancelled. This is the balance lever against absurdly long charms.
5. **Cost scales with charm length.** Shape and constant in §3.2.
6. **Kinship applies only to spells with ≥ 9 elements** in their trajectory. Shorter spells
   are exempt (see §3.4 for the consequence).
7. **The counter-charm melee passive is unchanged.** The 5-percentage-points-per-charm
   melee proc ([turn_loop.dart:578](../lib/battle/engine/turn_loop.dart#L578)) survives the
   redesign untouched. Only the *active* is being replaced.
8. **The charm still occupies an artifact slot** via `ArtifactKind.counterCharm`. Trajectory
   entry replaces spell-binding; the slot economics are unchanged, which is what the §2
   breadth argument rests on.
9. **Heraldic arms are keyed to trajectory**, so kin continue to share arms — preserving
   today's visual tell under the new kinship definition. Loans and art sync key to the proof
   hash instead (§3.3).
10. **Do not act before the playtest.** See §7.

### The breadth objection, and why it was dropped

An early concern was that a 3-element charm would match too large a slice of the meta. It
was overstated: it assumed a 5-symbol alphabet including neutral (125 prefixes) when the
real alphabet is 4 (64 prefixes), and it ignored the cost structure. A 3-element charm
matches 1 of 64 formulas, cancels only the leading effect, costs a whole artifact slot, and
charges full mana per trigger. Against a 3-effect spell that is one third of one spell for
a permanent slot. Short charms are self-limiting.

The residual, non-blocking version of the concern: **the distribution of opening formulas is
not uniform.** The `FormulaTracker` lead-change rule means the first committed element is
whichever zone takes the lead first, which is unlikely to be uniform across the four
elements. Worth a histogram (§5, Phase 1) — if one prefix covers a large share of real
spells, `k` in §3.2 wants raising. This is a tuning input, not a design flaw.

---

## 3. Rulings made on Soren's behalf

### 3.1 The matching primitive already exists

`TrajectoryParser.certifiedElementSequence(outputs)` ([trajectory_parser.dart:110](../lib/battle/engine/trajectory_parser.dart#L110))
drives `FormulaTracker` from `outputs.dominanceTrajectory`, `outputs.supremeDominanceFlags`,
and `outputs.t` — all public, all SNARK-certified. Counter-charm matching and kinship both
key off this same call.

**Consequence: phases 1–3 need no circuit change, no VK break, and no re-inscribe.** The
proof already publishes everything the new mechanics consume. Build against
`certifiedElementSequence`, never against a locally replayed sequence, or the trust boundary
that `_certifiedManaCost` established gets reopened.

### 3.2 Charm length is a whole number of formulas; cost is triangular in formulas

Because one formula is exactly 3 elements, charm length should be constrained to a multiple
of 3. Let `F = length / 3`:

```
cost = k · F(F+1)/2          // triangular in formulas
```

With `k = 10`: `F=1 → 10`, `F=2 → 30`, `F=3 → 60`, `F=4 → 100`.

Grounding: innate mana pool is 100, +100 per mana gem, Meditate restores 25, duels start at
half pool ([match_config.dart:39](../lib/battle/models/match_config.dart#L39)). So a
one-formula charm costs under half a Meditate — cheap enough that fishing it out with a
single-effect spell is a genuine trade, which is the counterplay Soren wants — while a
four-formula charm costs a full innate pool *per trigger*, making total spell negation a
real gamble. The superlinear shape is what stops long charms from being strictly correct;
linear scaling would make a full-spell counter far too efficient.

`k` is `[TODO — playtest]`, matching how the other artifact constants are treated
([turn_loop.dart:578](../lib/battle/engine/turn_loop.dart#L578) and the Rod of Wind rate).
Tune `k`, keep the shape.

The triangular form is also idiomatic here — Watery Boost already charges `n(n+1)/2`, so
players have met this curve before.

### 3.3 Two identifiers, two jobs — do not let "kin" mean both

Kinship currently keys four unrelated systems. They must not all follow the new definition:

| System | Today | After | Why |
|---|---|---|---|
| Kin-stacking forfeit ([battle_session.dart:516](../lib/battle/networking/battle_session.dart#L516)) | commitment | **trajectory** (salted, §3.5) | This is the anti-exploit rule; it *should* move. |
| Spell permissions / loans ([spell_permission.dart:84](../lib/spells/spell_permission.dart#L84)) | commitment | **proof hash** | Security boundary. See below. |
| Heraldic arms ([spell_card_painter.dart:1536](../lib/ui/spell_card_painter.dart#L1536)) | commitment | **trajectory** | Preserves today's "kin share arms" visual tell. Settled — §2.9. |
| Art sync matching ([sync_art_session.dart:180](../lib/trade/sync_art_session.dart#L180)) | commitment | **proof hash** | Needs per-spell identity, not per-behaviour. |

**Permissions must not become behavioural.** A permission that "covers all Kin spells" would,
under trajectory kinship, silently extend to spells with *different grids* — potentially
someone else's coincidentally-matching spell. That is a privilege-escalation bug, not a
display quirk.

**Use `hash(proofBytes)` as the unique spell identifier.** It leaks nothing about the grid,
any holder of the proof can recompute it (loaned spells carry `proofBytes` through
`withGridWithheld` — [spell_asset.dart:390](../lib/spells/spell_asset.dart#L390)), and it
cannot be claimed for a spell you do not own, because proofs are owner-bound at public input
index 1 ([proof_wire.dart](../lib/protocol/proof_wire.dart)). It also satisfies the
anti-bait-and-switch requirement that motivated keeping a unique ID at all.

Two caveats to accept explicitly:
- UltraHonk proofs are randomised, so **re-inscribing a spell changes its identifier** and
  therefore its arms-if-keyed-that-way and its outstanding loan keys. Acceptable: after the
  Phase 4 ruleset bump everyone re-inscribes anyway, and loans are re-issued.
- Do **not** use `SpellAsset.id` ([spell_asset.dart:57](../lib/spells/spell_asset.dart#L57))
  for this. It is self-asserted and a recipient cannot verify it ties to the actual spell;
  `hash(proofBytes)` they can recompute.

### 3.4 The ≥9-element exemption creates a short-spell stacking hole

Settled decision 6 exempts spells with fewer than 9 trajectory elements from kinship. That
is the right fix for collisions — 9 elements is 4⁹ ≈ 262,000 combinations, where 3 elements
is only 64, so short spells would otherwise collide constantly and forfeit players for
casting two genuinely different cheap spells.

But the exemption means **short spells become freely kin-stackable.** Probably fine, since
short spells are weak, and there is precedent — Basic Spells already carry a scoped
kin-stacking exemption ([BASIC_SPELLS.md](BASIC_SPELLS.md)). Flagged so it is a decision
rather than an inheritance. See §8.

### 3.5 The book reveal is the largest exposure, and it needs a salted key

`exchangeBookReveal` sends the **sorted commitment list of every spell in your book** to the
opponent at battle setup ([battle_session.dart:500](../lib/battle/networking/battle_session.dart#L500)),
so the opponent can check it for internal duplicates. Today that hands your opponent a
stable, cross-match identifier for every spell you brought — including ones you never cast.

Migrating this to raw trajectories would be **worse**: a trajectory is semantically
meaningful, so the opponent would learn what your unplayed spells actually do.

The duplicate check only ever compares entries *within one player's own list*. So reveal
`SHA256(trajectory ‖ per_match_salt)` with a fresh random salt each match. Duplicates still
collide, so kin-stacking is still detected; the opponent learns neither the trajectory nor
anything that correlates across matches. Strictly better than today on both counts.

---

## 4. Why the commitment can simply be deleted

Not salted — deleted. The reasoning, recorded because it will otherwise be re-derived:

**The commitment is a proof public input, and that is unavoidable while it exists.** "Public
input" in SNARK verification means "a value in the verification equation," not "a value fed
into the circuit." The grid is a private witness and never leaves the device; Poseidon2 runs
over it *inside* the circuit; the result is a `pub` return value, which lands in the same
public-input vector the verifier consumes — `[4B count][public inputs, 32B each][proof]`
([proof_wire.dart](../lib/protocol/proof_wire.dart)). Anyone who verifies your spell
necessarily receives the commitment. There is no transport-layer fix.

**Unsalted plus deterministic makes it an offline oracle.** Anyone holding it can test grid
guesses for free, with no rate limit, against a hash deliberately optimised to be *fast*
in-circuit. Worse, no table is even needed for shared spells: Basic Spells ship with
identical commitments for every player, and any published recipe is recognisable in anyone's
book forever.

**Salting was considered and rejected as more work for the same result.** Salting requires
designing a salt-sharing protocol for every party that legitimately needs to match. Once
§3.3 moves every consumer off the commitment, nobody needs to match on it, so it can just
go — and the packing constraints go with it.

**Expected gate saving: modest.** One Poseidon2 permutation plus the 469-cell packing,
against tier-12's 390,726 rows in a 2^19 (524,288) bucket. Run `bb gates` at tier-12 first
regardless, per CLAUDE.md. Directionally helpful in a bucket that is ~75% full; not a reason
to do the work on its own.

### What this does *not* achieve, and what to tell players

Removing the commitment removes the *cheapest* oracle, not the only one. Still public and
unremovable:

- `segment_count` and `dot_count` are literal T=0 geometry, and they feed mana cost.
- `dominance_trajectory` and `supreme_dominance_flags` must stay public — the whole of this
  plan is built on them.

An attacker can still guess a grid, run the stepper, and compare. Removing the commitment
raises the per-guess cost from one hash to one CA simulation; `dot_count`/`segment_count`
remain a cheap pre-filter.

**Privacy therefore scales with spell complexity**, and that is the honest claim:

> Your grid is never transmitted. Reconstructing it means searching design-space against
> your spell's visible behaviour — hopeless for anything intricate.

A 3-dot spell has ~1.6M candidate placements before filtering and is recoverable over lunch.
A 10-dot spell is ~2⁵⁴ before filtering and is not recoverable by anyone your players will
meet. The spells simple enough to crack are largely the ones people publish anyway.

**Do not promise "fully protected."** The math does not support it, and a privacy claim that
quietly fails is worse than a modest one that holds.

### Rejected: publishing `mana_cost` instead of `segment_count`/`dot_count`

Considered as a Phase 5 and **rejected on inspection.** The idea was that a derived cost
leaks less than raw geometry. It does, but far less than it appears: `T` is public and
`effectCount` is derivable from the public trajectory, so an attacker divides back out and
recovers `5·segment_count + dot_count` exactly. That is two numbers collapsed into one
linear combination — and with coefficient 5 at small magnitudes, few solutions survive
(`5s + d = 17` admits only `(0,17), (1,12), (2,7), (3,2)`).

Against that small constant factor: the base formula is
`round(base * 1.05^T * 1.5^effectCount)` ([turn_loop.dart:6410](../lib/battle/engine/turn_loop.dart#L6410)),
IEEE-754 double arithmetic. Prime fields have no floats, and replicating double rounding
in-circuit is not something anyone should attempt — so the formula would have to be
redefined in exact rational arithmetic, shifting some spells' costs by ±1 mana. Gate cost
itself looks fine (exact-rational `(21/20)^T`, one ~211-bit remainder range check,
`tier_max` compare-and-select iterations for `effectCount` — low thousands of constraints),
but a rule redefinition plus a corpus regeneration for a constant factor is a bad trade.

Note also that only step 1 (`_certifiedBaseManaCost`) could ever move in-circuit: steps 2–5
of `_certifiedManaCost` read live battle state (chain, Efficiency, recall tally,
`nextSpellCostDouble`) that the circuit cannot see.

---

## 5. Phases

Ordered so that everything not requiring a circuit change lands first, and the VK-breaking
change is a single deliberate step at the end.

### Phase 1 — Measurement (do first, it is cheap and it sets `k`)

Histogram the opening formula across the Basic Spell set and any spells collected during the
playtest. Output: distribution of 3-element prefixes, and distribution of trajectory lengths
(to sanity-check the ≥9 threshold from §2.6 against real spells).

Feeds `k` in §3.2 and confirms or corrects §3.4.

### Phase 2 — Counter charm redesign (Dart only)

- **Charm model.** Replace `targetCommitmentHex` on `ChapterAsset`
  ([chapter_asset.dart:33](../lib/spells/chapter_asset.dart#L33)) with a `List<BorderZone>`
  trajectory, length constrained to a multiple of 3. `targetSpellName`
  ([chapter_asset.dart:40](../lib/spells/chapter_asset.dart#L40)) becomes a display string
  for the trajectory instead of a bound spell's name.
- **Entry UI.** Replace `_bindCounterCharmOnSpell` ([library_screen.dart:189](../lib/ui/library_screen.dart#L189))
  with a trajectory entry surface. It no longer hangs off a spell, so it moves out of the
  per-spell menu and onto the charm itself.
- **Matching + resolution.** Hook the prefix match into the existing counter path — the
  `wasCountered`/`counterCharmOwnerId` plumbing on `ResolvedSpellEvent`
  ([turn_loop.dart:436](../lib/battle/engine/turn_loop.dart#L436)) already exists and stays.
  What changes is the *trigger test* and the fact that countering is now partial: cancel
  effects while in lockstep rather than nullifying the whole cast.
- **Partial counter is the genuinely new engine behaviour.** Today a countered cast never
  reaches `_applySpell` at all (which is what makes "no wild magic on a countered cast" hold
  for free — see the comment at [turn_loop.dart:3917](../lib/battle/engine/turn_loop.dart#L3917)).
  Partial countering means the cast *does* resolve, with a prefix of its formulas
  suppressed. **Re-check the wild-magic invariant when doing this** — it is currently
  load-bearing and implicit.
- **Summons.** Cancel the first 3 stat contributors rather than the first effect
  (`CreatureSpec.fromElements` consumes the same sequence).
- **Mana.** Charge per §3.2 on every trigger, regardless of effects cancelled.
- **Keep the melee passive unchanged** ([turn_loop.dart:578](../lib/battle/engine/turn_loop.dart#L578)) —
  settled, §2.7. The charm keeps its artifact slot (§2.8), so `AccoutrementKind.counterCharm`
  stays deliberately absent from the declarable list ([turn_loop.dart:728](../lib/battle/engine/turn_loop.dart#L728)):
  charms still self-trigger rather than being declared.

### Phase 3 — Kinship redefinition (Dart only)

- Kinship key becomes certified trajectory + per-step mana cost, gated to ≥9 elements.
- Confirm per-step cost is derivable from public outputs before starting. Expected yes:
  `certifiedElementSequence` needs only `dominanceTrajectory`, `supremeDominanceFlags`, and
  `t`, and `_certifiedManaCost` already accepts that sequence. **Verify, do not assume** —
  if it is not derivable it becomes a new public output and this phase joins Phase 4.
- Migrate the four consumers per the §3.3 table. Split the concept into two named things
  (behavioural kinship vs. unique spell identity) *before* refactoring, or this will produce
  a subtle permissions bug.
- Switch `exchangeBookReveal` to the salted trajectory hash of §3.5.

### Phase 4 — Commitment removal (circuit; VK-breaking)

Only after phases 2–3 have landed and nothing reads `commitmentHex`.

- `bb gates` at tier-12 **before** touching tiers 24/48.
- Remove the commitment return and the grid packing from the circuit.
- Bump `RULESET_VERSION` to 4.
- Regenerate the full golden corpus, positive **and negative**. A failing negative vector is
  a release blocker.
- Drop `commitmentHex` from `VerifiedSpellOutputs` ([proof_intake.dart:46](../lib/battle/engine/proof_intake.dart#L46))
  and the wire ABI offsets that follow it.
- Players re-inscribe. Ship the migration notice with it — there is precedent for the
  legacy-spell class and its delete flow ([library_screen.dart:592](../lib/ui/library_screen.dart#L592)),
  but a re-inscribe prompt is friendlier than a delete.

---

## 6. What this deliberately does not do

- **No salted commitment.** Superseded by deletion (§4).
- **No `hash(grid‖T)` identifier.** `T` is public and ranges 1–48 — about 5.6 bits of
  *published* value, so an attacker just tries all 48. It is not a salt. This was considered
  for loan keys specifically and rejected: it hands the grantee an oracle on the owner's
  grid, which is exactly what `withGridWithheld` exists to prevent.
- **No in-circuit mana cost.** Rejected in §4.
- **No change to the counter-charm melee passive.**
- **No change to how spells are inscribed or proven**, beyond the Phase 4 ABI change.

---

## 7. Timing — the most important decision in this plan

**Do not start before the playtest (Sat 2026-08-08).**

Phases 2–3 are Dart-only and could technically ship at any time. Phase 4 cannot: CLAUDE.md
invariant 4 requires the full positive *and* negative corpus to pass before any circuit
change is committed, on a tier-12 circuit already ~75% into its 2^19 bucket. That is vector
regeneration plus a full corpus run — not a three-day change with a playtest at the end of
it.

Doing phases 2–3 alone before the playtest would also mean playtesting mechanics that are
about to change again, and would split the kinship migration across a version boundary.

The cost of waiting is one playtest run on the old counter charm, which is information, not
waste — Phase 1's histogram wants that data anyway.

---

## 8. Open questions

Only two remain. The melee passive, the artifact slot, and arms keying were resolved
2026-08-05 and moved to §2.7–2.9.

1. **Short-spell stacking** — is free kin-stacking below 9 elements acceptable (§3.4)? There
   is precedent in the scoped Basic Spells exemption, and short spells are weak, so this may
   simply be fine. Phase 1's trajectory-length histogram should inform it: if a large share
   of real spells land under 9 elements, the exemption is a much bigger hole than it looks.
2. **`k`** in the cost curve (§3.2) — set from Phase 1's prefix histogram, then leave as
   `[TODO — playtest]` like the other artifact constants.
