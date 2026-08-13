# Runewright Architecture Review

## Executive Summary

Runewright's architecture is fundamentally sound. I would **not recommend a rewrite**.

The cellular-automata and cryptographic foundation is unusually clean, the trust model is thoughtfully reflected in the implementation, and introducing a transport abstraction early was a good architectural decision. The project's main architectural debt is now concentrated in **battle orchestration**, with a secondary issue in **network protocol infrastructure**.

This looks less like a project whose original abstractions were wrong and more like a project whose successful feature growth has exceeded a few abstractions that were perfectly reasonable when they were introduced.

### High-Level Assessment

| Area | Assessment | Main reason |
|---|---|---|
| CA / mathematical core | **Excellent** | Small, deterministic, dependency-light |
| ZK / FFI boundary | **Very good** | Narrow boundary, strong invariants, golden-vector discipline |
| Domain modeling | **Good** | Rich types, but battle/spell ownership is getting tangled |
| Battle engine | **Needs refactor soon** | `turn_loop.dart` is ~7,700 lines and mixes too many concerns |
| Networking | **Good 2-player architecture** | Transport seam works, but protocol infrastructure is duplicated |
| Multiplayer readiness | **Designed well, implementation not ready** | Current APIs still encode "local + peer" deeply |
| Persistence | **Adequate prototype architecture** | Models perform their own filesystem I/O |
| UI | **Functionally organized, structurally heavy** | Several 3k–6k line stateful screens |
| Testing / engineering discipline | **Excellent** | Extensive tests, vectors, attack tests, and hardware-gate philosophy |

---

# 1. Current Architectural Shape

Conceptually, the repository appears approximately structured as:

```text
Flutter UI
   │
   ├── Spell crafting / library / trade / apprenticeship
   │       │
   │       └── CA engine ──────────────┐
   │                                   │
   └── BattleScreen                    │
           │                           │
           └── TurnLoop                │
                 ├── Battle models     │
                 ├── Effect engine     │
                 ├── Spell assets ─────┘
                 ├── Proof validation
                 └── BattleSession
                         │
                     Transport
                         │
                  TCP / mDNS

Spell inscription
   │
   ├── Dart CA oracle
   ├── Identity
   └── Rust FFI
          │
        Noir / Barretenberg
```

This is a sensible architecture.

The primary problem is that **`TurnLoop` has gradually swallowed several layers of this diagram.**

---

# 2. Primary Architectural Concern: `TurnLoop`

`lib/battle/engine/turn_loop.dart` is approximately 7,700 lines.

File size alone is not the issue. The problem is the number and kinds of responsibilities contained within it.

`TurnLoop` currently handles responsibilities including:

- Deterministic battle resolution
- Network round sequencing
- Commit/reveal
- Entropy generation
- Proof verification
- Spell authorization
- Merkle membership
- Mana certification
- Hand/deck state
- Delayed-spell state
- Scrying encryption exchanges
- Wild magic
- Forced casts
- Movement
- Summons
- Melee
- UI playback callbacks
- State-hash exchange
- Connection-facing forfeits
- Various pieces of per-turn protocol state

This creates an important architectural risk:

> **The code deciding what the game rules mean is also substantially responsible for deciding whether remote input may be trusted.**

Those are especially important concerns to separate in a cryptographically enforced multiplayer game.

---

# 3. The Existing `B-1` Issue Reveals the Missing Abstraction

A normal current-turn peer cast effectively follows this pipeline:

```text
untrusted SpellAsset
        ↓
verify proof
        ↓
derive certified formulas / trajectory / wild magic
        ↓
resolve certified result
```

This is good.

However, certification is currently stored in temporary per-turn structures such as `certifiedPeerFormulas`.

A Mystery spell that fires on a later turn loses that certified representation.

The code can consequently fall back to something equivalent to:

```dart
certFormulas ?? _parsedFormulas(spell)
```

At that point, a delayed remote spell may eventually use the original wire-provided formula rather than the value certified by the proof.

The existing comments correctly characterize this as **desync-safe but not trust-safe**.

The important architectural point is that this is not merely an isolated bug.

It reveals a missing domain abstraction.

---

# 4. Introduce a `CertifiedSpell` / `CertifiedCast` Type

The battle resolver ideally should **never receive an untrusted remote `SpellAsset`**.

Instead:

```text
SpellAsset / WireSpell
        ↓
CastVerifier
        ↓
CertifiedSpell
        ↓
BattleResolver
```

A `CertifiedSpell` or `CertifiedCast` could contain the trusted semantic information derived from successful verification, such as:

- Verified commitment
- Owner
- Simulation duration / T
- Certified formulas
- Certified element sequence
- Supreme tags
- Certified geometry inputs
- Certified mana/cost inputs
- Wild-magic triggers
- Proof/ruleset identity as appropriate

A delayed spell would then store the **certified semantic object**, rather than returning later to the original peer-supplied claim.

This establishes a very useful invariant:

> **Anything capable of altering `BattleState` has already crossed the trust boundary.**

That would eliminate an entire category of potential security mistakes rather than fixing individual instances as they appear.

---

# 5. Separate Protocol Orchestration From Simulation

This is probably the highest-leverage architectural refactor, particularly given the planned mesh architecture.

A desirable eventual structure is:

```text
BattleProtocolDriver
        │
        │ produces authenticated/canonical declarations
        ▼
TurnResolutionInput
        │
        ▼
BattleResolver
        │
        ├── BattleState → BattleState
        └── BattleEvents
```

## `BattleProtocolDriver`

Responsible for:

- Network messages
- Commit/reveal
- Signatures
- Peer identity
- Proof exchange
- Proof verification
- Timeouts
- Protocol violations
- Cheating/forfeit decisions
- Producing validated inputs to the game engine

## `BattleResolver`

Responsible for statements conceptually like:

> Wizard A moves here.  
> Wizard B casts certified spell X at tile Y.  
> Joint entropy is Z.

It should know as little as practical about:

- Sockets
- TCP
- mDNS
- Message framing
- Signatures
- Who the "local" player is

Ideally it receives deterministic inputs and deterministically transforms state.

---

# 6. This Separation Naturally Supports N-Player Battles

The current two-player architecture naturally contains concepts equivalent to:

```text
myAction
peerAction
```

This becomes increasingly awkward when extended to mesh multiplayer.

The deterministic resolver should eventually think more naturally in terms of:

```text
Map<PlayerId, ResolvedAction>
```

or an equivalent collection of player declarations.

This allows networking topology and battle semantics to evolve separately.

The existing `MESH_ARCHITECTURE.md` already points toward this design. The implementation has now reached the stage where adopting that separation would likely pay for itself.

---

# 7. Consensus-Relevant State Exists Outside `BattleState`

`BattleState.toCanonicalBytes()` is treated as the lockstep consensus state, which is a good architectural choice.

However, `TurnLoop` also maintains mutable state capable of affecting later deterministic behavior, including things such as:

- `_drawSchedules`
- `_drawSeedNonce`
- `_seenPeerCommitments`
- `_ripplingNonce`
- `_componentStartSeat`
- Revealed hand positions
- Various pending protocol fields

Some of these are legitimately private or transient.

Some are publicly reconstructible.

Some are deliberately excluded from hashing.

The architectural danger is **latent divergence**:

> Two clients can theoretically possess identical `BattleState` hashes while differing in some secondary state that influences a later turn.

The current architecture therefore relies on the proposition that every excluded field is either irrelevant to future deterministic behavior or is deterministically reconstructed and updated identically.

The test suite provides substantial protection here, but the architecture makes the property harder to reason about than necessary.

A useful eventual distinction would be:

```text
ConsensusGameState
ConsensusSessionState
LocalPrivateState
PresentationState
```

Even if only some of those participate directly in the consensus hash/transcript.

The benefit is conceptual clarity: whether a field can cause desynchronization becomes much easier to determine from where it lives.

---

# 8. Networking Infrastructure Is Becoming Too Duplicated

There are currently several separate frame-reader implementations, including:

- `FrameReader`
- `BattleFrameReader`
- `TradeFrameReader`
- `SyncArtFrameReader`
- `ApprenticeFrameReader`

There are also several protocol-specific session implementations built around them.

Some comments explicitly describe one reader as effectively identical to another.

The repository's history demonstrates why this matters: the same class of **broadcast-stream / lost-frame bug** has appeared across multiple protocols.

That is a strong signal that this duplication is no longer harmless.

---

# 9. Introduce One Shared Framed Connection Primitive

A deliberately boring, heavily tested networking primitive would reduce risk:

```text
FramedConnection

receive(type)
receiveAny(types)
send(type, payload)
close()
```

It should centrally handle:

- Message framing
- Queuing
- Early-arriving messages
- Maximum frame size
- Decode failures
- Disconnect propagation
- Ordering guarantees
- Possibly protocol namespace/version information

Trade, Apprentice, Sync Art, and Battle should continue to have separate **protocol semantics**.

They simply should not independently implement basic TCP framing and buffering.

This also creates a natural substrate for the signed message envelope required by the future mesh architecture.

---

# 10. The Existing `Transport` Abstraction Has Been Successful

The `Transport` abstraction was a good early decision.

It allowed protocol logic to be tested in memory and isolated LAN socket behavior behind an interface.

However, the interface now contains an historical mismatch.

Conceptually it exposes:

```dart
abstract class Transport {
  advertise();
  discover();
  connect(peerId);
  send();
  onReceive;
  disconnect();
}
```

while `LanSocketTransport` represents an **already-connected one-peer socket**, making operations such as `advertise`, `discover`, and `connect` deliberate no-ops.

That indicates the implementation now contains two distinct concepts:

```text
PeerDiscovery / Listener
         ↓
DuplexPeerLink
```

For mesh networking, splitting these concepts would likely be cleaner than continuing to stretch `Transport`.

A mesh/network coordinator can then own multiple `DuplexPeerLink` instances.

This makes the type system reflect what the implementation is already actually doing.

---

# 11. There Is a Coarse Module Dependency Cycle

Most high-level module dependencies appear healthy.

In particular, the mathematical/CA engine remains comparatively isolated, which is valuable.

One notable cycle exists approximately as:

```text
battle ↔ spells
```

Battle naturally consumes concepts such as `SpellAsset` and permissions.

Meanwhile parts of `spells`, including areas such as recipe-book and wild-magic preview functionality, import battle-domain concepts such as:

- `EffectKind`
- `CreatureSpec`
- `ParsedFormula`
- Wild-magic types

This could eventually be broken by extracting shared game vocabulary into a lower-level domain/rules package:

```text
domain/
    formula
    effect_kind
    creature_spec
    wild_magic_definition
```

Then:

```text
spells ──→ domain ←── battle
```

This is not an urgent refactor, but the cycle will become progressively more expensive as both systems grow.

---

# 12. Persistence Is Appropriate for the Prototype but Increasingly Coupled

Several domain objects currently perform their own persistence through patterns such as:

```dart
SpellAsset.loadAll()
spell.save()
ChapterAsset.loadAll()
Identity.loadOrCreate()
SpellPermission.loadAll()
```

This is pleasantly simple for a local-only game and was a reasonable design choice.

As orchestration grows, however, application logic increasingly performs global/static storage operations.

That makes several future tasks harder:

- Transactional operations
- Import/restore validation
- Alternate storage backends
- Migration testing
- Fully isolated application tests

There is no need for an elaborate database/repository architecture.

Small interfaces would probably be sufficient:

```text
SpellLibrary
ChapterLibrary
PermissionStore
IdentityStore
```

Production implementations can use filesystem/secure storage.

Tests can use in-memory implementations.

This would also consolidate storage and migration policy rather than distributing it among domain models.

---

# 13. UI Complexity Is the Other Major Concentration Point

Several UI files have become very large.

Examples include approximately:

- `battle_screen.dart`: ~6,475 lines
- `library_screen.dart`: ~3,500 lines
- `main.dart`: ~1,755 lines

Again, file size alone is not the issue.

`BattleScreen` currently appears responsible for a mixture of:

- UI rendering
- Network lifecycle
- `TurnLoop` initialization
- Microphone capture
- Gesture capture
- Audio
- Animations
- Spell selection
- Stall detection
- Match completion
- Sightings persistence
- Numerous dialogs and interaction states

There is little value in decomposing widgets merely to reduce line counts.

However, **application orchestration should probably leave `BattleScreen`.**

A useful structure could be:

```text
BattleController / BattleCoordinator
             │
        BattleScreen
```

The controller/coordinator owns battle lifecycle and interaction with `TurnLoop`.

The screen owns Flutter presentation state and animation.

This is especially useful before introducing substantially different battle modes such as real-time/Sorcerer behavior.

Otherwise `BattleScreen` risks becoming the UI equivalent of `TurnLoop`.

---

# 14. Concrete Versioning Inconsistency

There is one issue worth fixing independently of larger architectural work.

The production Noir circuit currently uses:

```text
RULESET_VERSION = 3
```

and inscription uses:

```text
kRulesetVersionHex = 0x3
```

However:

```dart
MatchConfig({
  ...
  this.rulesetVersion = 2,
})
```

still defaults to **2**.

More importantly, `ProofIntake` parses the proof's `rulesetVersion`, but `_verifyPeerSpellCast()` does not appear to enforce:

```text
outputs.rulesetVersion
```

against:

```text
state.config.rulesetVersion
```

Consequently, the negotiated ruleset field is not currently enforcing exactly what its name suggests.

Existing verification-key and battle-protocol-version checks may prevent this from being directly exploitable between normal current clients, but this is precisely the sort of cross-layer version drift that explicit version negotiation is intended to prevent.

A better invariant would be:

```text
proof.rulesetVersion
    ==
match.rulesetVersion
    ==
supportedRulesetVersion
```

before a spell can become certified.

The ruleset version should ideally have one canonical definition rather than parallel constants/defaults scattered through the circuit, inscription, and battle layers.

---

# 15. Recommended Refactor Sequence

I would **not pause development for a large architectural rewrite**.

The game is now generating useful playtest information, and continuing to learn about the actual game is more valuable than pursuing architectural purity.

Instead, establish a boundary around further complexity.

## Priority 1 — Correctness and trust

Fix immediately:

1. The ruleset-version mismatch/enforcement issue.
2. The delayed-spell `B-1` certified-data hole.

These are correctness/trust issues rather than code-quality issues.

## Priority 2 — Establish the trust boundary as a type

Introduce:

```text
CertifiedSpell
```

or:

```text
CertifiedCast
```

Proof validation produces this object.

Battle resolution consumes it.

Remote `SpellAsset` data should not directly reach authoritative battle resolution.

## Priority 3 — Separate deterministic resolution from network exchange

Begin extracting:

```text
exchange
    ↓
validate
    ↓
resolve
```

from `TurnLoop`.

There is no need to immediately break every battle effect into separate classes.

Simply making deterministic game resolution independently callable would produce substantial architectural benefit.

## Priority 4 — Consolidate frame handling

Before adding another P2P protocol, replace duplicated frame readers with one tested framing/queueing primitive.

This addresses a demonstrated recurring bug class.

## Priority 5 — Generalize player representation when mesh work begins

Do not prematurely rebuild the current duel implementation around six-player networking.

But immediately before implementing mesh, replace deeply encoded:

```text
local + peer
```

assumptions with player-indexed structures such as:

```text
Map<PlayerId, ...>
```

where appropriate.

## Priority 6 — Incremental cleanup

Allow UI, persistence, and module-dependency improvements to happen incrementally as related features are touched.

They do not currently justify stopping feature development.

---

# 16. Architectural Direction

The most promising target architecture is based on a simple pipeline:

```text
UNTRUSTED WORLD
      │
      │ wire messages / peer spell claims
      ▼
Protocol + Cryptographic Verification
      │
      │
      ▼
Certified Actions
      │
════════════════════════════════
        TRUST BOUNDARY
════════════════════════════════
      │
      ▼
Deterministic Battle Resolver
      │
      ▼
Consensus State + Battle Events
```

This architecture maps particularly well onto Runewright because the game's core design already distinguishes between:

- Hidden player knowledge
- Public commitments
- Cryptographic proofs
- Deterministic rules
- Peer-to-peer communication
- Shared consensus

Making those distinctions equally explicit in the software architecture would reduce both ordinary bugs and security reasoning complexity.

---

# Conclusion

Runewright does **not** appear to have a foundational architecture problem.

Several of its original seams are strong:

- Dart CA oracle vs. Noir circuit
- Narrow Rust/FFI boundary
- Pluggable networking transport
- Explicit identity
- Canonical state serialization
- Golden-vector testing
- Attack-oriented tests
- Hardware verification gates

Those choices have allowed the project to become significantly more sophisticated without collapsing into an unstructured system.

The main architectural warning is now straightforward:

> **Do not add substantially more responsibility to `TurnLoop`.**

It has crossed the point where centralization is buying simplicity.

As more mechanics are added, it becomes increasingly difficult to tell whether a change belongs to:

- Game rules
- Consensus rules
- Network protocol
- Cryptographic trust validation
- Local presentation/orchestration

Those distinctions matter more in Runewright than they would in an ordinary game.

The highest-value architectural milestone is therefore:

> **Untrusted declaration → certified action → deterministic resolution**

That refactor has an unusually good payoff because it would simultaneously:

1. Clean up the largest architectural concentration.
2. Establish a much clearer security boundary.
3. Close the known delayed-spell trust problem structurally.
4. Make deterministic battle logic easier to test.
5. Prepare the battle engine for N-player operation.
6. Align the implementation with the existing mesh architecture design.

That is the direction I would use for the next significant architectural iteration rather than pursuing a broad rewrite.