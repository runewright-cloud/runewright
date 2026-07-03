# M4 — Findings Log (live, updated per milestone)

## Battle protocol security audit (B-round) — pre-existing divergence findings

### `nextSpellCostDouble` state-hash desync (pre-existing, fixed in B-1/B-8 pass)

**Severity:** State-hash mismatch (protocol violation / match abort) whenever
`nextSpellCostDouble` fires for a peer spell.

**Root cause:** `nextSpellCostDouble` is a status effect tracked in
`WizardAvatar.activeStatusEffects`, which is included verbatim in
`BattleState.toCanonicalBytes()` (the end-of-turn state hash). When a peer
casts a spell while the effect is active, the caster's client deducts the
doubled cost and removes the effect in phase 1 via `_spellManaCost`.
The verifier's former `_spellManaCostFromProof` never touched `activeStatusEffects`
at all — it didn't consume `nextSpellCostDouble`, didn't apply the HP-shortfall
conversion, and didn't remove the entry. At state-hash exchange, the caster has
removed one status effect; the verifier still holds it. The hashes diverge
deterministically every time the effect fires on a peer spell.

**The same bug pattern applies to the sorcerer-mode `manaCostMultiplier`:** the
caster applied the vocal-quality penalty multiplier in phase 1 via
`CastingEnhancements.fromSorcererQuality`; the verifier's
`_spellManaCostFromProof` did not, causing the two devices to deduct different
mana amounts from the peer's avatar — a live ledger divergence, though not a
state-hash divergence (mana is in the hash, but the effect list removal is the
immediate trigger).

**Fix:** `_spellManaCostFromProof` replaced by `_certifiedManaCost`
(B-1/B-8 pass, `lib/battle/engine/turn_loop.dart`). The new function applies
operations in the same sequence as `_spellManaCost`: certified base → chain
discount → sorcerer multiplier → `nextSpellCostDouble` (consume + HP shortfall +
effect removal). Both paths now produce identical mana deductions and identical
`activeStatusEffects` mutations for the peer, so the end-of-turn state hash
agrees.

**Scope:** 2-player only. Affects any match turn where a peer casts a spell and
`nextSpellCostDouble` is active in their status-effect list. Was silently
unreachable in hardware testing because `nextSpellCostDouble` is not yet granted
by any effect — first cast to grant it would have triggered the mismatch.

---

## M4.7 — Loose-ends cleanup sweep (post-gate)

Five items logged during the M4.6 hardware run, addressed in order of
importance. None of these block the gate result (M4.6) -- this is hardening
and trap-removal. A sixth, unplanned item came directly out of fixing
item 4 (below) -- see "Bonus finding."

### Bonus finding: item 4's fix exposed a real frame-drop race in `MatchSession`

Verifying "the full suite stays green" surfaced a genuine bug, not a test
artifact. After fixing item 2 from M4.6 (`runVerifierFlow` now calls
`initSrsCached` before `verifyIncomingProof`, to initialize the CRS),
`test/ui/gate_runner_test.dart`'s rejection-path test started reliably
**hanging** for the full 60s timeout -- both standalone and in the full
suite.

Root cause, in `lib/protocol/match_session.dart`: `_onFrame` only delivers
an incoming frame if `_pending` (a completer set by `_awaitNextFrame()`) is
already non-null -- **a frame that arrives before anything is waiting for
it was silently dropped**, not buffered. This was always a latent race
(any verifier-side setup latency before the first `_awaitNextFrame()` call
-- asset loads, anything -- could lose this race against a prover fast
enough to have already sent), but the window had apparently never been
wide enough in practice to lose reliably until item 4's fix added a real
disk-I/O `await` (the CRS init) in front of `verifyIncomingProof()`'s call.
**This is not a test-only concern: in the real game, any verifier-side
setup work before the first frame is awaited creates the identical window
against a prover peer who already sent.**

Fix: `MatchSession` now buffers at most one frame (`_bufferedFrame`) when
`_onFrame` fires with nothing waiting; `_awaitNextFrame()` checks that
buffer before creating a new completer. Matches the existing strict
request/response, no-pipelining design (`FrameReader`'s own doc comment)
-- only ever one frame in flight, so buffering exactly one is sufficient
and correct, not a partial fix.

Verified: the previously-hanging test now passes in ~8s, standalone and
inside the full suite; the entire protocol suite (`wire_test.dart`,
`match_session_test.dart`, `match_session_socket_test.dart`,
`lan_discovery_test.dart` -- 26+ tests) re-confirmed green afterward, so
the fix didn't regress anything the relay-attack/replay/rejection tests
depend on.

### 1. mDNS interface selection -- logic fixed and unit-tested; end-to-end discovery still a hardware follow-up

`lib/protocol/lan_discovery.dart` gained `filterRealWifiAddresses` and
`selectBestAddressFrom`/`selectBestAddress`: excludes Wi-Fi-Direct-named
interfaces (substring match on `p2p`, covers OEM variants like
`p2p-wlan0-0`) and Android's reliable Wi-Fi Direct subnet
(`192.168.49.0/24`) as a second, independent check (defense in depth in
case an OEM names a p2p interface something that doesn't contain "p2p").
When picking among a peer's resolved addresses, prefers one sharing this
device's own real-Wi-Fi /24 subnet -- both duel peers on the same AP share
a subnet; their respective Wi-Fi Direct addresses never do. Falls back
gracefully (excludes-Wi-Fi-Direct, then "first address") rather than
failing outright if every candidate looks suspect. `gate_screen.dart`'s
"Listening on ..." display hint now calls the same `preferredLocalAddress()`
instead of duplicating its own (buggy) interface-picking logic.

10 unit tests in `test/protocol/lan_discovery_test.dart`, all green,
against representative interface lists modeled on exactly what the M4.6
hardware run saw (a real `wlan0` alongside a `p2p0`/`192.168.49.x`
interface).

**Still open, flagged explicitly per the M4 plan's done-state:** this
closes the *logic* gap, but automatic mDNS discovery connecting two real
devices over real Wi-Fi has not been re-confirmed on hardware since this
fix landed -- `nsd` has no Linux desktop backend at all (M4.4), so this dev
machine cannot exercise real discovery regardless. **The M4.6 hardware run
used manual IP entry, not automatic discovery, and that remains the
validated path.** Confirming automatic discovery now correctly prefers the
real Wi-Fi address end-to-end is a two-device follow-up for Soren's next
hardware session, not something closable from this machine.

### 2. Stale `.so` guard

`scripts/check_ffi_fresh.sh` (new): compares the deployed Android `.so`'s
mtime against every file under `ffi/src/`; prints a clear "stale, run
build_android_ffi.sh" message and exits 1 if any source file is newer.
Converts the M4.6 launch-crash failure mode ("Content hash on Dart side is
different from Rust side") into an early, legible warning. Verified both
directions: flags staleness correctly when a source file is touched, and
reports clean once rebuilt. Added as Bug Avoidance Reminder #3 in
`CLAUDE.md` (alongside a new #4 for the CRS-init bug, M4.6) so it's
actually run, not just available. Confirmed via dogfooding: correctly
flagged itself stale again after this cleanup's own edit to
`ffi/src/api/prover.rs` (the atomic-write change, item 4 below) -- left
that staleness in place since no device run is needed for this cleanup
pass; rebuild before the next one.

### 3. Undersized dev SRS fixture -- deleted, not routed around

`~/.bb-crs/bn254_g1.dat` (16 MB, exactly 2^18 G1 points -- correctly sized
for tier-12's *unmultiplied* requirement specifically, not generically
"undersized") was a dev-machine-local artifact, never part of the repo,
left behind after `lib/ffi/prover.dart`'s `initSrs(srsPath:)` forwarding
was reverted in favor of `initSrsCached`. Confirmed via grep that nothing
in the codebase referenced it any more. Deleted outright, and rewrote the
stale comment in `prover.dart` (which named a Dart constant,
`gate_runner_test.dart`'s `_kSrsCachePath`, that no longer exists --
already-removed in M4.6) to explain the actual failure mode (file sized
for one circuit's point count breaks silently if reused for a bigger tier
or a multiplied-margin code path) without pointing at a fixture that could
trap a future session into the same confusion again.

### 4. Atomic SRS cache write

`ffi/src/api/prover.rs`'s `get_srs_cached` previously wrote a freshly
downloaded SRS straight to `cache_path` via `LocalSrs::save` (a single
non-atomic `std::fs::write` internally, confirmed by reading the `noir_rs`
source). An interrupted write (app killed mid-save, flaky in-person
network) could leave `cache_path` itself half-written -- and since
`get_srs_cached` only checks "does the file exist," every subsequent run
would hit the existing corrupt-file error path forever, never
self-healing.

New `save_srs_cache_atomic`: serializes to a uniquely-named temp file in
the same directory as `cache_path` (same filesystem -> the final rename is
atomic per POSIX), `fsync`s the temp file's actual on-disk contents
(`LocalSrs::save`'s internal `fs::write` doesn't fsync, so without this an
interrupted-at-power-loss case could still rename in data that was never
flushed to disk), then renames into place. A failure or panic at any point
before the rename leaves only the never-read temp file behind --
`cache_path` is either still absent or still holds its previous contents,
never a partial write. Confirmed corrupt-cache handling (the pre-existing
`corrupt_cache_file_returns_err_not_panic` test) still covers the
genuinely-corrupt case (e.g. an old version's cache format, or
filesystem-level bit rot) -- atomicity prevents *new* corruption from
interrupted writes; it doesn't and shouldn't change how an
already-corrupt file already on disk is handled.

Two new Rust tests: `atomic_save_round_trips_and_leaves_no_temp_file`
(happy path, plus confirms no `.tmp-*` leftovers) and
`failed_save_does_not_create_a_partial_file_at_cache_path` (forces a
write failure by targeting a nonexistent parent directory; confirms
`cache_path` is never touched, not even partially). All 7 Rust tests pass
(5 pre-existing + 2 new; 1 of the pre-existing 6 is `#[ignore]`d by design,
requires a real network-denial environment).

### 5. `connect_path` label imprecision -- fixed

`gate_screen.dart`'s `_listenAndAdvertise` labeled every incoming
connection `connect_path=mdns`, even though the listening side cannot
actually tell whether the peer found it via mDNS discovery or typed the
address manually (both produce an identical incoming TCP connection) --
this is exactly what the M4.6 hardware run's log showed (Pixel 9 logged
`connect_path=mdns` even though Pixel 6 connected via manual IP entry).
Relabeled to `connect_path=listening`, with a code comment explaining why
`mdns` would overclaim a path that was never actually observed from the
acceptor's side. The *initiating* side's label was already accurate
(`manual_ip` / will be `mdns` once discovery is hardware-confirmed) and is
unchanged.

### Verification run

- `flutter test test/protocol/lan_discovery_test.dart`: 10/10 pass.
- `cargo test --lib` (ffi/): 7/7 pass (1 ignored by design).
- Full protocol suite after the bonus frame-buffering fix
  (`wire_test.dart`, `match_session_test.dart`,
  `match_session_socket_test.dart`, `lan_discovery_test.dart`): all green,
  confirming the fix didn't regress the relay-attack/replay/rejection
  tests that depend on this exact dispatch path.
- **Full `flutter test` suite (94 tests across every file, including the
  parallel onboarding/spell-inscription work's tests): 93/94 pass.** The
  one failure, `test/widget_test.dart`'s "Game screen renders hex grid",
  is **pre-existing and unrelated** to M4 -- it asserts against the old
  `GameScreen`-direct UI (`find.text('Rune Duel')`, a "Step" button, a
  "Fire" rule button), but `main.dart`'s `home` now points to `AppRoot()`
  (the Step 1 onboarding flow, from the parallel onboarding session, not
  touched by M4 at all). Confirmed via reading `main.dart`/`widget_test.dart`
  directly, not just "presumed pre-existing" -- this is a stale smoke test
  left behind by the onboarding work's app-structure change, out of this
  cleanup's scope to fix (not an M4/networking concern, and fixing it would
  mean editing test assumptions about in-progress, not-mine onboarding UI
  work). Flagged here rather than silently left unmentioned.
- Full golden-vector corpus + Dart stepper regression: zero regression
  (circuits/stepper untouched by this cleanup).
- `flutter analyze`: clean throughout.
- The Android `.so` is currently flagged stale by `scripts/check_ffi_fresh.sh`
  (the bonus `match_session.dart` fix + item 4's `prover.rs` change
  postdate the last `cargo ndk` build). Deliberately left unrebuilt --
  no device run is part of this cleanup pass -- run
  `bash scripts/build_android_ffi.sh` before the next one.

---

## M4.6 — THE GATE: real two-device hardware run, ACCEPTED on both sides

### Result

Full success, both directions of the M4 plan's milestone gate, on real
hardware (Pixel 6 + Pixel 9, both on the same real Wi-Fi AP, no special
network configuration). Pixel 6 = Prover/Signer, Pixel 9 = Verifier/
Challenger, connected via the manual-IP path. Every step passed on both
devices:

```
Pixel 6 (prover):  connect → handshake → identity → proof_generated
                    (wall_ms=5702, matches the historical ~5.9s Pixel 6
                    tier-12 figure from M3.4) → proof_sent → final=accepted
Pixel 9 (verifier): connect → handshake → vk (CRS initialized) →
                    proof_received (17028B) → proof_verified=true →
                    owner_pubkey_matched=true → challenge_issued →
                    signature_verified=true → final=accepted
```

Full `RUNEWRIGHT_GATE` logcat trace from both devices, real timestamps:

```
Pixel 6:
15:50:34.928 step=discovered  value=n/a      connect_path=manual_ip detail="manual entry 192.168.1.229:42223"
15:50:34.928 step=connected   value=true     connect_path=manual_ip detail="manual_ip"
15:50:35.387 step=identity_loaded value=true connect_path=manual_ip detail="owner_pubkey=0x0e4a6a966b1a198563bdc672c3e412b3e915fc9e9ee19db1a4e118720e0bf94e"
15:50:42.246 step=proof_generated value=true connect_path=manual_ip detail="wall_ms=5702"
15:50:42.246 step=proof_sent  value=true     connect_path=manual_ip
15:50:43.458 step=signature_returned value=true connect_path=manual_ip
15:50:43.458 step=final       value=accepted connect_path=manual_ip

Pixel 9:
15:50:04.270 step=discovered  value=n/a      connect_path=mdns detail="host: listening on 192.0.0.4:42223"
15:50:05.165 step=discovered  value=true     connect_path=mdns detail="advertised as Runewright Duel"
15:50:35.369 step=connected   value=true     connect_path=mdns detail="mdns/manual host"
15:50:42.704 step=proof_received value=true  connect_path=mdns detail="17028B"
15:50:42.763 step=proof_verified value=true  connect_path=mdns
15:50:43.824 step=owner_pubkey_matched value=true connect_path=mdns
15:50:43.824 step=challenge_issued value=true connect_path=mdns
15:50:43.824 step=signature_verified value=true connect_path=mdns
15:50:43.824 step=final       value=accepted connect_path=mdns
```

This closes the M4 milestone: identity, the match protocol, the LAN
transport, and on-device proving all confirmed working together, end to
end, on two physical devices.

### A real bug the hardware run found that no automated test had caught

`verify_ultra_honk` requires barretenberg's global CRS initialized via a
prior `srs_init` call. On the prover side this always happened
incidentally (proving calls `initSrsCached` first). The verifier path
(`GateRunner.runVerifierFlow`) never called anything that initializes it,
and the first hardware run failed with `circuit_verify failed: Backend
error: You need to initialize the global CRS with a call to
init_crs_factory(...)`.

**This is a real bug in the production match-protocol path, not a
harness-only issue:** any real duel verifier who hasn't proven anything in
that app session yet would hit the identical failure the first time they
verify an opponent's proof. **No desktop test caught it** because
`test/ui/gate_runner_test.dart`'s happy-path test runs both prover and
verifier in the *same process* -- the prover's SRS init incidentally
populates the same global barretenberg state the verifier's `verify_proof`
then reads, masking the missing initialization entirely. Two separate
device processes, each with their own process-local global CRS state, was
the only thing that surfaced this. This is exactly why the M4 plan called
the two-device run a milestone gate rather than trusting automated tests
alone to close M4.

**Fix:** `GateRunner.runVerifierFlow` now also calls `initSrsCached` (sized
to the same circuit bytecode) before verifying, even though it never
proves. `runVerifierFlow`'s signature gained `circuitJson`/`srsCachePath`
parameters to match `runProverFlow`'s shape. Confirmed fixed by the
hardware run above. The same fix should be carried into the real (non-
diagnostic) match protocol wiring whenever it's built -- **a verifier must
initialize the SRS/CRS before its first `verify_ultra_honk` call,
independent of whether it has ever proven anything in that session.**

### Two smaller findings from the hardware run (logged, not blockers)

- **`_localIpHint()` picks the wrong interface on real Android hardware.**
  Pixel 9 displayed "Listening on 192.0.0.4:42223" -- that's a Wi-Fi Direct
  p2p interface, not the real Wi-Fi address (192.168.1.229, confirmed via
  `adb shell ip addr show wlan0`). The underlying socket is still correct
  (bound to `InternetAddress.anyIPv4`, reachable on every interface
  including the real one) -- this only affects the *displayed* hint text
  used for manual-IP entry. `_localIpHint()`'s "first non-loopback IPv4
  from `NetworkInterface.list()`" is too naive on real devices with
  multiple interfaces; it should prefer the `wlan0`-equivalent
  specifically. Cosmetic for the gate harness (worked around by knowing
  the real IP independently for this run); worth fixing before this UI
  pattern is reused anywhere a player relies on the displayed hint.
- **`connect_path=mdns` is logged on the listening side even when the
  peer actually used manual IP entry.** `_connectPath` is set to `'mdns'`
  as soon as "Listen + Advertise" is tapped (since that path always also
  advertises via mDNS), but doesn't distinguish "a peer discovered me via
  mDNS" from "a peer typed my IP manually" -- both arrive as the same
  `acceptOnce()` completion. The *initiating* side's log is accurate
  (`connect_path=manual_ip` correctly reflects what Pixel 6 did); only the
  listening side's label is imprecise. Logged for awareness, not fixed --
  doesn't affect this run's validity since Pixel 6's own log is unambiguous
  about which path was actually used.

### Verification run

- Real hardware: Pixel 6 (`18261FDF60069A`) + Pixel 9 (`4B070DLAQ002FQ`),
  both on the same Wi-Fi AP, full ACCEPTED both directions (see above).
- `flutter analyze`: clean throughout.
- `test/ui/gate_runner_test.dart` re-confirmed green after the CRS-init fix
  (now more faithfully exercises the verifier's independent SRS init,
  rather than incidentally relying on the prover's in-process state).
- Found and fixed, before it could affect a real build: an Android `.so`
  staleness issue (content-hash mismatch between Dart FRB bindings and the
  compiled Rust `.so` -- `ffi/src/api/identity.rs` and the `init_srs_cached`
  addition to `prover.rs` postdated the last `cargo ndk` build, causing an
  immediate crash on launch: "Content hash on Dart side is different from
  Rust side"). Rebuilt via `scripts/build_android_ffi.sh`; all linkage
  checks passed. **General lesson for next time:** after any Rust-side FFI
  change, the Android `.so` needs an explicit rebuild before the next
  device run -- it is not regenerated automatically by `flutter build`.

---

## M4.5 — Two-device gate harness (diagnostic UI, not game UI)

### What was built

- **`lib/ui/gate_runner.dart`**: pure async orchestration (no Flutter
  widget dependency) for the prover/signer and verifier/challenger flows.
  Calls only existing, already-tested entry points -- `MatchSession`,
  `Identity`, the FFI prover -- in the same sequence those modules already
  define; adds no new protocol/crypto logic.
- **`lib/ui/gate_screen.dart`**: the actual screen. Two first-class connect
  paths (Listen+Advertise via `lan_discovery.dart`/mDNS, and a manual
  host:port field that bypasses discovery entirely), a role toggle
  (Prover/Signer vs Verifier/Challenger), and a per-step status list. Wired
  as the app's `home` (superseding `SpikeScreen` the same way `SpikeScreen`
  superseded the M2 spike before it -- not deleted, just no longer `home`).
- **Per-step visibility, without touching protocol logic:** most steps
  (`owner_pubkey_matched`, `challenge_signature`, etc.) are reconstructed
  from a thrown `ProtocolException`'s `(reason, message)` or from
  `presentProof`/`verifyIncomingProof`'s successful completion --
  `match_session.dart` was **not** modified to add progress callbacks, per
  the explicit instruction to stop and flag rather than touch protocol
  logic. This works because `RejectReason` is already an ordered,
  exhaustive enum of exactly where a rejection happens (a consequence of
  how the protocol was designed in M4.1, not a new mechanism). The one step
  with genuine **live** visibility, `proof_verified`, uses the
  `verifyIncomingProof(verifyProof: ...)` injection seam that already
  existed for testing -- the harness's `verifyProof` callback reports status
  before returning the bool, which is not a protocol change either.
- **Minimal, additive lifecycle methods added to the transport layer**
  (flagged, not silently done): `LanListener.close()` (cancel a listener
  before it accepts -- was previously impossible to release without an
  incoming connection) and using the already-existing but previously-unused
  `MatchSession.close()` in the screen's teardown path. Neither changes any
  existing behavior; both fill a gap any well-behaved caller of `bind()`
  would eventually hit.
- **Connect-path layer isolation, by design:** mDNS advertise failing does
  not block the listening socket from accepting a manual-IP connection --
  the advertise call is wrapped separately and logged as its own
  found/not-found event, so a real-device run can tell "mDNS doesn't work
  here" apart from "sockets don't work here" instead of one opaque failure.
- **Caught a real bug before it shipped:** the first draft used the name
  `StepState` for the harness's own enum, which collides with
  `package:flutter/material.dart`'s `Stepper` widget's own `StepState` --
  silently ambiguous-import errors, not a runtime bug, but would have
  blocked compilation. Renamed to `GateStepState`.

### Verification run

- **`test/ui/gate_runner_test.dart` -- the harness's logic confirmed against
  the real stack**, not mocks: real on-device (desktop) proving of the
  fixed tier-12 witness with a real `Identity.ephemeral()` key, real
  `MatchSession` exchange over real localhost TCP sockets, real
  `verify_ultra_honk`. Two tests:
  - Happy path: both sides reach `final = pass`; `proof_generated` carries
    a real `wall_ms` (~2.3-2.4 s on this desktop, consistent with prior
    M2/M3 desktop-proving figures); `proof_verified` confirmed to fire live
    via the injection seam, not just inferred from success.
  - Rejection path: a real, cryptographically valid proof presented under
    the *wrong* pubkey -- confirms `proof_verified = pass` but
    `owner_pubkey_matched = fail` are correctly distinguished, i.e. the
    granular reporting genuinely isolates *which* check failed rather than
    collapsing to one generic failure.
  - Both used the cached SRS (`~/.bb-crs/bn254_g1.dat`, 16 MB) -- no
    network download needed in this environment.
- `flutter analyze`: clean.
- Golden-vector corpus: zero regression (untouched by this milestone).

### What this does NOT verify (the actual gate)

- mDNS advertise/discover on real hardware (no Linux backend at all --
  same limitation as M4.4).
- Real radio behavior (Wi-Fi association, AP/client isolation, multicast
  deprioritization).
- The actual UI rendering/interaction (button taps, step list updates) --
  `gate_runner_test.dart` exercises the orchestration logic the screen
  calls into, not the screen itself.
- A second physical device, full stop.

This harness is ready for the two-device run. It needs two phones on a
controlled Wi-Fi network -- Soren's to perform.

---

## M4.4 — mDNS/NSD discovery + Android manifest permissions

### What was built

- **`lib/protocol/lan_discovery.dart`**: `advertiseDuelHost`/
  `stopAdvertisingDuelHost` (register/unregister an `_runewright._tcp`
  service) and `discoverDuelHosts`/`stopDiscoveringDuelHosts` (start/stop
  discovery), plus `connectToDiscoveredService(Service)` which feeds a
  resolved service's address/port straight into
  `LanSocketTransport.connectTo`. Uses `package:nsd` rather than
  `multicast_dns`: `nsd` wraps the native NSD/Bonjour stack on each platform
  and supports *registering* (advertising) a service, not just resolving
  one -- `multicast_dns` is a pure-Dart mDNS *client* only and would need a
  hand-rolled mDNS responder to advertise.
- **Deliberately not wired into `Transport`'s `advertise()`/`discover()`/
  `connect()` methods.** Those three thin method signatures don't fit
  `nsd`'s actual shape (a `Service` object, a `Registration` handle to
  unregister later, a `Discovery` that streams multiple found/lost peers
  over time) without losing information or stashing hidden state. Both
  `InMemoryTransport` and `LanSocketTransport` already treat
  advertise/discover/connect as no-ops, with real connection setup via
  dedicated static factories instead (`pair()`, `bind()`+`connectTo()`).
  `lan_discovery.dart` follows the same shape: a separate layer that
  *produces* a connected `LanSocketTransport`, not a method bolted onto
  one. Consistent with the existing pattern, not a new exception to it.
- **Android manifest** (`android/app/src/main/AndroidManifest.xml`): added
  `CHANGE_WIFI_MULTICAST_STATE`, per `nsd`'s own README-documented Android
  requirement. `INTERNET` was already present (covers the LAN sockets).
  **Correction to the M4 brief's guess:** the brief suggested
  `ACCESS_WIFI_STATE` would "likely" be needed too -- checked against the
  package's actual documented requirements rather than assuming, and it
  isn't; only `CHANGE_WIFI_MULTICAST_STATE` is listed. Not added, since
  nothing in this codebase uses it for anything (no Wi-Fi-state queries
  exist), and unused permissions are something to avoid, not hedge in.
- **Caught a real bug before it shipped:** the first draft of the manifest
  comment used `--` (double hyphen) inside an XML comment, which is invalid
  per the XML spec and would have broken the Android build. Caught by
  validating the manifest with a parser before moving on, not by trusting
  the edit -- worth calling out since it's exactly the kind of error that's
  invisible in a diff review but fails at build time.

### Known limitation: cannot be tested in this dev environment

- `nsd`'s platform support is Android/iOS/macOS/Windows -- **no Linux
  desktop backend at all** (unlike `flutter_secure_storage`, which at least
  has a native Linux plugin reachable only outside `flutter test`; `nsd`
  has no Linux implementation to reach regardless of how it's run). There
  is no way to exercise real mDNS advertise/discover from this machine.
- This isn't a gap to paper over: real mDNS discovery is inherently a
  real-network concern (AP/client isolation on guest Wi-Fi, multicast
  deprioritization, platform-specific timing) that **only the two-device
  validation gate can actually test**, per the M4 plan's own "characterize,
  don't assume a code bug" guidance. Nothing here substitutes for that.

### Verification run

- `flutter analyze`: clean (after fixing the manifest XML comment bug
  above; re-validated with `xml.etree.ElementTree` before considering it
  done).
- `dart pub get`: `nsd` resolves cleanly alongside the rest of the M4
  dependencies.
- No automated test for `lan_discovery.dart` itself (see limitation above);
  the code is exercised for the first time at the two-device gate.

---

## M4.3 — LAN socket Transport: localhost checkpoint (abstraction-integrity confirmed)

### What was built

- **`LanSocketTransport`** (`lib/protocol/lan_socket_transport.dart`): a
  `Transport` adapter over `dart:io` TCP sockets. `LanSocketTransport.bind()`
  + `LanListener.acceptOnce()` for the listening side (split into two steps
  so the caller learns the OS-assigned port before a peer connects),
  `LanSocketTransport.connectTo(host, port)` for the dialing side -- mirrors
  `InMemoryTransport.pair()`'s "two already-connected ends" shape rather
  than using the interface's `advertise/discover/connect` methods directly
  (same as `InMemoryTransport`; those become meaningful once mDNS discovery
  is wired in as a separate piece).
- **Zero changes to `MatchSession` or the protocol logic.** Confirmed by
  literally sharing the test bodies: `test/protocol/match_session_suite.dart`
  holds all 6 protocol tests parameterized over a `Transport`-pair factory;
  `match_session_test.dart` (in-memory) and `match_session_socket_test.dart`
  (real localhost sockets) both call the identical suite. This is the
  abstraction-integrity check the plan asked for, made structurally
  impossible to fake (the same test code runs against both transports, not
  just "tests with the same names").
- **Why `LanSocketTransport` needed no framing logic of its own:** TCP is a
  byte stream, not message-delimited, but `MatchSession` already routes
  every incoming chunk through `wire.dart`'s `FrameReader`, which was built
  generically (not socket-specific) to reassemble a byte stream into frames
  regardless of how it's chunked. A `Socket` is already a `Stream<Uint8List>`,
  so the adapter is a thin pass-through (`send` -> `_socket.add`, `onReceive`
  -> `_socket` directly). The correctness work for partial/coalesced reads
  lives in exactly one place, not duplicated per transport.
- **`FrameReader` stress-tested directly, not just incidentally** -- added
  `test/protocol/wire_test.dart` because localhost sockets are fast enough
  that the socket-transport tests might never actually trigger a split-
  across-many-reads or two-coalesced-frames scenario in practice (timing-
  dependent, not guaranteed). Tests force both directly: a frame fed to
  `FrameReader.addChunk()` one byte at a time, two frames coalesced into a
  single chunk, and three frames re-chunked at arbitrary non-frame-aligned
  boundaries (mid-header and mid-payload cuts). All four pass.

### Verification run

- `flutter test test/protocol/wire_test.dart test/protocol/match_session_test.dart test/protocol/match_session_socket_test.dart -d linux`:
  **16/16 pass** -- 4 `FrameReader` stress tests + 6 protocol tests over
  in-memory + the identical 6 over real localhost sockets, zero failures,
  zero `MatchSession` changes between the two transport variants.
- `flutter analyze`: clean.

### Not yet built (remaining in Task B)

- mDNS/NSD discovery (`advertise()`/`discover()`/`connect(peerId)` are still
  no-ops on `LanSocketTransport` -- connection setup currently requires
  already knowing host:port, fine for the localhost checkpoint, not for
  real field use).
- Android manifest permissions for NSD/multicast.
- The real LAN-between-two-devices run and the two-device validation gate.

---

## M4.2 — Identity backup (export/import) + third poseidon2_hash2 cross-check vector

### What was built

- **Identity backup** (`lib/identity/backup_format.dart`, `backup.dart`,
  `backup_io.dart`): manual, no-server export/import of the on-device Ed25519
  seed. Self-describing PEM-armored binary format (magic + version, fails
  loudly on unknown formats rather than corrupt-importing). Encryption
  on-by-default: Argon2id (OWASP-recommended interactive minimum: 19 MiB
  memory, 2 iterations, parallelism 1) -> XChaCha20-Poly1305 AEAD, both from
  `package:cryptography` (already a dependency, vetted, nothing hand-rolled).
  Plaintext export requires an explicit `acknowledgedPlaintextRisk: true`
  the UI must only set after showing the key-exposure warning. Import
  requires `confirmOverwrite: true` the same way -- destructive by design,
  never silently overwrites. File save/pick glue uses one plugin
  (`file_picker`, both `saveFile(bytes:)` and `pickFiles(withData: true)`
  work in bytes, not paths, so Android scoped storage is a non-issue).
- **Key rotation note, flagged not solved:** importing a different seed than
  the one currently on-device is, semantically, a key rotation event. This
  code does not re-sign or otherwise touch any in-flight delegation
  (master/apprentice loans, scrolls) bound to the old `owner_pubkey` -- the
  delegation system doesn't exist yet, so there's nothing to re-sign today,
  but **when it's built, key rotation must account for invalidating/
  re-issuing delegations tied to the old key.** Recorded here so it isn't
  rediscovered as a surprise later.
- **Third `poseidon2_hash2` cross-check vector** (`ffi/src/api/identity.rs`):
  a cryptographically random 32-byte key (not the second vector's sequential
  `0..31` pattern), split via the same first16/last16-LE convention
  (`key_hi = 0xc99502afe3f0288a3add28af7f7f1e1e`,
  `key_lo = 0xcb2712a65f5ad1234bf601a8d349c6ec`), run through
  `poseidon2_hash2` to get
  `owner_pubkey = 0x1c2b369adc1352bf11e6db4989574f413e7d8d43bd3edfc3b87c281f41129aa7`,
  then through `nargo execute` against `circuits/ca_v2_4_tier12` --
  **"Circuit witness successfully solved."** `Prover.toml` restored
  afterward. `poseidon2_hash2` now has three cross-oracle vectors (zero,
  sequential non-zero, random non-zero), all agreeing with the real circuit.

### Toolchain/test-environment notes

- **`flutter_secure_storage_linux` is a native-only plugin (no Dart code at
  all)**, registered at native engine startup -- only reachable from a real
  `flutter run -d linux` process, never from `flutter test` (which always
  runs on the headless Flutter Tester engine regardless of `-d`). Backup
  tests that exercise `Identity.loadOrCreate`/`overwriteWithSeed` install an
  in-memory mock for the `plugins.it_nomads.com/flutter_secure_storage`
  method channel (`test/identity/fake_secure_storage.dart`) rather than
  hitting real storage -- confirmed via a throwaway smoketest that the real
  channel is genuinely unreachable under `flutter test`, not a transient
  failure.
- **`flutter test <directory>` has a cosmetic output-interleaving quirk** in
  this environment -- test names from one file occasionally print duplicated
  against the wrong index when multiple files in a directory are discovered
  together (final pass/fail count is still correct). Running explicit file
  paths (`flutter test test/identity/foo_test.dart test/identity/bar_test.dart`)
  gives clean, correctly-attributed output; used throughout M4 for that
  reason.
- `file_picker`'s public API is `FilePicker.saveFile(...)` /
  `FilePicker.pickFiles(...)` (static methods directly on the `FilePicker`
  class), not `FilePicker.platform.saveFile(...)` -- the `.platform`
  indirection is internal, not part of the public surface in 11.0.2.

### Verification run

- `flutter test test/identity/key_packing_test.dart test/identity/backup_test.dart -d linux`:
  15/15 pass (5 key-packing including the new high-entropy vector + 10
  backup), zero failures.
- `cargo test --lib` (ffi/): 3/3 pass (all three `poseidon2_hash2`
  cross-checks).
- `flutter analyze`: clean.

---

## M4.1 — Identity module + transport-agnostic protocol layer, green over in-memory transport

### What was built

- **Identity** (`lib/identity/`): on-device Ed25519 keypair generation, secure
  storage (`flutter_secure_storage`, Android Keystore-backed), the
  `key_hi`/`key_lo` split (`key_packing.dart`), and the ownership-challenge
  signing primitives (`identity.dart`).
- **A new Rust FFI surface** (`ffi/src/api/identity.rs`): `poseidon2_hash2`,
  exposed to Dart for the first time. Not anticipated in the original plan
  ("no FFI changes needed" turned out to be wrong) -- see below.
- **Protocol layer** (`lib/protocol/`): the pluggable `Transport` interface,
  an in-memory loopback implementation for tests, the wire framing
  (`wire.dart`), the confirmed proof-wire-format reader (`proof_wire.dart`),
  and the match protocol state machine (`match_session.dart`).
- **Tests**: a Dart round-trip test for the key split, a Rust cross-oracle
  test for `poseidon2_hash2`, an FFI smoke test, and 6 protocol tests over
  the in-memory transport (happy path, tampered proof, owner_pubkey
  mismatch, wrong signer, replayed/stale signature, relay attack). All green
  on first run.

### Finding: "Gamemaster mode" is not a duel-networking concept

The M4 brief asked to confirm which of two networking modes was in scope:
"peer-to-peer with both parties signing" vs. "a Gamemaster mode with single
merge authority." Reading `runewright_design_v2_4.md` end to end: Gamemaster
Mode only exists as one of three *storytelling* modes under Talewright
(line 918) -- a GM narrates a TTRPG-by-text and "cannot override
battle-outcome signatures." It has no networking/merge-authority concept and
Talewright is explicitly post-ship/out of scope. There is exactly one duel
protocol in the design (Battle Integrity / Owner Binding sections): two
co-present peers, per-turn signing, commit-reveal randomness, a per-match
Ed25519 ownership challenge. No decision was needed; the brief's premise was
incorrect.

### Finding: a new FFI surface was required, not anticipated in the plan

`CIRCUIT_IO.md` §5 requires "the verifying client recomputes
`Poseidon2(split(presented_key))` and checks equality" -- but no Poseidon2
function was exposed to Dart, and `CLAUDE.md` invariant 1 forbids
reimplementing Poseidon2 in Dart. Closed by exposing
`bn254_blackbox_solver::poseidon2_permutation` (acvm-repo, part of the noir
monorepo, pinned via `rev = "v1.0.0-beta.20"` to the **exact commit**
(`b4236c19...`) noir_rs already resolves transitively) through a new thin
FFI function, `poseidon2_hash2`, mirroring
`circuits/ca_v2_4_tier12/src/main.nr`'s helper of the same name exactly
(state = `[a, b, 0, iv]`, `iv = 2 * 2^64`, permute, take `state[0]`). This is
the literal ACVM/Noir-stdlib implementation, not a second one.

**Cross-oracle confirmation (two separate checks):**
1. `poseidon2_hash2("0x0", "0x0")` reproduces the known-good
   `owner_pubkey` value already verified end-to-end against the real
   circuit in `tamper_test.rs`/`desktop_vk_test.rs`
   (`0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1`).
2. A **non-zero** key vector (bytes `0..31` split first-16/last-16-LE,
   `key_hi = 0xf0e0d0c0b0a09080706050403020100`,
   `key_lo = 0x1f1e1d1c1b1a19181716151413121110`) was run through
   `poseidon2_hash2` to get
   `owner_pubkey = 0x228e9a8a908419c3c66a519957e70f0b45d5d1375a4b3bbe4b4662cd03aa3d89`,
   then fed into `circuits/ca_v2_4_tier12`'s `Prover.toml` and run through
   `nargo execute` (`~/.nargo/bin/nargo`, beta.20, commit `b4236c19` --
   matches the pinned toolchain exactly). **Result: "Circuit witness
   successfully solved"** -- the circuit's
   `assert(owner_pubkey == poseidon2_hash2(key_hi, key_lo))` held for a real
   non-zero key, not just the zero stub. `Prover.toml` was restored
   afterward; this was a throwaway cross-check, not a permanent vector.

### Finding: the `key_hi`/`key_lo` split is confirmed pure client convention (plan amendment 2)

Read `circuits/ca_v2_4_tier12/src/main.nr` lines 84-96: the only constraint
touching `key_hi`/`key_lo` is `assert(owner_pubkey ==
poseidon2_hash2(key_hi, key_lo))` over whatever two field values they are.
Zero in-circuit byte-order or half-assignment logic. The first-16/last-16,
little-endian split (`lib/identity/key_packing.dart`) is therefore entirely
a Dart-side convention -- closing the `CIRCUIT_IO.md` §5
`[CONFIRM vs stepper/client]` flag. A future platform (iOS) needing a
different native byte order can revise this function alone; the VK is
unaffected.

**iOS interop note (logged, not built):** when an iOS port is attempted, its
Ed25519 implementation must produce keys that, once split via this same
convention, are byte-compatible with Android's -- both platforms must agree
on `key_hi`/`key_lo` for the same logical key, not merely be internally
consistent each on its own.

### The relay-attack defense (plan amendment 1), as implemented

`MatchSession` (`lib/protocol/match_session.dart`) binds the ownership
challenge to `SHA256(len-prefixed(nonce, proof_public_inputs, match_id))`,
not the bare nonce. `match_id` is established once per session at handshake
time (`MatchSession.initiate`/`.accept`) and is never re-read from any later
message -- this is what defeats relaying a challenge from one session into
another: the relayed signature is bound to the *relaying* session's
match_id, which necessarily differs from the victim session's. Tested
directly in `test/protocol/match_session_test.dart`'s relay-attack case by
constructing the cross-session digest explicitly and confirming
`Identity.verify` rejects it.

**Known limitation, not silently ignored:** this defeats relaying an
*established* challenge across sessions. It does not by itself authenticate
the very first handshake against an active on-path adversary who controls
the transport during initial connection setup -- a deeper channel-binding
question, out of scope for M4's protocol layer.

### Toolchain note: `flutter pub add` / `dart pub add` / `flutter pub get` report exit 255 in this snap environment

All three report exit code 255 with **zero stdout/stderr**, even though the
underlying operation (resolving and writing `pubspec.lock`, modifying
`pubspec.yaml` for `add`) **succeeds** -- confirmed by inspecting the
resulting files after each "failed" call. `dart pub get` (not `add`) reports
exit 0 normally. Root cause not pinned down (snap-confine intercepts ptrace
and refuses under `strace`, which masks rather than explains the silent
255). Workaround used throughout M4.1: edit `pubspec.yaml` by hand, then run
plain `dart pub get` and verify via `pubspec.lock`/file diffs rather than
trusting the exit code.

### Toolchain note: `flutter_rust_bridge_codegen generate` needs explicit flags here

No `flutter_rust_bridge.yaml` config file exists in this repo, so the bare
`flutter_rust_bridge_codegen generate` (as documented in `M2_ffi_spike.md`)
now fails with "Please provide `rust_input`". Working invocation from repo
root:
```
~/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root ffi --dart-output lib/src/rust
```
(`~/.cargo/bin` is not on `$PATH` in this shell either.)

### Verification run, end to end

- `cargo test --lib` (ffi/): 2/2 pass (the two `poseidon2_hash2` cross-checks).
- `flutter test test/ffi/identity_ffi_smoketest.dart -d linux`: real FFI
  round-trip confirmed (not faked).
- `flutter test test/protocol/match_session_test.dart -d linux`: 6/6 pass,
  first run, including the relay-attack and replay cases.
- `flutter test test/identity/key_packing_test.dart`: 4/4 pass.
- `NARGO_BIN=~/.nargo/bin/nargo bash scripts/run_vectors.sh`: full
  stepper-regression + golden/negative corpus, **zero regression** -- same
  OK/SKIP pattern as the established M3 baseline (13 vectors, 0 failures).
- `flutter analyze`: clean (pre-existing unrelated `avoid_print` infos in
  `scripts/find_mask_vector.dart` only).

### Not yet built (next in the M4 plan)

- The real LAN-socket + mDNS transport adapter (plan step 3).
- Two-device validation (plan step 4).
- Wiring real (non-ephemeral) `Identity.loadOrCreate()` + real proofs into a
  minimal harness screen.
