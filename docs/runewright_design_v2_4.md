# Runewright — Game Design Document (v2.4)
*Briefing document for Claude Projects context*

*Last updated: post-v2.3 revision review (Fable) and follow-up discussion. Incorporates the 12-item punch list and three substantive findings (void gate, scroll single-use, absorption-rod/accoutrement defense), the mana/chain "chain-as-currency-for-T" resolution, the burn-accoutrements ruling, owner-pubkey representation fix, the reversed difficulty gradient, and an errata sweep. Open decisions are flagged inline in **DECISION** and **TODO** blocks.*

> **v2.4 changelog (this pass):** void wild-magic re-gated by *tier cap* (the cost curve alone doesn't tax grinders — combinatorics defeat it); scrolls bound to a named opponent at issuance (no global state → "one-time" otherwise unenforceable); `owner_pubkey` carried as `Poseidon2(pubkey)` (256-bit Ed25519 key won't fit one BN254 field); absorption-rod accoutrement-defense role deliberately dropped, Burn-accoutrements interactions specified; difficulty gradient reversed (repeat formulas *easiest*, opposites hardest) with an effect-table power-audit goal; mana exponential affirmed (cognitive-load throttle) with the free threshold set to **T−4** (dominance can't begin before the border is reached at gen 4); **T-architecture changed from a single circuit to three discrete tiers `T_max ∈ {12, 24, 48}`** (12/24 green everyday play, 48 a yellow opt-in spectacle tier — occasional big-spell memories matter, and low-seed bloomers are tier-gated not mana-gated); HP standardized to 24; chain break-vs-regress resolved (action breaks, inaction regresses); errata sweep (ring 13→12, apprenticeship numbering, worksheet sync, truncated cell, version header).

> **How to read the decision flags in this doc**
> - **`[DECISION — needs Soren]`** — a genuinely open choice the review surfaced that only you can make (game feel, missing constant, or a factual question about prior measurements). I've laid out the options but have *not* picked one. These are also collected in the "Open Decisions" section at the end.
> - **`[APPLIED — confirm]`** — I resolved this per your stated prior intent or per the review's clear recommendation, and wrote the doc as if it's settled. If you disagree, flag it and I'll flip it.
> - **`[TODO — playtest]`** — settled in principle, tuning deferred to playtesting.

---

## Vision & Design Philosophy

A mobile game simulating the experience of being a D&D-style wizard in real life. Core pillars:

- **Jealously guarded magical discoveries** — players are incentivized to protect their spell designs.
- **No central authority** — fully peer-to-peer, zero ongoing server overhead for the developer.
- **Cryptographic integrity** — cheating on spell output is mathematically hard, not just socially discouraged.
- **Mystique as a structural feature** — the decentralized design creates speculation, rumor, and community lore organically.
- **Face-to-face experience** — duels happen in person between two or more phones via local wireless; the design is optimized for in-person play, including psychological games and misdirection in combat, and out of combat a level of tradecraft-esque tactics including shoulder-surfing and deceitful trade bargains (à la *Diplomacy*) as a real meta-game element for discovering magical secrets — balanced by an ethos of respecting people's personal privacy and comfort levels.
- **Free, ad-free, no microtransactions** — donation-only model, no data harvesting.
- **Word-of-mouth distribution** — designed to feel like a discovery shared between people with similar taste.

> **Scope-of-secrecy honesty note (from review §1).** The cryptography protects the *exact grid* — your rune cannot be forged, replayed, or counter-targeted without being witnessed. It does **not** make your spell's *function* unstealable: because the CA is deterministic, public, and open-source, a tool-using player who has seen your spell's effects can search offline for *some* grid producing the same trajectory. They get a functional clone, not your commitment. The design embraces this bifurcated meta (by-hand artisans vs. "spell foundry" optimizers) rather than pretending to prevent it. The promise that survives scrutiny is *"your exact rune cannot be forged or countered without being witnessed,"* not *"your spell cannot be copied."* However the clone may have different mana costs (likely cheaper for power users). Mitigation of this split approach comes in the form of social preferences, and the wild-magic system (which depends on the exact grid via the commitment, not just the trajectory) already gives hand-crafted grids residual value a clone lacks.

---

## Platform & Tech Stack

- **Primary target:** Android (Flutter/Dart)
- **Development environment:** Ubuntu Linux, VS Code, Flutter SDK
- **iOS port:** Not currently planned; possible next step if demand is demonstrated; would require Mac hardware and a significantly different distribution approach
- **Cross-platform multiplayer:** Out of scope; would like to manage in some form if an iOS port ever materializes
- **Local networking:** Pluggable transport layer (see below). Three possible adapters behind one interface — a **cross-platform** floor (BLE + LAN sockets/mDNS; all Android + future iOS), **Nearby Connections** (Google↔Google convenience, best for field play), and **Wi-Fi Direct** (infra-free Android range). Transport is auto-negotiated **per session** (with manual override) so any two players share a common one and can cross-play. Radio robustness matters mainly in sorcerer field play. All bundled in one APK; no external component for any user.
- **ZK proofs:** Noir framework with Barretenberg backend (UltraHonk)
- **In-circuit hashing:** Poseidon2 (BN254, state size 4, sponge with rate 3 capacity 1) — matches Noir stdlib
- **Spell effect hashing:** SHA-256 (outside circuit, standard Dart crypto package)
- **Mobile FFI:** TBD (noir_rs recommended starting point, with Rust FFI bridge to Dart). Re-survey the mobile Noir FFI ecosystem (noir_rs, mopro) at Phase 2 start rather than trusting any earlier snapshot.

### Pluggable transport layer `[RESOLVED — build the seam from day one]`

*(review §1)* **Distribution and transport are separate decisions.** Distribution (how players get the app) is **Google Play Store** — easy, familiar, no change. Transport (how two phones talk during a duel) is built behind a **pluggable interface** so it isn't hardwired to any one mechanism.

**Why the seam matters:** the duel transport, not the store, is where the Google dependency actually lives. Nearby Connections is part of Google Play Services (a device-side runtime, `com.google.android.gms:play-services-nearby`), so it does not function on de-Googled Android (GrapheneOS, CalyxOS, AOSP-only) — *regardless of how the app was installed.* That demographic overlaps heavily with this game's most natural evangelists (privacy-conscious, FOSS-friendly, donation-ware, no data harvesting), so a Nearby-only build would silently exclude exactly the people most likely to love it. Hardwiring Nearby makes a fallback a rewrite; a seam makes it one new adapter.

**Hard requirement (met):** a stock-Android / Play-Store player must never install anything beyond the app itself. This holds — Google Play Services is already present and auto-updated on such devices, the `play-services-nearby` client library is compiled into the APK, and the AOSP fallback uses only OS framework APIs. **Both transports ship inside the single APK; no user on any device ever obtains a separate component.**

**Architecture (brief for implementation):**
- Define a minimal transport interface: `advertise / discover / connect / send(bytes) / onReceive / disconnect`. All game/netcode talks to this interface only — never to a transport SDK directly.
- **Adapter 1 — AOSP universal transport (the floor every session can use):** Wi-Fi Direct (`WifiP2pManager`), LAN sockets with NSD/mDNS discovery, and/or Bluetooth — all OS framework, present on *every* Android device including stock/Google ones, no Play Services. Pairing via a **transport-agnostic QR-code or short-code** handshake (natural and even thematic for in-person play). This is the common denominator that guarantees anyone can duel anyone.
- **Adapter 2 — Nearby Connections (optional convenience, Google↔Google only):** where *both* devices have Google Play Services, offer Nearby's zero-config discovery as a nicety. It is **never the sole path** to a connection.
- **Cross-play rule — negotiate per session, not per device.** Nearby Connections and the AOSP transport are different, non-interoperable protocols: a phone on Nearby cannot discover or connect to a phone on AOSP. So the two phones must agree on a transport they *both* support at handshake time. Because every device — Google and de-Googled alike — supports the AOSP floor, a Play-Store player and a GrapheneOS player **always share a common transport and can cross-play.** The naive "Nearby if Google, else AOSP, chosen per device" logic is explicitly *wrong* — it would bisect the community into two non-interoperable pools. Avoid it.
- Payloads are tiny (UltraHonk proofs are tens of KB; per-turn state hashes smaller), so any of these transports is more than sufficient.

> **Radio behavior — no free auto-switching (unlike Nearby), and it matters *per play mode*.** Nearby Connections automatically abstracts and juggles Bluetooth + Wi-Fi (discover on BLE, upgrade to Wi-Fi for bandwidth, fall back to Bluetooth). The raw AOSP APIs do *not* coordinate — "use whichever radio is stronger / hand off as you move" is orchestration you'd build yourself. **Tabletop wizard mode doesn't need it:** tiny payloads, ~1 m separation, turn-based — pick one transport (Wi-Fi socket primary, Bluetooth fallback, availability-based). **Sorcerer field mode does:** players move around a field, drift apart, and pass in and out of radio range, so range, robustness, and hand-off become real — and this is exactly where Nearby's juggling (or Wi-Fi Direct's longer range) earns its keep. Treat the radio question as per-mode, not a flat yes/no.

> **iOS cross-play readiness — the radio choice sets the ceiling.** "AOSP" means Android; the named APIs are Android-only. But iOS↔Android local P2P is feasible *at the transport layer down the line* **only on cross-platform foundations**: **BLE** (custom GATT service, iOS CoreBluetooth ↔ Android) and **LAN sockets + mDNS/Bonjour** interoperate; **Wi-Fi Direct** (Apple uses its own AWDL/Multipeer) and **Nearby Connections** (Apple analog is Multipeer Connectivity) do **not**. So if iOS is ever in scope, build the universal transport on **sockets+mDNS and/or BLE** and never make Wi-Fi Direct or Nearby the sole path — a future iOS port then becomes one more adapter behind the seam. (Caveat: transport is only one piece of an iOS port — full app, ZK FFI on iOS, App Store distribution all separate; this just keeps the networking door open. Matches the "iOS someday-maybe" stance in the stack section.)

> **`[DECISION — needs Soren]` Transport adapters & selection.** Mode matters: tabletop wizard play needs no radio sophistication; sorcerer *field* play is where range, robustness, and hand-off matter (see Radio behavior above). The three meaningful adapters — by *protocol*, with platform reach:
> - **Cross-platform (BLE + LAN sockets/mDNS)** — *universal*: all Android **and future iOS**. Ideal for tabletop; for field play needs a hosted hotspot (sockets) or accepts BLE's shorter range. This already covers de-Googled Android, so it overlaps Wi-Fi Direct — Wi-Fi Direct's only unique add is infra-free **range**.
>
> **Selection — auto-negotiate with manual override (recommended over pure manual).** Pure manual (each player picks one; connect only if both match) is fragile. Instead, the QR/short-code pairing advertises each side's supported adapters and **auto-picks the best common one**; a settings toggle lets power users **force** a specific adapter (e.g. "Wi-Fi Direct for range" before a field match). Three selectable options, no coordination burden on casual players.
>
> **Build order (incremental — do *not* build all three before first playable):**
> 1. **Cross-platform BLE + sockets** — covers everyone incl. de-Googled, iOS-ready, tabletop-ideal. The universal floor.
> 2. **Nearby Connections** — adds best-in-class Google↔Google field robustness.
> 3. **Wi-Fi Direct** — only if de-Googled *field* play needs infra-free range; budget for the OEM-quirk risk.
>
> Each is one adapter behind the seam; the interface and the per-session capability handshake exist from the first networking commit regardless of how many adapters are built.

> **`[DESIGN NOTE]` Multi-player (>2) and its transport implications.** Supporting more than two players (a future goal, not first playtest) shifts the transport emphasis:
> - **BLE does not scale smoothly.** It's central/peripheral, so multi-player means a **star** (one host relays to several peripherals). Practical simultaneous-connection counts are device/chipset-dependent (~a handful) and BLE throughput is low — fine for 2-player and *small* groups via a hub, flaky beyond that. BLE is not a clean everyone-to-everyone mesh.
> - **LAN sockets are the better multi-player floor:** all players on a shared network or the host's hotspot, sockets + mDNS — more devices, more range, more throughput, still cross-platform/iOS-ready.
> - **Nearby Connections gains value:** its `P2P_CLUSTER` strategy is purpose-built for M-to-N Android groups, smoother than raw BLE for Android-Android multiplayer.
> - **Net:** Multi-player is a real goal, lean the universal floor on **LAN sockets (not BLE-as-primary)**, keep Nearby for smooth Android clusters, relegate BLE to 2-player/small-group/bootstrap.
> The transport is the *easy* half — see the N-player game-design scope in Open Decisions / future work for the harder part (turn order, targeting, friendly-fire, match records, free-for-all vs. teams).

Implementation order is flexible — the non-negotiable is that the interface exists from the first networking commit so neither adapter is special-cased into the rest of the code, and that connection is **negotiated per session** so cross-play is preserved.

---

## The Spellbook Loop (Outside of Battle)

Players inscribe spells into a persistent spellbook on their device. This is the primary creative activity of the game, done outside of battles.

### The Rune Grid

- **Shape:** Hexagonal grid, vertex-down orientation
- **Ring indexing:** rings are counted by **distance from center, center = ring 0** (the axial-coordinate convention). So "ring N" = radius N. There are **13 rings total** (0–12), but the *border* is at radius **12**. A hex region of radius R has `1 + 3R(R+1)` cells, which is what makes the counts below exact.
- **Inscribable region:** Center hex plus 8 rings (radius 8 → `1 + 3·8·9 = 217` cells)
- **Buffer region:** Rings 9–11 — participate in CA simulation but start empty and cannot be inscribed (makes activating the last ring non-trivial)
- **Border ring:** Ring 12 (the outermost ring; 13th ring counting the center) — activations here are counted but cells immediately deactivate and do not participate in CA rules
- **Total cells in simulation:** 469 (radius 12 → `1 + 3·12·13 = 469`) — the number the circuit is built on
- **Coordinate system:** Axial hex coordinates (q, r)

> **`[RESOLVED]` Grid size behind the Phase 1.5 measurement: 469 cells.**
> The 409k-gate / 19,650-gates-per-step result was measured on the full **469-cell** grid, not the 169-cell grid from the Phase 1 brief. The **green** band (comfortable mid-range mobile, ~3.1s desktop proving) therefore stands *for the current design as specified* — no `(469/169)` rescaling is needed. (Headroom is real and deliberately spent via three circuit tiers — see "T-architecture" and "Circuit budget as design lever": tiers at `T_max ∈ {12,24,48}` keep everyday play in green while reserving a yellow spectacle tier.)
> **`Phase 2 measurement: 469 cells.**
> The smoketest was repeated on a Pixel 6 and was able to complete the proof in ~24 seconds.
### Cell States

Two states only: **inactive** (0) and **active** (1). All gameplay variation comes from the rule modification system, not from cell-type variety.

> **Presentation note (review §3) — single most important post-pivot UX decision.** Elemental identity used to live in the cells (13-state CA) and now lives entirely in the dominance system. If the inscription view does not make dominance periods *viscerally* legible — background washes shifting color per dominant element, the rule change **felt** rather than read from a counter — the simulation will look like monochrome Conway and the elemental flavor will exist only in the player's head. Treat live dominance coloring as a first-class requirement of the inscription UI, not polish.

### Border Zone Partitioning — Landscape Layout

The border ring is partitioned into four elemental zones in a landscape arrangement, with opposing elements on opposing sides:

- **Mountain (Earth)** — leftward 18 cells
- **Sun (Fire)** — top 18 cells
- **Sky (Air)** — rightward 18 cells
- **Sea (Water)** — bottom 18 cells

Total: 72 cells. Art outside the grid visually supports the landscape metaphor — mountain silhouette on left, sun at top, sky on right, sea below.

- **Corner cell assignment `[APPLIED — confirm]`:** corner cells assigned symmetrically across rotations (settled previously; pending implementation).

---

## Cellular Automaton Rules

### Baseline Rules (Neutral State)

Hex Conway 2/2 rule:
- An active cell with exactly 2 active neighbors survives
- An inactive cell with exactly 2 active neighbors becomes active
- All other transitions: cell becomes or remains inactive

This is the rule set in effect before any element has gained dominance, or after all elements have decayed to zero pressure.

### Element-Specific Rule Sets

When an element holds dominance (see Dominance System below), its rules replace the baseline:

- **Fire:** Born on exactly 1 neighbor. Survives on exactly 1 neighbor. *(unpredictable wild flitting)*
- **Earth:** Born on exactly 2; survives on any. *(slow inexorable growth)*
- **Water:** Born on 1 and 2; survives on 3+. *(coalescence)*
- **Air:** Standard reproduction; dies with 2+ active neighbors. *(sparse, scattered persistence)*

The Phase 1.5 lookup table contains 70 entries (5 rule states × 2 cell states × 7 neighbor counts), confirming the rule variants compile efficiently regardless of exact specifics.

> **Praise worth protecting (review §3).** These four rule sets are the document's standout strength: the dynamics *visually are* the elements (flickering tendrils, inexorable accretion, coalescing blobs, scattered wisps), which matters enormously in a game where players stare at simulations for hours. Do not let later tuning sand these into generic variants.

### Border Cell Behavior

Border cells (ring 12) follow special rules:
- Activations are counted for the dominance system
- Border cells immediately deactivate the following generation
- Border cells do not participate as neighbors in subsequent CA rules
- Border collateral damage (adjacent cells deactivating) was considered but **removed** to keep triple-element formulas from being harder than player intuition expects

---

## Dominance System

The mechanic by which the player's CA pattern shifts the active rule set during simulation.

> **`[RESOLVED]` Pressure / decay model: floored at 0, dominant-only decay.**
> Pressure can never drop below 0 (so the "negative pressure" language from v2.1 is removed), and **only the currently-dominant element decays**. This resolves the three v2.1 contradictions. The model in full:
> - Each generation, **every** element gains +1 pressure for each border cell activated in its zone (regardless of who is dominant — this is how a challenger overtakes the leader).
> - Each generation, **only the dominant** element loses pressure, by `floor(generation_count / 2)`, floored at 0.
> - Non-dominant pools never decay — they only rise via activations.
>
> **One deliberate consequence (write it into the design, don't fight it):** banked pressure is **sticky upward**. An element that brushes its border zone early keeps that pressure indefinitely until *it* becomes dominant and starts decaying. So long simulations tend to **flicker between elements late-game** — the heavily-decaying leader gets overtaken by whichever rival banked the most, which then decays and is itself overtaken — rather than settling into true neutral. True neutral (all four at 0) is only reachable when nothing has banked pressure or the dominant has decayed to 0 while the rest are also at 0. This is coherent and dramatic, but it revises the old "late-game tendency toward neutral" framing to "late-game tendency toward **flickering dominance / chaos**" (updated in the Decay Philosophy and Design Philosophy sections).

### Pressure Tracking

Each of the four elements maintains a pressure counter (integer, minimum 0):
- Each generation, each element gains +1 pressure for each border cell activated in its zone
- Each generation, only the dominant element decays, by `floor(generation_count / 2)`, floored at 0
- The element with the highest pressure is "dominant" and determines which rule set is active
- **Sticky ties:** the current leader stays dominant unless strictly exceeded by another element

### Neutral State

When all four elements are at 0 pressure, the baseline neutral rules apply. Because non-dominant pressure never decays, neutral is "sticky" only in the sense that the simulation stays in baseline rules until some element banks enough new border activations to take the lead — but once any element has banked pressure, returning to a true all-zero neutral is rare (it requires the dominant to decay to 0 while no rival holds banked pressure).

### Supreme Dominance

When the dominant element has more total activations than the other three combined, it is "supremely dominant." Supreme dominance is detected per generation and emitted from the circuit as a flag (one boolean per generation).

Supreme dominance affects external formula parsing (see Spell Crafting) — each generation of supreme dominance counts as an additional trajectory entry for that element.

> **`[RESOLVED — difficulty gradient reversed]` Repeats are now the *easiest* formulas, opposites the hardest.** The intended difficulty order is: **same-element (e.g. fire-fire-fire) easiest → element + neighbor → element + opposite hardest.** This reversal (from the old "repeats are the prestige formulas" framing) **dissolves the supreme-dominance exploit** the v2.1 review worried about: a sustained supreme blob produces lots of same-element entries, but those now *should* be easy, so supreme dominance handing you cheap repeats is no longer an inversion — it's the system working as intended. No cap or log-scale on supreme bonus is needed for that reason. *(Test early anyway that the easiest path isn't so easy it's the only path.)*
>
> **`[TODO — playtest, named goal]` Effect-table power audit follows from the reversal.** The 16-effect table was filled under the *old* philosophy. Under the new gradient, **power should rise with difficulty: opposite-pair effects (the hardest to assemble) should be the strongest, same-pair the most modest.** Right now the table doesn't reflect that. Adopt a deliberate power audit against the `same < neighbor < opposite` gradient as a named playtest objective when filling/tuning the table, rather than leaving power level uncorrelated with achievability.

### Generation-Based Decay Philosophy

The decay rate (`floor(generation_count / 2)`) grows over time, making sustained dominance progressively harder. Early generations have light decay; late generations heavy. Combined with sticky-upward non-dominant pressure (see Pressure model above), this creates naturally short rule periods, increasing chaos in long simulations (rules flicker as the heavily-decaying leader is overtaken by rivals' banked pressure), and a late-game tendency toward **flickering dominance** rather than settling into neutral. Net pacing: short simulations are controllable, long ones are dramatic and volatile.

- **`[DECISION — needs playtesting]`** Decay rate is the primary lever for tuning how hard each class of spell effect is to craft.
---

## Spell Crafting

The system by which dominance trajectories produce spell effects. **All spell crafting logic is external to the ZK circuit** — the circuit emits the trajectory and external code parses it.

### Trajectory

The circuit emits one entry per generation indicating the dominant element (or neutral state), plus the supreme-dominance flag per generation. External code processes this trajectory into formulas.

**Trajectory entry counting:**
- Each new dominance event (transition from one element/neutral to a *different* element) counts as one entry for that element
- Each generation of supreme dominance counts as one *additional* entry for the dominant element (subject to the supreme-dominance decision above)
- Neutral periods are gaps, not entries — they separate dominance events but don't contribute to formulas
- Same-element repetition without a different element between events requires a neutral gap

### Formula Structure

Every formula consists of exactly three elemental entries from the trajectory:
- **First entry:** the formula's **affinity** (element flavor)
- **Second + third entries together:** map to one of 16 base **effect types**

This produces 4 affinities × 16 effects = 64 distinct spell outcomes.

### Multi-Formula Spells

If a trajectory contains more than three entries, sequential triplets each form their own formula:
- `[fire, earth, water, air, fire, earth]` → two formulas: fire-earth-water and air-fire-earth
- `[fire, earth, water, air, fire]` → one formula (fire-earth-water) plus two residuals (air, fire)
- `[fire, earth]` → zero formulas (need three entries), two residuals

A spell can contain multiple formulas, each contributing its own effect.

### Residuals

Trajectory entries that don't complete a formula become residuals. Residuals provide minor stat buffs that stack on a log-3 growth scale (effects added to pool at counts 1, 3, 9, …):
- **Fire residuals:** +1 damage on next damage spell
- **Water residuals:** 2× mana regeneration for a turn
- **Earth residuals:** +1 armor (temporary HP)
- **Air residuals:** +1 range and movement speed for a turn

### Spell Affinity

A spell's overall affinity for chain casting and wild magic purposes:
- **Single-formula spell:** affinity = that formula's affinity
- **Multi-formula spell:** hybrid affinity = all distinct first-elements of completed formulas

A spell with formulas fire-X-X and water-X-X has fire-water hybrid affinity. A spell with fire-X-X, fire-X-X, and earth-X-X has fire-earth hybrid affinity (fire counts once).

---

## Effect Naming Worksheet (fill in)

*(review §7: "for a game whose entire social meta is secrets … giving each of the 16 base effects an in-world name would do a lot of flavor work for free." Each effect currently has only a rules-document name. Fill the right column with diegetic names. Two suggested starting points are pre-filled as examples and can be overwritten.)*

| Second-Third Combo | Base Effect (mechanical) | In-World Name *(fill in)* |
|---|---|---|
| Fire-Fire | Damage |Blast|
| Earth-Earth | Barriers |Barrier|
| Water-Water | Illusions |Reflections|
| Air-Air | Speed Manipulation |Boost|
| Fire-Earth | Sprite Summoning |Spirit Solidified|
| Fire-Water | Chain Interaction | Blazing Flow |
| Fire-Air | Spell Interaction |Energy flows|
| Earth-Fire | Hound Summoning |Form Animated|
| Earth-Water | Tile Modification |Terrain Sculpting|
| Earth-Air | Range Modification |Gravity Modified|
| Water-Fire | Cloud Summoning |Essence Vaporization|
| Water-Earth | Accoutrements Interaction |Shape Artifact|
| Water-Air | Status Effect Interaction |Flows of Time|
| Air-Fire | Dispels |Flowing Disintergration|
| Air-Earth | Haymaker Interaction |Aura of Force|
| Air-Water | Divination |Scrying Pool|

> **Mirror-pair note (review §7).** The ordered-pair structure is a real systemic asset worth keeping conversant when naming: Fire-Earth **sprites** / Earth-Fire **hounds** (which element *leads* picks the creature); Water-Fire **clouds** / Fire-Water **chains** (steam → momentum). When you name and when you fill gaps, keep mirror pairs thematically in dialogue with each other.

---

## Effect Table (Needs Playtesting)

The 16 base effect types, mapped to second-third element combinations (first element = affinity flavor). Potency (bracketed) values apply under the Fire/Potency enhancement. *(Typos from v2.1 swept; flagged cells from review §4/§7 marked inline.)*

| Second-Third | Base Effect | Fire Flavor | Earth Flavor | Water Flavor | Air Flavor |
|---|---|---|---|---|---|
| Fire-Fire | Damage [+50% damage] | 4 damage | 2 damage; also damages walls or sprites it intersects en route to target | 2 splash damage (AoE radius 2) | 2 damage and 1 self movement |
| Earth-Earth | Barriers, 2[3] turns | 2 HP; adjacent tiles take 1 fire damage at end of turn | 4 HP | 2 HP + 10% mana regen while active | 2 HP; free move when it collapses |
| Water-Water | Illusions, 3[4] turns | Deal 1 damage to attacker if tile targeted | Lasts twice as long | Mirror player movement (opposite direction) | Movable Illusions may be repositioned each turn up to 2 tiles during move selection, will move one tile at random otherwise|
| Air-Air | Speed Manipulation | Move n extra tiles at cost of `n(n+1)/2` health [1 free tile] | Reduce target move speed by 1 for [4] turns | High Liquidity: move n extra tiles at cost of `n(n+1)/2 × 100` mana [1 free tile] | Increase target move speed by 1 for 2[3] turns |
| Fire-Earth | Sprite Summoning [sprites may take immediate turn] | High-damage sprite | High-HP sprite | Splash-damage sprite | Knockback sprite |
| Fire-Water | Chain Interaction | Chain bonuses accumulate twice as fast next 2[3] turns | Chain bonuses grow at half speed next 3[4] turns | You gain all chain status of affected target; overwrites your existing chains [+1 turn to them] | All chain bonuses removed [all chains set to −1: mana cost increased instead of decreased] |
| Fire-Air | Spell Interaction | Next spell's cost paid twice; mana shortfall converts to health damage at 1[2] HP per 10 mana| Always resolve last unless others are sluggish, 3[4] turns | Copy spell [may copy twice; second copy still costs its mana] | Always resolve first unless others are quick, 2[3] turns |
| Earth-Fire | Hound Summoning [hounds may take immediate turn] | Extra-damage hound | Extra-health hound | Splash-damage hound | Extra-fast hound |
| Earth-Water | Tile Modification [may place second effect in adjacent tile] | Floor is Lava (hurts to pass through) | Impassable terrain that also blocks spells from passing through | Costs 2 movement to enter and drains mana on entry |Conveyor tiles force-move whatever stands on them; direction chosen at effect resolution and permanent|
| Earth-Air | Range Modification | Penetrating: spells can't be blocked by walls; 1 damage to anything in hexes en route, 2[3] turns | Reduce spell range by 1 for 3[4] turns | Turbulent: next spell fires in intended direction but range randomized 1–max, 3[4] turns | Increase spell range by 1 for 2[3] turns |
| Water-Fire | Cloud Summoning, 3[4] turns | Toxic Smoke (1 damage/turn) | Dust Cloud: blind 1 turn even after leaving | Refreshing Cloud: +10% mana regen inside | Mobile Cloud: caster may re-center it each turn |
| Water-Earth | Accoutrements Interaction | Burn Random Player Accoutrements to deal 1[2] damage *(random target via joint entropy; can't hit core gem; burning a counter charm reveals its target)* | Summon 1[2] Absorption totem | Summon 1[2] mana gems | Summon 1[2] bookmarks |
| Water-Air | Status Effect Interaction | 1[2] damage per active status effect | All status effects dormant 2[3] turns | Status effects lose 1[2] turn | All status effects gain 1[2] turn |
| Air-Fire | Dispels | Minions (sprites & hounds) radius 2[3] | Illusions radius 3[4] | Terrain radius 2[3] | Clouds radius 3[4] |
| Air-Earth | Haymaker Interaction, 2[3] turns | Stacking fire DoT, damage = turns remaining, 2 turns at a time | Target move speed reduced by 1 | Target status effects lose a turn | Bonus damage equal to spaces moved toward target |
| Air-Water | Divination |See target's counter charm alignment, will turn bookmarks marking those spells red for rest of the match|Identify Illusions and See Through Clouds 1[2] turns| See Target's available spells 2[3] turns |See target's planned movement 2[3] turns|


**Design guidance for filling this out (unchanged from v2.1):** effects thematically consistent with elemental composition; power scales with formula achievability; flavor variations meaningfully different across affinities while remaining the same effect type; mix of defensive/utility, offensive, and manipulative effects; effects interact with battlefield, opponent state, and other spells. (Source-material tradition prizes seemingly minor effects used creatively, so don't over-prune "weak" entries.)

> **Duration principle — buffs shorter than debuffs.** When setting durations, **self-buffs should run shorter than effects you land on an opponent.** Reason: under tile-targeting + commit-before-move, you can reliably place an effect on the tile you yourself occupy (or will), but landing one on an opponent means *cornering or accurately predicting them onto a targeted tile* against their dodging — much harder. Equal durations would overvalue the easy self-target case; shorter self-buff windows keep "buff your own feet" from being strictly better than fighting to control where the enemy stands. Apply this as a tie-breaker when filling in the bracketed/duration numbers across the table.

---

## Summons — Sprites & Hounds

Two summonable creature families, distinguished by **which element leads the formula** (the ordered-pair rule the review §3/§7 flagged as a systemic asset to protect):

- **Sprites** — summoned by **Fire-Earth** formulas (fire leads). Suggested identity: *agile, ranged, fragile* — flying/hovering attackers that strike from a distance and ignore ground terrain.
- **Hounds** — summoned by **Earth-Fire** formulas (earth leads). Suggested identity: *melee, fast, sturdy* — ground pursuers that must close to attack but take a hit.

Both **may take an immediate turn the generation they are summoned if spell is made potent** (per the effect table). Both act on the Summons step of turn order (step 1), in creation order, moving then attacking the nearest enemy.

Summons always act with the following priorities.
1a. *Sprites* Try to be 4 tiles away from nearest enemy player, where they can hit but not be hit in return by wizards (unless they've enhanced their base range)
1b. *Hounds* Move on path most directly to nearest enemy player. They are not particularly intelligent and kiting them into damaging terrain or clouds is a common tactic to deal with them. The only terrain they acknowledge is the impassible earth walls which they will try to path around.
2. Attack, targeting the closest enemy player (or illusion, they are unable to discern the difference). If no enemy players are around, they will target the closest enemy minion. Targets that are both equally close and equal priority chosen at random.


### Base profiles (suggested)

| Creature | HP | Damage | Move | Attack Range | Special |
|---|---|---|---|---|---|
| **Sprite** (Fire-Earth) | 2 | 1 | 1 | 4 | ignores effects of terrain modifier; may act immediately on summon |
| **Hound** (Earth-Fire) | 4 | 2 | 2 | 1 (melee) | Must close to attack; may act immediately on summon |

### Flavor variants (suggested deltas from base — fill / tune)

Each summon's *fourth* element (the affinity flavor of its formula) modifies the base profile:

| Affinity flavor | Sprite variant (Fire-Earth-**X**) | Hound variant (Earth-Fire-**X**) |
|---|---|---|
| **Fire** | High damage: Damage +2 (→4) | Extra damage: Damage +2 (→4) |
| **Earth** | High HP: HP +2 (→8) | Extra health: HP +4 (→12) |
| **Water** | Splash: attacks hit radius 1 | Splash: attacks hit radius 1 |
| **Air** | Knockback: hits push target back 1 hex | Extra fast: Move +2 (→5) |

> Open tuning questions to settle during playtest: do summons persist indefinitely or have a lifespan? Defaulting to persisting indefinitely for now.Can a player control more than one at once (and is there a cap)? Do they block movement / occupy tiles as obstacles? Does friendly fire from your own AoE hit your summons? Leaving these as `[TODO — playtest]` for now; flag any you want pinned down on paper instead.

---

## The Cryptographic System

### Zero-Knowledge Proof

At inscription time, the player generates a ZK proof attesting to:

> "I know a `grid_state` such that:
> 1. `Poseidon2(grid_state) == commitment`
> 2. Running `grid_state` through the CA for `T` generations produces the declared border activations, dominance trajectory, and supreme-dominance flags."

The proof is stored in the spellbook alongside the spell.

### Commitment Scheme `[APPLIED — confirm]`

```
commitment = Poseidon2(grid_state)        // grid only; T is a separate public input
```

The grid pattern itself is the source of variance. **T is bound by the proof as a public input but is deliberately kept *out* of the commitment hash.**

> **Why grid-only, not `grid || T` (review §5, resolved by your prior decision).** You stated your current position directly: *counter charms should fire against anything with the same initial grid-state hash, regardless of step count, loan status, or custody chain.* That requires T **outside** the hash — one commitment covers all step-count variants, so:
> - a counter charm kills a rune at *every* T;
> - the bestiary can cryptographically group "sub-versions encountered at different step counts," exactly as that section claims;
> - re-inscribing the same grid yields the same commitment, so counter-spells continue to apply.
> This resolves the v2.1 inconsistency (the doc previously said both `Poseidon2(grid)` and `Poseidon2(grid || T)` in different paragraphs). If you ever want step-count-specific counters, that's the `grid || T` world instead — but it contradicts your stated intent, so I've committed to grid-only.

### Owner Binding (anti-theft) `[APPLIED — confirm, with one deviation from the review]`

> **Problem (review §5):** a ZK proof, once transmitted for verification (every cast), is a self-contained object valid no matter who presents it. As specified in v2.1 nothing binds a proof to its creator, so a modified client could **replay** another player's proof and cast their exact spell — voiding the bestiary's "cannot recreate" promise outright. This is the most important technical finding in the review.

**The fix, adapted to keep your grid-only counter-charm semantics:**
- The proof takes an **`owner_pubkey`** as a public input and attests that the inscriber declared it. *(It is **not** folded into the commitment.)*
- At cast time, the caster must **sign a per-match challenge** with the private key matching the proof's `owner_pubkey`. A replayed proof carries the original owner's pubkey, and the thief cannot produce that signature, so the replay is useless.
- A thief can't swap in their *own* pubkey either, because that requires regenerating the proof — which requires knowing the grid.

> **`[APPLIED — v2.3 review §1]` Representation: carry `Poseidon2(pubkey)`, not the raw key, and keep all signatures off-circuit.** An Ed25519 public key is 256 bits, which **exceeds the BN254 scalar field** — `owner_pubkey: Field` won't hold it as written. Bind **`Poseidon2(pubkey)` as the single field-sized public input** and have the verifying client hash the presented key to check (simpler than two field limbs). Standardize on **Ed25519 for every off-circuit signature** — match challenges, loans, scrolls, match records — so the circuit never does in-circuit signature verification (boring, well-supported Dart crypto). One Phase-0-style smoketest worth doing: confirm the toolchain genuinely binds an *unconstrained* public input into verification (it should in Noir/UltraHonk; a one-line dummy constraint referencing `owner_pubkey` is free insurance).

> **`[RESOLVED]` Deviation from the review, ratified.** The review proposed folding the owner into the commitment itself (`commitment = Poseidon2(grid || owner_pubkey)`). That is **not** done here, because it would make the *same grid inscribed by two different people* produce *different commitments* — contradicting your rule. **Confirmed by you:** a counter charm counters any spell with the same initial starting grid, *regardless of any other factor* (owner, T, loan status, custody chain). So `owner_pubkey` stays a **separate public input** (anti-replay only) and the commitment stays grid-only (owner-independent counter targeting). Both properties hold at once.

This owner-binding layer is also what makes the **Master/Apprentice loans, spell scrolls, and inheritance** below possible — delegation is "the owner signs authorization for another key to cast this commitment."

### Battle integrity (review §1) `[APPLIED — confirm]`

The inscription proof guarantees a spell's outputs came from *some* valid grid evolution. It guarantees nothing about HP, mana, movement, accoutrement state, or turn resolution — all client-enforced, and the client is GPL. Two cheap additions close most of the gap and are table stakes for serverless P2P:
- **Lockstep state hashing:** run the battle as deterministic lockstep; both clients exchange and sign a state hash every turn. Any divergence is immediately detectable and attributable. *(This signed per-turn log is also the raw material for shareable battle transcripts — see §ELO and Runewright+.)*
- **Jointly generated randomness:** all in-battle randomness (summon-collision adjacent tile, turbulent range, bookmark retargeting) must come from commit-reveal entropy — each player commits to a nonce at turn start, reveals, XOR. Otherwise one client silently controls every die roll.

### Ruleset Versioning `[APPLIED — confirm]`

> **Problem (review §5):** your deploy-and-patch philosophy collides with ZK rigidity — any CA rule tweak, decay retune, or grid resize is a new circuit with a new verification key, and every existing spellbook proof verifies only against the old one. Without a plan, the first balance patch bricks every spellbook in the community.  The goal is to cease CA modification once playtesting is complete.  Asking players to reinscribe their entire library is potentially a very big ask.

- Embed a **ca_ruleset_version`** as a public input.
- The match handshake negotiates versions; clients carry verifiers for the last N versions.
- Frame in-fiction as **"arcana editions"** / revisions so versioning is flavorful rather than bureaucratic.

### Circuit-budget optimizations carried from review §5 `[APPLIED — confirm]`
- **Pack the grid before hashing.** The grid is 469 booleans but the commitment currently hashes 469 field elements (~157 Poseidon2 permutations). Since cells are already constrained to {0,1} for the CA, pack them into a small number of field elements via weighted bit sums (a couple of linear combinations, nearly free) and collapse the hash toward a single permutation. Document the packing order alongside `GRID_ORDERING.md`.
- **Never reimplement Poseidon2 in Dart.** The client reads the commitment from the prover's public inputs; it never computes the commitment itself. Treat commitments as opaque on the Dart side.
- **T-architecture: three discrete circuit tiers `[RESOLVED]` — `T_max ∈ {12, 24, 48}`.** Noir arrays (`[Field; T]` trajectory/flags) are compile-time sized, so T can't be a free runtime variable. Rather than one circuit (which would cap spectacle) or one-per-T (a verification-key zoo), ship **three** circuits sized to T_max = 12, 24, and 48. The match handshake negotiates `ruleset_version` **and** picks the **smallest tier that covers the spell's declared T**; within a tier the active `T` is a public input with no-op padding generations beyond it (T is public, so padding hides nothing). Rationale:
  - **12 (~236k gates, deep green):** the everyday tier — fastest inscription, where the vast majority of spells live.
  - **24 (~472k gates, top of green):** room for the discovery curve — early players and artisans landing tricky opposite-element formulas will run well past the theoretical minimum, and this tier keeps them comfortable.
  - **48 (~943k gates, yellow, 1–3 min inscription):** the **virtuoso spectacle tier** — opt-in, self-selected, deliberately weighty to inscribe. Permits the rare ~8–14-formula monster that becomes a story the table retells for a year. Occasional spectacle is a per-match memory worth the per-inscription cost, and it takes the sting out of losing; the cognitive-load argument is a per-*turn* concern that this doesn't contradict.
  - Three VKs per ruleset version, not one and not a zoo. Hardware improvement steadily pulls the 48-tier toward green over time without the ceiling ever moving.
  - **The 48-tier raises the *effect* ceiling, not just length:** ~44 usable generations → up to ~14 formulas in a perfect rapid-cycle (near-impossible to tune, which is the point). The mana curve (`1.25^(T−4)`, on cell count) remains the backstop: a long sim is either a cheap low-seed bloomer (the engineering flex) or an expensive saved-pool deathstar.
- **Supreme flags packing:** the per-generation supreme flags pack into one field as a bitmask if phone verifier cost ever matters.

### Public Inputs (Circuit Outputs)

- `commitment: Field` — Poseidon2 hash of (packed) grid state
- `T: Field` — generation count (active T; constrained `1 ≤ T ≤ tier_max`, where `tier_max ∈ {12,24,48}` is the circuit used)
- `owner_pubkey: Field` — `Poseidon2(inscriber's Ed25519 pubkey)` (anti-replay; not in commitment; hashed because the raw 256-bit key exceeds BN254)
- `ruleset_version: Field` — arcana edition
- `border_activations: [Field; 4]` — total activations per element (summed over the active T)
- `dominance_trajectory: [Field; tier_max]` — dominant element per generation (sized to the tier; padded beyond active T)
- `supreme_dominance_flags: [Field; tier_max]` — boolean per generation (sized to the tier; paddable to a bitmask)

### Private Inputs (Witness)

- `grid_state: [Field; 469]` — initial grid configuration (only inscribable region populated)

### Spell Effect Hash

After proof verification, both players compute deterministically:

```
seed = SHA256(commitment || border_activations || trajectory || community_seed)
```

This hash is scanned for wild-magic patterns (see Wild Magic).

### Community Seed Word

An optional word factored into the wild-magic hash, creating local magical traditions:
- Affects wild-magic effects only, not recipe effects
- Recipe effects remain universal across all communities (players travel without invalidating their spellbook for recipe purposes)
- Local communities develop unique wild-magic optimizations as "home-turf advantage"
- Default seed: `"universal"`; communities choose their own; tournaments announce a seed at event start for equal footing
- Case-insensitive, stripped of whitespace and punctuation before hashing

---

## Master / Apprentice System

*A relationship-with-stakes onboarding mechanic, built on owner-bound proofs (above). Knowledge flows in both directions regardless of who wins, which is a deliberate counterweight to the hoarding-stagnation failure mode of a secrecy economy.*

### Taking on an Apprentice — Loaned Spells
- A master may **lend spells** to an apprentice by signing a **delegation certificate** that lets the apprentice's signature validate the spell, for a master-set period.
- **Loaned spells preserve the master's commitment** `[APPLIED — confirm]`. The apprentice's signature merely *authorizes use*; the spell is still mechanically the master's. Consequence (intended and flavorful): anyone holding a counter charm against the master's spell can snuff it in the apprentice's hands. This is consistent with grid-only commitments and your "same grid hash regardless of loan/custody" rule.
- Loans may be **extended any number of times** — an extension is just the master signing a fresh certificate.
- **Borrowed-but-not-inherited spells carry their own flag** `[APPLIED — confirm]`, distinct from owned and from inherited spells.

### Loan Expiry Without a Server `[APPLIED — confirm]`
- Delegation certificates carry an **expiry timestamp**; the **verifying opponent's client enforces it** against its own clock at match time. An apprentice can't fake-extend a loan because it's the other player's device doing the checking.
- **Clock-mismatch handling:** if the two clients' clocks disagree beyond tolerance, a **flag is thrown and the players are prompted to resolve it** in person (grossly skewed clocks are socially conspicuous in face-to-face play anyway).

### Ending an Apprenticeship
An apprenticeship ends in exactly one of three ways:
1. **Lapse.** The loans elapse (master stops renewing) and the apprentice is considered off studying on their own.
2. **Awarded graduation.** The master simply decides the apprentice is ready and graduates them, permanently bestowing the loaned spells — *including their full grid states* (an awarded graduation is a gift of the real runes, not just continued use).
3. **Graduation battle.** The master identifies a number of the apprentice's *discovered* spells they want, and the two duel:
   - **Master wins** → master permanently gains the selected apprentice spells, **including their grid states**, into their library.
   - **Apprentice wins** → the originally loaned spells are revealed to the apprentice (full grid states) and added to their library.
   - Either way, the apprenticeship ends.

### Graduation Battle Terms Are the Apprentice's to Set `[APPLIED — confirm]`
- The **apprentice chooses the graduation battle's terms** — wizard/sorcerer toggle set, grid size, whether loaned spells are permitted in the duel — **and the time of the duel**.
- The counterweight is that **loaned spells expire if the master stops renewing them**, so the apprentice can't stall indefinitely while leaning on borrowed power.
- Rationale (review): a veteran with a full library usually *should* win a graduation battle, so apprenticeship risks becoming a trap where the teacher farms the student's research. Letting the apprentice name the terms is a small, folklore-correct thumb on the scale ("the student names the terms of the trial") and rewards learning the modes the master is weakest in.

### The Concealment Sub-Game (emergent, worth protecting)
The master selects which apprentice spells to claim based only on **observed (bestiary-level)** knowledge from watching the apprentice duel. So the apprentice has motive to *conceal* their best discoveries from their teacher — but spells you never cast can't win you the graduation battle. The whole apprenticeship becomes a slow game of how much to show your master.

### Lineage & Heirlooms `[APPLIED — confirm]`
- Spells inherited through graduation carry **provenance / chain of custody** in the signatures themselves. A grid that has passed through three master-apprentice chains is a genuine **heirloom** with a traceable history.
- Combined with the bestiary and seed words, this yields the full apparatus of magical traditions: schools, inheritances, famous defections, "the student who beat the master and took the Ember Rune." This is the single most lore-efficient mechanic in the document — protect it.

### Reveal Enforcement — social first, escrow later `[APPLIED — confirm]`
- Nothing in the protocol can *cryptographically compel* a loser to hand over grid states (the grids live on their device). **Ship social enforcement:** in a small in-person community, welching on a graduation wager is reputation suicide, and the signed match record makes the obligation publicly attributable.
- **Keep verifiable escrow in the back pocket** (each party encrypts staked grids to the other before the battle, with a ZK proof the ciphertext really contains the staked commitment's preimage; winner decrypts, no cooperation needed). That's real circuit work — not v1. The possibility of a dramatic public welch may be worth more than the cryptography anyway.

---

## Spell Transfer (Deliberate Ownership Transfer)

*(review §8 — falls out nearly free from owner binding; the most pillar-aligned feature not previously in the doc.)* `[APPLIED — confirm]`
### Scrolls
Once proofs are owner-bound, **transfer becomes a designable act rather than theft**: an owner signs over a scroll that lets the recipient cast a specific spell without revealing the grid. This makes *Diplomacy*-style bargains **enforceable** — spells become tradeable goods, treaties gain teeth, betrayal gains texture. (The Master/Apprentice loan is essentially a time-boxed, renewable version of the same primitive.)

> **`[APPLIED — v2.3 review §1]` "One-time" must be bound to a named opponent (or match), not left bare.** There is no global state in this architecture, so a scroll spent against opponent A can be **replayed against opponent B** — only A and the issuer know it was used. Cryptographic single-use would need an online issuer or a ledger, both off the table by design. The fix that stays inside the architecture: the issuer signs `(commitment, recipient, opponent)` — *"a scroll prepared for the duel against Veyra."* It's flavorful (the scroll is keyed to a specific rival), reuses the loan-certificate verification path wholesale, and the opponent's client refuses a scroll not naming them. (Alternative: a tight expiry like loan certificates — hours, not weeks. Named-opponent binding is preferred.)

### True Spell Trading
Rather than meticulously coaching someone to recreate a grid, a wizard may **grant full use of a spell** to another — handing over the actual initial grid state. This transfer carries a **provenance chain** recording the original creator and the trail of ownership. Note the deliberate asymmetry: there is **no primitive for granting *permanent re-castable* ownership of a merely *loaned* spell** — that's intentionally withheld, because a freely reproducible spell, once given away for a favor, could be passed by that recipient to a dozen others before the creator captures any further trade value. Likewise, **simultaneous escrowed trades are intentionally not enforced**: two wizards can *agree* to swap spell for spell, but nothing in the protocol guarantees both sides deliver — the only thing binding the bargain is the social cost of treachery (which, in a small in-person community, is considerable).
---

## Starter Runes (Onboarding as Folklore)

*(review §8; pairs with the Master/Apprentice system as your two onboarding pillars.)* `[APPLIED — confirm]`

Ship three or four **public starter runes** — grid states printed in the app itself — whose commitments every client knows. In-fiction: *"every apprentice learns Magelight."* They:
- solve the cold-start problem (a new player can duel immediately);
- teach CA intuition by being inspectable;
- are, because universally known, **universally counterable** — creating organic pressure to graduate to secret spells of your own.

Onboarding, tutorialization through Master/Apprentice relationship, and the secrecy incentive in one mechanic, with wikis and centralized knowledge stores discouraged by game culture.

---

## Loadout System

### Spellbook
Players may put any number of successfully inscribed spells into a spellbook for a battle. All spells must have a unique initial grid state. Spellbooks are flavored as morphic, chaotic, semi-sapient objects: spells can't be stored on every page (their magical energies interfere), so buffering glyph-pages are needed. Any spell not currently opened under the wizard's watchful gaze tends to migrate and hide among the buffer pages.

> **Praise (review §3).** This semi-sapient-spellbook fiction is "a small masterpiece of mechanical flavoring": it turns a dry card-game constraint (limited hand size) into taming a willful object. Protect it.

Each chosen spell may be enhanced one of four ways, each tied to an element:
- **Water — Efficiency:** mana cost reduced by a third.
- **Fire — Potency:** spell effects use their bracketed values.
- **Air — Velocity:** spell range increased by 2.
- **Earth — Mystery:** spell may be precommitted to fire on a chosen tile after a 1–3 turn delay; the spell, location, and delay are all secret until it resolves.

Players may attach a spell name and image shown when the spell is used in battle.

> **`[APPLIED — confirm]` Mystery and counter charms need commit-reveal *with salt* (review §4).** A precommitted Mystery spell (secret spell + tile + delay) and a counter charm (secret until triggered) both require the holder to commit at battle start and reveal on trigger — otherwise a player can reactively claim they'd "totally countered" the spell you just cast. **These one-shot battle commitments DO need salt**, unlike the spell commitment: the no-salt rationale (stable commitments for counter-targeting) doesn't apply here, and an unsalted commitment over a small space (spell × ~61 tiles × 3 delays) is trivially brute-forceable mid-match.

### Accoutrements

Select 12 accoutrements across 4 element-typed kinds:
- **Water — Mana Gems:** first selected is the indestructible **core gem**. Each gem provides 10 mana/turn and +100 max mana pool.
- **Fire — Counter Charms:** name a known spell (by its Poseidon hash = its initial grid state). If that spell is cast during the battle it fizzles — action wasted, mana returned. The countered spell isn't publicly revealed until it activates.
  - **`[RESOLVED]` Targeting rule:** a counter charm fires against **any spell sharing the same initial grid-state hash**, regardless of owner, T, loan status, or custody chain. Requires commit-reveal with salt (above).
  - a counter charm keyed to the original commitment also fizzles a *copied* cast of it.
- **Air — Bookmarks:** each bookmark tracks a spell within the spellbook no matter how it hides; once used it auto-finds a new random spell to track. Players toggle between bookmarked spells for casting (effectively hand size).
- **Earth — Absorption Rod:** if an enemy-controlled spell would inflict a status effect, each absorption rod nullifies one turn of that status effect.

> **`[RESOLVED — v2.3 review §1 + your ruling]` No dedicated accoutrement-defense, by choice; Burn-accoutrements interactions specified.** The rod's redefinition (from "neutralizes spells that interact with accoutrements" to "nullifies one turn of a status effect") removed the only answer to accoutrement attacks — at the same revision that added Water-Earth's **Burn Random Player Accoutrements**. **This is intentional:** a single attack vector on accoutrements isn't worth dedicating a quarter of all accoutrement slots to defending them, and the burn is fine *unguarded* because its random targeting (EV ≈ 1/12 against any specific accoutrement) makes it **diffuse attrition that punishes hoarding twelve eggs in one basket**, not a "deny my opponent all mana" denial strategy. Its real role is letting a drawn-out game eventually grind through a killer counter charm. Required interaction spec:
> - **Cannot hit the core gem** (indestructible by definition).
> - **Burning a counter charm reveals what spell it was countering** — a great consolation prize and information leak.
> - **Burn target is drawn from joint commit-reveal entropy** — otherwise the victim's client quietly picks its own least-valuable accoutrement.
> - **`[DECISION — needs Soren]` "Absorption totem"** (named in the Water-Earth/Earth effect cell) is currently undefined — either define it (a deployable that absorbs the next accoutrement-targeting effect?) or rename the cell to summon an Absorption Rod.

### Spell Mana Cost

> **`[RESOLVED]` Free threshold, then exponential at base 1.25.**
> ```
> mana_cost = ceil( starting_active_cells × 1.25^( max(0, T − 4) ) )
> ```
> - **4 free turns:** the exponent is 0 for `T ≤ 4`. Four generations is the fastest the border (ring 12) can first be reached from the inscribable edge (ring 8), crossing the un-inscribable buffer rings 9–11 one per generation — so no formula can form before T=4, and no spell is penalized for the minimum viable run-up. *(Golden test vectors should still confirm the exact dominance-onset generation in `stepper.dart`; T−4 is the design intent.)*
> - **base 1.25 (intentionally steep):** the curve is *meant* to make big multi-effect spells a periodic payoff, not a per-turn option. A full mana loadout caps at **1,200 pool / 120 per turn**.
>
> Reference cost for a 10-cell rune (vs. that 1,200 / 120 loadout):
>
> | T | mana cost | ≈ full-regen turns | ≈ % of max pool |
> |---|---|---|---|
> | 4 | 10 | 0.1 | 1% |
> | 5 | 13 | 0.1 | 1% |
> | 7 | 20 | 0.2 | 2% |
> | 10 | 39 | 0.3 | 3% |
> | 15 | 117 | 1.0 | 10% |
> | 20 | 356 | 3.0 | 30% |
>
> So a T=20, multi-formula spell runs ~30% of a maxed pool — castable, but only after **mana ramping or efficient chain-discount building**, and not every turn. That is the design goal. (A community wanting a gentler local variant can drop the base toward 1.15–1.20, but **1.25 is canonical.**) `[TODO — playtest]` confirm it feels like "ramp toward a big spell," not "locked out of long sims."

> **`[RESOLVED — v2.3 discussion]` Why exponential, and what the chain actually buys.** The exponential is *not* just a cost — it's a **cognitive-load throttle on effect count**. A turn where ten formula-effects resolve in CA order, interacting with status effects, terrain, summons, and wild magic, is homework for *both* players, every turn, across a café table; a linear cost would make those multi-formula monsters routine, and routine is exactly what they must not be. The chain discount then does something elegant: a maxed chain (~65% off at length 10) offsets roughly **4–5 generations** of exponential growth (`1.25^4.6 ≈ 2.9 ≈ 1/0.35`), so **chains are functionally the currency that purchases T**. A big spell isn't priced in mana, it's priced in *turns of disciplined same-affinity play beforehand* — a far more interesting cost than a number. (And one extra active cell multiplies the whole `1.25^T` term, so a counter-dodging burn cell costs dozens of mana on a long spell but pocket change on a short one — the exponential makes *famous long spells specifically* expensive to keep safe. Good.)

> **`[RESOLVED — editorial, v2.3 discussion + tier decision]` The headroom framing, corrected.** At base 1.25 the chain-subsidized ceiling sits around **T ≈ 15–16 *for spells with a meaningful starting cell count*** — beyond that, no discount stack keeps a many-celled rune affordable. **But mana keys off *starting* cells, so a small seed that blooms into grid-wide activity is barely taxed at all:** a 3-cell bloomer is ~106 raw mana at T=20 and still under ~1,000 raw at T=30, undiscounted. Those spells aren't mana-gated — they're gated purely by the **tier ceiling** (`T_max ∈ {12,24,48}`), which is exactly the clever-engineering payoff the design wants to reward: cleverness buys *cheap access to the effect ceiling*. So there are two regimes, both intended: high-cell spells are mana-gated (the saved-pool deathstar), low-seed bloomers are tier-gated (the engineering flex). The tier ceiling is therefore an **intentional complexity/spectacle horizon, not a circuit limitation** (gates scale linearly; you're green to ~T=24 and yellow to ~T=100). The 48-tier exists precisely so the rare virtuoso monster can be genuinely enormous.

> **Design-by-algebra knob:** the `1.25` base and the `0.9` chain decay are really *one* knob — the exchange rate between chain discipline and simulation length. Work backwards from the desired experience and solve for the constants before the first session; playtest then only confirms the window *feels* right.

> **`[RESOLVED — free threshold = T − 4]`** The exponent uses `max(0, T − 4)`: dominance can't begin until the border (ring 12) is first reached from the inscribable edge (ring 8), which takes 4 generations across buffer rings 9–11. The first four generations are therefore a free run-up, and the tax begins at T=5. *(Golden test vectors should confirm the exact dominance-onset generation against `stepper.dart` when they're written — but T−4 is the committed design value.)*

### Void Spell Mana Cost (independent formula) `[RESOLVED — values tunable]`

A **void spell** (a grid that completes **zero formulas**, and is therefore eligible for void wild magic) uses its own cost formula instead of the standard one:

```
void_cost = ceil( 10 × 1.25^( active_tiles − 1 ) )
```

| Active tiles | Void cost | ≈ % of max pool |
|---|---|---|
| 1 | 10 | 1% |
| 2 | 13 | 1% |
| 3 | 16 | 1% |
| 5 | 25 | 2% |
| 8 | 48 | 4% |
| 10 | 75 | 6% |
| 15 | 228 | 19% |
| 20 | 694 | 58% |

**`[CORRECTED — v2.3 review §1]` The cost curve alone does NOT gate grinders — the combinatorics defeat it.** The earlier rationale ("stronger triggers need more tiles, which the exponential taxes") has a broken middle step: searching more *candidates* doesn't require more *tiles*. The candidate count at `k` tiles is `C(217, k)` — 217 grids at 1 tile, ~23,000 at 2, ~1.68M at 3. A length-4 trigger pattern lands roughly once per thousand candidates, so a tool-assisted grinder finds strong triggers comfortably inside the 2–3-tile space, at **13–16 mana**. The exponential never engages for the grinder it was meant to tax, while it *does* tax the hand-crafter (who can't search at scale). The gate is backwards from its intent.

**`[FIX — applied]` Gate *power*, not eligibility: cap the wild-magic tier by active tile count (or void mana paid).** The void cost formula above stays (it still prices the artifact), but the **usable wild-magic bracket is capped by tile count**: the scaling tiers beyond the minimum 3-character sequence only unlock at progressively higher tile counts (exact thresholds `[TODO — playtest]`). So a cheap 3-tile void can *only ever* fire the weakest bracket no matter what pattern the grinder found, and "cost tracks power" becomes true **by construction** rather than by hoped-for rarity. (Equivalently: scale void-effect potency directly with void cost paid. Either makes the floor real.)

**Structural note:** with the tier cap in place, the two archetypes keep mirror cost drivers — the standard formula is linear in cells and exponential in **T** (you pay for *simulation time*); void is exponential in **cells** with a **tile-gated power ceiling** (you pay for *pattern search*, and cheap searches can't buy strong effects).

> **`[DECISION — optional / playtest]` Free-T grinding.** Because the void hash shifts with T (via border activations + trajectory) but this formula doesn't tax T, T is in principle a free grinding knob. It's largely self-closing — meaningful T-driven hash variation requires border/dominance activity, and enough of that *forms a formula*, disqualifying void status. **Default: tile-only (ship it).** Back-pocket fix if void-T-fishing shows up in playtest: layer the standard `× 1.25^max(0, T−4)` term on top. Tunable knobs to watch: the **floor (10)**, the **per-tile rate (1.25)**, and the **tile→tier thresholds**.

---

## Wild Magic System

A parallel-to-recipes effect system based on hash-pattern scanning.

> **Design intent — wild magic is global and double-edged.** Unlike recipe effects (which place onto a single committed tile), wild-magic effects are designed to **mostly affect all players, minions, and the whole field at once, wherever they are** — they ignore the tile-targeting rule entirely. They are a *double-edged sword*: the same "all mana bars fill" or "everyone teleports" hits you and your opponent alike. The skill of a wild-magic build is not aiming it but being **positioned and prepared to benefit from the symmetric effect more than your opponent does** (e.g. triggering a board-wide teleport when you're the one who wanted to escape a corner). Build *around* the double edge; don't expect to point it.

### Eligibility
Determined by the spell's overall dominant element (cumulative across all formulas):
- Single-affinity spells: scan the hash for that element's patterns
- Perfectly balanced spells (multiple elements equally dominant): eligible for *all* balanced elements' patterns simultaneously — the "wild magic specialist" archetype
- **Void eligibility `[RESOLVED]`:** a spell inscribed with no formulas (no elemental affinity) is eligible for **void** effects. The review §4 exploit (zero-formula grids are the cheapest to produce) is **not** closed by the cost curve alone — the combinatorics let a grinder find strong triggers at 2–3 tiles / 13–16 mana (see Void Spell Mana Cost). It is closed instead by **capping the usable wild-magic tier by active tile count**: a cheap low-tile void can only fire the weakest bracket regardless of the pattern found, so power tracks tiles-paid by construction.

### Trigger Patterns
Scan the spell-hash hex string for two pattern types per element:
- **Repeating numerals** (111, 222, AAAA): assigned per element, no overlap
- **Ascending runs** (3456, F012, BCDE): F wraps to 0; first numeral must be the element's designated trigger

### Wild Magic Effects (intentionally short while core effects are playtested)
Sequences continuing past the minimum 3 scale per the brackets.

| Triggering Sequence | Void Effect | Fire Flavor | Earth Flavor | Water Flavor | Air Flavor |
|---|---|---|---|---|---|
| 000 | All adjacent non-player cell effects instantly vanish [+1 radius] | All spell effects next turn deal +1 fire damage [+1 per effect] | All adjacent cells become earth walls 2 turns [+1 turn] | All mana bars immediately fill | All players and minions teleported to random locations |

> **`[TODO — playtest]` Wild-magic table is a stub** by design. When expanding, remember (review §6) that wild magic is *locally* optimal via seed words — a spell tuned for one community's seed is mistuned for another's, which is what makes traveling wizards mechanically real. Protect that property.
>
> **`[RESOLVED — Chaos column deleted]`** Chaos was a 13-state cell type the 2-state pivot removed, and nothing routed to it (eligibility goes only to the four element affinities or to void). Deleted rather than given a contrived trigger: a balanced spell already fires **up to four element wild-magic effects at once**, which is reward enough for perfect balance — no separate Chaos domain needed.
- Operate independently from recipe effects (both can fire from the same spell)
- Scale with the length/intensity of the triggering pattern
- Influenced by the community seed word
- Should feel emergent and surprising rather than carefully designed

The wild-magic specialist build (perfectly balanced elements, maximum trigger eligibility) requires high CA mastery and offers an alternate archetype alongside elemental specialists and the versatility spectrum.

---

## Chain Discount System

Each pure element tracks an independent chain counter. Casting sequential spells of the same affinity accumulates a mana discount.

### Chain Advancement `[RESOLVED — action breaks, inaction regresses]`
- **Pure-affinity spell aligned with active chain:** chain advances by 1, discount applies fully.
- **Hybrid-affinity spell partially aligned:** chain advances by the alignment fraction (fractional credits accumulate toward the next integer).
- **Casting a spell with *zero* overlap with the active chain → the chain *breaks* entirely (resets to 0).** A hard cost, deliberately: a high-utility off-alignment spell should hurt your chain to cast.
- **Taking *no* chain action that turn (no spell, or a Haymaker) → the chain *regresses by 2*** (a gentler decay for inaction, not a full reset).

> **`[RESOLVED — v2.3 review §10]` The overlap is fixed:** the v2.3 doc had a non-aligned *cast* triggering both "break" and "regress by 2." The rule is now **action breaks, inaction regresses** — casting something off-alignment is an active choice with a hard consequence (full reset); merely failing to advance (idle turn / haymaker) only nudges it down by 2. Distinct events, distinct penalties.


### Discount Formula
```
discount = (0.9 ^ chain_length) × (fraction of spell's formulas aligned with active chain element)
```
Examples (chain length 5): pure fire on fire chain `0.9^5 × 1.0 = 59%`; fire-fire-water (2/3) `≈ 39%`; fire-water-air (1/3) `≈ 19%`.

| Chain length | Pure discount | 50%-aligned hybrid |
|---|---|---|
| 1 | 10% | 5% |
| 3 | 27% | 14% |
| 5 | 41% | 20% |
| 10 | 65% | 33% |

This rewards specialization while still letting hybrid mages benefit partially.

---

## Haymakers
Players may throw an awkward, inefficient punch at an adjacent hex for 1 damage at no mana cost. Spell effects (Air-Earth row) can empower a haymaker with bonuses.

- **`[RESOLVED]` Action cost:** a haymaker **consumes the cast-a-spell action** for the turn (it is declared in step 3 in place of a spell).
- **`[RESOLVED]` Resolution timing:** haymakers resolve in **step 5, before any spell resolves**. The adjacent target hex is taken relative to the puncher's position *after* movement resolves.
- **`[RESOLVED]` Simultaneous haymakers:** the player with **fewer total remaining status-effect turns** (summed across all their active status effects) resolves first; if still tied, a pseudorandom coin flip via commit-reveal entropy.

---

## Core Combat Constants

> **`[RESOLVED — HP 24, swept]` Core constants.**
> - **Player HP: 24** (default; players may adjust before a match if both agree). Mnemonic: 6 hexes × 4 elements. *(This supersedes the stray "32" that lingered in two cross-references from an earlier draft — 24 is canonical.)*
> - **Base spell range: 3 hexes.** On the default radius-4 battlefield (max separation 8 hexes), range 3 sits well below the diameter, so corner-to-corner sniping is impossible — you must close distance or invest in Air/Velocity (+2) or Earth-Air range modifiers. Range becomes relatively shorter on larger custom boards (more kiting), which is a fine knob for groups to feel.
> - **Fire-Air mana→HP conversion: 1 HP per 10 mana** unpaid (default, `[TODO — playtest]`; interacts with HP scale, so revisit if HP moves). At 24 HP, a ~100-mana shortfall converts to ~10 HP — a serious ~40% of health, not an instakill; if that feels too swingy at 24 HP, soften the rate to 1 HP per 15 mana.

---

## Battlefield

> **Core combat loop — tiles, not targets.** Spells are placed on **hexes, never on players** (wild magic is the deliberate exception). This makes the central skill *positional and psychological* rather than mechanical aim: you win by **cornering the opponent onto the tile you've committed to** — herding them with your own movement, terrain modifiers, and summons — while **reading or manipulating where they'll move and bluffing your own path**. Especially early game (before big spells come online), expect duels to be won and lost in this movement mind-game more than in raw spell power. Everything in the effect table that modifies movement, terrain, summons, or range is, at bottom, a tool for controlling *where bodies can stand.*

### Grid
- Hexagonal battlefield, vertex-down orientation
- Default radius 4 (61 tiles), adjustable by player preference
- Consistent visual language with the rune grid

### Movement
- Players move up to 2 spaces per turn
- Both players' locations are visible to each other
- Air-affinity spells can grant faster movement (speed stat)

> **`[RESOLVED]` Targeting vs. movement order.** You **commit your target hex before movement resolves**; the spell then resolves at that committed hex *after* movement. Both clauses from v2.1 are therefore true (declare first, resolve after). See the range note below — committing blind to movement is what makes range 3 a reading-the-opponent game rather than a reaction.

### Movement Collision
- Higher-speed player claims a contested tile; the other remains on their previous position along their path
- Equal speed: both bounce back to previous positions

### Terrain
Optional future feature: maps with tile-modifying terrain present from the start.

### Targeting
- **You target tiles, never players** (the sole exception is wild magic — see below). A spell places its effect on a hex; whether it *hits* the opponent depends entirely on whether they're standing on (or within the AoE of) that hex when it resolves.
- Target hex is committed before movement resolves; the spell then resolves at that hex after movement
- Range is measured from the caster's **post-movement** position to the committed target hex — i.e. range governs how far from *yourself* you can place an effect, not how far away an enemy you can "lock onto"
- Friendly fire possible with AoE (you can catch yourself and your own summons)

> **Why range 3 with tile-targeting (revisits the base-3 decision).** Since you place effects on tiles and commit before movement resolves, landing a hit is a *cornering and prediction* problem, not an aiming one: you target the tile you expect the opponent to be forced onto, using your own movement, terrain modifiers, and summons to shrink their escape options — while they try to read and dodge you, and you bluff your own movement to bait them. Range 3 is deliberately short enough that this positional pressure matters (you can't blanket the board from a corner) while Air/Velocity (+2) and Earth-Air range effects buy real reach when you've earned it. Base **3 stays.**
>
> **`[DECISION — needs Soren]` sub-question this exposes:** if your committed target tile ends up **out of range** because movement displaced *you* (e.g. a collision bounce), does the spell (a) fizzle (action + mana lost), (b) fire at max range along the caster→tile line, or (c) whiff? I lean (b). *(Note: the opponent moving never affects range — range is caster→tile only — so this is purely about your own displacement.)*

> **`[DECISION — needs Soren]` Illusions vs. visible-positions baseline (review §4).** Illusions that fake player position conflict with "both players' locations are visible." Reconcile: do illusions create *decoy* tokens (positions still truthful) or actually spoof the position readout? Pick one. *(With tile-targeting, decoys that bait a misplaced target tile are especially on-theme for the cornering game.)*

---

## Turn Order

1. **Summons turn:** summons automatically (occasionally manually) move, then attack the nearest enemy target, resolving in creation order.
2. Players choose their movement path.
3. Players **commit** their cast action — either a target hex for a spell, or a haymaker. **The target hex is committed before movement resolves** (step 4): you cannot watch movement land and then retarget. This makes casting a *prediction* of where bodies will be, not a reaction to where they are.
4. Movement resolves.
5. **Haymakers resolve** (before any spell). If both players haymaker the same beat, the player with **fewer total remaining status-effect turns** resolves first; if still tied, a pseudorandom coin flip via commit-reveal entropy.
6. **Spells resolve.** Between players, the spell with the **smaller step count (T)** resolves first; ties broken by **whichever initial grid hash is the smaller number**. *(The Fire-Air "always resolve first/last unless…" family overrides this default.)* Within a single player's spell: **wild magic first, then formula effects in the order the CA created them.** If multiple objects would be summoned to the same tile (e.g. two hounds), one is bumped to a random adjacent tile (commit-reveal entropy).
7. Status effects tick down.

> **`[RESOLVED]` Inter-player ordering:** lower-T spell first, tiebreak smaller grid hash, then — if two+ players cast the *exact same spell* (identical T **and** identical grid hash) — a **dice roll** drawn from joint commit-reveal entropy. **Haymakers** consume the cast-a-spell action and resolve before spells, with the status-turns / coin-flip tiebreak above.
>
> **`[RESOLVED]` Targeting vs. movement:** target is *committed* in step 3, *resolves* in step 6, with movement (step 4) in between. This is the canonical reading of the v2.1 "declare before move / move resolves first" tension — both are true: you declare first, it takes effect after movement.

---

## Multi-Player (3+ Players)

> Initial pass. Wizard-mode mechanics scale cleanly; resolved parts are `[APPLIED — confirm]`, with win-condition / teams / N-way records flagged as future-session work. (Not required for first playtest.)

**Commit & turn flow.** All players lock in movement + cast **privately and simultaneously** via the N-way commit-reveal round (everyone commits a hashed move+target, then all reveal), so adding players causes negligible slowdown — there is no serial turn-taking. Movement collision generalizes: when 3+ players contest a tile, highest speed claims it and the rest hold their prior positions; speed ties among contesters bounce back.

**Spell resolution order.** Sort *all* players' spells by **lowest step count first, then smaller grid hash**, then — for players who cast the **exact same spell** (identical step count *and* grid hash) — a **dice roll** from joint commit-reveal entropy (no client controls it).

**Same-tile object resolution — one principle:** *later-resolving (higher-step) spells act on the board state earlier ones leave.*
- **Summons / objects that can't coexist** (minion on minion): the earlier (lower-step) summon claims the tile; the later one is pushed to the nearest tile free of a conflicting object, cascading outward if needed. Both minions involved take a little **collision damage** (`[TODO — playtest]` amount) — so summoning onto an enemy minion's tile is a deliberate chip-at-a-cost play.
- **Tile-state modifiers** (clouds, terrain): the later-resolving modifier **overrides** the earlier one on that tile (last write wins).

**Strategic upshot — speed asymmetry as lenticular design (`[RESOLVED]`).** The two rules pull opposite ways, deliberately: cast **faster (lower step)** to claim a contested tile with a summon; cast **slower (higher step)** to win a terrain/cloud overwrite and have the last word on shared tiles. This hands expensive high-step spells a real compensating upside against their mana cost — but it's **lenticular by design** (Rosewater's term): most players just pick the spell whose *effect* they want and reason no further than "if my damage lands first, good" — since neither player knows their opponent's step count in advance, "optimizing" resolution order isn't even legible as a lever at that level, and the surface rule ("faster spells resolve first") is complete and satisfying on its own. The summon-vs-terrain asymmetry is a *second layer underneath* that surface reading — a discovery for high-skill players who've logged enough hours to start choosing a spell's step count *for* its resolution-order consequences, not despite them. Nobody is locked out of the simple read, and nobody is forced into the deep one. Protect this property when tuning: don't surface it via UI hinting, and don't let the asymmetry grow loud enough to feel mandatory.

**Still open (future N-player session):**
- **Win / elimination condition** — last wizard standing? eliminated at 0 HP while others continue? match ends at one survivor? Undefined.
- **Free-for-all vs. teams** — changes AoE/friendly-fire meaning (FFA: multi-hit is just value; teams: friendly fire on allies matters).
- **ELO + match records** — generalize 1-v-1 expected-vs-actual ELO to placement-based; **the signed record must allow N signers — do not hardcode two** (same trap as ruleset versioning).
- Counter charms and the bestiary already scale untouched (hash-based, caster-independent).

---

## Battle Modes

Four togglable options moving casting between traditional-fantasy ritual and tactical board game. Choosing the "Sorcerer" side trades strategic deliberation for speed and physical acuity; each toggles independently.

| Option | Wizard | Sorcerer |
|---|---|---|
| Game Speed | Turn-based | Free real-time movement/casting; status effects, minions, and mana regen tick every 15s `[TODO — playtest]` |
| Verbal Components | Waived (auto-cast) | Latin element names spoken and picked up by the mic; mana discount/penalty scales with **accuracy and volume**. **Doubles as the opponent's telegraph; clarity/loudness trade efficiency against secrecy. Volume peaks on the final formula as the phone pulls away for gestures — see Casting Stillness.** |
| Somatic Components | Waived (target by choosing a hex) | Two accelerometer gestures (distance + direction), performed **simultaneously with the final formula's vocalization**; optional haptic feedback. **Requires standing still — see Casting Stillness below.** |
| Movement | Select tiles on the battle grid | Physical movement via **step-count + compass-bearing** (leaning; see note); separated in time from casting |

> **Casting Stillness (`[APPLIED — confirm]`) — a constraint turned into a mechanic.** A pedometer and a somatic-gesture recognizer both read the accelerometer, so walking while gesturing would corrupt both. Rather than engineer around this, **casting requires the player to stand still** (the two somatic gestures are performed stationary). This:
> - **resolves the conflict for free** by temporally separating movement from casting (you never walk and gesture at once), which is what makes **step-count + compass-bearing movement viable** (the earlier hesitation);
> - leans into the strong trope of the **wizard rooted and relatively defenseless mid-incantation** — committing to a cast is a real positional exposure, which feeds directly into the tile-targeting cornering/prediction pillar (a stationary caster is a predictable presence during the channel);
> - **shrinks the play footprint**: with ~1 step ≈ 1 tile, a radius-4 arena fits in a few metres (unlike GPS, which needs a large field to beat 3–5 m error), keeping players in close radio range — which in turn means the cross-platform transport floor likely suffices and the field-roaming pressure on networking mostly evaporates (see Pluggable transport layer).
>
> Scope: this lives in sorcerer mode (somatic on / real-time). Wizard-mode hex-tap stays instant; "stand still" includes "sit still," so the seated-accessibility alternative is unaffected.
>
> **Self-interruption by movement (`[APPLIED — confirm]`) — the dive-dodge.** Moving mid-cast should *break your own cast*, so a player can abort by physically diving out of the way of an incoming spell. This is technically the **robust** half of the sensor problem, not the fragile half: abort needs only the coarse binary "did your body start to move?" (a footfall / net displacement), never a precise step count. A dive is the easiest possible signal to detect; precise counting stays confined to free movement, where a miss is low-stakes.
> - **Key on displacement/footfall, not acceleration magnitude.** A somatic gesture is a bounded oscillation with ~zero net translation; a step/dive takes you somewhere and lands a footfall. Keying on "you physically went somewhere" means vigorous gestures never false-abort. Tune to require a *definite* step/dive (committing to the dodge), since false aborts mid-gesture would feel awful.
> - **Always signal state:** haptic buzz + visual flip (channeling → cast broken → moving) the instant an abort fires, so the player never wonders whether their movement registered (kills the "game silently didn't update me" confusion).
> - **Stageable:** ship the soft-lock baseline first (movement input simply suspended during the channel), then add abort-on-locomotion as a pure additive upgrade.
> - **The telegraph is diegetic — the opponent's own incantation and gestures, not a UI marker.** In sorcerer mode the verbal components *are* the telegraph: a skilled listener decodes the spoken element names into the coming effect (first element = affinity; by the third spoken element the first formula's effect is known), and reads the somatic gestures for roughly *where* it's aimed. Information arrives in a curve — *what* well before *where* — so the victim often knows "something big is coming" while the target tile is still ambiguous, and the dive is a gamble under rising pressure. This folds combat counterplay into the same read-your-opponent ethos as the out-of-game espionage layer.
>   - **Clarity-vs-stealth tension (emergent, free):** the "mana discount scales with pronunciation **accuracy and volume**" mechanic now also trades against secrecy — clear, loud incantation telegraphs more. Counterplay becomes a physical information-hiding contest (whisper into a cupped phone, turn a shoulder, shield gestures with the body) — the shoulder-surfing meta moved into combat.
>   - **Somatic is any gestures the caster wishes to use on the final formula — the crescendo (`[APPLIED — confirm]`):** On the final formual two somatic gestures (distance + direction) are performed **simultaneously with vocalizing the last formula**. The spell discount/penalty is processed as an average of accelerometer movement intensity, loudness of voice, and accuracy of magic words. This (a) closes the whisper exploit — the phone is pulled away from the mouth at the exact moment *where* is revealed, so keeping the volume bonus forces you to **project**; (b) makes power and exposure peak on the *same beat* — your loudest, most-committed instant is also the targeting reveal, giving the victim an unmistakable audio + gesture cue for the dive; and (c) rewards the genuine spellcaster trope of the rising, forceful final word. Good theatre and good incentive design at once.
>   - **Self-balancing:** long multi-formula spells take longer to vocalize, so the scariest spells are the *most* readable/counterable. **Wild magic is not telegraphed** (hash-derived, fires separately from the spoken formula), so wild-magic-leaning builds are inherently less readable — another clean archetype distinction.
>   - **Tuning knob:** the reaction window = (final gesture/targeting reveal → spell landing). A small **resolution wind-up** after the incantation completes keeps that window from collapsing to zero. `[TODO — playtest]` feel number, not a paper one.
>
> **`[DECISION — deferred]` Hit-interruption** (taking damage mid-channel fizzles the cast) is a *separate* mechanism from movement self-interruption above, and is **held off for now** — ship without it; add only if duels lack punish windows. (Movement self-interruption is wanted and in; damage interruption is the deferred one.)

> **`[DECISION — needs Soren]` / accessibility (review §4, §8).**
> - **step-count + compass-bearing is now the lean** (Casting Stillness removes the pedometer/gesture conflict that was the main objection, and it keeps the footprint small). Confirm before building.  Need to reconcile or create alternatives for forced movement effects in Sorceror mode real time actual movement.
> - **Accessibility passes:** verbal components need a path for players who can't speak or be heard (noisy venues are your *home* venue) — and since the bonus now scales with **volume**, the accessible alternative must waive the loudness requirement gracefully (accuracy-only, or a non-vocal input) rather than penalizing players who can't project. Somatic gestures need calibration + a seated alternative. These double as graceful degradation when a phone's mic/accelerometer is poor.

---

## ELO & Match Records

### No Central Authority (By Design)
The lack of a global leaderboard is a feature — it creates regional metas, traveling-wizard dynamics, and community lore.

> **The psychological draw, not just the structural one.** A global ladder *manufactures* the ceiling it lets a handful stand atop — it's a constant, unambiguous reminder that you're rank #4,182. Removing the central authority removes the *disproof*: the undefeated champion of their venue gets to believe, with nothing able to contradict them, that they might be one of the best anywhere. This unbundles two motivations a ladder normally fuses — *objective proof of rank* and *the feeling of being among the best* — and serves them differently. The data-driven, external-validation competitor who needs the number is genuinely underserved (a narrow, conscious cost). But the larger population who wants the *feeling* is served **better** than a ladder would: an unauditable throne is more sustainable than a true rank that almost always says "no, you're not." It's also generative — no central authority means no visibly "solved" format, so the innovator always has live territory and the local hero becomes a *character* in other people's stories (the white-whale legend, the rumored unbeaten challenger two towns over) rather than a line on a list. And because rating is portable signed receipts, a traveling competitor can carry their record into a bigger pond and *test* the fantasy on their own terms — seek out the rumored best, stake a duel, win and absorb the legend — without the disproof ever being forced on them. Decentralization isn't only "regional metas and lore"; it's what makes the local-legend fantasy possible at all.

### Signed Match Records
After verified matches, both players cryptographically sign the outcome. Rating is accumulated, tamper-evident receipts. Rating changes computed and signed jointly at match end.

> **`[APPLIED — ships in v1]` The match-record format must reserve three fields NOW, even though Talewright is post-ship (Fable, Talewright discussion).** The *substrate* can't wait the way the rest of Talewright can — three cheap struct fields today versus migrating every signed record in existence later (same trap as ruleset versioning). Reserve:
> - **N signers, not two** — already flagged for multiplayer; the record must allow an arbitrary signer set, never hardcode a pair.
> - **Embedded match config** — custom HP, loadouts, grid size, toggle set. "I slew the dragon" must verifiably disclose whether the dragon had 200 HP or 5; for dramatic battles the config *is* the setup, so this is flavor, not bureaucracy.
> - **Optional stakes-hash** — a slot for a pre-committed, both-signed statement of what the outcome means (see Talewright → Stakes pre-commitment). Empty for ordinary duels; populated for canon-deciding ones.
>
> Everything else about Talewright can wait; these fields can't.

> **`[APPLIED — confirm]` Signed transcripts as lore artifacts (review §8).** You already need the lockstep per-turn log for anti-cheat; extend the signing to the *full deterministic replay*. Shareable, verifiable battle replays become the community's storytelling medium — and the natural raw material for Runewright+ later.

### Local Community Ledgers (Optional)
Trusted community members can run lightweight nodes recording signed outcomes; communities maintain their own records naturally.

### Adapted ELO Formula
```
novelty_stack = Σ e^(activated_elements / mana_cost) for each novel spell encountered this match
K = base_K × (floor_bonus + novelty_stack)
rating_change = K × (actual_score − expected_score)
```
- **activated_elements:** number of elements activated by the CA (components used for formulas or residuals; novel spells only)
- **novel spell:** commitment hash not previously in this player's bestiary
- **floor_bonus:** small constant so zero-novelty matches still contribute
- Ratings tracked separately across all 16 wizard/sorcerer toggle combinations

---

## Spellbook Bestiary

After every duel, opponents' spells used against you are added to your bestiary:
- Spell initial grid hash (unique fingerprint)
- Sub-versions encountered at different step counts *(groupable under one commitment thanks to grid-only hashing)*
- Effects triggered at each encountered step count
- Wild-magic effects
- Name/image first encountered (overwritable)
- Opponent identity (or "Unknown Wizard")
- **Not included:** any grid-state or replication info

Bestiary entries become **"white whales"** — spells you know exist and can counter, but cannot recreate without independent research.

> **Praise (review §6).** The white-whale loop creates genuine multi-month research arcs and, with seed words, is one of the two systems most capable of sustaining a small community for years. Protect it.

---

## Implementation Status

### Completed
- Flutter/Dart project initialized
- Hex grid data model (axial coordinates)
- CA simulation engine: 2-state with rule modifications
- Dominance tracking: pressure with `floor(N/2)` decay, no neutral reset *(see the pressure/decay decision — current impl may need to change)*
- Visual test UI
- Phase 0: trivial Poseidon and stub CA circuits verified
- Phase 1: 13-state CA measured, simplification rationale established
- Phase 1.5: 2-state CA with rule modifications measured
  - `ca_natural_v2`: 522k gates at T=20 (yellow)
  - `ca_lookup_v2`: 409k gates at T=20 (green), 3.1s desktop proving
  - Perfect linear scaling (R²=1.000) at 19,650 gates/step
  - 20× per-cell improvement over Phase 1 natural circuit
  - Lookup table: 70 entries
  - **`[RESOLVED]` Measured on the 469-cell grid → green band confirmed for the current design; reserved headroom intact.**

### Not Yet Implemented
- Supreme-dominance flag emission from circuit (decided; pending)
- Owner-binding (`owner_pubkey = Poseidon2(key)` public input + cast-time Ed25519 challenge signature) — *new this revision*
- `ruleset_version` public input + version negotiation — *new this revision*
- Grid packing before hashing — *new this revision*
- Lockstep state-hash exchange + commit-reveal battle entropy — *new this revision*
- Master/Apprentice loans, scrolls, graduation, lineage — *new this revision*
- Mobile FFI integration (Phase 2)
- Battlefield system
- Spellbook UI (incl. live dominance coloring)
- Networking (pluggable transport; local play)
- Verbal / somatic measurement systems
- Match record signing + transcript signing

---

## Open Decisions (consolidated — remaining items flagged `[DECISION — needs Soren]`)

**Resolved so far:** grid size (469, green) · pressure/decay (floored-at-0, dominant-only) · mana cost (free-4-then-`1.25^(T−4)`; exponential affirmed as effect-count throttle; chains buy T) · **T-architecture: three circuit tiers `T_max ∈ {12,24,48}`, handshake picks smallest covering the declared T (12/24 green everyday, 48 yellow spectacle tier)** · **void mana cost (`10×1.25^(tiles−1)`) PLUS a tile-gated power cap (the cost curve alone doesn't tax grinders)** · player HP (24) · base range (3) · Fire-Air conversion (1 HP / 10 mana) · owner-independent counter charms (same grid hash, any factor) · `owner_pubkey = Poseidon2(key)`, Ed25519 off-circuit · scrolls bound to a named opponent · difficulty gradient reversed (repeats easiest) · chain break-vs-regress (action breaks, inaction regresses) · burn-accoutrements ruling (diffuse 1/12 attrition; no dedicated defense) · inter-player resolution order (lower T first, tiebreak smaller hash) · targeting committed before movement · tile-targeting core loop · wild magic as global double-edged · haymaker action cost + resolution + tiebreak · buff-shorter-than-debuff duration principle.

Still open, priority-ordered:

1. **Divination family:** recipe-table (A) or wild-magic-only (B). *(Effect Table / Wild Magic.)*
2. **Effect-table power audit** *(named playtest goal, new this pass)* — re-tune so power rises with difficulty under the reversed gradient (opposite-pair strongest, same-pair most modest); the table was filled under the old philosophy. *(Supreme Dominance / Effect Table.)*
3. **"Absorption totem"** — define the summoned deployable, or rename the Water-Earth/Earth cell to summon an Absorption Rod. *(Accoutrements / Effect Table.)*
4. **Out-of-range committed target** (caster displaced off range): fizzle, fire-at-max-range-along-line, or whiff. *(Targeting — I lean fire-at-max-range.)*
5. **Effect-table specifics:** Earth-Water/Air conveyor direction rule; Fire-Water/Air "whose chains"; Copy-Spell vs. counter-charm ruling; Illusions vs. visible-positions reconciliation.
6. **Sorcerer movement mechanism:** GPS vs. step-count vs. compass-bearing — **leaning step-count + compass-bearing** (Casting Stillness resolves the pedometer/gesture conflict and keeps the footprint small). Confirm. *(Battle Modes.)*
7. **Summon details:** confirm sprite-vs-hound base identities and tune stat scaffold; decide persistence/lifespan, simultaneous-summon cap, tile-occupancy, and friendly-fire. *(Summons.)*
8. **Effect names:** fill the Effect Naming Worksheet (16 in-world names) — and re-sync it to the rearranged table. *(Effect Naming Worksheet.)*
9. **Transport adapters & selection:** how many of the three adapters to build now, and confirm auto-negotiate-with-manual-override. *(Pluggable transport layer.)*
10. *(Optional/playtest)* **Void free-T grinding** — fold a T term into void cost only if void-T-fishing appears; tune the **tile→tier thresholds** for the new void power cap. *(Void Spell Mana Cost.)*
11. **Multi-player (>2):** wizard-mode scaling resolved (simultaneous commit, resolution sort + same-spell dice roll, same-tile principle, lenticular speed asymmetry). Remaining future-session work: **win/elimination condition**, **free-for-all vs. teams**, **ELO + N-signer match-record format**. *(Multi-Player section.)*

> **Resolved this pass (was open):** chain reset-vs-regress (action breaks, inaction regresses) · supreme-dominance triviality (dissolved by the reversed difficulty gradient — repeats *should* be easy) · void wild-magic gate (tier cap by tiles, since the cost curve alone doesn't tax grinders) · scroll single-use (named-opponent binding) · `owner_pubkey` representation (`Poseidon2(key)`, Ed25519 off-circuit) · HP (24, swept) · burn-accoutrements (kept; diffuse 1/12 attrition; no dedicated defense) · **Chaos wild-magic column (deleted — four element effects at once is reward enough)** · **mana free-threshold (set to `T − 4`)**.

> **`[TODO — Phase 2 / protocol spec]` Carried-forward technical items:** (a) **golden test vectors** — a fixed `(grid, T) → (trajectory, activations, flags)` corpus the Dart stepper and Noir circuit must both pass; now *more* urgent, since the mana free-threshold constant and the trajectory format both depend on what the stepper actually does. (b) **Commit-reveal salt** for Mystery spells and counter charms is stated in-doc — make sure it survives into the protocol spec. (c) **Measure peak proving memory on a 4 GB device** (Pixel 6 timing ~24 s is known; memory headroom isn't). (d) **Sorcerer real-time mode has no discrete turns** — the lockstep state hash must run on the **15 s tick**, not per-turn; note this where lockstep is specced.

---

## Story-Sharing System ("Talewright" — name `[DECISION — needs Soren]`)

*Working name TBD (see naming note). A decentralized platform for telling stories set in worlds where Runewright's rules are how magic works — duels resolve dramatic clashes and cryptographically certify their outcomes. Scoped as a post-ship addon, but recorded here so nothing in the core is built against it.*

> **`[DECISION — needs Soren]` Name.** "Lorewright" and "Runewrite" are taken (and "Runewrite" fails verbally vs. "Runewright"); "Loreymode" reads as a nickname/typo and buries the strong word. Shortlist: **Talewright** (keeps the `-wright` craft suffix, sibling to Runewright — lead candidate), **Mythwright/Sagawright** (grander/serialized variants), or **Canonwright / Runewright Chronicles** (foregrounds the cryptographically-fixed canon; the Chronicles form sidesteps a standalone trademark search). Run the pick through tmsearch.uspto.gov + web search — "lore/rune + wright/write" is a well-fished pond.

### Core Concept — Decentralized, Treasure-Hunt Distribution
Stories are shared the same way spells are: peer-to-peer, no central repository. Readers trade ease-of-discovery for the **excitement of a treasure hunt** — finding the latest chapter is an event, and you find it *from another fan*, which seeds in-person conversation about the story along the way. The friction is the feature: discovery becomes social, and distribution becomes word-of-mouth, exactly as with the core game. Cryptographic + timestamp signatures let fans **sync to the latest authentic version** and protect against imitators.

### Three Storytelling Modes
1. **Author Mode.** One author writes and publishes a story, all at once or in chapters. The only mechanical layer is a **cryptographic + time signature** per release — proving authorship, ordering chapters, and letting fans verify they have the genuine latest version.
2. **Collaborator Mode.** Modeled on the old high-school-friends-roleplaying-in-a-chat-client experience. Carries Author Mode's authenticity + update features, and adds: collaborators may **start a battle** with characters of their choosing, **set the stakes**, and **cryptographically certify the outcome was what actually happened** — so canon-deciding clashes are tamper-evident, not just narrated. (This is where the duel engine and the signed-match-record system feed the story layer directly.)
3. **Gamemaster Mode.** A TTRPG played by text, turned into a serialized novel. The **GM narrates/storytells**; other players are characters. Like an actual-play podcast that both records the excitement *and* verifies the outcomes, this produces a cryptographically-verified serialized story. The GM **must be present at all encounters**, may **edit for clarity/concision** (e.g. trimming table talk), but **cannot override battle-outcome signatures** — the duels are the one thing even the narrator can't retcon.

### The Canon Must Be Hash-Chained (Fable, Talewright discussion) `[APPLIED — confirm]`

> **The omission hole.** The GM-can't-override-signatures boundary has a gap: the GM can't *override* a battle, but can *omit* one. Selective inclusion is retconning by editorial means — the signed duel where the GM's villain got embarrassed simply never appears in the published chapter. **Signatures prove that what's included is authentic; they don't prove the record is complete.**
>
> **Fix — hash-chain the canon (and get the data format for free).** Each chapter and each battle record embeds the **hash of the previous canon state**, so an omission leaves a *visible gap* and a player holding the orphaned signed record can prove the hole. This doubles as the story data format — **don't invent one**: a git-like chain of `(content_hash, prev_hash, timestamp, signatures)` *is* the format.
>
> **Stakes need pre-commitment.** *"If Kael wins, the bridge falls"* must be **signed by both parties before the duel** and its hash embedded in the battle record — same commit-reveal logic as Mystery spells — or you get post-hoc disputes about what the outcome *meant*. (This is the optional stakes-hash field reserved in Signed Match Records.)
>
> **Match config belongs in the signed record.** Custom HP and loadouts are a feature, but *"I slew the dragon"* must verifiably disclose whether the dragon had 200 HP or 5. For dramatic battles the config *is* the setup, so this is flavor, not bureaucracy. (Reserved field, above.)
>
> **Forks are mythology, not bugs.** When collaborators schism, the hash chain naturally supports **forks** — don't resist that. Name the losing branch **apocrypha** and a sync conflict becomes lore.

### Characters, Stats & Leveling
- Characters may be assigned specific **spells, accoutrement loadouts, and HP above or below standard** — so a story's protagonist can be deliberately over- or under-powered for narrative reasons. *(The config is captured in the signed battle record — see above.)*
- In **GM Mode**, the GM controls these stats for the players, allowing characters to **level up by whatever system the GM devises** (informal/houseruled for now).
- **Spell provenance in campaigns:** the GM may **loan spells from their own library** (usable *only* in their campaign's battles — a scoped delegation, mirroring the master/apprentice loan primitive) or **authorize players to use their own spells** in the campaign.
- A more **formal leveling system** may be explored if the mode proves popular — deferred until demand is shown.

### Design Notes
- **Built on existing primitives.** This addon mostly composes things the core already has: signed match records (battle certification), delegation certificates (GM spell loans / player authorization), commitment signatures (authorship + chapter ordering), and the peer-to-peer no-authority distribution model. The genuinely *new* work is the canonization/chaptering UI and wiring duel outcomes into the canon chain — **not** new cryptography, and **not** a bespoke data format (the hash chain is the format).
- **The GM-can-edit-but-not-override-signatures rule is the load-bearing trust boundary** — *now backed by the hash chain*, so "can't override" is reinforced by "can't silently omit." It's what lets a GM craft a readable narrative while keeping the clashes honest — the same "mathematically enforced where it must be, socially negotiated everywhere else" philosophy as the duels themselves.
- **Author Mode fights the treasure-hunt grain — don't lean on it (Fable).** Collaborator and GM modes fit friction-as-feature perfectly because the audience *is* the participants and their venue, so friction generates the social moment. A solo author's incentive is *reach*, which friction starves. Author Mode is nearly free to include and worth keeping, but **the strong core is the two modes where the readers were in the room.** Don't expect Author Mode to carry the system.
- **Friction-as-feature consistency.** Treasure-hunt discovery is the same design bet as in-person-only dueling and secret runes: the inconvenience generates the social connection and the mystique. Keep it; don't add a searchable central index "for convenience."
- **The substrate ships in v1, the rest is post-ship.** Talewright itself waits, but the three reserved match-record fields (N signers, embedded config, optional stakes-hash) ship with the core — see Signed Match Records.

---

## Design Philosophy Notes

- **Two complementary spell-crafting paths.** Recipe effects (deterministic, learnable, mastery-rewarding) coexist with wild magic (emergent, surprising, exploration-rewarding). The systems compose rather than compete.
- **Magic as natural force, not engineered system.** Rules-changing-mid-simulation, supreme dominance, residuals, and wild magic all support the metaphor that you're channeling something larger than yourself.
- **Difficulty matches intuition where possible.** Triple-element formulas should feel achievable in proportion to how achievable they sound — which is exactly why the supreme-dominance difficulty-inversion risk (above) matters.
- **Circuit budget as design lever.** Phase 1.5 (confirmed on the 469-cell grid) leaves real headroom, and the design *spends* it deliberately via three circuit tiers (`T_max ∈ {12, 24, 48}`): the everyday experience lives in green (12, 24), while the yellow 48-tier is an opt-in **spectacle horizon** for the occasional virtuoso monster. Note two regimes: high-cell spells are mana-gated (the economic ceiling sits ~T≈15–16 under chain subsidy), but low-seed bloomers are *tier*-gated, not mana-gated — which is the intended reward for elegant CA engineering. The long-tail depth comes from chain mastery, the spell-design space, and the rare big sim, not from making long sims routine.
- **In-person play as first-class concern.** Shoulder-surfing, physical gesture, vocalization, and venue play are not afterthoughts. The cryptographic design supports them; the UX should reinforce them.
- **The duel is a positioning mind-game, not a shooting gallery.** Because spells hit tiles rather than players, the core of combat is herding, prediction, manipulation, and bluff: cornering the opponent onto a committed tile using movement, terrain, and summons while they read and dodge you. This is the load-bearing skill, especially early game, and it rhymes with the out-of-game Diplomacy layer — both reward reading people and shaping their choices. Wild magic is the deliberate symmetric exception: a shared double edge you position to exploit rather than aim.
- **Hardware constraints become fiction, not friction.** Repeatedly, a device limitation is absorbed into the world rather than engineered around: the semi-sapient spellbook (limited hand size), the landscape border (scoring partition as a picture), and Casting Stillness (the pedometer/gesture clash becomes the rooted, vulnerable caster). When a sensor limit appears, the first question is whether the limitation *is* a mechanic before it's a problem.
- **Design for the bifurcated meta, not against it.** By-hand artisans and spell-foundry optimizers are both legitimate archetypes. The counter-charm monoculture pressure, seed-local wild magic, and a flatter mana curve collectively keep the foundry archetype from *dominating* without trying to prevent it. Make in-person discovery the higher-status path in the fiction and culture rather than writing unenforceable "don't post spell dumps" rules.

### Things to protect as development pressure mounts (review §8)
Named explicitly because they're the load-bearing originality, and each will at some point look cuttable for scope:
1. The bestiary white-whale loop
2. Community seed words
3. The semi-sapient spellbook fiction
4. The ordered-pair effect mirrors (sprites/hounds, clouds/chains)
5. Sorcerer mode's physicality — including the verbal/somatic telegraph and final-formula crescendo
6. The starter-rune + Master/Apprentice secrecy economy
7. **Lenticular layering** (Rosewater sense) — systems with a satisfying surface read and a separate deep read for high-skill players, e.g. resolution-order's summon/terrain asymmetry. Resist the urge to surface these via UI hints or tutorials; the second layer's value is in being *discovered*.

*The CA and the cryptography make the game possible; these seven make it yours.*

---

## Appendix: Player-Type Appeal (MTG Psychographics)

*A diagnostic of who this design is built for, using Rosewater's player profiles. Runewright has an unusually opinionated psychographic skew — and it lines up closely with the stated target audience (privacy-conscious, craft-appreciating, FOSS-aligned), which runs Johnny/Mel-heavy.*

**Johnny / Jenny — the home run.** The inscription loop is a pure creative canvas: you don't draft from a pool, you *design a cellular automaton* that births a spell nobody else has, in a 2²¹⁷ grid space, and keep it secret. "I built this myself and it's mine" is the Johnny fantasy crystallized; multi-formula chaining and wild-magic hash-divining feed combo-Johnny; the artisan-vs-foundry split explicitly blesses the elegant hand-crafted rune over the optimal one. *Protect:* keep expressive-but-suboptimal spells usable (the low-competitive-pressure, donation-ware ethos and the lenticular depth already do most of this work).

**Vorthos — excellent, almost effortless.** Flavor is load-bearing, not paint: elements that *are* their CA dynamics, the landscape border, the semi-sapient spellbook, incantations/gestures, community seed words as local traditions, master-apprentice lineages, heirloom provenance, white-whale legends, signed transcripts as lore. An embodied in-person ritual to inhabit, not just read.

**Mel — quietly the deepest fit, for a small population.** The design is built out of mechanical elegance: the CA→spell pipeline, ZK determinism, ordered-pair mirrors, the unified "later resolves on earlier's state" principle, and the self-balancing emergences (telegraph readability scaling with spell size, void cost auto-pricing grind-power, constraints-as-mechanics). Few Mels exist, but they become evangelists and overlap heavily with the FOSS/cryptography-curious crowd.

**Timmy / Tammy — strong in the duel, weak in the workshop.** Sorcerer mode is pure Timmy: the shouted crescendo, the somatic flourish, the dive-dodge, big multi-effect spells after a mana ramp, board-wide wild magic, summons on the table. But *inscription* is the opposite of what Timmy wants — cerebral homework. The saving grace: Timmy needn't inscribe at all. Starter runes enable day-one dueling; the bestiary, scrolls, and apprentice loans let them wield spells they didn't design. A happy "show up and brawl" participant borrowing the Johnnies' creativity.

**Spike — the genuine tension, and it's really *two* psychographics.** The tactical/innovator Spike is well-fed: dive-dodge timing, incantation-reading, the cornering mind-game, foundry trajectory optimization, counter-charm/bestiary metagaming, chain/loadout efficiency, lenticular resolution-order depth — and secrecy makes the format permanently unsolvable, which the innovator loves. The friction is only with the *ladder* Spike, and that splits in two:
- **Data-driven / external-validation Spike** (needs the objective global number): genuinely underserved by "no central authority" and "in-person only." A narrow, conscious cost of the vision.
- **Competitive-*feeling* Spike** (wants to *be* the best, or feel it): served **better** by decentralization — an unauditable local throne beats a true rank that says "no," and the local hero becomes a character in others' stories. Likely the larger group. (See ELO → No Central Authority for the full argument.)

**Synthesis.** Johnny/Vorthos/Mel core; social-Timmy and innovator-Spike well-served at the edges; only the data-validation Spike deliberately underserved. That profile is close to an exact match for the intended audience, so the skew is a feature, not a weakness. The load-bearing risk: the two on-ramps — **starter runes** and **master/apprentice** — carry enormous cross-psychographic weight (they're what let Timmy brawl without inscribing and what pull a new Johnny into the creative loop before its depth scares them off). They punch well above their size, which is one more reason they're on the protected list.
