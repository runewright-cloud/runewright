# Runewright — Game Design Document (v3.0)
*Briefing document for Claude Projects context*

---

## Vision & Design Philosophy

A mobile game simulating the experience of being a D&D-style wizard in real life. Core pillars:

- **Jealously guarded magical discoveries** — players are incentivized to protect their spell designs.
- **No central authority** — fully peer-to-peer, zero ongoing server overhead for the developer.
- **Cryptographic integrity** — cheating on spell output is mathematically implausible, not just socially discouraged.
- **Mystique as a structural feature** — the decentralized design creates speculation, rumor, and community lore organically.
- **Face-to-face experience** — duels happen in person between two or more phones via local wireless; the design is optimized for in-person play, including psychological games and misdirection in combat, and out of combat a level of tradecraft-esque tactics including shoulder-surfing and deceitful trade bargains (à la *Diplomacy*) as a real meta-game element for discovering magical secrets — balanced by an ethos of respecting people's personal privacy and comfort levels.
- **Free, ad-free, no microtransactions** — donation-only model, no data harvesting.
- **Word-of-mouth distribution** — designed to feel like a discovery shared between people with similar taste.
- **Story Telling Engine** -- Ability to set stakes for battles and crytographically confirm outcomes in a written record and embedded in written stories. Comparable to recording actual play podcasts / shows of TTRPGs.

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
- **Mobile FFI:** zkpassport/noir_rs beta.20 wrapped with Flutter Rust Bridge (FRB) v2.12.0, linked via Zig 0.14.x to resolve the libc++ ABI incompatibility between barretenberg's prebuilt static library and the Android NDK. The zkmopro fork was evaluated and rejected (crashes on-device for all circuits). The Zig/NDK link recipe is captured in scripts/build_android_ffi.sh. Status as of M3.4: on-device proving via the FRB path is not yet confirmed on ARM — the bare-metal ARM smoke test reproduced a proving failure distinct from the Kotlin/AAR path that proved successfully in M2; root cause under investigation before the full FRB/Flutter build proceeds.

### Pluggable transport layer [RESOLVED — built and gate-validated through M4]
The seam exists and works. lib/protocol/transport.dart defines the minimal Transport interface (advertise / discover / connect / send / onReceive / disconnect); all protocol logic talks to this interface only. MatchSession and BattleSession are transport-agnostic: they were tested first over InMemoryTransport (two wired-together in-memory channels, no sockets, no second device) and then over real TCP sockets without any protocol-layer changes — abstraction-integrity confirmed structurally by running the identical test suite against both transport backends.

What was built (M4):

InMemoryTransport — loopback pair for protocol tests. No radio, no second process. The bulk of protocol correctness work was done here before any real wireless was involved.
LanSocketTransport (dart:io TCP) — the cross-platform wired adapter. bind()+LanListener.acceptOnce() on the listener side (split so the caller learns the port before a peer connects), connectTo(host, port) on the dialing side. TCP stream framing is handled once in wire.dart's FrameReader; the socket adapter is a thin pass-through.
lan_discovery.dart — mDNS/NSD discovery via package:nsd, which wraps the native NSD/Bonjour stack (Android NsdManager, iOS Bonjour). Advertises as _runewright._tcp; resolves peer services with autoResolve: true. Deliberately not wired into Transport.advertise()/discover()/connect(): nsd's actual API shape — Registration handles, live Discovery streams of found/lost peers — doesn't fit those thin method signatures without losing information. Instead it's a separate layer that produces a connected LanSocketTransport, consistent with how InMemoryTransport.pair() and LanSocketTransport.bind()+connectTo() already work.
Wi-Fi Direct address filtering was a real M4.6 hardware finding: Android exposes multiple network interfaces alongside the real Wi-Fi one, including a Wi-Fi Direct group interface reliably in 192.168.49.0/24. Naively dialing the first resolved mDNS address risks dialing the unreachable p2p interface. selectBestAddressFrom filters by (1) shared /24 subnet with this device's real Wi-Fi addresses, (2) exclude the known Wi-Fi Direct subnet, (3) first address as a last resort. Separately unit-tested against representative real-device interface lists.

Gate result (M4.6): full two-device run accepted — Pixel 6 (prover/signer) + Pixel 9 (verifier/challenger), same Wi-Fi AP, manual IP entry. Every step confirmed: handshake → proof generated (~5.7 s, consistent with M3 figures) → proof sent (17 028 B) → proof verified → owner pubkey matched → challenge issued → signature verified → final=accepted, both directions.

Nearby Connections and Wi-Fi Direct: not built. LAN sockets covered everything M4 needed. The cross-play rationale from the design doc was confirmed in practice — both devices share the same TCP floor; no Google Play Services dependency.

Still open: mDNS auto-discovery connecting two real devices over real Wi-Fi. lan_discovery.dart's logic is unit-tested but has not been confirmed end-to-end on hardware — nsd has no Linux desktop backend, so it cannot be exercised from the dev machine. The M4.6 gate used manual IP entry. Confirming that selectBestAddressFrom correctly prefers the real Wi-Fi address during live mDNS discovery is a two-device follow-up.

iOS cross-play door is still open: LAN sockets + mDNS (Bonjour) interoperate with iOS; Wi-Fi Direct and Nearby Connections do not. The transport choice made here keeps a future iOS adapter behind the same seam. nsd's package:nsd already has an iOS backend; the wire layer (dart:io TCP) is identical on both platforms.

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

 **`[RESOLVED — superseded by Neutral Ink Ruleset measurements]`** The Phase 1.5 proxy figures (409k gates / 19,650 gates/step / ~3.1s desktop) were the basis of the original green-band estimate. The actual **RULESET_VERSION 2 (ink substrate)** circuits, measured 2026-06-23/24 on a Pixel 6 (`bb gates` + median of 3 warm runs each):
>
> | Tier | ACIR opcodes | Padded bucket    | Warm prove (Pixel 6) | Full inscription | Peak RSS  |
> |------|-------------|------------------|----------------------|------------------|-----------|
> | 12   | 388,374     | 2^19 (524,288)   | ~12.7 s              | ~15.8 s          | ~1 GB est |
> | 24   | 807,831     | 2^20 (1,048,576) | ~24.5 s              | ~31.5 s          | ~2.1 GB   |
> | 48   | 1,646,745   | 2^21 (2,097,152) | ~48.9 s              | ~62 s            | ~4.3 GB   |
>
> Each tier fits its dyadic bucket with comfortable headroom (~136k / ~241k / ~450k gates free). Scaling is approximately linear in `tier_max`. Tier-48 peak RSS ~4.3 GB requires a ≥6 GB device; tier-48 is gated to high-RAM hardware at the handshake. See `CIRCUIT_IO.md §7` for the full measurement notes.
### Cell States

Two states only: **inactive** (0) and **active** (1). All spell inscribing gameplay variation comes from the rule modification system, not from cell-type variety.

> **Presentation note (review §3) — single most important post-pivot UX decision.** Elemental identity used to live in the cells (13-state CA) and now lives entirely in the dominance system. If the inscription view does not make dominance periods *viscerally* legible — background washes shifting color per dominant element, the rule change **felt** rather than read from a counter — the simulation will look like monochrome Conway and the elemental flavor will exist only in the player's head. Treat live dominance coloring as a first-class requirement of the inscription UI, not polish.

### Border Zone Partitioning

The border ring is partitioned into four elemental zones in a vaguely landscape arrangement, with opposing elements on opposing sides:

- **Mountain (Earth)** — Bottom Left 18 cells
- **Sun (Fire)** — Top Left 18 cells
- **Sky (Air)** — Top right 18 cells
- **Sea (Water)** — bottom 18 cells

Total: 72 cells. Art outside the grid visually supports the landscape metaphor — mountain silhouette on left, sun at top, sky on right, sea below.

- **Corner cell assignment `[APPLIED — confirm]`:** corner cells assigned symmetrically across rotations.

---

## Cellular Automaton Rules

### Baseline Rules (Ink Rules State)

Three active rules designed to capture the effect of magical ink flowing on paper, with an occasional impulse to create serif effects (all on by default):

Rule A — Gap-fill / merge
An inactive cell with ≥1 complete axis (both antipodal neighbors active) becomes active. Fills gaps between two converging strokes that face each other across a single empty cell.

Rule B — Tip extension
An active cell with exactly one active neighbor activates that neighbor's antipode — growing the line straight outward. Only fires at genuine tips (degree-1 cells), never along a stroke body.

Rule E — Periodic serif flare (cadence 4)
On "pulse" generations (generation % cadence == 0), an inactive cell with exactly one active neighbor becomes active. This hits every cell touching a stroke tip (the straight continuation that Rule B already handles, plus the two forward diagonals). Cells along a body (≥2 active neighbors) are never touched. Gives tips a periodic forward flare on the beat.

Rule C (collision burst) was removed; Rule E replaced it with a cheaper distance-1 pulse.


This is the rule set in effect before any element is currently sitting at torrential flow status.

### Element-Specific Rule Sets

When an element holds the dominant flow (see the Dominant Flow System below), its rules replace the baseline:

- **Fire:** Born on exactly 1 neighbor. Survives on exactly 1 neighbor. *(unpredictable wild flitting)*
- **Earth:** Born on exactly 2; survives on any. *(slow inexorable growth)*
- **Water:** Dies ; survives on 3+. *(Floods create Rivers)*
- **Air:** Born on 2; dies with 2+ active neighbors. *(sparse, scattered persistence)*

The v2.4 lookup table contains 56 entries (4 elemental rule states × 2 cell states × 7 neighbor counts), confirming the elemental rule variants compile efficiently; the neutral branch is now handled separately by the ink rules (Rules A/B/E) and is no longer table-based.

> **Praise worth protecting (review §3).** These four rule sets are the document's standout strength: the dynamics *visually are* the elements (flickering tendrils, inexorable accretion, coalescing blobs, scattered wisps), which matters enormously in a game where players stare at simulations for hours. Do not let later tuning sand these into generic variants.

### Border Cell Behavior

Border cells (ring 12) follow special rules:
- Activations are counted for the dominance system
- Border cells immediately deactivate the following generation
- Border cells do not participate as neighbors in subsequent CA rules
- Border collateral damage (adjacent cells deactivating) was considered but **removed** to keep triple-element formulas from being harder than player intuition expects

---

## Dominant Flow System

The mechanic by which the player's CA pattern shifts the active rule set during simulation.

> - Pressure can never drop below 0
> - Each generation, **every** element gains +1 pressure for each border cell activated in its zone (regardless of who is dominant — this is how a challenger overtakes the leader).
> - Each generation element/s in the lead loses energy to mana siphoning by `floor(generation_count / 2)`, floored at 0. Tied leads divide the siphoning between them.
> - Elemental pools not in the lead never decay — they only rise via border activations.
> - If an element has more pressure in it's pool than all the other elements put together, it is considered to have torrential dominance. This causes the magical ink to become infused with that element, altering it's appearance and behavior.

> **One deliberate consequence (write it into the design, don't fight it):** banked pressure is **sticky upward**. An element that brushes its border zone early keeps that pressure indefinitely until *it* becomes dominant and starts decaying. So long simulations tend to **flicker between elements late-game** — the heavily-decaying leader gets overtaken by whichever rival banked the most, which then decays and is itself overtaken — rather than settling into true neutral. True neutral (all four at 0) is only reachable when nothing has banked pressure or the dominant has decayed to 0 while the rest are also at 0. This is coherent and dramatic, but it revises the old "late-game tendency toward neutral" framing to "late-game tendency toward **flickering dominance / chaos**" (updated in the Decay Philosophy and Design Philosophy sections).

### Pressure Tracking

Each of the four elements maintains a pressure counter (integer, minimum 0):
- Each generation, each element gains +1 pressure for each border cell activated in its zone
- Each generation, only the leading element/s decays, by `floor(generation_count / 2)`, floored at 0
- The element with the highest pressure has "dominant flow" and is added to the spell formula on the cadence step (every 4th step.)
- **Sticky ties:** the current leader stays dominant unless strictly exceeded by another element

### Neutral State

When all four elements are at 0 pressure, the baseline neutral ink rules apply. Because non-dominant pressure never decays, neutral is "sticky" only in the sense that the simulation stays in baseline rules until some element banks enough new border activations to create torrential dominance

### Torrential Dominance

When the dominant element has more total pressure than the other three combined, it is "supremely dominant." Supreme dominance is detected per generation and emitted from the circuit as a flag (one boolean per generation).

Torrential dominance affects external formula parsing (see Spell Crafting) — each generation of supreme dominance counts as an additional trajectory entry for that element.

The intended difficulty order is: **same-element (e.g. fire-fire-fire) easiest → element + neighbor → element + opposite hardest.**
>
> **`[TODO — playtest, named goal]` Effect-table power audit follows from the reversal.** The 16-effect table was filled under the *old* philosophy. Under the new gradient, **power should rise with difficulty: opposite-pair effects (the hardest to assemble) should be the strongest, same-pair the most modest.** Right now the table doesn't reflect that. Adopt a deliberate power audit against the `same < neighbor < opposite` gradient as a named playtest objective when filling/tuning the table, rather than leaving power level uncorrelated with achievability.

### Generation-Based Decay Philosophy

The decay rate (`floor(generation_count / 2)`) grows over time, making sustained dominance progressively harder. Early generations have light decay; late generations heavy. Combined with sticky-upward non-dominant pressure (see Pressure model above), this creates naturally short rule periods, increasing chaos in long simulations (rules flicker as the heavily-decaying leader is overtaken by rivals' banked pressure), and a late-game tendency toward **flickering dominance** rather than settling into neutral. Net pacing: short simulations are controllable, long ones are dramatic and volatile.

- **`[DECISION — needs playtesting]`** Decay rate is the primary lever for tuning how hard each class of spell effect is to craft.
---

## Spell Crafting

The system by which dominance trajectories produce spell effects. **All spell crafting logic is external to the ZK circuit** — the circuit emits the trajectory and external code parses it.

### Trajectory

The circuit emits one entry per generation indicating the dominant element (or neutral state), plus the torrential-dominance flag per generation. External code processes this trajectory into formulas.

**Trajectory entry counting:**
- When an element first becomes dominant
- When dominance switches to another element
- Every 4 turn on the cadence step if an dominant element remains dominant
- Each turn of torrential dominance counts as one *additional* entry for the dominant element
- Neutral periods are gaps, not entries — they separate dominance events but don't contribute to formulas

### Formula Structure

Every formula consists of exactly three elemental entries from the trajectory:
- **First entry:** the formula's **affinity** (element flavor)
- **Second + third entries together:** map to one of 16 base **effect types**

This produces 4 affinities × 16 effects = 64 distinct spell outcomes.

### Multi-Formula Spells

If a trajectory contains more than three entries, sequential triplets each form their own formula:
- `[fire, earth, water, air, fire, earth]` → two formulas: fire-earth-water and air-fire-earth
A spell can contain multiple formulas, each contributing its own effect.


### Spell Affinity

A spell's overall affinity for chain casting and wild magic purposes:
- **Single-formula spell:** affinity = that formula's affinity
- **Multi-formula spell:** hybrid affinity = all distinct first-elements of completed formulas

A spell with formulas fire-X-X and water-X-X has fire-water hybrid affinity. A spell with fire-X-X, fire-X-X, and earth-X-X has fire-earth hybrid affinity (fire counts once).

---

## Incantation Effect Naming Worksheet

*(review §7: "for a game whose entire social meta is secrets … giving each of the 16 base effects an in-world name would do a lot of flavor work for free." Each effect currently has only a rules-document name. Fill the right column with diegetic names. Two suggested starting points are pre-filled as examples and can be overwritten.)*
 
| Second-Third Combo | Base Effect (mechanical) | In-World Name *(fill in)* |
|---|---|---|
| Fire-Fire | Damage |Blast|
| Earth-Earth | Barriers |Barrier|
| Water-Water | Links |Reflections|
| Air-Air | Speed Manipulation |Boost|
| Fire-Earth | Status Effect Interaction |Controlled Consumption|
| Fire-Water | Chain Interaction |Flow |
| Fire-Air | Spell Interaction |Energy flows|
| Earth-Fire |Fuel Transmutation |Fuel Consumption|
| Earth-Water | Tile Modification |Terrain Sculpting|
| Earth-Air | Range Modification |Inertia|
| Water-Fire |Clouds| Cloud|
| Water-Earth | Artifacts Interaction |Shape Artifact|
| Water-Air | Illusions | Illusions|
| Air-Fire | Effect doubling |Bellows|
| Air-Earth | Melee Enhancement |Aura of Force|
| Air-Water | Divination |Scrying Pool|

> **Mirror-pair note (review §7).** The ordered-pair structure is a real systemic asset worth keeping conversant when naming: Fire-Earth **sprites** / Earth-Fire **hounds** (which element *leads* picks the creature); Fire-Water **chains** (steam → momentum) / Water-Fire **tithes** (burn one resource, gain another). When you name and when you fill gaps, keep mirror pairs thematically in dialogue with each other.

---

## Incantation Effect Table (Needs Playtesting)

The 16 base effect types, mapped to second-third element combinations (first element = affinity flavor). Potency (bracketed) values apply under the Fire/Potency enhancement.

| Second-Third | Base Effect | Fire Flavor | Earth Flavor | Water Flavor | Air Flavor |
|---|---|---|---|---|---|
| Fire-Fire | Damage [+50% damage] | 4 damage | 2 damage; also damages walls or sprites it intersects en route to target | 2 splash damage (AoE radius 2) | 2 damage and 1 knock back|
| Earth-Earth | Barriers, 2[3] turns | 2 HP; adjacent tiles take 1 fire damage at end of turn | 4 HP | 2 HP + 50% mana regen while active | 2 HP; free move when it collapses |
| Water-Water | Reflections, 2[3] effect only valid if spell resolves on an enemy| Whenever caster takes damage target takes equal damage |Whenever target creates a summon, caster creates an identical summon under caster's control| Whenever target gains mana, caster gains equal mana |Whenever target gains a status effect target casted itself, caster of this effect gains the same status effect.|
| Air-Air | Speed Manipulation | Move n extra tiles at cost of `n(n+1)/2` health [1 free tile] | Reduce target move speed by 1 for 3[4] turns | High Liquidity: move n extra tiles at cost of `n(n+1)/2 × 100` mana [1 free tile] | Increase target move speed by 1 for 2[3] turns |
| Fire-Earth | Status Effect Interaction | 1[2] damage per active status effect | All status effects dormant 2[3] turns | Status effects lose 1[2] turn | All status effects gain 1[2] turn |
| Fire-Water | Chain Interaction | Chain bonuses accumulate twice as fast next 2[3] turns | Chain bonuses grow at half speed next 3[4] turns | You gain all chain status of affected target; overwrites your existing chains [+1 turn to them] | All chain bonuses removed [all chains set to −1: mana cost increased instead of decreased] |
| Fire-Air | Spell Interaction | Next spell's cost paid twice; mana shortfall converts to health damage at 1[2] HP per 10 mana| "Sluggish" Always resolve last unless others are sluggish, 3[4] turns | Copy enemy spell [may copy twice; second copy still costs its mana] | "Quick" Always resolve first unless others are quick, 2[3] turns |
| Earth-Fire | Fuel Transmutation |Wither a [2] random active spell[s] (found by bookmarks) gain a[2] random (noncountercharm) artifact |Burn 4[8] life, reactivate a[2] withered spell[s]|Burn 100[200] mana, gain 4[8] life|Burn a[2] random artifact, gain 100 [200] mana|
| Earth-Water | Tile Modification [may place second effect in adjacent tile] | Floor is Lava (2 damage to pass through) | Impassable terrain that also blocks spells from passing through for line of sight| Costs 2 movement to enter and drains mana on entry |Conveyor tiles force-move whatever stands on them; direction chosen at effect resolution and permanent|
| Earth-Air | Range Modification | Penetrating: spells can't be blocked by walls; 1 damage to anything in hexes en route, 2[3] turns | Reduce spell range by 1 for 3[4] turns | Turbulent: next spell fires in intended direction but range randomized 1–max, 3[4] turns | Increase spell range by 1 for 2[3] turns |
| Water-Fire |Clouds, tiles covered by clouds can only be targeted by adjacent entities entities in clouds can only target adjacent tiles. Clouds are radius 1 for 2[3] turns|Entities entering or ending turn in cloud take 1 damage| Entities that leave this cloud may still only target adjacent tiles for 2 additional turns (is a status effect)| Cloud radius 2 | Cloud will move 1 tile during summon phase every turn to try and center itself on closest enemy entity, preferring players over summons|
| Water-Earth | Artifacts Interaction | Burn Random Player Artifact to deal 1[2] damage *(random target via joint entropy; can't hit core gem; burning a counter charm reveals its target)* | Summon 1[2] Rod of Spreading| Summon 1[2] mana gems | Summon 1[2] bookmarks |
| Water-Air | Illusions |Copy target summon, it attacks aggressively and only has 1 hitpoint| Copy Terrain and expand it to all adjacent tiles without terrain already, the copies have 1 hitpoint.| Create 3 Illusions of the wizard spaced evenly in the surrounding radius. If the wizard is subjected to a spell or attack, on a chance equal to 1/number of illusions remaining, the wizard is hit with the effect, otherwise destroy a random illusion and move the wizard to that tile.| Non wizard entity becomes an illusion with 1 hit point.|
| Air-Fire | Multiplier cycles | Your next air effect is twice [thrice] as powerful |Your next fire effect is twice[thrice] as powerful| Your next earth effect is twice [thrice] as powerful | Your next water effect is twice [thrice] as powerful|
| Air-Earth | melee attack Interaction, 2[3] turns | Stacking fire DoT, damage = turns remaining, 2 turns at a time | Target move speed reduced by 1 | Target status effects lose a turn | Bonus damage equal to spaces moved toward target |
| Air-Water | Divination |See target's counter charm alignment, will turn bookmarks marking those spells red for rest of the match|Identify Illusions and See Through Clouds 1[2] turns| See Target's available spells 2[3] turns |See target's spell target tile 2[3] turns|


> **Duration principle — buffs shorter than debuffs.** When setting durations, **self-buffs should run shorter than effects you land on an opponent.** Reason: under tile-targeting + commit-before-move, you can reliably place an effect on the tile you yourself occupy (or will), but landing one on an opponent means *cornering or accurately predicting them onto a targeted tile* against their dodging — much harder. Equal durations would overvalue the easy self-target case; shorter self-buff windows keep "buff your own feet" from being strictly better than fighting to control where the enemy stands. Apply this as a tie-breaker when filling in the bracketed/duration numbers across the table.

---

## Summons

Instead of creating spell effect incantations, players may use glyph crafting to summon creatures from world's beyond.  All possible creatures exist in some parallel world, by using the elements to describe that creature's attributes. Once linked to in this way mana may be paid to summon a matching creature onto the battlefield and bind it to the caster's will.

Creatures stats are determined by multipliers of the elements they are linked to. Adjusting the multiplier base is the primary lever for tuning and balancing creatures
Summons **may take an immediate turn the generation they are summoned if spell is made potent** (per the effect table). Both act on the Summons step of turn order (step 1), in creation order, moving then attacking the nearest enemy.
### Elemental Affinity

A summon's elemental affinity match whatever element appeared the most in it's formulation. If there's a tie whichever element (between the elements in the tie) appeared first determines the affinity.

Summons deal damage in the type that their affinity is. And they take half damage rounded up from a type that matches their elemental affinity, normal damage from adjacent element types, and double damage from enemy types. For example, A fire summon would take half damage from fire, normal from air and earth, and double from water.

### Stats

|Element|Stat|Multiplier (rounded down)|
|---|---|---|
|Fire|Attack Damage|.5|
|Air|Move Speed|.5|
|Water|Attack Range|.33|
|Earth|Hit Points|1|

### Abilities

Creatures exact elemental sequences can be parsed to detect specific creature abilities, similar to how wild magic parses hashes. An element may be used more than one time when searching for ability patterns. This table describes what patterns link to what abilities. Elements patterns are abbreviated by their initials. The primary mechanism for balancing these abilities is the length of the formula and how difficult it is to achieve. Defaulting to 4 long for all for initial play testing.

|Pattern|Ability|Description|
|---|---|---|
|AAAA|Flying|May move through other entities as if they were not there, but still not end their move in the same tile as another entity. Unaffected by modified terrain (though still by clouds)|
|FFFF|Cleave|Attack damage will be applied to a second enemy entity if that second enemy is adjacent to both the primary target and this creature.|
|EEEE|Big|Creature now occupieds 3 adjacent hexes (forming a triangle of sorts) and is unable to be moved by exterior forces. It's range and the range of things effecting it applies from any of it's tiles.|
|WWWW|Morphic|Upon death will reform into new creature with half the number of elements rounded down and selected at random|
|FAFA|Charger|Adds damage equal to half the distance it moved before attacking rounded up|
|AWAW|Stealthy|Other summons will treat this creature as if it doesn't exist unless it's within an adjacent tile.|
|WEWE|Muddy|Attack will reduce move speed of target by 1 for 1 turn.|
|EFEF|Molten Carapace|Attacks from sources within 1 range of this creature cause 1 fire damage to be reflected.|


### Personalities
When added to a spell book a set of glyphs may be added to force a particular personality onto the creature to govern it's behavior in battle.
Evasive: these creatures try to put themselves at a distance from all enemies while still being in attack range of at least one. Prefer targeting players in decision making ties.
Aggressive: Move on path most directly to nearest enemy player. They are not particularly intelligent and kiting them into damaging terrain or clouds is a common tactic to deal with them. The only terrain they acknowledge is the impassible earth walls which they will try to path around.
Protective: Prioritize trying Insert themselves between their summoner and other hostile entities.
Tactical: Will prioritize trying to slay targets with the fewest hitpoints. Factoring in resistances and vulnerabilities.
2. Attack, targeting the closest enemy player (or illusion, they are unable to discern the difference). If no enemy players are around, they will target the closest enemy minion. Targets that are both equally close and equal priority chosen at random.

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

The inscription proof guarantees a spell's outputs came from *some* valid grid evolution. It guarantees nothing about HP, mana, movement, art state, or turn resolution — all client-enforced, and the client is GPL. Two cheap additions close most of the gap and are table stakes for serverless P2P:
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

### artifacts

Select 12 artifacts across 4 element-typed kinds:
- **Water — Mana Gems:** first selected is the indestructible **core gem**. Each gem provides 10 mana/turn and +100 max mana pool.
- **Fire — Counter Charms:** name a known spell (by its Poseidon hash = its initial grid state). If that spell is cast during the battle it fizzles — action wasted, mana returned. The countered spell isn't publicly revealed until it activates.
  - **`[RESOLVED]` Targeting rule:** a counter charm fires against **any spell sharing the same initial grid-state hash**, regardless of owner, T, loan status, or custody chain. Requires commit-reveal with salt (above).
  - a counter charm keyed to the original commitment also fizzles a *copied* cast of it.
- **Air — Rod of Spreading:** A rod of spreading may be activated to increase the spell effect radius by 1 for each effect in the next spell. This consumes the rod. Only one rod may be used per spell. Earth while tiles still prevent spell effects from traveling past them through this AoE.
- **Earth — Bookmarks:** each bookmark tracks a spell within the spellbook no matter how it hides; once used it auto-finds a new random spell to track. Players toggle between bookmarked spells for casting (effectively hand size).

> **`[RESOLVED — v2.3 review §1 + your ruling]` No dedicated artifact-defense, by choice; Burn-artifacts interactions specified.** The rod's redefinition (from "neutralizes spells that interact with artifacts" to "nullifies one turn of a status effect") removed the only answer to artifact attacks — at the same revision that added Water-Earth's **Burn Random Player artifacts**. **This is intentional:** a single attack vector on artifacts isn't worth dedicating a quarter of all artifact slots to defending them, and the burn is fine *unguarded* because its random targeting (EV ≈ 1/12 against any specific artifact) makes it **diffuse attrition that punishes hoarding twelve eggs in one basket**, not a "deny my opponent all mana" denial strategy. Its real role is letting a drawn-out game eventually grind through a killer counter charm. Required interaction spec:
> - **Cannot hit the core gem** (indestructible by definition).
> - **Burning a counter charm reveals what spell it was countering** — a great consolation prize and information leak.
> - **Burn target is drawn from joint commit-reveal entropy** — otherwise the victim's client quietly picks its own least-valuable artifact.
> - **`[DECISION — needs Soren]` "Absorption totem"** (named in the Water-Earth/Earth effect cell) is currently undefined — either define it (a deployable that absorbs the next artifact-targeting effect?) or rename the cell to summon an Absorption Rod.

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
- **Void eligibility `[RESOLVED]`:** Void effects entirely removed for now

### Trigger Patterns
Scan the spell-hash hex string for two pattern types per element:
- **Repeating numerals** (For example 111, 222, AAAA): assigned per element, no overlap
- **Ascending runs** (3456, F012, BCDE): F wraps to 0; first numeral must be the element's designated trigger

### Wild Magic Effects (intentionally short while core effects are playtested)
Sequences continuing past the minimum 3 scale per the brackets.

| Triggering Sequence |Fire Flavor | Earth Flavor | Water Flavor | Air Flavor |
|---|---|---|---|---|
| 000 | Burning Hot - All spell effects next turn deal +1 fire damage [+1 damage per effect] | Mountains - All adjacent cells become earth walls 2 turns [+1 turn] | Mana Flood - All mana bars immediately fill | Zephyr - All players and minions teleported to random locations |
| 111 |Spontaneous combustion - Each player has another [+1] bookmarked spell immediately go off without mana cost targeting a random in range tile |Chasm - A randomly drawn line bisects the battlefield.  It is impassible (without flying), and indestructible for 2[+1] turns, but has no bearing on targeting.| Glacier - Tiles without existing terrain all become Ice tiles for 2 [+1] turns, when moving onto ice a players continue moving that direction.| Updraft - All players gain flying for 2 [+1] turns.|
|---|---|---|---|---|
012345| Phoenix - all players gain "The next time they would die, the respawn with 1 hitpoint instead"|Statuesque - All players return to full health and mana each turn, the effect is lost if they move or cast a spell.|

T
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
- **Taking *no* chain action that turn (no spell, or a melee attack) → the chain *regresses by 2*** (a gentler decay for inaction, not a full reset).

> **`[RESOLVED — v2.3 review §10]` The overlap is fixed:** the v2.3 doc had a non-aligned *cast* triggering both "break" and "regress by 2." The rule is now **action breaks, inaction regresses** — casting something off-alignment is an active choice with a hard consequence (full reset); merely failing to advance (idle turn / melee attack) only nudges it down by 2. Distinct events, distinct penalties.


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

## melee attacks
Players may throw an awkward, inefficient punch at an adjacent hex for 1 damage at no mana cost. Spell effects (Air-Earth row) can empower a melee attack with bonuses.

- **`[RESOLVED]` Action cost:** a melee attack **consumes the cast-a-spell action** for the turn (it is declared in step 3 in place of a spell).
- **`[RESOLVED]` Resolution timing:** melee attacks resolve in **step 5, before any spell resolves**. The adjacent target hex is taken relative to the puncher's position *after* movement resolves.
- **`[RESOLVED]` Simultaneous melee attacks:** the player with **fewer total remaining status-effect turns** (summed across all their active status effects) resolves first; if still tied, a pseudorandom coin flip via commit-reveal entropy.

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
3. Players **commit** their cast action — either a target hex for a spell, or a melee attack. **The target hex is committed before movement resolves** (step 4): you cannot watch movement land and then retarget. This makes casting a *prediction* of where bodies will be, not a reaction to where they are.
4. Movement resolves.
5. **melee attacks resolve** (before any spell). If both players melee attack the same beat, the player with **fewer total remaining status-effect turns** resolves first; if still tied, a pseudorandom coin flip via commit-reveal entropy.
6. **Spells resolve.** Between players, the spell with the **smaller step count (T)** resolves first; ties broken by **whichever initial grid hash is the smaller number**. *(The Fire-Air "always resolve first/last unless…" family overrides this default.)* Within a single player's spell: **wild magic first, then formula effects in the order the CA created them.** If multiple objects would be summoned to the same tile (e.g. two hounds), one is bumped to a random adjacent tile (commit-reveal entropy).
7. Status effects tick down.

> **`[RESOLVED]` Inter-player ordering:** lower-T spell first, tiebreak smaller grid hash, then — if two+ players cast the *exact same spell* (identical T **and** identical grid hash) — a **dice roll** drawn from joint commit-reveal entropy. **melee attacks** consume the cast-a-spell action and resolve before spells, with the status-turns / coin-flip tiebreak above.
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

### Vocal Components
Vocal components consist of the player reading out the latin words that make up all the elements in their spell followed by a finishing word "Finitus". The clarity, loudness, and fluidity of the pronunciation will apply a mana discount or penalty.

### Somatic Components

There are 5 types of somatic components that will determine what spell enhancement the spell will be cast with.
Neutral -
Potency - An upheld hand twitching back and forth, as if struggling to contain the power.
Velocity -
Efficiency - Moving in a vertical circle in front of the caster, like Doctor Strange making portals.
Mystery - 
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

**Resolved so far:** grid size (469, green) · pressure/decay (floored-at-0, dominant-only) · mana cost (free-4-then-`1.25^(T−4)`; exponential affirmed as effect-count throttle; chains buy T) · **T-architecture: three circuit tiers `T_max ∈ {12,24,48}`, handshake picks smallest covering the declared T (12/24 green everyday, 48 yellow spectacle tier)** · **void mana cost (`10×1.25^(tiles−1)`) PLUS a tile-gated power cap (the cost curve alone doesn't tax grinders)** · player HP (24) · base range (3) · Fire-Air conversion (1 HP / 10 mana) · owner-independent counter charms (same grid hash, any factor) · `owner_pubkey = Poseidon2(key)`, Ed25519 off-circuit · scrolls bound to a named opponent · difficulty gradient reversed (repeats easiest) · chain break-vs-regress (action breaks, inaction regresses) · burn-artifacts ruling (diffuse 1/12 attrition; no dedicated defense) · inter-player resolution order (lower T first, tiebreak smaller hash) · targeting committed before movement · tile-targeting core loop · wild magic as global double-edged · melee attack action cost + resolution + tiebreak · buff-shorter-than-debuff duration principle.

Still open, priority-ordered:

1. **Divination family:** recipe-table (A) or wild-magic-only (B). *(Effect Table / Wild Magic.)*
2. **Effect-table power audit** *(named playtest goal, new this pass)* — re-tune so power rises with difficulty under the reversed gradient (opposite-pair strongest, same-pair most modest); the table was filled under the old philosophy. *(Supreme Dominance / Effect Table.)*
3. **"Absorption totem"** — define the summoned deployable, or rename the Water-Earth/Earth cell to summon an Absorption Rod. *(artifacts / Effect Table.)*
4. **Out-of-range committed target** (caster displaced off range): fizzle, fire-at-max-range-along-line, or whiff. *(Targeting — I lean fire-at-max-range.)*
5. **Effect-table specifics:** Earth-Water/Air conveyor direction rule; Fire-Water/Air "whose chains"; Copy-Spell vs. counter-charm ruling; Illusions vs. visible-positions reconciliation.
6. **Sorcerer movement mechanism:** GPS vs. step-count vs. compass-bearing — **leaning step-count + compass-bearing** (Casting Stillness resolves the pedometer/gesture conflict and keeps the footprint small). Confirm. *(Battle Modes.)*
7. **Summon details:** confirm sprite-vs-hound base identities and tune stat scaffold; decide persistence/lifespan, simultaneous-summon cap, tile-occupancy, and friendly-fire. *(Summons.)*
8. **Effect names:** fill the Effect Naming Worksheet (16 in-world names) — and re-sync it to the rearranged table. *(Effect Naming Worksheet.)*
9. **Transport adapters & selection:** how many of the three adapters to build now, and confirm auto-negotiate-with-manual-override. *(Pluggable transport layer.)*
10. *(Optional/playtest)* **Void free-T grinding** — fold a T term into void cost only if void-T-fishing appears; tune the **tile→tier thresholds** for the new void power cap. *(Void Spell Mana Cost.)*
11. **Multi-player (>2):** wizard-mode scaling resolved (simultaneous commit, resolution sort + same-spell dice roll, same-tile principle, lenticular speed asymmetry). Remaining future-session work: **win/elimination condition**, **free-for-all vs. teams**, **ELO + N-signer match-record format**. *(Multi-Player section.)*

> **Resolved this pass (was open):** chain reset-vs-regress (action breaks, inaction regresses) · supreme-dominance triviality (dissolved by the reversed difficulty gradient — repeats *should* be easy) · void wild-magic gate (tier cap by tiles, since the cost curve alone doesn't tax grinders) · scroll single-use (named-opponent binding) · `owner_pubkey` representation (`Poseidon2(key)`, Ed25519 off-circuit) · HP (24, swept) · burn-artifacts (kept; diffuse 1/12 attrition; no dedicated defense) · **Chaos wild-magic column (deleted — four element effects at once is reward enough)** · **mana free-threshold (set to `T − 4`)**.

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
- Characters may be assigned specific **spells, artifact loadouts, and HP above or below standard** — so a story's protagonist can be deliberately over- or under-powered for narrative reasons. *(The config is captured in the signed battle record — see above.)*
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
