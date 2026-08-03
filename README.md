# Runewright

**A decentralized, in-person wizard-dueling game where your spells are rune flavored 
cellular automata rules and your proofs are the only referee.**

Runewright is a mobile game about being a D&D-style wizard in real life. You *inscribe*
spells by designing the initial state of a hexagonal cellular automaton, generate a
zero-knowledge proof that the simulation ran exactly as you claim, and then duel other
players face-to-face over local wireless.

There is no server, no account, and no central authority. Your opponent never sees your
spell — only a proof that it does what you say it does.

> **Status: pre-release, in active development.** Nothing has shipped yet; the circuits,
> wire protocol, and CA ruleset are still allowed to break. See [Project status](#project-status).

---

## The idea

Most games with secret information need a trusted server to hold the secret. Runewright
doesn't have one, so it uses cryptography instead.

Each spell is the **initial state of a 469-cell hex-grid cellular automaton**. When you
inscribe it, your phone runs the simulation for `T` generations and produces a proof
attesting to:

> *"I know a grid state whose hash is `commitment`, and running it forward for `T`
> generations produces exactly these border activations, this dominance trajectory, and
> these supreme-dominance flags."*

Your opponent verifies the proof on their own phone. They learn the spell's **effects**
and never learn the **pattern that produced them**. Reverse-engineering someone's spell
from its outputs is a genuine puzzle — which is the whole game. Spell designs become
jealously-guarded discoveries, traded, loaned, stolen by shoulder-surfing, and passed
down from master to apprentice.

Three design commitments fall out of that:

- **Cheating on spell output is mathematically implausible**, not merely discouraged.
- **Mystique is structural.** Because nobody can see anybody's spellbook, rumor and
  folklore about what's possible emerge on their own.
- **Zero ongoing infrastructure.** Free, ad-free, no microtransactions, no data
  harvesting, no server to shut down.

---

## How a spell works

### The rune grid

A vertex-down hexagonal grid in axial `(q, r)` coordinates, 13 rings deep:

| Region | Rings (radius) | Cells | Role |
|---|---|---|---|
| Inscribable | 0–8 | 217 | where you draw |
| Buffer | 9–11 | 180 | simulates, but starts empty and can't be inscribed |
| Border | 12 | 72 | activations are *counted*, then the cell immediately clears |
| **Total** | **0–12** | **469** | the grid the circuit is built on |

The border ring is partitioned into four 18-cell elemental zones — water, air, fire,
earth — so *where* your pattern reaches the edge determines which element it feeds.

Cells have exactly two states: inactive (0) and active (1). All of the variety comes from
the rule system, not from cell types.

### The ink substrate and dominance

The CA runs on a neutral "ink" substrate with a small set of birth/survival rules, plus a
**dominance system**: each generation, pressure from the four elements — fire, air, water,
earth — is tallied, and the element in the lead *changes the rules for the next
generation*. Sustained control produces **supreme dominance**. The sequence of dominant
elements across generations is the spell's **trajectory**, and the trajectory is what gets
compiled into a **formula** — the actual battlefield effect.

So spell design is an inverse problem: you want a particular effect, which means you want
a particular trajectory, which means you have to find a starting pattern that produces it.

### Proof tiers

Noir arrays are compile-time sized, so `T` can't be a free variable. Runewright ships
three circuit tiers and the match handshake picks the smallest one covering the declared
`T`. Measured on a Pixel 6 (median of 3 warm runs):

| Tier (`tier_max`) | ACIR opcodes | Padded bucket | Warm prove | Full inscription | Peak RSS |
|---|---|---|---|---|---|
| 12 | ~388k | 2^19 | ~12.7 s | ~15.8 s | ~1 GB |
| 24 | ~808k | 2^20 | ~24.5 s | ~31.5 s | ~2.1 GB |
| 48 | ~1.65M | 2^21 | ~48.9 s | ~62 s | ~4.3 GB |

Tier 12 is the everyday tier. Tier 48 is the opt-in virtuoso tier — deliberately weighty
to inscribe, gated at the handshake to devices with enough RAM.

---

## Cryptography

| Piece | Choice |
|---|---|
| Proof system | [Noir](https://noir-lang.org/) + Barretenberg, UltraHonk |
| In-circuit hash | Poseidon2 (BN254) — Noir stdlib only, **never reimplemented client-side** |
| Signatures | Ed25519, entirely **off**-circuit |
| Effect hashing | SHA-256, standard Dart `crypto` |
| On-device proving | `zkpassport/noir_rs` via `flutter_rust_bridge` |

A few load-bearing decisions:

- **`commitment = Poseidon2(packed_grid)` — grid only.** `T`, the owner key, and the
  ruleset version are separate public inputs. This is what makes counter-charms work:
  the same starting grid produces the same commitment no matter who inscribed it or how
  many generations they ran, so a counter-charm fires against every variant of a spell.
- **Owner binding prevents proof replay.** A ZK proof, once transmitted, is a
  self-contained object anyone could re-present. So the proof carries
  `owner_pubkey = Poseidon2(Ed25519 pubkey)` as a public input, and casting requires
  signing a per-match challenge with the matching private key. A stolen proof is useless;
  swapping in your own key would require regenerating the proof, which requires the grid.
- **Every one of the 469 cells is constrained to `{0,1}`.** Under-constrained cells are
  the classic ZK exploit vector, and the negative test corpus exists to prove they aren't.
- **`RULESET_VERSION` (currently 3) bumps on any consensus-visible rule change.** It's a
  deliberate verification-key-breaking mechanism; the handshake negotiates it.
- **Identity is local and self-custodied.** A keypair is generated on first launch and
  stored on-device. There is no recovery backdoor, and the UI says so.

The circuits are open-sourced specifically so this is auditable. The trust model depends
on it — the competitive moat is spell design and community, not secret circuits.

---

## Correctness: the golden vector corpus

The CA is implemented **twice** — once in Dart ([`lib/engine/stepper.dart`](lib/engine/stepper.dart),
which is canonical) and once in Noir. Any disagreement between them is a consensus bug
that would only surface as an unverifiable proof mid-duel.

The corpus is how that's prevented. Vectors are *generated by running the Dart stepper*,
and the circuit must reproduce them byte-for-byte. It runs in CI on every push. Alongside
the positive vectors sits a **negative** corpus: witnesses that a correct circuit must
*reject*. Each security constraint is paired with the attack that breaks it if the
constraint is removed.

**A failing negative vector is a release blocker, full stop.** A faster circuit that
accepts one bad witness is strictly worse than the slow one.

---

## Beyond the crypto core

The proof pipeline is the foundation; the game built on it currently includes:

- **Battle mode** — turn-based duels with lockstep state hashing and commit-reveal
  entropy, so neither client controls the dice.
- **LAN networking** — a pluggable transport layer (`lib/protocol/`) with a TCP socket
  adapter and mDNS discovery. Gate-validated on two real devices: handshake → prove →
  transmit → verify → challenge → signature check, in both directions.
- **Spellbook & library** — persistent local spellbook, spell art packs, heraldic sigils
  generated from your identity key.
- **Master / Apprentice** — cryptographically-scoped spell *loans* that expire without a
  server, and graduation battles on the apprentice's terms.
- **Commune & trade** — deliberate ownership transfer of spells, and scroll-based
  one-shot casting.
- **Wild magic & artifacts** — forced casts, chaotic effects, and rod/bookmark items.
- **Sorcerer mode (scaffolding)** — voice and gesture recognition for casting without
  touching the screen, with an on-device enrollment/practice trainer.

---

## Repository layout

```
lib/engine/        the CA stepper — canonical definition of rule behaviour
lib/spells/        inscription, spell assets, art packs, permissions
lib/battle/        turn loop, effect resolution, battle networking
lib/protocol/      transport interface, LAN sockets, mDNS discovery, wire format
lib/identity/      Ed25519 keypair, onboarding rite
lib/practice/      lib/sorcerer/   voice + gesture recognition
lib/ui/            Flutter screens and painters
circuits/          Noir crates (CA tiers 12/24/48, book-sortedness) + grid ordering spec
ffi/               Rust ↔ Dart proving bridge (noir_rs + flutter_rust_bridge)
test_vectors/      generated golden + negative corpus
scripts/           vector generation, benchmarks, Android FFI build
docs/              design docs, circuit I/O contract, milestone findings logs
```

---

## Building

Requires the Flutter SDK, a Rust toolchain, and pinned versions of `nargo` and `bb`.

```bash
git clone https://github.com/runewright-cloud/runewright.git
cd runewright

bash bootstrap.sh          # installs the pinned Noir/Barretenberg toolchain
bash bootstrap.sh --check  # verify versions without installing

flutter pub get
flutter test               # Dart unit + engine tests
bash scripts/run_vectors.sh  # golden vector corpus (compiles + runs the tier-12 circuit)

flutter run -d linux       # desktop target, fastest way to see the UI
flutter run -d <android>    # the real target
```

**Toolchain pinning is not optional.** The vector corpus is a byte-exact cross-language
contract, and a beta-channel version bump can change witness or commitment output.
`nargo`, `bb`, and the `noir_rs` bridge must move together.

If you change anything under `ffi/src/`, regenerate the bridge and rebuild the Android
`.so` before running on a device — a stale library installs cleanly and then crashes on
launch:

```bash
bash scripts/build_android_ffi.sh
bash scripts/check_ffi_fresh.sh
```

---

## Project status

Milestones M0–M4 are complete: the circuits are built and measured, on-device proving is
validated on real hardware, and a full two-device duel — proof generated, transmitted,
verified, challenged, and signed — has been run end to end.

Active work is on the game layer built above that foundation. The CA ruleset is at
version 3 and still subject to change; **no public release has happened, so
verification-key-breaking changes are still cheap and are being taken deliberately while
they are.**

---

## Documentation

- [`docs/runewright_design_v3_0.md`](docs/runewright_design_v3_0.md) — the game design document
- [`docs/CIRCUIT_IO.md`](docs/CIRCUIT_IO.md) — byte-level circuit ↔ client I/O contract
- [`docs/GOLDEN_VECTORS.md`](docs/GOLDEN_VECTORS.md) — the vector corpus and how it's generated
- [`circuits/GRID_ORDERING_v2.md`](circuits/GRID_ORDERING_v2.md) — canonical cell ordering
- [`docs/MESH_ARCHITECTURE.md`](docs/MESH_ARCHITECTURE.md) — multi-player session topology
- [`docs/PRIVACY_POLICY.md`](docs/PRIVACY_POLICY.md) — short version: nothing leaves your device
- [`CLAUDE.md`](CLAUDE.md) — engineering contract, invariants, and hard-won traps

---

## Licensing

- **Code** — GPL-3.0-or-later ([`LICENSE`](LICENSE))
- **Creative assets** — CC BY-SA 4.0 ([`LICENSE-ASSETS`](LICENSE-ASSETS))
- **Circuits** — open-sourced for auditability; the trust model requires it.

Third-party art, audio, and voice models are credited in [`CREDITS.md`](CREDITS.md).
Attribution for the bundled avatar sprites is a licence condition, not a courtesy.
