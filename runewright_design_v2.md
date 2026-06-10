# Runewright — Game Design Document (v2)
*Briefing document for Claude Projects context*

*Last updated: post-Phase 1.5, reflecting design pivots from initial 13-state CA to current 2-state CA with rule modification gates.*

---

## Vision & Design Philosophy

A mobile game simulating the experience of being a D&D-style wizard in real life. Core pillars:

- **Jealously guarded magical discoveries** — players are incentivized to protect their spell designs
- **No central authority** — fully peer-to-peer, zero ongoing server overhead for the developer
- **Cryptographic integrity** — cheating on spell output is mathematically hard, not just socially discouraged
- **Mystique as a structural feature** — the decentralized design creates speculation, rumor, and community lore organically
- **Face-to-face experience** — duels happen in person between two phones via local wireless; the design is optimized for in-person play, including psycholgical games and misdirection in combat and out of combat a level of tradecraftesque tactics like including shoulder-surfing and deceitful trade bargins like "Diplomacy" as a real meta-game element for discovering magical secrets.  But an ethos respecting peoples personal privacy and comfort levels.
- **Free, ad-free, no microtransactions** — donation-only model, no data harvesting
- **Word-of-mouth distribution** — designed to feel like a discovery shared between people with similar taste

---

## Platform & Tech Stack

- **Primary target:** Android (Flutter/Dart)
- **Development environment:** Ubuntu Linux, VS Code, Flutter SDK
- **iOS port:** Not currently planned, possible next step if demand is demonstrated; would require Mac hardware and significantly different distribution approach
- **Cross-platform multiplayer:** Out of scope, would like to manage in some form if iOS port ever materializes
- **Local networking:** Google Nearby Connections API (handles WiFi Direct and Bluetooth automatically)
- **ZK proofs:** Noir framework with Barretenberg backend (UltraHonk)
- **In-circuit hashing:** Poseidon2 (BN254, state size 4, sponge with rate 3 capacity 1) — matches Noir stdlib
- **Spell effect hashing:** SHA-256 (outside circuit, standard Dart crypto package)
- **Mobile FFI:** TBD (noir-rs recommended starting point, with Rust FFI bridge to Dart)

---

## The Spellbook Loop (Outside of Battle)

Players inscribe spells into a persistent spellbook on their device. This is the primary creative activity of the game, done outside of battles.

### The Rune Grid

- **Shape:** Hexagonal grid, vertex-down orientation
- **Inscribable region:** Center hex plus 8 rings (radius 8, 217 cells)
- **Buffer region:** Rings 9-11 — participate in CA simulation but start empty and cannot be inscribed to make activating the last ring non trivial.
- **Border ring:** Ring 12 — activations here are counted but cells immediately deactivate and do not participate in CA rules
- **Total cells in simulation:** 469 per current implementation
- **Coordinate system:** Axial hex coordinates (q, r)

### Cell States

Two states only: **inactive** (0) and **active** (1). All gameplay variation comes from the rule modification system, not from cell type variety.

### Border Zone Partitioning — Landscape Layout

The border ring is partitioned into four elemental zones in a landscape arrangement, with opposing elements on opposing sides:

- **Mountain (Earth)** — leftward 18 cells
- **Sun (Fire)** — top 18 cells
- **Sky (Air)** — rightward 18 cells
- **Sea (Water)** — bottom 18 cells

Total: 72 cells.
Art outside the grid will visually support the landscape metaphor — mountain silhouette on left, sun graphic at top, sky on right, sea below.

---

## Cellular Automaton Rules

### Baseline Rules (Neutral State)

Hex Conway 2/2 rule:
- An active cell with exactly 2 active neighbors survives
- An empty cell with exactly 2 active neighbors becomes active
- All other transitions: cell becomes or remains inactive

This is the rule set in effect before any element has gained dominance, or after all elements have decayed to zero pressure.

### Element-Specific Rule Sets

When an element holds dominance (see Dominance System below), its rules replace the baseline. The current rule set definitions:

- **Fire:** Born on exactly 1 neighbor. Survives on exactly 1 neighbor. (Unpredictable wild flitting)
- **Earth:** Born on exactly 2, survives on any. (slow inexorable growth)
- **Water:** Born on 1 and 2, survives on 3+ (coalescence)
- **Air:** Standard reproduction; dies with 2+ active neighbors (sparse, scattered persistence)

The Phase 1.5 lookup table contains 70 entries (5 rule states × 2 cell states × 7 neighbor counts), confirming the rule variants compile efficiently regardless of exact specifics.

### Border Cell Behavior

Border cells (ring 12) follow special rules:
- Activations are counted for the dominance system
- Border cells immediately deactivate the following generation
- Border cells do not participate as neighbors in subsequent CA rules
- Border collateral damage (adjacent cells deactivating) was considered but **removed** to avoid making triple-element formulas harder than player intuition expects

---

## Dominance System

The mechanic by which the player's CA pattern shifts the active rule set during simulation.

### Pressure Tracking

Each of the four elements maintains a "pressure" counter (integer, minimum zero):

- Each generation, each element gains +1 pressure for each border cell activated in its zone
- The currently-dominant element loses pressure equal to `floor(generation_count / 2)` each generation
- The element with the highest pressure value is "dominant" and determines which rule set is active
- **Sticky ties:** the current leader stays dominant unless strictly exceeded by another element

### Neutral State

When no element has positive pressure (all at zeros), the baseline neutral rules apply. This means returning to neutral is "sticky" — the simulation continues in baseline rules until an element generates enough new activations to overcome any negative pressure.

### Supreme Dominance

When the dominant element has more total activations than the other three combined, it is "supremely dominant." Supreme dominance is detected per-generation and emitted from the circuit as a flag (one boolean per generation).

Supreme dominance affects external formula parsing (see Spell Crafting below) — each generation of supreme dominance counts as an additional trajectory entry for that element.

### Generation-Based Decay Philosophy

The decay rate (`floor(generation_count / 2)`) grows over time, making sustained dominance progressively harder. Early generations have light decay; late generations have heavy decay. This creates:

- Naturally short rule periods (dominance is hard to maintain)
- Increasing chaos in long simulations (rules flicker as decay outpaces activations)
- Late-game tendency toward neutral state.
- Natural pacing where short simulations are controllable and long simulations are dramatic

---

## Spell Crafting

The system by which dominance trajectories produce spell effects. **All spell crafting logic is external to the ZK circuit** — the circuit emits the trajectory and external code parses it.

### Trajectory

The circuit emits one entry per generation indicating the dominant element (or neutral state), plus the supreme dominance flag per generation. External code processes this trajectory into formulas.

**Trajectory entry counting:**
- Each new dominance event (transition from one element/neutral to a different element) counts as one entry for that element
- Each generation of supreme dominance counts as one *additional* entry for the dominant element (in addition to the base dominance entry)
- Neutral periods are gaps, not entries — they separate dominance events but don't contribute to formulas
- Same-element repetition without a different element between events requires a neutral gap

### Formula Structure

Every formula consists of exactly three elemental entries from the trajectory:

- **First entry:** determines the formula's **affinity** (the element flavor)
- **Second + third entries together:** map to one of 16 base **effect types**

This produces 4 affinities × 16 effects = 64 distinct spell outcomes.


### Multi-Formula Spells

If a trajectory contains more than three entries, sequential triplets each form their own formula:

- Trajectory `[fire, earth, water, air, fire, earth]` = two formulas: fire-earth-water and air-fire-earth
- Trajectory `[fire, earth, water, air, fire]` = one formula (fire-earth-water) plus two residuals (air, fire)
- Trajectory `[fire, earth]` = zero formulas (need three entries), two residuals

A spell can contain multiple formulas, each contributing its own effect to the spell's outcome.

### Residuals

Trajectory entries that don't complete a formula become residuals. Residuals provide minor stat buffs that both stack accumulate on a log 3 growth scale (effects added to pool on 1, 3, 9, ...:

- **Fire residuals:** 1 bonus damage on next damage spell
- **Water residuals:** 2 times mana regeneration for a turn
- **Earth residuals:** 1 armor (temporary hp)
- **Air residuals:** +1 range and movement speed for a turn


### Spell Affinity

A spell's overall affinity for chain casting and wild magic purposes:

- **Single-formula spell:** affinity = that formula's affinity
- **Multi-formula spell:** hybrid affinity = all distinct first-elements of completed formulas

A spell with formulas fire-X-X and water-X-X has fire-water hybrid affinity. A spell with formulas fire-X-X, fire-X-X, and earth-X-X has fire-earth hybrid affinity (fire counts once despite being affinity of two formulas).

---

## Effect Table (Needs Playtesting)

The 16 base effect types, mapped to second-third element combinations (with first element as affinity providing flavor):
Potency Effects in brackets

| Second-Third | Base Effect | Fire Flavor | Earth Flavor | Water Flavor | Air Flavor |
|---|---|---|---|---|---|
| Fire-Fire | Damage [Increases damage by 50%] |4 Damage| 2 damage also damages walls or sprites it intersects on way to target | 2 Splash Damage (AoE radius 2) | 2 Damage and 1 self movement |
| Earth-Earth | Barriers 2[3] Turns| 2 HP adjacent tiles take one fire damage at end of turn | 4 HP | 2 HP + 10% manage regen while active | 2 HP free move when collapses
| Water-Water | Mana Gem Manipulation | Destroy 2[3] Mana Gem| All mana gems regeneration but core disabled 2[3] turn| Summon Mana gem [2] | Supercharged, all gems effects doubled [tripled] next turn.|
| Air-Air | Speed Manipulation | May move a number of additional tiles at cost of (n(n+1))/2) health [1 free tile]| Reduces target move speed by 1 for [4] turns. | High Liquidity (May move a number of additional tiles at cost of (n(n+1))/2)*100 mana) [1 tile for free]| Increases target move speed by 1 for 2[3] turns | 
| Fire-Earth |Sprite Summoning[Sprites may take immediate turn]| High damage sprite | High HP sprite | Splash Damage Sprite| Knockback sprite |
| Fire-Water | Chain Interaction |Chain bonuses accumulate twice as fast next 2[3] turns |Chain bonuses grow at half speed for the next 3[4] turns|You gain all chain status of effected target will overright any existing chains you have [+1 turn to them| All Chain Bonuses Removed [All chains set to -1 (mana cost increased instead of decreased by normal chain bonuses]|
| Fire-Air | Spell Interaction |Next spell cast has cost paid a second time, if not enough mana debt translates as 1[2]% damage to health|Always resolve last unless other spells are sluggish 3[4] Turns|Copy Spell [May copy twice, but will require paying spells mana cost for second copy]|Always resolve first unless other spells are quick 2[3] turns|
| Earth-Fire | Hound Summoning [Hounds May take immediat turn] |Exra Damage Hound|Extra Health|Splash Damage hound|Extra Fast Hound |
| Earth-Water |  Tile Modification [May place second effect in adjacent tile] | Floor is Lava (hurts to pass through) | Impassible terrain that also blocks spells from moving through it | costs 2 movement to step into and drains mana when stepped into | Conveyor tiles that force move player or summons that moves on them. Direction of movement is opposite closest to opposite direction of hex from caster when cast |
| Earth-Air | Range Modification |Pentrating Range, Spells Cannot Be Blocked by walls, and 1 damage done to anything in Hexs in route to the spells intended target 2[3] turns|Reduce Spell Range by 1 for 3[4] turns |Turbulent Range, next spell cast goes off in intended direction but randomizes the range between 1 and maximum 3[4] turns| Increase Spell Range by 1 for 2[3] turns|
| Water-Fire | Summon Clouds 3[4] turns|Toxic Smoke (1 damage a turn)|Dust cloud Blind 1 turn even after leaving cloud|Refreshing Cloud +10% mana regen in cloud|Mobile Cloud (Caster may choose new center of cloud at start of turn|
| Water-Earth | Status Effect Interaction |1[2] damage for each active status effect|All Status effects dormant for 2[3]turn|Status Effects Lose 1[2] Turn|All Status Effects Gain 1[2] Turn|
| Water-Air | Illusions 3[4] turns|Deal 1 damage to attacker if targeted | Last twice as long | Mirror Player movement (opposite directions| |
| Air-Fire | Dispels |Minions (sprites and hounds radius 2[3]|Illusions radius 3[4]|Terrain Radius 2[3]|Clouds Radius 3[4]|
| Air-Earth | Haymaker Interaction 2[3] turns|Creates Stacking Fire Dot does damage equal to turns remaining 2 turns at a time|Target Move Speed Reduced by 1| Target Status Effects Lose a Turn| Bonus Damage Equal to spaces moved towards Target|
| Air-Water | Bookmark Interaction | Burn 1 [2] bookmark |Cannot use bookmarks 1[2] turns | Summon [2] Bookmarks | All Current Spell pages lost and equal number of new ones found [caster may choose to flutter second time]|

**Design guidance for filling this out:**
- Effects should be thematically consistent with their elemental composition
- Power level should scale with formula achievability (repetitive formulas more powerful than mixed)
- Flavor variations should feel meaningfully different across the four affinities while remaining the "same effect type"
- Some effects should be defensive/utility, some offensive, some manipulative (of opponent's spellbook, mana, etc.)
- Consider that effects will interact with the battlefield, opponent state, and other spells

---

## The Cryptographic System

### Zero Knowledge Proof

At inscription time, the player generates a ZK proof attesting to:

> "I know a grid_state such that:
> 1. `Poseidon2(grid_state || T) == commitment`
> 2. Running grid_state through the CA for T generations produces the declared border activations, dominance trajectory, and supreme dominance flags"

The proof is stored in the spellbook alongside the spell.

### Commitment Scheme

```
commitment = Poseidon2(grid_state)
```

The grid pattern itself is the source of variance. Same grid = same spell root, though running for additional time may add numerous more effects and change mana cost. Different grid = different commitment = different spell.

This means re-inscribing the same rune produces the same commitment (so counter-spells continue to apply). Players who want a different commitment must genuinely change the grid pattern, which has real mana cost as well as altering wild magic properties.

### Public Inputs (Circuit Outputs)

- `commitment: Field` — Poseidon2 hash of grid state and T
- `T: Field` — generation count
- `border_activations: [Field; 4]` — total activations per element
- `dominance_trajectory: [Field; T]` — dominant element per generation
- `supreme_dominance_flags: [Field; T]` — boolean per generation

### Private Inputs (Witness)

- `grid_state: [Field; 469]` — initial grid configuration (only inscribable region populated)

### Spell Effect Hash

After proof verification, both players compute deterministically:

```
seed = SHA256(commitment || border_activations || trajectory || community_seed)
```

This hash is parsed for wild magic patterns (see Wild Magic below).

### Community Seed Word

An optional word factored into the wild magic hash, creating local magical traditions:

- Affects wild magic effects only, not recipe effects
- Recipe effects remain universal across all communities
- Players can travel between communities without invalidating their spellbook for recipe purposes
- Local communities develop unique wild magic optimizations as "home turf advantage"
- Default seed: "universal"
- Communities choose their own seed word
- Tournament format: announced seed at event start for equal footing
- Case-insensitive, stripped of whitespace and punctuation before hashing

---

## Loadout System

### Spellbook
Players may put any number of spells they've successfully inscribed into a spellbook to be used for a battle. All spells must have a unique initial grid state. Spellbooks are flavored as chaotic semi-sapient objects.  Any spell not currently opened and under the wizard's watchful gaze will often migrate and hide between other pages.

Each chosen spell may then be enhanced in one of four ways:
Efficency - Mana cost of spell reduced by a third.
Potency - Spell effect switch use their bracketed effects in the table.
Velocity - Spell range increased by 2
Mystery - Spell may be precommitted to go off on a chosen tile with a delay between one and three turns. The spell, the location, and the delay are all secret until the spell resolves.

### Accoutrements

Players will be able to select 12 accoutrements of 4 types.

Mana Gems - The first one of these selected is considered the core gem and is indestructible. Each gem provides 10 mana per turn and increases maximum mana pool by 100.
Counter Charms - A known spell from the library (identified by its poseidon hash representing it's initial grid state) if that spell is cast during the battle it fizzles, the action is wasted but the mana is returned.  The spells charms countered is not publically revealed till they activate.
Bookmarks - Each magical bookmark identifies a spell and tracks it within the spellbook no matter how it tries to hide. Once used it will automatically find a new random spell to track in the spellbook. Players may toggle between any book marked spell for casting.  Effectively works as increasing hand size in a card game.
Absorption Rod - If a spell would interact with an accoutrement, the absorption rod neutralizes the effect instead (creating new accoutrements is not the same as interacting with existing ones) each rod has 2 charges of absorption before being rendered useless.

### Spell Mana Cost
mana_cost = Starting Active Cells * 1.25^number of steps

The softer exponent (1.15 vs 1.3) provides headroom for longer simulations as a premium experience. Total activations naturally scales with both grid complexity and simulation length.

The mana cost curve has been deliberately calibrated to allow long simulations as expensive options for skilled players, supporting the game's intended long-tail community engagement.


## Wild Magic System

A parallel-to-recipes effect system based on hash pattern scanning.

### Eligibility

Determined by the spell's overall dominant element (cumulative across all formulas):
- Single-affinity spells: scan hash for patterns matching that element
- Hybrid-affinity spells: scan for patterns matching any of the spell's component affinities
- Perfectly balanced spells (multiple elements equally dominant): eligible for all balanced elements' patterns simultaneously — this is the "wild magic specialist" archetype

### Trigger Patterns

The spell hash hex string is scanned for two pattern types per element:

- **Repeating numerals** (e.g., 111, 222, AAAA): assigned per element with no overlap
- **Ascending runs** (e.g., 3456, F012, BCDE): F wraps to 0; first numeral must be element's designated trigger

If a spell is inscribed with no formulas, and thus no elemental affinity, are eligible for powerful void effects 
### Wild Magic Effects
The sequence continuing past the minimum 3 causes effects to scale as listed in brackets
|Triggering Sequence | Void Effect | Fire Flavor | Earth Flavor | Water Flavor | Air Flavor | Chaos Flavor| 
|000||All adjacent non player cell effects instantly vanish [+1 radius]|All spell effects of all spells next turn also deal 1 additional fire damage [+1 damage for each effect]|All adjacent cells become earth walls for 2 turns [+1 turn]|All Mana Bars Immediately Fill| All players and minions teleported to random locations|

- Operate independently from recipe effects (both can fire from the same spell)
- Scale with the length/intensity of the triggering pattern
- Are influenced by the community seed word, producing different effects in different communities
- Should feel emergent and surprising rather than carefully designed

The wild magic specialist build (perfectly balanced elements, maximum trigger eligibility) requires high CA mastery and offers a third archetype alongside recipe-optimizers and CA-engineers.

---

## Chain Discount System

Each pure element tracks an independent chain counter. Casting sequential spells of the same affinity accumulates a mana discount.


### Chain Advancement

- **Pure-affinity spell aligned with active chain:** chain advances by 1, discount applies fully
- **Hybrid-affinity spell partially aligned:** chain advances by alignment percentage (fractional credits accumulate toward next integer advancement)
- **Pure-affinity spell of different element:** in wizard mode, hard reset; in sorcerer mode, decay
- **Hybrid spell with zero alignment to active chain:** wizard mode hard reset; sorcerer mode partial decay

### Discount Formula

```
discount = (0.9 ^ chain_length) × (percentage of spell's formulas aligned with active chain element)
```

Examples (chain length 5):
- Pure fire spell, fire chain active: 0.9^5 × 1.0 = 59% discount
- Fire-fire-water hybrid (2/3 fire), fire chain active: 0.9^5 × 0.67 = 39% discount
- Fire-water-air hybrid (1/3 fire), fire chain active: 0.9^5 × 0.33 = 19% discount

This rewards specialization while still allowing hybrid mages to benefit partially from their accumulated chains.

### Reference Points

| Chain length | Pure discount | 50% aligned hybrid |
|---|---|---|
| 1 | 10% | 5% |
| 3 | 27% | 14% |
| 5 | 41% | 20% |
| 10 | 65% | 33% |

### Chain Diminishment
Elemental Chain bonus count diminishes by 2 for any turn in which associated element not cast.
---


## Battlefield

### Grid

- Hexagonal battlefield grid, vertex-down orientation
- Default radius: 4 (61 tiles) — adjustable by player preference
- Consistent visual language with the rune grid

### Movement

- Players move up to 2 spaces per turn
- Both players' locations are visible to each other
- Movement resolves **before** spell targeting
- Air-affinity spells can grant faster movement (speed stat)

### Movement Collision

- Higher-speed player claims contested tile
- Other player remains on their previous position on their path
- Equal speed: both bounce back to previous positions

### Terrain

Optional feature may eventually be added to allow maps with tile modifing terrain appearing from the beginning.

### Targeting

- Spells target a single hex tile (AoE spells affect radius around target)
- Players declare target tile, then declare movement
- Movement resolves first, then spell resolves at declared target
- Friendly fire possible with AoE spells

---

##Turn Order
1. Summons turn: summons will automatically (or in a few cases manually) move, then attack the closest enemy target.  These effects resolve in the order in which the summons were created.
2. PLayers chose their movement path
3. Players target a hex tile with a spell.
4. Movement resolves
5. Spells resolve effects.  Wild magic first, then the spell effects in the order the CA created the formulas.  If multiple objects would be summoned to the same tile (e.g. two hounds) one will be moved to a random adjacent tile.
6. Status effects tick down.
   
## Battle Modes

There will be a variety of effects
### Wizard Mode Options

- Turn-based
- Deliberate, strategic
- Hard chain reset on off-element casting
- Players move and cast once per turn

### Sorcerer Mode

- Real-time
- Frantic spell queuing under time pressure
- Chain decay at 2x rate instead of hard reset
- Physical engagement (gestures, vocalizations) encouraged but not required
- Same underlying spell and battlefield mechanics

*Wizard mode is being designed first; sorcerer mode adapts from it.*

---

## ELO & Match Records

### No Central Authority (By Design)

The lack of a global leaderboard is a feature — it creates regional metas, traveling wizard dynamics, and community lore.

### Signed Match Records

After verified matches, both players cryptographically sign the outcome. Rating is accumulated receipts — tamper-evident but not centrally verified. Rating changes computed and signed jointly at match end.

### Local Community Ledgers (Optional)

Trusted community members can run lightweight nodes recording signed match outcomes. Different communities maintain their own records naturally.

### Adapted ELO Formula

Standard ELO modified to account for spell novelty:

```
novelty_stack = Σ e^(triggered_digits / mana_cost) for each novel spell encountered this match
K = base_K × (floor_bonus + novelty_stack)
rating_change = K × (actual_score - expected_score)
```

Key definitions:
- **triggered_digits:** hex characters in spell_string participating in triggering patterns (novel spells only)
- **novel spell:** commitment hash not previously in this player's bestiary
- **novelty_stack:** accumulates additively per novel spell
- **floor_bonus:** small constant ensuring zero-novelty matches still contribute

Wizard and Sorcerer ratings tracked separately (different skills).

---

## Spellbook Bestiary

After every duel, opponent's spells used against you are added to your spellbook bestiary:

- Spell commitment hash (unique fingerprint)
- Effects triggered
- Harmonic/wild magic count
- Opponent identity (or "Unknown Wizard")
- **Not included:** rune pattern, grid state, replication instructions

Bestiary entries become "white whales" — spells you know exist and can counter, but cannot recreate without independent research.

---

## Counter Spell System

Before each duel, players load counter spell slots from their bestiary.

- Counter spells target specific commitment hashes
- Counter slots persist across duels (not consumable)
- Number of counter slots: **TODO: specify, subject to playtesting**
- Counter effect: **TODO: specify (hard fizzle, mana tax, harmonic reduction, or reflection)**
- When a counter activates, it is revealed to both players
- Revelation leaks intelligence: opponent knows you've faced that spell before

The system creates a "widely-known spells become widely-countered" dynamic that naturally rebalances community metas.

---

## Implementation Status

### Completed

- Flutter/Dart project initialized
- Hex grid data model complete (axial coordinates)
- CA simulation engine: 2-state with rule modifications complete
- Dominance tracking system: implemented (pressure with `floor(N/2)` decay, no neutral reset)
- Visual test UI working
- Phase 0 complete: trivial Poseidon and stub CA circuits verified
- Phase 1 complete: 13-state CA circuit measured, simplification rationale established
- Phase 1.5 complete: 2-state CA with rule modifications measured
  - `ca_natural_v2`: 522k gates at T=20 (yellow)
  - `ca_lookup_v2`: 409k gates at T=20 (green), 3.1s desktop proving
  - Perfect linear scaling (R²=1.000) at 19,650 gates/step
  - 20x per-cell improvement over Phase 1 natural circuit
  - Lookup table: 70 entries total (well under stop-and-ask threshold)

### Not Yet Implemented

- Supreme dominance flag emission from circuit (decision made to add it; pending implementation)
- Mobile FFI integration (Phase 2)
- Battlefield system
- Spellbook UI
- Networking (local play)
- Effect table (recipes and wild magic)
- Counter spell mechanics
- Match record signing

---

## Open Design Questions / TODO List

Compiled from the design pivots; items need resolution before or during Phase 2:

**Settled but pending implementation:**
- Supreme dominance flag emission from circuit
- Border zone corner cell assignment (symmetric across rotations)

**Needs design completion:**
- Full 64-entry effect table (16 effect types × 4 elemental flavors)
- Wild magic effect table per element
- Wild magic trigger numerals per element (updated for 4-element schema)
- Mana cost formula final choice and tuning
- Mana cost preview UX
- Hand size and refresh mechanics
- Counter spell effect type and slot count
- Sorcerer mode chain decay mechanics
- Residual diminishing returns curve specifics
- Flooded tiles terrain proposal: keep or discard

**Needs implementation verification:**
- Cell count: design says 463, implementation has 469 — reconcile
- Element-specific CA rules: verify exact specifications match design intent
- Trajectory output format: confirm circuit emits what external code expects

**Needs playtesting:**
- Whether pressure decay rate `floor(N/2)` is the right tuning
- Whether supreme dominance threshold (strictly more than sum of others) is right
- Whether 18 cells per border zone is the right count for balanced play
- Whether T=20 is the right "typical" simulation length
- Whether the effect table power levels are balanced across formula tiers

**Future considerations (post-Phase 2):**
- Onboarding flow for solo players (AI opponent? tutorial?)
- Documentation/wiki structure
- Community discovery mechanisms (find-players-nearby?)
- Tournament format documentation
- Spectator mode for in-person events

---

## Design Philosophy Notes

These don't belong in mechanical specifications but inform downstream decisions:

**Two complementary spell crafting paths.** Recipe-based effects (deterministic, learnable, mastery-rewarding) coexist with wild magic effects (emergent, surprising, exploration-rewarding). Players choose their balance point along this spectrum, and the systems compose rather than compete.

**Magic as natural force, not engineered system.** The simulation is meant to feel like channeling something larger than yourself. Rules-changing-mid-simulation, supreme dominance, residuals, and wild magic all support the metaphor that you're working with magic, not just executing algorithms.

**Difficulty matches intuition where possible.** Triple-element formulas (fire-fire-fire) should feel achievable in proportion to how achievable they sound. Supreme dominance was added specifically to align mechanic difficulty with player expectations.

**Circuit budget as design lever.** Phase 1.5 revealed substantial circuit headroom. This headroom is being reserved for longer simulations rather than additional mechanics, supporting the long-tail community vision where mastery deepens over years.

**In-person play as first-class concern.** Shoulder-surfing, physical gesture, vocalization, and venue play are not afterthoughts. The cryptographic design supports them; the UX should reinforce them.
