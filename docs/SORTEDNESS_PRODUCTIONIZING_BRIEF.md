# Sortedness-Circuit Productionizing Brief

*Proposed 2026-07-23. Turns the GO'd measurement spike
(`SORTEDNESS_CIRCUIT_SPIKE.md`) into a shipped enforcement path: one real
circuit + VK, wired into chapter creation and duel setup, that upgrades the
in-hand check from **interim soft** (already live — `SPELL_DRAW_WIRING_PLAN.md
§6`, `turn_loop.dart` step 3a) to **hard**. The Dart wiring it enforces against
(`DrawSchedule`, `leafIndex`, `cast_out_of_hand`) is done; this is the crypto
layer that makes it un-riggable. §8 lists the decisions that need Soren.*

---

## 1. What "productionize" means here

The spike left four throwaway measurement crates
(`circuits/book_sortedness_n{32,48,64}`, `_pin`) whose only job was a `bb gates`
number. Productionizing replaces them with:

1. **One production circuit** (with a chosen chapter-size story — §2) + its
   pinned VK(s), bundled with the app like the CA tier VKs.
2. **Chapter-creation integration** — prove once when a chapter is built/edited,
   persist the proof with the chapter asset.
3. **Handshake + duel-setup integration** — carry the proof, verify a peer's
   chapter is well-formed before trusting the in-hand check.
4. **The soft→hard flip** — a consensus-visible rule change, versioned.

It does **not** touch the draw/enforcement Dart logic — that shipped with the
wiring and already runs against `leafIndex`. This brief is purely the "make the
peer's tree provably sorted" layer §7 promised.

---

## 2. DECISION — chapter-size handling (the central circuit-design call)

A Noir circuit is fixed-size; the book Merkle tree's shape depends on the leaf
count `k`. The circuit reconstructs `peerBookRoot`, so it must agree with
`BookCommitment.computeRoot` on exactly how many leaves and what padding. Three
ways to reconcile a fixed circuit with variable chapter sizes:

- **A. Exact fixed size.** Every chapter is exactly `N` spells; one circuit.
  Simplest crypto, rigid game constraint (no deckbuilding flexibility). Likely
  too rigid.
- **B. Size tiers + pad-to-tier (recommended).** A small set of chapter-size
  tiers (the measurement crates already *are* this: 32/48/64); pick the smallest
  tier ≥ `k`; pad the chapter up to the tier size with a **max-value sentinel
  leaf** (`0xFF…FF`) that sorts last, and publish the real count `k`. The circuit
  proves the first `k` leaves are real + strictly ascending and the rest are the
  sentinel, then reconstructs the tier-`N` root. `DrawSchedule` already takes a
  `chapterSize` — it just uses `k`, ignoring sentinel positions `[k, N)`.
  Matches the CA tier idiom (`tier_max ∈ {12,24,48}`, handshake picks the
  smallest covering tier — CLAUDE.md invariant 6) and the tier-negotiation
  machinery already exists.
  **Cost:** `BookCommitment.computeRoot` must change to pad to the tier size
  before hashing — a commitment-scheme change (re-run the `_pin` parity check
  and regenerate any committed roots after it).
- **C. Variable `k` in one circuit.** Awkward in Noir (level count varies with
  `k`); reconstructing an arbitrary-`k` odd-level-zero-padded tree under a fixed
  loop bound is the messy path. Rejected unless B's padding proves unworkable.

**Recommendation: B.** Fewest surprises, reuses the tier pattern, keeps the
circuit the exact shape the spike measured. Confirm the tier set (32/48/64, or a
trimmed {48} if one size suffices) with the game-design chapter-size cap from
`SPELL_DRAW_WIRING_PLAN.md §7` (N≤48 stays in CA tier-12's proving bucket).

---

## 3. The production circuit

- Fold `book_sortedness_n*` into one crate parameterized by the tier `N` (or keep
  per-tier crates if that's simpler to build — the CA circuits are per-tier
  crates, so that's in-idiom). Public inputs: `root` (hi/lo) and `k` (real leaf
  count); private: the `N` padded leaves.
- Constraints, extending the spike's two: (1) leaves `[0,k)` strictly ascending;
  (2) leaves `[k,N)` all equal the sentinel; (3) root reconstruction over `N`
  leaves == `root`. The `k` boundary must itself be constrained (a `k` the prover
  can move would let it hide a real leaf as a "sentinel").
- Keep the hand-rolled two-block SHA-256 from the spike (beta.20 has no
  byte-oriented `std::hash::sha256`); the `_pin` crate stays as the parity guard
  and should be kept/committed as a regression test for it.

---

## 4. Chapter-creation integration

- **Where:** the inscribe/library flow, when a chapter is created or its spell
  set changes. Off the gameplay path — proving latency doesn't affect a duel.
- **Persist** the proof (and the tier/`k`) alongside the chapter asset so it's
  reused every match without re-proving.
- **On-device proving time — measure here.** The spike deferred this (only a
  desktop `bb gates`). This is the M2-style on-device run: confirm chapter-build
  proving is acceptable on a ≥4 GB phone. Bucket parity with CA tier-12/24
  (8.9 s / 16.9 s in the M2 spike) is the expected proxy, but confirm.

---

## 5. Handshake + duel-setup verification

- **Carry** the sortedness proof at handshake next to `peerBookRoot` and the leaf
  count (the count field the wiring already added — `battle_wire.dart`,
  `duel_setup.dart`). The **VK is bundled per tier** with the app (like the CA
  VKs, M3 bundled-VK path), not sent per-match — only the proof crosses the wire.
- **Verify** in duel setup with `verify_ultra_honk` against `peerBookRoot` + the
  bundled VK, **before** the first turn's in-hand check is trusted. Traps:
  - Pure-verify path must init the SRS/CRS first (`initSrsCached`) — CLAUDE.md
    Bug-Avoidance #4 / M4.6.
  - Don't oversize the SRS for the bundled-VK path — Bug-Avoidance #2 / M3.
- **On a missing/invalid proof:** decision in §8 — reject the match, or fall back
  to today's soft enforcement for that peer.

---

## 6. Versioning & backward-compat

- New VK(s) + the soft→hard rule flip are **consensus-visible**. Settle whether
  this rides `RULESET_VERSION` (currently CA-rule-scoped) or a sibling
  protocol-version field; either way both clients must agree they're enforcing
  hard. Nothing has shipped, so the bump is cheap — do it cleanly now.
- Under option B, existing chapter assets need a one-time **re-commit** (re-pad →
  new `peerBookRoot`) **and** a first-time **prove**. Since membership proofs
  also key off `peerBookRoot`, the re-pad must land atomically with the circuit.

---

## 7. Vectors & tests

- Carry over the spike's positive + N1/N2/N3 negatives.
- **Close the spike's coverage gap:** add vectors with **high-half-differing and
  realistic (random-looking) leaves** — the spike's small-integer leaves all have
  `hi = 0`, so the `leaf_lt` high-half branch is untested (`SPELL_DRAW_WIRING_
  PLAN.md §11`).
- **Option-B-specific negatives:** a real leaf disguised as a sentinel; a `k`
  that under- or over-counts the real leaves; a sentinel that isn't the canonical
  max value. Each must fail.
- **Integration test:** a duel-setup path that rejects (or soft-falls-back on) a
  peer whose chapter carries no valid sortedness proof, and accepts one that does
  — the end-to-end analogue of the wiring's `cast_out_of_hand` test.

---

## 8. Decisions for Soren

1. **§2 chapter-size handling:** exact-N / size-tiers+pad / variable-k.
   *Recommend size-tiers + pad-to-tier (B).* Also fix the tier set (or single
   size) given the ≤48 proving-bucket sweet spot.
2. **§5 missing-proof policy:** hard-reject a peer with no valid sortedness proof,
   or soft-fall-back to today's honest-client check for that match? *Recommend
   hard-reject once shipped* (soft is the pre-ship interim), but it affects
   cross-version play.
3. **§6 versioning field:** `RULESET_VERSION` vs a protocol-version sibling.
4. **Sequencing:** the Dart wiring is done and the interim soft check is live, so
   this is a clean, non-blocking upgrade — schedule it whenever the enforcement
   guarantee is wanted, after an on-device proving-time confirmation (§4).

---

## 9. Out of scope

- The draw/enforcement Dart logic — done (`DrawSchedule`, `_advanceDrawState`,
  the §6 check).
- Per-cast or per-draw proving — still explicitly rejected; this proves once per
  chapter.
- The two open wiring findings (turn-1 no-cast timing; per-draw seed nonce for a
  hypothetical multi-draw effect) — those are `SPELL_DRAW_WIRING_PLAN` concerns,
  not this circuit's.
