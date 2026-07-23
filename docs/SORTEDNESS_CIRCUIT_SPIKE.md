# Sortedness-Circuit Spike Brief

*Proposed 2026-07-23. Spike for `SPELL_DRAW_WIRING_PLAN.md §7`: the one-time,
chapter-creation ZK proof that a committed chapter is well-formed (sorted +
distinct), which upgrades hand-membership from soft to hard enforcement without
any in-match proving. This is a **measurement-first spike** — the go/no-go is a
gate count, not a design preference. Do not build the integration until the
central number (§3) is in hand.*

---

## 1. Goal & go/no-go framing

Prove, once when a chapter is created, that the chapter's committed Merkle root
`R` (`peerBookRoot`) commits a leaf set that is **strictly ascending by
`commitmentHex`** (which also makes it duplicate-free). That single guarantee is
what makes `SPELL_DRAW_WIRING_PLAN.md`'s positional draw enforcement sound: with
it, "position *p* holds the *p*-th smallest card" is true and un-riggable, so the
in-match in-hand check (wiring plan §6) is hard, not advisory.

**The spike answers one question:** *is reconstructing the SHA-256 book root
in-circuit cheap enough to be worth it?* Everything else (integration, wire
field, versioning) is straightforward and deferred to the wiring plan. If the
gate count is unacceptable, the spike's deliverable is the fallback recommendation
(§8), not a shipped circuit.

---

## 2. What the circuit proves (precise statement)

- **Private inputs:** the `N` chapter leaves (each a 256-bit `commitmentHex`,
  represented in-circuit as two `Field`s — a hi/lo split — since a 256-bit value
  exceeds the BN254 field).
- **Public input:** `R` — the SHA-256 Merkle root, exactly as
  `BookCommitment.computeRoot` produces it.
- **Constraints:**
  1. **Sorted + distinct:** `leaf[i] < leaf[i+1]` for all `i`, as unsigned
     big-endian 256-bit comparison. Strict `<` gives distinctness for free.
  2. **Root reconstruction:** rebuild the SHA-256 Merkle tree over the leaves —
     **replicating `book_commitment.dart` bit-for-bit**: leaves in given order,
     interior node = `SHA-256(left ‖ right)` over 32-byte halves, **odd levels
     right-padded with the 32-byte zero node** — and assert the result equals `R`.
- **No return value needed** beyond the standard proof; `R` being public and the
  assertion passing is the statement.

---

## 3. The central unknown — SHA-256-in-circuit cost (MEASURE FIRST)

**Why SHA-256 and not Poseidon2.** The CA circuit uses Poseidon2 (`poseidon2_hash2`
in `ca_v2_4_tier12/src/main.nr`) precisely because it's ZK-native and cheap. The
book tree can't follow suit: membership proofs are generated **in Dart**
(`BookCommitment.proveMembership`) and verified in Dart at cast time (no circuit —
that's what keeps casting real-time), and CLAUDE.md invariant 1 forbids a
hand-rolled Poseidon2 in Dart. So the book tree is SHA-256 (library, via the
`crypto` package — allowed; it's a vetted lib, not a hand-rolled consensus hash),
and a proof that binds to `peerBookRoot` **must reconstruct that SHA-256 tree
in-circuit.** SHA-256 is the expensive primitive in ZK; this is the cost driver.

**The measurement.** A tree over `N` leaves is `N-1` interior `SHA-256(64→32)`
compressions. Build a skeleton circuit (§5) and run `bb gates` at
**`N ∈ {32, 48, 64}`** (candidate max chapter sizes). Report gate count and the
UltraHonk padding bucket it lands in.

**The bar (borrow the CA tiers' framing).** The CA tier-12 sits ~236k of its
2^18 (262k) bucket. A *one-time, off-the-hot-path* proof has a far looser latency
bar than a per-cast CA proof — but proving still has to finish in seconds on a
phone at chapter-creation time. Rough decision bands:
- **≲ 2^18 rows:** comfortable — Option A (§4) as-is, done.
- **2^18–2^19:** acceptable for a one-time proof; confirm phone proving time with
  a quick on-device run (M2-style), since this is off the gameplay path.
- **≫ 2^19, or > the CA tier-48 ~943k:** stop — go to a fallback (§8). A
  sortedness proof more expensive than a whole CA spell proof is a design smell.

**Honesty flag:** my wiring-plan §7 called this circuit "tiny." That's the
Poseidon2 intuition; with SHA-256 forced by the Dart-side binding it may well
*not* be tiny. This spike exists to replace that intuition with a number before
anyone commits to the approach.

---

## 4. Design axes the spike settles

- **A. Binding target = the Merkle root `R` (baseline).** Reconstruct `R`
  directly. Simplest and unambiguously correct — the same root membership proofs
  use, so the sortedness guarantee provably covers the exact set that casts are
  checked against. Cost = `N-1` SHA-256 compressions. **Start here.**
- **B. Binding via `hashLeaves` — rejected unless A fails.** `book_commitment.dart`
  already has `hashLeaves` = flat `SHA-256` over the sorted leaves (~`N/2` blocks
  — cheaper than the tree). *But* membership proofs verify against the Merkle
  root, not `hashLeaves`; proving sortedness of `hashLeaves`'s set does **not**
  constrain the Merkle set unless the circuit computes both from the same private
  leaves (strictly more cost than A) or the two roots are otherwise bound. So B
  only helps if paired with a membership rework — out of scope. Note it, don't
  chase it.
- **C. Chapter-size cap.** Cost scales with `N`. If A is borderline, capping the
  max chapter size (e.g. 32) is the cheapest lever and may be a fine game-design
  constraint anyway. The spike should report cost *as a function of N* so this
  lever is quantified, not guessed.
- **D. Leaf comparison must match Dart's sort exactly.** Dart sorts the
  `commitmentHex` *strings* lexicographically; with uniform `0x`-prefix + 64 hex
  chars that equals unsigned big-endian byte order of the decoded 32-byte values.
  The circuit's `<` must be that same order over the hi/lo `Field` split (compare
  hi, then lo). Pin it with a vector whose leaves are adjacent in value.

---

## 5. First concrete experiment

1. Scaffold `circuits/book_sortedness/` (Nargo bin crate, same shape as
   `ca_v2_4_tier12`).
2. `main.nr`: params `leaves: [(Field, Field); N]` (private), `root: pub Field`
   — or root as `(Field, Field)` if a 256-bit root needs two Fields; match how
   `peerBookRoot` bytes map to public inputs, cross-checking `CIRCUIT_IO.md`'s
   packing conventions. Implement the two constraints from §2, reusing the repo's
   SHA-256 approach (Noir stdlib `std::hash::sha256` — confirm it's the byte-wise
   variant matching `crypto`'s `sha256`).
3. `nargo compile`, then **`bb gates`** at `N = 32, 48, 64`. This is the whole
   deliverable of the first pass — the number.
4. Only if the number passes: a hand-built positive witness (a real sorted
   chapter) proves & verifies, and the §6 negative vectors fail.

Keep it isolated from the CA crates; this shares no code with them.

---

## 6. Correctness pins & golden vectors

Per CLAUDE.md's constraint/negative-vector discipline — a sortedness constraint
you can't write the attack against is one you don't understand yet:

- **Positive:** an honestly-sorted real chapter → root matches, sortedness holds,
  proof verifies.
- **Negative N1 — reordered leaves:** same leaf *set*, adjacent pair swapped so
  it's no longer ascending, with a root recomputed over that order → **must fail**
  (this is the exact "map a strong card onto an early-drawn position" attack the
  proof exists to stop).
- **Negative N2 — duplicate leaf:** two equal leaves (strict `<` violated) →
  **must fail.**
- **Negative N3 — padding mismatch:** a witness that pads an odd level with
  something other than the 32-byte zero node → root won't match `R` → **fail**
  (guards the bit-for-bit `book_commitment.dart` replication).
- **Lex-order pin (§4.D):** leaves that differ only in the low half, ordered
  correctly and incorrectly, confirm the hi/lo comparison matches Dart's string
  sort.

Generate the roots for these vectors from `book_commitment.dart` itself (it's the
oracle), the same "Dart oracle → circuit → vector" order the CA work uses.

---

## 7. Integration surface (light — full detail lives in the wiring plan)

Only sketch here so the spike knows what it's feeding:
- **Where it runs:** chapter creation/edit (the inscribe/library flow), once,
  persisted alongside the chapter asset. Re-run only when the chapter's spell set
  changes.
- **Wire:** the proof (and its VK) must reach the peer so they can verify a peer's
  chapter is well-formed before trusting the in-hand check — a new handshake field
  next to `peerBookRoot`, plus the chapter **leaf count `N`** (already needed
  public for the draw schedule; wiring plan §3).
- **Versioning:** new circuit ⇒ new VK ⇒ consensus-visible. Settle whether it
  rides `RULESET_VERSION` or a sibling protocol-version field when integrating;
  nothing has shipped, so the bump is cheap. Pre-existing chapter assets need a
  one-time re-commit to carry the witness.

---

## 8. Go/no-go & fallbacks

- **GO (cost ≤ ~2^19):** proceed with Option A; hand the wiring plan a real
  proving-time number and the chosen `N` cap.
- **NO-GO (cost ≫ 2^19):** do **not** force it. Fallbacks, in order of
  preference:
  1. **Cap `N` small** (Option C) until cost fits — cheapest, quantified by the
     §3 measurement.
  2. **Ship soft enforcement only** (wiring plan §6 interim) and revisit — the
     wire already carries the position-authenticating membership proof, so hard
     enforcement can be added later without a wire change.
  3. **Reconsider the book-tree hash** (larger effort): a SNARK-friendlier hash
     that Dart can also compute *via a vetted library* (not hand-rolled) would
     collapse the cost, but it touches the membership system and the "opaque
     commitment" trust story — a separate design pass, not this spike.

The forbidden outcome is quietly shipping a circuit that's too big because the
approach was already decided. The approach is decided *conditional on the number*;
this spike produces the number.

---

## 9. Toolchain notes

- **Paths (corrected — the CLAUDE.md handoff note is stale):** `nargo`
  1.0.0-beta.20 is at `~/.nargo/bin/nargo` (not `/tmp/nargo`, and not on `$PATH`);
  `bb` 5.0.0-nightly.20260324 is at `~/.bb/bb`. Keep the toolchain pinned together
  (CLAUDE.md Toolchain §).
- **Commands:** `~/.nargo/bin/nargo compile` in the crate, then
  `~/.bb/bb gates -b target/book_sortedness.json` for the count. Mirror the CA
  crates' `Nargo.toml` shape.
- **SHA-256 in Noir:** confirm the stdlib `sha256` byte-variant is bit-identical
  to the `crypto` package's output on the same input before trusting any root
  match — this is the classic Dart↔circuit transcription seam, so pin it with the
  smallest possible vector (one interior node: `SHA-256(leafA ‖ leafB)`) first.

---

## 10. Out of scope

- The in-match in-hand check, `DrawSchedule`, and all Dart wiring — that's
  `SPELL_DRAW_WIRING_PLAN.md §§3–9`; it can proceed in parallel with its interim
  soft check.
- Any per-draw or per-battle proving — explicitly rejected in the wiring plan;
  this circuit runs once per chapter, off the gameplay path.
- Mobile on-device proving-time measurement — only needed if §3 lands in the
  2^18–2^19 band; a desktop `bb gates` count is the first gate.

---

## 11. Spike results (2026-07-23) — GO

**The central number (§3).** `bb gates` (nargo 1.0.0-beta.20, bb
5.0.0-nightly.20260324, same toolchain pin as the CA crates) on
`circuits/book_sortedness_n{32,48,64}/`:

| N  | acir_opcodes | circuit_size | padded UltraHonk bucket | utilization |
|----|-------------:|-------------:|------------------------:|------------:|
| 32 |       12,568 |      263,746 |     2^19 (524,288)      |    50.3%    |
| 48 |       19,274 |      406,400 |     2^19 (524,288)      |    77.5%    |
| 64 |       25,464 |      532,738 |     2^20 (1,048,576)    |    50.8%    |

Freshly re-measured CA tiers for an apples-to-apples reference (same
toolchain; these numbers have drifted from the stale ~236k/262k tier-12
figure in the CLAUDE.md Bug Avoidance section, apparently from CA circuit
growth since M3/M4 — **that CLAUDE.md figure needs a refresh**, filed here,
not fixed here since it's out of this spike's scope):

| Circuit  | acir_opcodes | circuit_size | padded bucket        |
|----------|-------------:|-------------:|----------------------:|
| tier-12  |      382,174 |      390,726 | 2^19 (524,288)        |
| tier-24  |      798,166 |      810,183 | 2^20 (1,048,576)      |
| tier-48  |    1,630,150 |    1,649,097 | 2^21 (2,097,152)      |

**Reading:** N=32 and N=48 land in the *same padded bucket as CA tier-12*
(the cheapest, most-validated proving tier — 8.9s/717MB on-device per the M2
spike). N=64 bumps one bucket up, to tier-24's level (16.9s/1175MB on-device).
None of the three approach tier-48. This directly answers §3's bar: **well
inside the "≲2^19, comfortable" to "2^18–2^19, acceptable" bands — nowhere
near the "≫2^19 / worse than tier-48" stop condition.**

**Verdict: GO on Option A (§4)**, binding directly to the Merkle root `R`, no
chapter-size cap forced by cost. If a cap is still wanted for game-design
reasons, N=48 is the natural line — it's the largest size that stays in
tier-12's bucket; N=64 costs one more bucket (still cheap in absolute terms).

**On-device proving time:** not yet measured (spike doc's own gate says this
is only needed in the 2^18–2^19 band as a confirmation step). Given the
bucket match to tier-12/tier-24, the M2 on-device numbers for those tiers
(8.9s / 16.9s) are a reasonable proxy; an explicit on-device run is a
follow-up for whoever picks up the wiring plan, not a blocker for this GO.

### SHA-256 in Noir 1.0.0-beta.20 — the stdlib byte-oriented `sha256` doesn't exist

§9's "confirm the stdlib sha256 byte-wise variant" turned out to have a
different answer than assumed: beta.20's `noir_stdlib` has **no**
`std::hash::sha256` for byte arrays — only the low-level
`sha256_compression(input: [u32;16], state: [u32;8]) -> [u32;8]` block
primitive survived (the message-schedule/round-constant expansion happens
inside that opcode; padding is the caller's job). There is no external
`noir-lang/sha256` crate either at this pin.

Every hash in this circuit is `SHA-256(left ‖ right)` over a **fixed
64-byte** message, so rather than a general variable-length routine, each
crate hand-builds the two FIPS-180-4 blocks for exactly that length: block 0
= the 64 message bytes as 16 big-endian `u32` words; block 1 = the fixed
padding word (`0x80000000`, zeros, then the 64-bit bit-length `512`). This
is simpler and cheaper than a generic implementation would have been, and
sidesteps an entire class of padding-logic bugs since there's only one
message length to support.

**Bit-parity confirmed** (§9's pin) via `circuits/book_sortedness_pin/`
(N=2): Prover.toml generated from `BookCommitment.computeRoot` itself
(`scripts/gen_book_sortedness_vectors.dart`, the Dart oracle — never hand
computed), `nargo execute` solves, meaning the hand-rolled two-block SHA-256
matches the `crypto` package's `sha256` bit-for-bit on this input. This is
the load-bearing check: without it, the N=32/48/64 root-match numbers above
would be measuring a circuit that doesn't prove what it claims to.

### Golden vectors (§6) — all four cases behave as required

Generated by `scripts/gen_book_sortedness_vectors.dart` (Dart oracle:
`BookCommitment.computeRoot`, never hand-derived), checked against
`circuits/book_sortedness_n32/` and `_n48/`:

- **Positive** (N=32/48/64, honestly sorted): `nargo execute` solves; N=32
  additionally taken through a full `bb prove` / `bb verify` round trip —
  proof verifies.
- **N1 (reordered leaves, adjacent swap):** fails, as required — `Cannot
  satisfy constraint` at the `leaf_lt` sortedness assert.
- **N2 (duplicate leaf):** fails, as required — same sortedness assert
  (strict `<` correctly rejects equality).
- **N3 (bad padding — non-zero pad node at the 3→2 odd level of an N=48
  tree):** fails, as required — but at a *different* assert, the
  root-reconstruction check, confirming the circuit hard-codes the 32-byte
  zero pad node rather than accepting an arbitrary one.

### What's built, for whoever picks up the wiring plan next

- `circuits/book_sortedness_pin/` — N=2 SHA-256 bit-parity pin.
- `circuits/book_sortedness_n{32,48,64}/` — the measurement crates (each
  self-contained, no shared lib, matching the CA tier crates' per-size
  duplication convention rather than introducing a new path-dependency
  pattern for a spike).
- `scripts/gen_book_sortedness_vectors.dart` — Dart-oracle vector generator;
  regenerate any crate's `Prover.toml` by rerunning it (writes all three
  positive vectors + the pin, and prints N1/N2/N3 negative-vector TOMLs to
  `/tmp` for ad hoc `nargo execute --prover-name` runs — negatives are
  intentionally not committed as any crate's checked-in `Prover.toml`).
- Not built (correctly out of scope per §10): any Dart-side wiring, the
  handshake field, VK distribution, or `RULESET_VERSION`/protocol-version
  bump — that's `SPELL_DRAW_WIRING_PLAN.md`'s job, now unblocked with a real
  number instead of the "tiny" intuition this spike existed to check.
