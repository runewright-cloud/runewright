# M3 — Review Outcome & Go-Ahead (read alongside M3_brief.md and your M3.0 gap analysis)

Your M3.0 gap analysis is approved, and Step 0 came back clean (zkpassport/noir_rs beta.20 exposes a fully public Rust API, no fork needed, track C ≈ 1 day). Proceed with the M3.1–M3.4 plan as you laid it out, **track C folded in**. The amendments below are decisions from review — apply them; they are not optional. Three of them are **checkpoints**: surface the result and pause for confirmation before continuing past them.

The `IS_BUFFER[i] | IS_BORDER[i]` constants-array check (not `index ≥ 217`) is confirmed correct — that was the right catch. Use it.

## Amendment 1 — Deferred public inputs: commit the binding now (VK stability)

Your analysis is right: VK stability is about gates, not slot presence, so the only way to avoid a verification-key change when the identity layer ships is to commit the final constraint *shape* now with dummy witness values. Decision: **commit it now; do not defer.** Specifically:

- `ruleset_version`: `assert(ruleset_version == RULESET_VERSION)` against a `global RULESET_VERSION: Field`.
- `owner_pubkey`: the full final binding `assert(owner_pubkey == Poseidon2::hash([key_hi, key_lo], 2))`, with `key_hi` and `key_lo` as **private** inputs in `main()` from day one. Interim witnesses use `key_hi = key_lo = 0` and `owner_pubkey = Poseidon2::hash([0,0], 2)`.

Two things that make "stable forever" actually true — without them this amendment is pointless:

- **Lock the exact Poseidon2 invocation as a spec commitment, and make the future identity module conform to it.** The VK is stable only if the gate structure is *identical* later. So the canonical owner-binding construction is being decided today: `Poseidon2::hash([key_hi, key_lo], 2)` — fixed hash variant, fixed arity 2, fixed `[hi, lo]` ordering, **binding only the pubkey and nothing else**. Record this verbatim in the circuit interface spec / `CIRCUIT_IO.md` §5 as the canonical form. If the identity module later binds anything additional (a domain separator, a nonce) or changes arity/ordering, the VK churns and this whole effort is wasted — so the spec note must state that no further inputs may be added to this hash.
- **`RULESET_VERSION` semantics:** pin it to `1` and document that it is the rule-set **epoch** — bumped on any consensus-visible CA rule change, which is an *intended* VK change that makes incompatible rule-sets non-interoperable and prevents replay of old proofs against new rules. This is distinct from the *unintended* churn the `owner_pubkey` lock avoids. State that distinction in the spec so a future rule tweak bumping the version isn't mistaken for a regression.

**Witness-shape propagation (do in the same change as the `main()` signature):** adding `key_hi`/`key_lo` as private inputs changes the witness layout. Update `CIRCUIT_IO.md` §1 (byte-level I/O contract) and the `gen_vectors.dart` / `Prover.toml` witness format to include the two extra private fields immediately — not as a later patch. If the harness is built against the old shape and the circuit against the new one, you get a witness-count mismatch that's tedious to trace.

## Checkpoint A — Confirm §5 is final BEFORE writing the owner_pubkey binding

The VK-stability argument assumes the final owner-binding construction is known now. Before writing that constraint, confirm from `CIRCUIT_IO.md` §5 and the design doc that the in-circuit binding is genuinely finalized as exactly `Poseidon2` over the 2-field-packed pubkey (arity 2, fixed ordering, pubkey only). Note: the still-unconfirmed Ed25519 byte order is *client-side packing* (how the pubkey becomes `key_hi`/`key_lo`) and does **not** affect the in-circuit gate structure, so it does not block the lock. But if the identity design might bind more than the pubkey, or the hash construction itself is not settled, **stop and report** — locking a non-final construction into the VK is worse than deferring and accepting one churn later. Proceed only if §5's in-circuit form is final.

## Checkpoint B — neg_mask_abuse grid (before declaring M3.1 done)

The `neg_mask_abuse` negative vector — a grid that is quiet before `T` but active after — is the *only* vector that exercises the §7 masking backstop, which is the entire reason the masking constraint exists. The other six negatives and the anchors don't test it. Treat finding this grid as a checkpoint, not a step: use the stepper to locate a valid one and surface it (the grid + the generation at which it first activates past `T`). If the stepper can't find one in reasonable time, **report that** rather than quietly shipping unverified masking — we'll decide how to construct one. M3.1 is not done until masking is exercised by a real vector.

## Amendment 2 — Rule-table fixes verify against live `ca_rules.dart`

The three FLAT_TRANSITION fixes (fire born{1}, water born{1,2}, earth survive{1..6}/born{2}) must match the Dart canonical exactly. The `phase15_divergence` tests are self-checking for this *provided* they compare against the live `ca_rules.dart` rules rather than a hardcoded expectation. Confirm that's how they're wired; then all three flipping green is your proof of correct alignment, and you remove the `isFalse` wrappers.

## Checkpoint C — Gate-count delta drives the memory projection (M3.2 → M3.3)

Do not carry forward the "~2.5–3 GB" estimate from M3.0 — that's a guess. The real multiplier is the v2.4-vs-proxy gate-count delta, which M3.2 produces. So the order is: measure the delta in M3.2, project memory from it, then measure on device in M3.3. Also: your "safe on 6 GB+" phrasing concedes the 4 GB floor may not hold for tier 48. That may be acceptable (the user-facing position is "tier-48 mega-spells may need beefier hardware; everyday tiers 12/24 fit 4 GB"), but it's a conscious decision, not a default. Report the projected and measured tier-48 RSS explicitly and flag where it lands relative to both 4 GB and 6 GB so the asterisk doesn't silently grow.

## Everything else in your plan stands

M3.1 (tier-12 circuit + `IS_BUFFER` constant + harness + corpus), M3.2 (tiers 24/48 + delta), M3.3 (on-device re-measure via the proven Phase 2 Kotlin path), M3.4 (track C: swap `ffi/Cargo.toml` to zkpassport/noir_rs beta.20, update `prover.rs` import paths, FRB codegen, `BB_LIB_DIR` escape hatch on hand) — all as written. Compile with the main beta.20 toolchain throughout; the beta.19 spike constraint is retired.

## Proceed

Start M3.1. Hit Checkpoint A before writing the `owner_pubkey` binding; hit Checkpoint B before calling M3.1 done; hit Checkpoint C before projecting M3.3 memory. Otherwise execute straight through and report at each checkpoint.
