# M4 — Brief: Networking & Identity Layer (orient & propose first)

This is a fresh session and a new milestone. **Do not build yet** — orient against the repo, then produce a gap analysis and a dependency-ordered plan, and wait for approval. Read `CLAUDE.md`, the design document (networking / identity / duel sections), `CIRCUIT_IO.md` (§5 owner-binding, §8 public inputs), `docs/M3_findings.md`, and `GOLDEN_VECTORS.md` §7 (the now-confirmed proof wire format) before proposing.

## Where the project is (context — verify against the repo)

M3 is complete. The real v2.4 ZK circuit proves and verifies end-to-end on-device (Pixel 6) through the production path: `zkpassport/noir_rs` (beta.20) wrapped with flutter_rust_bridge — one Rust core, Dart bindings. On-device numbers, all verified: T12 ~5.9 s / ~698 MB, T24 ~11.6 s / ~1176 MB, T48 ~21.6 s / ~2068 MB (T48 at ~50% of 4 GB — the memory question is closed). The proof wire format is empirically confirmed: `[4B BE public-input count][public inputs, 32B each][proof fields, 32B each]`, public parameters ordered before the return tuple — see `GOLDEN_VECTORS.md` §7.

Already in place for this milestone, from M3.1: the circuit carries VK-stable `owner_pubkey == Poseidon2(key_hi, key_lo)` and `ruleset_version == RULESET_VERSION` constraints, with `key_hi`/`key_lo` as private inputs (currently zeros). The identity layer fills these in with real keypairs **without changing the verification key** — that was the whole point of locking the constraint shape early. Conform the identity work to that existing in-circuit construction; do not redesign the binding.

## Scope of M4 (verify exact requirements against the design doc)

The design is local, face-to-face, peer-to-peer: local wireless, no central authority, both parties present. Two modes exist in the design (peer-to-peer with both parties signing, and a Gamemaster mode with single merge authority) — confirm which is in scope for M4 from the design doc. Core pieces:

- **Identity:** real keypairs replacing the zeroed `key_hi`/`key_lo`; the Ed25519 → `key_hi`/`key_lo` field-packing (`CIRCUIT_IO.md` §5 left this as `[CONFIRM when identity module added]` — this is when). Owner-binding via the existing circuit constraint.
- **Match protocol:** serialize and exchange proof + public inputs; each peer verifies the other's proof (`verify_ultra_honk`) using the confirmed §7 wire format; per-match signing; proof-replay prevention.
- **Transport:** carry the protocol over local wireless between two co-present devices.

## The decision that must be made deliberately: transport choice IS the iOS fork

This matters more than it looks. The prover is iOS-capable (zkpassport/noir_rs supports `aarch64-apple-ios`; logic is in Rust, not Kotlin) — M3 kept that door open on purpose. **But iOS crossplay can be silently closed at the transport layer**, which is a networking decision, not a prover one:

- Android's native local-wireless APIs (Wi-Fi Direct / Nearby Connections) have **no interoperable iOS equivalent** (iOS uses Multipeer Connectivity; they do not talk to each other). Building on a platform-native "nearby device" API forecloses crossplay.
- A **shared cross-platform transport** — local TCP/UDP sockets over a common Wi-Fi network, or a cross-platform P2P library — keeps both platforms on the same wire and preserves crossplay.

So the transport must be chosen with iOS feasibility explicitly in mind. In the proposal, **name the transport options and state which preserve cross-platform interop and which foreclose it**, and recommend one. Do not default to the first Flutter "nearby" plugin that appears. (iOS itself is not built in M4 — it's kept *feasible*, not validated; an iOS port of the proving layer is a separate later effort with its own platform-specific work, e.g. the `HARDWARE_CONCURRENCY` thread-pool issue will recur differently there.)

## Testing strategy — protocol first, radio later (no second device needed early)

Structure the plan so the match protocol is proven correct *before* real wireless is involved:

1. **Transport-agnostic protocol layer first.** The core logic — Alice produces proof + public inputs, serializes, sends; Bob deserializes, verifies, reacts; both sign; replay is rejected — is pure logic independent of the radio. Build and test it over an **in-process or localhost channel** (two app instances on one machine, or two emulators, over `127.0.0.1`/LAN). This needs **no second physical device**, and runs on x86-64 emulators where proving is fast and already known-good. This is the bulk of M4's correctness work.
2. **Real local-wireless transport second.** Only after the protocol is proven over the easy channel, wire in the chosen cross-platform local transport and validate the actual radio path. The genuine two-physical-devices test (and the face-to-face UX) belongs here — that's the one stage a second device is actually required, and it can come last.

Keep the transport behind an interface so the protocol layer doesn't care whether bytes crossed localhost, an in-memory channel, or real wireless — that interface is also what makes step 1 possible and what keeps the transport swappable if the iOS-compatible choice changes.

## Proposal should cover

- Gap analysis: what exists vs. what M4 needs (identity, protocol, transport).
- The transport recommendation with the iOS-interop reasoning explicit.
- A dependency-ordered plan: identity/keypairs → transport-agnostic protocol (localhost-testable) → real local-wireless transport → two-device validation.
- How the Ed25519 → `key_hi`/`key_lo` packing works without changing the VK.
- Which design mode (P2P vs Gamemaster) is in scope.

## Out of scope for M4

- Actually building/running on iOS (kept feasible; not validated here).
- Game UI beyond a minimal harness to drive a match.
- Talewright / narrative addon.

## Proceed

Read the sources above, produce the gap analysis and the plan (with the transport decision reasoned, not defaulted), and wait for approval before building.
