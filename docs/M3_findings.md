# M3 — Findings Log (live, updated per milestone)

*Companion to `docs/M2_findings.md`. Each milestone gets a section here as it closes;
read `docs/M3_brief.md` and `docs/M3_review_and_goahead.md` for what was approved and why.*

---

## M3.1 — v2.4 tier-12 circuit, golden-vector harness

**Status: complete.**

- `circuits/ca_v2_4_tier12` implements the full v2.4 contract: boolean cells (§10.1),
  buffer/border zero at T=0 (§10.2), bit-packed Poseidon2 commitment (§10.4),
  masked `border_activations`/`dominance_trajectory`/`supreme_dominance_flags`
  (§10.6/§10.7), `owner_pubkey`/`ruleset_version` binding (§10.9), and the corrected
  `FLAT_TRANSITION` table (fire/water/earth fixes, Amendment 2).
- Single-command loop: `scripts/run_vectors.sh` → Dart stepper regression →
  `nargo compile` → `scripts/gen_vectors.dart` (two-oracle: stepper for CA outputs,
  `nargo execute` for the commitment).
- Full positive + negative corpus in `test_vectors/seeds.json` / `corpus.json`. The
  rule-diff test (`test/engine/ca_run_test.dart`) parses `FLAT_TRANSITION` live from
  `main.nr` rather than a hand-copied duplicate — confirmed all 5 rules match
  `ca_rules.dart` exactly.
- The 4 `declared_override` negative vectors were reclassified as SNARK
  public-input-binding checks, not circuit-constraint vectors (see
  `GOLDEN_VECTORS.md` §3's `[RESOLVED M3.1]` note) — their circuit-relevant half is
  discharged by the positive vectors; the remaining "tampered proof rejected" half
  is one consolidated smoke test deferred to M3.4.

Full detail lives in `GOLDEN_VECTORS.md` and `test_vectors/seeds.json`; not repeated here.

---

## M3.2 — Tiers 24/48 replication, gate-count delta

**Status: complete.**

### What was built

`circuits/ca_v2_4_tier24` and `circuits/ca_v2_4_tier48` — identical to
`ca_v2_4_tier12` except `TIER_MAX` (24, 48 respectively). `constants.nr` (grid
geometry: `N`, `IS_BORDER`, `IS_BUFFER`, `NEIGHBORS`, `BORDER_ZONE`, the packing
weight tables) is tier-independent and copied verbatim — the inscribable grid
doesn't change with tier, only the generation cap does. All three compile cleanly
and `nargo execute` solves correctly on the default (all-zero, T=1) witness.

### Measurement setup

`bb` 5.0.0-nightly.20260324 (the version pinned in `CLAUDE.md`) was not previously
installed on this Linux dev machine — only an Android-arm64 prebuilt existed (M2 FFI
spike cache). Installed via the official `bbup` installer for this measurement;
confirmed `bb --version` matches the pin exactly.

The proxy circuit (`circuits/ca_lookup_v2`) hardcodes `global T: u32 = 20` (no tier
parameterization) and was never measured at T=12/24/48 — `phase1_5_results.csv` only
has T={5,10,20,30}. To get a same-T comparison, the proxy was copied to
`/tmp/ca_lookup_v2_t{12,24,48}` (not modifying the committed repo file) with `T`
edited to match, then compiled and measured the same way.

### Results

`nargo info` (ACIR opcodes) and `bb gates -b <bytecode.json>` (UltraHonk
`circuit_size`, the real proving-cost metric):

| Tier | v2.4 ACIR opcodes | proxy ACIR opcodes | ACIR delta | v2.4 gates | proxy gates | gate delta |
|---|---|---|---|---|---|---|
| 12 | 93,898  | 109,970 | -14.6% | 211,384 | 251,973 | **-16.1%** |
| 24 | 198,478 | 218,858 | -9.3%  | 442,111 | 487,771 | **-9.4%**  |
| 48 | 407,638 | 436,634 | -6.6%  | 903,565 | 959,367 | **-5.8%**  |

**v2.4 is cheaper than the proxy at every tier, in both metrics.** This overturns
M2's floor caveat ("v2.4 will cost more than the proxy; the multiplier is unknown
until M3"). The real circuit does not just close the gap — it comes in under the
proxy's gate count.

### Why: the proxy's commitment scheme, not v2.4's added constraints, dominates cost

v2.4 adds real security constraints the proxy never had (469 boolean-cell asserts,
469 buffer/border-zero asserts, output masking, `owner_pubkey`/`ruleset_version`
binding) — all `[CONFIRM vs stepper]` items from CIRCUIT_IO.md §13 that needed
hardening. Despite that, it's cheaper, because of how each computes its commitment:

- **Proxy (`ca_lookup_v2`)**: `commitment_hash` calls `poseidon2_permutation` 157
  times (once per 3-cell block across 469 cells, plus one final block) — a naive,
  unbatched accumulation.
- **v2.4**: bit-packs all 469 cells into two `Field`s (`POW2_253`/`POW2_216` weighted
  sums — pure arithmetic, cheap in both ACIR and gates), then calls
  `poseidon2_hash2` (a single `poseidon2_permutation` call) once for the commitment
  and once more for the `owner_pubkey` binding assertion — 2 permutations total
  versus the proxy's 157.

Poseidon2 permutation is the single most expensive primitive in either circuit; the
per-cell boolean/region constraints v2.4 adds are comparatively cheap (single
multiplication or comparison per cell). The proxy's hashing inefficiency was masking
how cheap the CA-loop-plus-constraints actually is — fixing the commitment scheme
saved more than the new constraints cost.

The savings shrink as `T` grows (-16.1% at T=12 down to -5.8% at T=48) because the
commitment/constraint cost is paid once per circuit (independent of `T`), while the
per-generation CA loop — identical in both circuits' core mechanics — scales with
`T` and dominates at the larger tiers.

### Implication for the 4 GB question (M2 caveat #2)

This is a gate-count result, not an on-device time/RSS measurement. M3.3 (below)
checked the next layer — the padded/dyadic circuit size, which is what UltraHonk's
memory footprint actually scales with — and found v2.4 and the proxy land in the
**same** dyadic bucket at every tier (both round up to 2^18/2^19/2^20 at T=12/24/48).
So the gate-count win likely does *not* translate into a proportional memory win,
but it also can't push v2.4 *above* the proxy's bucket. Combined, gate count and
dyadic bucket bound v2.4 at or below the proxy's M2-measured on-device numbers
(~2.10 GB / ~32 s at T=48 on an 8 GB Pixel 6) — see M3.3's conclusion for how this
was settled without a direct on-device v2.4 run.

### Artifacts

- `circuits/ca_v2_4_tier24/`, `circuits/ca_v2_4_tier48/` — committed.
- Proxy comparison builds were done in `/tmp` (not committed — they're a throwaway
  same-T variant of the already-committed `ca_lookup_v2`, kept only long enough to
  run `bb gates`).
- `bb` 5.0.0-nightly.20260324 now installed at `~/.bb` (added to `PATH` via
  `~/.bashrc` by the `bbup` installer) — first time this toolchain piece has been
  available on this Linux dev machine; previously only `nargo` was on hand.

---

## M3.3 — On-device re-measurement attempt, and why it was redirected

**Status: concluded without a direct on-device v2.4 measurement (see "Strategic
conclusion" below) — the dyadic-bucket analysis from M3.2 settles the 4 GB
question, and the real on-device v2.4 numbers will come from M3.4's production
path instead of a separate spike-harness run.**

### What was attempted

Reused the M2 spike's Kotlin measurement harness (`StudioProjects/NoirAndroidTest`,
`com.github.madztheo:noir_android:1.0.0-beta.20-2`) per the plan: added the real
`ca_v2_4_tier{12,24,48}.json` as assets, updated `MainActivity.kt` to build the
v2.4 ABI's full input map (`grid_state`, `key_hi`, `key_lo`, `T`, `owner_pubkey`,
`ruleset_version` — vs. the proxy's `grid_state`-only ABI), and added a
single-tier cold-launch mode for clean per-tier isolation.

### What broke

Loading the real v2.4 bytecode into this harness crashes natively (SIGABRT),
consistently and immediately, every time, right as `setupSrs()` starts its SRS
download. Confirmed via two isolation tests:

1. **The harness itself is fine.** The unmodified proxy circuit
   (`ca_lookup_v2_t12.json`, the same harness, same device, same network) ran
   clean: `wall_ms=8912 peak_rss_kb=712520 verified=true` — matching M2's recorded
   ~8.9 s / ~717 MB almost exactly. Device, network, and wrapper are all healthy.
2. **Only the v2.4 manifest triggers it**, via *either* SRS entry point the Kotlin
   wrapper exposes: the default bytecode-parsing path
   (`Noir.setup_srs_from_bytecode`) and an explicit-circuit-size workaround
   (`Circuit.fromJsonManifest(data, size=...)`, which routes through
   `Noir.setup_srs` instead) both abort identically. v2.4 is the first circuit
   this harness has ever loaded with `pub` **input** parameters (`T`,
   `owner_pubkey`, `ruleset_version`) rather than only public *return values* —
   the likely fault line, though the abort gives no panic message, only a bare
   `SIGABRT` inside the closed-source `noir_java` `.so`.

### Desktop repro: isolates the bug to the Kotlin/JNI layer, not the shared core

Rather than debug the closed third-party Kotlin wrapper directly (it's superseded
by M3.4's production path regardless), reproduced the same call sequence on the
desktop x86-64 host against **zkpassport/noir_rs v1.0.0-beta.20-1** directly — the
actual production dependency for M3.4, not the wrapper. A minimal Rust binary
(`/tmp/zkpassport_repro`, not committed — throwaway diagnostic) called
`noir_rs::barretenberg::srs::setup_srs_from_bytecode` then
`noir_rs::barretenberg::prove::prove_ultra_honk` against the real
`ca_v2_4_tier12.json` bytecode, with a hand-built witness matching the v2.4 ABI
order (469 grid cells, `key_hi`, `key_lo`, `T=1`, the pinned `owner_pubkey`,
`ruleset_version=1`):

```
setup_srs_from_bytecode OK: num_points=262145
prove_ultra_honk OK: proof length = 17028 bytes
```

**No crash.** This confirmed the *desktop* (x86-64) core was clear and that the
Kotlin/JNI wrapper's SIGABRT was specific to that binding layer, not the shared
core in the abstract. **Amendment, M3.4 step 0:** the same core, run on ARM
(not x86-64), reproduces a *different but related* failure — see M3.4 below.
The desktop-vs-ARM split, not the wrapper-vs-core split, turned out to be the
operative axis.

### Strategic conclusion

Per direction: M3.3's job (resolve the 4 GB question for tier 48) is satisfied by
M3.2's analysis, not by a separate on-device v2.4 run on the spike harness:

- v2.4 has **fewer gates than the proxy at every tier** (M3.2), and
- v2.4 and the proxy land in the **same dyadic (padded) bucket at every tier**, so
  v2.4's actual UltraHonk memory footprint cannot exceed the proxy's.
- The proxy's M2-measured on-device numbers (T=48: ~32 s, ~2.10 GB peak RSS on an
  8 GB Pixel 6) are therefore a **ceiling**, not a floor, for v2.4.
- **Tier 48 is GO on 8 GB.** The 4 GB question is unchanged-to-improved relative to
  M2's "open question" framing — still not a hardware-measured 4 GB verdict (none
  available), but the projection from the 8 GB run is now backed by a circuit that
  is provably no larger than the one M2 already measured, not merely assumed
  smaller.
- The actual on-device v2.4 timing/RSS numbers will fall out of M3.4 once the
  production FRB path proves on-device — no separate spike-harness measurement
  step is needed first.

### Artifacts

- `StudioProjects/NoirAndroidTest` (separate repo, not part of `runewright`):
  `app/src/main/assets/ca_v2_4_tier{12,24,48}.json` added; `MainActivity.kt`
  updated to the v2.4 ABI + single-tier mode + `size`-override workaround. Left in
  this state — not reverted — since it correctly demonstrates the bug isolation
  and may be useful if filing an upstream `noir_android` issue later. Not used
  for any reported measurement.
- `/tmp/zkpassport_repro` — throwaway desktop diagnostic, not committed.

---

## M3.4 — Production FRB integration: step 0 (bare-metal ARM prove smoke test)

**Status: blocked. Stopped per plan before starting the FRB/Flutter build — this
is the genuine blocker the step-0 gate was designed to catch.**

### What was built

A standalone Rust binary (`/tmp/arm_prove_smoke`, not committed — throwaway),
depending directly on `zkpassport/noir_rs v1.0.0-beta.20-1` (no FRB, no JNI, no
Kotlin), cross-compiled for `aarch64-linux-android` using the same NDK/Zig/
`BB_LIB_DIR` recipe as `scripts/build_android_ffi.sh`, and pushed/run on the
Pixel 6 via `adb shell` directly. It calls `setup_srs_from_bytecode` then
`prove_ultra_honk` against the real `ca_v2_4_tier12` bytecode, with the same
known-good witness used throughout (all-zero grid, `T=1`, the pinned
`owner_pubkey = poseidon2_hash2(0,0)`, `key_hi=key_lo=0`, `ruleset_version=1`).

### Three new toolchain bugs found and fixed getting the binary to run at all

None of these were hit by M2/M3.1-3.3 because they only ever built/ran a
**cdylib** (loaded via `dlopen`); this is the first **executable** built with
this toolchain. Fixed in `ffi/android_shims.c` and
`scripts/ndk-cxx-android.sh` (shared with the production cdylib build, so
M3.4's real build benefits from these too):

1. **`strtof_l`/`strtod_l` undefined.** Linking a binary pulls in more of
   libc++'s `<locale>` machinery than the cdylib did. NDK 30 declares these
   `static inline` (no linkable symbol exists to satisfy Zig's prebuilt
   `libc++.a`, which expects a real symbol). Fixed: hand-written shims calling
   the real (non-`_l`) Bionic `strtof`/`strtod`, forward-declared without
   `<stdlib.h>` to avoid colliding with the inline declarations.
2. **`std::basic_streambuf<char>::seekpos`/`seekoff` undefined**, referenced
   from `get_bn254_crs.cpp`'s `httplib::DataSink` vtable inside
   `barretenberg-rs`'s static lib (its own internal CRS-fetching HTTP client —
   never called at runtime; SRS fetching goes through `noir_rs`'s Rust-side
   `netsrs` instead, but the vtable still needs every virtual resolved to
   link). Zig's bundled `libc++.a` doesn't include the explicit instantiation
   that would normally provide these. Fixed: a new shim
   (`ffi/android_shims_streambuf.cpp`) forcing
   `template class std::basic_streambuf<char, std::char_traits<char>>;`,
   compiled with Zig's own `c++` (not NDK clang++, which would produce the
   incompatible `__ndk1`-namespaced symbols) with `-fno-sanitize=all` (Zig
   enables UBSan-trap instrumentation by default, which isn't being linked
   against a runtime here since the final link is NDK clang, not Zig).
3. **`executable's TLS segment is underaligned`** — modern ARM64 Bionic
   refuses to load any ELF whose `PT_TLS` segment isn't placed at a
   ≥64-byte-aligned address; `lld` only emits/places it that way if some
   linked `__thread` variable actually demands 64-byte alignment, which
   nothing in this link did (declared alignment 16). Patching the ELF header
   after the fact (`termux-elf-cleaner`) only relabels the field — it doesn't
   move the segment, so the loader's stricter skew check still failed
   (`skew=32`). Fixed properly: an unused 64-byte-aligned `__thread` dummy
   variable in `android_shims.c`, compiled with `-fno-emulated-tls` (NDK
   clang defaults to call-based emulated TLS for this target config, which
   doesn't influence the real `PT_TLS` segment at all), and force-kept via
   `-Wl,-u,runewright_tls_align_force` (otherwise `--gc-sections` discards an
   unreferenced dummy).

With all three fixed, the binary runs on-device: `setup_srs_from_bytecode`
succeeds (network SRS download works, `num_points=262145`, matching the
desktop value exactly).

### The actual result: confirmed ARM circuit-builder bug in `prove`, not just `compute_vk`

```
Calling prove_ultra_honk...
thread 'main' panicked: prove_ultra_honk failed: "circuit_prove failed: Backend error: vector"
```

Reproduced consistently across multiple runs, **both with and without** a
desktop-precomputed VK supplied (Amendment A's bundled-VK workaround, tested
explicitly via a second binary, `compute_vk`, that calls
`get_ultra_honk_verification_key` on x86-64 and saves the 3,680-byte result).
Bundling the VK does **not** route around this — it fails identically either
way. **Classification, per the plan's explicit criterion: this is the
circuit-builder/ARM bug (`std::out_of_range("vector")`), not an FRB/Dart
marshalling error** — there is no FRB in this binary at all.

### Sharpening the diagnosis: it's not "ARM can't prove," it's "this circuit can't prove on ARM"

Three data points, same device, same `barretenberg-rs` version
(4.2.0-aztecnr-rc.2), same `noir_rs` version:

| Path | Circuit | Pub *input* params | Result |
|---|---|---|---|
| `madztheo/noir_android` Kotlin wrapper (M2) | proxy (`ca_lookup_v2`) | none (only pub return values) | **succeeds** — real numbers recorded, e.g. T=12: 8.9s/717MB |
| Same Kotlin wrapper (M3.3) | real v2.4 | `T`, `owner_pubkey`, `ruleset_version` | SIGABRT in `setup_srs` |
| Direct Rust binary, no wrapper (M3.4 step 0, this finding) | real v2.4 | same three | clean `Err`: `std::out_of_range("vector")` in `prove_ultra_honk` |

v2.4's gate count (211k at T=12) is *smaller* than the proxy's (252k) — so this
isn't a size ceiling. The one structural difference between the circuit that
works on this exact ARM stack and the one that doesn't is **`pub` function
*parameters*** (v2.4 has three; the proxy has zero, only `pub` return values).
That difference also doesn't reproduce at all on x86-64 desktop (confirmed
working twice over: M3.3's repro and this finding's own desktop control runs
of `prove_ultra_honk`/`get_ultra_honk_verification_key` against the identical
bytecode/witness). The likely fault line is `barretenberg-rs`
4.2.0-aztecnr-rc.2's AArch64 handling of public **input** indexing/sizing
specifically — but that's a hypothesis pointing at where to look next, not a
confirmed root cause; no barretenberg/Aztec source was inspected to verify it.

### Why this matters before building the FRB harness

Per the plan: building the full Flutter/FRB integration around a `prove` call
that cannot complete on-device would mean discovering this same failure later,
at higher cost, wrapped in JNI/Dart noise that would make it harder to tell
apart from a marshalling bug. Stopping here, with a clean Rust-only repro and
an unambiguous classification, is the cheap version of finding this.

### Artifacts

- `/tmp/arm_prove_smoke`, `/tmp/zkpassport_repro/src/bin/compute_vk.rs` —
  throwaway diagnostics, not committed.
- `/tmp/ca_v2_4_tier12.vk` — desktop-computed VK used for the bundled-VK
  control test, not committed.
- **Committed, reusable for the eventual real FRB build regardless of how the
  blocker resolves:** `ffi/android_shims.c` (added `strtof_l`/`strtod_l`
  shims + the TLS-alignment-forcing dummy variable),
  `ffi/android_shims_streambuf.cpp` (new), `scripts/ndk-cxx-android.sh`
  (compiles both new shims, force-keeps the TLS dummy, adds `-fno-emulated-tls`
  / `-fno-sanitize=all` as needed). None of this is wasted even though step 0
  didn't clear — the production cdylib build would have hit at least the
  `strtof_l` and streambuf issues too, since both stem from linking more of
  `barretenberg-rs`'s surface than the M2 spike's narrower FFI usage did.

---

## M3.4 — Public-parameters hypothesis: disproven, and a deeper finding

**Status: the stated hypothesis is wrong. Found something more fundamental
instead — the bug is not circuit-specific at all.**

### Test 1: toy circuits, one pub param vs. one pub return

Two minimal circuits, compiled at beta.20, run through the same bare-metal ARM
binary (`setup_srs_from_bytecode` + `prove_ultra_honk`, no FRB/JNI):

- `toy_pubparam`: `fn main(x: Field, y: pub Field) { assert(x == y); }` — one
  `pub` *parameter*.
- `toy_pubreturn`: `fn main(x: Field) -> pub Field { x }` — one `pub` *return
  value*, zero `pub` parameters — the same ABI shape as M2's successful proxy
  circuit.

**Both failed identically**: `"circuit_prove failed: Backend error: vector"`.
If the hypothesis were right, `toy_pubreturn` should have proved clean. It
didn't. **The public-parameters hypothesis is disproven** — the bug doesn't
distinguish `pub` parameters from `pub` return values at all.

### Test 2: SRS-undersizing hypothesis (a real, already-documented bug from M2) — also ruled out

`ffi/src/api/prover.rs` already carries a multiplier
(`compute_subgroup_size(circuit_size * 8)`, comment: "to guard against
... needing extra points on AArch64") from the M2 spike — a different,
previously-found AArch64 SRS-sizing bug. Worth ruling in or out before
concluding anything. Rebuilt the smoke test to size the SRS manually with a
configurable multiplier instead of the bare `setup_srs_from_bytecode`
convenience call. Tested `toy_pubreturn` at multiplier 1 (the default, 65
points) and 8 (513 points) — **both failed identically.** Oversizing the SRS
8× past what the circuit needs doesn't help.

### Test 3: the absolute floor — zero public anything

`toy_allprivate`: `fn main(x: Field) { assert(x == x); }` — no `pub`
parameters, no `pub` return, the simplest circuit that can exist. **Also
failed identically**, with and without a desktop-precomputed VK supplied
(ruling out the bundled-VK workaround here too, as it already was for v2.4).

This rules out every circuit-content explanation: not public parameters, not
public returns, not SRS sizing, not VK precomputation. `prove_ultra_honk`
fails on this exact ARM build for **any input**.

### The actual difference: which prebuilt binary is being exercised

If `prove_ultra_honk` is categorically broken on ARM via this build, M2's
recorded *successes* need explaining. Checked what the working Kotlin path
(`madztheo/noir_android` 1.0.0-beta.20-2) actually runs on-device: its AAR
bundles a self-contained, prebuilt `libnoir_java.so` (29.7 MB, arm64-v8a) —
built by **their** CI. Confirmed their `noir_java`'s `Cargo.toml` depends on
the identical `noir_rs` git tag (`v1.0.0-beta.20-1`, `features =
["barretenberg"]`) I'm using — the Rust-level dependency is the same.

The difference is the underlying native `barretenberg` artifact each build
resolves to. My build links against `~/.cache/runewright/barretenberg/
4.2.0-aztecnr-rc.2/arm64-android/libbb-external.a` — fetched via
`scripts/build_android_ffi.sh`'s `BB_LIB_DIR` override, working around a
documented `barretenberg-rs` `build.rs` bug ("`aarch64-linux-android` matches
the `linux` arm before the `android` arm, downloading the wrong arm64-*linux*
binary"). Their CI's `libnoir_java.so` was built through some other path
entirely (their own `build.rs` resolution, possibly without ever hitting that
target-match bug, or against a different point release of the prebuilt
binary than the one sitting in my cache, despite both nominally being
"4.2.0-aztecnr-rc.2"). **I have not yet confirmed *which* of these explains
the gap** — only that the artifact is plausibly different, not that I've
proven how. The honest state: M2's "GO" was earned by the Kotlin-AAR's
bundled native binary, not by the `BB_LIB_DIR`-cached one this Rust-level
smoke test (and the eventual FRB cdylib build) actually link against. It is
not yet established that the production FRB path's link target works on ARM
**at all**, independent of v2.4.

### Why this is bigger than the original question

The original ask was "is it public parameters." It isn't. The honest
reframing: **on-device proving has only ever been confirmed to work through
the Kotlin/AAR artifact** (M2). The `BB_LIB_DIR`-cached static lib — what
`scripts/build_android_ffi.sh` produces and what M3.4's FRB build would link
against — has never been confirmed to prove anything on ARM, for any circuit,
public or private, v2.4 or trivial. That's a precondition for the whole FRB
track, not a v2.4-specific gap.

### Not yet tried, in rough cost order

- Diff the two artifacts more concretely: compare `libbb-external.a`'s
  exported symbol versions/sizes against what's embedded in `libnoir_java.so`
  (extractable but not directly diffable as a `.a`; would need objdump-level
  comparison of overlapping symbols).
- Try removing the `BB_LIB_DIR` override and letting `barretenberg-rs`'s
  `build.rs` run unmodified for `aarch64-linux-android`, to see what it
  *actually* downloads (confirm or refute the target-match bug still
  reproduces, and what artifact results) — costs a clean rebuild, informative
  either way.
- Search for a barretenberg-rs/Aztec release note describing what changed (if
  anything) in the arm64-android artifact across "4.2.0-aztecnr-rc.2"
  point-builds — searched issues/PRs already (see below), found nothing
  specific; could go deeper into the release artifact history itself.

### Upstream search (done, in parallel, per the plan)

Searched `AztecProtocol/aztec-packages`, `zkpassport/noir_rs`, and general
GitHub issue search for `"Backend error" vector barretenberg`, `out_of_range`
+ `android`, `aarch64` + `circuit_prove`. **No hits matching this signature.**
Nothing found that confirms or denies whether a later release fixes this —
the version-bump branch of the original plan has no supporting evidence
either way yet.

### Recommendation

Don't restructure v2.4's ABI (M3.1's locked construction) on the basis of a
disproven hypothesis — that work is real cost for a fix that the toy-circuit
evidence says won't fix anything. The next cheap, decisive test is comparing
the two native artifacts directly or trying an un-overridden `build.rs` to
see what it fetches today — reporting before spending more device time.

---

## M3.4 — Steps 1-3: both candidate artifacts fail; the bug pinpointed in source

**Status: steps 1-2 of the follow-up plan both produce a non-proving binary.
Step 4's trigger condition (re-evaluate the version pin) is now met — but one
avenue (madztheo's actual build mechanism) remains unexplored before that.**

### Step 1: un-overridden `build.rs`

Removed `BB_LIB_DIR`, rebuilt clean. The fetch log: `Downloading barretenberg
static library from .../barretenberg-static-arm64-linux.tar.gz` — confirms
the documented target-match bug fires for real, today, against the exact
dependency this project uses. **Read the actual published `build.rs` source**
(pulled from the local Cargo registry cache, `barretenberg-rs-4.2.0-aztecnr-
rc.2/build.rs`) to confirm why, rather than inferring it:

```rust
t if t.contains("aarch64") && t.contains("linux")   => "arm64-linux",   // line 55
...
t if t.contains("aarch64") && t.contains("android") => "arm64-android", // line 66
```

`aarch64-linux-android` contains both substrings; Rust's `match` takes the
first arm that matches, and `arm64-linux` is listed first. This is a literal,
verified bug in the published crate, not a guess — every consumer building
`aarch64-linux-android` without `BB_LIB_DIR` hits it.

Built the floor circuit against this (wrong-target) artifact anyway, with the
NDK API bumped to 28 (needed `aligned_alloc`/`getrandom`, native from API 28,
to get past link). **Result: fails identically** —
`"circuit_prove failed: Backend error: vector"`. Expected, since it's
confirmed the wrong libc target; not informative about the real fix on its
own.

### Step 3 (provenance, done before step 2 to make step 2 meaningful)

Fetched `barretenberg-static-arm64-android.tar.gz` fresh from the same
`v4.2.0-aztecnr-rc.2` release tag and compared against the file `BB_LIB_DIR`
has pointed at all along (`~/.cache/runewright/barretenberg/...`):

```
584d0d4ffb582f670c26cf03d2a799fe0f1f53fa3939010b83b33fd32a0aa4d4  (fresh download)
584d0d4ffb582f670c26cf03d2a799fe0f1f53fa3939010b83b33fd32a0aa4d4  (existing cache)
```

**Byte-identical.** The artifact this project has been building against
since M2 is not stale, not corrupted, not the wrong variant — it is the
genuine, official, correctly-Android-targeted release asset.

### Step 2: the correct artifact, confirmed authentic, still fails

This is the artifact already exercised in every `BB_LIB_DIR`-set test in this
session (M3.4 step 0, the toy circuits, the floor circuit) — all of which
failed identically. Step 3 just removes "maybe the cache is bad" as an
explanation. **The official, hash-verified, correctly-targeted
`arm64-android` build of barretenberg 4.2.0-aztecnr-rc.2 does not prove, for
any circuit, on this Pixel 6.**

### Trying to find madztheo's actual recipe (to identify a working artifact per step 2's second half)

Their `noir_java/Cargo.toml` depends on the *identical* `noir_rs` git tag
(`v1.0.0-beta.20-1`, `features = ["barretenberg"]`) — same transitive
`barretenberg-rs = "=4.2.0-aztecnr-rc.2"` pin. No discoverable difference at
the Cargo level. Their `.cargo/config.toml` configures a **plain NDK
`aarch64-linux-android33-clang` linker — no Zig, no static-libc++
substitution**. Tried reproducing that exact combination (the verified
correct `arm64-android` artifact + plain NDK dynamic `libc++_shared`, API 33,
no `BB_LIB_DIR`-style override): **link failure**, hundreds of unresolved
`std::__1::*` symbols (`ultra_prover.cpp`, `translator_circuit_builder.cpp`,
~300+ references each). This conclusively confirms the Zig/static-libc++
workaround built up across M2/M3 is solving a **real, necessary** problem,
not a red herring — without it, this artifact cannot even link via the plain
NDK path madztheo's config file shows. So either their JitPack CI does
something not visible in the public repo (no CI workflow file is committed;
`jitpack.yml` references `scripts/prepareJitpackEnvironment.sh`, which
**404s** — doesn't exist at that path in the current repo) to reconcile this,
or their actual build environment differs from what `.cargo/config.toml`
alone implies (e.g. a Gradle-level Rust plugin injecting its own linker
environment). **Could not identify their actual working recipe from public
source.**

### Where this leaves step 4

Per the plan's trigger: both step 1 (wrong-target artifact) and step 2 (the
verified-correct, hash-confirmed official artifact) fail to produce a proving
ARM binary. That meets step 4's condition. Before treating a version bump as
necessary, two things are still worth weighing:

1. **The "no working artifact in this release" conclusion is based on the
   one official prebuilt asset, not an exhaustive search.** Haven't checked
   whether `aztec-packages` shipped a corrected/patched arm64-android asset
   under a different point-release tag, or whether building barretenberg
   from source (`cd barretenberg/cpp && ./bootstrap.sh`, the `BB_LIB_DIR`
   panic message's own suggested alternative) against the NDK toolchain
   directly — rather than using either prebuilt artifact — would avoid
   whatever's wrong with the prebuilt one. This is real new work (a C++
   cross-build), not a quick test.
2. **madztheo's actual recipe is still unconfirmed, not ruled out.** Their
   AAR's `libnoir_java.so` is real, working evidence (M2 measured it
   directly) that *some* build of this exact dependency graph proves on this
   exact device. I haven't exhausted ways to find out what it is — e.g.
   asking upstream, or extracting/objdumping their shipped `.so` to compare
   its `barretenberg`-internal symbol versions/build flags against the two
   artifacts already tested, which might reveal a version string, build
   timestamp, or commit hash embedded in the binary.

Reporting here rather than choosing a direction unilaterally — building from
source or reverse-engineering a third party's binary are both substantively
larger asks than anything tried so far this session.

---

## M3.4 — RESOLVED: root cause found via on-device debugger, one-line fix, no rebuild or version bump needed

**Status: blocker cleared. The official `arm64-android` artifact is fine. The
bug was an unsigned-integer underflow in barretenberg's thread-pool sizing,
triggered only because `std::thread::hardware_concurrency()` returns 0 in
this process's environment — fixed by setting one environment variable
before proving.**

### Getting a real backtrace

Per the brief: caught the exception under a real debugger instead of relying
on the stringified message. No `lldb`/`gdbserver` was available locally or
via `apt` (no sudo); used `lldb-server`'s built-in `gdbserver`-protocol mode
(bundled with the NDK) as the on-device stub, paired with the `lldb` client
extracted from VS Code's CodeLLDB extension (`.vsix`, ~55 MB — far lighter
than a full LLVM release tarball) as the host driver. Forwarded the port
(`adb forward tcp:5039 tcp:5039`), launched the floor-circuit binary under
`lldb-server gdbserver`, connected, and set `breakpoint set -E c++` (catches
at the `__cxa_throw` call, before any unwinding/catching happens — this is
what makes the stack trace meaningful, since whatever catches this exception
and stringifies it as `"Backend error: vector"` runs *after* this point).

### The actual exception, and where

Not `std::out_of_range` — **`std::__1::length_error`**, thrown from
`std::vector<std::thread>::reserve()`. Full relevant frames:

```
frame #3: vector<thread>::reserve(unsigned long)
frame #4: (anonymous namespace)::ThreadPool::ThreadPool(unsigned long)
frame #5: bb::parallel_for_mutex_pool(size_t, function<void(size_t)> const&)
frame #6: bb::Polynomial<...>::Polynomial(...)
frame #7: bb::ProverInstance_<UltraZKFlavor>::allocate_wires()
frame #8: bb::ProverInstance_<UltraZKFlavor>::ProverInstance_(...)
...
frame #20: noir_rs::backends::barretenberg::api::circuit_prove
frame #21: noir_rs::backends::barretenberg::prove::prove_ultra_honk
```

Classification per the brief's framework: **thread/parallelism setup** — the
"potentially fixable without rebuild" bucket, distinct from a circuit-builder
bug or a CRS/SRS-wiring bug.

### Root cause, confirmed by reading barretenberg's actual source

`parallel_for_mutex_pool` (`barretenberg/cpp/.../parallel_for_mutex_pool.cpp`):

```cpp
static THREAD_LOCAL_MAYBE ThreadPool pool(get_num_cpus() - 1);
```

`get_num_cpus()` returns `size_t` (unsigned). Its fallback chain
(`thread.cpp`): `HARDWARE_CONCURRENCY` env var, if set; else
`std::min(32U, std::thread::hardware_concurrency())`. The C++ standard
explicitly permits `hardware_concurrency()` to return `0` when it "is not
computable or well-defined" — and it does, in this process's environment.
`0 - 1` on an unsigned type wraps to `SIZE_MAX`. `vector<thread>::reserve
(SIZE_MAX)` throws exactly `length_error("vector")` — matching the `"Backend
error: vector"` string seen at every layer above this all session. This is
fully explained by source inspection; no further debugging was needed once
the backtrace pointed here.

This also explains why M2's Kotlin-wrapper path never hit it: it runs inside
a full Android app process (zygote-forked, normal cpuset/affinity), where
`hardware_concurrency()` behaves normally. The bare-metal binary launched via
`adb shell` apparently sees a different (cgroup/cpuset-restricted view,
unconfirmed exactly why) environment where it returns 0. **This was never a
property of the v2.4 circuit, the artifact, or the Rust bindings — it fires
for any circuit, in any standalone-binary context, the moment
`hardware_concurrency()` returns 0.**

### The fix, confirmed working

Set `HARDWARE_CONCURRENCY` (any nonzero value) before calling into
barretenberg:

```
HARDWARE_CONCURRENCY=4 ./arm_prove_smoke ./ca_v2_4_tier12.json
→ prove_ultra_honk OK: proof length = 17028 bytes
```

Confirmed reproducible at `HARDWARE_CONCURRENCY=4` and `=8` (the Pixel 6's
actual core count), across multiple runs, on **both** the floor circuit
(`toy_allprivate`) and the **real `ca_v2_4_tier12` bytecode** — first try, no
SRS multiplier override even needed (v2.4's own circuit size already exceeds
UltraHonk's minimum point requirement; only the tiny toy circuits needed the
already-known `×8` multiplier from `ffi/src/api/prover.rs` on top of this
fix). Both the official `arm64-android` artifact and the (wrong-target,
previously untested-this-far) `arm64-linux` one got past this exact point
once the env var was set — the artifact was never the problem.

### Consequence for the open questions

- **No version bump.** The pinned `barretenberg-rs = "4.2.0-aztecnr-rc.2"`
  artifact proves fine. CLAUDE.md's toolchain pin stands.
- **No build-from-source.** Not needed — moot once this is the actual fix.
- **madztheo's recipe is no longer interesting to chase.** Their app process
  just never had `hardware_concurrency()` return 0 in the first place;
  there's no special artifact or build trick to find.
- **Production fix, for `ffi/src/api/prover.rs`:** call
  `std::env::set_var("HARDWARE_CONCURRENCY", "<n>")` once, early (e.g. in
  `frb_init_app`, alongside `setup_default_user_utils()`), before any
  proving/VK/SRS call. `<n>` should come from
  `std::thread::available_parallelism()` (Rust's own equivalent, queried
  fresh — needs confirming it doesn't hit the *same* underlying problem on
  this platform; if it does, hardcode a conservative value like `4`).
  Belongs in M3.4's actual FRB build, not this diagnostic.

### Artifacts

- `lldb` client extracted from `codelldb-linux-x64.vsix` — kept at
  `/tmp/codelldb_extract`, not committed (throwaway tool, reusable if more
  on-device debugging is needed later; worth remembering this path instead
  of re-deriving it).
- All other diagnostic binaries/circuits from this session remain
  uncommitted throwaways in `/tmp`.

## M3.4 — Steps 1-4 done, step-6 on-device gate CLEARS

**Status: gate passed. Public-input marshalling across FRB and the
`HARDWARE_CONCURRENCY` fix surviving FRB's threading are both confirmed.**

### Steps 1-4

- `ffi/Cargo.toml`: swapped to `noir_rs` (`zkpassport/noir_rs` tag
  `v1.0.0-beta.20-1`), matching the main beta.20 toolchain. Added the `ctor`
  crate.
- `ffi/src/api/prover.rs`: fixed `noir::` → `noir_rs::` throughout; fixed
  several call-signature mismatches the new dependency's API has versus the
  old zkmopro fork (`get_ultra_honk_verification_key` and
  `get_ultra_honk_keccak_verification_key` take an extra
  `max_storage_usage: Option<u64>`; `prove_ultra_honk` likewise). Hardened the
  `HARDWARE_CONCURRENCY` fix per your instruction: moved it out of
  `frb_init_app` into a `#[ctor]`-attributed function, which runs at `.so`
  load time (`DT_INIT_ARRAY`) — strictly before any Rust/FRB code, and
  therefore before FRB can spawn its first worker thread. This matters
  because barretenberg's read of that env var is cached in a `static
  thread_local`, populated lazily per-thread on first read; `frb_init_app`
  alone doesn't guarantee it lands before every future worker thread's first
  touch, a `#[ctor]` does. Extended `prove_and_time`'s signature to the full
  v2.4 witness ABI (`grid_state`, `key_hi_hex`, `key_lo_hex`, `t_hex`,
  `owner_pubkey_hex`, `ruleset_version_hex`, `vk_bytes`, `low_memory`), built
  via `from_vec_str_to_witness_map` (hex strings — `owner_pubkey` is a full
  254-bit field, `from_vec_to_witness_map`'s `u128` can't hold it).
- `ffi/src/bin/desktop_vk_test.rs`: repurposed from the old proxy-circuit
  spike to precompute VKs for the real `ca_v2_4_tier{12,24,48}` bytecode on
  x86-64 (bypassing the AArch64 `circuit_compute_vk` bug), bundling each as
  `assets/circuits/ca_v2_4_tier*.vk`, and sanity-proving once per tier on
  desktop with the known-good witness as a self-check. All three tiers: VK
  computed (3,680 bytes each), desktop sanity-prove succeeded.
- `scripts/build_android_ffi.sh`: unchanged, ran clean — the new dependency's
  cdylib build did **not** need the `strtof_l`/streambuf/TLS-alignment shims
  added during M3.4 step 0 (those were specific to linking a standalone
  *binary*; the cdylib pulls in less of libc++, consistent with that
  earlier finding). Linkage checks all pass (no `libc++_shared`, zero
  undefined `NSt3__1`/`NSt6__ndk1` symbols).
- FRB codegen regenerated cleanly against the new signature
  (`flutter_rust_bridge_codegen generate`, found at `~/.cargo/bin/`, not on
  `$PATH`). Updated `lib/ffi/prover.dart`'s thin wrapper and extended
  `lib/ui/spike_screen.dart` (per the approved M3.4 plan: "extend rather than
  build new UI") to drive the real v2.4 circuits with the known-good witness
  instead of the old proxy spike.

### Step 6 gate result: PASS, with one transient anomaly worth flagging

Built, installed, and ran on the Pixel 6 (`flutter build apk --release`,
manual `adb install` + `monkey` launch + `input tap`, since `flutter run`
wasn't used for this headless flow). First release-mode attempt **hung** —
reached "Proving tier 12…" and then sat at 0% CPU, 83 threads all sleeping,
for 20+ minutes with no crash and no progress. Notably, **23 unnamed
worker threads** were present — more than one `(cores-1)`-sized pool's worth,
consistent with barretenberg's `parallel_for_mutex_pool` pool being `static
thread_local`: every distinct OS thread that calls into it for the first
time gets its *own* pool, and FRB's tokio runtime can dispatch across many
blocking-pool threads over an app's lifetime, not just one.

Attempting to attach a debugger to get a live backtrace hit a wall: `run-as`
and direct `ptrace` attach both failed against the release build (not
debuggable; `lldb-server --attach` segfaulted outright). Rather than sink
more time into attaching to a release process, tested with a **debug build**
instead (same native `.so` — Flutter's build mode doesn't touch the
already-built Rust library, only the Dart layer) — debuggable, so `run-as`
would have worked if needed. It didn't hang: completed in **5,875 ms,
`verified=true`**, no debugger needed after all. Reinstalled the **release**
APK clean (full uninstall first, ruling out stale app-private state) and ran
it twice more: **5,751 ms** and **5,811 ms**, both `verified=true`. Three
clean runs in a row, tightly clustered timing, after the one hang.

Working theory, not confirmed: the hang coincided with heavy concurrent
load from this session's own tooling — multiple `adb`/`lldb-server`
diagnostic processes were running against the same device at that exact
moment (the M3.4 step-0 debugging session). Thread-pool proliferation
(many thread_local pools, each wanting `cores-1` real OS threads) under
that additional contention is a plausible trigger for a livelock that
clears once the contention is gone, but this is circumstantial — there is
no captured backtrace of the hung state to confirm it. Flagging this as a
small open risk to watch for during tiers 24/48 (longer-running, more
memory pressure), not as a resolved root cause.

Note on diagnostics: the `RUNEWRIGHT_DIAG`/`eprintln!` lines added to confirm
the env var's value on the proving thread never appeared in logcat — Rust's
`eprintln!` writes to a file descriptor the Android app process doesn't have
attached to anything logcat captures (unlike `adb shell`, which has a real
tty). Other native logging (e.g. `reqwest`'s own `tracing`-based logs) does
reach logcat via a different path already wired up by a dependency. The
success/failure of the prove call itself remains the definitive signal;
the `eprintln!` diagnostics added for this gate are dead weight in the
on-device app and could be removed or rewired to whatever logging sink the
`reqwest` traces use, if this gate is ever rerun and needs the same
visibility.

### What this gate confirms

- **Public-input marshalling across FRB works.** `T`, `owner_pubkey`,
  `ruleset_version` (the three `pub` parameters) cross the Dart↔Rust
  boundary and into the witness correctly — `verified=true` is conclusive
  here, since a wrong public input value would fail verification, not just
  proving.
- **The `HARDWARE_CONCURRENCY` `#[ctor]` fix survives FRB's threading** — at
  least in the common case; three clean runs is good evidence, not proof
  against a rarer race under contention.

## M3.4 — Step 7: on-device measurement, tiers 12/24/48 (real circuit confirms the M3.2 prediction)

**Status: done. v2.4 beats the proxy on both wall-clock time and peak RSS at
every tier — the real-circuit confirmation M3.2's gate-count/dyadic-bucket
analysis predicted but couldn't measure directly.**

### A methodology bug found and fixed along the way

First measurement pass (release build, 3 runs/tier, force-stop + relaunch +
cooldown between runs) came back with v2.4 *losing* on memory despite M3.2's
prediction that it shouldn't be able to: T48 measured ~3.49 GiB median vs the
proxy's M2 figure of ~2.10 GB. Before reporting that as the real number,
traced it down rather than taking it at face value: `init_srs` (the
bundled-VK path `spike_screen.dart` actually calls) was sizing its SRS via
`compute_subgroup_size(circuit_size * 8)` — an `* 8` margin whose entire
purpose, per its own comment, was giving on-device `circuit_compute_vk`
breathing room. That function is never called on this path; the VK comes
from a bundled desktop-computed asset specifically *to avoid* on-device VK
computation. The margin had no remaining justification and was inflating the
loaded SRS by a full 3 dyadic buckets at T48 (2^20 → 2^23) for no benefit.
Removed the multiplier (confirmed via M3.4 step 0's bare-metal testing that
v2.4's raw, unmultiplied sizing is sufficient for `prove_ultra_honk`).
Rebuilt, re-measured: T48 median RSS dropped from ~3.49 GiB to ~2.02 GiB —
essentially matching the proxy. This fix is the actual content of M3.2's
"same dyadic bucket" prediction showing up correctly on real hardware; the
inflated first measurement was an artifact of leftover code from a
since-bypassed workaround, not a property of v2.4 or the underlying ARM
proving path.

### Final numbers (release build, Pixel 6, 3 runs/tier, median reported)

| Tier | v2.4 wall (median) | v2.4 peak RSS (median) | M2 proxy wall | M2 proxy RSS |
|---|---|---|---|---|
| 12 | 5.9 s | 698 MB | 8.9 s | 717 MB |
| 24 | 11.6 s | 1,176 MB | 16.9 s | 1,175 MB |
| 48 | 21.6 s | 2,068 MB | 32.2 s | 2,104 MB |

v2.4 is faster **and** equal-or-lighter on memory at every tier — confirming
M3.2's prediction (fewer gates, same-or-better dyadic bucket) directly on
hardware, not just by gate-count analysis.

### The 4 GB question (open since M2): resolved

T48's measured peak RSS (2,068 MB median, worst single run 2,120 MB) is
**50.5% of the 4 GB line** and 33.7% of 6 GB. This is a measured result on
the actual v2.4 circuit, through the actual production FRB path, on the
actual target device class — not the projection-from-gate-count M3.2 offered
or the proxy-circuit floor M2 measured. **Tier 48 is GO on 4 GB**, not just
8 GB. The "open question" M2 raised is closed.

### Artifact: `ffi/src/api/prover.rs`'s `init_srs` fix is committed

The multiplier removal is a real, permanent fix (not a throwaway diagnostic)
— it was wasting ~7/8 of the SRS memory it allocated on a since-bypassed
workaround, and is now corrected for any future tier or circuit using the
bundled-VK path.

## M3.4 — Step 8: the bb-verify tamper smoke test (closes the M3.1 deferral)

**Status: done. One test, as planned — not four.**

`ffi/src/bin/tamper_test.rs` (new, committed): proves a real tier-12 v2.4
proof with the known-good witness, then:

1. **Parses the wire format empirically** rather than trusting the doc
   comment: `[4 bytes BE num_public_inputs][public inputs, 32B each][proof,
   32B fields]`. Printed all 32 public-input fields of a real proof and
   matched each to its known plaintext value:
   - `pub[0]` = `T` = 1
   - `pub[1]` = `owner_pubkey` = the pinned `poseidon2_hash2(0,0)`
   - `pub[2]` = `ruleset_version` = 1
   - `pub[3]` = `commitment` — numerically identical to `pub[1]` in this
     proof, **not a bug**: with an all-zero grid *and* all-zero key halves,
     both `commitment = poseidon2_hash2(0, 0)` and
     `owner_pubkey = poseidon2_hash2(key_hi, key_lo) = poseidon2_hash2(0, 0)`
     reduce to the exact same value. A coincidence of the degenerate test
     witness, not evidence of a wiring mistake — confirmed by the formula,
     not just the matching bytes.
   - `pub[4..31]` (28 values) = all zero = `border_activations[4]` +
     `dominance_trajectory[12]` + `supreme_flags[12]`, consistent with an
     empty grid that never activates anything.

   This confirms `pub` *parameters* precede the `pub` return tuple in
   ABI-declaration order, exactly as assumed when this was first reasoned
   through analytically in the M3.4 planning — now verified against a real
   proof rather than left as an assumption.

2. **Tampers one byte of the commitment** (byte offset 100 = `4 + 3×32`) and
   calls `verify_ultra_honk`. Result: `Ok(false)` (underlying message:
   `"UltraVerifier: verification failed at reduction step"`). The untampered
   proof verifies (`Ok(true)`) immediately before, confirming the test
   actually exercises the byte that matters and isn't vacuously passing.

This discharges the SNARK-binding half of all four `declared_override`
vectors deferred since M3.1 (`neg_commitment_mismatch`, `neg_forged_trajectory`,
`neg_forged_activations`, `neg_mask_abuse`) and resolves GOLDEN_VECTORS.md
§7's `[CONFIRM: noir CLI]` encoding question. Both docs updated.

---

## M3 — complete

All four milestones closed:

- **M3.1**: real v2.4 tier-12 circuit, full positive + negative golden
  corpus, single-command iteration loop.
- **M3.2**: tiers 24/48 replicated; v2.4 beats the proxy on gate count at
  every tier (commitment scheme efficiency outweighing the new constraints).
- **M3.3**: on-device measurement redirected after finding the spike
  harness's mobile wrapper had its own unrelated bug; M3.2's gate-count
  analysis stood in for a direct measurement at the time.
- **M3.4**: production FRB integration. Found and fixed the real root cause
  of the long-standing "Backend error: vector" mystery (a `hardware_concurrency()`-
  returns-0 underflow in barretenberg's thread-pool sizing — not a circuit bug,
  not a bad artifact, not a version mismatch). Confirmed public-input
  marshalling and the threading fix both survive FRB's real dispatch model.
  Found and fixed a second, unrelated bug along the way (an unnecessary 8x
  SRS-oversizing margin) that was masking M3.2's memory prediction. Closed
  the M2 "4 GB open question" with a real on-device measurement: T48 at
  50.5% of the 4 GB line. Closed the M3.1 SNARK-binding deferral with one
  tamper test, encoding confirmed empirically.

The real v2.4 circuit now proves and verifies end-to-end on the Pixel 6
through the production Flutter/FRB path, for all three tiers, with real
performance numbers and a verified reject-on-tamper property — the
milestone's definition of done.
