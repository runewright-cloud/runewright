# M4 — Findings Log (live, updated per milestone)

## Avatar Picker Plan built end-to-end; two widget-test traps worth knowing (2026-08-03)

**Context:** docs/AVATAR_PICKER_PLAN.md implemented in full — Monsters + a
96x96 portrait atlas in `build_avatar_pack.py`, `AvatarPortraitAtlas`, avatar
id persistence, `AvatarPickerScreen`, the Settings Avatar card, and the
`avatarId` (0x1E) handshake exchange (`kBattleProtocolVersion` 2 → 3). All 53
portraits auto-detected cleanly via the bounding-box rule; only the two
overrides the plan already named (`Flower-01.png`, `Mermaid_01.bmp`) were
needed — no new overrides, no plan corrections. All 46 pre-existing avatar
ids kept their exact atlas cell (diff-verified).

**Two widget-test traps hit while writing §6's tests, neither previously
documented here:**

1. **`ui.decodeImageFromPixels` (and any real image codec decode —
   `rootBundle.load` + `instantiateImageCodec`) hangs forever inside a bare
   `testWidgets` `await`, up to the 10-minute timeout.** The completion
   callback arrives from a real engine thread, which never reaches an awaited
   Future inside `testWidgets`' FakeAsync zone unless bridged through
   `tester.runAsync(() => ...)`. First surfaced as a 10-minute-timeout test
   failure with no other symptom. Fix: wrap the decode call itself in
   `tester.runAsync`. This is presumably why
   `wizard_movement_preview_test.dart`'s equivalent real-file decode is gated
   behind an opt-in env var (`WIZARD_PREVIEW_DIR`) and a no-op by default —
   it was never meant to run unattended, which had the side effect of hiding
   this trap. A widget test needing a decoded image should build a synthetic
   one with `decodeImageFromPixels` wrapped in `runAsync`, not read a real
   asset file.
2. **`SettingsScreen` needs `installFakePathProvider()`, not just
   `installFakeSecureStorage()`, or `pumpAndSettle` hangs.** `_load()` awaits
   `VocalTuning.load()` first, which resolves a file path via
   `path_provider` — with no mock, the plugin channel call never completes
   under the headless test engine, and the screen never gets past its
   spinner. `credits_screen_test.dart` already carried this requirement
   (it calls `installFakePathProvider()` for exactly this reason); a new test
   pumping `SettingsScreen` needs to copy that, not just the secure-storage
   mock.

**Verification gate note:** the contact sheet (§3.4) and the full positive
test suite (1115 tests, one pre-existing test's tile-position assumption
fixed for the new Avatar card pushing content down — no other regressions)
are done. The interactive `flutter run -d linux` click-through and the
two-device LAN pass from §7.2/§7.3 were **not** completed this session — no
GUI input-automation tool (`xdotool` or equivalent) is available in this
environment and no root to install one, so the picker/settings/battlefield
visual flow has not been driven by hand. Leave both on the outstanding list
per the plan's own instruction not to report the feature complete without
them.

## Trade manual-IP fallback + real bug report: hung on "Waiting for their offer" (2026-07-28)

**Context:** Commune/Trade never had a manual-IP fallback the way
`battle_lobby_screen.dart` does (see the 2026-07-20 entry below) — it only
ever had `nsd` auto-discovery. Since `nsd` has no Linux desktop backend at
all, trade was completely untestable on the Soren's Linux-laptop + Pixel 6
pair until this landed: `TradeDiscovery.startAdvertising` now soft-fails its
`nsd` registration (mirrors `LanMatchDiscovery`, listening socket binds
regardless) and gained `listeningPort`/`localAddressHint()`;
`trade_screen.dart` gained the same address-hint display + `host:port`
manual-connect field as the battle lobby. New resilience test:
`test/trade/trade_discovery_resilience_test.dart` (same shape as
`match_discovery_resilience_test.dart`).

**Real bug report, first real two-device trade attempt:** pixel hosted and
offered a real spell; laptop joined via the new manual-IP field and offered
nothing. Both sides submitted their offer; both hung forever on "Waiting for
their offer" (`_Stage.submittingOffer`).

**Investigation — could not reproduce locally despite several realistic
attempts, all over real loopback TCP sockets (`LanSocketTransport`, not
`InMemoryTransport`):** trivial empty/empty offer exchange; the exact
asymmetric shape reported (one real spell item vs. an empty offer). Both
completed instantly. `exchangeOffer`'s subscribe-before-send ordering is
correct and symmetric on both sides; `TradeItem`/`TradeOffer` payloads are
small metadata only (no proof bytes or grid), ruling out a payload-size
theory. `trade_wire.dart`'s `TradeFrameReader._drain()` is byte-identical to
the canonical, hardware-validated `wire.dart` `FrameReader`, so it isn't a
regression specific to trade's copy.

**A first theory — that the listens omit `onDone`/`onError`, so a silently
dropped TCP connection never closes the reader — was WRONG as the cause
here.** Recorded because it cost a round trip: it was inferred from code
reading rather than reproduction, and Soren correctly rejected it on
evidence (devices a foot apart on a private phone hotspot; and the hang
*moved between devices* between runs, which a flaky link doesn't explain).
The gap is real and worth closing (it is, below), but it was not this bug.
**Reproduce before theorising** — the reproduction took one test.

**CONFIRMED root cause: `TradeFrameReader`'s `StreamController` is a
*broadcast* controller, and a broadcast stream silently discards any event
added while it has no subscriber.** `TradeSession` only subscribed *inside*
`exchangeOffer`/`exchangeConfirm` (via `framesOfType(...).first`). Every step
of this protocol is gated on a human pressing a button, so the two peers are
never subscribed at the same moment: whoever pressed Submit **first** sent
their offer while the other device was still sitting in its offer-builder UI
with nothing listening — that frame was dropped on the floor, permanently.
The second player's `await` could then never be satisfied. **The second
submitter always hangs.** That is exactly the reported evidence: Linux hung
when the Pixel submitted first; the Pixel hung when Linux submitted first;
host/guest role was irrelevant. `exchangeConfirm` had the identical defect
(two humans decide independently, seconds apart).

**Why every existing test missed it, and why the first repro attempts did
too:** `trade_session_test.dart` calls both sides' `exchangeOffer` in the
same event-loop turn, so both are subscribed before either frame is
delivered. Reproducing over real loopback TCP with a payload matching the
report *also* passed, for the same reason. The bug only appears once the two
calls are **staggered in time** — a 300 ms delay is enough. Note that
subscribe-before-send (the discipline the 2026-07-18 `exchangeGrantsAndSave`
race fix introduced) does **not** help: the gap that matters is between the
two peers *calling the method at all*, not between subscribe and send inside
one method. That earlier fix closed a real but much smaller window and was
mistaken for a general defence.

**The codebase already had the correct pattern — trade just never got it.**
`BattleFrameReader` (`battle_wire.dart`) is queue-backed
(`_pendingByType`/`_waitersByType`) precisely because this same failure was
hit during LAN duel setup (its doc comment describes it, differing FFI
latency during `exchangeIdentityAuth` being enough to trigger it). Trade
copied battle's *shape* (broadcast stream + `framesOfType`) without the
buffering that makes it safe.

**Fix:** `TradeSession` now keeps ONE permanent subscription for the
session's life and routes every protocol await through a new `_nextFrame(
Set<TradeMsgType>)`, which returns a matching frame that **already arrived**
from an in-order buffer, or registers a waiter. `close()` and stream
done/error fail all pending waiters instead of leaving them hung.
`framesOfType` is kept but documented as a footgun — anything the protocol
awaits must use `_nextFrame`.

**Regression test:** `test/trade/trade_session_staggered_test.dart` — real
loopback TCP, with a deliberate delay between the two peers' calls, covering
offer, confirm, a cancel from the *first* decider, and close-releases-an-
in-flight-await. **Verified all four fail (5 s timeouts) with the fix
stashed and pass with it applied.** The delay is load-bearing; removing it
makes the file test nothing.

**Fixes applied alongside:**
- `LanListener.acceptOnce()` (`lan_socket_transport.dart`) now sets
  `SocketOption.tcpNoDelay` on the accepted socket too — previously only
  `LanSocketTransport.connectTo` (the dialing side) set it, a latent
  Nagle/delayed-ACK asymmetry for this kind of small-message,
  one-round-trip-per-step protocol.
- **`trade_screen.dart` gained a Cancel escape hatch** (`_abortExchange`) on
  the three post-pairing exchange spinners (`submittingOffer`,
  `awaitingConfirm`, `exchanging`) — previously `_SpinnerSection` had no way
  out at all once past pairing, so *any* stall (this bug, a genuine network
  drop, anything) left force-quitting the app as the only recourse.
  `_abortExchange` calls `TradeSession.close()` first — which now explicitly
  fails pending `_nextFrame` waiters, the thing that actually unblocks an
  in-flight exchange; merely disconnecting the transport does not — before
  resetting to idle. The `_submitOffer`/`_decide` catch blocks guard
  `_stage == _Stage.idle` first, so an old now-erroring future doesn't
  clobber the user's own cancel-triggered reset back into an error screen.
- Not added to the `pairing` stage's spinner: at that point `_session` isn't
  set yet, so `_abortExchange`'s unblock mechanism wouldn't reach the
  in-flight `TradeSession.initiate`/`.accept()` call — a real gap, but
  scoped out rather than shipping a half-working escape hatch.
- The socket listens in `initiate`/`accept` now pass `onDone`/`onError` that
  close the reader, so a genuinely dropped connection fails the pending
  awaits instead of stalling. (This is the first theory's fix. It was not
  this bug, but it is a real hole and cost one line each.)
  `TradeFrameReader.addChunk` ignores post-close chunks so that can't throw.

**Still open — `sync_art_session.dart` has the same defect, unfixed.** It
still does `framesOfType(...).first` over the same broadcast stream for its
want-list and art-bundle rounds. Its exposure is much smaller than trade's
(both sides call `sync()` automatically right after pairing, so the window
is FFI/handshake timing — milliseconds — not a human button press), but it
is the same bug and the battle precedent shows milliseconds is enough to
trigger it. **Not fixed here: out of scope for a trade bug, and Sync Art
deserves its own reproduction + regression test rather than a copy-paste
fix.** Recommended fix is identical: give `SyncArtSession` the same
`_nextFrame` buffer. `match_session.dart` is a strict, tightly-sequenced
request/response handshake and is *not* obviously exposed; `battle_session`
is already queue-backed and safe.

**Next:** retry the two-device trade. The staggered regression test now
covers the exact failure, but this needs the real hardware pass to close.

---

## Basic Spells (shipped starter spells + unlimited chapter copies) (2026-07-27)

Built per `docs/BASIC_SPELLS_PLAN.md`. Two real bugs found while implementing
"a chapter may hold unlimited copies of a Basic spell," neither anticipated
by the plan — both were boundary bugs (the plan's own guiding principle:
"when behavior surprises you, suspect the boundary, not the math").

### Trap: a second guard forbids re-casting the same grid, unrelated to chapter dedup

`TurnLoop._verifyPeerSpellCast` has a "Kin-stacking" check
(`_seenPeerCommitments`) that forfeits the match if a peer casts the same
`commitmentHex` twice in one match. It predates this feature and quietly
assumed a chapter could hold at most one copy of any grid (the ONLY thing
enforcing that was a UI guard in `library_screen.dart`). Removing the UI
guard for Basic spells without touching this check means casting a SECOND
copy of any Basic spell forfeits the match — found via a widget test that
hung for exactly 30s (`Future.wait` doesn't fail fast when one side of a
paired exchange throws and the other is left awaiting a reply that never
comes; see "Trap" below). Fixed by exempting `isBasicGridAndT` matches, and
by moving the check to run AFTER proof verification so it keys off VERIFIED
`outputs.commitmentHex`/`.t` rather than the untrusted wire value — same
trust-boundary discipline as the ownership exemption. See
`docs/BATTLE_AUTH_PLAN.md` §4a. Confirmed scoped correctly: a non-Basic
duplicate-commitment cast still forfeits
(`test/battle/engine/basic_spell_duplicate_chapter_test.dart`).

### Trap: `Future.wait` on a paired caster/verifier exchange hangs, not throws, when only one side errors

`TurnLoop.runTurn` pairs are driven with
`Future.wait([caster.runTurn(...), verifier.runTurn(...)])` throughout the
test suite. When the verifier's side legitimately throws (a forfeit), the
caster's side is left awaiting a protocol reply the verifier never sends —
and `Future.wait`'s default (`eagerError: false`) waits for BOTH futures to
complete before surfacing anything, so the whole test hangs at the 30s
default timeout instead of failing fast with the real error. Diagnosed by
attaching `.then/.catchError` with `print` to each side individually rather
than trusting `Future.wait`. Any NEW test that expects one side of a paired
exchange to reject must either use `eagerError: true`, or (cleaner) leave
the side that's expected to hang un-awaited via `unawaited(future.catchError(...))`
and assert only on the side that's supposed to throw — see the second test
in `basic_spell_duplicate_chapter_test.dart` for the pattern.

### Trap: a seeding side-effect in `AppRoot` can strand the router on its spinner

`AppRoot` now runs `seedBasicSpells()` (calls `path_provider` +
`rootBundle`) alongside `Identity.exists()` (secure storage only) on every
launch. Widget tests that exercise `AppRoot`/onboarding
(`test/ui/onboarding_flow_drive_test.dart`) never needed a `path_provider`
mock before and don't have one — `getApplicationDocumentsDirectory()` inside
an unguarded `Future.wait` turned into an unhandled Future error, which left
the `FutureBuilder` at `!snapshot.hasData` forever (never `hasError`
specifically — just never resolves), and `pumpAndSettle` timed out. Fixed by
making the seed call fire-and-forget with its own `.catchError` swallowing
any failure (`unawaited(seedBasicSpells().catchError((_) => 0))`) — seeding
is a nice-to-have that must never gate routing to the menu or onboarding.
General lesson: any side effect added to a router/gate widget's startup
Future needs its own error boundary, independent of whatever the router
actually depends on — don't let `Future.wait` silently couple an optional
side effect's failure mode to a load-bearing check.

---

## Practice Mode — multi-exemplar scoring, playtest strictness dial, English trainer voice (2026-07-22)

Follow-up to 2026-07-21's `ventus` swap. On-device testing surfaced a new
symptom: heavy stalling with the stall-hint pointing at `ventus` even with
all five words freshly enrolled — ruling out both the cross-voice and
short-template explanations already investigated. Root-caused and fixed
across several linked changes; recorded together since each shaped the next.

### Root cause #1: enrollment and casting were captured at wildly different paces

Pulled the real enrollment off-device (`adb shell run-as` into
`app_flutter/practice_enrollment/`) and compared frame counts against
Soren's own hold-to-record attempt clips: `ventus` enrolled at 189 frames
(1.9s) but cast in ~0.7s; `aqua` enrolled at 35 frames but cast in ~0.4s — up
to a 5x spread. The min-audio guard
(`kMinSegmentAudioFraction` x the *enrolled template's* length) makes a
brisk cast of a slowly-enrolled word structurally unable to cross,
regardless of threshold — the enrollment capture UI (tap → play sample →
fixed 2.5s window) doesn't teach or enforce a consistent pace.

A leave-one-out offline test (new `test/practice/vocal_calibration.dart`
harness, run against Soren's own hold-to-record clips) confirmed the fix
once pace was controlled: templates built from one brisk clip, scored
against the other same-pace clips, hit 3/5 words at 4/4 with margins
+1.7-+3.8 (`terra`/`finitus`/`ventus`) — but `aqua` and `ignis` stayed at
0-1/4 correct with near-zero or negative margins. Confirmed a SEPARATE,
genuine acoustic confusion (`aqua`/`terra`, the same pairing flagged back in
2026-07-16's Piper-voice measurement), not a pace artifact.

### Root cause #2 explored and ruled out: delta (Δ) MFCC features

Added `MfccExtractor.deltas()` (standard N=2 regression-window delta
coefficients) and A/B'd static-only vs static+delta at weights 1x-8x against
the same real clips (offline, via the calibration harness's `USE_DELTAS`/
`DELTA_WEIGHT` flags — never wired into the shipped scorer). Result: a wash
at every weight tested. `aqua` stayed stuck at 0-1/4 correct with negative
margins across the ENTIRE weight range; margins scaled linearly with weight
but never flipped sign. Conclusion: `aqua`/`terra` are closer in this
speaker's voice than static-or-delta MFCC can separate — not a feature-
engineering problem. Deltas are implemented and available but NOT wired into
`StreamingPhonemeScorer`; keep in reserve, don't retry without new evidence.

### Fix: multi-exemplar scoring (recommendation #1, tried before deltas and it won)

Same leave-one-out data, scored against a SET of the OTHER clips (min
distance over the set) instead of one held-out template: **25/25 correct,
every margin positive** (`aqua` +0.47 to +2.81, `ignis` +0.05 to +1.80 — one
`ignis` fold's margin is thin, worth firming up with more real reps before
fully trusting it). Beat delta features outright with zero new signal —
just don't collapse a word down to one brittle exemplar.

Shipped end to end:
- `VocalEnrollment` (lib/practice/vocal_enrollment.dart): storage moved from
  one `{"frames": [...]}` file per word to `{"takes": [[...], ...]}`, up to
  `maxTakes` (5, FIFO past the cap). Legacy single-take files still load
  (migrated as a one-element set). Added `maxVoicedFrames` (200 frames,
  ~2s) — a hard ceiling on one take, so a held-too-long button press (the
  230-frame `finitus` that started this investigation) is rejected with an
  actionable message instead of silently poisoning the template.
- `VocalTemplateSource.templatesFor(word)` — new method returning the full
  exemplar set; defaults to wrapping `templateFor` as a one-element list, so
  `SingleVoiceTemplateSource` needed no change. `PerUserEnrolledTemplateSource`
  returns the real set (or the Piper fallback's one-element set per-word).
- `StreamingPhonemeScorer`: `_Segment.referenceSets` +
  `_minQualityOverSet()` replace the old single-reference `_windowQuality`.
  Both the target-quality check (condition 3) and every competitor's
  contrastive quality (condition 4) are now min-over-set. Written as a
  standalone helper depending only on the query buffer (no streaming
  state), specifically so it's **lift-and-reuse for the battle-mode port**
  per Soren's "only pursue battle-portable solutions" direction — battle's
  whole-utterance `endCapture()` can call the same method.
- `test/practice/multi_exemplar_e2e_test.dart` (new): the golden corpus only
  ever exercised 1-element sets. Added a 2-element-set variant (bundled
  template + `lessac2`, both already-committed fixtures, no new assets)
  proving the SAFETY-relevant direction — a larger set introduces zero new
  false advances. (The completion-improves direction is what the real-voice
  leave-one-out already proved; a synthetic-voice-only corpus can't
  reproduce genuine cross-take speaker variation, so it isn't asserted here.)

### Playtest tool: strictness dial (Settings + Practice tab)

Soren's explicit design constraint: careful enunciation must stay part of
the challenge, and the right bar depends on the play environment (quiet
solo practice vs a noisy multi-caster battle) — so rather than hand-pick one
"medium" operating point, built a single 0.0 (easy) - 1.0 (strict) dial
(`lib/practice/vocal_tuning.dart`) mapping to the three raw constants:

- 1.0 reproduces the shipped constants EXACTLY (floor 6.25 / margin 0.9 /
  debounce 8) — an untouched dial changes nothing.
- 0.0 is deliberately forgiving (floor 9.5 / margin 0.3 / debounce 4) per
  Soren's "err on the too easy side, battles may be noisy" direction —
  margin 0.3 rather than lower because measured correct multi-exemplar
  attempts still need real separation, just less of it than 0.9.
- Default 0.45 (floor 8.04 / margin 0.57 / debounce 6) — a starting point
  for playtesting, not a conclusion.

Persisted to `vocal_tuning.json`; the identical slider widget
(`VocalStrictnessSlider`) appears in both the new `SettingsScreen` (menu's
"Settings" button was a dead `onTap: null` stub before this) and Practice's
Vocal tab, reading/writing the same file so either surface reflects the
other. Verified on-device via adb screenshots: math matches the formula
exactly at three tested points, and both directions of cross-screen sync
confirmed.

### Enrollment UI rebuilt: hold-to-record, multi-take, per-word clear

The old enrollment flow (tap → play sample → fixed 2.5s window) is exactly
what caused root cause #1's pace mismatch, and only ever stored one take.
Replaced with the same hold-to-record mechanism already built for
calibration-capture attempts (unified into one shared `_onHoldStart`/
`_finishHold` pair, parameterized by `_HoldTarget.{enrollment,calibration}`,
rather than duplicating the mic-handling code a third time). Each word row:
play-model icon, hold-to-record button, live `n/5` take count, per-word
clear. Verified on-device: mic engagement, the `EnrollmentException`
too-quiet/short error path, take counting, and per-word clearing all
confirmed against the real running app (see the on-device screenshot pass —
also cleared Soren's real `ignis` enrollment as a side effect of testing the
clear button; flagged for re-recording).

### English trainer voice (Soren's direction, separate from the bug hunt)

Most players will map Latin spelling onto English pronunciation habits
regardless of what the trainer teaches — switched the trainer/bundled-
template voice from Italian (`it_IT-paola-medium`/`it_IT-riccardo-x_low`) to
English (`en_US-lessac-medium`/`en_US-amy-medium`, fetched from
`rhasspy/piper-voices`). IPA re-derived from the actual bundled espeak-ng
(not guessed) — notable non-classical outcomes accepted the same way the
Italian entry's were: `ignis` word-final "s" voices to /z/ ("IG-neez"),
unstressed "-us"/"-a" endings reduce to schwa across four of the five
words, and `finitus`'s medial "t" flaps to /ɾ/ (American "water"-style) —
all genuine `espeak-ng -v en-us` output, all documented in
`latin_phonemes.dart`'s header. `test/practice/latin_phonemes_test.dart`'s
Italian-specific palatalized-geminate assertion replaced with checks for
the s-voicing and t-flap instead.

### A second, unrelated bug found while regenerating fixtures: Piper's default trailing silence

Regenerating the English e2e fixtures, `same voice: correct word completes`
failed for `finitus` — full-utterance DTW quality was excellent (2.71,
nowhere near the 6.25 floor) but the live per-frame trace showed the
attempt-gap reset (`kAttemptGapFrames`, 30 consecutive unvoiced frames)
firing before 8 consecutive passing frames could accumulate. Measured: the
fixture carried ~380-430ms of trailing silence, comfortably past the 300ms
reset threshold. Re-rendering (to exploit Piper's known synthesis
nondeterminism, per 2026-07-21's finding) did NOT fix it — the padding
turned out to be **deterministic**, not stochastic: `piper --help` shows
`--sentence_silence` defaults to a fixed 0.2s post-utterance pad. This is
almost certainly the same mechanism behind 2026-07-21's "`aer` is half
silence" finding — a FIXED pad biases short words proportionally more than
long ones, which is exactly the shape of that bug.

**Fix: `--sentence_silence 0`** added to `generate_practice_assets.dart`'s
Piper invocation and to every fixture-rendering command. This is a cleaner
fix than the trim-after-the-fact approach prototyped and reverted
2026-07-21 (that trim reshuffled every word's relative length and moved the
"shortest template" bias onto `terra`) — suppressing the pad at the source
removes only the artificial addition, leaving real per-word trailing-decay
differences alone, so it can't reshuffle relative lengths the same way.
Regenerated all bundled templates + trainer clips + e2e fixtures with the
flag; full corpus (44 tests across `real_template_e2e_test.dart`,
`multi_exemplar_e2e_test.dart`, and the rest of `test/practice/`) passes
clean. Worth remembering for any future Piper-based asset work in this repo.

### ignis pronunciation override: "ignisse" TTS input, not plain "ignis" (iterated twice)

Soren's ear on hearing the English trainer clip: plain "ignis" (espeak's
natural /ɪɡnˈiz/, "IG-neez") read as "digging knees." Two rounds of target,
swept via `espeak-ng --ipa -v en-us` against candidate respellings:

1. **"Sound like ignite, ending in /s/ not /t/"** — `ignyce` -> `/ˈɪɡnaɪs/`
   hit the vowel+consonant, but no respelling tried (ignyce, ignisse,
   ignyse, ig'nyce, igNYCE, ...) shifted espeak's stress rule onto the
   second syllable the way "ignite" itself stresses it — rule-based stress
   assignment isn't controllable through spelling alone here.
2. **Revised: "last syllable rhymes with kiss"** (`/kˈɪs/`) — `ignisse` ->
   `/ɪɡnˈɪs/` ("ig-NISS") hits that exactly, and as a bonus lands stress on
   the second syllable that round 1 couldn't get — supersedes `ignyce`
   entirely, both the sound and (incidentally) the stress goal.

Added `kTtsTextOverride` (scripts/generate_practice_assets.dart) — a
per-word map from `VocalWord` to the string actually fed to Piper/espeak,
separate from `VocalWord.name` (what players see, say, and cast). Only
`ignis` uses it so far. `latin_phonemes.dart`'s ignis entry: `ɪ-ɡ-n-ɪ-s`;
the espeak-derivation comment shows the override input, not the literal
word, so a future reader isn't confused about why "ignis" phonemizes
differently than a direct `espeak-ng ... ignis` run would show.

Regenerated ignis's bundled template, trainer clip, and both e2e fixture
voices (twice, once per iteration); backed up and restored the other four
words' assets around each regen since the generator has no per-word
selection flag and Piper's synthesis is non-deterministic (2026-07-21
finding) — don't let one word's change perturb four that don't need it.
Full corpus (44 tests) green after both iterations.

### Deferred / open

- The thin `ignis` margin (+0.05 in one leave-one-out fold) — trust it for
  now per Soren's call (mid-playtest-session, couldn't re-record), but
  firm it up with more real reps before treating multi-exemplar as fully
  proven on `ignis` specifically.
- Delta features (built, validated as NOT helpful, not wired in) and
  length-normalized contrastive comparison (never built) both remain
  in reserve if multi-exemplar alone proves insufficient during playtesting.
- Battle-mode port: `_minQualityOverSet` is deliberately written to be
  reusable from `ReferenceMatchVocalScorer.endCapture()`. Not done this
  session (explicitly deferred) — wire enrolled multi-take templates in
  there once Practice Mode's discrimination is trusted through playtesting.
- The strictness dial's medium/default numbers are a starting point, not a
  conclusion — the whole point of building it was to let Soren find the
  real number empirically rather than have it re-guessed offline again.

## Practice Mode — aer replaced with ventus; silence-trim prototyped and reverted (2026-07-21)

Soren's on-device report: heavy stalling, and when it wasn't stalling the
stall-hint disproportionately named `aer` as "what it sounds like you
said" — even with all five words enrolled (ruling out the mixed-voice
cross-template ranking failure mode from the 2026-07-16 entry). Matches
that entry's own prediction: `aer` is the shortest bundled template (34
frames) and has the vocabulary's lowest spectral norm (3.43), so it
structurally steals argmin rows in the contrastive comparison (condition 4
in streaming_phoneme_scorer.dart) regardless of who's speaking.

**Fix: retired `aer` (air) in favor of `ventus` (wind), everywhere** —
`VocalWord` enum, `fromAffinityZone`'s `'air'` mapping, `latin_phonemes.dart`,
`formula_generator.dart`, bundled asset + trainer clip, both e2e voice
fixtures. This is a real casting-word change, not practice-only (Soren
confirmed): Air spells are now cast by speaking "ventus." IPA verified via
the same bundled espeak-ng Piper uses (not guessed): `ventus -> vˈɛntʊs`
(the "-us" ending gets Italian /ʊ/, same pattern as `finitus`). Re-ran
`real_template_e2e_test.dart` after the swap alone: **passed clean**,
`ventus` never appears in any false-advance pair.

### Side-quest: bundled templates are silence-padded, not just `aer`'s

While investigating, found the shipped `aer.json`'s tail was ~16 of 34
frames at the log-energy floor (`c0 ≈ -93.9`, every other coefficient
`~1e-15`) — pure digital silence appended by Piper's render, not word
content. Since silence is the scorer's documented best imposter (2026-07-16
entry), a half-silence reference is pure downside. Prototyped a trim in
`generate_practice_assets.dart` (same voiced-span algorithm as
`VocalEnrollment.trimSilence`) and regenerated all five templates: **every
one of them shrank substantially** (`aqua.json` 18KB -> 7.6KB), confirming
the padding was universal, not an `aer`-specific defect.

**Reverted anyway.** Trimming shortens each template by a different
amount, which reshuffles the vocabulary's relative lengths — after
trimming, `terra` became the new shortest template (24 frames) and
**inherited `aer`'s exact failure mode**: re-running the e2e harness
produced 4 new false advances, all `X accepted as terra` or `aqua`/`terra`
cross-contamination (the two post-trim shortest words), zero involving
`ventus`. Removing the weakest word didn't remove the bias, it relocated
it — confirming (via Soren's question about whether this trades off
against fast-but-clear casting) that the real fix has to be a
length-normalized contrastive comparison, not vocabulary curation or a
floor/margin/debounce re-tune (re-tuning was considered and rejected too:
tightening margin/debounce to compensate would add latency and stalls,
directly opposed to Soren's fast-casting goal — see below).

**Piper's synthesis is NOT deterministic run-to-run** — a real trap for
whoever touches this generator next. Re-rendering `ignis` alone produced
33, then 57, then 62 MFCC frames across three separate runs with identical
input/model/args (the VITS stochastic duration predictor isn't seeded
deterministically in this Piper build). Practical consequence: **never
"regenerate to be safe" on words you didn't mean to change** —
`git checkout` the untouched assets back to their committed bytes instead
of re-running the generator, or you'll silently perturb every template's
length and invalidate the whole calibration. This cost real time in this
session (the trim revert required two rounds of `git checkout` because the
first regen pass touched all five words, not just the new one).

### Confirmed while here: real-time casting doesn't use any of this yet

`BattleScreen._initSorcererMode()` calls `VocalScorerFactory.create()` with
**no templates**, so live casting runs `ReferenceMatchVocalScorer`'s energy
fallback (`pronunciation = volume`) — word identity is not checked in
battle today, only loudness, inside a fixed capture window
(`_voiceCaptureWindow`, no endpointing). Two separate future items, per
discussion with Soren:
1. Once Practice Mode's contrastive discrimination is trustworthy (the
   length-normalization fix above), port it into
   `ReferenceMatchVocalScorer.endCapture()` reading the same
   `PerUserEnrolledTemplateSource` templates — battle's version is actually
   *simpler* (known target, bracketed window, no streaming/debounce
   machinery needed). This makes real pronunciation scoring self-reported
   by the caster's device (same trust model as today's volume score — the
   peer can't recompute it from audio it never received).
2. Soren's "enunciate clearly but cast fast" goal is a separate lever:
   endpointing/VAD on `_voiceCaptureWindow` so the window closes when
   speech stops, instead of always waiting out the fixed delay. Independent
   of pronunciation scoring; don't conflate the two when picking this back
   up.

## LAN duel setup Stage 2 implemented (docs/LAN_BATTLE_WIREUP_PLAN.md §4) (2026-07-20)

Turns on the full "sound duel" trust chain on top of Stage 1's playable-but-
trust-incomplete duel: proof verification, cast authorization (both
directions — outgoing grants were a TODO left in Stage 1, now wired), and
Phase D's signed per-turn state hash (built, not left optional).

**`BattleScreen`'s `TurnLoop` construction is now asynchronous** for a real
duel — loading the tier's bundled VK asset + circuit bytecode and calling
`initSrsCached` (CLAUDE.md Bug-Avoidance #4: a pure verifier that never
proves in a session still needs the CRS initialized) all happen before
`_loop` exists. New `_loopReady` gate in `build()`: a loading spinner until
ready, and a **blocking, fail-closed error screen** if any of that setup
throws — deliberately does NOT fall back to trusting peer casts unverified.
Solo/test play is unaffected (same synchronous-feeling path, `verifyProof`/
`vkBytes`/`signMessage` all stay null).

**Phase D closes a doc-comment-only gap**: `battle_session.dart` referenced
a `kStateHashSignatureTag` in a comment, but it was never actually defined
anywhere in the codebase. Now defined in `turn_loop.dart`, used to sign/
verify `TAG ‖ matchId ‖ turnNumber ‖ hash` — distinct from the auth-handshake
tag so a signature can't be replayed across the two purposes.

**Real bug found while writing tests, not scoped to product code:** two of
three new cast-authorization tests initially passed for the wrong reason.
`throwsA(isA<StateError>())` is satisfied by any `StateError`, and the test
fixture never set `localChapterCommitments` on the caster's `TurnLoop`, so
no proof bytes were attached to the wire — the verifier was forfeiting on
`missing_spell_proof`, not the authorization check the test claimed to
cover. Caught because the *third* (success-path) test hung: when one side's
`runTurn()` forfeits and throws mid-turn, the other side hangs forever
waiting for exchanges (melee/free-move/state-hash) that will never come —
`Future.wait([both sides])` is only safe when neither side is expected to
throw. Fixed the fixture and tightened every rejection assertion to check
the actual forfeit-reason substring. Worth remembering for any future test
in this area.

**Verification:** four new test files, all exercising real mechanisms (no
mocked crypto) — `turn_loop_proof_verification_test.dart` (a genuine
FFI-proven spell, via `inscribeSpell`, verified end-to-end through two real
`TurnLoop`s over paired `BattleSession`s — the actual "real-device proof
round trip" the plan asked for), `turn_loop_cast_authorization_test.dart`
(forged-owner rejected / valid-loan authorized / expired-loan rejected),
`turn_loop_phase_d_test.dart` (valid signature round-trips / tampered
signature forfeits), and the manual-IP-fallback test from the entry below.
Full suite green except the same two pre-existing, unrelated issues already
on record (SRS-download network flakiness under heavy concurrent load;
the `spell_authorization_test.dart` date-rollover fixture) — neither is
new, neither is this work's doing.

**Not yet done:** a real two-device LAN run that reaches proof verification
(the Stage 1 two-device pass only exercised the trust-incomplete path). No
second physical device in this environment — same gate as Stage 1.

---

## Real bug report: hosting from Pixel 6 worked, joining from Linux desktop crashed back to the lobby (2026-07-20)

**Root cause confirmed live, not guessed:** `nsd` (the mDNS package
`match_discovery.dart`/`lan_discovery.dart` use) has **no Linux desktop
backend at all** — `lan_discovery.dart`'s own header comment already said
this, but nothing had exercised the path end-to-end until Stage 1 made
`battle_lobby_screen.dart` actually try. Confirmed by running the real app
on `-d linux` and calling `discoverDuelHosts()`/`advertiseDuelHost()`
directly: both threw `NsdError(MissingPluginException(No implementation
found for method startDiscovery/register on channel com.haberey/nsd))` — a
clean, catchable Future rejection, not a native crash.

`_startJoining`'s existing try/catch DID catch this cleanly and reset to
`_LobbyMode.idle` — from the user's perspective indistinguishable from "the
app crashed back to the battle menu," even though it was working exactly as
coded. The real bug: `_startHosting` treated *any* `startAdvertising`
failure as fatal to hosting, even though the mDNS-advertise half is purely
cosmetic — the underlying `LanSocketTransport` listening socket has no `nsd`
dependency and peers can reach it directly if they know the address.

**Fix — manual IP fallback restored to the real duel flow**, reusing the
exact pattern already proven in `gate_screen.dart`'s M4.5 two-device gate
(which is where "manual IP entry... previously had that working" came
from — a separate diagnostic screen, not part of the battle lobby):
- `LanMatchDiscovery.startAdvertising` now binds the listening socket first
  (unconditional) and treats the `nsd` registration as best-effort — a
  failure there is logged and swallowed, never fatal to hosting. Added
  `listeningPort` + `localAddressHint()` so the host can display its
  address for the peer to type in.
- `LanMatchDiscovery`/`battle_lobby_screen.dart`'s `_startJoining` no longer
  treats an `nsd.startDiscovery` failure as fatal either — it surfaces as a
  small inline note ("Automatic discovery isn't available here") and stays
  in the joining view rather than bouncing to idle.
- `_JoiningSection` now has a permanent `host:port` manual-entry field
  (always visible, not just on discovery failure — real networks can also
  block multicast outright via AP isolation, per `lan_discovery.dart`'s own
  risk note) that dials `LanSocketTransport.connectTo` directly, same
  hand-off path (`_beginDuelSetup`) as an mDNS-discovered peer.
- `_HostingSection` now displays "Listening on `<ip>:<port>`" so the host
  can read it off to the joining player.

**New test** (`test/battle/networking/match_discovery_resilience_test.dart`)
exploits a convenient property: the plain `flutter_test` harness has no
platform channels registered either — the same condition as `nsd` on Linux
desktop — so it validates the exact resilience path without needing a real
device: `startAdvertising` still binds and accepts a real connection even
though mDNS registration fails, and `startDiscovering` fails cleanly (never
hangs). Full suite green except two pre-existing, unrelated issues surfaced
by the calendar rolling to 2026-07-20 while re-running the suite (not
caused by this fix — see below); do not confuse them with this fix.

**Two pre-existing, unrelated issues noticed while re-verifying (not fixed
here, out of scope for this bug report):**
- `test/spells/spell_authorization_test.dart` — "a caster holding a valid
  loan grant naming them may cast" hardcodes `expiresAt:
  DateTime.utc(2026, 7, 20)` and calls `castingPlayerMayUse` without an
  explicit `now:` override, so it silently relied on real wall-clock time
  staying *before* 2026-07-20. Today's rollover to that exact date makes the
  grant read as already-expired at midnight. Needs a real `now:` fixture
  fix, not a networking concern.
- `test/spells/inscribe_test.dart` / `test/ui/gate_runner_test.dart` —
  intermittent "SRS download failed — check your network connection" under
  system load (these tests fetch/cache a large structured-reference-string
  file and run real ~2GB-RSS provers). Passed cleanly in this session's
  earlier full-suite run; failed only when re-run under heavier concurrent
  load (this machine was also running the user's own live Pixel 6 session
  throughout). Environmental, not a logic regression.

---

## LAN duel setup Stage 1 implemented (docs/LAN_BATTLE_WIREUP_PLAN.md) (2026-07-19)

**Closes the "no LAN → `BattleScreen` flow" gap** noted below (Sightings entry)
and in `BATTLE_AUTH_PLAN.md §0a` — `battle_lobby_screen.dart` no longer
dead-ends at "Ready to duel."; it now runs the full handshake
(`runDuelSetup`, `lib/battle/networking/duel_setup.dart`) and pushes
`BattleScreen` with a real `BattleSession`. New: `duel_setup.dart`,
`duel_battle_setup.dart` (symmetric, pubkey-sorted `BattleState` — DECISION 2),
`duel_host_settings_screen.dart`, `duel_join_chapter_screen.dart`,
`ui/widgets/chapter_picker.dart` + `int_stepper_row.dart` (extracted from
`solo_practice_settings_screen.dart`, reused by the new host-settings screen).
Two new wire types (`matchIdNonce` 0x1A, `artifactLoadout` 0x1B) plus
`battleProtocolVersion` on `DeviceCapabilities` and an asymmetric
`sendHostMatchConfig`/`receiveHostMatchConfig` pair on `BattleSession`
(host-authoritative config — DECISION 3; `exchangeMatchConfig`'s existing
strict-equality check can't express "guest adopts whatever the host sends in
this same round trip," since the guest can't already know the value it would
need to send back to match).

**Stage 1 only** (LAN_BATTLE_WIREUP_PLAN §2 DECISION 4): identity auth + real
pubkey binding are real; peer spell casts are trusted, not proof-verified
(`TurnLoop.verifyProof` stays null, same as solo/test). Do not present this as
secure play. Stage 2 (proof verification, cast authorization, optional signed
state hash) is separately scoped in the plan.

**Real bug found and fixed while building this — not scoped to the new
code:** `BattleFrameReader`/`BattleSession.framesOfType` (`battle_wire.dart`,
`battle_session.dart`) used a plain broadcast `StreamController`, which drops
any event added while it has zero listeners. Every exchange method's
`send(...); await framesOfType(type).first` pattern has a real window where
the peer's reply can be decoded and dropped before the local `.first` call
gets around to subscribing — this is possible on a **real two-device LAN
duel**, not just a same-process test artifact (two devices' differing FFI
latency during `exchangeIdentityAuth`, e.g., is enough). It surfaced
reliably in `duel_setup_test.dart` once `exchangeIdentityAuth` (FFI-heavy) sat
directly before a new symmetric exchange. Fixed by making
`BattleFrameReader` buffer per-type (`_pendingByType`) and deliver directly to
a registered waiter when one's already listening (`_waitersByType`) — a frame
is never dropped, and never replayed to a *later* caller for the same type
(every call site's usage is "at most one active waiter per type," so a later
call is always for that type's next occurrence, e.g. next turn's
`actionCommit`). Full existing test suite (479 tests) re-run green after the
fix — no regressions. See `battle_wire.dart`'s `BattleFrameReader` doc comment
for the full explanation.

**Also found (test-only, not a production hazard):** a second, unrelated race
in the *test* harness itself — `Future.wait([runDuelSetup(...host),
runDuelSetup(...guest)])` evaluates the host call synchronously up to its own
first `await` before the guest call even starts, so host's first `send()`
could race ahead of guest's `BattleSession` ever subscribing a listener
(dropped by the *transport-level* broadcast stream, same class of bug as
above but one layer up). This can only happen when both roles run in one
isolate — i.e. every test using `InMemoryTransport`, never real cross-device
play, since two real devices each run their own independent event loop with
no shared synchronous ordering. Fixed with a one-line `await
Future<void>.value();` yield in `runDuelSetup` right after constructing the
session, forcing both sides' constructors to finish before either sends
anything — harmless in production (a real LAN socket already buffers at the
OS level regardless of listener timing).

**Verification done:** `test/battle/networking/duel_setup_test.dart` (new) —
paired-session integration confirming byte-identical `BattleState` across
host/guest with *different* artifact loadouts (deliberately, to catch a
regression back to a stubbed peer loadout) and pubkey-sorted role assignment,
plus a 2-turn `TurnLoop` determinism check over the real `BattleSession` (not
a fake). `flutter analyze` clean on every new/touched file. Full suite (479
tests) green.

**Not yet done — the actual gate (CLAUDE.md: hardware run > everything
else):** no two-device LAN pass. This environment has no second physical
device; the headless paired-session tests are necessary but the plan's own
§6 risk section is explicit that they're not sufficient. Whoever picks this
up next should run `flutter run` on two devices (or one device + `-d linux`
as the second) on the same network, host from one, join from the other, and
play at least one full turn before calling Stage 1 done.

---

## Sightings tab implemented (docs/SIGHTINGS_PLAN.md) (2026-07-19)

Full vertical slice: `lib/spells/sighting_asset.dart` (`SightingAsset` model
+ file-per-record store, grouped by opponent pubkey), the `0x01`/`0x03`
wire-format name field (`turn_loop.dart` `_encodeAction`/`_decodeAction`,
wire-format bump per plan §2 — nothing had shipped, so no compat shim), the
certified BASE mana cost retained via a new `TurnLoop.lastCertifiedBaseManaCosts`
turn-scoped map (factored out of `_certifiedManaCost` step 1 into
`_certifiedBaseManaCost` so the two call sites can't drift), the
`sightingsFromResolved` pure capture-filter + gated `_recordSightings` hook
in `battle_screen.dart`, and the grouped `_SightingsTab` UI in
`library_screen.dart` (replacing the placeholder; stale header comment fixed).

**Capture is wired but dormant** (plan §0a): there is still no LAN →
`BattleScreen` flow (`BattleScreen` is only ever constructed with a
`SoloBattleSession`). The capture hook is correct and will start populating
the tab the moment a real networked `BattleTurnSession` reaches
`BattleScreen` — proven here with the synthetic-event tests below, not by
playing a duel.

**Widget-test limitation, not silently skipped:** attempted a `testWidgets`
pass driving the real `LibraryScreen` → SIGHTINGS tab (`test/ui/sightings_tab_test.dart`,
since deleted). It hung indefinitely under both `pumpAndSettle()` and bounded
`tester.pump(Duration(...))` — this is the same, already-documented
`testWidgets()` + real `dart:io` + `FakeAsync` zone deadlock as the "Real
finding" entry further down this log (`BattleScreen`'s `_loadSpells()`):
`_CraftingsTabState.initState()` fires `SpellAsset.loadAll()` (real disk I/O
against the fake-path-provider temp dir) as an un-awaited side effect of
`pumpWidget()`, outside any `runAsync()` wrapping, with no constructor seam
to inject pre-loaded data. `test/ui/commune_trade_navigation_test.dart` had
already independently hit and documented this exact same "`LibraryScreen`
never settles, even on its unrelated default tab" limitation for the Loans
tab; this confirms it's structural to `LibraryScreen`, not specific to
Sightings. Per the same precedent (didn't make an architecture change to
force a test past a pre-existing, unrelated limitation without asking):
covered the actual logic with two disk-I/O-free unit-test files instead —
`test/spells/sighting_asset_test.dart` (model/store: upsert, round-trip,
grouping, delete) and `test/ui/battle_screen_sightings_capture_test.dart`
(`sightingsFromResolved` filtering + one persistence round trip through
`SightingAsset.record` confirming a repeat cast upserts). Manually confirmed
`flutter run -d linux --release` still boots and runs cleanly with the new
tab wired in (no GUI automation tooling in this sandbox to click through and
screenshot the tab itself — same tooling gap noted in the "Real finding"
entry below).

## Morphic (WWWW) reform: guarantee an Earth slot, no more stillborn successors (2026-07-18)

Follow-up to the previous entry: investigating the flaky
`summon_cast_test.dart` failure ("reform through a real battle turn: a dying
Morphic creature leaves a successor") found a real, if narrow, design gap —
not just a flaky test.

**Mechanism:** `morphicReducedSequence` (`lib/battle/models/creature_spec.dart`)
picks `floor(n/2)` elements from the dying creature's full element sequence
uniformly at random (Fisher-Yates over indices). `CreatureSpec._statsOf` sets
`maxHp = earthCount` in whatever got picked, with **no minimum floor** (an
already-documented, deliberate design principle). Put together: a Morphic
reform whose random draw happens to exclude every Earth activation spawns a
successor at 0 HP — dead on arrival, no combat, no visible cause. Quantified
against the test's own `WWWW FF EE` (8-element) creature via a 20,000-trial
probe: **21.6%** of draws were stillborn this way (matches
`C(6,4)/C(8,4) = 15/70 ≈ 21.4%` by hand), and 98.5% of those couldn't
re-chain either (their own reduced sequence wasn't a pure `WWWW`), so the
whole reform line silently vanished. `TurnLoop._reapDead` running 3x per
turn (action resolution → creature-AI sweep → end-of-turn tick) meant a
stillborn successor from the first reap got swept away by the second before
anyone saw it exist.

**Soren's call, on hearing the mechanism explained:** this was intentional
when the "no minimum floor" design went in, but re-litigated once he saw it
concretely — instant, unexplained death on reform reads as a feel-bad
moment, not fair randomness. Decision: reserve one of the `half` reduced
slots for a guaranteed Earth activation (chosen at random among the
original's Earth activations, same as everything else); the remaining
`half - 1` slots stay fully random as before. If the original has zero
Earth to begin with, there's nothing to reserve — same as an original
summon cast with zero Earth, which already spawns at 0 HP by the same
"no minimum floor" principle; this fix targets the "had Earth, randomly
lost it on reform" case specifically, not that pre-existing edge case.

**Verification:** re-ran the same 20,000-trial probe against the fixed
`morphicReducedSequence` — 0/20000 stillborn. Added permanent regression
coverage in `test/battle/models/creature_spec_test.dart` (Earth-guaranteed
across 500 deterministic RNG draws; explicit fallback-to-random case when
the original has no Earth at all). The previously-flaky
`summon_cast_test.dart` case passed 15/15 in a row (was failing roughly
1-in-3 to 1-in-5 runs before). Full `flutter test test/battle` (199 tests,
was 197 — the 2 new creature_spec cases) green, no regressions.

## Bellows (Air-Fire multiplierCycles) never actually amplified anything (2026-07-18)

Soren reported that Airy Bellows (Air-flavor multiplierCycles, targeting the
caster's next Water-flavor effect) didn't visibly double the next water
spell's effect.

**Root cause:** `WizardAvatar.pendingEffectMultipliers` was correctly *set*
by `EffectApplicator._applyMultiplierCycles` and correctly synced in
`BattleState`'s serialization, but the only place that read it —
`TurnLoop._applySpell` (`lib/battle/engine/turn_loop.dart`) — just called
`.remove()` on it and discarded the value, behind an explicit
`TODO(battle): apply the retrieved multiplier ... once SpellEffect supports
it`. This was affinity-generic code, so **all four Bellows flavors were
broken** (Fire→Air, Earth→Fire, Water→Earth, Air→Water), not just the one
Soren happened to test.

**Design call, escalated and resolved:** "doubling power" has no uniform
numeric meaning across the 16 effect kinds (Divination/TileModification/etc.
have no obvious "power" field). Soren's answer: don't scale fields at all —
insert extra copies of the *same resolved effect* into the resolution
order, applied immediately after the original (2 total for base, 3 under
Potency). This sidesteps the per-effect-kind semantics question entirely
and is the mechanism now implemented.

**Fix:** `TurnLoop._applySpell`'s per-formula loop now computes each
formula's own affinity, consumes (`.remove()`s) any pending multiplier keyed
to *that* affinity, and calls `EffectApplicator.apply` that many times
instead of once. Consuming via `.remove()` means only the first
matching-affinity formula in a spell is amplified — matches the design doc's
singular "next effect of [element]" wording, and naturally prevents the
multiplier from persisting past the one cast that consumes it.

**Known interaction, not a new bug:** effects that reposition their target
(e.g. Air-flavor Damage's knockback) can cause the second application to
miss if the first knockback already moved the target off the fixed spell
target tile. Confirmed via a boundary-pinned test case (dummy placed where
the knockback push lands out-of-bounds and no-ops) that when the target
*does* stay put, the second hit lands correctly. This is inherent to
"insert a copy in the resolution order" for position-mutating effects, not
something this fix introduces or was asked to solve.

**Verification:** new `test/battle/engine/multiplier_cycles_test.dart`, 7
cases — all four Bellows flavors doubling their target element's damage
end-to-end through `TurnLoop`/`SoloBattleSession`, one Potency case (2→3),
one negative case (non-matching affinity untouched), one single-consumption
case (multiplier doesn't leak into a second cast). Full `flutter test
test/battle` (197 tests) green, no regressions.

## Practice Mode — scoring redesign: enrollment + contrastive crossing (2026-07-16)

Follow-up to the 2026-07-10 entries, triggered by Soren's on-device report
that "words tend to keep skipping forward" and a prior session's conclusion
that MFCC+DTW+CMN "can't tell right word from wrong word, only attempt from
silence." Reproduced everything offline before changing anything; the
offline numbers say that conclusion was half right — and its reassuring
half was wrong.

### The smoking gun: pure digital silence crossed the real word templates

Simulating the exact shipped pipeline (c0-drop, CMN, 2x sliding window,
cost/steps, floor 7.0, debounce 4) against the real
`assets/practice_templates/*.json`: 1s of all-zero PCM crossed aqua/terra/
aer at frame 4 — the debounce minimum, i.e. 40ms into capture — and
ignis/finitus within ~1s. Same for ambient and loud noise. The reassuring
"noise settles at ~10.6, floor 7.0 has margin" figure from 07-09/07-10 came
from the unit tests' toy sine-sweep reference, not real templates. Two
structural causes, neither fixable by any floor value:

1. **Short CMN'd windows are degenerate.** The scorer evaluated from the
   first frame; a 4-frame mean-centered window carries almost no shape,
   and its corner-anchored DTW cost collapses toward the reference's own
   mean frame magnitude.
2. **After c0-drop + CMN, silence is the metric's best imposter.** A
   silence frame is (near-)zero; its distance to a CMN'd reference frame
   is just that frame's magnitude — which measures BELOW a correct word
   spoken by a different voice (silence ~2.7-4.7 vs cross-voice correct
   ~5.3-6.3, full-utterance). Loudness has to gate silence out before the
   metric votes; that complements dropping c0, it isn't redundant with it.

### Word discrimination: absolute cost can't, contrastive ranking can — same-voice only

Rendered the 5 words with a second Piper voice (`it_IT-riccardo-x_low`,
natively 16 kHz) and with the template voice at altered prosody (paola +
`--length_scale 1.12 --noise_scale 0.85 --noise_w 0.9` — same voice,
different utterance: the enrolled-player proxy). Full-utterance cost/steps
against the real templates:

- **Cross-voice (riccardo):** correct diagonal 5.31-6.26 vs wrong-word
  off-diagonal 5.08-7.95 — complete overlap, no absolute floor exists.
  Argmin over the closed 5-word vocabulary: only 2/5 correct (aer, the
  shortest template at 34 frames, wins rows it shouldn't — short
  references get a systematic cost/steps advantage).
- **Same-voice (paola-variant):** diagonal 2.83-3.55, argmin 5/5 correct,
  margins 1.03-1.71. Speaker match is what unlocks the metric — which is
  why per-user enrollment was promoted from deferred fast-follow to built.

### What shipped

Crossing a word now requires ALL of (streaming_phoneme_scorer.dart's
header is the canonical description):
1. *Minimum-audio guard* (`kMinSegmentAudioFraction` 0.6 x ref frames of
   fresh audio) — kills the degenerate-short-window crossings.
2. *Energy gate* (`kMinVoicedFraction` 0.35 voiced; voiced = RMS ≥
   max(`kSpeechRmsEpsilon` 0.004, 2.5x rolling ambient)). The ambient
   follower starts at 0, attacks down instantly, rises slowly — seeding
   it from the first frame would lock the threshold above speech if
   capture opens mid-utterance.
2b. *Spectral-structure gate* (`kMinSpectralNorm` 3.0): mean L2 norm of
   the voiced frames' CMN'd MFCCs. Broadband noise passes RMS at any
   volume but is nearly featureless after CMN — measured speech 4.1-8.0,
   uniform noise ~1.96 amplitude-independent, silence 0. Must be computed
   over voiced frames centered on their own mean: the window can carry a
   leading-silence stub (attempt-gap reset lags onset by up to 29
   frames), and CMN over a bimodal silence+sound window inflates every
   deviation — silence-vs-sound contrast masquerading as structure. This
   bimodality was exactly how "noise -> aer" kept crossing at every
   floor/margin combination until the gate went voiced-only.
3. *Absolute cap* (the old "floor", demoted) — anti-babble only.
4. *Contrastive margin* (the actual discriminator): the target template
   must beat every other vocabulary word on the same audio by
   `kDefaultContrastiveMargin`. Competitors are evaluated lazily (when
   1-3 pass, plus every `kHintEvalIntervalFrames` for the stall hint), so
   steady-state cost stays ~1 DTW/frame.
- *Attempt segmentation*: `kAttemptGapFrames` (30, ~300ms) consecutive
  unvoiced frames reset the segment window — a failed attempt's stale
  audio otherwise inflates a clean retry's corner-anchored cost forever
  (found via the wrong-then-right unit test: quality pinned at 5.5 on
  continuous no-pause retries). Consequence worth knowing: **a retry
  chanted with no pause stays stalled** — accepted strict-side behaviour;
  a breath is what marks a new attempt (the capture UI says so).

**Enrollment** (vocal_enrollment.dart + PerUserEnrolledTemplateSource in
vocal_template_source.dart + the enrollment card in practice_screen.dart):
player records each word once — the Piper clip plays first as the
pronunciation model to imitate; Piper stays the *trainer*, the player's
voice becomes the *reference*. Stored at
`<docs>/practice_enrollment/<word>.json`, same schema as the bundled
templates; per-word fallback to Piper until enrolled; recording trimmed to
its voiced span and rejected under ~20 voiced frames. Stall hint
("Hearing something closer to 'terra'…") after 2.5s dwell, fed by the
scorer's `currentBestGuess`.

**Per Soren's decisions this session:** enrollment + contrastive is the
direction (over Sherpa-ONNX and over reframing as an honest
attempt-detector); miss feedback = stall + subtle hint; tuning bias =
strict (never false-advance — a stalled correct attempt costs a retry, a
false advance corrupts the training loop invisibly).

### The e2e harness is what actually caught things

`test/practice/real_template_e2e_test.dart` runs the real scorer against
the real bundled templates with committed Piper renders
(`test/practice/fixtures/voices/`, README has provenance): same-voice
correct must complete, all 40 wrong-word pairs (both voices) must stall,
silence/noise must stall. Its first run caught 5 false advances the
synthetic-chirp unit tests sailed past (4 with aer as target). Constants
were then chosen by grid search through this harness:
(floor 6.25, margin 0.9, debounce 8) — one of three zero-false-advance /
5-of-5-correct operating points (also clean: 5.75/0.85/6, 6.0/0.85/6);
picked for maximum floor headroom since a real human enrollment matches
itself more loosely than the Piper same-voice proxy. At the old
0.75 margin / debounce 4 there were 4 wrong-word false advances.

### Still open — the next real-device pass

- Constants are calibrated against Piper-render proxies; a real human
  enrollment + real mic is the actual test. Use the live quality readout,
  and re-run the e2e harness after ANY constant/template change — it is
  the practice-mode equivalent of the golden corpus.
- aer (34 frames, template norm 3.43 — lowest in the vocabulary) is
  structurally the weakest target. A slower re-render (length_scale 1.7)
  was tried and REJECTED: it fixed 2 of 3 aer false advances but made
  correct same-voice aer stall — don't retry that without new evidence.
- Unenrolled fallback (cross-voice) correct-word completion is NOT
  guaranteed and deliberately not asserted — accepted cost of strict
  tuning; the enrollment card explains it. Only cross-voice aqua
  completed at the shipped constants.

## Summons UI vertical slice — Rune Craft toggle, personality picker, battle display (2026-07-14, follow-up)

Closed the gap the previous entry flagged: the Summons engine had no way to
actually be *reached* from the UI. Added the missing UI plumbing so summon
spells can be inscribed and battle-tested, per Soren's ask after noticing the
Rune Craft screen had no Incantation/Summon toggle.

**What shipped:**
- `lib/main.dart` (Rune Craft / `GameScreen`): an Incantation/Summon `_ModeBar`
  toggle styled like the existing `_RuleBar`; a live `_SummonPreview` widget
  (swaps in for `FormulaBar` in Summon mode, built from
  `CreatureSpec.fromElements(_formulaTracker.committed)` — no new tracker
  plumbing needed, `committed` was already the full flat sequence); a
  personality picker folded into `_SpellNameDialog` (returns a small
  `_InscribeDetails` record instead of a bare `String` now); `isSummon`/
  `summonPersonality` threaded into the existing `inscribeSpell()` call.
  `GameScreen(loadedSpell:)` (the "view/re-edit a spell" path — see below)
  now also restores `_isSummonMode`/`_summonPersonality` from the loaded
  spell in `initState()`, so re-opening a summon spell shows it correctly
  instead of silently defaulting back to Incantation mode.
- `lib/battle/models/creature_spec.dart`: new display-only additions
  (`kSummonAbilityLabel`, `summonSummaryLabel`, `summonSummaryFromFormula`) —
  the single shared formatter every UI call site uses, mirroring
  `formulaEffectLabels`/`kEffectKindLabel`'s existing pattern in the sibling
  `effect_kind.dart`. `kSummonPersonalityLabel` went in `minion.dart` instead
  (it defines `SummonPersonality`; `creature_spec.dart` doesn't import
  `minion.dart` and adding that import would create a cycle, since
  `minion.dart` already imports `creature_spec.dart`).
- `lib/ui/battle_screen.dart` / `lib/ui/library_screen.dart`: the
  selected-spell caption and library list both branch on `spell.isSummon` to
  show `summonSummaryFromFormula(...)` instead of incantation effect labels;
  both spellbook/library card lists get a small `Icons.pets` corner badge on
  summon-mode cards (added by *wrapping* `SpellCardWidget` in a `Stack` at
  each call site, not by editing `SpellCardWidget`/`SpellCardPainter`
  themselves — that widget's rendering is pinned by
  `test/ui/spell_card_widget_test.dart`).

**Two scope cuts, made from evidence, not guesswork:**
- `lib/ui/spell_view_screen.dart` (`SpellViewScreen`) is **dead code** —
  grepped every call site; `library_screen.dart`'s actual "View" action
  navigates to `GameScreen(loadedSpell: spell)`, not `SpellViewScreen`. It's
  never instantiated anywhere. Skipped touching it; the loaded-spell path
  through `GameScreen` already got the mode-restore fix above, which is the
  thing that's actually reachable.
- `kEnhancementDescription` (`lib/spells/enhancement_zone.dart`) is **also
  dead** — defined, but no widget currently renders it (the cast-time
  `_EnhancementPicker` only shows the short zone label, e.g. "POTENCY", never
  the longer description string). The plan assumed swapping its Potency
  entry for a summon-aware one; since nothing displays it today, there was
  nothing to swap. Didn't invent a new description tooltip just to have a
  branch to write.

**Real finding: `testWidgets()` + real `dart:io` hangs, and why the fix only
gets you halfway.** Wrote `test/ui/battle_screen_summon_test.dart` to widget-test
the badge/caption end-to-end through the real `BattleScreen` tree. It hung
indefinitely — not slow, *actually stuck*, confirmed by killing it after 5+
minutes with zero progress and no timeout error (a genuine infinite loop or
zone deadlock would look exactly like this; a slow-but-alive process would
have eventually printed `package:test`'s own timeout failure).

Bisected with throwaway probe scripts (`dart run` doesn't work for
Flutter-dependent code — `dart:ui` isn't resolvable outside a `flutter test`
binding; had to probe via a real `testWidgets`/`test` pair instead):
`SpellAsset.save()` alone, under a plain `test()`, resolves instantly. The
*identical* call, under `testWidgets()`, hangs forever. Root cause:
`testWidgets` runs its body inside `package:fake_async`'s `FakeAsync` zone
(so animation timing is deterministic and controllable via `pump(duration)`)
— and genuine `dart:io` operations awaited from inside that zone never get a
chance to complete, because nothing pumps the *real* event loop while the
fake zone is driving. This is `flutter_test`'s own documented gotcha
(`WidgetTester.runAsync` exists specifically for it), just not one this
codebase had hit before — `spell_asset_test.dart` only ever uses plain
`test()`, and no existing widget test does real `SpellAsset` I/O mid-test.

Wrapping the direct `spell.save()` call in `tester.runAsync()` fixed *that*
call — but `BattleScreen.initState()` also fires `_loadSpells()`
(`SpellAsset.loadAll()`, a real disk read) as an un-awaited side effect of
`pumpWidget()`, which runs *outside* any `runAsync` wrapping (it has to —
`pumpWidget` needs the fake-async clock). That Future's completion can't be
reliably synchronized with from outside; the widget has no constructor seam
to inject pre-loaded spells for a test. Concluded this specific widget
(real-disk-loaded `BattleScreen`) isn't practically testable via
`testWidgets` without a production-code change (a spell-injection seam)
that's a real architecture decision, not something to sneak in to satisfy a
test. **Didn't make that change without asking** — deleted the widget test
and covered the same logic instead with direct unit tests on
`summonSummaryLabel`/`summonSummaryFromFormula` (`creature_spec_test.dart`,
+8 cases: ability-clause formatting, zone-name parsing, case-insensitivity,
void-formula null case) — the part that actually needed verifying was the
*string content* the caption shows, not that `Stack`/`Icon`/`Text` render
(Flutter's own job to guarantee that).
`test/ui/game_screen_summon_mode_test.dart` (the Rune Craft toggle, added
alongside the main pass below) hit none of this, because `GameScreen` does
no disk I/O until the player explicitly presses Inscribe.

**Verification run:**
- `flutter analyze`: clean project-wide (same pre-existing warnings only).
- `flutter test`: 310 run (up from 303 pre-slice), same 6 pre-existing
  unrelated `proof_intake_test.dart` failures, zero new failures, zero
  hangs after the above fix/cut.
- Manual: confirmed `flutter run -d linux` still boots cleanly; full
  interactive click-through (toggle → draw → inscribe → battle → cast) not
  independently re-driven this pass beyond the automated widget test for the
  Rune Craft half — no GUI automation tooling (`xdotool`/`scrot`/etc.) or
  `integration_test` harness exists in this sandbox to drive a real mouse
  through the battle-screen half, and building one was out of scope for a
  UI-plumbing pass. Flagging this explicitly: `game_screen_summon_mode_test.dart`
  is real automated verification of the Rune Craft toggle/preview through
  the actual widget tree; the battle-screen badge/caption verification is
  one level down (unit-tested string content + code review + `flutter analyze`),
  for the reasons above.

## Summons system implemented — engine + battle wiring, no crafting/casting UI yet (2026-07-14)

Implemented the design doc's "Summons" section: a summon-mode spell reads its
element sequence as a creature instead of an incantation effect. Scope was
explicitly limited (per plan) to the engine + battle wiring — no Rune Craft
"summons mode" toggle, personality-glyph picker, or in-battle summon-casting
UI. Every summon this pass is created programmatically (tests, or a future
UI pass); `SpellAsset.isSummon`/`summonPersonality` exist and round-trip
through JSON, but nothing in `main.dart`/`battle_screen.dart` sets them yet.

**New module: `lib/battle/models/creature_spec.dart`.** Pure, no-Flutter,
fully unit-tested (`test/battle/models/creature_spec_test.dart`, 41 cases).
`CreatureSpec.fromElements(List<BorderZone>)` derives affinity (most-common
element, first-appearance tiebreak), stats, and the 8 ability patterns from
a flat element sequence. Also carries the resistance wheel
(`applyResistance`/`resistanceTierOf`) and `morphicReducedSequence` (WWWW
death-reform selection).

**Stat formula — a real design gap, resolved with a documented default.**
The design's "logarithm base 1" for Earth/HP is mathematically undefined
(division by ln(1) = 0). Read as linear growth instead: `maxHp =
max(1, earthCount)`. Fire/Air/Water use `1 + floor(log_base(count))` with
base 2/2/3 respectively. Used **integer repeated-division log**, not
`dart:math`'s `log(n)/log(base)` — the latter lands on the wrong side of
exact powers due to float error (`log(4)/log(2)` can evaluate to
`1.9999999999999998`, silently off-by-one at every power-of-base boundary).
This would have been a very easy bug to ship undetected without the boundary
tests in `creature_spec_test.dart` (counts 1/2/3/4/7/8 for damage/move,
0/2/3/8/9 for range).

**`Minion` collapsed from a sealed Sprite/Hound hierarchy to one concrete
class.** The v2.4 model (kept dormant in the codebase since the v3.0
effect-table rework, per `effect_kind.dart`'s own comment) is gone:
`spiritStats`/`houndStats`/`ignoresTerrain`/`splashRadius`/`knockback` all
deleted. A creature's identity is now `affinity` + `stats` (from
`CreatureSpec`) + `abilities` (`Set<SummonAbility>`) + `personality`
(`SummonPersonality`, glyph-assigned in the design, defaults to
`aggressive` — no picker UI yet) + `elementSequence` (retained for Morphic
reform, not just the derived spec).

**A real `actedThisTurn` bug caught by the integration tests, not by
inline reasoning.** First-pass logic set `actedThisTurn: !enhancements.isPotent`
at creation — backwards. `actedThisTurn` is a transient "acted this
Summons-phase pass" flag, unconditionally reset to `false` at the end of
every `_resolveSummons` call; a creature created during action resolution
(phase 5) never participates in the *current* turn's already-finished
Summons phase (phase 4) regardless of this flag's value — it only
determines eligibility for the *next* turn's Summons phase. Setting it
`true` for non-Potent summons made them skip their actual first turn
entirely; the "Potent = immediate turn" case needs the flag to *stay*
`false` after the bonus action too, since Potency grants an *additional*
action, not a replacement for the next Summons-phase turn. Two of the eleven
`summon_cast_test.dart` cases failed against the first-pass code and pinned
the fix — the kind of bug that reads as obviously correct until you trace
the phase-4/phase-5 ordering by hand.

**Big (EEEE) footprint is a pure function of position, not stored state.**
`footprintFor(center, abilities)` = `[center]` normally, or `[center,
neighbor0, neighbor1]` for Big (two *consecutive* hex-neighbor directions,
which are themselves mutually adjacent — a true triangle). This meant the
state-hash serialization (`battle_state.dart toCanonicalBytes`) only needs
to write `position` once, not three coordinates — footprint, spawn-tile
validity, targeting distance, and knockback-immunity all derive it on
demand via `Minion.occupiedTiles`/`distanceTo`.

**Molten Carapace (EFEF) reflects through the *effect's* attacker position,
not a per-ability special case.** `EffectApplicator._hitMinion(ctx, m,
amount)` now takes the `ApplyContext` directly and derives both the
resistance-wheel `attackType` (`ctx.descriptor.affinity`) and the carapace
check (`hexDistance(ctx.caster.position, m.position) <= 1`) from it — every
existing damage path (direct/traversal/splash/knockback) gets both behaviors
for free, no new call-site plumbing needed beyond the signature change.

**Peer trust boundary extended, not reinvented.** Added
`TrajectoryParser.certifiedElementSequence` (refactored `parse` and it to
share one `_drive(outputs)` helper) and threaded a parallel
`certifiedPeerElementSequences` map through `_verifyPeerSpellCast` /
`_resolveActions` / `_applySpell`, alongside the existing `certifiedPeerFormulas`
(B-1/B-8). A peer's summoned creature is derived from the SNARK-certified
trajectory, never the wire-declared `SpellAsset.formula` — same pattern,
same verification gate (`verifyProof`/`vkBytes` non-null), no new trust
surface. **Not covered by a full two-client forgery integration test this
pass** — that would need real proof bytes through the whole
`_TurnSessionPair` harness (see `turn_loop_determinism_test.dart`), which is
heavy (FFI proving, ~7s/proof). Covered instead at the unit level
(`certifiedElementSequence` correctness, `trajectory_parser_test.dart`) plus
structural analogy to the already-tested `certFormulas` mechanism it
mirrors exactly (`formula_certified_test.dart`'s "wire-formula bypass"
case). Flagging this gap explicitly rather than overclaiming coverage.

**Verification run:**
- `flutter analyze`: clean project-wide (only pre-existing warnings in files
  this change never touched: `spell_test_lab_screen.dart`,
  `scripts/find_mask_vector.dart`).
- `flutter test`: 299 run, only the same 6 pre-existing
  `test/battle/engine/proof_intake_test.dart` failures (confirmed via
  `git stash` — reproduce identically with this change removed; a
  proof-field-count fixture mismatch unrelated to Summons).
- `flutter build linux --debug`: succeeds; the binary boots and runs cleanly
  for 8s with no error output (no summon UI exists yet to drive
  interactively, so this is a boot/regression check on the screens this
  change's files feed — spell cards, battlefield rendering, inscription).
- No `RULESET_VERSION` bump (summon derivation is off-circuit Dart, no CA
  rule changed). The `BattleState.toCanonicalBytes` format *did* change
  (new creature identity fields) — fine pre-release, but both clients need
  the same build for the state-hash exchange to agree.

**Not built this pass (flagged for the next one, per the locked plan
scope):** Rune Craft summons-mode toggle, personality-glyph assignment UI,
in-battle summon-casting affordance, and a full two-client peer-forgery
integration test for the certified element sequence.

## Practice Mode — reverted to whole-word checkpoints after mid-word bleed-through on real speech (2026-07-10, fifth follow-up)

First proper multi-word real-device session (Pixel, quiet room) surfaced a
structural bug the floor value couldn't fix: sometimes a checkpoint would
clear semi-instantly mid-word. Soren's own diagnosis, confirmed correct:
saying "terra" could register the first syllable ("ter") as a poor-but-
sufficient match for terra's first phoneme checkpoint, crossing it
prematurely, and then the trailing "-ra" would get scored against
whatever checkpoint came *next* (e.g. aer's first phoneme, if aer followed
in the formula) — a wrong-word match purely from bad luck of onset timing.

**Root cause:** `LatinPhonemes`' per-phoneme checkpoint boundaries within a
word were static, duration-weighted splits of the *reference* audio's own
frame count — never real forced alignment. They have no way to know where
a given speaker's actual articulation transitions between phones, which
varies a lot person to person and even utterance to utterance. Once wrong,
a boundary crossed too early doesn't just mis-score one phoneme, it feeds
that segment's leftover audio into the next checkpoint's window, so an
error at one boundary propagates into the next word entirely with no
recovery mechanism.

**Fix: reverted to one checkpoint per whole word**, not per phoneme.
`VocalTemplate.checkpointFrameIndices`/`checkpointLabels` are now always
length 1 in `SingleVoiceTemplateSource` (see that file's updated header).
This removes the mid-word-bleed failure mode structurally — there's no
sub-word boundary left to misplace — at the cost of losing "which specific
phoneme within a word stalled" feedback granularity (still keeping "which
*word* stalled," via `wordIndex`). This matches the granularity real
Sorcerer-mode casting already uses successfully. `LatinPhonemes` itself
(the phoneme table + G2P derivation trail) is kept, unused by the scorer
for now, as groundwork for a real future forced-alignment source rather
than deleted.

Renamed `phonemeLabel(s)` -> `label`/`checkpointLabels` throughout
(`_Segment`, `CheckpointClarity`, `VocalTemplate`, `PracticeScreen`) since
the field no longer ever holds a phoneme — it's the whole word now, and
the old name would have been actively misleading, not just imprecise.

**Not yet re-tested:** this needs a fresh real-device pass to confirm the
mid-word-bleed symptom is actually gone (it should be, structurally, but
"should be" isn't "confirmed" — see the standing verification-hierarchy
rule). The floor (7.0) and CMN/windowing fixes from the last several
entries are unchanged and still apply on top of this.

## Cast-time enhancement selection — dormant wire/UI gaps found and fixed (2026-07-13)

Moved spell enhancement choice (Potency/Velocity/Efficiency/Mystery) from
library/chapter-add time (`ChapterEntry.embellishment`) to cast time in
battle (`battle_screen.dart`'s new `_EnhancementPicker`). Eligibility rule
unchanged: still gated on `SpellAsset.supremeTags` (supreme/torrential
dominance achieved during that spell's own simulation).

**This was not a pure UI relocation — the old mechanism was already dead.**
Investigation before touching anything found the add-time choice never
actually reached battle: `battle_screen.dart`'s `_loadSpells()` discarded
`ChapterEntry.embellishment` entirely, both `SpellCastAction(...)`
construction sites never passed `isPotent`/`isVelocity`, and — the real
find — `turn_loop.dart`'s wire encoder (`_encodeAction`, case `0x01`
`SpellCastAction`) never serialized `isPotent`/`isVelocity` onto the wire at
all, unlike `0x03` (`MysterySpellCastAction`), which already did. Since
`_resolveActions` rebuilds `CastingEnhancements` from the wire-decoded
action for *both* players every turn, this meant a peer's enhancement choice
would have silently desynced effect magnitude/mana cost between the two
devices in any real (non-solo) duel — invisible in solo practice, where the
"peer" is the same local action object. Fixed by mirroring `0x03`'s pattern
exactly for `0x01` (3 new bytes: isPotent/isVelocity/isEfficiency).

**Added a fourth enhancement flag, `isEfficiency` (Water), that never
existed before** — only a sorcerer-mode vocal-quality `manaCostMultiplier`
existed previously, unrelated to loadout enhancements. Because Efficiency
directly reduces mana cost (not just effect magnitude, like Potency), Soren
opted to have it — and, for consistency, Potency/Velocity/Mystery too —
cryptographically verified rather than trusted from the wire: added
`TrajectoryParser.certifiedSupremeTags(VerifiedSpellOutputs)` (mirrors
`_deriveSupremeTags`'s local-CA-replay logic, but reads the SNARK-certified
`dominanceTrajectory`/`supremeDominanceFlags` instead) and a check in
`_verifyPeerSpellCast` that forfeits the match if a peer claims an
enhancement zone their spell's own certified data doesn't back. This
subsumes the older, narrower precedent at the old `_certifiedManaCost` call
site ("hasPotentLoadout/hasVelocityLoadout only gate effects, not cost; pass
false") — all four claims are now verified up front, so the cost/effect
formulas can trust the wire flags directly afterward.

**Velocity's "+2 range" has no engine seam to attach to, confirmed by
investigation, not assumed.** `_applySpell`/`_resolveActions` apply a cast
to whatever `targetHex` is on the action unconditionally — there is no
server/engine-side range enforcement anywhere in `turn_loop.dart`. The only
range concept is `battle_screen.dart`'s `_maxCastRange`, which is
client-side UX only (gates which taps the local player's own device
accepts). `isVelocity` is now wired correctly everywhere (data model, wire,
certified verification, effect-resolution eligibility) but the actual
mechanical range bonus remains a no-op, same as before this change —
flagged to Soren explicitly as a follow-up rather than inventing new range
mechanics unprompted.

**Also extracted `_deriveSupremeTags` (formerly private to
`library_screen.dart`) into `lib/spells/supreme_tags.dart`**, since
`battle_screen.dart` now needs the same eligibility derivation to backfill
`supremeTags` for spells added to a chapter before that tracking existed —
previously only the library screen's add-to-chapter flow did this backfill,
so a spell added to a chapter long ago and never re-touched in the library
could reach battle with stale/empty `supremeTags`.

Verification: `flutter analyze` clean project-wide; `flutter test`
(excluding `proof_intake_test.dart`, which has 6 pre-existing failures
confirmed unrelated — that file and `proof_intake.dart` are byte-identical
to `HEAD`, untouched by this change) — 241/241 pass, including
`turn_loop_determinism_test.dart`'s two-client determinism test, which
exercises the exact wire encode/decode path that was fixed.

## Custom Spell Art P1 — on-device verification pass, Pixel 6 (2026-07-13)

Ran the full P1 on-device checklist against a real Pixel 6 (Android 16, 8 GB)
over adb (no `xvfb`/`xdotool` in this environment, so driven via
`input tap`/`swipe` + screenshots rather than a scripted UI driver). Required
rebuilding the Android `.so` first (`bash scripts/build_android_ffi.sh` —
`ffi/src/{bin/desktop_vk_test.rs,api/prover.rs}` had drifted ahead of the
bundled `.so`; CLAUDE.md Bug Avoidance #3). All five checklist sections pass.

**Memory (Section 1).** Baseline app PSS ~555 MB (post-proving from an
earlier real inscription in the same session — proving itself hit
RSS ~1.5 GB / wall 14.8s on-device for a T12 proof, logged separately here as
a useful data point). A single MAX import (4096×4096, 7.5 MB JPEG — the
worst legally-importable case: right at both the dimension and byte
ceilings) didn't produce a measurable spike in 0.5s-granularity sampling,
suggesting the decode+resize+encode is fast enough on Tensor G1 that the
~67 MB decode buffer comes and goes within a fraction of a second. Five
back-to-back re-imports of the same MAX file (real `Replace Custom Art`
round trips, continuously sampled at 300ms) peaked at **PSS 991,769 KB
(~968 MB)**, settling to ~653 MB five seconds after the last one — no
climbing trend across repeats, no crash, no ANR. The blob store correctly
*overwrites* the same `spellHashHex` key rather than accumulating files
(confirmed only 2 files present in `spell_art/` after 6+ total imports across
the session). `compute()` isolate confirmed: UI stayed tap-responsive
throughout every import (never needed a retry tap), and the 20s timeout
never fired on any legitimate image.

**Visual (Section 2).** 84dp library card and the full-screen 512² overlay
both render cleanly — no visible JPEG blocking at quality=96 (MAX's
selected quality step). Swipe-to-reveal-emblem works correctly and feels
right (a plain horizontal `tester.drag`-equivalent gesture, no fighting with
scroll). **Open finding, not yet a `[DECISION]`:** ALPHA (PNG with a
transparent background) flattens to **plain white** on import — but this is
*not* an explicit compositing choice in `_encodeCanonical`; it's the
`image` package's implicit default when its JPEG encoder drops the alpha
channel. Looked clean and intentional-reading in practice (not garbage), but
relying on an unstated library default for a design-visible outcome is
fragile — a future `image` version bump could silently change it. If white
is in fact the desired background, it should become an explicit
`compositeOnto(white)` step in the code so it can't drift.

**Persistence & correctness (Section 3).** Survives `am force-stop` +
relaunch (fresh PID confirmed) — art reloads from the blob store immediately
on the new process, no re-import needed. Old-shaped (pre-P1, no
artHash/artSource/artUpdatedAt keys at all) spell JSON hand-fabricated and
dropped into `app_flutter/spells/` loads with zero parse errors, renders the
vector emblem, and is even correctly grouped into the existing Kin badge —
the nullable-field migration path is solid on-device, not just in
`spell_asset_test.dart`. `Revert to Coat of Arms` deletes both
`.full.jpg`/`.thumb.jpg` from `spell_art/` (confirmed empty directory after,
not just hidden) and clears all three metadata fields from the JSON.

**EXIF / privacy (Section 4) — confirmed on genuine camera hardware, not
just the synthetic test fixture.** Shot two real photos on the Pixel 6 with
location services on (`location_mode=3`); pulled EXIF showed real GPS
(lat/lon + altitude), timestamp, and `Make=Google`/`Model=Pixel 6`/HDR+
software tag — a full, real EXIF payload, not a stub. After import, the
stored blob's EXIF is completely empty (`imageIfd` empty, no GPS IFD) at the
correct 512×512 canonical size. **Treat "stored spell art is always
EXIF-stripped" as a confirmed invariant, not just a code-level intention** —
this is the finding P2 most needs, since it's the one that becomes a real
privacy leak the moment art starts crossing the wire.

**Failure paths (Section 5).** OVERSIZE (>8 MB, pushed via `adb push`,
rejected before decode) → clean snackbar "That image is too large
(max 8 MB)." JUNK (text file renamed `.jpg`) → clean snackbar "Unrecognized
image format (PNG, JPEG, or WebP only)." Neither crashed, neither left a
partial/corrupt file in `spell_art/` (checked directly on-device both times).

**Not a bug, but noted:** immediately after a scripted rapid-fire
`import → screenshot` sequence, the small library card occasionally still
showed the *previous* art for one frame/screenshot despite the underlying
`SpellAsset` JSON and blob store already being correctly updated. Root-caused
via a new widget test (`spell_card_widget_test.dart`, "reload transition..."
— the exact no-art→art transition on an already-mounted `SpellCardWidget`)
which passes cleanly, and confirmed harmless on-device by forcing a full tab
remount (data was always correct; only the very next paint occasionally
lagged the disk write by a beat under back-to-back scripted taps faster than
a human would drive the UI). Not a P1 blocker.

**P1 is playtest-ready per this pass.** P2 (opponent art, sync,
`SpellSighting`) can proceed against this baseline whenever it's greenlit.

## Custom Spell Art P1 landed — own-library art, image caps, data-layout decision (2026-07-10)

Built P1 of the custom-spell-art feature (see the CLAUDE.md custom-art
umbrella prompt + P1 go-ahead): a player can import an image to replace the
coat of arms on their own library spells. Own spells only, no networking, no
opponent art — those stay gated behind P2/P3.

**Format substitution: JPEG, not WebP.** The umbrella prompt specified
canonical WebP; Phase 0 accepted the `image` pub package (^4.8.0) as the new
dependency without checking encode support. Turns out `image` 4.8.0 can
*decode* WebP (`lib/src/formats/webp_decoder.dart`) but has no WebP encoder
at all. Re-encoding to WebP would need a second package or a native binary.
Rather than block P1 on that, canonicalized to JPEG instead — same caps, same
hashing, same "small bounded raster" goal, just a different container. See
`lib/spells/spell_art_import.dart`'s header comment. Worth revisiting if a
future phase (P4 trading, or a nicer transparency story) actually needs
alpha/WebP.

**Confirmed image caps** (pre-decode guards, then re-encode targets):
pre-decode ≤ 8 MB source / ≤ 4096×4096 declared dimensions (checked via a
header-only `Decoder.startDecode()` parse, so a compression-bomb file is
rejected before the expensive full pixel decode); re-encode full art to
512×512 canonical JPEG ≤ 256 KB, thumbnail to 256×256 ≤ 32 KB (quality
backed off 90→80→65→50→35 until it fits, keeping whichever step first hits
the ceiling). Decode + resize + encode all run off the UI isolate via
`compute()`, wrapped in a 20s wall-clock timeout on the caller side.

**Data-layout decision: art bytes are NEVER inlined on `SpellAsset`.**
`inscribeSpell()` calls `SpellAsset.loadAll()` on every inscription to check
for a duplicate `spellHashHex`, which parses every persisted spell's full
JSON file. Inlining full-size art blobs there would make that dedup scan
read tens of MB per inscription on a mature library. Instead: `SpellAsset`
gained only lightweight metadata (`artHash`, `artSource`, `artUpdatedAt`);
the actual bytes live in a new side store (`lib/spells/spell_art_store.dart`)
keyed by `spellHashHex`, loaded only when a card is actually rendered.
Confirmed `SpellAsset.loadAll()` is a genuine load-all (parses every file),
so this split was mandatory, not a nice-to-have.

**Two-layer front/back card model.** `SpellCardWidget`
(`lib/ui/spell_card_painter.dart`) now resolves custom art at the small-card
level (falls back to the existing `commitmentHex`-keyed vector coat of arms
while loading or on a store miss — the pre-P1 rendering path is untouched
when no art is set). The full-screen overlay is a genuine two-layer flip:
custom art shows by default when present, a horizontal swipe reveals the
true, locally-derived emblem underneath, and a text hint ("Swipe to see the
true sigil" / "...the custom art") makes the gesture discoverable. This is
the anti-spoof guarantee from the umbrella prompt's hard invariant 3 — the
true emblem must never be fully unreachable — verified end-to-end by a real
widget test (swipe, assert the emblem `CustomPaint` is now showing), not
just by reading the code.

**Bug the tests actually caught: EXIF wasn't being stripped.** The first
draft of `_encodeCanonical` in `spell_art_import.dart` assumed re-encoding
through a fresh `Image` object would drop source metadata for free. A test
asserting `decoded.exif.imageIfd.isEmpty` failed: `copyCrop`/`copyResize`
deliberately *carry the source `Image`'s EXIF forward* (so orientation-aware
resizing works), so a camera photo's make/model/GPS/timestamp would have
survived into stored spell art untouched. Fix: explicitly
`resized.exif = img.ExifData()` before encoding. Left as a test, not just a
comment, so a future refactor of that function can't silently regress it.

**Flutter test gotcha: real file I/O + `Image.memory` hang `pump()`
forever, not just fail.** Widget tests that populate `SpellArtStore` (real
`dart:io` file writes/reads) and then render the result via `Image.memory`
(real `dart:ui` codec decode) must wrap the whole sequence in
`tester.runAsync()` — `AutomatedTestWidgetsFlutterBinding`'s fake-clock test
zone doesn't drive real async I/O forward, so plain `pump()`/`pumpAndSettle()`
just hangs (observed: 2+ minute timeout, not a fast failure). Even inside
`runAsync`, `pumpAndSettle()` alone raced the real file read once; added a
short real `Future.delayed` before the final pump. See
`test/ui/spell_card_widget_test.dart`.

**Pre-existing, unrelated flakiness noted in passing:** `test/spells/
inscribe_test.dart`'s "second inscription reuses the on-disk SRS cache" test
can blow its fixed 30s per-test timeout when `flutter test` runs multiple
proving test files concurrently (default concurrency) — three real
UltraHonk proofs run back-to-back with growing RSS (1.3 GB → 2.2 GB →
2.8 GB+), and under CPU contention the third can miss the deadline. Confirmed
via `git stash` that this reproduces on the pre-P1 codebase too (not caused
by this work) and disappears entirely with `--concurrency=1`. Not fixed here
— flagging since it'll bite the next person who runs the full suite by
default.

## Practice Mode — floor was too loose on-device, not just drift-inflated (2026-07-10, fourth follow-up)

First real-device (Pixel, good mic, quiet room) pass exposed the floor
problem directly rather than as a slow plateau: the formula completed the
instant capture started, before any word was spoken -- too fast to even
read the live quality number. This is the same root cause flagged as
"still unresolved" in the previous entry (synthetic noise settling at
~10.6 against the bounded window, uncomfortably close to
`kDefaultCheckpointFloor = 11.0`), now confirmed as the actual bug rather
than a synthetic-test artifact: **11.0 doesn't discriminate real speech
from near-silence/ambient audio at all.**

Likely trigger mechanics: Android's mic backend appears to deliver a
larger first buffered chunk than Linux's `parecord`-piped stream did, so
the very first `acceptPcmChunk` call processes many frames of
mostly-pre-speech ambient audio in one synchronous burst (the per-frame
evaluation loop can cross multiple segments within a single call — see
`acceptPcmChunk`). On Linux's finer-grained delivery the same underlying
looseness only ever showed up as a slow plateau (the 8-8.5 real-voice
numbers, themselves gathered before the windowing-drift fix and so already
suspect); on Android's chunkier delivery it's severe enough to cascade
through the entire formula in one callback.

**Fix:** dropped `kDefaultCheckpointFloor` from 11.0 to 7.0 — real margin
below the ~10.6 noise baseline. The 8.0-8.5 real-voice data point that
justified 11.0 is now explicitly treated as stale in the code comment;
using it again to justify the next number would be repeating the same
mistake. Confirmed `flutter test`/`flutter analyze` still clean at 7.0 (no
constant-dependent test assertions — see the "explicit strict test-only
floor" note in the previous entry).

**Not yet confirmed:** whether 7.0 lets genuine correct speech complete on
this device at all, or is now too strict given the disruption of removing the
drift crutch. That's the next real-device data point, not something
resolved in this session — and this time, get it with the live quality
readout actually visible (the previous device's completion was too fast to
read a number; watch for whether that's still true at 7.0, since if it is,
the "floor too loose" diagnosis may not be the whole story and the large-
initial-chunk hypothesis itself needs checking, e.g. via a debug log of
chunk sizes as they arrive on Android).

## Practice Mode — unbounded query window let ANY sustained sound eventually pass (2026-07-09, third follow-up)

While chasing why real speech plateaued around 8-8.5 (previous entry),
built a synthetic stress test feeding pure random noise against a toy
reference and watching `currentNormalizedQuality` over time via the new
live-diagnostic getters, rather than trusting real-mic sessions to
localize it. Result was a real, previously-invisible bug: **quality drifted
downward over time from ~12 to ~9.8 purely from feeding more (still
random, still wrong) audio** — meaning if a player just kept making any
sound at all long enough, the checkpoint would eventually cross regardless
of content. This directly breaks the "anti-gabble is emergent" design
requirement (mumbling/wrong content must never complete, full stop).

**Root cause:** `_evaluateCurrentSegment` compared "every query frame since
this segment started" against the fixed-length reference via corner-
anchored DTW (both endpoints forced). As query length grows far past the
reference's length, most of the excess collapses onto repeated reference
columns, and cost/steps asymptotically approaches the reference's own
*typical* nearest-neighbour distance — a property of the reference's scale,
not of whether the query matches it. This is a known failure mode of
naively-unbounded online DTW; real online-DTW/score-following
implementations bound the comparison to a sliding window for exactly this
reason, which this design had not done.

**Fix:** capped the comparison window to the most recent `2x` the
segment's reference length (`_evaluateCurrentSegment`'s `windowCap`), not
"everything since the segment started." This is a sliding window, not a
timeout — there is still no limit on how long the pointer may stall; it
just can no longer coast to a pass purely from elapsed wrong audio. `2x`
was chosen because the "identical audio" test independently showed a
genuine match converges to near-zero cost by roughly that point.

**Still unresolved:** even with the bounded window, synthetic noise against
the toy sine-sweep reference used in unit tests settles at a steady-state
quality (~10.6) close to the real-voice range (8-8.5) that had prompted
`kDefaultCheckpointFloor = 11.0`. This might mean CMN + a short reference
genuinely leaves too little dynamic range to separate "correct" from
"wrong" — or it might mean a synthetic sine-sweep reference (extremely
regular, unlike real speech's formant structure) is simply not a
representative stand-in for real word templates and shouldn't be trusted
as a proxy for calibration decisions either way. Split the difference: the
unit test asserting rejection now uses an explicit, deliberately strict
test-only floor (3.0) to verify the mechanism works, decoupled from
whatever `kDefaultCheckpointFloor`'s real value should be — that's now
clearly a real-data question, not a synthetic-test question.

**Next real step, not done in this session:** re-test with a real voice
now that the drift bug is fixed (the previous 8-8.5 plateau may itself have
been partly drift-inflated, so that data point should be treated as stale),
AND get a real *wrong-word* attempt's quality number (e.g. deliberately
saying "terra" against an "aqua" target) — calibrating the floor needs both
a real correct-case and a real incorrect-case number to know if there's
enough separation between them, not just the correct-case number gathered
so far.

## Practice Mode — cepstral mean normalization added after real-voice calibration data (2026-07-09, second follow-up)

After the c0-drop fix (below), Soren's real voice against the Piper
reference "couldn't get under 9" on the live quality readout (floor is
6.0) — a real, hard number, not a hang. A quality stuck a few points above
the floor (not wildly high) is the signature of a *systematic* per-
coefficient offset (mic/room/vocal-tract-length differences between a real
voice and Piper's studio-quality render), not random mismatch — the standard
fix for that in speech processing is cepstral mean normalization (CMN):
subtract each segment's own per-coefficient mean from its frames before
comparing, so a roughly-constant bias cancels on both sides while the
frame-to-frame pattern (the actual phonetic content) survives.

**First attempt broke a unit test, and rightly so.** Applying CMN naively
made the "audio that never matches the reference" test start reporting a
false match. Root cause: that test's reference fixture was all-zero silence
— every frame literally identical, zero internal variance. Mean-centering a
set of identical frames zeroes them out completely, wiping out the one
thing CMN is supposed to preserve. This could have been a real design flaw
(CMN destroying signal at phoneme-checkpoint granularity generally) or a
test-fixture artifact (degenerate-by-construction silence reference) —
checked empirically against an actual generated template
(`assets/practice_templates/aqua.json`) before deciding: even a 10-frame
slice of real reference audio has meaningful per-coefficient stddev (1-3,
not 0). Silence was never representative of real word references. Fixed
the test fixture (a frequency sweep, not silence/a steady tone) rather than
reverting the feature — see `_chirpPcm` in
`test/practice/streaming_phoneme_scorer_test.dart`.

**Second empirical surprise while fixing the test:** matching audio only
converges to a clean (near-zero) DTW cost once *more* than one
reference-length of matching content has been fed — feeding exactly one
reference-length's worth left quality still measurably above zero. The
corner-anchored DTW alignment needs some slack (more query frames than
reference frames) to fully resolve minor across-computation numerical
differences even for literally-identical underlying signal content. Not
itself a bug, just a real property of this design worth knowing before
tuning `kDefaultDebounceFrames`/expecting instant convergence.

Also added `StreamingPhonemeScorer.floor`/`currentNormalizedQuality`
getters and a live "quality: X / floor: Y" readout in `PracticeScreen`,
specifically so the floor can keep being calibrated against real voices
with real numbers rather than guessed at blind — this is what surfaced the
"9" data point in the first place. **Still open:** whether CMN closes
enough of the gap on Soren's actual voice, or whether the floor also needs
raising, is unconfirmed — next step is another real-mic pass with this
build.

## Practice Mode — first real-mic pass found two live bugs (2026-07-09, same day follow-up)

First `flutter run -d linux` pass (device-testing note from the entry below
is now partially resolved) surfaced two real bugs the unit tests couldn't
catch because they only ever used synthetic all-zero-PCM "speech":

1. **`_startCapture` had no error handling.** A failure inside it (permission
   check or `record`'s `startStream` throwing) died completely silently —
   the Start button's press ripple would show and nothing else would ever
   happen, no error, no snackbar, nothing in the UI. Root cause turned out to
   be environmental (missing `ffmpeg`/`pulseaudio-utils` on the test
   machine — `record_linux` shells out to `parecord`/`ffmpeg` rather than
   using a native binding; its actual plugin `.cc` file is a no-op stub,
   all real capture logic is in Dart via `Process.start`), but the real fix
   is structural: wrapped the whole body in try/catch, surfacing failures
   via SnackBar + `debugPrint`. Any future capture-path failure (on any
   platform) will now be visible instead of silent.

2. **The DTW distance included MFCC coefficient c0 (log-energy/loudness).**
   Once capture actually started, the pointer never advanced past word 1
   against real speech, despite passing every unit test. c0 encodes overall
   loudness, not phonetic shape — so a real mic recording at some arbitrary
   gain/distance, compared against Piper's fixed studio-quality render, would
   inflate the DTW distance for reasons that have nothing to do with
   pronunciation. This is a known pitfall in DTW-based pronunciation scoring
   (c0 is conventionally dropped for exactly this reason) that the unit
   tests couldn't surface, because they fed literally-identical synthetic
   audio as both "reference" and "query" — identical audio matches at any
   loudness, including with c0 included, so the bug was invisible until
   real, differently-recorded audio was used. Fixed by dropping index 0 from
   every MFCC frame before any distance comparison in
   `streaming_phoneme_scorer.dart` (`_dropC0`/`_dropC0All`), applied
   symmetrically to both reference and query frames. Confirmed one of the
   existing unit tests (the "audio that never matches" stall test) had
   accidentally been testing loudness-invariance rather than content-
   mismatch — a differently-loud *constant* signal produces ~zero AC content
   regardless of amplitude (same as silence), so once c0 is excluded it
   spuriously "passes" as a match. Replaced with a genuine tone (non-constant
   waveform) as the mismatch case.

Also added a live diagnostic readout to `PracticeScreen` (current
normalized quality vs. the floor, shown while capturing) specifically so
`kDefaultCheckpointFloor`/`kDefaultDebounceFrames` can be calibrated against
real voices with real numbers, rather than guessed at again. **Still open:**
neither constant has been tuned against an actual human voice yet — that's
the next real-device step, not done in this session.

## Practice Mode (vocal, Phase 1) — scoring architecture and asset pipeline (2026-07-09)

Built on `feature/practice-mode`, branched from `origin/feature/ink-substrate`
(not `main` — `main` predates the entire sorcerer/battle/menu codebase; see
"main is far behind ink-substrate" below). Pure client scaffolding under
`lib/practice/` + `lib/ui/practice_screen.dart`; does not touch the circuit,
proving, commitments, lockstep, or networking.

### `finis` renamed to `finitus`

`VocalWord.finis` (`lib/sorcerer/vocal_score.dart`) is now `VocalWord.finitus`,
per Soren's explicit decision. Grep-confirmed zero wire-format impact (the
wire encoding is 3 quantised score bytes, never the word enum itself) and
only 3 total references repo-wide before the rename (the enum value plus two
comments in `sherpa_vocal_scorer.dart`) — safe, contained change.

### Sherpa-ONNX cannot satisfy the no-static-window requirement even once integrated

`lib/sorcerer/sherpa_vocal_scorer.dart` was already an explicit
"NOT YET INTEGRATED" stub, but its own integration checklist targets a
**KWS (keyword-spotter)** model — whole-keyword confidence, not streaming
per-phoneme/forced-alignment output. Real Sorcerer-mode casting itself is
also static-window today (`battle_screen.dart`'s `_onCast`: fixed
`Future.delayed(_voiceCaptureWindow)` then whole-utterance MFCC+DTW). Neither
existing nor planned infrastructure could have supported Practice Mode's
rate-invariant, no-fixed-window pointer model — this was a real architectural
gap, not a corner we cut.

### Chosen fallback: checkpoint-based online DTW, not a phoneme classifier

`lib/practice/streaming_phoneme_scorer.dart` reuses the existing
`lib/sorcerer/mfcc.dart` MFCC/DTW machinery rather than standing up a trained
acoustic model. Each word's reference audio is sliced into "checkpoint"
segments (a coarse duration-weighted heuristic over `LatinPhonemes`'
hardcoded phoneme table, **not** true forced-alignment boundaries — see that
file's header). A pointer advances checkpoint-by-checkpoint; on every new
~10ms MFCC frame, a fresh corner-anchored DTW runs between "all query frames
since the last checkpoint crossed" and that checkpoint's reference slice
(`DtwMatcher.distanceWithSteps`, added alongside the existing `distance()` —
additive, doesn't touch real Sorcerer-mode's call path).

**Length-normalized floor, the load-bearing fix:** the checkpoint-clear
condition is `cost / steps` (cost-per-DTW-step), not raw accumulated cost.
Raw cost is a running sum that grows with path length even for a perfect
match (more frames → more nonnegative terms), so a fixed threshold on raw
cost would force slower speech to match tighter per frame than fast speech
just to clear the same bar — exactly backwards for a "fast and slow clean
casts score identically" requirement. Dividing by step count removes that
bias. `test/sorcerer/mfcc_dtw_steps_test.dart` proves this directly: raw cost
triples when the same content is stretched 3x, cost/steps stays close.
Debounce (`kDefaultDebounceFrames`, currently 4) requires this to hold for
several consecutive frames — a real hysteresis, not a listening window; there
is no timeout anywhere in the scorer, so a floor that's never cleared simply
stalls the pointer forever (this **is** the anti-gabble mechanism, not a
separate check).

**What made this non-trivial to express:** the natural per-call granularity
(evaluate once per `acceptPcmChunk` call) would have made the debounce
duration depend on the host platform's audio-stream chunk size rather than
elapsed audio time — a real bug I caught via the unit tests, not by
inspection. Fixed by evaluating one new MFCC frame at a time inside
`acceptPcmChunk`'s loop, so `_framesClear` counts actual ~10ms frames
regardless of how many frames a single chunk delivers.

### Template-source shape: single Piper voice now, swappable by design

`lib/practice/vocal_template_source.dart` defines `VocalTemplateSource`
(one method, `templateFor(VocalWord)`) with `SingleVoiceTemplateSource` as
the only implementation shipped. Per Soren's decision: Piper (not a human
recording) is the reference speaker, chosen for reproducibility — a Piper
render is deterministic and regenerable as a build artifact keyed to the
voice model version (`it_IT-paola-medium`, sha256 pinned in
`scripts/generate_practice_assets.dart`), unlike a one-off human take.
`MultiVoiceTemplateSource` (average several Piper voices to dilute
speaker-timbre bias) and `PerUserEnrolledTemplateSource` (record the
player's own voice) are documented as deferred fast-follows in that file's
header, not built. **Known limitation, accepted for this playtest:** MFCC
encodes timbre/vocal-tract length, which DTW doesn't correct for, so a single
voice is still speaker-dependent — but it's an *impartial* bias (not tuned to
any one player), which is the bar for a first friends-playtest, not for
ship.

### One Piper render feeds both the trainer clip and the scoring template

`scripts/generate_practice_assets.dart` renders each word exactly once
through Piper's Italian voice; the same output is copied verbatim to
`assets/audio/practice/<word>.wav` (playback) and separately resampled
22050→16000 Hz + run through `MfccExtractor.extract()` to produce
`assets/practice_templates/<word>.json` (scoring). No second render, no
phoneme-driven pass distinct from the trainer audio — per Soren's explicit
requirement that what the player hears and what they're scored against can't
silently diverge.

### `ignis`/`finitus` G2P verified empirically, not assumed

Ran the actual `espeak-ng` binary bundled inside the Piper release (not a
guess) before writing `lib/practice/latin_phonemes.dart`:
```
ignis   -> ˈiɲɲis    (gn palatalizes+geminates, as the design brief predicted)
aer     -> aˈɛr
aqua    -> ˈakwa
terra   -> tˈɛrɾa     (rr -> geminate trill+tap)
finitus -> finˈitʊs   (Italian /ʊ/ on the un-Italian "-us" ending, not /u/)
```
No spelling workarounds were needed — Italian orthographic rules already
produce the intended targets for all 5 words. The phoneme table is a
hardcoded 5-entry lookup (the vocabulary is closed), not a general G2P
engine.

### Piper toolchain (not committed to the repo)

No root/apt access in this dev environment (`sudo` requires a password,
`pip`/`ensurepip` both absent). Used the self-contained Piper release
instead of system packages:
- Piper 2023.11.14-2, `piper_linux_x86_64.tar.gz` from
  `github.com/rhasspy/piper` releases — bundles its own `espeak-ng` +
  `onnxruntime`, no system install needed. Installed to `~/.piper/piper-bin/`
  (persistent, not `/tmp` — `/tmp/nargo` already taught this lesson once).
- Voice: `rhasspy/piper-voices` `it_IT-paola-medium` (medium quality; the
  other Italian voice, `riccardo`, is x_low only). Installed to
  `~/.piper/voices/`. sha256 of the `.onnx` pinned in
  `scripts/generate_practice_assets.dart` (`6fc918b5...c04210c`) so a re-fetch
  can be verified byte-identical.
- No `ffmpeg`/`sox` available either (no apt access) — the 22050→16000 Hz
  resample in `scripts/generate_practice_assets.dart` is a small
  hand-written linear-interpolation resampler. Adequate for MFCC feature
  extraction on short offline-generated clips; not used anywhere at runtime.

### `main` is far behind `feature/ink-substrate` — branch bases need care

Asked to branch off `main` for decoupling from ink-substrate's in-flight
work; discovered `main` predates the *entire* current game (`lib/sorcerer/`,
`lib/battle/`, `MenuScreen`, the current `formula.dart` — 146 files / ~28k
lines of diff) — it's the old crypto-core-only milestone. Branched off
`origin/feature/ink-substrate` instead (last pushed commit — has everything
Practice Mode depends on, excludes only the uncommitted local WIP). **If
"branch off main" comes up again before ink-substrate merges, check this
first** — the ask is almost always "decouple from uncommitted work," not
"decouple from everything built since the crypto-core milestone."

### Not device-tested this pass

Everything above is `flutter analyze` clean and covered by
`flutter test test/practice/ test/sorcerer/mfcc_dtw_steps_test.dart` (21/21
pass) plus a full-suite regression run (pre-existing SRS-network-download
and temp-dir-race flakes only, none touching Practice Mode files). Per the
verification hierarchy, "it compiles"/unit tests are not the top of the
ladder — a real-device or at least `flutter run -d linux` interactive pass
(mic permission prompt, real audio playback, live checkpoint highlighting)
was handed to Soren to run manually rather than automated in this session.
**Do not call Phase 1 done until that pass happens.**

## Mod-system seam orientation — deferred-feature findings (2026-07-05)

Orientation pass for a possible future mod system (player-toggleable formula
length 3/4/5, community-defined effect tables for longer patterns, an
ordered per-player mod-precedence stack). No code was written — the feature
stays documented-but-unbuilt, deferred until popular demand. Two findings
below matter independent of whether it ever ships; the third corrects a
type-level bug in the seam proposal itself before anyone builds against it.

### Latent exploit: mana cost is coupled to formula count, not just activation count

`_certifiedManaCost` (`lib/battle/engine/turn_loop.dart:1529`) computes
`effectCount` from `certFormulas.length`, i.e. `1.5^(effectCount-1)` scales
with how many complete formula-groups a trajectory produces. At the current
fixed formula length (3) this is an inert, faithful proxy for activation
count. It becomes a live, exploitable cost difference the moment formula
length is player-toggleable: the same trajectory (e.g. 9 committed
activations) would cost `1.5^2` at length 3 vs `1.5^0` at length 5 — same
work, cosmetic toggle producing a real cost delta.

**Fix, when the length toggle is built:** pin the cost divisor to a fixed
accounting constant (`BASE_FORMULA_LENGTH = 3`), independent of the
player's chosen display length —
`cost = 1.5^(floor(committed.length / BASE_FORMULA_LENGTH) - 1)` always. The
length toggle regroups the trajectory for effect lookup and display only,
never for cost accounting. This preserves all existing tests byte-for-byte;
do not switch to raw `committed.length` as the divisor, since that's a
different curve shape and silently rebalances existing length-3 play.

**This fix must land inside the same change as the length toggle, never as
a follow-up** — pre-toggle it's dormant, but shipping the toggle without it
arms a real exploit on day one.

### The v1-committed signed match record does not exist yet

Per `runewright_design_v3_0.md` ("Signed Match Records", `[APPLIED — ships
in v1]`), the match-record format is supposed to reserve three fields now,
even though Talewright itself is post-ship: **N signers** (not a hardcoded
pair — same trap as ruleset versioning), **embedded match config** (custom
HP, loadouts, grid size, toggle set), and an **optional stakes-hash**
(pre-committed, both-signed statement of what the outcome means; empty for
ordinary duels).

Orientation for the mod-system pass found no such struct in the codebase.
The only implemented Ed25519-signed struct is `SpellPermission`
(`lib/spells/spell_permission.dart`) — a loan/permission grant with no
config field — and `docs/BATTLE_PROTOCOL.md` §6 has only a stubbed per-turn
state-hash signature (`// TODO(battle)`).

**When this record is built** (for stakes/Talewright or any other reason),
reserve these additional fields in its config bundle at the same time, per
the same cheap-now/expensive-retrofit logic that motivated the original
three: `modStackHash` (nullable, absent = no mods active), `rulesetVersion`,
`tierMax`.

**No action needed now** — do not create this struct solely to hold these
fields. This is a note for whoever builds the v1 record next, whatever
motivates that work.

### Correction to the mod-manifest seam proposal: coverage-set element type

The mod-system orientation proposal (chat-only, not yet written to any
file) sketched `ModManifest.coverage: Map<int, Set<List<BorderZone>>>`.
That has a latent bug worth fixing in the design, not the code — nothing is
built yet: `Set<List<BorderZone>>` uses identity equality on a raw `List`,
so two structurally-equal patterns would be treated as distinct set
members, and coverage checks would silently misclassify.

Whatever immutable `Pattern` wrapper (value equality + `hashCode`) gets
introduced for the resolver's map key (the `resolvePattern` seam) must also
be the element type in the manifest's coverage sets — one wrapper type, not
two ad hoc solutions to the same problem. Recording this here since it's
the only standing note on the mod-system seams; a future implementer should
read this section before building `ModManifest` or the resolver.

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

---

## 2026-07-28 — Somatic gesture: real corpus calibration (SORC.5)

First real IMU corpus captured on the Pixel 6 via practice_screen's Gesture
tab: 10 reps each of fire/air/water/earth/melee plus idle/walk/garbage
confusables, now committed at `test/sorcerer/fixtures/corpus_pixel6/`. Pulled
with `adb shell run-as com.runeduel.rune_duel cat
app_flutter/gesture_enrollment/<name>.json`.

### The corpus was fine. The constants were the bug.

Leave-one-out nearest-neighbour ranking is **100% correct for all 50 gesture
reps** under nearly every representation tried. The five chosen motions are
genuinely separable — no choreography change was needed.

What failed was the shipped `GestureClassifier` default constants
(`energyFloor 0.02`, `distanceCap 4.0`, `marginThreshold 0.5`) applied to
**raw** IMU frames. Over the real corpus those defaults produce:

```
  9x  confusable_idle -> fire   <<< FALSE ACCEPT
 10x  confusable_walk -> fire   <<< FALSE ACCEPT
  4x  melee -> neutral (missed)
  2x  air   -> neutral (missed)
```

Two independent scale errors:

1. **`energyFloor` was ~400x too low.** Real idle sits at mean-square energy
   0.04–7.76, not below 0.02, so the stillness gate never fired and a still
   hand reached DTW at all.
2. **Raw DTW distance is amplitude-dominated, and fire is the quietest
   gesture** (E≈25, vs air 390, melee 1100). So near-zero motion lands nearest
   to fire: idle→fire distance 1.80 vs fire→fire 1.75. Meanwhile cap 4.0 sat
   *below* air's (4.16) and melee's (3.80) natural within-class distances, so
   those two were rejected outright.

### Fix: normalise before matching

`normalizeForMatching()` (imu_sample.dart) — smooth over 5 frames, multiply
the gyro block by `kGyroBalance = 4.0`, then scale the rep to unit RMS.
Applied to **both** query and every template rep at classify time, so stored
enrollment JSON stays raw and reprocessable.

The gyro boost is not a fudge: this device's gyro magnitudes run ~1/4 of its
accel magnitudes, so after a single global normalisation the accelerometer
dominates the Euclidean cost and drowns the rotation signature that actually
separates the gestures. Sweeping the factor moved held-out false accepts 2→0.

New constants: `energyFloor 8.0`, `distanceCap 0.80`, `marginThreshold 0.15`.
Genuine reps span 0.21–0.86 in normalised space; the closest impostor
(theatrical garbage) sits near 0.90. **Bias the cap down, never up** — a
rejected genuine gesture is a cast without enhancement, but a false accept
applies the wrong one.

### Things that did NOT work — don't re-try

- **Rotation-invariant features** (`[|a|, |g|, a·g, |a×g|]`). These are what
  would neutralise grip-orientation differences between people, and they keep
  100% top-1 ranking — but confident-accept rate collapses to 40% (4% without
  normalisation). Too much signal discarded.
- **Raw magnitudes only** (`[|a|, |g|]`): 4% accept.
- **Fixed-length resampling**: no gain over plain unit-RMS. DTW is already
  time-warp invariant, which was the original design call and it holds.
- **Smoothing alone**, without normalisation: makes things *worse* (50%
  accept) — it sharpens the amplitude domination rather than removing it.

### Handedness comes free — mirroring is an exact isometry

Reflecting across the sagittal plane is `ax→−ax, gy→−gy, gz→−gz` (acceleration
is a true vector so only the mirrored axis flips; **angular velocity is a
pseudovector** and picks up an extra sign, so the *other* two flip). Getting
this backwards yields a physically impossible motion that still plots
plausibly — the classic IMU-mirroring bug.

Because that is a signed permutation, it is orthogonal, so it commutes with
smoothing, per-channel scaling, unit-RMS and DTW. Measured worst
`|d(a,b) − d(mirror a, mirror b)|` = **0.00e+0**. A mirrored template set
therefore reproduces right-handed accuracy bit for bit — **one capture covers
both hands, no recapture, no recalibration**. `mirrorFrames`/`mirrorSamples`
in imu_sample.dart; guarded by tests in gesture_confusion_e2e_test.dart.

The gestures are strongly chiral (mean self-vs-mirror distance 1.20–1.61, far
outside the cap), so a handedness mismatch degrades to `neutral` — never to a
wrong gesture. That negative case is now a test.

### Generalization: promising, not proven

Enrolling only reps 0–4 and testing reps 5–9 (a real style shift — later reps
run ~40% slower) gives **100% top-1, 100% accept, 0 false accepts**. Speed and
amplitude variation are handled.

But that probe cannot test the dominant cross-person variable, **grip
orientation**, which is a rigid rotation of the device frame. The features
that would survive it are the rotation-invariant ones that measured poorly
above. The vocal precedent is a warning: same-voice 5/5 vs cross-voice 2/5
(2026-07-16 entry). **Universal bundled templates remain unvalidated until
2–3 other people are captured** (~10 min each).

Mitigating: universality **fails safe**. Wrong-gesture confusion never occurred
once in 50 reps, so a stranger's rendition falling outside the cap yields
"no enhancement", not "wrong enhancement". Frustrating, never exploitable.

### Streaming feedback is viable (basis for the haptic trainer)

Running prefix alignment cost (own class vs best competing class), sampled
through the gesture:

```
gesture        @25%          @50%          @75%         @100%
fire        1.17 / 1.54   1.10 / 1.66   1.06 / 1.74   1.13 / 1.85
air         0.62 / 0.79   0.77 / 1.21   0.80 / 1.57   0.72 / 1.47
water       0.38 / 0.68   0.62 / 1.30   0.73 / 1.47   0.79 / 1.49
earth       0.40 / 0.46   0.60 / 0.97   0.66 / 1.29   0.75 / 1.51
melee       0.28 / 0.39   0.51 / 1.03   0.60 / 1.45   0.53 / 1.31
```

Separation exists from ~25% in and widens monotonically, so a haptic that
builds as the player commits correctly and fades as they drift has a real
signal to drive — no faking needed. Cost is ~1500 DP cells per frame at 55 Hz,
trivially inside the latency budget. Reuse `DtwMatcher.distanceWithSteps` and
mirror `StreamingPhonemeScorer`'s structure.

**Choreography note: fire is the least self-consistent gesture** (own-class
cost 1.06–1.17 vs 0.28–0.80 for the others). See the correction below — this
is structural, not a performance problem.

### Correction: fire is a tremor, and DTW is the wrong matcher for it

Fire's intended choreography is **phone held mostly still, hand shaking** —
"having trouble containing the energy". That is a *stochastic texture*, not a
trajectory: successive shake cycles have arbitrary phase, so there is no
repeatable path to time-align. DTW pays a large cost for a perfectly good
performance. **Re-recording it cannot help** — an earlier note in this
document suggesting that was wrong. This also explains fire's two anomalies:
lowest energy of any gesture (~25) *and* highest own-class DTW cost.

Per-gesture crispness (mean own-class distance / mean nearest-other-class
distance; higher = tighter, better isolated cluster):

```
transform                  fire      air    water    earth    melee
gyroX4+unitRms (shipped)   1.83     2.11     2.35     2.27     2.54
traj+spec concat (w=1.0)   1.87     1.42     1.42     1.38     1.56
spec2 (|a|,|g| bands)      2.26     1.37     1.32     1.44     1.35
```

Fire is best matched **spectrally** (1.83 → 2.26); the other four are best
matched by **trajectory DTW** (2.1–2.5, collapsing to ~1.35 under spectral).
Concatenating both into one sequence is worse than either specialist — it
dilutes the trajectory signal without meaningfully helping fire. There is no
single representation that wins for both, and that is a property of the
gestures, not a tuning failure.

**Resolution — do not change the cast-time classifier.** Fire at 1.83 works:
all 10 reps accept, zero false accepts, and the e2e gate passes. The tremor
design costs ~25% margin versus the trajectory gestures, which is a price, not
a failure.

**But use a spectral matcher for fire in the TRAINER.** Training is
single-class verification (the target gesture is known), so a per-gesture
representation costs nothing there — the scale-comparability problem that
would break a mixed-representation *classifier* simply does not arise. And a
tremor is arguably the *easiest* gesture to give streaming feedback on: its
identity is a stable instantaneous property (shake rate + intensity) rather
than a path you must complete, so the haptic can say "you're there, hold it"
continuously. Closer to sustaining a musical note than to executing a dance
step.

**Watch the stillness gate on fire.** "Mostly still" is in direct tension with
`energyFloor = 8.0`: fire's weakest recorded rep is 13.75, only 1.7x above the
floor — the tightest margin of any gesture. A player shaking too gently will
be stillness-gated and see nothing happen. Mitigations, in order of
preference: (a) have the trainer coach intensity; (b) make the gate spectral
rather than pure energy — low-energy *high-frequency* is a tremor, low-energy
*low-frequency* is genuine stillness, and the band energies distinguish them
for free. Verify (b) against `confusable_idle` before relying on it.

### Traps found

- **The device samples at ~55 Hz, not the 100 Hz**
  `SensorsGestureCapture._samplingPeriod` requests. Never assume the requested
  rate; `impliedSampleRateHz` records the real one and reps store it.
- `earth[3]` is a clipped capture (0.92 s vs ~1.5 s for its siblings) — the
  single worst rep in the corpus, from releasing the button early.
- Synthetic fixtures at amplitude 3.0 sit at energy ~4.9, **below the energy
  of a real human gesture** (weakest recorded rep: 13.75). Fixtures written
  before a gate is calibrated will silently fall on the wrong side of it once
  it is.

### Tooling

`tool/gesture_corpus_analysis.dart <corpus_dir>` — offline bench (not a test).
Prints the representation sweep, held-out threshold cross-validation, the
operating curve (accept% and first-false-accept per cap), the handedness
study, the generalization probe, and the streaming-feedback study. **Re-run it
after any feature or constant change**; do not hand-tune one constant in
isolation.

---

## 2026-07-28 — Battle scenery: generated hex-terrain backdrop

Soren added the CC0 **Screaming Brain Studios "Realistic Hex Tiles"** pack under
`assets/art/` (gitignored, like every raw art source). Each battle now draws a
generated terrain backdrop beneath the battlefield, on the *same* hex grid, so
playable tiles sit squarely on their terrain and the landscape runs out past the
edge of the field.

**Purely cosmetic.** Scenery never touches movement, line of sight, targeting,
or any hashed/committed state. `lib/battle/models/terrain.dart` (`TileEffect`)
is the real terrain system and is unrelated; the new code lives under
`lib/ui/scenery/` and every file says so in its header.

### Decisions (Soren, 2026-07-28)

- **One aligned map**, not a separate decorative backdrop — battlefield hexes
  coincide with terrain hexes.
- **Bonus sheet (18 tiles)**, but **only ground you could walk on**: lava,
  cooling magma and both waters are excluded. They stay in the enum and in the
  shipped atlas (they cost nothing and a hazard feature may want them).

### Sheet geometry — measured, not assumed

Both sheets in the pack use the same top-face geometry. The Bonus sheet is
768x432, 6x3 cells of 128x144:

- Top face is a **flat-top hex 128 wide x 128 tall** at rows 0..127 — i.e.
  stretched vertically by 2/sqrt(3) versus a regular hex.
- Rows 128..143 are a **16px straight-down extrusion**, which overlaps the tile
  behind it. Tiles must be drawn **back to front** or the depth reads wrong.
- Tiling step: dx = 96, dy = 128, odd-column y-offset 64.

The painter reproduces `BattlefieldPainter.hexToPixel` exactly via a single
canvas transform (`sx = 2*hexSize/128`, `sy = sqrt(3)*hexSize/128`) rather than
per-tile maths — the 0.866 vertical squash is invisible on a texture.

### Asset pipeline

`scripts/build_hex_terrain.py` -> `assets/art_pack/terrain/hex_terrain_atlas.png`
(+ `ATTRIBUTION.md`), same raw-source/derived-output split as
`build_art_pack.py`. It does three things the runtime should not:

1. Keys out the source's hard **teal `#008080`** (the Flat/Thick sheets use
   magenta `#ff00ff`) into a real alpha channel — the source PNGs are RGB with
   no alpha and cannot be drawn as-is.
2. **Rebuilds edge alpha analytically** as 8x8 supersampled coverage of the
   known silhouette polygon. The source key is hard-edged, which reads as
   jaggies once scaled; complementary coverage on shared edges also means
   adjacent tiles composite seam-free.
3. **Bleeds RGB outward** into the transparent margin, or bilinear filtering
   pulls the key colour in as a halo.

### How "logical transitions" are actually guaranteed

Terrain is never chosen per tile. Two fBm value-noise fields (elevation,
moisture) -> quantile banding into 5x5 bands -> a **Lipschitz-1 clamp** over the
hex adjacency graph -> a hand-authored 5x5 biome ladder. The clamp is the
load-bearing step: it computes the largest field <= the banded one in which
adjacent hexes never differ by more than one band, so every adjacency lands
inside a 3x3 window of the ladder, and the ladder is authored so every such
window is a plausible pair. **No post-hoc fixups.** `sceneryAdjacencyIsLegal`
derives the legal relation from the ladder itself (so it cannot drift), and
`test/ui/scenery_map_test.dart` checks every adjacency of every map across all
7 regions x 12 seeds.

Determinism: seeded from the duel's shared `matchId` via SHA-256, so both
devices render the same landscape without exchanging a byte. Solo play takes
local entropy. 32-bit-masked integer hashing throughout, IEEE-754 +,-,* only.

### Three things only *looking at it* caught

All the unit tests were green before any of these were found. This is the
verification-hierarchy point, again.

- **Quantiles over the whole disc put a snowfield in a meadow.** Band
  thresholds computed over the full generated map are globally correct but say
  nothing about the arena, which is a small fraction of it — so "Verdant Downs"
  legitimately rendered an alpine battlefield with its meadows out of frame.
  Fix: `focusRadius` (the battlefield radius) — thresholds come from the arena's
  cells, applied everywhere. Extremes now sit past the edge, which is also the
  better picture: near meadow, distant peaks.
- **Linear area-scaling of feature clusters made a plaza.** Paving covered
  9-14% of tiles and clusters merged into one slab. Fix: sqrt area scaling plus
  a minimum separation of 4 hexes between clusters of the same kind -> 3-7%.
- **Snow/rime are far brighter than anything else in the atlas** and fight the
  game pieces for attention even at 5%. The temperate presets now carry **zero
  weight in the top elevation band**; regions that should look cold say so.

### Traps

- `dart format` destroys a lookup table's grid layout, which for the biome
  ladder *is* the documentation. It sits in a `// dart format off` block with
  short aliases; keep it that way.
- `flutter_test` hangs on `instantiateImageCodec` / `Picture.toImage` under the
  default fake-async zone. The preview renderer wraps its body in
  `tester.runAsync`. (First attempt burned a 600s timeout on this.)
- A missing/corrupt atlas must never take the battle down — the load is
  try/caught and the painter treats a null image as "draw nothing".

### Tooling

`test/ui/scenery_render_preview_test.dart` is a **tuning loop, not an assertion
test**: with `SCENERY_PREVIEW_DIR` set it renders one PNG per region plus a seed
sweep through the real painter and the real atlas; without it, it is a no-op.
Every defect listed above came from that renderer. Re-run it after touching any
region weight, ladder cell, or dimming constant.

### Follow-up (same day): the terrain was invisible inside the grid

Soren: *"I wanted the tiling to occur inside the battle grid, while still
keeping the cells easily identifiable."*

`BattlefieldPainter._drawTile` filled every playable hex with an **opaque**
checkerboard (`_kTileLight`/`_kTileDark`), so the scenery only ever showed
*outside* the playable radius. The geometry was right all along — the grids
coincided exactly — but the board was painted straight over the terrain.

**This is the second time in one feature that a green test suite said nothing
about the actual requirement.** The scenery previews looked correct because
they rendered the backdrop *alone*; nothing composited `BattlefieldPainter` on
top until it was asked for explicitly. The preview harness now draws the
composite, which is the only view that answers the real question.

Fix — `BattlefieldPainter.terrainBeneath` (default `false`, so the original
opaque stone board is exactly what still renders if the atlas fails to load):

- Playable tiles become a **wash** (~12% warm / ~15% cool) instead of a fill.
  Both parities need a wash; tinting only one reads as "some tiles are
  highlighted" rather than as a checkerboard.
- The tile rim becomes a **light line over a dark halo** (2.6px `_kEdgeHalo`
  then 1.0px `_kEdgeLine`). A single 1px border vanishes wherever the terrain
  matches its luminance — the old dark edge is fine on snow and invisible on
  pinewood. The two-tone rim is what actually keeps cells countable, and it is
  now doing most of the work the checkerboard used to do.
- Scenery's `_kInnerBrightness` 0.62 → 0.82, `_kInnerSaturation` 0.88 → 0.96.
  The old values were tuned with nothing on top; once the wash and rim were
  added the arena went muddy. **Tune these against the composite only.**

`test/ui/battlefield_terrain_beneath_test.dart` asserts pixels — deliberately,
unlike the neighbouring crash-smoke test. It probes cell centres (terrain shows
through / the default board still hides it / adjacent parities differ) and a
shared edge (a rim is actually drawn). The original bug was invisible to every
non-pixel test, so a pixel probe is the regression guard.

### Follow-up 2 (same day): snow, rime and ice removed

Soren: *"there's some blue watery or snowy tiles still, they seem out of
place, lets remove them."*

`snow`, `frost` and `ice` dropped out of `SceneryTile.walkable`, joining lava
and open water as excluded. They stay in the enum and in the shipped atlas — a
seasonal or hazard feature may want them — but nothing draws them. Taken as one
family: they are a single visual group, and keeping snow while dropping the
blue ones would have looked stranger than either.

Consequences worth knowing, because this was not a one-line change:

- **The ladder lost its top tier.** The elevation axis now tops out at bare
  `chalk` crag, and the crest row is uniformly chalk — above the treeline there
  is only rock, whatever the moisture. Highland became
  `sand / chalk / chalk / pine / pine`, which puts the treeline transition
  (crag thinning into pinewood) where the rime band used to be.
- **`frostcapRidge` became `stonecrest` ('Stonecrest').** A region named for
  frost that cannot contain any is worse than no preset. It was also
  re-weighted damper than `chalkHills`, so its crags stand out of pinewood
  rather than out of sand — otherwise the two collapse into the same look.
- **The feature avoid-rule had to be re-earned.** `avoidNeighbours` was
  `{snow, ice, frost}` for both features, which became vacuous. Rather than
  keep dead machinery it is now `{mossSoil}`: you do not pave a bog, and
  waterlogged ground does not carry a fire. The corresponding test is
  meaningful again instead of trivially green.
- `mossSoil` left the ruins substrate set for the same reason (it cannot be
  both a substrate and something to avoid).

New test `the excluded tiles never appear on any map` checks the exclusion
directly and asserts `walkable` itself has not been widened back — the older
`isWalkable` test would happily pass if someone re-added a tile to the set.
The palette is now temperate throughout: clay, earth, mire, sand, dry grass,
scrub, grass, pinewood, chalk, plus paving and burn scars.

---

## 2026-07-29 — Sluggish resolution order: the hang hypothesis, and the real fix

Reported symptom: "targeted myself with the sluggish debuff, then my game
froze." The proposed cause was a wait — sluggish means you resolve last, so if
nobody else casts you sit waiting for a caster who never comes.

### That mechanism does not exist — checked, not assumed

`isSluggish` occurs in exactly two places in the whole tree: the getter on
`WizardAvatar`, and the `_ResolutionGroup group()` closure inside
`TurnLoop._resolveActions`. It is a **sort key and nothing else**. No exchange,
Completer, or `await` anywhere in `turn_loop.dart` or `battle_screen.dart` is
gated on cast order; every `session.exchange*` call is unconditional and
symmetric per turn, so the number and order of frames cannot diverge because of
a status effect.

Reproduced negatively, three ways, all green before any change:

1. Solo (`SoloBattleSession`): sluggish local avatar casts, dummy passes.
2. Solo: self-cast the real sluggish formula (`['earth','fire','air']` — Earthen
   Energy Flows) at own tile, then four more turns of casting while sluggish.
   `_prepareForHit` returns `false` for a self-hit, so self-targeting is a
   normal, supported path.
3. Two-client lockstep (`TurnSessionPair`): sluggish caster vs. passing peer —
   canonical state identical on both clients, no deadlock.

So whatever froze the app, it was not this. If it recurs, the thing to capture
is whether the phase banner was stuck on "Resolution" (⇒ `_isBusy` stuck true
⇒ `runTurn` never returned ⇒ a genuine LAN exchange desync, most likely one
client having thrown mid-turn and stopped exchanging) or whether a fullscreen
spell card was up (⇒ the reveal sequence).

### What was actually wrong, and is now fixed

Sluggish/Quick were being applied as *absolute* groups, so they ranked a cast
against Pass/Dash/Meditate too. The design doc (§Effect Table, Fire-Air) says
"resolve last **unless others are also sluggish**" — i.e. it is a ranking among
the casts. `_resolveActions` now computes `allCastsSluggish` / `allCastsQuick`
over the casts resolving this turn and collapses the group to normal when every
caster shares the modifier. The single-caster case falls out of it: the lone
caster is trivially "all of them", so a sluggish wizard casting alone resolves
at the front instead of behind the opponent's Pass.

Deliberate detail: the caster set counts `SpellCastAction` only. A
`MysterySpellCastAction` still standing at resolution is the *delayed* variant
(`_verifyMysteryAction` has already rewritten the immediate one), so it stashes
a `PendingDelayedSpell` rather than resolving and must not count as "another
cast". Delayed spells actually firing this turn arrive as `SpellCastAction`s via
`delayedFires` and do count.

### Latent lockstep landmine, found on the way and closed

The sort comparator returned `0` whenever either side was not a spell — so a
cast vs. a Pass, or two Passes, compared equal. `pairs` is built local-actor
first, and Dart's sort is stable at these sizes, which means **the two clients
stably sorted equal elements into different orders**. It never diverged
canonical state because nothing Pass/Dash/Meditate does is order-sensitive, and
the state-hash exchange therefore never caught it. The collapse rule above makes
ties strictly more common, so the comparator now falls back to `playerId` and is
a total order.

New `test/battle/engine/resolution_order_test.dart` pins all of it over two
concurrent loops. To get there, the `_TurnSessionPair` fixture was lifted out of
`turn_loop_determinism_test.dart` into `test/battle/engine/turn_session_pair.dart`
so any engine test needing real two-client lockstep can use it.

One thing that test *cannot* assert: the lone-caster ordering itself.
`lastResolvedSpells` only carries casts, so with one cast there is no order to
observe — and since non-cast actions are order-insensitive, the collapse changes
no canonical state today. It is the rule that is now right; the two-caster cases
are what pin it.

---

## 2026-07-29 (same day) — "state hash mismatch on turn N": the mana ledger split in two

Follow-up from the same two-device session. The banner that flashed by was
`Turn error: Bad state: state hash mismatch on turn 3: local=… peer=…` —
`TurnLoop._exchangeStateHash`. That is the lockstep tripwire doing its job:
both devices hash `BattleState.toCanonicalBytes()` and compare, so the message
means the two devices' *battle state genuinely diverged*, not that the network
glitched. Every field in the canonical encoding is explicitly sorted, so
ordering is never the cause — a real value differed.

### The value that differed: the caster's mana

Two structurally different paths charge for the same cast, by design:

| device | path | base |
|---|---|---|
| caster | `_deductManaForCommittedSpell` → `_spellManaCost` | `SpellAsset.manaCost`, baked at inscribe time |
| opponent | `_verifyPeerSpellCast` → `_certifiedManaCost` | recomputed from the proof's public outputs |

Both then apply chain / efficiency / sorcerer / `nextSpellCostDouble` in the
same order — that part was already audited (B-1/B-8). The **base** was not.
The two effectCount formulas are different functions:

```
inscribe (main.dart) : effectCount = max(0, (activations - 1) ~/ 3)
certified            : effectCount = max(0, completeFormulas - 1)
                                   = max(0, activations ~/ 3 - 1)
```

They agree only when the activation count is an exact multiple of 3. On any
residual they differ by one, i.e. a **1.5x cost gap on the very same cast**:

| activations | wire | certified | |
|---|---|---|---|
| 3 | 0 | 0 | agree |
| 4 | 1 | 0 | **diverge** |
| 6 | 1 | 1 | agree |
| 7 | 2 | 1 | **diverge** |

Measured on the repro (segmentCount 3, dotCount 2): 4 activations → caster
charged itself 31, opponent charged it 21. `avatar.mana` differs → state hash
differs → both devices throw and forfeit. Turn 3 is simply the first turn
someone cast a residual-activation spell.

The gap was *known and written down* — there is a `NOTE(B-1, balance)` on
`_certifiedManaCost` describing it exactly — but it was filed as a balance
difference. It is not: neither device ever applies the other's number, so it is
a lockstep divergence. **Any time two code paths compute a value that lands in
`toCanonicalBytes()`, "they disagree" is a desync, never a balance note.**

### Fix

`_spellManaCost` no longer reads `SpellAsset.manaCost`. New `_wireBaseManaCost`
recomputes the base as the exact local mirror of `_certifiedBaseManaCost` —
same inputs, same operations, same order — using `_parsedFormulas(spell).length`
for the effect count. That is the same triplet grouping `TrajectoryParser`
performs on the certified trajectory, so the two land on the same integer for
an honest spell. A dishonest one still loses: the opponent charges the certified
amount regardless, and the state hash catches the difference.

The certified count is the one that had to win — it is the trust boundary, and
the wire count was exploitable by padding the formula list.

`main.dart`'s inscribe handler was corrected to the same rule, so the card no
longer advertises a price the duel doesn't charge. **Spells inscribed before
this still carry the old inflated `manaCost` in their asset file** — harmless
for play (nothing reads it to charge any more) but the library card will read
~1.5x high for a residual-activation spell until it's re-inscribed.

### Why it presented as a freeze, not an error

Worth knowing for the next desync: when one device throws mid-turn it stops
exchanging, and the other device blocks forever on its next
`session.exchange*`. In the app that is `_isBusy` stuck true — the phase banner
frozen on "Resolution", no input accepted. The device that *threw* shows a
4-second snackbar and then looks fine. So "one device froze, the other seemed
OK" is the signature of a mid-turn throw, and the snackbar on the *other* phone
is where the real message is. `mana_cost_lockstep_test.dart` reproduces this
shape exactly: without `eagerError: true`, `Future.wait` just hangs.

### Tests

`test/battle/engine/mana_cost_lockstep_test.dart` — two concurrent loops, one
real cast, asserting **both devices agree on the caster's remaining mana** and
canonical state matches. Covers 3 (was already fine), 4 and 7 activations. It
fails loudly on the pre-fix engine.

`chain_discount_test.dart`'s fixture had to change with it: it used
`manaCost: 1000` as "the base price", which no longer feeds the engine. It now
encodes the price the way the engine reads it (`t: 0`, `dotCount: manaCost`).
The one factor that can't be neutralised is `1.5^(formulas-1)`, which is now
intrinsic — so the hybrid spell's full price is 1.5x the pure one's, and that
test asserts against `_fullPrice(hybrid)` rather than a hard-coded 1000.

---

## 2026-07-29 (same day) — DEV FLAG: proofless spells accepted in a real duel

**This is temporary. `lib/dev_flags.dart` must be deleted before release, along
with every `DEV FLAG` comment that references it.**

Spell Test Lab spells never run through the circuit, so `proofBytes` is empty,
`_appendSpellProofTail` sends no tail, and the opponent's device forfeits on
`missing_spell_proof`. Correct behaviour, but it makes two-device effect testing
impossible — and several effects (reflections, counter-charms, scrying, anything
needing a real opponent) can't be exercised in solo practice at all. So
`kAllowProoflessSpells` waves the empty-proof case through.

Scope is deliberately narrow: a spell that *does* carry proof bytes is still
fully verified — proof, commitment binding, duplicate-grid detection,
enhancement claims, cast authorization, Merkle membership. There is a test
pinning that (`proofless_spell_flag_test.dart`, "a spell that DOES carry a
proof is still fully verified"), because a bypass that quietly widened into
"skip verification" is the failure mode worth guarding.

### The non-obvious part: an unverified cast has to be FREE

The first cut charged the peer via `_spellManaCost` on the wire `SpellAsset`,
to mirror what the caster deducted. It desynced immediately, and the reason is
worth writing down:

**The 0x01 action encoding carries commitment, T, target and formula — no
segmentCount/dotCount.** It never needed them: the verifying device reads
geometry from the *proof's* public outputs. Strip the proof and the opponent
has no geometry at all, so it prices a base of 0 while the caster prices from
its local asset file. `avatar.mana` diverges and `_exchangeStateHash` forfeits
at the end of that same turn — the bypass would have swapped a clean forfeit
for the "state hash mismatch on turn N" freeze it existed to avoid.

Options were (a) put geometry on the wire, or (b) charge nothing on both sides.
(b) won: (a) means changing a committed-and-revealed wire format, keeping
`SoloBattleSession._encodeDummySpellCast` in sync with it, and adding untrusted
data to the action — a lot of blast radius for a flag we intend to delete.

Free costs little in practice: `SpellTestLabScreen._persistTestSpell` already
writes `manaCost: 0, segmentCount: 0, dotCount: 0`, so these spells priced at
zero anyway. The real loss is that a test spell no longer consumes a pending
`nextSpellCostDouble` / `chainSurcharge` — that consumption lives inside
`_spellManaCost`. To exercise those, make the *follow-up* cast a real proven
spell. Chain building is unaffected (`_updateChainState` runs during
resolution, not costing).

**General lesson, third time today:** the wire format and the proof outputs are
two different sources for the same facts, and the code assumed the proof would
always be there to fill the gap. Any bypass of the proof path has to ask "what
did this path read out of the proof that nothing else provides?" — for mana
that was the geometry.

### Also true, and not fixed

- The peer's **draw state doesn't advance** for a proofless cast (no Merkle
  proof to say which chapter slot was spent). Draw state isn't in
  `toCanonicalBytes`, so it can't desync the match, but the opponent's view of
  the caster's hand drifts and scrying a test-spell hand reads stale.
- Effects resolve from `_parsedFormulas(spell)` — the wire formula — on both
  devices, via the `certFormulas ?? …` fallback at the `TODO(B-1)`. Same source
  both sides, so no desync, but it means **closing that TODO requires removing
  this flag first**. They are the same hole.

### Refactor that came with it

`_deductManaForCommittedSpell`'s inline enhancement-building switch became
`_castingEnhancementsFor(action)`, shared by every site that prices a cast.
Mana lands in the state hash, so two copies of that switch is a desync waiting
to happen — the same shape as the effectCount bug earlier today.

### Both devices must build with the same value

If one has the flag and the other doesn't, the strict device forfeits the first
time a test spell is cast. `BattleScreen` shows a permanent red
**⚠ UNVERIFIED PLAY** banner whenever the flag is on and the session is a real
duel — partly so no result from such a match is mistaken for real, partly so a
glance at both phones confirms they match. Do not remove that banner while the
flag exists.

### Removal checklist

1. Delete `lib/dev_flags.dart`.
2. `grep -rn "DEV FLAG\|kAllowProoflessSpells\|allowProoflessSpells" lib/ test/` —
   remove the `TurnLoop.allowProoflessSpells` parameter, the `_isProoflessBypass`
   helper and its call in `_deductManaForCommittedSpell`, the bypass branch in
   `_verifyPeerSpellCast`, the `_UnverifiedPlayBanner` widget and its call site.
3. Delete `test/battle/engine/proofless_spell_flag_test.dart`.
4. Purge the `[TEST] ` spells (Library → test-spell list) so nothing proofless
   remains castable.

---

## 2026-07-30 — Measured: bb's UltraHonk prover is NOT byte-deterministic

Run while evaluating whether the Wild Magic seed hash could be taken over the
**proof bytes** instead of the proof's public inputs (`docs/WILD_MAGIC_PLAN.md`
§4.1). The appeal: a grinder searching for wild-magic trigger patterns would
have to generate a real proof per candidate (seconds + ~700 MB) instead of just
running the stepper (microseconds). That only works if a given witness maps to a
stable proof — so it was worth measuring rather than assuming.

### Result

**Three proofs of the same witness produce three different byte strings.** Both
on a toy circuit and on the real `ca_v2_4_tier12`:

```
$ bb prove -b ca_v2_4_tier12.json -w ca_v2_4_tier12.gz -k vk_t12/vk   # ×3
d50feb43…  t12_1/proof     ← all three differ
2e2f1941…  t12_2/proof
f3296ced…  t12_3/proof

ef2ed006…  t12_1/public_inputs   ← all three IDENTICAL
ef2ed006…  t12_2/public_inputs
ef2ed006…  t12_3/public_inputs
```

**Public inputs are byte-stable; only the proof body varies.** Expected — the
public inputs are a function of the statement, the randomness lives in the body.

### The source is the ZK blinding, confirmed directly

`bb` exposes ZK and no-ZK verifier targets. Same circuit, same witness:

| `-t` target | 2 runs identical? |
|---|---|
| `noir-recursive` (poseidon2, **ZK**) | **no** |
| `noir-recursive-no-zk` (poseidon2, no ZK) | **yes** — byte-identical |

### The app cannot opt out, and must not want to

`noir_rs`'s `settings_ultra_honk_poseidon2()` (the settings
`prove_ultra_honk` uses — `ffi/src/api/prover.rs:506`) hardcodes:

```rust
ProofSystemSettings { oracle_hash_type: "poseidon2", disable_zk: false, … }
```

Note the asymmetry in that crate: `prove_ultra_honk_keccak` takes a `disable_zk`
parameter, `prove_ultra_honk` (the poseidon2 path we use) does **not**. Turning
ZK off would mean forking `noir_rs` — and is categorically off the table anyway,
since ZK is exactly what stops a proof leaking the grid, and the secret grid is
the entire game.

### Consequences (recorded so this isn't re-derived)

1. **Proof bytes are not a safe consensus input** for anything that must be a
   stable property of a spell. `spellHashHex = Poseidon2(commitment, T)` is
   identical across re-proofs, so the save-time dedupe key cannot even
   distinguish them.
2. **Cast-time proof substitution is live, not theoretical.** `BookCommitment`
   leaves are `commitmentHex` only (`book_commitment.dart:10`), so K
   independently-generated proofs of one grid all verify, all match the
   commitment check in `_verifyPeerSpellCast`, and all satisfy the *same* Merkle
   path. Any future feature deriving anything from proof bytes must first bind
   the proof into the chapter leaf.
3. **Re-proving is cheap:** ~4.0–4.3 s wall, ~690 MB peak for tier-12 on this
   12-thread desktop (vs the 8.9 s / 717 MB Pixel 6 figure from the M2 spike).

### Toolchain note

`/tmp/nargo` was gone again (reboot, as CLAUDE.md warns). Not needed —
`circuits/*/target/*.json` (compiled circuit) and `*.gz` (witness) were already
committed, and `bb write_vk` + `bb prove` run straight off them. `bb write_vk`
on tier-12 takes ~1.9 s, so a determinism re-check costs under a minute.

---

## 2026-07-30 — Cloud desync report: engine cleared, cause is a one-sided turn abort

Report from a two-device duel (Spell Test Lab spells, so the proofless dev-flag
path): **(1)** a Water-Fire cloud was drawn only on the caster's device;
**(2)** the player standing in that cloud had no adjacent-only cast
restriction. Follow-up answers pinned down that both symptoms were on the *same*
device — the one that could not see the cloud — which means that device's
`BattleState.clouds` was empty, not that its renderer dropped a cloud it had.

### What was ruled out (don't re-tread this)

Four throwaway reproductions, all green:

1. **Proofless path, two real `TurnLoop`s over `TurnSessionPair`.** Caster and
   peer each end the turn with 1 cloud and the *same* cloud id
   (`player_a_cl_foxs04` on both — `EffectApplicator._uid` draws from the shared
   `HashRng`, so ids are consensus data, not device-local).
2. **Same, with a 5-leaf chapter** so `_appendSpellProofTail` emits a real
   multi-level Merkle path rather than the degenerate single-leaf one. No
   decode divergence.
3. **Certified path**, driven by synthetic proof bytes assembled to
   `proof_intake.dart`'s wire format (`dominance_trajectory = [fire, water,
   fire]` → `FormulaTracker` → one `(fire, water, fire)` triplet → clouds). The
   peer resolves from `TrajectoryParser`, the caster from the wire formula, and
   they agree.
4. **UI, non-caster's device**: real `BattleScreen` + `SoloBattleSession(
   dummyAutoCast: true, dummyCastFormula: ['fire','water','fire'])`, so the
   local device is *not* the caster. After resolution the painter has
   `clouds=1, hiddenCloudIds={}` — the reveal hold-back
   (`_playResolvedSpellSequence` → `_bloomSpellEffects`) clears correctly for a
   peer-cast effect. With the cloud dropped on the local player's own tile the
   painter gets `spellRangeRadius=1`, and `_onTapBattlefield`'s
   `_maxCastRange` gate rejects out-of-range taps.

Engine-side the restriction is enforced for *every* caster in
`_resolveActions` (`_cloudBoundToAdjacent`, turn_loop.dart), and a long-range
cast out of a cloud fizzles identically on both devices.

### Why "the cloud is missing on one device" is necessarily a turn abort

`BattleState.toCanonicalBytes()` serializes clouds (id, position,
remainingTurns, kind, radius), and `BattleSession.exchangeStateHash` is a real
exchange — so a cloud existing on only one device cannot survive to the end of
that turn: it forfeits with `state_hash_mismatch`. And a mismatch *throw*
happens after resolution, so it can't be what removed the cloud either.

That leaves one shape: **the losing device threw before `_resolveActions` ran**
— entropy/reveal verification, the scry or spell-reveal openings, or the
`_verifyPeerSpellCast` family — so it never applied the peer's cast at all,
while the caster's device applied it in full. Every one of those paths sends a
forfeit and throws; `_submitTurn` caught the throw, showed a 4-second snackbar,
and let play continue from a permanently diverged state. That is why the
symptom presents as a rendering bug several turns later.

Note for the proofless case specifically: `_verifyPeerSpellCast` returns early
on `allowProoflessSpells`, *before* membership/authorization/mana, so the
Test-Lab-spell path skips most of those throws — which makes a version skew
between the two devices (`kAllowProoflessSpells` off on one → instant
`missing_spell_proof` forfeit, exactly as `dev_flags.dart` warns) the first
thing to rule out.

### Change made

`battle_screen.dart`: a throw out of `runTurn` in a **real duel** now sets
`_turnError` and renders the blocking `_blockingError` screen (same fail-closed
doctrine as `_verifierInitError`), with the message selectable so it can be
read off the device. Solo/practice keeps the snackbar — a local throw there is
recoverable and desyncs nothing. Until this landed, every lockstep break in a
LAN duel was a 4-second toast.

---

## M4.x — Wild Magic implementation (2026-07-30)

Implements `docs/WILD_MAGIC_PLAN.md` in full: all three phases, all twelve
effects, the forced reveal-and-cast primitive, and the leyline seed word.
`RULESET_VERSION` deliberately **not** bumped (nothing about the CA, the
circuit, the grid, or the commitment changed — see the plan's §11).

### Traps paid for here, worth not paying twice

1. **`FormulaTracker` does not commit one activation per generation.** Three
   *consecutive* fire generations commit exactly ONE activation, not three:
   rule 1 only fires on a **lead change**, and rules 2/3 need supreme dominance
   or a cadence pulse (gen % 4 == 0). Any test fixture that wants N activations
   of one element has to interleave neutrals (`[1,0,1,0,1]`) so each is a fresh
   lead change, or set the supreme flags. The first draft of
   `wild_magic_resolution_test.dart` used `[1,1,1]`, got zero formulas, and
   therefore zero eligible elements and no wild magic at all — which looked
   exactly like a broken seed hash.

2. **`CreatureSpec` gives a creature `maxHp == the number of EARTH
   activations`.** A pure-fire summon spawns at 0 HP and is reaped the same
   turn by `_reapDead`. Pre-existing design, not a wild-magic bug, but it makes
   "pure fire" a bad default for any summon test fixture.

3. **The movement preview's output is re-walked as DECLARED STEPS.** Modelling
   ice sliding inside `Battlefield.resolveMovement` looked right — the preview
   is what arbitrates contested tiles, so it "should" know where sliders end
   up. But `MovementResult.paths` feeds straight back into
   `TurnLoop._walkAvatar` as the cleared path, so the slid-through tiles became
   declared steps and the avatar slid *back down its own slide*: enter (0,2),
   slide to (0,0), then "walk" the injected (0,1) step and slide to (0,2)
   again. **Reverted**: the preview arbitrates on the pre-slide destination and
   the real walk slides afterward. Costs a little arbitration accuracy on iced
   ground, costs nothing in lockstep (both clients run identical code on both
   halves, and the real walk's occupancy check stops a second slider short
   rather than stacking them). Anything that adds free movement to `_walkAvatar`
   in future faces the same trap.

4. **`FlutterSecureStorage` has no platform channel under `flutter test`.**
   Awaiting `Identity.loadCommunitySeed()` inside `SettingsScreen._load` left
   the whole screen on its spinner and broke an unrelated credits test with
   `pumpAndSettle timed out`. Any new identity read from a widget's `initState`
   must be loaded *separately* from whatever gates the first paint, and guarded
   (`try/catch`, or `.catchError` on the `.then`) — an unhandled rejection there
   fails whichever test happens to be running.

5. **A `const` map cannot be keyed by `HexCoord`** (it overrides `==`), so test
   fixtures want `{coord: const Tile()}`, not `const {coord: Tile()}`.

### Decisions taken during implementation, beyond the plan

- **`tileBlocksMovement(TileEffect?)` / `tileIsIndestructible(...)` in
  `terrain.dart`.** The plan's §8.2 says to grep `ImpassableTile` and touch
  every site deliberately. Rather than leave ~15 open-coded `is ImpassableTile`
  checks that a future tile variant would have to re-audit one by one, every
  MOVEMENT site now routes through one predicate, and the two
  TARGETING/line-of-sight sites (traversal damage stopping at a wall,
  `_spreadTiles`' wall-shadowed BFS) deliberately do **not** — that is exactly
  the chasm's "no bearing on targeting" rule, now expressed as one decision
  rather than fifteen.

- **`_resolveActions` and `_applySpell` are now `async`.** The plan flagged this
  (§9.5) as a possible prerequisite. It was: Spontaneous Combustion's reveal
  round trip has to land *after* wild magic fires and *before* the triggering
  spell's own formula effects, which is mid-`_applySpell`. The applicator stays
  synchronous and **queues** forced casts; `_applySpell` awaits
  `_drainForcedCasts` at exactly that seam.

- **Rippling Reflections' doubling wraps the FORMULA LOOP, not the method.**
  A7/invariant 7 says a doubled spell must not re-fire wild magic. Rather than
  passing `fireWildMagic: false` and trusting it, the `repeatWholeSpell` loop
  sits *inside* `_applySpell` around the formula iteration, so a doubled
  application structurally cannot reach the wild-magic seam or re-roll the coin.

- **Zephyr does not route landings through `resolveTileEntry`.** The plan (§8.4
  item 6) asked for a decision either way. Cascading conveyor pushes in entity
  order after a simultaneous board-wide teleport would make the final board
  depend on iteration order in a way that is much harder to keep in lockstep
  than the lost flavour is worth. A teleport onto a conveyor is pushed by
  `_endOfTurn`'s standing-on-a-conveyor sweep instead — same outcome, one phase
  later.

- **Mana Flood sets `mana = maxMana` directly** rather than going through
  `_applyManaGain`. The plan suggested the helper so the gain fires Reflections'
  `manaMirror` trigger; but an effect that already fills EVERY bar leaves a
  mirror nothing to add, and routing through the helper would double-count.

- **`MatchConfig.matches` compares the NORMALIZED seed**, so two duelists who
  typed `"Rivendell!"` and `"rivendell"` agree at the handshake exactly when
  their spells would hash identically. `normalizeCommunitySeed` therefore lives
  in the models layer (`wild_magic_effect.dart`) with `WildMagic` delegating to
  it — one implementation, since a second copy of that regex is a consensus bug.

- **Guest-side seed surfacing.** The LAN path is host-authoritative
  (DECISION 3), so a *mismatch* is structurally impossible: the guest adopts the
  host's word. What the guest gets instead is a notice when the host's tradition
  differs from their own — the plan's §7.5 intent, adapted to the protocol we
  actually have.

### Still outstanding

- **The two-device LAN pass has NOT been run.** Per CLAUDE.md's verification
  hierarchy this is required before Phase 3 is called done: a whole-match run
  where at least one wild-magic effect fires on each side and the per-turn state
  hashes agree throughout. Force a trigger with a dev-only seed word chosen to
  put `000` in a test spell's hash (the search takes seconds — see the fixture
  comments in `wild_magic_test.dart`).
- **Spontaneous Combustion has never crossed a real wire.** `forcedReveal`
  (0x43) is unit-tested through a fake host and exercised in solo (where it
  short-circuits to local-only), but the actual two-device reveal round trip is
  untested. It is also the one conditional (non-uniform) frame in the protocol,
  so it is the most likely place for a frame-sequence divergence.

**Late fix, worth knowing:** `_verifyPeerSpellCast` both **forfeits on** and
**deducts** the certified mana cost. Routing a forced reveal through it
unchanged would therefore have charged a player for a cast they never chose to
make — and, worse, forfeited the match against anyone who happened to be
holding a spell they couldn't afford. The mana block is now skipped under
`forcedCast: true`, alongside the duplicate-grid guard. Any future caller of
that method for a cast the player did not choose needs the same treatment:
the checks it runs assume a *voluntary* cast.

---

## 2026-07-30 — Core gem removed: the mana pool is innate

**The change.** The "core gem" — a mandatory, indestructible first Mana Gem that
`accoutrementsFromArtifacts` silently prepended to every loadout — is gone. Its only real job
was making sure a wizard had a mana pool at all, and it did that by charging an artifact slot
and then carving a hole in the burn rules to protect it. The pool is now intrinsic:
`MatchConfig.innateManaPool` (default 100), with gems as pure optional capacity on top.

Soren's ruling on the two open questions: **gems stay** (+100 pool / +10 regen each, unchanged),
and **regen stays gem-only** — the innate pool has *no* passive regeneration. A gemless wizard
refills by meditating (+25/phase, +50/turn, already implemented). Capacity is free; throughput
is bought with gems or with your turn.

**Two things this touched that were not obvious from the request:**

1. **`maxMana` is stored state, not a derivation** — and it is hashed into
   `toCanonicalBytes()`. Burning a gem removed the accoutrement but never lowered the pool.
   That staleness was *reachable before this change* (any non-core gem could be burned), but
   the core gem made it look benign. With every gem burnable it becomes a live desync source
   the moment two clients disagree about a clamp. Fixed via `EffectApplicator._syncMaxMana`,
   which recomputes and re-clamps; every add/remove gem path now goes through it. Note this is
   also §6.2 of `ARTIFACT_SYSTEM_PLAN.md` — that plan's gem *activation* must reuse the same
   helper rather than open-coding `maxMana -= 100`.

2. **`kBattleProtocolVersion` 1 → 2 is load-bearing here.** Removing the `isCoreGem` byte
   changes the state-hash encoding, and `MatchConfig` gained a negotiated field. The nasty part
   is the config: a v1 peer simply *omits* `innateManaPool`, so `fromJson` fills in our default
   and **config agreement passes** — then the peer derives a different `maxMana` and hashes an
   extra byte per accoutrement, desyncing on the first state-hash exchange. Field-by-field
   config agreement does not protect you from a peer that never sends the field. The version
   gate is what catches this class, so bump it whenever `toCanonicalBytes` or the negotiated
   `MatchConfig` shape moves.

**Also worth knowing:** `WizardAvatar.maxManaFromGems`/`manaRegenPerTurn` hardcoded 100/10 while
`MatchConfig` carried the same numbers as knobs — two sources of truth that happened to agree at
defaults. They are now `maxManaFor(config)` / `manaRegenFor(config)`, so the knobs are real.

Coverage: `test/battle/models/innate_mana_pool_test.dart` (gemless pool, gem stacking, gem-only
regen, no inserted core gem, burn taking the last gem and shrinking the pool). Full suite: 987
green.

---

## 2026-07-30 — Wizards walk instead of teleporting; sprite seam added

**The change.** Movement used to be applied silently: `_resolveAvatarMovement` wrote
`av.position` and the next repaint drew the token on its new tile. Wizards now slide along the
tiles they actually walked, and a contested-tile collision plays as both wizards reaching for
the tile with the loser shoved back off it. Wizard tokens are also now character sprites rather
than coloured discs, behind a seam built for the avatar picker and the walk-cycle work that
come later.

**The one design decision worth remembering: the walk is time-normalised, not speed-normalised.**
Every wizard's route takes the same 72% of the timeline no matter how many tiles it covers, so
two colliding wizards arrive on the contested tile on the *same frame*. That simultaneity is
the entire reason the collision reads as a collision. It is tempting to make a Dash cover
ground visibly faster — don't: speed is already expressed by *who wins the tile*, and staggering
the arrivals turns a shoulder-check into two unrelated moves. (`wizardWalkStateAt`, extracted
top-level and public precisely so this timeline is testable on its own.)

**Three non-obvious things this touched.**

1. **`resolveMovement` knew who bounced but not off what.** `MovementResult.bounced` is a bare
   set of playerIds, which is enough to *apply* a collision and useless for *showing* one — no
   tile, no winner, so a speed win is indistinguishable from the loser choosing to stop short.
   Added `MovementResult.contests` (tile + contestants + winner, recorded as the fixed-point
   loop settles each one). It is strictly additive and UI-only; `bounced`/`paths` are untouched,
   so nothing consensus-visible moved. A player pushed back repeatedly appears in several
   contests and the UI lunges them at the **first** one — the tile they visibly reached
   furthest for.

2. **Clearing the animation is load-bearing, not tidiness.** Movement is Phase 3; knockback,
   Zephyr and ice all displace the same wizards in Phase 4+. While `avatarMoveAnimations` is
   non-empty the painter draws those wizards from the animation instead of from `occupancy`, so
   a spent animation left in place would pin a knocked-back wizard to wherever the movement
   phase left them. `_playResolvedSpellSequence` clears it the instant playback ends, before
   any card resolves.

3. **A lunge has to be dropped when the walk didn't end next to the contested tile.** The
   arbitration preview deliberately ignores conveyors and ice, so the real walk can carry a
   collision loser somewhere unrelated afterwards. Recoiling onto a tile they are nowhere near
   renders as a teleport-and-snap-back, i.e. exactly the bug this feature exists to remove.
   `_moveEventFor` drops the lunge unless `hexDistance(path.last, lunge) == 1`.

**Sprite seam.** `scripts/build_avatar_pack.py` → `assets/art_pack/avatars/avatar_atlas.png` +
a generated `lib/ui/avatars/avatar_catalog.g.dart`. Raw sheets stay gitignored under
`assets/art/`, same convention as the painterly and terrain packs. Notes for whoever picks up
the picker:

- **Row order is RPG Maker 2000's — up, right, down, left — not RPG Maker XP's Down/Left/Right/Up.**
  Verified against the art (row 2 is the only row with a face; rows 1 and 3 are mirrors), not
  assumed from the format's reputation. Column order is step / **stand** / step.
- **The teal colour key is only valid inside the 72×128 walk block.** Several sheets use the
  same teal as a real art colour in the portrait region to the right of it, so keying the whole
  sheet punches holes in the artwork.
- **`AvatarAssignment` is a pure function of playerId today, and that is a feature.** Both
  devices independently derive the same sprite for the same wizard with nothing on the wire.
  When the picker lands, a locally-stored choice is invisible to the peer, so the chosen id has
  to travel in the handshake and be installed via `AvatarAssignment.explicit` on **both**
  devices. Getting this wrong doesn't fail loudly — each player just sees a different board.
- **CC BY 3.0 requires attribution** (unlike the CC0 terrain pack, credited nowhere because it
  needs no credit). `CREDITS.md`, the in-app credits screen, and a test asserting the screen
  still says it. The downloaded archive shipped no licence file — `[CONFIRM — Soren]` flags in
  `CREDITS.md` and `assets/art_pack/avatars/ATTRIBUTION.md` ask for the listing's exact terms
  before a public build.

Coverage: `test/battle/models/movement_collision_test.dart` (contest reporting),
`test/battle/engine/avatar_move_events_test.dart` (route recording, conveyor tail, lunge and
the adjacency guard, all through a real `runTurn`),
`test/ui/wizard_movement_animation_test.dart` (the timeline, plus the painter pass and the
sprite seam). `test/ui/wizard_movement_preview_test.dart` renders the collision filmstrip and a
facing sheet to PNG under `WIZARD_PREVIEW_DIR` — same "looked at it" harness as the scenery
previews, and how the sprite scale and lunge reach were tuned.

**Not done:** no real-device pass yet. This is pure rendering over an existing turn, so the LAN
risk is low, but per the verification hierarchy it isn't finished until it has been seen on
hardware in a two-device duel.

---

## M4.x — Artifact system rework (Phase 0 activation) — 2026-07-31

Built from `docs/ARTIFACT_SYSTEM_PLAN.md` in the plan's six-step order. Every loadout
artifact is now **passive + one consumable activation**, at most one per player per turn,
declared in a new public **Phase 0** commit-reveal ahead of the Phase 1 action commit.
No CA / circuit / golden-vector surface was touched, so **no `RULESET_VERSION` bump** — but
the battle wire protocol and `BattleState.toCanonicalBytes()` both changed, which is its own
compatibility break (old and new clients cannot duel).

### The melee RNG ordering bug was real, and this feature is what made it matter

`§6.1`'s prediction held exactly. The melee round applied haymakers **local-first**, so device
A ran A-then-B while device B ran B-then-A — off the *same* shared `meleeRng`. It had never
been caught because `_applyHaymaker` only touched that stream via `_redirectIfIllusion`, which
early-returns without drawing unless the victim holds decoys. So a divergence needed *both*
players to melee in the same turn *and* an illusion in play.

The counter-charm melee proc makes **every** melee draw from that stream, so any two-melee turn
would have desynced. Fixed first, on its own, by sorting the applications by `playerId` — the
same convention `_findCounteringCharm` already used.

**Worth writing down:** the regression test
(`turn_loop_determinism_test.dart`, "two melees into illusions stay in lockstep") was verified
to *fail before the fix and pass after* by temporarily reverting the source, not just by
observing green. A determinism test that has never been seen red is not evidence of anything —
`player_a` sorts before `player_b`, so device A's local-first order and the sorted order are
identical, and only the B-perspective loop diverges. Half the fixture proves nothing on its own.

### What surprised us

- **`_endOfTurn` had no access to `entropy`.** Both new end-of-turn draws (the rod movement roll
  under tag `0x0A`, the bookmark redraw under `0x09`) need `_playerPhaseSeed`, which needs
  entropy, and `_endOfTurn(preMovPos, rng)` only had the phase RNG. Threading `entropy` in as a
  third parameter was the honest fix; reaching for the `_turnEntropy` field would have worked
  and hidden the dependency.
- **The rod's `remainingTurns: 1` status must be added AFTER `tickStatusEffects`.** Added before
  it, the tick decrements it to 0 and sweeps it in the same breath — the bonus would silently
  never exist. The plan called this out and it was still the easiest thing to get wrong.
- **`_addStatus` replaces any effect of the same id**, so the rod passive could not reuse
  `StatusEffectId.speedUp` without clobbering a spell's speed buff (and vice versa). New id
  `rodMobility`, summed alongside speedUp/speedDown in `effectiveMoveSpeed`.
- **Phase 0 could not live inside `runTurn`.** The action commit is exchanged by `beginTurn()`,
  which the UI calls as soon as the player locks in an action — so a Phase 0 placed at the top
  of `runTurn` would run *after* the commit it is supposed to precede. It lives in
  `beginArtifactPhase()`, memoized like `_beginTurnFuture`, awaited at the top of
  `_beginTurnImpl`. Tests and solo mode get it transitively with no changes; the UI calls it
  explicitly and early so the peer's declaration is on screen *before* the player picks.
- **`cancelPendingTurn()` deliberately does NOT clear `_artifactPhaseFuture`.** By the time a
  turn is abandoned the Phase-0 frames have already crossed the wire and both devices have
  applied the declaration. Replaying it would send a second pair of frames the peer is not
  waiting for.
- **The turn-scoped flag lives on `WizardAvatar`, not in a `TurnLoop` map.** `§6.3` asked for it
  in the avatar record of `toCanonicalBytes()`, and `pendingFreeMoveBurst` is the existing
  precedent for turn-scoped state on the avatar. Cleared *after* `_exchangeStateHash()`, never
  before — it gates charm firing at Phase 5, so it is part of the state both devices must agree
  on for that turn.
- **`_redrawHand` and `DrawSchedule.redrawHand`/`SpellDraw.redrawHand` already existed** (wild
  magic's Scattered Gusts). §8.3's "needs `redrawHand`" was written before that landed; all the
  bookmark burn needed was an explicit target size (the burned slot is permanently gone) and a
  distinct phase-seed tag so the two redraw paths cannot collide on one turn.

### Trust boundary

One validation path (`_validateActivation`), called for the local declaration and the peer's
alike — the B-1/B-8 lesson, applied before there was a second path to remove. A declaration is
valid only if the kind is `manaGem`/`bookmark`/`rodOfSpreading`, the declarer holds one, and
they have not already declared this turn. Failure degrades to no-activation on both devices
rather than forfeiting: a desync here is indistinguishable from a stale client.

The wire names a **kind**, never an accoutrement id, and the engine consumes the owner's first
match by sorted id. That removes the whole class of "peer names an id it does not own" bug by
construction rather than by checking for it.

`_consumeRodOfSpreading` stays the single rod-consumption path; only its *input* moved (from an
action-commit flag to the Phase-0 declaration). A rod declared but never spent — no cast, a
fizzle, a counter — survives; what is wasted is the once-per-turn activation budget.

### Coverage

`test/battle/engine/artifact_activation_test.dart` (20 tests: round trip from both
perspectives, the four trust-boundary cases, gem pool/clamp/last-gem, the rod's guaranteed +1
at 10 rods, bookmark burn incl. burning the last one, and the melee proc incl. a clean fizzle),
plus the Phase-0 charm gate in `counter_charm_test.dart` and the melee-ordering regression in
`turn_loop_determinism_test.dart`. Every two-client test asserts
`toCanonicalBytes()` equality across swapped perspectives — that is the real assertion; the
per-artifact expectations are the readable half.

Probabilistic mechanics are pinned at their **saturating** ends (10 rods = 100%, 20 charms =
100%) so they assert without hard-coding the RNG stream.

**Not done: no two-device pass yet.** Phase 0 is a new network round trip, and per CLAUDE.md's
verification hierarchy a green suite is not sufficient evidence for a protocol change. This is
the release gate for the feature.

### Pre-existing breakage found (not ours, not fixed)

Two **untracked** files fail to compile against current APIs and are excluded from every run
above: `test/battle/engine/turn_loop_nplayer_test.dart` (references a `MeshBattleSession` that
does not exist in `lib/`) and `lib/battle/models/chapter_accoutrements.dart` (references
`Accoutrement(isCoreGem:)`, removed with the core gem, and `ArtifactKind.deflectionRod`,
repurposed for the Rod of Spreading). They are leftovers from another session's WIP; someone
should decide whether to finish or delete them.

### Cleanup backlog found while building this (not done, roughly priority-ordered)

1. **Two-device LAN pass on Phase 0** — the release gate for the artifact rework. New round
   trip + `toCanonicalBytes()` break; a green suite is not sufficient evidence.
2. **`TurnLoop.lastCounterCharmProcs` has no UI consumer yet.** The engine records every melee
   proc (attacker, victim, gem-destroyed vs spell-withered) and `battle_screen.dart` ignores
   it. Right now a gem just vanishes and a card just greys out with no explanation — exactly
   the "reads as a bug rather than a mechanic" failure the Phase-0 banners exist to avoid.
   Cheapest fix: a line in the resolution reveal sequence.
3. **Name the absorption totem.** Mechanically settled in code (identical to an Absorption
   Rod, summon-only, excluded from the passive/activation split); the effect table says
   "totem", the code says `deflectionTotem`, the design prose says "rod". **Soren picks one**,
   then the other two get renamed. No mechanic hangs on it.
4. **Three `[TODO — playtest]` numbers now live in the design doc** and are whiteboard values:
   5%/charm proc (12 charms = 60%), 10%/rod movement (10+ rods = guaranteed), and — the
   largest untested assumption in the rework — **whether artifact depletion ends matches too
   fast**. The whole artifact economy now trends toward zero and no match-length data accounts
   for that.
5. **Two untracked files don't compile against current `lib/`** and are excluded from every
   test run: `test/battle/engine/turn_loop_nplayer_test.dart` (`MeshBattleSession` has never
   existed in any commit) and `lib/battle/models/chapter_accoutrements.dart`
   (`Accoutrement(isCoreGem:)` removed in c8fd79d; `ArtifactKind.deflectionRod` repurposed for
   the Rod of Spreading). Another session's WIP — finish or delete. A third,
   `lib/battle/models/network_battle_setup.dart`, is untracked but compiles clean; it just
   needs a decision about whether it belongs in the branch.
6. ~~Pre-existing inconsistency in `_applyHaymaker`~~ — **fixed 2026-07-31**, alongside a
   requested behavior change: a melee punch redirected onto an illusion decoy now does
   *nothing else* (no teleport, no damage, no haymaker side effect — the decoy dies and that's
   it; `_redirectIfIllusion` used to also teleport the real wizard onto the decoy's tile). That
   change exposed exactly the bug flagged here: the Fire haymaker DoT block re-queries
   `_avatarsAt(targetTile)` by position, so without the teleport a redirected wizard would
   incorrectly take DoT stacks. Fixed by tracking redirected playerIds through `_applyHaymaker`
   and skipping them in the DoT sweep too. `EffectApplicator._resolveIllusionRedirect` (the
   formula-effect path) intentionally keeps its teleport — melee has no "spell chasing the
   illusion's last position" framing, so the two paths are now deliberately asymmetric, not
   accidentally duplicated. Covered by
   `test/battle/engine/illusion_melee_redirect_test.dart` — no test seam exists for
   `math.Random.secure()`-backed entropy, so it runs ~40 independent single-turn trials and
   asserts invariants against whichever branch (real hit vs. decoy hit) each trial actually
   took, rather than pinning the RNG. Verified to fail against the pre-fix teleport by
   reverting the source, same discipline as the melee-ordering regression test above.
7. **Housekeeping:** a stray `.claude/settings.local.json.tmp.1096781.*` temp file is sitting
   in the repo, and `stash@{0}` is a `WIP ink-substrate (resume here)` stash from a different
   branch that has been carried along untouched.
8. ~~`TurnLoop.lastCounterCharmProcs` has no UI consumer~~ — **still true**, but the sibling
   gap (a countered CAST had a red "COUNTERED" ribbon with no flash, per user request) is now
   fixed: `_FullscreenSpellCard` plays a double-pulse rubric-red flash
   (`_kCounteredFlashCurve`) on entry when `countered: true`, on top of the pre-existing static
   ribbon. Item 2 above (the melee proc's silent gem-vanish/card-grey) is unrelated and still
   open.
9. ~~Rod of Spreading terminology~~ — **swept 2026-07-31**. Every comment and doc-prose mention
   in `lib/` and `docs/runewright_design_v3_0.md` now reads "Rod of Wind" (the name already
   shown to players everywhere in the UI); `test/battle/engine/rod_of_spreading_test.dart` is
   renamed to `rod_of_wind_test.dart`. **The Dart identifiers are deliberately untouched** —
   `AccoutrementKind.rodOfSpreading` (battle state, serialized by ordinal — a rename would be
   safe) and `ArtifactKind.rodOfSpreading` (loadout selection, `accoutrement_loadout.dart` /
   `chapter_asset.dart`, **serialized by NAME to on-device storage** — a rename would orphan
   any already-saved loadout unless paired with a migration alias in `_kindFromName`). Renaming
   the identifiers is a real follow-up if wanted, but it's a different-shaped task (data
   migration, not terminology) from what was asked here.
10. **Artifact activation UX + timing rework, 2026-07-31** — see `ARTIFACT_SYSTEM_PLAN.md` §13
    for the full writeup; this is the "what tripped us up" half.
    - **Confirmed the forced-modal removal doesn't need to touch the wire protocol at all.**
      `beginArtifactPhase()`'s doc comment already anticipated an "implicit" call path (run
      lazily from `beginTurn()` instead of eagerly at turn start) and explicitly said fairness
      holds either way — that turned out to be exactly the escape hatch needed. The UI change
      is real (long-press replaces a blocking prompt) but it's pure UI-trigger-timing; Phase 0
      itself, its commit-reveal shape, and its position ahead of `actionCommit` are unchanged.
    - **The actual hard part was Rod's movement passive**, not the UI. It used to be rolled at
      end-of-turn N specifically because movement commits (Phase 2) before the turn's main
      entropy is revealed (Phase 3) — a deliberate anti-lookahead property (B-5), not
      incidental. Making the roll usable the SAME turn it's decided is only safe because it
      draws from a *second*, independently-committed entropy source
      (`BattleTurnSession.refreshEntropy`) that is never mixed into anything look-ahead
      sensitive. Nearly reached for reusing the main entropy early instead — would have quietly
      reopened the B-5 hole for a bonus round of "SpellDraw can go stale mid-turn"-flavored
      analysis before catching it; reusing the already-wired-but-unused refresh seam sidesteps
      that entirely by construction (it's a wholly separate joint value).
    - **The `remainingTurns: 1` status-effect timing flips when you move the roll earlier.**
      The old code added the rod's status effect *after* `tickStatusEffects()` specifically so
      it wouldn't be swept in the same turn it was granted. Once the roll moved to Phase 0 (same
      turn as the read AND the tick), that ordering constraint disappears on its own — the
      status is read at Phase 2 (before the tick) and correctly expires at that same turn's
      Phase 6 (after the tick), with no special-casing needed. Worth naming explicitly because
      it's easy to port the OLD "add after tick" comment forward out of habit into code where
      it no longer applies (and where doing so would silently swallow the roll before Phase 2
      ever reads it).
    - **Test consequence:** `effectiveMoveSpeed` read right after `runTurn()` returns is no
      longer a valid proxy for "did the rod bonus apply" — the one-shot status has already
      expired by the time the turn fully resolves. The rewritten test in
      `artifact_activation_test.dart` proves the bonus was live by giving it a 3-tile move
      path (unreachable at base speed 2) and asserting the avatar actually walked all 3 tiles,
      rather than inspecting post-turn state.

---

## 2026-07-31 — Animations "pre-rendered": the painter shows engine state the reveal hasn't got to yet

**Symptom** (as reported): wizards teleport to their destination, blink back, and *then* walk it
properly. Clouds appear, vanish, and reappear when the spell card resolves.

**Cause — one bug, two faces, and it isn't in either animation.** `BattlefieldPainter` is
constructed with `repaint: Listenable.merge([pulseAnimation, ...])` and `_pulseController`
is `..repeat()`. So the battlefield repaints **every frame, forever, without a widget
rebuild** — reading `widget.state` live. Meanwhile `TurnLoop.runTurn` mutates that same
`BattleState` *in place* and then keeps `await`-ing network exchanges: movement is applied at
Phase 3, clouds are conjured at Phase 5, and the turn doesn't return until after Phase 6.5.

Every frame in those gaps draws the new truth. The animations were both being handed to the UI
*after* `runTurn` returned — hundreds of milliseconds to several seconds too late — so what the
player saw was: engine result first, animation of that result second.

**This is the general shape of the trap**, not two isolated glitches: *any* visual that is
recorded during resolution and played back afterwards is spoiled by the free-running repaint.
The fix has to be "narrow the window to zero", not "make the animation better".

### The two fixes

1. **Movement now plays from inside `runTurn`.** New awaited seam
   `TurnLoop.onMovementResolved` (typedef `MovementPlayback`), called immediately after
   `_resolveAvatarMovement` and before Phase 4. `_resolveAvatarMovement` is synchronous and the
   callback body runs synchronously to its first `await`, so `_playAvatarWalks`' `setState`
   installs the animation **before any frame can render the new occupancy** — that
   synchronous-run property is the whole fix; move the call one `await` later and the bug is back.
   - **Awaiting a UI callback mid-turn is safe here** and worth being unbothered by: it sits
     immediately before the Phase 4b melee commit, which already blocks on an unbounded *human*
     decision via `meleeTargetPicker`. Both peers spend their playback independently and
     re-synchronise at the next exchange. Nothing consensus-visible is read or written.
   - **`.orCancel` on the TickerFuture is not optional now that the turn blocks on it.**
     Leaving the battle screen mid-walk disposes the controller, and a plain `TickerFuture`
     *never completes* when its ticker is cancelled — that would strand `runTurn` (and its open
     exchange) forever. `await ctrl.forward(from: 0).orCancel.catchError((_) {})`.
   - Playing the walk *here* is also just more correct: it now happens in the turn's real
     chronology (Phase 3, before the melee prompt asks about post-move adjacency) rather than
     being replayed after every spell has already resolved.

2. **`ResolutionBaseline` — a snapshot of what was on the field when the turn started**
   (cloud ids / terrain hexes / minion ids), installed by `_submitTurn` before `runTurn` and
   handed off to `_hiddenCloudIds` & co. the moment it returns. While it's set, the painter
   skips anything *not* in it.
   - **Why the painter evaluates this, and not the caller:** a hidden-set computed in `build()`
     is already stale — the applicator conjures the cloud between rebuilds, and the next
     pulse-driven repaint draws it. The check has to happen at *paint* time
     (`_cloudHeldBack`/`_tileHeldBack`/`_minionHeldBack`). This is the load-bearing detail; a
     "just compute the set in build" fix looks identical and doesn't work.
   - The post-turn hidden sets are now seeded from **baseline diff ∪ resolved-event
     `created*`**, not from the events alone, so the handoff holds back exactly what the
     baseline was holding back. Otherwise anything created outside a `ResolvedSpellEvent` (a
     wild-magic conjuration) pops in at the seam. The reveal sequence's tail releases whatever
     no card claimed — and its trigger condition now includes "the hidden sets are non-empty",
     or that remainder would stay invisible for the rest of the match.

### The one deliberate trade-off

`_pickFreeMoveDirection` (Phase 5.5 / 6.5) is the only point where the player makes a *decision*
against a board that is still mid-reveal — this turn's lava and clouds already exist. The
hold-back is therefore **lifted for the duration of that prompt and restored afterwards**.
Asking someone to step somewhere while hiding what's on the tile is a worse bug than the pop-in
the hold-back exists to prevent. (`ResolutionBaseline` is an immutable snapshot, so restoring it
re-hides them and they still bloom with their cards.)

### Still outstanding (same family, not fixed)

- **Conveyor chain rides** (`_conveyorChainAnimations`) are still recorded during resolution and
  replayed after `runTurn` — so a pushed entity jumps first and rides the belt second. Fixing it
  properly means the same treatment as movement, but `lastConveyorChainEvents` is appended from
  ~5 sites across Phases 4–6, so it needs a per-event playback seam rather than one call.
- **HP/mana and status changes** are likewise visible the instant the engine applies them,
  ahead of the cast orb and card that explain them. Not reported as a problem; noted so it isn't
  re-derived as a new discovery.

### Coverage

- `test/battle/engine/avatar_move_events_test.dart` — new `onMovementResolved` group: fires with
  positions already applied, the turn *waits* for playback before Phase 4, and it still fires on
  a turn where nobody moved.
- `test/ui/battlefield_painter_test.dart` — new `ResolutionBaseline` group. Pixel comparisons
  (render to `Picture` → PNG bytes), not smoke tests, because "was it drawn?" is the entire
  question: a post-snapshot cloud must render byte-identically to an empty field.

---

## 2026-07-31 — Overspending mana: the client allowed it, the peer forfeited

**Report:** "I cast a spell on my laptop that cost more mana than I had, the client allowed
it, but it caused a desync on my Pixel."

### Why it looked like a desync and wasn't one

Not a divergence bug — an *asymmetric rule*. Both devices did exactly what they were written
to do, and the two behaviours are incompatible:

- **Caster's device** (`_deductManaForCommittedSpell`) charges with a clamp:
  `av.mana = (av.mana - cost).clamp(0, _kMaxMana)`. Overspending is silently absorbed; the
  bar empties to 0 and play continues.
- **Peer's device** (`_verifyPeerSpellCast` step 4) treats the same cast as cheating:
  `if (peerAvatar.mana < verifiedCost) { session.sendForfeit('insufficient_mana_for_spell'); throw }`.

So one device plays on and the other stops the match. Whichever device *casts* is the one
that sees nothing wrong, which is why it reads as "the other phone desynced."

The forfeit is the right call — it's a trust-boundary check on an untrusted peer, and
weakening it to a clamp would let a peer cast for free. **The fix belongs in the UI**: don't
offer the player a cast their opponent will forfeit over.

### The fix

`TurnLoop._spellManaCost` couldn't be asked "what would this cost?" — computing the price and
applying its consequences were the same function (it consumes `chainSurcharge` /
`nextSpellCostDouble` and calls `absorbDamage`). Split:

- **`_spellCostBreakdown`** — pure. Returns `(cost, hpDamage, surchargeIdx, doubleIdx)`.
- **`_spellManaCost`** — unchanged behaviour; applies what the breakdown reports.
- **`previewSpellCost` / `canAffordSpell`** — public, side-effect free, what the UI reads.

One price function, so the gate and the deduction cannot drift. (`_certifiedManaCost` is
untouched and still the peer-side mirror — see CLAUDE.md's order-identity note.)

UI barrier in `battle_screen.dart`, three layers:
1. Hand cards print their price and grey out + refuse taps when unaffordable.
2. CAST is disabled with "Not enough mana — N needed, M left".
3. `_onCast` re-checks and snackbars, in case mana moved under a stale frame.

### Two traps this hit

- **Gate *selection* on the cheapest achievable price, not the base price.** The enhancement
  picker only appears once a card is selected, and Water/Efficiency is −1/3 — gating selection
  on the undiscounted cost puts a spell the player *can* afford permanently out of reach.
  `_bestCaseSpellCost` applies Efficiency when the spell actually earned that supreme tag.
- **Sorcerer mode must quote the worst case.** The vocal score doesn't exist until *after*
  the player commits, and a fizzle multiplies cost by 1.50 while also withholding the
  Efficiency discount. Quoting 1.0× would let the gate approve a cast the peer then forfeits
  over — the exact bug, reintroduced. `previewSpellCost` prices sorcerer casts at
  `CastingEnhancements.maxManaCostMultiplier` with the discount withheld; a well-spoken
  incantation then costs *less* than advertised, which is the only safe direction.

**Not blocked:** a pending `nextSpellCostDouble` converts its shortfall to HP damage and
clamps the price to what the caster holds. That is a legal over-budget cast, and it falls out
of the shared price function without a special case in the gate.

### Coverage

`test/battle/engine/mana_affordability_gate_test.dart` (9 tests) — the preview equals what
the cast actually deducts; previewing repeatedly consumes nothing (no status effect, no HP,
no mana); affordable at exactly `cost == mana` and not one above; the `nextSpellCostDouble`
exemption; the sorcerer worst-case quote.

**Outstanding:** the UI half is verified by analyzer + engine tests only. `BattleScreen` has
no widget-pump harness in `test/ui/` (nothing pumps it today), so the greyed card, the dead
CAST button and the readout still want one real-app pass — `flutter run -d linux`, take a
turn with a spell you can't afford.

---

## 2026-07-31 — Two WIP files parked as `.pending` (and one of them is already dead)

**What happened.** Three untracked files were sitting in the tree from an unfinished n-player
mesh pass. Two of them did not compile, which meant `flutter analyze` carried 10 errors and
`flutter test` had a file that failed to *load* — 1 red file against 1059 green tests, forever,
until a production class that doesn't exist yet lands.

Renamed rather than deleted or committed-as-is:

- `test/battle/engine/turn_loop_nplayer_test.dart` → `.dart.pending`
- `lib/battle/models/chapter_accoutrements.dart` → `.dart.pending`

`lib/battle/models/network_battle_setup.dart` compiles and is committed normally — it is the
2-6-player generalization of `duel_battle_setup.dart` (which is 2-device only), so it is real
forward work for the mesh milestone, not a duplicate.

**Why `.pending` and not `skip:`.** These are compile errors, so the file fails at load time.
`skip: true` and `@Skip()` both require the file to compile first — neither can park a file
like this. The test runner globs `*_test.dart` and the analyzer reads `*.dart`, so the suffix
takes a file out of both with a rename you can reverse in one command.

**Why not just leave them untracked.** Untracked is one `git clean -fd` from gone, and the test
is 276 lines that encode real reasoning about the withheld-reveal elimination path (§10c) —
including *why* it tests a mismatched reveal rather than a silent peer (neither
`InMemoryTransport` nor `BattleFrameReader` has a timeout, so a truly silent peer hangs the
exchange forever; that gap is inherited from the 2-player protocol, not introduced here).

**The trap worth writing down: parked WIP rots against decisions made after it was written.**
`chapter_accoutrements.dart` is not merely unfinished — it is **superseded**, in two separate
ways, and resuming it by "making it compile" would reintroduce deleted behaviour:

1. Its stated purpose is "the core-gem-assignment rule lives in one place." The core gem was
   **removed** on 2026-07-30 (see that entry above) — the mana pool is innate now, and removing
   the `isCoreGem` byte was load-bearing enough to bump `kBattleProtocolVersion` 1 → 2.
   Restoring `isCoreGem` to make this file compile would silently revert a protocol decision.
2. It maps `ArtifactKind.deflectionRod`, a slot that was repurposed into `rodOfSpreading`
   (Rod of Wind) on 2026-07-24.

And the live replacement already exists: `accoutrementsFromArtifacts` in
`accoutrement_loadout.dart`, used by both `solo_battle_setup.dart` and `duel_battle_setup.dart`.
**So this file should almost certainly just be deleted** — it is parked only because deleting an
untracked file is unrecoverable, and once it is in history that stops being true. Deleting it is
now free.

The test file is the opposite case: genuinely ahead of the codebase, blocked on a real missing
production class (`MeshBattleSession` — per-peer `BattleSession` fan-out, docs/MESH_ARCHITECTURE
.md). It also references `Accoutrement(isCoreGem:)`, so when it is un-parked, those two call
sites want deleting, not implementing.

**Note CI would not have caught any of this.** `.github/workflows/ci.yml` runs
`scripts/run_vectors.sh`, which tests `test/engine/` plus the circuit corpus — nothing under
`test/battle/` is in CI. A permanently-red local suite is the only signal that exists here, which
is exactly why it is worth keeping green.

## 2026-08-01 — Boost (Air-Air Speed Manipulation) was a status badge that did nothing

**What was broken.** `Watery Boost` — the Water flavor of Air-Air Speed Manipulation, "High
Liquidity" — resolved fine, set a `highLiquidity` status effect on the target, showed a "High
Liq." badge in the status panel, and then *nothing*. `WizardAvatar.hasHighLiquidity` and
`highLiquidityFreeTiles` existed and were **read by nothing in the engine**. Its Fire twin,
`highMobility`, was dead in exactly the same way. Both were applied through
`EffectApplicator._addStatus`, the 999-turn "permanent" variant — so they also never expired.

Grep is the whole diagnosis here: a getter with no callers is a feature with no implementation.
Worth a periodic sweep for the others (`_addStatus`'s only two call sites were these two, and
removing them left the helper itself unreferenced — that's a smell, not a coincidence).

**The fix, and the design decision behind it.** Soren's call: the boost is **not** a lasting
modifier. It resolves, and the wizard immediately chooses how far to run, paying as they go.
That is the same shape as the Airy Barrier burst step, so it reuses the same window — the Phase
5.5 / 6.5 post-resolution free-move commit-reveal rounds — rather than inventing a second
suspension point. The two **stack**: burst step free, boost tiles paid after it.

- Water pays `n(n+1)/2 × 100` mana; Fire pays `n(n+1)/2` life. Both in `TurnLoop.boostMoveCost`.
- Base cast has **0 free tiles**; Potency grants 1. The design table's `[1 free tile]` is a
  potency bracket by that table's own convention, and `effect_resolver.dart` already agreed
  (`freeExtraTiles: p ? 1 : 0`) — only the prose in `effect_kind.dart` promised it
  unconditionally. Prose corrected to match the resolver.
- Targeting unchanged: the grant lands on whoever occupies the target tile, so casting it on a
  foe hands *them* the prompt on their device.
- Both flavors on one wizard in one turn: **Water wins** (`WizardAvatar.grantBoostMove`). Mana
  is the resource that can't kill you.

**Three things that were load-bearing to get right.**

1. **The wire carries the path, never the price.** `_runFreeMoveRound` exchanges only the
   declared path (`_encodePath`, empty = stand fast — the old `_encodeOptionalTarget` shape
   couldn't express a multi-tile run). Both devices re-derive the grant with
   `freeMoveGrantFor` and re-price with `boostMoveCost` on their own state. A peer that declares
   a path longer than it can pay for gets **truncated and billed for what it actually walked**,
   not rejected — truncation is deterministic on both sides, rejection would need a new error
   path. Same rule as `_certifiedManaCost` (B-1/B-8): never accept a peer's claim about what it
   may do or what that costs.
2. **Bill off budget spent, not tiles drawn.** `_walkAvatar` now returns
   `({path, spent})`. A slow tile is 1 tile but 2 budget points; a conveyor push or ice slide is
   free tiles and 0 points. Pricing off `spent` is what makes both of those come out right, and
   it's the number BattleScreen's preview derives too (from `predictAvatarMove`'s
   `budgetRemaining`). Those are two separately-maintained mirrors of the same walk — the seam
   most likely to drift — so there's a slow-tile vector pinning them together in
   `airy_barrier_free_move_test.dart`.
3. **A Fire boost's life cost is NOT `absorbDamage`.** Routing it through barriers would let an
   Earth barrier soak the price and make the tiles free. It's a direct `hp` deduction, floored
   at 1, and `freeMoveGrantFor` caps the grant at `hp - 1` so the floor is never reached by
   surprise. (Note this differs from Earth Fuel Transmutation's "burn 4 life", which *does* go
   through `absorbDamage` — that one is framed as self-inflicted damage, this one as a price.
   If that distinction ever needs unifying, unify it deliberately.)

**UI.** The prompt builds a path with the same gesture as the movement phase (tap to extend,
tap the tip to undo, tap origin to clear), tinted by the paying element rather than air. The
MP/HP bar shows the projected level in full colour behind a desaturated fill of what the run
will eat, reading `500 → 200`. A bare burst step still commits on the tap — one free tile has
nothing to weigh; only a Boost gets the MOVE button, because there the player is choosing how
much to spend.

**Still open, and adjacent.** `TurnLoop._endOfTurn` has a live
`TODO(ui): signal free move grant to the UI` — an Airy Barrier that **expires from old age**
(`tickBarriers`) grants nothing at all, unlike one that bursts from damage. That is the other
half of "when an air barrier collapses" and is untouched by this change.

**Not yet hardware-verified.** 1076 tests green and `flutter build linux` clean, but nobody has
cast this in a running app or across two devices. Per the verification hierarchy that means it
is not done: the Spell Test Lab is the intended path (build a `[TEST]` Watery / Boost spell,
Test Battle, cast it on yourself).

---

## M4.x — Exclusive tile occupancy, the melee lunge, and animated summon movement (2026-08-04)

Three changes to how summons read and behave on the board, from one session's direction.

**1. Bodies are exclusive.** Nothing may stand on anything else — avatar on avatar, avatar on
summon, summon on summon. The rule was already in the design doc (v3.0 states it most explicitly
under *Flying*: "may move through other entities as if they were not there, but still not end
their move in the same tile as another entity"), but only three of the five movement paths
enforced it, each with its own hand-rolled copy of the predicate. There is now one:
`tileOccupied(state, hex, {ignoreAvatarId, ignoreMinionId})` in `tile_entry_resolver.dart`.
Every path consults it — declared walks, the free-move window, conveyor cascades, creature AI
steps, spawn placement, and the client-side move preview.

- **The avatar movement phase resolves against a pre-move snapshot** (`TurnLoop._occupiedTiles()`),
  not live positions, and this is the one non-obvious part. Movement is simultaneous, but
  `_resolveAvatarMovement` walks avatars one at a time and writes each position as it goes. Using
  live positions would let whoever comes first in iteration order walk through a tile the second
  player hasn't vacated yet, and forbid the reverse. The snapshot makes it order-independent —
  and it means **two adjacent wizards can never swap tiles**, which is the deliberate,
  explainable version of that rule rather than an accident of list order.
- **Walking into a body is reported as a one-sided `MovementContest`** so the UI shows the
  existing lunge-and-recoil. Gameplay-wise it is just "the walk ended here"; nothing reads it
  back. Without it the walk stops a tile early with nothing on screen to say why, which reads as
  a bug. Note the consequence for tests: the *origin-holder* branch of `resolveMovement`'s
  arbitration is now effectively unreachable for avatars (you cannot reach an occupied origin to
  contest it), so a stationary wizard no longer records a `wonContestAt`.
- **Flying keeps its documented exemption**: it walks *through* bodies and is only pulled back if
  it would come to rest on one (the truncation loop at the end of `_walkAvatar`). Budget already
  spent stays spent. Creature AI gets no such exemption — it steps one tile at a time and every
  one of those tiles is somewhere it comes to rest, so there is no pass-through to distinguish.

**2. Attack range 0 now means zero.** `Minion.effectiveAttackRange` used to `clamp(1, 999)`,
which quietly turned every melee creature into a reach-1 skirmisher — and `attackRange` is
`waterCount ~/ 3`, so *most* creatures have none. It now clamps at 0, and `_creatureTurn` spends
one movement point stepping the creature onto its target's tile, strikes, and shoves it straight
back out (it cannot stay — see rule 1). **A creature that spent its whole budget closing arrives
with nothing left to strike with and waits for next turn**, and one with `moveSpeed 0` and
`range 0` can never attack at all. That is the literal reading of the rule and it is a real
nerf to melee; if playtesting says the "spend a point" cost is too harsh, the knob is the
`unspent > 0` guard in `_creatureTurn`, not the clamp.

**3. Summons walk instead of teleporting, and wear a proper portrait.**

- `MinionMoveEvent` / `TurnLoop.lastMinionMoveEvents` / `onSummonMovementResolved` mirror the
  avatar trio exactly, awaited at the end of Phase 5b **before `_reapDead`** so a creature that
  lunged in and died to a Molten Carapace is seen making the lunge rather than vanishing off a
  tile it never visibly left. The list is cleared at the *start* of the Summons phase, not the
  turn: a Potent summon's Phase 5 bonus action is already shown by that spell's own card reveal,
  and replaying it here would walk the creature twice.
  **[CORRECTED 2026-08-19 — this paragraph's last sentence was wrong.]** The card reveal never
  reads these events; `_playSummonWalks` is their only consumer anywhere. Clearing the list at
  the Summons phase therefore discarded the bonus action's playback record entirely rather than
  avoiding a double-walk. Both lists are now reset in `runTurn` with every other per-turn sink
  and appended to by both phases. See M4.17.
- The painter's walk timeline is now shared, not duplicated: `AvatarMoveAnimation` and
  `MinionMoveAnimation` both extend `EntityMoveAnimation`, and `wizardWalkStateAt` became
  `entityWalkStateAt`. A melee creature's whole attack *is* the lunge-and-recoil, so it arrives
  through the same `lungeTile` field a wizard's lost contest does. Both playbacks share the one
  `_moveAnimController` — they never overlap (avatars in Phase 3, creatures in Phase 5b).
- The card-art thumbnail went from `hexSize * 0.62` to `kHexInscribedSquare` (`2√3/(1+√3)` ≈
  1.268 — the largest axis-aligned square a flat-top hex can hold; the slanted edge binds, not
  the flat-to-flat height). Adjacent tile centres are √3 apart, so neighbours still clear each
  other by ≈ 0.46·hexSize. The thumbnail is a widget layered over the painter, so it has to ride
  the animated token: `BattlefieldPainter.minionTokenPos` is the single shared position source,
  and `_MinionArtOverlay` rebuilds off the same controller.

**Verification.** 1168 tests green (`test/battle/engine/tile_exclusivity_test.dart` is new and
covers both rules end-to-end through the real commit-reveal pipeline; the painter/timeline side
is in `test/ui/wizard_movement_animation_test.dart`), `flutter build linux` clean. **Not yet
hardware-verified** — per the verification hierarchy that means it is not done. The Spell Test
Lab is the path: summon a melee creature next to something and watch it lunge.

## 2026-08-05 — "A spell they neither own nor hold a grant for", for a spell in your own library

A LAN test died mid-duel on the Linux side with:

```
peer cast a spell they neither own nor hold a grant for
(owner=0x2bc53f13…eba22, caster=0x2c8503…49a8) — match forfeit
```

The spell ("Airblast") was sitting in the Pixel's **Craftings** tab wearing the player's own
coat of arms, which is why the message read as impossible.

### The diagnosis

`owner=0x2bc53f13…` is byte-identical to the `ownerPubkeyHex` in `assets/basic_spells/*.json`
— i.e. the Runekey of the machine that ran `scripts/export_basic_spells.dart`, the Linux dev
box, which was also the device *rejecting* the cast. Airblast was inscribed on Linux and
reached the Pixel by library import. `owner_pubkey` is a proof public input, so it cannot be
re-bound; the rejection was correct.

**Craftings is `SpellAsset.loadAll()` with one filter, for the `[TEST]` prefix.** It has no
owner filter, so imports, Commune/Trade transfers (grid included → they never appear under
Loans either), loans, and the five shipped Basics all list there. Worse, `_CraftingsTabState`
loaded the *local* wizard name and sigil once and handed them to every card: a foreign spell
was drawn with your arms on it. Nothing in the UI could tell you the spell was unusable until
a peer forfeited a match over it.

### Four fixes (all in this change)

1. **`BattleMsgType.forfeit` (0x40) was send-only** — `sendForfeit` wrote it and *nothing in
   the tree ever read it*. Every forfeit condition is one-sided by construction, so the peer
   sat waiting on an exchange the other device had abandoned: one dead device, one live one.
   That is the "desync". Added `BattleTurnSession.peerForfeit`, a future completed by the
   incoming frame, subscribed once in `BattleScreen.initState`, rendering the existing
   `_blockingError` with a plain-English gloss per forfeit tag. Safe to subscribe late —
   `BattleFrameReader.framesOfType` is queue-backed. Covered by
   `test/battle/networking/peer_forfeit_test.dart`, including the arrives-before-anyone-listens
   ordering. `TurnSessionPair` now routes forfeits between its two sides too.
2. **Craftings tells the truth about ownership** — three states, not two, because "not yours"
   and "not castable" are different facts:
   - *own* — inscribed by this Runekey, or a shipped Basic. Keeps the local sigil.
   - *granted* — another wizard's inscription, covered by a current loan/transfer grant that
     duel setup transmits. Shows **the inscriber's** sigil in gold, plus the expiry
     (`"Another wizard's spell — yours to cast · 4d remaining"`).
   - *foreign* — another wizard's inscription with no current grant. Same sigil in rubric red,
     `"Casting it would end the duel."` This is the state Airblast was in.

   The classifier (`_classifyOwnership`) calls `usableGrantFor`, a new function factored out of
   `localIdentityMayUse`'s permission branch, so **the marker and the cast-time gate are the
   same predicate** — a Library that disagrees with the duel about what is castable would be
   worse than one that says nothing. It takes the grantee hex rather than an `Identity` so
   classifying a whole library costs one Poseidon2 derivation, not one per spell.

   Loans are additionally **filtered out** of Craftings (`_craftingsOnly` drops
   `gridWithheld`, which exactly identifies the loan paths) — they have their own tab.
   Transfers and imports are NOT filtered: a transfer arrives with its grid intact and never
   appears under Loans, so Craftings is the only place it exists. It carries the marker.
3. **`localIdentityMayUse` had zero production callers** — documented as "call this before
   `ChapterAsset.withEntry`" and never called, so an uncastable spell could reach a duel. Now
   gates the Craftings and Loans adds (`_blockedAsUnownedSpell`). Deliberately *not* gating the
   Spell Test Lab's batch add: lab spells carry a zero `owner_pubkey` by construction and the
   gate would reject all of them.
4. **`DEBUG: Reset Identity` fired on one tap with no confirmation** — it clears the Runekey
   but not `<app documents>/spells/`, silently orphaning every spell inscribed under the old
   key. Now confirms, and counts how many spells are about to be orphaned.

### Coverage

1262 tests green, including five new `usableGrantFor` cases in
`test/spells/spell_authorization_test.dart` — one of which asserts directly that the marker's
predicate and `localIdentityMayUse` never disagree, across the loan-expiry boundary.
`test/ui/about_screen_test.dart` fails on an assertion that the real
README.md contains "zero-knowledge proof" — the phrase is no longer in the README. Pre-existing,
unrelated, not fixed here.

### Still open

- Two-device re-run to confirm the forfeit now ends both sides cleanly. Per the verification
  hierarchy this is not done until that happens.
- `duel_setup.dart`'s grant filter mixes comparison styles on one line:
  `_hexEq(p.granteePubkeyHex, myOwnerHex) && localCommitments.contains(p.commitmentHex)`. The
  second is an exact string match; any case/padding difference silently drops a legitimate
  grant and produces this same forfeit. Not the cause here, not changed, worth normalising.

---

## 2026-08-05 — Wall line of sight, and the traversal-damage bug that hid behind a passing test

Implemented `docs/WALL_LOS_PLAN.md` in full: line of sight, destructible terrain, and the
per-effect resolution table. Two things are worth writing down.

### The bug: a `break` that stopped the wrong half

`EffectApplicator._applyDamage`'s `DamageKind.traversal` branch (Earthen Blast) looked like
it respected walls. It walked `_hexLinePath` from caster to target and `break`ed at an
`ImpassableTile`. Then, outside the loop, it hit the final target unconditionally anyway:

```dart
for (final hex in path) {
  if (ctx.state.tileEffects[hex] is ImpassableTile) break;
  ...hit everything at hex...
}
// Hit the final target (not already walked).
...hit everything at ctx.targetTile...
```

So the wall suppressed the *incidental en-route damage* — which is Earthen Blast's entire
upside over the other three Blast flavors — while the *primary* damage landed regardless.
That is strictly worse than having no check at all: the wall cost the caster their bonus and
cost the victim nothing. **A partial guard reads as a working feature.**

**How it hid:** the only test touching this area
(`test/battle/engine/target_tile_effects_test.dart`) asserted that Firey Inertia's
`penetrating` status chip landed on the right avatar. It never asserted that `penetrating`
changed an outcome — and it couldn't have, because the thing `penetrating` is supposed to
bypass had never been built. A test that checks a field was set is not a test of the
behaviour that field is supposed to cause. `test/battle/engine/line_of_sight_test.dart` now
pins the behavioural version: *"an Earthen Blast at a target behind a wall damages the wall
and not the target"*, which fails on the code that shipped.

### The shape of the fix

Retargeting happens **once, in `TurnLoop._applySpell`**, before the formula loop: compute
`losBlockerTile(state, actor.position, targetHex)` and dispatch every formula at the blocker
instead of the declared target. That is the authoritative path both peers run. The traversal
branch keeps its own wall guard for the paths that don't retarget (Rod of Wind's per-tile
spread, delayed casts) — but now the wall *takes* the hit and the trailing final-target hit
only runs when the path was clear.

Three things that cost time and are worth remembering:

1. **`_hexLinePath` had to be lifted before anything else could use it.** Three subsystems
   need the same line walk (cast resolution, ranged summon attacks, the battle_screen
   targeting mirror), and a second copy would have been a desync waiting to happen. It is now
   `hexLinePath` in `lib/battle/engine/line_of_sight.dart`, and `losBlockerTile` is the only
   place that decides what blocks.
2. **Chasms are the recurring trap.** `terrain.dart`'s `ChasmTile` comment asks every new
   `ImpassableTile` consumer to decide about chasms explicitly. The LOS predicate is such a
   consumer and the answer is *no* — which is exactly why it tests `is ImpassableTile`
   directly rather than calling `tileBlocksMovement()`. Anything that calls the movement
   predicate for a targeting question will silently make chasms block spells.
3. **Terrain HP is a side-map, and destruction must clear all of them.** `terrainHp` and
   `terrainBarriers` live on `BattleState` next to `expiringTiles`, not on `TileEffect`
   (which is deliberately immutable). `placeTerrain` / `removeTerrain` are the only sanctioned
   mutators precisely because a bare `tileEffects.remove(hex)` leaves ghost HP and ghost
   barriers that the *next* tile on that coord inherits. Both maps are in
   `toCanonicalBytes()`, outer sorted by (q, r) and the barrier map's inner sorted by
   `SpellAffinity.index` — an unsorted inner map is the classic mismatch that only surfaces
   on a two-device run.

### Coverage

1310 tests green (48 new across `line_of_sight_test.dart` and `terrain_hp_test.dart`). The
pre-existing `test/ui/about_screen_test.dart` README-phrase failure is unchanged and unrelated.

### Still open

- **No two-device run yet.** Terrain HP changes mid-turn, so it crosses the state-hash
  exchange point within the turn it changes — the same hazard `WILD_MAGIC_PLAN.md` A6 called
  out. Per the verification hierarchy this is not done until a real two-device duel breaks a
  wall on both sides and agrees on the hash.
- **No on-screen pass** of the new UI: terrain HP pips, terrain barrier arcs, and the
  vermilion "your spell lands *here*" highlight on the blocker. `flutter run -d linux` is the
  cheap target for that.
- ~~**Summons are deliberately not LOS-gated.**~~ *Resolved same day — see below.*

### Follow-up, same day: three effects still buffed the caster regardless of aim

Soren caught this reviewing the fallback rule. Three flavors ignored their target tile
entirely and buffed `ctx.caster`:

- **Airy Inertia** (Earth-Air, Air) — `rangeUp` on the caster
- **Firey Scrying Pool** (Air-Water, Fire) — `revealCounterCharms` on the caster
- **Watery Illusions** (Water-Air, Water) — decoys placed around `caster.position`

They are leftovers the 2026-07-27 tile-targeting sweep missed (see
`test/battle/engine/target_tile_effects_test.dart`, which exists for exactly this class of
bug). **Ruling: every effect only reaches a wizard standing on the tile it resolves on.** All
three now read `_avatarsAt(ctx.targetTile)`; the decoy set is owned by, and wrapped around,
the wizard it lands on rather than the caster.

Two things fell out of the fix, and both are improvements:

1. **The `_onBareTerrain` guards became redundant and are gone.** I had added them so §2.5's
   "a blocked self-buff is lost" would be real — a caster-directed effect would otherwise
   always find its recipient and never fall back. With the effects tile-targeted, bare
   terrain means `_avatarsAt` is empty, nothing lands, and the fallback fires on its own. The
   rule collapses back to plain *"did the effect find a recipient on this tile?"*, which is
   what it should have been.
2. **`affectsTarget` was left dead and has been removed** from `SpeedManipulationEffect`,
   `RangeModificationEffect`, and `SpellInteractionEffect` (that last one was already dead
   before this — its slug/quick branches were swept in July and nothing re-read the flag).
   A field named `affectsTarget` that no longer affects targeting is the same trap
   `penetrating` was: written by the resolver, read by nobody, and read as documentation by
   the next person. Eight resolver call sites dropped with it.

**The generalisable lesson:** a self-targeting effect is invisible to any rule keyed on "what
is on the target tile" — LOS retargeting, the terrain fallback, cloud adjacency, illusion
redirect. That is now stated as a maintenance note on `_dispatch`. If a new effect needs to
buff the caster unconditionally, it has to be exempted from those rules deliberately, not by
accident of how it was written.

### Follow-up: blocked summons land short of the wall

I had left summons LOS-exempt because the plan's §5.2 named formula dispatch only. Soren's
ruling closes it: **a summon blocked by a wall resolves on the last tile it was in before
hitting it.**

This is the one case that does *not* resolve on the blocker, and the reason is physical: an
incantation effect can land on a wall, but a creature needs a tile it can stand on, and a
wall is precisely the tile nothing can stand in. So `losBlockerTile` moved above the
`isSummon` branch in `_applySpell`, and the summon branch anchors on
`tileBeforeBlocker(caster, target, blocker)` — the last hex of the line before the blocker,
or the caster's own tile when the wall is adjacent to them (`_castSummon`'s existing spawn
search then steps outward from there, since bodies are exclusive).

`tileBeforeBlocker` lives in `line_of_sight.dart` next to the predicate it pairs with, and
`battle_screen._blockedLandingHex` branches on `spell.isSummon` so the vermilion
"lands *here*" highlight keeps agreeing with the engine.

**A test-fixture trap worth recording, because it cost a cycle:** the first version of the
spawn test used `formula: ['earth','earth','earth','earth']` and asserted the creature
appeared one hex short of the wall. It appeared at `HexCoord(3, -1)` instead. **EEEE is the
`Big` ability** (`kSummonAbilityPattern`), so the creature had a 3-tile footprint,
`_findCreatureSpawnTile` could not fit it against the wall, and it stepped sideways — nothing
to do with line of sight. Any summon fixture that wants a plain one-tile creature must avoid
all four 4-length ability patterns (AAAA/FFFF/EEEE/WWWW and the alternating ones). Three
earths gives 3 maxHp, no abilities, and a stationary creature that stays where it spawned.

---

## M4.9 — Watery Inertia: turbulent range (2026-08-06)

The second of the three unwired effects `WALL_LOS_PLAN.md` §"out of scope" listed alongside
`penetrating`. Same shape as Firey Inertia before it: `EffectResolver` produced
`turbulent: true`, `EffectApplicator` attached `StatusEffectId.turbulent` to whoever stood on
the resolve tile, `battle_screen` drew a "Turbulent" chip — and nothing read any of it.
`WizardAvatar.hasTurbulent` had zero callers. A status that costs its victim nothing while
looking like it works is worse than an absent one; that is §9's lesson restated.

### Two rulings, both Soren's (do not re-litigate)

Design v4.0 §303 reads *"Turbulent: next spell fires in intended direction but range
randomized 1–max, 4[5] turns"*, and the two halves of that sentence disagree.

1. **It persists for the full 4[5] turns; it is NOT consumed by the first cast.** Every spell
   in the window is randomized. "Next spell" is loose prose, and the sibling flavors
   (Firey/Earthen/Airy) all persist.
2. **"max" is the caster's own `effectiveSpellRange`, not the declared distance** — so a roll
   above the declared distance sails *past* the target. Falling short and overshooting are
   both real outcomes. A caster with an Airy Inertia stacked on top gets a *wider* spread,
   not a cancellation.

### Where it lives, and why it isn't in `_applySpell`

`_turbulentTarget` is called from `_resolveActions`, **above** the `SpellCastEvent` emission
— not inside `_applySpell` where `penetrating` is read. That placement is the whole reason
the effect is legible in play: the orb visibly flies to where the spell actually went and
the card reveal blooms there, instead of the orb flying at the declared tile while the
damage lands somewhere else. `ResolvedSpellEvent.targetHex` carries the rolled hex too.

Three consequences that are easy to get backwards:

- **The cloud-adjacency legality check still reads the DECLARED hex.** The roll is not the
  player's choice, so it must never be able to make their cast illegal. Same reasoning
  applies to any future range-legality check.
- **The line-of-sight walk runs against the rolled hex**, because that is where the spell is
  physically flying. A short roll can therefore stop a spell in front of a wall that would
  have blocked it anyway, and an overshoot can put a wall in the way that wasn't.
- **Wild magic's forced free casts are deliberately exempt** — they reach `_applySpell`
  directly (`resolveForcedCast`), and a cast the player never aimed has no "intended
  direction" to be thrown off.

### Determinism

Rolled from commit-reveal entropy, phase-seed tag **0x0B**, with a per-turn `_turbulentNonce`
so two casts in one turn don't fly the same distance (reset in `runTurn` next to
`_wildMagicNonce`; the seed already carries the turn number). Design v4.0 §418 names
"turbulent range" in its jointly-generated-randomness list for exactly this reason — a
locally-rolled destination desyncs at the next state hash.

Two details worth keeping:

- **An off-board overshoot walks the roll back, it does not re-roll.** Re-rolling would
  consume a second draw from a stream the other device advances in lockstep.
- **The not-turbulent path must be side-effect free.** `_turbulentTarget` returns early
  before touching the nonce, so an ordinary caster cannot perturb the stream.

### Coverage

`test/battle/engine/turbulent_range_test.dart` (10 tests, all behavioural — where damage
lands, never "is the chip set"): declared-tile fidelity without the status, distance varies
with it, direction preserved, overshoot, falling short, off-board roll walked back,
self-target unchanged, still randomizing after the first cast (the persistence ruling), stops
on expiry, and — the load-bearing one — a line of five wizards where **only the one on the
rolled tile is hit**.

Plus a lockstep test in `turn_loop_determinism_test.dart`: two independently-driven loops
must roll the same landing hex. It pins the golden value (`fixedJointEntropy` ‖ turn 1 ‖ 0x0B
‖ `player_a` ‖ nonce 0 → distance 1, so a cast declared 3 out lands 1 out) because the seed
preimage is consensus-visible; two devices on builds that hash it differently would desync
mid-duel. It also asserts the landing is *not* the declared tile, so the test cannot pass
vacuously if the wiring is ever removed.

### Still open

- **No two-device run.** Same standing gap as the Wall LOS work.
- **Plain spell range is still UI-gated only.** `effectiveSpellRange` is read by
  `battle_screen._maxCastRange` and by wild magic's `_randomTileInRange` — `_applySpell`
  never checks `hexDistance(caster, target) <= effectiveSpellRange`. Cloud adjacency has a
  trusted-engine twin (`_cloudBoundToAdjacent`) precisely because a UI gate isn't enough for
  peer casts and the Practice dummy; plain range has no such twin, so a peer's out-of-range
  cast currently resolves. Not introduced by this change, but adjacent to it and worth
  closing with the same B-1 reasoning.
- **`WizardAvatar.hasPenetrating` / `penetrationDamage` are dead.** The engine reads
  `TurnLoop._penetrationDamageFor` instead, and the two disagree on the default for a missing
  modifier (1 vs 0). `hasTurbulent` is now live; those two are not. Delete them.
- **Watery Energy Flows' copy-spell and Firey Scrying Pool's counter-charm reveal** are the
  remaining two from the same audit, still unwired.

---

## M4.10 — Spell range is enforced by the engine, not the caster's UI (2026-08-06)

Found while wiring turbulent (M4.9), closed the same day at Soren's direction. `_applySpell`
never checked `hexDistance(caster, target) <= effectiveSpellRange`. The only range gate in
the game was `battle_screen._maxCastRange`, which decides what a **human player's own client**
lets them tap — so a modified client could declare a target clean across the field, and the
Solo Practice dummy (which encodes its cast straight onto the wire and never touches that
code) was equally unbounded. Same class as B-1's mana costs: the honest client enforces a
rule the cheating one simply skips.

A quieter consequence: **Earthen Inertia's −1 did nothing to a peer.** `effectiveSpellRange`
was read by the caster's own UI and by wild magic's `_randomTileInRange`, and by nothing
else, so laying a rangeDown on an opponent shortened only what their client *offered* them.
An effect whose entire text is "reduce spell range by 1" was advisory.

### The check, and the two things that make it non-obvious

In `_resolveActions`, folded into the existing fizzle branch beside `ignoredCloudRestriction`
— an out-of-range cast fails entirely, mana already spent, chain regressed. Deliberately the
same failure mode as the cloud violation rather than a forfeit: a fizzle fully neutralises
the exploit (the cheater gains nothing and still pays), and it is safe against a false
positive in a way a forfeit is not.

1. **It measures from `preMovPos`, not `actor.position`.** Movement resolves in Phase 3,
   before action resolution, but the player declared their target in Phase 1 from where they
   stood *then* — which is exactly what the UI gated against. Measuring from the post-move
   tile would fizzle the legal cast of anyone who walked away from their target afterwards.
   `preMovPos` is captured at Phase 2 for this class of question and was already threaded
   into `_resolveActions` for `_endOfTurn`. A delayed (Mystery) fire uses its own
   `delayedOriginHex`, the tile it was declared from turns ago.
2. **Walking closer does not launder an illegal declaration** — otherwise the exploit just
   becomes "declare far, then walk". Both directions are pinned by tests.

### The governing ruling: *valid when the cast was completed*

Soren's ruling, same day, after the first cut shipped with the origin snapshotted but the
range read live: **targeting is valid so long as it was valid at the time the cast was
completed.** Both halves of the test are now read as of that one moment, and the asymmetry
that made the first cut wrong is gone.

- **Same-turn casts:** `preMovRange`, a `playerId → effectiveSpellRange` map captured at
  Phase 2 beside `preMovPos`. Nothing between the Phase 1 action commit and that line can
  change a range — statuses tick at end of turn, spell effects do not resolve until Phase 4 —
  so it is a faithful snapshot of the moment of choosing. Without it, an Earthen Inertia
  resolving *earlier in the same action phase* clipped a cast that was legal when its caster
  chose it.
- **Delayed (Mystery) casts:** `PendingDelayedSpell.declaredRange`, captured alongside
  `origin` at the declaration turn and carried to the fire through
  `SpellCastAction.delayedRange`. The Mystery target tile is committed at declaration and
  never revisited, so judging it against a range acquired while it sat pending would punish
  the player for the passage of time. Neither field is in `toCanonicalBytes()` (neither is
  `origin`) and neither crosses the wire: both peers rebuild the record from the same
  resolution, so they stay in lockstep for free.

**Keeping the pair self-consistent is the whole trick.** `(origin, range)` are captured at the
same instant and answer one question together: *"could you legally have aimed there, from
there, with that reach?"* Reading one at declaration and the other at resolution is what
produced the retroactive clip in the first place. Any future gate on a declared choice should
be built the same way.

**A note on proving the same-phase test isn't vacuous:** it drives the dummy through
`SoloBattleSession.dummyCastFormula: ['earth','earth','air']` so an Earthen Inertia lands on
the caster during the very phase their own max-range cast resolves in. Whether that actually
exercises the snapshot depends on resolution order, so it was verified by temporarily
reverting `castRange` to `actor.effectiveSpellRange` and confirming the test fails. **A
timing test you have not watched fail is a timing test you have not written.**

The cloud check one line above still measures from `actor.position`. That asymmetry is
pre-existing and left alone deliberately; if it is ever revisited, note that the two
questions genuinely differ — cloud adjacency is about where the murk is *now*, range is
about what the player could legally have declared.

### What it cost, and what that tells us

**24 existing tests failed on the first run** — every one a fixture that summoned or blasted
past its own `baseSpellRange: 3`, across six files. None were testing range; they were
testing creature AI, chain discounts, attack events, tile exclusivity. The fixtures were
simply written in a world where range was not a rule.

That is the finding worth keeping: **an unenforced invariant quietly becomes false everywhere,
including in the tests that are supposed to describe the game.** The fix was to give those
fixtures the reach their scenarios need (`baseSpellRange: 6`, and a `range:` knob on
`summon_cast_test`'s `_setup` for the two scenarios that deliberately play out on a radius-8
and radius-10 board). The real app was never affected: both the Spell Test Lab and Solo
Practice aim the dummy at `dummyPos + (0, 2)`, two hexes from a range-3 caster.

### Coverage

`test/battle/engine/cast_range_test.dart`, 7 tests: past reach does nothing at all (and emits
no `ResolvedSpellEvent`), exactly max range still resolves, one hex past is the first failure,
rangeDown really shortens a cast, rangeUp really lengthens one, walking away does not
invalidate a legal declaration, walking closer does not legalise an illegal one. They call
`TurnLoop` directly with the action a cheating client would put on the wire — going through
the UI gate would prove nothing.

### Still open

- **No two-device run**, same as M4.9.
- **The UI's pending-cast orb still draws its range ring from the caster's live range**
  (`_maxCastRange(caster, pending.origin)` in `battle_screen._pendingCastOrbs`), while the
  engine now judges that same pending spell against `declaredRange`. Cosmetic — the ring is
  a hint, not a gate — but the two now disagree by one hex whenever a rangeUp/rangeDown lands
  while a Mystery spell is in flight. Point it at `pending.declaredRange` when the delayed-cast
  UI is next touched.
- **The cloud adjacency check one line above still measures from `actor.position`.**
  Pre-existing, and arguably right — cloud adjacency is about where the murk is *now*, range
  is about what the player could legally have declared — but the two neighbours reading
  different positions deserves a comment at minimum, which it now has.

---

## M4.11 — Trajectory counter charms and behavioural kinship (2026-08-06)

`docs/COUNTER_CHARM_KINSHIP_PLAN.md` phases 1–3, built out of order relative to the plan's
own §7 (which said "not before the playtest"). Soren's call, with a reason that holds: the
old charm had to be *bound to a spell you already owned*, which meant a playtest would have
exercised a mechanic nobody could actually use on the day. §0 of the plan records the full
status, the eight rulings made during the build, and what was deliberately left out. This
entry is only the things that were surprising.

### The partial counter is where all the risk was, and the fix was to not take it

A charm now cancels a spell **formula by formula** while its trajectory and the spell's stay
in lockstep. That is a genuinely new engine behaviour: today a countered cast never reaches
`_applySpell` at all, and that accident is what makes wild-magic invariant A1 ("no wild
magic on a countered cast") true — for free, with no flag, as the comment at the top of
`_applySpell` says out loud.

The temptation was to add a `fireWildMagic: false` for countered casts and let everything
flow through one path. The better answer was to keep **two** paths:

- **full counter** → the old code, unchanged, `_applySpell` never called. A1 still holds
  for free.
- **partial counter** → `_applySpell` with `suppressedFormulas: n`. Wild magic fires,
  because the cast really happened.

`ResolvedSpellEvent.wasCountered` therefore keeps its old meaning ("nothing happened") and
a new `counteredFormulas` carries "a charm fired". Every existing consumer of
`wasCountered` — the COUNTERED ribbon, the no-thumbnail rule, the chain regression — stayed
correct without being touched. Splitting the *event* field was what let the *code* paths
stay split.

The generalisable bit: **when a new case makes an implicit invariant explicit, check whether
you can leave the old case on the old code rather than merging both onto a new one.** The
merge is where the invariant would have been lost.

### Two identities, and the one place it would have been a security bug

Kinship moving from grid to behaviour means "kin" stops being a single value. The plan (§3.3)
warned about this; it is worth restating because the failure is silent.

`commitmentHex` was answering four questions at once. Two of them want the *many-to-one*
behavioural key (kin-stacking, heraldic arms). Two want a *one-to-one* per-spell key
(loan/transfer permissions, art sync). Re-keying permissions to the kin key would have
extended a grant to any spell that coincidentally does the same thing — including someone
else's. That is privilege escalation from a one-line "make kinship consistent" refactor.

`lib/spells/spell_identity.dart` names the two apart before anything uses them, and both
`spell_permission.dart` and `sync_art_session.dart` now carry a comment saying *why* they
are not moving. They stay on `commitmentHex`, which is a grid identity and still one-to-one,
so they are sound today; Phase 4 re-keys them to `uniqueSpellId` when deleting the
commitment forces it. Doing that early would have invalidated every outstanding grant's
signature (`canonicalMessage` covers `commitmentHex`) two days before a playtest, for no
security gain.

**The book Merkle root did not move either**, for the same reason: it authenticates which
card was cast from which hand slot, which needs one-to-one. Only the batch hash and the
post-match reveal — the duplicate check — moved to salted kin leaves.

### The salted reveal is strictly better than what it replaced, both ways

`exchangeBookReveal` used to send the sorted commitment of **every spell in your book**, so
an opponent got a stable, cross-match identifier for spells you never cast. Sending raw
trajectories instead would have been *worse* — a trajectory says what a spell does.

`SHA-256(salt ‖ kinKey)` under a fresh per-match salt fixes both: kin still collide (so
kin-stacking is still detected), and the opponent learns neither the trajectory nor anything
that correlates across matches. **The salt is never transmitted and the receiver never needs
it** — the duplicate check only ever compares entries *within one player's own list*. That
asymmetry is the whole reason this works without a salt-sharing protocol, and it is the
thing to remember if anyone is tempted to "fix" the missing exchange.

Kinship-exempt spells (trajectory under 9 elements) contribute a **random** leaf, so they
can never collide. The exemption made concrete rather than special-cased at the check.

### Phase 1's histogram says the ≥9 exemption is bigger than it looks

`scripts/trajectory_histogram.dart` over the five shipped basics:

```
under 9 elements: 4 of 5 (80.0%) — freely kin-stackable
```

Four of the five basics are 3-element pure-element spells. That is a *biased* corpus — they
are deliberately trivial — so it does not settle open question 1. But it does mean the
question cannot be waved through: **run the script against a library export from the playtest
before treating the short-spell exemption as harmless.** The script also reads library
backup JSON directly for exactly that.

`k` stays 10 for the same reason: five spells is not a distribution.

### Smaller things

- **`targetSpellName` was deleted rather than repurposed** as the plan suggested. A stored
  display string for a trajectory is pure redundancy, and it is the same shape of bug the
  old field already had (it went stale when a bound spell was renamed). `charmTrajectoryLabel`
  derives it.
- **A charm whose owner cannot pay does not fire and is not consumed.** Part-paying would
  make §2.4's "full cost every trigger" a soft cost. Consequence worth knowing: a cheap
  charm can fire in an expensive one's place on a low-mana turn.
- **Longest match wins** when several charms match, ties breaking by the existing fixed
  scan order. Pure function of state, so both devices agree — the same discipline the old
  `_findCounteringCharm` already had, just with a comparison added.
- **`_decrementArtifact`'s counter-charm special case is gone.** Every charm now gets its
  own tile (attuned or not), because an unattuned charm needs somewhere visible to be
  attuned *from* — it can never fire until it is.

### Still open

- **No two-device run.** The charm trajectory is inside `BattleState.toCanonicalBytes()` and
  decides which formulas resolve, so a divergence here is a desync, not a display bug. Unit
  tests pin the hash; only hardware proves the wire.
- **No on-screen pass** of the attune dialog or the partial-counter banner.
- **Phase 4 is untouched** and unchanged: still VK-breaking, still needs the full positive +
  negative corpus.

---

## M4.12 — Spell components split, and the deadlock that shaped the wire (2026-08-06)

*Companion doc: `docs/SPELL_COMPONENTS_PLAN.md`, which is the contract. This records what
was learned building it, including the thing that did not work.*

### The deadlock is the interesting part

Sequential casting needs one signal: "the player ahead of you has finished performing."
The obvious way to get it is to watch for their `actionCommit` frame — the protocol
already sends one per player per turn, and it is opaque, so it leaks nothing.

**It deadlocks.** `actionCommit` goes out from inside `TurnLoop.beginTurn`, which first
awaits `beginArtifactPhase()` — the Phase-0 artifact-activation exchange, which is
*simultaneous* and completes only when both sides have declared. So the trailing player
would be waiting on a frame the leading player cannot send until the trailing player has
committed. Each waits for the other, forever.

Three ways out were considered:

1. **Force Phase 0 open at the start of the action phase for everyone.** Rejected: it
   would take away the player's chance to declare an artifact during their turn, which is
   the whole point of the corner-tile long-press.
2. **Add an explicit "done declaring artifacts" step.** Rejected as scope: a new
   confirmation beat in every turn, to serve a pacing feature.
3. **A dedicated frame, sent before any of the turn's exchanges are touched.** Taken —
   `componentsDone` (0x46), payload = turn number.

The lesson generalises: **a pacing signal must not ride on a rendezvous exchange.** Any
frame the engine *awaits* is, by construction, unavailable as a "the other side is ready"
notification, because it is gated on the very readiness you are trying to observe. This
is the same shape as the boundary bugs in the handoff notes — the math was fine, the
*ordering* was where it lived.

### Latch, don't stream

`componentsDone` is recorded on arrival into a **set of turn numbers**, with waiters
served from that set. The first implementation reached for a broadcast stream, which is
wrong in the ordinary case rather than an edge case: the leading player finishes
performing *before* the trailing player's screen asks whether it may act. A broadcast
drops a signal that has no listener yet, so the trailing player would be locked out for
the remainder of that turn — a hang, on the most common timeline. Same lesson
`BattleFrameReader._pendingByType` already carries; it just had to be relearned one
layer up.

A set rather than a latest-turn counter, because this signal is *not* part of the
lockstep sequence — nothing keeps the two sides' turn counters in step at the moment it
arrives, so "greater than N" is not a safe test.

### The constructor pump claims the frame

`BattleSession` pumps `componentsDone` from its constructor (so nothing can arrive
unwatched). `BattleFrameReader` hands each frame to exactly one waiter, so that pump is
now the *only* way to observe the signal — a second `framesOfType(componentsDone)`
listener waits forever. Found by writing a test that tried to read the payload directly;
it hung for 30s. Documented at the pump, and the test now checks the encoding through the
public latch instead.

### Somatic: what the trust boundary forced

The free-style motion gate ("were you gesticulating throughout, not just once?") was
originally sketched with a mana penalty for failing it. That is unimplementable and was
dropped: whether a phone moved is a **self-attested sensor claim the peer can never
recheck** — precisely the B-1/B-8 shape the vocal redesign spent a milestone removing.
The ratified behaviour is that failing it costs the enhancement and nothing else, which
keeps somatic strictly self-limiting: it can lose you power, never grant it.

The same reasoning killed the reserved somatic wire byte the earlier plan called for. It
was never needed. What crosses the wire is the *enhancement claim*, already certified
against `supreme_dominance_flags`; a gesture field alongside it would be a new untrusted
input buying nothing.

### The constant that was not invented

`castMotionSatisfied` introduces **no new energy threshold** — SOMATIC_GESTURE_PLAN §6.5
forbids invented constants and there is no corpus of free-style casting motion to
grid-search against. It reuses `GestureClassifier.energyFloor` (the measured Pixel 6 idle
ceiling) and gets its independence from a **coverage rule** instead: 3 of 4 equal windows
must clear the floor. That distinguishes "moving throughout" from "one flourish in an
otherwise still hold", which the overall-energy gate cannot. The window counts *are*
reasoned rather than measured, and that is flagged as outstanding, not hidden.

### Smaller things

- **Clockwise seating is not spawn-array order.** `Battlefield.spawnPositions` returns
  vertices in *player-count* order — 4 players sit on opposite pairs (`v3, v0, v2, v5`),
  which is not a walk around the table. Seating had to be derived by sorting players by
  their vertex's index in the clockwise list. Anyone reaching for `spawns[i]` as a seat
  index will get a plausible-looking wrong answer for 4+ players.
- **Seating is stored, not derived at read time**, because it keys on *starting*
  positions and wizards move. It stays out of `toCanonicalBytes()`: it is a pure function
  of setup inputs both devices already agree on, so hashing it would add a desync surface
  without adding a check.
- **`state.turnNumber` is the turn just finished** during the action phase (`runTurn`
  increments at its top), so the signal is labelled `turnNumber + 1`. Getting this wrong
  produces a gate that never opens, which looks exactly like a network fault.
- **Solo seats only the real player.** The dummy performs no components, so it is not in
  the order and nobody ever waits on it.

### Still open

- **No real-device pass on the somatic cast seam.** The classifier cleared its confusion
  matrix on the committed corpus, but IMU streaming during a live mid-battle hold has
  never run on hardware, and the coverage rule has never met real casting motion.
- **No two-device LAN pass on the ordering gate.** It is a wire-timing behaviour; the
  verification hierarchy puts hardware above the integration test that covers it now.
- **`awaitComponentSlot` collapses to "the one peer"** because the transport is pairwise.
  A mesh session with 3+ performers needs `componentsDone` to name its sender so a waiter
  can count them off.
- **No on-screen pass** of the components banner, the gesture-only cast, or the
  post-release Mystery delay prompt.

---

## M4.13 — Pre-playtest sweep: the duel had no way to end badly (2026-08-06)

*A general house-cleaning pass ahead of the first playtest build. Most of it was
confirmation that things are fine; one finding was a genuine blocker, and it was not
the kind a test suite was ever going to catch.*

### The blocker: nothing detected a peer that simply left

`BattleSession` subscribed to its transport with `onReceive.listen(_reader.addChunk)` —
no `onDone`, no `onError`. So the layer had **no notion of the connection ending**. Every
exchange in `runTurn` waits on `framesOfType(...)`, and those futures simply never
complete once the peer is gone. The surviving device sat blocked with no error, no
message, and no way out but force-quitting.

`peerForfeit` already existed and its doc comment describes exactly this failure shape
("one dead device and one live one") — but it only covers the case where the peer's
device is *alive, diagnosed a problem, and had time to send a frame about it*. That is
the rare case. The common ones at a playtest are all the other door: app backgrounded,
screen locked until TCP resets, wizard walks out of Wi-Fi range, process killed. None of
those sends a forfeit.

The fix is the same seam one more time — `peerConnectionLost`, a future completed from
`onDone`/`onError`, rendered as its own blocking error ranked *below* forfeit and
lockstep-break (both of those also end with the socket closing, and both say something
more specific about why).

### The half of it that mattered more

Detecting the drop was only half. `BattleScreen.dispose()` **never closed the session or
the transport at all** — despite the lobby explicitly handing ownership over
(`battle_lobby_screen.dart`'s `_handedOff`, whose comment says "BattleScreen now owns the
session/transport lifecycle"). `BattleSession.close()` existed and had zero callers
anywhere in `lib/`.

So the single most likely playtest exit — *a player taps "Leave battle"* — left the
socket wide open. An open socket is precisely what the peer reads as "still there", so
the leaver's opponent hung indefinitely with no signal, which the new `onDone` handler
would never have fired for either. Closing the session on dispose is what converts that
into a clean socket close, and therefore into the opponent's "Lost contact" screen.

The general lesson: **a hang-detection mechanism is only as good as the teardown that
triggers it.** Wiring `onDone` without also guaranteeing somebody calls `close()` would
have shipped a fix that never fires on the path that needed it most.

### Cancelling is not closing (the thing that makes this safe)

`close()` does `_sub.cancel()` before disconnecting, and **a cancelled subscription never
fires `onDone`**. That is load-bearing: it is why tearing down our own session at a normal
match end cannot raise a false connection-lost error over the top of the result screen.
The `_matchEnded` guard in the screen is the second belt on the same trousers, for the
ordering where the peer's socket closes first. There is a test for each.

### The components gate needed releasing by hand

`_componentsDoneWaiters` are plain completers, not frame waiters, so the transport dying
does not touch them. A trailing player blocked on the sequential-components gate would
stay locked even after the connection-lost screen was up. `_noteConnectionLost` completes
them explicitly. Any *future* completer keyed to a wire signal needs the same treatment —
the frame-reader teardown will not find it.

### Smaller things fixed in the same pass

- **`test/ui/vocabulary_screen_test.dart` was failing on `main`** (1 of 1463). Not a real
  defect: the Somatic tab labels its cells by the *enhancement* they buy
  (Potency/Velocity/Efficiency/Mystery, via `kEnhancementLabel`) while the test, written
  in the same commit, asserted element names. The test now reads the labels from the same
  map the panel does, so a rename cannot pass here and diverge live.
- **Launcher label was `rune_duel`** — the Flutter template default, which is what a
  playtester would have seen on their home screen. Now `Runewright`. Linux window title
  likewise.
- **Sync Art's received-art size cap** (OUTSTANDING_ITEMS.md §7, open since the art-pack
  work). Capped on the base64 *string* length before `base64Decode`, because decoding
  first is the allocation being refused. The integrity check is no defence here — the
  peer hashes their own bytes, so any size passes it. Negative test added.
- **SRS hint on the verifier-init error.** A device that has never inscribed has no SRS
  cached and downloads it on first duel — including a pure-verifier device (Bug-Avoidance
  #4). At a venue with no internet that is a blocking error whose raw text ("SRS download
  failed", a reqwest timeout) tells a player nothing. Appended, never substituted.

### Confirmed fine (so nobody re-checks them)

Dev flags (`kAllowProoflessSpells`, `kShowDevSurfaces`) both `false`. `key.properties`
present, so release builds are really signed. `check_ffi_fresh.sh` clean. Release APK
builds: 82 MB, arm64-only. The SRS cache is already sized for tier-48 on first download,
so a player who inscribes at tier 12 does not need a second download to duel at 48.
Avatar CC BY 3.0 attribution is surfaced in-app. Component toggles all default off.

### Still open

- **No two-device pass on any of this.** The connection-lost path is a wire-timing
  behaviour; the verification hierarchy puts hardware above the socket-level test that
  covers it now. The cheap version: start a duel, kill one app from the task switcher,
  confirm the other shows "Lost contact" rather than freezing.
- **"Leave battle" has no confirmation dialog.** It is a bare `Navigator.pop` in the app
  bar, and it now genuinely ends the duel for both players (before, it just leaked the
  socket). One mis-tap on a touch screen mid-duel is a lost match. Flagged, not fixed —
  it is a design call.
- **`assets/audio/` is 47 MB in the tree, unregistered in `pubspec.yaml`** and referenced
  by no code, so it does not reach the APK. `SPELL_SOUND_PACK_PLAN.md` is still blocked on
  §2 decisions D-1…D-7.

### Follow-ups, same sweep (2026-08-07)

Four items from the M4.13 flag list, taken up after review.

- **"Leave battle" now confirms.** It had to cover the Android back gesture too, not
  just the app-bar button — back-swipe is the *easier* of the two to hit by accident
  mid-duel, so guarding only the button would have been half a guard. Both call sites
  read one predicate, `leavingNeedsConfirmation`, precisely so they cannot drift apart.
  Lifted once the match ends: at that point the close button is just "go back".
- **Branding unified on one word.** `RUNE WRIGHT` → `RUNEWRIGHT` (menu), `Rune Wright` →
  `Runewright` (app title, Rune Craft app bar), matching README, CREDITS and the design
  docs, which were already one word. Two tests asserted the old string.
- **SRS readiness is now visible in the lobby, not discovered at the venue.** A device
  that has never inscribed has no SRS, and the first duel fetches ~130 MB — which fails
  as a blocking error mid-handshake on a bad venue network. The lobby now checks for the
  cache file on entry and, when missing, offers an explicit "prepare this device" step.
  **Deliberately not an automatic background download:** 130 MB is far too much of
  someone's mobile data to spend without asking. The prepare path uses tier 12's
  bytecode on purpose — `get_srs_cached` sizes *every* download to the tier-48 floor
  regardless of caller, so this fetches identical bytes while loading far less into
  memory. That same floor policy, plus the atomic publish, is what makes a bare
  file-exists check a sound readiness signal; `srsCacheReady`'s doc says so, because if
  the policy changes the check silently stops being right.
- **Version is `1.0.1+2`.** The `+N` is the Android versionCode and is the half that
  matters mechanically — monotonic, never reusable on Play. Bump it per handout build so
  a bug report can name which build it came from.

#### The test-harness trap this cost an hour to

`test/ui/lobby_srs_readiness_test.dart` hung for the full 10-minute timeout rather than
failing. Cause: real file I/O (`File.writeAsBytes`) awaited directly in a `testWidgets`
body. A real Future never completes inside the fake-async zone, so the test does not
fail — it *hangs*, which reads like an infinite loop in the widget. It belongs in
`tester.runAsync`, same as the image-decode case already in the notes. Worth recognising
on sight: **a widget test that times out rather than failing is nearly always real async
work outside `runAsync`.**

#### Still open after this pass

- `BattleScreen` has no widget-test harness at all — nothing in the suite builds one, so
  the leave-confirmation *dialog* (that it renders, reads right, that "Keep duelling"
  cancels) is unverified. Only the predicate behind it is pinned. Same for the lobby's
  prepare button: the card's presence is tested, the download path is not.
- The two-device pass on connection-loss is still the real gate, and still outstanding.

---

## M4.x — Rod of Wind: "the boost didn't work" (2026-08-07)

A play-test reported that spending a Rod of Wind produced no visible effect. The
mechanic was wired correctly end to end; the *coverage* was the bug.

#### What was actually wrong

`EffectApplicator.apply`'s case-2 set was a four-entry allowlist — direct/knockback
damage, status-effect interaction, tile modification — plus case 1 for splash and
clouds. Everything else fell through to "apply once, unchanged". That is **15 of 64**
(affinity × effect-kind) combinations responding to the rod, and the rod was consumed on
every cast with at least one formula regardless. Reproduced across six formulas: barrier,
reflections, speed, traversal damage and divination all spent the rod and widened
nothing.

The allowlist's stated justification was already false when it was read:

> *Everything else is left single-target: caster self-buffs (barrier, quick,
> penetrating…) … re-running them per tile would wrongly multiply a single-recipient
> effect.*

The **2026-07-27 tile-targeting sweep** had converted every handler in the file to
resolve against whoever occupies `ctx.targetTile`. The comment survived the sweep; the
allowlist it justified survived with it. Two independent properties make the per-tile
loop safe, and both are now written into `apply`'s doc comment because a future change to
either silently breaks the model: `_addStatusWithDuration` **replaces rather than
stacks**, and `_avatarsAt` matches an **exact position** so a wizard is hit once however
large the disc.

Spreading is now the default. `_isSpreadableAtTiles` names only the exceptions and is
**exhaustive over the sealed `SpellEffect` hierarchy** — the old `_ => false` wildcard is
exactly what let a new effect kind default to "never spreads" without anyone deciding.

#### Two things this cost, both worth remembering

1. **A negative vector that passes under mutation is not a negative vector.** Two drafts
   of the chain-steal tests passed with the constraint deleted. The first asserted the
   wrong invariant entirely (see below); the second was carried by an unrelated tie-break
   because the victims' `playerId`s happened to sort the same way strength did. Every
   exception here was verified by *removing it and watching the paired test fail*. Do
   that — reading the test is not enough.
2. **Read the handler before claiming what a loop would do to it.** The Watery chain
   steal was written up as a multiplication hazard (`chainLengths[el] += bonus * 2` once
   per occupied tile). It is not: `_applyChainInteraction` calls `clear()` and re-derives
   from the target on every pass, so looping it is idempotent in the bonus. The real
   hazard was *whose* chain you get — last tile of `_spreadTiles`' BFS order wins.

#### Rulings (Soren, 2026-08-07)

- Illusions spread for the decoy and creature-copy flavors; **Earth's terrain copy does
  not** — it already fans out onto all six neighbours, so a 7-tile disc would paint ~24
  tiles from one cast. It is the one illusion case where the disc compounds with a
  fan-out the effect performs on its own.
- Traversal damage does not spread: it is the caster→target flight line, applied once per
  cast by `TurnLoop._applyPenetrationEnRoute`, and a line has no disc form.
- The chain steal is excluded from the per-tile loop but **not** from the rod. The disc
  widens its candidate set inside `_strongestChainTarget` and the **strongest chain wins**
  — aim into a crowd, rob its best-built duellist. Ties break on `playerId`, the
  convention `_findCounteringCharm` and the melee round already use, so both devices pick
  the same victim.

#### Why it reached a play-test

The summon branch had an end-to-end vector through `runTurn`; the incantation branch had
none. Every incantation test handed `effectiveRadiusBonus` straight to
`EffectApplicator`, which cannot catch a break anywhere in *Phase-0 declaration →
`declaredActivation` → `rodRequested` → `_applySpell` → `_consumeRodOfSpreading`*. Both
modes now have one. **A feature with a UI declaration step and an engine consumption step
needs a vector that spans both, or the seam between them is untested by construction.**

#### Still open

- Consensus-visible between peers: both devices need the same build or their state hashes
  diverge on the first spread cast. Not a `RULESET_VERSION` bump (that gates CA/circuit
  rules, and nothing here touches the circuit), but it is a two-device gate.
- Unchanged and worth a later look: a Big or rod-enlarged creature is matched by
  `_minionsAt` once per occupied tile, so it takes a spread effect once per footprint
  tile inside the disc. Pre-existing for direct damage; now reaches more effects. Read as
  "more of the blast lands on a bigger target" rather than a bug, but it was never
  explicitly ruled on.
- No UI feedback confirms the bonus applied. The corner tile's outline reflects the
  *declaration* only, and in a LAN duel it does not light up until the opponent reaches
  Phase 0, because `_beginArtifactPhaseForTurn` blocks on the commit-reveal exchange.

---

## M4.x — Status effect durations stack (2026-08-07)

Rule change, Soren's call: applying a status effect to an entity that already carries
that effect now **extends it by the new application's duration** instead of replacing
it. Land a 3-turn slow on someone with 2 turns of slow left and they have 5.

#### One entry point, and why it is one entry point

`StatusEffect.applyTo(effects, id, mods, turns)` in `wizard_avatar.dart` is now the only
way a status reaches an entity. Five sites used to hand-roll `removeWhere(id)` +
`add(StatusEffect(...))`: `EffectApplicator._addStatusWithDuration` and `_mirrorStatus`,
`TurnLoop._addStatus`, the muddy-melee minion debuff, and wild magic's Updraft. Each was
one edit away from disagreeing with the others about a rule that has to be identical on
both peers, so the rule moved into the model beside `StatusEffect` and they all call it.
`TurnLoop._applyHaymaker`'s Fire DoT, which stacked `+= 3` by hand long before any of
this, now rides the same path — it was the only place that already had the new behaviour.

Two properties it deliberately keeps:

- **Magnitude does not stack, only duration.** One entry per effect id stays an invariant
  of `activeStatusEffects`, because `effectiveMoveSpeed` / `effectiveSpellRange` *sum*
  every matching modifier they find — a second `speedDown` entry would double the debuff
  rather than extend it. The surviving entry carries the newest application's modifiers.
- **The refreshed entry is re-appended at the end.** `chainAccumulationMultiplier` reads
  the list in reverse and takes the first chain effect it finds, so "most recently applied
  wins" is positional. Refreshing in place would have let a stale `chainSlow` outrank a
  `chainFast` cast after it.

#### The comment that had to be corrected

`EffectApplicator.apply`'s doc comment (from the Rod of Wind entry above) named
"`_addStatusWithDuration` **replaces** rather than stacks" as one of two load-bearing
properties making the per-tile spread safe. That half is now false. The spread is still
safe, but on the *other* property alone: `_avatarsAt` matches an exact position, so each
wizard falls in exactly one tile of the disc and is hit once however large it gets. The
comment now says so, and says it is the property to check rather than assume. (Minions
are not affected: nothing in `EffectApplicator` puts a status on a minion — the only
minion status write is the muddy melee debuff, which is not a spread path. If that ever
changes, note `_minionsAt` matches *any* occupied tile, so a Big creature would stack a
spread status once per footprint tile.)

#### Where it does not silently accumulate

`rodMobility` is applied and ticked away inside the same turn (`_artifactEntropyImpl`
rolls it, Phase 6 expires it), so the next turn's roll always finds a clean slate and the
per-turn passive never piles up. The exception is a bearer under `statusDormant`, whose
effects do not tick at all — rolls accumulate turns there until dormancy lifts, the same
as any other status applied during dormancy. Documented at the id in
`status_effect_ids.dart` rather than special-cased in code.

#### Tests

`test/battle/engine/status_effect_stacking_test.dart` pins the primitive (fresh add,
extend-what-remains, single entry, newest modifiers win, re-append position) and the spell
path through `EffectApplicator.apply`. One existing test changed meaning: wild magic's
*"bracket steps extend the duration and re-firing does not stack"* asserted the old rule
directly — Updraft fired twice at 4 turns is now 8, still in one entry. Full suite green.

#### Still open

- Consensus-visible between peers, like every battle-engine rule: both devices need the
  same build or their state hashes diverge the first time a status is re-applied. Not a
  `RULESET_VERSION` bump (that gates CA/circuit rules; nothing here touches the circuit),
  but it is a two-device gate.
- Balance is untested at the table. Duration stacking is strictly a buff to repeated
  casts of the same debuff — the "rest of match" sentinel (`revealCounterCharms` = 999)
  is harmless, but a spammed slow or `nextSpellCostDouble` now compounds where it used
  to plateau. Worth watching in the first play-test that has two casts of one status.

---

## M4.9 — The tier/VK mismatch that broke lockstep (and froze the board)

*2026-08-08, from a play-test. Two separate bug reports, one root cause.*

### The reports

1. "Froze on battle map, no indication of error other than lack of responsiveness."
2. `The duel broke lockstep and cannot continue ... circuit_verify failed: Backend error:`
   `Assertion failed: num_public_inputs == static_cast<size_t>(vk->num_public_inputs).`
   `Actual: 42 Expected 66. Reason: Oink verifier: num_public_inputs mismatch with VK`

### Root cause

The battle screen loaded **one** verification key for the whole duel, chosen from
`MatchConfig.tier` (default **24**), and `TurnLoop._verifyPeerSpellCast` verified *every*
peer cast against it. But a spell is proven at the smallest tier covering **its own T**
(`tierForSteps`, `inscribe.dart`) — a T≤12 spell is a **tier-12** proof.

Public-input count is `10 + 2*tier_max`, plus 8 for barretenberg's pairing-point object:

| tier | public inputs |
|------|---------------|
| 12   | 42            |
| 24   | 66            |
| 48   | 114           |

So the reported 42-vs-66 is exactly *a tier-12 spell cast into a tier-24 match*. The delta
of 24 is `2 × (24 − 12)` — the arithmetic identifies the tier gap precisely, which is worth
remembering: **this error message names both tiers if you invert the formula.**

`MatchConfig.tier` is a *ceiling* negotiated at handshake, never the tier any given spell
was proven at. Treating it as the latter meant most duels broke on the first real cast,
since tier-12 is the common cheap spell and the config defaults to 24.

### Why it presented two different ways — the important part

The regression test below, run against the *unfixed* code, **timed out rather than
throwing**. A mismatched VK makes the assertion fire *inside* the native call and the Dart
future never completes. So:

- If the abort surfaces as a catchable error → "duel broke lockstep" (report 2).
- If it wedges the FFI call → `runTurn` never returns, `_isBusy` never clears, the board
  freezes with no error, **and the peer freezes too**, waiting for the next exchange
  (report 1).

Both reports are the same bug. This is also a standing hazard beyond this fix: **a failing
verify can hang the turn loop rather than fail it.** The `catch_unwind` wrappers do not
cover a native `assert` abort. Worth a timeout around `verifyProof` in a later pass.

### The fix

- `TurnLoop` takes `vkBytesForTier` (a `Uint8List? Function(int tier)`) alongside the old
  single `vkBytes`, which remains as the fallback so the ~14 test call sites passing
  `vkBytes: Uint8List(0)` keep working.
- `_verifyPeerSpellCast` derives the tier from the spell's own T and selects both the VK
  and the parse layout from it. T is peer-supplied, so it is fail-closed by construction
  (a wrong tier picks a VK the proof cannot satisfy), and the certified `outputs.t` is
  re-checked against the claim so the value that chose the layout is bound to the value
  the proof attests.
- `_wildMagicFromOwnProof` had the same bug for *local* spells — `parseOwn(bytes, tier)`
  with the match tier reads the trajectory arrays at the wrong offsets. Now derives from T.
- The battle screen loads **all three** bundled VKs (already in `pubspec.yaml`), and inits
  the SRS from the **largest** tier's bytecode: it must cover the biggest proof the device
  might verify, and the cache is sized to the tier-48 floor anyway.

### Tests

`turn_loop_proof_verification_test.dart` gained a real-FFI regression test: a tier-12 spell
cast into a **tier-24** match, asserting the VK lookup asked for tier 12 and the cast
survived. **Verified to fail (by timeout) without the fix.**

The pre-existing test in that file could never have caught this — it runs a tier-12 spell
in a tier-12 match, so the right and wrong lookups coincide. *A fixture whose match tier
equals its spell tier cannot see this class of bug.*

Five fixture files (`mana_cost_lockstep`, `resolution_order`, `vocal_recall_parity`,
`turn_loop_determinism`, `wild_magic_resolution`) built tier-24-shaped synthetic proofs for
low-T spells — internally inconsistent, describing spells that cannot exist. They now
derive tier via `tierForSteps(t)`, so the fixture matches what a real inscription produces.
Suite: 1549 green (the 2 `vocabulary_screen_test` failures are pre-existing).

### Also added — stall diagnostics

Every exchange is "send ours, await theirs"; if the peer never answers, the board freezes
silently. `BattleSession` now records which frame it is blocked on and exposes
`stalledExchange` after 8s; the battle screen polls it and shows a "WAITING FOR OPPONENT —
`<frame>`" banner. Deliberately **not** on the `BattleTurnSession` interface: that is
`implements`-ed by every test double, so a member there forces a stub into each.

This does not fix any hang — it makes the next one diagnosable from a screenshot instead of
guessed at, which is what cost the most time here.

## M4.10 — "state hash mismatch on turn 3": the two cast-charging phases

*2026-08-08, from a play-test. Second lockstep break of the day, unrelated to the
tier/VK one above — that fix let duels get far enough to hit this.*

### The report

`This duel broke lockstep and cannot continue ... Bad state: state hash mismatch on
turn 3: local=47b8a4f3... peer=78421261...`

### Root cause: a cast is charged in two different phases

A spell's mana is deducted in two places, and they are deliberately in different phases:

| whose cast | where it is charged | phase |
|---|---|---|
| your own | `_deductManaForCommittedSpell`, right after the action commit crosses the wire | **1** |
| the peer's | `_verifyPeerSpellCast`, once the reveal is verified | **5** |

Neither can move on its own: you cannot charge for a cast you have not seen revealed, and
the caster's own device must price and affordability-gate the cast at commit time.

So for any single cast, **device A applies the deduction three phases earlier than device
B does**. Anything that touches the caster's mana in between is applied on opposite sides
of the deduction on the two devices — and `_applyManaGain` clamps at `maxMana`, so the
order is *observable*:

```
caster's device:   100 − 11 = 89, then +25 → clamped 100
opponent's device: 100 + 25 → clamped 100, then − 11 = 89
```

Exactly one thing lands in that window in ordinary play: **move-phase Meditate**, granted
at Phase 2. Which is why this presents on turn 3 and not turn 1 — a player spends the
opening turns meditating, arrives at their mana ceiling, and the first turn they *cast
while also meditating in move* is the turn the clamp has something to eat.

The mana totals are not the worst of it. `_fizzlesForMana` was also being evaluated
against two different pools — the opponent priced an unaffordable cast against 25 more
mana than the caster did, so the two devices could disagree about whether the spell
fizzled *at all*, and resolve completely different turns.

### The fix

Move-phase Meditate now pays out at **Phase 5, after both casts have been charged**
(`_applyMoveMeditations`), instead of at Phase 2 where it is declared. Phase 2 still
exchanges and records the declaration; only the payout moved.

**The caster's own ordering is the canonical one.** Their cast was committed — and gated
for affordability — before the meditation was worth anything, so a move-Meditate cannot
fund the same turn's spell. It never could on the caster's device; now every device agrees.

The payout also walks its players in **sorted playerId order**, not local-first. It was
local-first, which is a different order on each device: a Reflections `manaMirror` link
makes one player's gain feed the other's, so with two meditators and a link the clamp is
order-sensitive there too. Same convention `_findCounteringCharm` and the Phase 4b melee
round already follow.

### Test

`turn_loop_determinism_test.dart` → "cast + move-Meditate mana lockstep". Two real
`TurnSessionPair` loops; caster at their 100 ceiling casts an 11-mana spell *and*
meditates in move. **Verified to fail without the fix**, with the identical
`state hash mismatch on turn 1: local=… peer=…` shape as the play-test screenshot.
Suite: 1550 green (the 2 `vocabulary_screen_test` failures are still pre-existing).

### Still open — the rest of the Phase 1 → Phase 5 window

The meditate payout was the only thing in that window that bites in *ordinary* play, but
it is not the only thing in it. The inputs to both pricing paths are the caster's `mana`,
their `chainSurcharge` / `nextSpellCostDouble` entries, their chain state, and their HP.
Chain state and mana are now clean. Two rarer holes remain, **both the same root cause**:

1. **Water haymaker status drain** (`_applyHaymaker`, Phase 4b) strips a turn from *all*
   of its target's status effects and removes any that hit zero. Punch a caster who is
   carrying `nextSpellCostDouble` with **1 turn left**: their own device already consumed
   it at Phase 1 and charged double; the opponent's device drains it away at Phase 4b and
   charges single. Mana diverges.
2. **Shortfall-to-HP damage** (`_certifiedManaCost` step 5) can in principle kill the
   caster. On their device that death lands at Phase 1, before the melee round's
   `isAlive` gate; on the opponent's, at Phase 5, after it. One device throws a punch the
   other does not.

Both need a status combination rare enough that neither has been seen in play. The
options, none of them free, for whoever picks this up:

- **Snapshot the pricing inputs at Phase 1** on every device (each avatar's mana +
  cost-relevant status entries), and have `_verifyPeerSpellCast` price against the
  snapshot. Precise and closes the whole window at once, including anything added later;
  costs a per-turn snapshot and a second source of truth for "what did they carry".
- **Defer each offending mutation past the charge**, as the meditate payout now is.
  Cheap per case, but it is one-at-a-time and the next addition to Phases 2–4b reopens it.
- **Charge both casts at Phase 5.** Structurally the cleanest — one phase, one order —
  but the local mana bar then does not move until reveal, and the commit-time
  affordability gate needs somewhere else to live.

**The standing rule this leaves behind: anything new that mutates a wizard's mana, chain,
cost-modifying statuses, or HP between the action commit (Phase 1) and the action reveal
(Phase 5) is a lockstep bug by construction.** That window has two different charging
orders in it and always will, until one of the three options above is taken.

---

## M4.14 — The ruleset epoch that negotiated nothing (2026-08-13)

Flagged independently twice: by `OUTSTANDING_ITEMS.md` §6 while wiring Stage 2, and by an
outside architecture review (`docs/Runewright Architecture Review — August 2026.md`).
Both were right.

`ProofIntake` has parsed `ruleset_version` since it was added and **nothing ever read
it**, while `MatchConfig.rulesetVersion` still defaulted to a hardcoded `2` — the
circuits having moved to `3`. So the "negotiated" epoch was a field that negotiated
nothing: both peers agreed on a stale value, and no code compared it to what any proof
actually attested.

**Not exploitable, and the reason matters.** `RULESET_VERSION` is a circuit global, so it
is baked into each tier's verification key; a proof from another epoch cannot satisfy the
bundled key. The property held — it was just being enforced by accident, as a side effect
of VK selection, rather than by anything that knew it was enforcing it.

That is precisely why it needed to become explicit. **The implicit guarantee evaporates
the moment two VKs are bundled**, which is exactly what a ruleset bump is for. A version
field whose only enforcement is a coincidence of key selection will pick the worst
possible moment to stop working.

### What changed

- `kRulesetVersion` (inscribe.dart) is now the **single canonical definition**.
  Inscription, the gate runner, the benchmark screen and `MatchConfig` all derive from it
  instead of restating `3` / `'0x3'` / `2` in five places.
- `rulesetVersionHex` is **computed** (`toRadixString(16)`), not hand-written beside the
  int. A literal `'0x3'` next to a `3` is the drift this constant exists to prevent, and
  naive interpolation would silently emit `0x10` for version 10.
- `_verifyPeerSpellCast` forfeits on
  `outputs.rulesetVersion != state.config.rulesetVersion`, beside the existing `t` and
  commitment binds.

**When bumping `kRulesetVersion`, update the three `circuits/ca_v2_4_tier*/src/main.nr`
globals in the same commit.** Nothing enforces that pairing but this note.

### Wire-visible consequence

`MatchConfig.rulesetVersion` moving 2 → 3 changes an exchanged config field, and config
agreement is field-by-field. **A device on an older build and one on this build will no
longer agree and will not start a match.** Nothing has shipped, so this is free now — but
it is the reason this landed as its own commit rather than folded into a larger one: a
future "our phones stopped pairing" bisect should land on a commit whose message says so.

### Verification

`test/battle/engine/ruleset_version_bind_test.dart`, sharing
`certified_cast_fixture.dart` with M4.15. Verification is stubbed to `alwaysOk`
deliberately — the point is to reach *past* the VK's implicit guarantee and prove the
explicit check exists. Confirmed to fail against the pre-fix engine (the cross-epoch
proof was accepted without complaint) before being accepted.

---

## M4.15 — A Mystery delay was laundering the wire formula (2026-08-13)

The live half of the same architecture review that produced M4.14. A real trust hole that
the entire test suite was structurally incapable of catching.

### The hole

`_verifyPeerSpellCast` re-derives a peer cast's formulas, element sequence and wild-magic
triggers from the VERIFIED proof outputs — the B-1 fix — because nothing binds
`SpellAsset.formula` to the proof. **The commitment is grid-only (CLAUDE.md invariant 2),
so every non-proof field on a peer's `SpellAsset` is free text.**

That certified data lived only in `runTurn`'s three turn-scoped maps, keyed by
`commitmentHex` and cleared at the top of every turn. Fine for a cast that resolves on the
turn it is revealed. A Mystery cast resolves **up to three turns later**, by which point
the maps are long gone, so `_applySpell` hit its `certFormulas ?? _parsedFormulas(spell)`
fallback and resolved from the wire formula.

### Why nothing caught it, and why the delay specifically

This is the part worth internalising:

> **Both devices fell back identically, so the state hash never fired.** The honest
> verifier read the same forged `spell.formula` the attacker sent, agreed with itself,
> and played on. Desync-safe, and therefore invisible to every lockstep test we own —
> but not trust-safe.

The contrast with an *immediate* cast makes it sharp. Forge the formula on an immediate
cast and the verifier resolves certified (earth) while the caster resolves its own wire
value (fire): `_exchangeStateHash` catches the difference and forfeits. The forgery only
pays if it is routed through a Mystery delay, where the certified data has expired and
both sides fall back to the same lie. **The delay was not incidental to the exploit; it
was the exploit.**

This surfaced concretely while writing the tests: the first positive-path test used the
forged fixture on an immediate cast and failed with a state-hash mismatch. That failure
was the fix's own logic working correctly, and it is now `honestSpell()` in the fixture,
with the reasoning recorded there.

### The fix

`PendingDelayedSpell` now carries a `CertifiedCast` (formulas + element sequence + wild
magic), captured on the declaration turn while the verification that produced it is still
in scope. Three things made it fall out cleanly:

1. **Both devices already had a derivation path.** The owner parses its own proof
   (`ProofIntake.parseOwn`), the verifier reuses what `_verifyPeerSpellCast` derived from
   the verified outputs. Same bytes, same tier, same result — so the field costs nothing
   on the wire and is not in `toCanonicalBytes()`, exactly like `origin` and
   `declaredRange` beside it.
2. **`_wildMagicFromOwnProof` was already most of the derivation.** It now delegates to
   `_certifiedFromProofBytes`, so there is still one derivation, not two.
3. The three certified maps stay as they are for current-turn casts; the delayed entry is
   simply preferred over them at resolution.

**Trap worth remembering:** the certified lookup for a delayed fire is keyed by **object
identity** (`Map<TurnAction, CertifiedCast>.identity()`), not by `commitmentHex`. The
commitment is grid-only, so the same grid proven at two different `T`s shares a
commitment — a delayed fire and a same-grid current-turn cast would otherwise collide and
hand one the other's certified data. For the same reason the declaration site branches on
**ownership** (`actor.playerId == localPlayerId`) rather than on map presence.

### What is left of TODO(B-1)

Only `kAllowProoflessSpells`. A spell with no proof bytes has nothing to derive from, so
it still resolves from the wire formula on both devices. Closing the TODO for good means
deleting that flag first, then making a null `CertifiedCast` for any peer spell a forfeit
rather than a fallback.

### Verification

`test/battle/engine/delayed_spell_certified_test.dart`, built as negative vectors per
§10/§11. The fixture's proof attests three supreme **earth** activations while its wire
`formula` claims **fire**; `activeChainElement` (consensus state, derived straight from
the resolved formulas) reports which source resolution actually read.

Confirmed to fail against the pre-fix engine before being accepted — the delayed fire
resolved as `SpellAffinity.fire`, the wire lie. **A negative vector that has never been
seen to fail is not evidence of anything**, and this one in particular could not have
been caught by any amount of lockstep testing.

### Still open

A two-device pass. By CLAUDE.md's verification hierarchy this work sits at
integration-test level, and it touches the peer battle path.

---

## M4.16 — Peer summons never replicate: creatures exist on one device only (2026-08-13)

**Found by the replay corpus on its first attempt at a summon script.** A real, live bug,
not a harness artifact.

### The bug

`_encodeAction` does not encode `SpellAsset.isSummon` or `summonPersonality`, and
`_decodeAction` rebuilds the peer's `SpellAsset` with those fields at their defaults
(`isSummon: false`). A summon cast therefore arrives at the opponent's device as an
**ordinary incantation**: the caster takes `_applySpell`'s summon branch and spawns a
creature, while the verifier takes the formula-effect branch and spawns nothing.

Measured on a two-loop paired run, honest fixture, proof verification live:

```
caster device   minions: 1
verifier device minions: 0
→ Bad state: state hash mismatch on turn 1
```

The match forfeits on the very turn a summon is cast. **Summons are unusable in any real
two-device duel.**

### Why nothing caught it

Every existing summon test (`summon_cast_test.dart`) runs in **solo mode** — its fixture
comment even says "never verified in solo mode". Solo has no second device, so the peer
decode path never executes and the missing wire fields cannot matter. The feature is
thoroughly tested in the one configuration where the bug is invisible.

This is the M4.x lesson again, in a new place: **a seam that only exists between two
devices cannot be tested on one.** Compare M4.6, where the two-device gate found a bug no
automated test had.

### Reproduction

`test/battle/engine/peer_summon_replication_test.dart`, currently `skip:`ped with a
pointer here. It asserts the verifier spawns the creature and fails today for exactly the
right reason. **Un-skip it with the fix — it is the regression test.**

### The fix (2026-08-13)

Both spell-cast encodings — immediate (`0x01`) and Mystery (`0x03`) — now carry
`[isSummon:1][personalityIndex:1]` immediately before the proof tail.
`kBattleProtocolVersion` 4 → **5**: the action bytes are inside the action commit hash,
so a v4 client would read the two new bytes as the start of the proof tail. This has to
fail the handshake rather than proceed.

The personality travels as a `SummonPersonality` **index**, not its name — one byte
instead of a length-prefixed string, and it cannot carry an arbitrary value. The cost is
that **the enum's declaration order is now wire-visible: append only, never reorder or
remove a case.** Same rule the element order already lives under.

`peer_summon_replication_test.dart` is un-skipped and passing: both devices spawn the
creature.

**Telling detail:** `forcedReveal` (0x43) *already* carried `isSummon` and the
personality — the wild-magic path knew these fields were needed. The ordinary action
encoding simply never got them. That is what an oversight looks like rather than a
design decision, and it is why the gap survived: nobody re-derived the requirement when
writing the normal path.

It does leave two encodings for one field (0x43 uses a length-prefixed string, the action
bytes use an index). Harmonising them is a cleanup with its own test surface and was
deliberately not bundled into a bug fix — tracked in `OUTSTANDING_ITEMS.md`.

### A second trap, found while writing the script

The obvious "plain creature" fixture — three earths, chosen to dodge the four-element
ability grant — produces `MinionStats(hp: 3, dmg: 0, move: 0, range: 0)`. Stats come
straight from element counts (`CreatureSpec._statsOf`): `hp = nEarth`,
`damage = nFire ~/ 2`, `moveSpeed = nAir ~/ 2`, `attackRange = nWater ~/ 3`. A
three-earth creature **cannot move or attack** — it spawns and then does nothing forever.

The first version of the summon script therefore passed while covering nothing but the
spawn. `EEFFAA` (hp 2 / dmg 1 / move 1) actually pursues and hits, and dodges every
pattern in `kSummonAbilityPattern`.

**A script whose actor is inert is a green test that asserts nothing.** Check that the
entity you summoned can actually do the thing the script claims to cover.

---

## M4.17 — A Potent summon's bonus action is invisible (found 2026-08-16, FIXED 2026-08-19)

Found while extracting the Summons phase behind the deterministic seam. Recorded rather
than fixed at the time: the extraction's whole claim was "no behaviour change", and this
is a behaviour change. Characterized and then fixed in a later slice.

`_castSummon` gives a Potent summon an immediate bonus action the moment it is cast, in
Phase 5:

```dart
if (enhancements.isPotent) {
  _creatureTurn(creature, rng, moveEvents: ctx.minionMoveEvents, ...);
}
```

`_creatureTurn` appends the walk to `lastMinionMoveEvents` and any blow to
`lastMinionAttackEvents`. Phase 5b then **replaced both fields wholesale** —
`resolveSummonActions` allocated fresh lists and `_resolveSummons` assigned them over the
old ones — which threw both away before `onSummonMovementResolved` ever saw them. The
creature's free first action was **fully resolved in state** (it really moved, it really
dealt the damage) but the UI never animated it: the token appeared at its spawn tile,
then jumped to wherever the bonus action left it as part of the Phase 5b walk, and the
bonus blow landed with no attack animation at all.

**Not a desync.** Both devices ran `_castSummon` identically and discarded identically,
and none of the three lists feeds the state hash. It was a presentation bug only.

Nothing caught it because the events are UI-only bookkeeping: no test asserted on the
Potent path's move events, and the replay corpus had no Potent script — the transcript
records `minionMoves` / `minionAttacks` as *counts taken after* Phase 5b, so the corpus
was blind to it by construction.

### The second half: the append landed in the PREVIOUS turn's list

Found during characterization, and it is the more dangerous half. `_castContext`'s doc
comment claimed it "always captures the CURRENT `lastX` lists — `runTurn` reassigns them
at the top of every turn". That premise was **false for exactly these two fields**:
`runTurn` reset five sinks and not these, which were only ever replaced in Phase 5b. So
on any turn after the first, Phase 5's append went into the *previous* turn's outcome
list — a collection already handed to the UI. Harmless only because nothing read it back,
and it would have become a live cross-turn leak the moment anyone "fixed" the discard by
merging the two lists.

### Two documents asserted the discard was correct, on a false premise

`TurnLoop.lastMinionMoveEvents`'s own doc comment, and this file's 2026-08-04 entry, both
said the bonus action was *"already shown by that spell's own card reveal, so replaying it
here would walk the creature a second time"*. That is not true. `_playSummonWalks` (via
`onSummonMovementResolved`) is the **only** consumer of `MinionMoveEvent`/`AttackEvent`
anywhere in the app; the card-reveal sequence reads `lastCastEvents` / `lastResolvedSpells`
/ `lastConveyorChainEvents` / `lastWildMagicEvents` and never touches the minion lists. The
clear was guarding against a double-walk that could not occur. Both comments are corrected.

**The tell was in the asymmetry.** `lastConveyorChainEvents` is reset in `runTurn` and
appended to by both phases, so a Potent summon shoved by a conveyor on its bonus step
animated while its own step did not — the same `_creatureTurn` call writing three sinks,
one of which worked. That is what "when behavior surprises you, suspect the boundary"
looks like in practice: the difference was ownership, not logic.

### The fix

One invariant, stated once and now structural:

> **Every per-turn `lastX` event list is freshly allocated at the top of `runTurn`, and
> every phase that emits events during that turn appends into those same list objects. No
> phase reassigns one mid-turn.**

Three production changes, all bookkeeping:

1. `runTurn` resets `lastMinionMoveEvents` / `lastMinionAttackEvents` alongside the other
   five per-turn sinks.
2. `resolveSummonActions` takes `moveEvents` / `attackEvents` as required parameters and
   **appends** to them, exactly as it always did for `conveyorChainEvents`, and returns
   `void`. `SummonActionOutcome` is deleted — the type existed only to carry lists back
   for the caller to assign, which was the bug.
3. `_resolveSummons` passes the loop's live lists and assigns nothing.

Playback now reads chronologically: bonus action first, then the sweep in `state.minions`
creation order. `_creatureTurn` did not move, no new callback or suspension point was
added, and the RNG stream, `actedThisTurn` handling, damage, deaths and creation order are
untouched.

**`kBattleEngineVersion` stays at 2.** The bump test is "could two builds compute a
different canonical `BattleState` from identical inputs", and that file's header says in
so many words that *"presentation, UI, animation, and event playback do not"* qualify.
These events are `TurnLoop` fields, not `BattleState` fields, and `MinionMoveEvent`'s own
doc says TurnLoop never reads them back. `kRulesetVersion` (3) and `kBattleProtocolVersion`
(5) are equally untouched.

**Corpus.** No existing golden changed — verified by regenerating the whole corpus and
finding one new file and zero modifications, which is the strongest available evidence
that canonical state and per-turn event counts are unmoved for every scripted match.
`potent_summon_acts_twice.json` is new: turn 1 is `minionMoves: 2, minionAttacks: 1`
(bonus action + sweep) against turns 2-3's `minionMoves: 1, minionAttacks: 1`, and that
contrast is what a future regression would break.

Regressions live in `test/battle/engine/potent_summon_bonus_events_test.dart`, including
a direct list-identity/lifecycle test (the turn-N lists are fresh objects and turn N+1
never touches them) and a `TurnSessionPair` parity test asserting both devices build the
same event sequence *and* identical canonical bytes.

**The lesson worth keeping:** an event sink passed as a parameter and appended to cannot
be silently replaced; one returned for the caller to assign can. The three sinks
`_creatureTurn` writes were split across both shapes, and the two that used the returned
shape were the two that lost data. Prefer the parameter.

---

## M4.18 — The free-move window applied both runs in device-relative order (found 2026-08-16, FIXED)

Found by inspection while extracting the free-move rules behind the deterministic seam,
then reproduced before being believed. `_runFreeMoveRound` ended with:

```dart
// Local first, then peer, on both devices — the order matters because the
// second walk sees the first one's occupancy.
if (localPath != null && localPath.isNotEmpty) _applyFreeMove(_localAvatar(), ...);
if (peerId != null && peerPath.isNotEmpty)     _applyFreeMove(peerAvatar, ...);
```

The comment is self-contradicting: "local first, then peer" is not the same order **on
both devices**. Device A ran A-then-B; device B ran B-then-A. Two things depend on that
order, and both are consensus-visible:

1. **Live occupancy.** The window is sequential — one avatar walks at a time — so the
   second run sees where the first one stopped. Two wizards declaring the same
   destination tile hand it to whoever is applied first.
2. **The shared phase RNG.** Both runs draw from the one `HashRng` the window was seeded
   with. A closed conveyor loop rolls its exit tile (`tile_entry_resolver._findLoopExit`),
   so the two devices bind different draws to different wizards.

This is exactly the melee bug from `ARTIFACT_SYSTEM_PLAN.md` §6.1, in a second place. The
melee round was fixed by sorting on `playerId`; the free-move window never was.

**Reproduced** in `test/battle/engine/free_move_ordering_test.dart` on `TurnSessionPair`
(the genuine two-client fixture — `SoloBattleSession` echoes state hashes back and hides
this entire class of bug, which is why nothing caught it for so long). Both flavours fail
as `StateError: state hash mismatch on turn 1`. The control test in the same file — same
terrain, same grants, only ONE wizard moving — passes on the unfixed code, which is what
rules out the fixture as the cause.

**Fixed** by ordering the two applications on ascending canonical `owner_pubkey` bytes.
Notes on the choice:

- **Bytes, not the hex string.** `key_packing._leBytesToFieldHex` emits
  `toRadixString(16)` with no zero padding, so the same key can be spelled `0x2` or
  `0x02`, and a *shorter* string can hold a *larger* number (`'0x2' > '0x10'` as text,
  `2 < 16` as a value). `compareCanonicalPubkeyHex` decodes both to a common fixed-width
  big-endian form first, which makes lexicographic byte order and unsigned numeric order
  the same thing — and agrees with the BigInt ordering `duel_battle_setup.dart` already
  uses to assign spawns, so there is no second notion of "lower player".
- **`owner_pubkey`, not `playerId`.** The pubkey is the identity both devices
  authenticated. `playerId` is the tiebreak only, so the order stays total for solo/test
  states where both avatars carry the same all-zero sentinel key; that also means the fix
  never depends on `List.sort` stability.
- **The RNG assignment changed on purpose.** Under local-first, device A's local wizard
  took the first draw. Now the lower pubkey does, on both devices. Preserving the old
  single-device assignment was never an option — it is the broken half.

### Other sites with a device-independent-but-different convention (recorded, unchanged)

These all sort on `playerId.compareTo`, which is a *textual* compare of what is, in a real
duel, an unpadded hex pubkey — so their order is arbitrary rather than numerically
meaningful. **None of them is a desync**: both devices compute the same string compare on
the same strings and agree. Left alone deliberately; changing them is a consensus-visible
reordering that needs its own reproduction and its own corpus run.

- `turn_loop.dart` Phase 4b melee applications
- `turn_loop.dart` Phase 0 artifact-activation declarations
- `turn_loop.dart` `_artifactEntropyImpl`'s rod-of-wind rolls
- `_findCounteringCharm`'s avatar sweep

If these are ever unified on the canonical-pubkey rule, it is a `RULESET_VERSION`-visible
change and wants a two-device pass, not just a green suite.

---

## M4.19 — `isSummon` is a wire field steering trusted calculations (found 2026-08-17, NOT fixed)

Found by inspection while preparing the mana-cost extraction, after `PeerCastVerifier`
made the trust boundary explicit enough to read off what does and does not cross it.
Recorded rather than fixed: closing it requires an authenticated structure that does not
exist yet (see "What a fix needs" below), and inventing an engine-side rule instead would
be exactly the confabulated structure CLAUDE.md warns against.

### The gap

`TurnLoop._certifiedManaCost` takes `isSummon: spell.isSummon` — a plain wire field —
and every other input it takes is certified. Nothing binds that field:

* **Proof public outputs** (`proof_intake.dart`) are `T`, `owner_pubkey`,
  `ruleset_version`, `commitment`, `border_activations`, `dominance_trajectory`,
  `supreme_dominance_flags`, `segment_count`, `dot_count`. No summon bit.
* **`commitment = Poseidon2(packed_grid)`** is grid-only (CLAUDE.md invariant 2), and
  summon-ness is not a property of the grid.
* **Book membership** (`book_commitment.dart`) hashes `commitmentHex` leaves, so the
  Merkle root binds the grid set and nothing else. The Option-2 batch hash is over the
  same leaves.
* **`spellHashHex = Poseidon2(commitment, T)`** (`inscribe.dart`) — again no summon bit.

Summon-ness is the author's *interpretation* of a certified trajectory, chosen in the UI
(`main.dart`'s `_isSummonMode`) and stored only in the local `SpellAsset` JSON. The same
grid is a legal summon and a legal incantation; no proof can distinguish them because
there is nothing to distinguish.

The action commit *does* bind the field for the turn — `_encodeAction` includes the two
summon bytes (protocol v5) and the commit hashes those bytes — so a caster cannot flip it
after seeing the reveal. That is a temporal binding, not an authenticity one.

### Why it is load-bearing

`_certifiedManaCost` and `_updateChainState` both branch on it to pick the chain affinity:

| declaration | affinity source | can be null? |
|---|---|---|
| summon | `CreatureSpec.fromElements(certElementSequence).affinity` — the majority element | no, for any non-empty sequence |
| non-summon | `pureAffinityOf(certFormulas)` — null unless every formula shares one affinity | yes |

A hybrid spell is supposed to break the chain and pay full price (design doc R3 — purity
is the whole rule). Declaring it a summon launders it into a pure cast: it takes the
`0.9^n` discount *and* advances the chain instead of clearing it. Measured in
`test/battle/engine/summon_declaration_trust_test.dart`: the same certified spell, same
proof bytes, same commitment, same battle state, same 4-cast fire chain, costs **34 mana
declared an incantation and 23 declared a summon**, and leaves the chain **cleared vs.
advanced to 5 casts**.

Both devices consume the same wire declaration, so this is a *cheat, not a desync*: the
state hash agrees and nothing rejects it.

Two smaller consequences ride along:

* **Recall opener.** `_certifiedManaCost` passes the same field to
  `IncantationRecall.tallyAgainst` as `expectedIsSummon`, which picks the opener word the
  caster is scored against. The caster authors both the spoken claim and the declaration,
  in one committed payload, so the opener slot can never score wrong — one free unit of
  recall on every cast, worth a `openerWrongWeight = 3` swing.
* **Interpretation shopping.** The same certified grid resolves as a creature or as
  formula effects, chosen after seeing the board rather than at inscribe time.

`vocal_slot.dart`'s `openerFor` doc comment names the reasoning error precisely: it
justifies trusting the field because it is "already consensus-visible". That establishes
both devices read the same value, not that the value is true. **Consensus-visible is not
certified** — worth remembering as its own rule, since the same sentence would justify
trusting any wire field.

### Adjacent, same provenance

`spell.summonPersonality` travels in the same two bytes, is equally uncertified, drives
creature AI, and lands in canonical state (`battle_state.dart` writes
`m.personality.index` into `toCanonicalBytes`). Any fix for `isSummon` should cover it —
they are one authored label, not two.

### What a fix needs

Engine-side derivation is impossible: there is no certified datum to derive from. The
options, cheapest first:

1. **Bind it off-circuit.** Extend the book Merkle leaf from `commitmentHex` to a hash
   over `(commitment, T, isSummon, personality)` — i.e. move membership onto a
   `uniqueSpellId`-shaped leaf. No circuit change, no `kRulesetVersion` bump, no
   re-proving. It does invalidate every committed root and every outstanding
   loan/transfer signature keyed to `commitmentHex`, which is exactly the migration
   `spell_identity.dart` already schedules for Phase 4 — so this wants to ride with that,
   not ahead of it.
2. **Bind it in-circuit.** A new public input. Costs a `kRulesetVersion` bump, new VKs,
   and re-proving every spell — and it certifies a field the CA has no opinion about,
   which is a poor fit for what the circuit is for.
3. **Rule it away.** Make chain affinity read the same function in both modes so the
   declaration stops being worth lying about. That is a design change to the chain rules,
   not a trust fix, and it is Soren's call.

Option 1 is the recommendation, deferred to the Phase-4 identity migration.

### Verification

`test/battle/engine/summon_declaration_trust_test.dart` characterizes the live behaviour,
including the parts that are wrong; `expectedChainLaunderingIsLive` flips to false when
the fix lands and the expectations invert. The attack stays as the regression. 807 tests
in `test/battle/` green, full suite 1619 green (the 2 `vocabulary_screen_test.dart`
failures are pre-existing and fail identically without this file).

No version epoch moved: nothing about the characterization changes canonical state, wire
framing, or proof semantics.

---

## M4.20 — A forced cast resolves the peer's authored formula (found 2026-08-19, FIXED 2026-08-19)

Found by a provenance audit of the peer-authored `SpellAsset` fields that survive
`ActionWire.decodeAction` — `name`, `formula`, `t`, `isSummon`, `summonPersonality`. The
audit's headline result is that two of the three fields it set out to check are sound:
**`t` is bound to the proof** and **`name` is presentation-only**. The third is not,
and the leak is not on the path anyone was watching.

### The audit's result, field by field

| field | classification | where it is bound, or where it leaks |
|---|---|---|
| `t` | authored → **commit-bound → proof-certified** | `PeerCastVerifier.certifyPeerCast` rejects `outputs.t != spell.t` with `t_mismatch`. Its only *use* before that check is `tierForSpell(spell.t)`, which selects the VK — fail-closed, because a wrong tier picks a key the proof cannot satisfy. Nothing downstream reads a wire `t`: `CertifiedPeerCast` deliberately does not carry one, mana comes from `certifiedBaseManaCost(outputs, …)` over `outputs.t`, and `toCanonicalBytes` never encodes it. |
| `name` | authored → **presentation-only** | No gameplay read anywhere. Terminal consumers: the wire codecs, `SightingCapture.spellName` (local bestiary file, off-lockstep), `SpellCardWidget`/`showSpellCardFullscreen` via `TurnLoop.spellAt`, and event/log text. Absent from `toCanonicalBytes`, from every hash, and from resolution. |
| `formula` | authored → **certified-superseded on the ordinary path, LOAD-BEARING on the forced-cast path** | See below. |

### The gap

`TurnLoop.resolveForcedCast` calls `DeterministicResolution.applySpell` with **no
certified arguments**:

```dart
await _resolution.applySpell(
  _castContext(entropy), actor, pick.spell, target, const CastingEnhancements(), rng,
  fireWildMagic: false, subjectToRippling: false, skipChainUpdate: true,
);
```

`certFormulas` and `certElementSequence` therefore default to null, and `applySpell`
falls back to `parsedFormulas(spell)` / `elementSequence(spell)` — the **authored wire
formula**, which no proof attests (the commitment is grid-only, CLAUDE.md invariant 2).

The certified data exists and is thrown away one call earlier. `ForcedCast.run` step 3
calls `host.verifyForcedReveal`, which runs the reveal through the real trust boundary:

```dart
await _verifyPeerSpellCast(
  SpellCastAction(spell: spell, targetHex: const HexCoord(0, 0)),
  merkleProof,
  <String, CertifiedCast>{},   // ← the certified semantics land here and are discarded
  forcedCast: true,
);
```

`_verifyPeerSpellCast` writes `cast.semantics` into the map it is handed. That map is a
throwaway literal, so the proof-derived formulas, element sequence and wild-magic
triggers are computed, verified, and dropped. Step 4 then resolves from the wire.

### Why it is exploitable, not merely untidy

The ordinary cast path is safe precisely because the two devices read *different*
formulas: the caster resolves its own wire value, the receiver the certified one, and
`_exchangeStateHash` forfeits on the difference. That is what makes an immediate forgery
self-defeating (M4.15 is the same lesson from the Mystery-delay direction).

The forced-cast path removes that asymmetry. Both devices resolve the *same* authored
formula — the revealer from its own `localSpellAt(position)`, the receiver from the
revealed bytes — so the state hashes agree. A modified client edits `formula` in its own
on-disk `SpellAsset` (a plain JSON field, bound by nothing), reveals it, and both devices
apply it. The forfeit that catches an immediate forgery cannot fire here.

Two properties make it worse than an ordinary cast:

* **The cast is free.** A8 exempts forced casts from mana entirely, and
  `_verifyPeerSpellCast` skips its mana block under `forcedCast: true`. So the laundered
  formula costs nothing.
* **The slot guard does not help.** `ForcedCast.run` selects slots publicly before anyone
  reveals, which stops the revealer *shopping* for a favourable spell. It does not stop
  them *lying about the contents* of whichever slot was picked — the reveal is checked for
  position, proof validity, commitment and T, none of which constrain `formula`.

Reachability: the only caller today is wild magic's Spontaneous Combustion, whose triggers
are derived from certified proof outputs plus the community seed — attacker-influenceable
by grinding a grid whose hash triggers it. Per the Phase-3 notes above, **Spontaneous
Combustion has never crossed a real wire**, so this is live code with no hardware pass.

`spell.isSummon` and `spell.summonPersonality` ride the same path for the same reason;
that is M4.19, not a separate finding.

### What a fix needs

Cheapest repair, and the one the surrounding code already implies: **carry the certified
cast from step 3 to step 4 instead of discarding it.** `ForcedCastHost.verifyForcedReveal`
returns `void` today and its doc comment already claims it "Returns the certified spell" —
the type never caught up with the prose. Make it return the `CertifiedCast?`, store it on
`ForcedCastPick`, and have `resolveForcedCast` pass `certFormulas` / `certElementSequence`
/ `certWildMagic` through to `applySpell`, exactly as `resolveActions` does for an ordinary
cast. No new derivation, no second source of truth — the value is already computed.

The local player's own picks (`isLocalPlayer`) never go through `verifyForcedReveal`, so
they need the same `certifiedFromProofBytes` fallback the delayed-fire branch uses at
`deterministic_resolution.dart:2763`; otherwise the two devices would resolve one pick
from certified data and the other from the wire, and the state hash would forfeit.

**Version implications: none on the wire.** No wire bytes move — `forcedReveal` (0x43)
already carries the proof and the Merkle path, which is everything the certified
derivation needs, so `kBattleProtocolVersion` stays at 5. No circuit change, so
`RULESET_VERSION` stays at 3. It does change resolution for any cast where the wire
formula and the certified trajectory disagree — see the engine-version note in the fix
below, which is where that lands.

### Verification

`test/battle/engine/authored_spell_field_trust_test.dart` characterizes all three fields:

* a `t` sweep that encodes one action frame and patches **only the two `t` bytes** —
  every other byte, including the proof, held identical. Against a proof certifying T=3:
  T−1, T+1 and 11 → `t_mismatch`; 24 → `invalid_spell_proof` (the wire value selects a
  different tier and the proof is parsed at the wrong offsets — fail-closed, one check
  earlier); 0, 49 and 0xFFFF → `invalid_spell_tier`. Only T=3 certifies.
* two casts identical but for `name` (including a 64-character multi-byte one) producing
  byte-identical `toCanonicalBytes`.
* the formula control pair: on the ordinary path the receiver resolves the certified earth
  trajectory (no cloud) while the caster resolves its own authored `water/water/fire` (a
  cloud); on the forced path the receiver resolves the **authored** formula and the cloud
  appears.

905 tests in `test/battle/` green. The one failure is
`action_resolution_characterization_test.dart`'s "Scattered Gusts re-deals the hand" case,
a **pre-existing test defect** unrelated to this audit: it asserts a random redeal cannot
equal the prior hand, which is a coin flip — baseline measurement was 3 failures in 6 runs.
Not fixed in this slice.

### The fix (2026-08-19)

Exactly the repair the section above specifies: **carry the certified cast from step 3 to
step 4 instead of discarding it.** Four small edits, no new derivation and no second
source of truth.

1. `TurnLoop._verifyPeerSpellCast` returns `Future<CertifiedCast?>` — the semantics it was
   already computing, or null for `PeerCastUncertified` (solo, verification not wired up,
   proofless dev flag). A rejection still throws. The ordinary path ignores the return and
   keeps reading the turn-scoped map, so nothing about it changes.
2. `ForcedCastHost.verifyForcedReveal` returns that `CertifiedCast?`, which is what its
   doc comment claimed all along. The throwaway map stays a throwaway **on purpose**: a
   forced reveal is not a cast the peer chose, so it must not publish itself into this
   turn's certified maps where an ordinary cast of the same grid would pick it up.
3. `ForcedCastPick` carries a `certified` field. Peer picks get it from
   `verifyForcedReveal`; local picks from a new `ForcedCastHost.certifiedFromProofBytes`,
   which TurnLoop already implemented for the `ActionResolutionHost` seam. Both routes end
   at `PeerCastVerifier.semanticsOf` over the same proof bytes at the same tier, so the
   revealing device and the receiving device derive byte-identical formulas, element
   sequence and wild-magic triggers — which is what keeps the state hashes agreed.
   Branching on ownership rather than on map presence is deliberate, for the reason the
   delayed-declaration branch documents: the map is keyed by commitment, the commitment is
   grid-only, so a peer revealing the same grid this turn must not be able to supply OUR
   semantics.
4. `TurnLoop.resolveForcedCast` passes `certFormulas` / `certElementSequence` /
   `certWildMagic` to `applySpell`, exactly as `resolveActions` does for an ordinary cast.
   (`certWildMagic` is inert under A8's `fireWildMagic: false`; it is passed so the
   certified triple travels as one value rather than as two-thirds of one.)

A null `certified` still falls back to the wire, and that is correct rather than a
leftover: it means there was no proof to derive from at all, both devices see the same
absence, and the fallback is desync-safe. A peer pick that came back uncertified
additionally tries `certifiedFromProofBytes` on the revealed bytes first — parsing
unverified is no stronger than the bytes it was handed, but it is strictly better than the
authored formula and it is what the revealing device itself resolved from.

**`kBattleEngineVersion` 1 → 2.** The wire is byte-identical and every proof verifies the
same way, so neither of the other two gates can see this — which is precisely the case
`battle_engine_version.dart` was introduced for. "Honest inputs are unchanged" is not the
test; the test is whether two builds can compute a different canonical `BattleState` from
the same inputs, and here they can, two ways: the M4.20 attack itself, and — with no
adversary at all — any spell whose stored `formula` simply does not match its proof, which
a v1 build resolves from the field and a v2 build from the proof. Without the bump a mixed
pair desyncs mid-match on a state hash instead of being refused at the handshake.
`kRulesetVersion` stays 3 (no circuit change) and `kBattleProtocolVersion` stays 5 (no
framing change).

### The contradictory-formula question, deliberately left open

The fix **supersedes** a contradictory authored formula; it does not **reject** one. That
was considered and is not being decided here, because deciding it would be inventing
policy rather than closing a hole:

* **Semantic comparison is well-defined.** `elementSequence(spell)` (wire) and
  `TrajectoryParser.certifiedElementSequence(outputs)` (certified) are directly
  comparable, and raw string comparison would be wrong — `_zoneFromName` lowercases and
  `whereType` drops unrecognized names, so several texts legitimately denote the same
  sequence. An honest client writes `FormulaTracker.committed` into both
  (`main.dart:516/596`), so they agree today.
* **But the existing mismatch convention does not extend to it.** `t_mismatch`,
  `commitment_mismatch` and `ruleset_version_mismatch` all guard a wire value that is
  *load-bearing before certification* — `t` selects the VK and the parse layout,
  `commitment` keys the certified maps and the duplicate-grid guard, `ruleset_version` is
  a negotiated consensus parameter. `formula` is load-bearing in none of them: it is
  superseded outright, and the codebase documents it as a desync-safe fallback that the
  `kAllowProoflessSpells` path actively depends on.
* **So a `formula_mismatch` forfeit would be a new protocol requirement, not an
  enforcement of an existing one.** It would newly oblige every conformant client to
  transmit a formula derived exactly from the certified trajectory, on pain of losing the
  match, and it would apply to every ordinary cast, not just forced ones. That is Soren's
  call, and it wants the `kAllowProoflessSpells` question (the standing TODO(B-1)) settled
  in the same breath, since an uncertified cast has nothing to compare against.

Recommendation if it is ever taken up: fold it into the same pass that deletes
`kAllowProoflessSpells`, and make it a rejection at `certifyPeerCast` (one place, both
paths) rather than a forced-cast special case.

### Verification of the fix

`test/battle/engine/authored_spell_field_trust_test.dart` keeps sections 1 and 2 as
characterization and turns section 3 into a regression suite:

* **the historical pin** — a `ForcedCastPick` with no certified semantics still falls back
  to the wire and still makes the cloud. That is the shape M4.20 had; what the fix removes
  is the forced-cast path's ability to *produce* such a pick.
* the forged reveal (proof certifies earth/earth/earth, authored formula claims
  water/water/fire) resolves to **no cloud** on a peer pick, on a local pick, and through
  the full two-device `ForcedCast.run`;
* local and peer picks produce **byte-identical canonical state**;
* the forged spell and an honest twin — same grid, same commitment, byte-identical proof,
  differing only in the authored `formula` — produce byte-identical canonical state, which
  is the invariant stated directly: the same proof implies the same gameplay;
* an honest forced cast is byte-identical to its pre-fix resolution;
* a forced cast is still free (A8), a bad proof still forfeits (`invalid_spell_proof`), a
  proofless reveal is still refused, and the ordinary-path control is untouched;
* a **positive control** — a reveal whose proof certifies water/water/fire really does
  create the cloud through the same end-to-end sequence — so "no clouds" cannot pass
  vacuously by the forced cast never having resolved.

`forced_cast_test.dart` covers the seam itself: which source each pick's semantics comes
from (own proof for local, `verifyForcedReveal` for peer), the uncertified fallback, and
the no-proof-at-all case. Slot selection, ordering, withheld/malformed/wrong-slot forfeits
are unchanged and still green.

921 of 922 tests in `test/battle/` pass; the one failure is the known Scattered Gusts
coin-flip defect described above, unrelated and not fixed here. Full suite 1734 pass, 2
fail — the pre-existing `vocabulary_screen_test.dart` pair. Analyzer clean (no new
errors, warnings or infos).

M4.19 (`isSummon` / `summonPersonality`) is **untouched and still live**: those two fields
ride the same reveal and are still uncertified, exactly as characterized. The fix
deliberately does not paper over them — `ForcedCastPick.spell` remains the wire object and
its doc comment now says so.

### Incidental, not pursued

* **`wireBaseManaCost` overflows on an absurd `t`.** `pow(1.05, 65535)` is `Infinity` and
  `.round()` on it throws. Unreachable from a peer (the wire `t` never reaches that
  function; only a *local* spell does) and unreachable from the inscribe UI, so it is a
  robustness note, not a finding. It is why the `t` sweep patches frame bytes directly
  instead of driving a full turn — a caster with `t = 0xFFFF` dies charging itself.
* **`certifiedPeerCasts` is keyed by commitment with no ownership branch** at
  `deterministic_resolution.dart:2487`, unlike the delayed-declaration branch 280 lines
  below, which comments the hazard explicitly. Since the commitment is grid-only, a local
  cast of the same grid a peer certified this turn picks up the peer's certified semantics.
  Both devices compute the same map, so it is desync-safe; whether it is *correct* when the
  two casts ran at different T is a separate question, not audited here.
* **`SoloBattleSession`'s truncated 0x01 encoder** (`_encodeDummySpellCast`) and its inline
  `_splitActionCommit` copy are **intentionally a reduced protocol**, documented as such in
  that file's header, and cannot reach a network: the class is an in-process
  `BattleTurnSession` stub used by Solo Practice, the Spell Test Lab, `battle_screen.dart`'s
  no-session fallback, and ~20 engine tests. It never emulates real peer wire behaviour —
  it *is* the peer, locally, with `verifyProof` null. Worth knowing that a large share of
  the engine suite therefore exercises the short frame rather than the real one. Left
  untouched.

---

## M4.10b — The rest of the Phase 1 → Phase 5 charging window (found 2026-08-19, FIXED 2026-08-21)

*Investigation slice only: no policy fix, no phase reordering, no version bump. This
section is the evidence M4.10's "Still open" paragraph asked for, plus two hazards that
paragraph did not know about.*

Tests: `test/battle/engine/mana_charge_window_characterization_test.dart`, 11 cases
(5 divergences + 6 controls), all green as **characterizations of the bug**. Battle
suite: 944 green.

### 1. The temporal contract, as it actually runs

There is exactly one asymmetry and everything below is a consequence of it: **each
device charges its own player's cast at Phase 1 and the other player's at Phase 5.** For
a single cast the two devices are four phases apart. When *both* players cast, each
device applies the two charges in the opposite relative order from the other.

Timeline for one cast by `player_a`, both devices side by side:

| point | device A (`player_a`, the caster) | device B (`player_b`, the peer) |
|---|---|---|
| Phase 0 | artifact declare/exchange/apply — gem burst mana, rod roll | identical, same point |
| **Phase 1** | `beginTurn` → action commit exchanged → **`_deductManaForCommittedSpell`**: `spellCostBreakdown` prices, `fizzlesForMana` decides, `applySpellManaCost` consumes the surcharge/double, absorbs shortfall HP, deducts mana | commits its own action; knows only that *a* commit arrived. **Cannot see whether A is casting at all** |
| Phase 1 (rest) | scry openings, spell-reveal openings | identical |
| Phase 2 | movement commit-reveal; move-Meditate **declared only** (payout deferred by M4.10) | identical |
| Phase 3 | entropy reveal; `resolveAvatarMovement` — **SlowTile mana drain**, FloorIsLava HP, conveyor-loop HP | identical, but A's cast is **not yet charged here** |
| Phase 4 | `moveClouds` (positions only) | identical |
| Phase 4b | melee commit-reveal; `applyHaymaker` — HP, Water **status drain**, Earth `speedDown`, Fire DoT; `applyCounterCharmProc` — **gem destroyed → `_syncMaxMana` clamps current mana**. Victim query filters on `isAlive` | identical *inputs*, different *caster state*: on B the caster still holds its uncharged mana, its unconsumed statuses, and its pre-shortfall HP |
| **Phase 5** | `_verifyPeerSpellCast` charges **B's** cast | `_verifyPeerSpellCast` → **`certifiedManaCost`** charges A's cast here: prices, consumes, absorbs shortfall HP, `fizzlesForMana` |
| Phase 5 | `_applyMoveMeditations` (M4.10's fix — strictly after both charges) | identical |
| Phase 5 | `_resolveActions` → chain update, effects, `chainSurcharge`/`nextSpellCostDouble` *application* | identical |
| Phase 6 | status tick, terrain auras, regen | identical |

The pricing inputs first become known at Phase 1 on the caster's device only. On the
peer's device **no pricing input is knowable before Phase 5** — the action is hidden
behind its commitment until the reveal. That single fact is what rules out the naive
form of repair option A; see §5.

### 2. Hazard 1 — Water haymaker vs `nextSpellCostDouble` (M4.10's guess, CONFIRMED)

Reproduced exactly as predicted. Caster carries `nextSpellCostDouble` with
**`remainingTurns == 1`**; the opponent has the Water haymaker and punches them.

```
base cost                       20   (5×3 segments + 2 dots, ×1.05^3, effectCount 0)
caster device : Phase 1 prices with the status present   → 40 charged, entry consumed
peer device   : Phase 4b drain takes 1 → 0 and REMOVES it → Phase 5 finds nothing
                                                         → 20 charged
start 500 → caster device 460, peer device 480. State hash mismatch on turn 1.
```

`chainSurcharge` diverges identically (23 vs 20 — `ceil(20 × 0.9⁻¹)`), and for the same
reason: both consumables are applied with `remainingTurns = 2`
(`EffectApplicator`), so both sit at exactly 1 for exactly one turn. **That one-turn
window is why this has never been seen in play**, and the control test pins it: at
`remainingTurns = 2` the drain takes 2 → 1, the entry survives, and both devices agree.

### 3. Hazard 2 — Lethal shortfall vs the Phase 4b `isAlive` gate (M4.10's guess, CONFIRMED, but narrower than stated)

Two corrections to the original write-up, both narrowing it:

* **The shortfall→HP conversion is reachable only through `nextSpellCostDouble`.** In
  both mirrors `hpDamage` is computed *inside* the `doubleIdx >= 0` branch and is 0
  everywhere else. Every other unaffordable cast fizzles instead. So hazard 2 is a
  sub-case of hazard 1's status, not an independent one.
* **`meleeCandidates`' `isAlive` gate is not a divergence source.** A wizard's melee
  target is commit-revealed from their *own* device, so a caster dead at Phase 4b on
  their own device simply commits "no target" and the peer reads that null off the wire.
  Pinned by its own control test. The asymmetry lives entirely in `applyHaymaker`'s
  `_avatarsAt` victim query, which filters on `isAlive`.

Reproduction: mana 0, HP 3, `nextSpellCostDouble`; cost 20 × 2 = 40, shortfall 40,
`hpDamage = ceil(40/10) = 4`, HP 3 − 4 → dead.

```
caster device : dead at Phase 1  → at Phase 4b the target tile queries EMPTY → punch lands on nobody
peer device   : alive at Phase 4b → punch lands, leaves its speedDown behind → dies at Phase 5
```

HP itself clamps at 0 on both sides, which is why the divergence has to be observed
through the punch's *side effect* rather than through HP. With ≥1 counter charm on the
attacker it is worse than cosmetic: the proc's victim list differs, so the two devices
consume the shared melee `HashRng` stream differently from that point on.

The control pins the boundary precisely: a **survivable** shortfall is order-independent
(24 − 4 − 1 = 19 on both devices), because plain subtraction commutes and the gate never
fires. The window is observable only when the shortfall is lethal.

### 4. Hazard 3 — SlowTile mana drain (NOT in M4.10's list; the worst one)

`DeterministicResolution` line ~759, inside `resolveAvatarMovement`:
`av.mana = (av.mana - effect.manaDrainOnEntry).clamp(0, 9999)`. Phase 3. Ordinary
terrain. **No status effects required.**

```
caster mana 25, cost 20, SlowTile drain 10 on the caster's move path

caster device : 25 − 20 (Phase 1) = 5, then − 10 drain → clamp → 0
peer device   : 25 − 10 drain (Phase 3) = 15, then Phase 5: 20 > 15 → fizzlesForMana → NOT CHARGED → 15
```

The mana totals are not the worst of it. **The two devices resolved completely different
turns**: on the caster's device the spell landed (opponent 24 → 20) and advanced the
caster's fire chain to 2; on the peer's device it fizzled — opponent untouched, no chain.
This is the exact failure mode M4.10 called out as worse than the totals, and unlike the
two hazards it named, it needs no rare status combination at all. It is reachable in
ordinary play by any caster who walks over a Slow tile with mana near their spell's price.

The control pins that the same walk with mana well clear of the price agrees on both
devices: with no clamp reached and no fizzle boundary crossed, the two subtractions
commute.

### 5. Hazard 4 — Counter-charm gem destruction (NOT in M4.10's list)

`applyCounterCharmProc` → `_consumeAccoutrement(victim, manaGem)` → `_syncMaxMana`,
which does `if (av.mana > av.maxMana) av.mana = av.maxMana`. Phase 4b.

```
caster maxMana 200 (innate 100 + 1 gem × 100), mana 200, cost 20; the gem is destroyed

caster device : 200 − 20 = 180, then clamp to the new 100 → 100
peer device   : clamp 200 → 100, then − 20 → 80
```

This is the **original M4.10 clamp-ordering bug arriving from the ceiling instead of the
floor**, and it survives the meditate fix untouched because the shrink happens at Phase
4b, not Phase 2. It is the clearest evidence that M4.10's "defer the offending mutation"
option is a treadmill: the gem clamp was added to Phase 4b *after* the meditate payout
was moved out of Phase 2, and reopened the window without anyone noticing.

### 6. Full audit of the window

Every value reaching `certifiedManaCost` / `spellCostBreakdown` / `fizzlesForMana` /
`applySpellManaCost`, classified:

| input | source | mutable in the window? | classification |
|---|---|---|---|
| `certifiedBase` | SNARK public outputs | no | immutable for the turn |
| `certFormulas`, `certElementSequence` | SNARK public outputs | no | immutable |
| `recall` | action bytes, inside the commitment | no | immutable |
| `isEfficiency` | verified against certified supreme tags | no | immutable |
| `isVocalComponents` | match config | no | immutable |
| `isSummon` | **wire field** (M4.19) | no | immutable *in time*; its problem is trust, not temporality. Untouched here |
| `caster.chainLengths` / `activeChainElement` | avatar | **no** — only `_updateChainState` / `_regressChain` / `setAllChainsToNegative` touch them, all Phase 5+ | immutable in-window (M4.10's "chain state is now clean" **confirmed**) |
| `chainSurcharge` presence | avatar statuses | **YES** — Water haymaker drain, Phase 4b | **should have been snapshotted at commitment** |
| `nextSpellCostDouble` presence + modifiers | avatar statuses | **YES** — same drain | **should have been snapshotted at commitment** |
| `caster.mana` | avatar | **YES** — SlowTile drain (Phase 3), gem-destruction clamp (Phase 4b) | **ambiguous — needs a ruling** (see §8) |
| `caster.hp` | avatar | **YES** — lava, conveyor loops, haymaker damage | legitimately live for damage; **the death it causes is the ambiguous part** |
| `caster.maxMana` | avatar accoutrements | **YES** — gem destruction, Phase 4b | should be snapshotted, or the charge moved |
| effect-list *indices* (`surchargeIdx` / `doubleIdx`) | `spellCostBreakdown` output | n/a — computed and applied in adjacent statements | safe as written; do not separate those two calls |
| draw schedule / hand | — | YES (charm wither) | does not enter pricing |

Also noted, inert: the pricing mirrors match `nextSpellCostDouble` / `chainSurcharge`
with a raw `indexWhere` that **ignores `isDormant`**, while `WizardAvatar.nextSpellCostDoubled`
checks it. That getter has no callers in `lib/`, so nothing disagrees today — but the two
readings of "is this status active" are one call site away from disagreeing. Separate
from M4.10b; not touched.

### 7. Did the mana extraction change the defect?

No — and it is worth being precise, because the extraction *looks* like it should have.
Moving both mirrors behind `DeterministicResolution` changed **where the arithmetic
lives, not when it runs**: `TurnLoop` still calls `spellCostBreakdown` +
`applySpellManaCost` at Phase 1 and `certifiedManaCost` at Phase 5. The window is
byte-for-byte the one M4.10 described.

What it *did* do is make one repair strictly easier and expose an asymmetry that matters
for the others:

* The caster's side is now **already split** into a pure pricing function
  (`spellCostBreakdown` → `(cost, hpDamage, surchargeIdx, doubleIdx)`) and a separate
  applicator (`applySpellManaCost`). That is exactly the shape a snapshot repair needs.
* The peer's side is **still fused**: `certifiedManaCost` prices *and* mutates in one
  pass (consumes the status entries, absorbs shortfall HP) and returns only an `int`.
  Any snapshot repair has to split it the same way first.

### 8. Repair options

**A — snapshot the pricing inputs at Phase 1.**
Both devices hold the full replicated state at Phase 1, so a snapshot needs **no new wire
field and no new persistent field** — this is worth stating plainly because it is the
first thing anyone will assume is required. But the peer's device does not know *whether*
the peer is casting at Phase 1 (the action is behind its commitment), so it must snapshot
**both players unconditionally** and consume conditionally at Phase 5.

That forces the answer to the §6 snapshot question:

* **Snapshotting the numeric final price is not viable.** The peer cannot compute a price
  at Phase 1 — it has no spell, no proof, no recall. Only the *inputs* can be snapshotted.
* **Consumption must happen at charge time, not snapshot time**, for the same reason: the
  peer's device must not strip a `nextSpellCostDouble` off an avatar that may turn out not
  to have cast at all. So consumption becomes *"remove this status if it is still there"* —
  idempotent, and a no-op on the caster's device (already consumed) and on a drained peer
  (already removed). That is coherent, but note what it means: **the status is paid for
  even when a Phase-4b drain has already destroyed it.** That is a gameplay ruling, not an
  implementation detail.

Coverage: closes hazards 1 and 2's *pricing* half. Does **not** close hazard 4 — the
`maxMana` ceiling clamp is not commutative with the charge no matter what price you
snapshot. Closes hazard 3's *fizzle* disagreement (both devices judge affordability
against the snapshot pool) and, by the floor-clamp commutativity
`clamp₀(clamp₀(x−a)−b) == clamp₀(clamp₀(x−b)−a)`, the mana totals too — but only for
floor clamps. Any future in-window mana *gain* reopens it, exactly as move-Meditate did.
Does not close hazard 2's death-timing half at all: the shortfall HP still lands at Phase
1 on one device and Phase 5 on the other. **Two of the four hazards survive option A.**

**B — defer each offending mutation past the charge.**
Closes whichever case you point it at, and nothing else. The gem-destruction hazard is
the argument against it: that clamp was added to Phase 4b *after* the meditate payout was
deferred out of Phase 2, silently reopening the window. Deferring SlowTile drains and
haymaker status drains past Phase 5 would also move real gameplay — a drain that no
longer applies before the melee round it shares a phase with. Rejected.

**C — charge both casts at Phase 5, in canonical order.**
One charging point, one order, on both devices. Every in-window mutation then lands on
the same side of both charges everywhere, which closes all four hazards **and everything
added to Phases 2–4b later** — the property neither A nor B has.

The two objections M4.10 raised against it have both weakened since it was written:

* *"The commit-time affordability gate needs somewhere else to live."* It already does.
  `fizzlesForMana` replaced the old forfeit, and the real gate is `canAffordSpell` in the
  UI, which reads `previewSpellCost` and never charges. The Phase-1 deduction is no longer
  load-bearing for affordability; it is load-bearing only for the mana bar.
* *"The local mana bar does not move until reveal."* True, and now the whole cost:
  a presentation change, on a bar that already cannot show the recall multiplier at
  commit time (`previewSpellCost` deliberately quotes the honest base price).

Requirements C brings with it, none of them large but all of them mandatory:
1. The two charges must run in **sorted `playerId` order**, not local-first — the same
   convention `_findCounteringCharm`, the melee round and `_applyMoveMeditations` already
   follow. A Reflections `manaMirror` link makes the order observable.
2. They must run **strictly before `_applyMoveMeditations`**, preserving M4.10's ruling
   that a move-Meditate cannot fund the same turn's spell.
3. The local charge site must be unconditional, not inside `_verifyPeerSpellCast` — solo
   mode and the uncertified path still have to charge.
4. `fizzledForMana` marking moves with it; resolution already runs after.

### Recommendation

**Option C.** Not because it is the smallest diff — it is not — but because it is the
only one that states a temporal rule rather than a list of exceptions:

> **A cast is priced and charged at the moment it is revealed, against the state as it
> stands then, in canonical player order — on every device.**

A and B both leave "which phase charged this?" as a per-value question that every future
Phase-2-to-4b addition has to re-answer correctly, and the gem clamp is the proof that it
will not be re-answered correctly. C makes the standing rule M4.10 left behind
(*"anything new that mutates a wizard's mana, chain, cost-modifying statuses or HP between
the action commit and the action reveal is a lockstep bug by construction"*) into
something the engine enforces structurally instead of something a comment asks for.

### Open decisions — need Soren

1. **A/B/C.** Recommendation above.
2. **Should a mid-turn mana loss be able to fizzle a cast that was affordable when
   committed?** Under C, yes: walk over a Slow tile and your cast can fail. Under A, no.
   Today the answer is *both, one per device*, which is why it has to be decided rather
   than discovered. Recommendation: yes — it is legible ("the tile drained you"), and it
   is what the peer's device already does.
3. **Is a `nextSpellCostDouble` destroyed by a Water haymaker still paid for?** Under C,
   no (it is gone by the charge point). Under A, yes. Recommendation: no — the punch
   visibly stripped the curse; charging for it anyway reads as a bug to a player.
4. **Should the lethal shortfall land before or after the melee round?** Under C it lands
   after, so a dying caster still gets punched and still throws their own punch. That is
   a real rules change from what the caster's device does today.
5. Not blocking, but adjacent: **should the shortfall→HP route stay gated on
   `nextSpellCostDouble` alone?** It is currently the only path by which an unaffordable
   cast is not simply a fizzle, and neither M4.10 nor the design prose says whether that
   is intent or accident.

### Version implications (argument only — nothing bumped here)

* **`kRulesetVersion` — no.** No proof semantics participate. `certifiedBase`, the
  formulas and the element sequence are unchanged; no VK moves; no spell needs re-proving.
* **`kBattleProtocolVersion` — no**, for A or C. Neither adds a message, a field, or a
  framing change; A's snapshot is computed independently on both devices from state they
  already share.
* **`kBattleEngineVersion` 2 → 3 — yes, for any of A, B or C.** The gate's own test is
  *"could two builds compute a different canonical `BattleState` from identical inputs"*,
  and here the answer is demonstrably yes: the five reproductions above are transcripts —
  same messages, same proofs, same VK — that a patched and an unpatched build resolve into
  different states. The SlowTile case does not even need an adversary or a rare status.
  There is a subtlety worth stating rather than glossing: today's canonical state for
  these transcripts is **not merely different, it is undefined** — the two peers already
  disagree, which is the bug. Fixing it does not *change* a well-defined rule so much as
  *define* one, and the gate still fires, because a mixed pair would desync mid-match on a
  state hash instead of being refused at the handshake. That refusal is the entire reason
  v1 exists.

### Tests

`test/battle/engine/mana_charge_window_characterization_test.dart` — 11 cases, real
paired `TurnSessionPair` loops (two independent `TurnLoop`s, real commit-reveal, live
proof verification stubbed to `alwaysOk`). Every intermediate is pinned — base cost 20,
the doubled 40, the surcharged 23, the shortfall's 4 HP, the 25/15/0 drain arithmetic,
the 200/100/80 gem clamp — so a fix inverts specific expectations rather than replacing
the file. Six of the eleven are **controls** that remove only the in-window mutation and
assert agreement, which is what makes each divergence attributable to the window rather
than to the fixture.

Not attempted: a two-device hardware pass. By CLAUDE.md's verification hierarchy this
work sits at integration-test level; it is characterization, not a fix, so there is
nothing yet for a device pass to confirm.

---

## M4.10b, part 2 — the fix: canonical Phase-5 cast settlement (2026-08-21)

Option **C** from the comparison above, taken as recommended. `kBattleEngineVersion`
**2 → 3**; `kRulesetVersion` stays 3 and `kBattleProtocolVersion` stays 5.

### The rule

> **A committed spell reserves nothing.** Both players' ordinary committed casts are
> priced and settled from the replicated state that exists at the start of Phase 5, in
> ascending `playerId` order, before `_applyMoveMeditations` and before any other Phase-5
> resource mutation.

### Timeline, before and after

| | **v2 (before)** | **v3 (after)** |
|---|---|---|
| Phase 1 | `_deductManaForCommittedSpell`: prices the LOCAL cast, gates affordability, consumes chainSurcharge / nextSpellCostDouble, absorbs shortfall HP, deducts mana | commit-reveal exchanges only. **Nothing is charged** |
| Phases 2–4b | mutations land *after* the local charge and *before* the peer charge | mutations land before **both** charges, on both devices |
| Phase 5 | `_verifyPeerSpellCast` certifies **and** charges the peer, inline | `_verifyPeerSpellCast` certifies and returns a `_CastSettlement`; `_settleCommittedCasts` then settles **both** casts in sorted `playerId` order |
| Phase 5 | `_applyMoveMeditations` | unchanged — still strictly after settlement |

### Production changes (four files)

* **`turn_loop.dart`**
  * `_beginTurnImpl` no longer calls the deduction. The line is replaced by a comment
    saying what must never go back there.
  * `_deductManaForCommittedSpell` → **`_localCastSettlement`**: same body, same five
    steps, but returns a `_CastSettlement` instead of executing. The avatar is re-read
    *inside* the closure (`_localAvatar()`), never captured — closing over a Phase-1
    value would have quietly rebuilt the bug in snapshot clothing.
  * `_verifyPeerSpellCast` gains an optional `List<_CastSettlement>? settlements` sink,
    the same idiom `certifiedPeerCasts` already uses. Its charging block moves out to
    **`_certifiedPeerCastSettlement`**. The forced-cast caller passes no list and is
    therefore still never charged, exactly as before.
  * **`_settleCommittedCasts`** — the one authoritative settlement path.
* **`deterministic_resolution.dart`** — comments only. The "Mana cost" section header
  said the two mirrors were reached "at two different moments (the caster at commit, the
  peer after verification)", which is precisely what is no longer true.
* **`battle_engine_version.dart`** — bump + v3 history entry.
* **`certified_cast_fixture.dart` / `match_replay.dart`** — an additive `startingMana`
  knob for the new replay script, defaulting to `kStartMana` so no existing golden moves.

**No wire codec, no proof path, no phase reordering, no arithmetic change.** The five
pricing steps and the shortfall→HP rule are byte-identical; only *when* they run moved.

### How the two mirrors stay apart

The B-1/B-8 property is that an untrusted path cannot reach the trusted mirror. The
obvious way to write this fix — one settlement record with a `certified: bool` — would
have been exactly that regression: one flag away from letting a caller select the trusted
branch.

Instead `_CastSettlement` is `({String playerId, void Function() settle})`. **It carries
no discriminator at all.** The closure is built by the site that already knows which
mirror the cast belongs to, each site is the only constructor of its kind, and neither
takes a parameter that could change its mind. The two mirrors meet as opaque closures and
nowhere else.

### What the five former divergences do now

Every one adopts the LATE reading — the one the peer's device already had, which is the
only one that was ever computed from settled state:

| hazard | old caster device | old peer device | v3, both |
|---|---|---|---|
| `nextSpellCostDouble` drained at Phase 4b | 40 charged | 20 charged | **20** |
| `chainSurcharge` drained at Phase 4b | 23 charged | 20 charged | **20** |
| lethal shortfall vs the melee round | punch missed | punch landed | **lands, then they die** |
| SlowTile drain | resolved, mana 0 | fizzled, mana 15 | **fizzled, mana 15** |
| gem destruction clamp | mana 100 | mana 80 | **80** |

### Semantics that are now decided, and were not before

* **A mid-turn mana loss can fizzle a cast that was affordable when committed.**
  Commitment is not reservation. The UI gate (`canAffordSpell` → `previewSpellCost`) is
  unchanged and still quotes the honest price at commit time; it is a courtesy, not a
  promise.
* **A cost-modifying status destroyed before Phase 5 is not paid for.** Punch the curse
  off someone and they cast at the ordinary price.
* **The melee round completes before a lethal payment.** A caster who will die paying for
  their spell still throws their punch and still takes one.
* **A caster killed by their own shortfall still does not land the cast** — *unchanged*,
  and now pinned by its own regression. Both devices already did this under v2 (the charge
  preceded `_resolveActions` on each of them); the fix moved *when* the caster dies, not
  what their death does to the spell.
* **The HP-shortfall rule itself is untouched** and still reachable only through
  `nextSpellCostDouble`. Deliberately not broadened in this slice.

### On the sort, and the dependency audit it required

Charging one caster cannot currently change any pricing input of the other. Each
settlement reads and writes only its own avatar's `mana`, `activeStatusEffects`,
`chainLengths` and HP (via `absorbDamage`, which touches only that avatar's own barriers).
The one cross-player mana link in the engine — a Reflections `manaMirror` — lives in
`applyManaGain`, which is **gain-only** (`if (amount <= 0) return`) and is not on the
settlement path.

So the order is **not observable today**, and the sort is defensive rather than
load-bearing. It is fixed anyway, by the convention `_findCounteringCharm`, the Phase 4b
melee round and `_applyMoveMeditations` already follow, for one reason: the alternative is
local-first, which is a *different order on each device*, and "not observable" is a
property of the current effect list rather than of the settlement machinery. **Anything
added to settlement that does read across players is an interaction and must be brought
to Soren as one, not left to the sort to define.** That sentence is also in
`_settleCommittedCasts`'s doc comment, where someone might actually read it.

### The meditate ordering is now load-bearing in a new way

M4.10 moved the move-Meditate payout to Phase 5 to fix a clamp-ordering desync, and ruled
that a move-Meditate must not fund the same turn's spell. Under v2 that ruling *fell out*
of the caster charging at Phase 1. Under v3 it is **exactly and only the order of two
adjacent lines**: `_settleCommittedCasts` then `_applyMoveMeditations`. Swapping them
would let a meditation pay for a cast, silently and identically on both devices — a rules
change wearing the costume of a reordering, invisible to every lockstep test. Both
directions are pinned by the "move-phase Meditate cannot fund this turn's cast" group.

### The replay corpus

**All eight existing goldens are byte-identical.** That is the strongest single piece of
evidence the fix is behaviour-preserving for ordinary play: the corpus contains no
transcript in which anything touched a caster's mana, statuses or HP between the commit
and the reveal.

One script was added, `slow_tile_drains_a_cast_into_a_fizzle` — the status-free
demonstration of the new rule, and **verified to fail against the pre-fix engine**, where
it desyncs on turn 2 and the match forfeits (the harness records 1 turn where the golden
has 3).

Building it surfaced a small rules fact nobody had written down: **a wizard cannot walk
onto a spell-made Slow tile at base speed.** The tile costs `1 + extraMoveCost` = 3
movement and `_kBaseMoveSpeed` is 2, so the step is simply refused. The SlowTile race is
only reachable by a *hasted* caster, which is why the script spends turn 1 on
`[air, air, air]` before the walk. It is also why the unit-test fixture uses a synthetic
`SlowTile(extraMoveCost: 0)`: the hazard is the drain, not the movement cost.

### Verification

* `mana_charge_window_characterization_test.dart` — **15 cases**, up from 11. The five
  divergences inverted (same fixtures, same pinned intermediates, expectations flipped from
  "the devices disagree, here is each number" to "they agree, here is the one number"), all
  six controls kept unchanged, plus four new: the lethal-shortfall cast-resolution
  regression, both move-Meditate orderings, and a **both-players-cast** case that exercises
  the two-entry sorted settlement path on both devices at once.
* `test/battle/` — **948 green** (944 before this work).
* Full suite — **1759 green**; the 3 failures are pre-existing and unrelated: the 2 known
  `vocabulary_screen_test` ones, and `inscribe_test`'s SRS-cache case, which is the known
  full-suite-load flake (it passes in isolation both with and without this change, and
  touches no battle code).
* Analyzer — 16 infos/warnings, **identical to the pre-change baseline**, none in the
  changed code.

### Audit: is there a second settlement path left?

No. Grepping every mana write outside `DeterministicResolution` leaves exactly two, and
both are inside the settlement closures reached only from `_settleCommittedCasts`:
`turn_loop.dart`'s local deduction and its certified peer deduction. `previewSpellCost` is
read-only. Everything else that touches mana (`effect_applicator`, `wild_magic_applicator`)
is Phase-5 spell *resolution*, downstream of settlement, and is not cast payment.

Phase 1 now mutates nothing on account of a spell being committed. The artifact phase
(Phase 0) still spends mana, but it does so before the action commit on both devices
symmetrically and is a separate mechanic, not a cast charge.

### Left alone, deliberately

M4.19 (`isSummon` still steers the certified chain affinity from a wire field), M4.20's
formula policy, M4.17, `certifiedPeerCasts`' commitment keying, `kAllowProoflessSpells`.
One thing noticed and not touched: **`_verifyMysteryAction` drops `fizzledForMana` when it
converts an immediate Mystery cast to a `SpellCastAction`**, so a fizzled immediate Mystery
still resolves. Pre-existing, unchanged by this slice (settlement runs before the
conversion, exactly as the Phase-1 deduction did), and desync-safe because both devices
convert identically. Worth its own look.

### Still open

A two-device hardware pass. This work sits at integration-test level by CLAUDE.md's
verification hierarchy, and it changes the mana ledger on the peer path.

---

## M4.21 — Mystery is a mana-fizzle bypass (characterized 2026-08-22)

*This section records the characterization only. The repair is written up in
"M4.21, part 2" below.*

### The governing invariant, stated first

> Once canonical Phase-5 settlement marks a committed cast `fizzledForMana`, later
> Mystery conversion or delayed-declaration handling must not resurrect it. The action
> is spent and produces no spell consequence. **Mystery receives no special
> affordability exception.**

Nothing in the codebase disagreed with that sentence. `VOCAL_RECALL_PLAN.md` §4/§9.5
and `casting_enhancements.dart`'s doc comment on `fizzle` both state the rule
unconditionally — the cost outran the pool, the mana is refunded, the turn is spent —
and `runewright_design_v4_0.md` §791 describes Mystery as *delay plus secrecy* and
nothing else. There was no design intent to implement. There was a dropped field.

### Two manifestations, one invariant

**A. Immediate Mystery — the flag is lost in conversion.**

`TurnLoop._verifyMysteryAction` rebuilds an immediate (delay 0)
`MysterySpellCastAction` as a *fresh* `SpellCastAction`, copying `spell`, target,
`isPotent`, `isVelocity` and `recall` — but not `fizzledForMana`. Settlement runs
before that conversion, so the flag was written onto an object that is then discarded:

| line | what happens |
|---|---|
| `turn_loop.dart` `_settleCommittedCasts` | prices both casts, calls `_markFizzledForMana` on the **`MysterySpellCastAction`** |
| `turn_loop.dart` `_verifyMysteryAction` (≈50 lines later) | discards that object for a new one, flag defaulting to `false` |
| `deterministic_resolution.dart` `enhancements.fizzle` gate | reads `false` → full resolution |

**B. Delayed Mystery — the flag is never read.**

A non-immediate `MysterySpellCastAction` passes through `_verifyMysteryAction`
untouched, so here the flag *survives* — and then nothing consumes it.
`resolveActions`' `MysterySpellCastAction` case destructures
`spell, mysteryCommitment, isPotent, isVelocity` and queues a `PendingDelayedSpell`
unconditionally. Since a delayed fire is never re-priced (settlement happens on the
declaration turn only), an unaffordable declaration becomes a fully-effective free cast
one turn later.

These are two different defects that happen to violate the same invariant. **Fixing the
conversion does not fix the declaration**, which is why the repair below touches two
files rather than one.

### Not introduced by M4.10b

`git log -L` on `_verifyMysteryAction` shows `fizzledForMana` arrived in `fb1225a`
(vocal recall), which added `recall:` to this constructor call and not the new flag.
Under the pre-M4.10b rule the local charge happened at Phase 1 and the peer's inline in
`_verifyPeerSpellCast` — **both still before the conversion**. M4.10b moved the timing
without changing the outcome, and noted the gap in its own "Left alone, deliberately"
section rather than widening that slice.

### What it actually costs

Measured on two genuinely separate `TurnLoop`s over `TurnSessionPair`, real
commit-reveal exchanges, no network:

| pin | value |
|---|---|
| starting mana | 5 |
| canonical cost | 21 (`5×3 + 2 = 17`, `× 1.05⁴`, `× 1.5⁰`) |
| fizzle verdict immediately before conversion | `true` |
| converted action's fizzle value | `false` |
| mana paid | **none** — refunded on both devices |
| HP paid | none |
| spell effects | **resolve** — target 24 → 20 HP |
| chain | **builds to 2** (fire) instead of regressing to 0 |
| canonical state on both peers | identical |

**This is an exploitable affordability bypass, not a presentation inconsistency.** The
caster gets a full-effect cast *plus* chain progress for zero mana. And because both
devices convert identically it is desync-safe — no state-hash forfeit, no symptom, no
log line. Any client reaches it by choosing a spell it cannot afford and routing it
through Mystery. The delayed variant is the same bypass with a one-turn fuse.

That combination — free, silent, and available to an unmodified client — is what makes
this worth an engine epoch rather than a patch note.

### Scope: only the mana fizzle

`outOfRange` and `ignoredCloudRestriction` are recomputed at the resolution gate from
`preMovRange` and live cloud positions. They never travel on the action, so the
conversion cannot drop them, and the out-of-range Mystery control confirms they still
suppress correctly. `fizzledForMana` is the only fizzle input that rides the action
object, and therefore the only one exposed to a reconstruction.

### The conversion field audit

Treated as a data-loss audit rather than a one-bit search, since the whole class of bug
is "a reconstruction that forgot something":

| field | classification |
|---|---|
| `spell`, `isPotent`, `isVelocity`, `recall` | explicitly copied |
| `targetHex` | deliberately reconstructed from `immediateTarget` |
| `mysteryCommitment`, `immediateTarget`, `immediateNonce` | consumed by the conversion; irrelevant after |
| `delayedOriginHex`, `delayedRange` | correctly null — this is a same-turn cast |
| `conveyorDirection` | not representable on Mystery; documented as deliberate in `turn_actions.dart` |
| `isEfficiency` | not representable — Mystery and Efficiency are mutually exclusive claims, and the `0x03` encoding has no byte for it |
| `handIndex` | **dropped, currently harmless** |
| `fizzledForMana` | **accidentally dropped** ← the bug |

**On `handIndex`: dropped, and deliberately left dropped.** Every consumer runs
upstream of the conversion — `appendSpellProofTail` at encode time and
`_advanceDrawState` in Phase 5, both of which read `input.action` specifically *because*
the converted action has lost the distinction (there is a comment in `runTurn` saying
so). Adding it back would be speculative: there is no consumer that needs it, and a
copied-but-unread field is how the next audit gets a false negative. Fix it when
something downstream of the conversion asks for it, not before.

`turn_loop.dart`'s `_verifyMysteryAction` is the only immediate-Mystery conversion site
in `lib/`.

### The fixture trap this cost an hour to

A Mystery cast **is itself a cast-time enhancement claim**, and `PeerCastVerifier`
requires every claim to be backed by that spell's own certified supreme-dominance zone
(fire→Potency, air→Velocity, water→Efficiency, **earth→Mystery**). A synthetic proof
with a pure-fire trajectory therefore forfeits on `unbacked_enhancement_claim` before
any of this is reachable.

Worse, it *presents* as a hang rather than a failure: the forfeit kills one loop while
the other is still waiting on an exchange, and the `Future.wait(...).timeout()` reports
the timeout, not the `StateError` underneath. Any paired-session Mystery fixture needs
an earth-dominant supreme generation. The one here uses `fire, fire, fire, earth` —
one complete fire formula (the damage) plus an earth residual (the backing).

### Characterization corpus

`test/battle/engine/mystery_fizzle_characterization_test.dart` — 9 tests, all green
against the unfixed engine, pinning the bug as behaviour so the repair has something to
invert:

| # | case | pre-fix |
|---|---|---|
| 1 | unaffordable immediate Mystery | **BUG** — flag true, 4 damage, chain 2, refunded |
| 2 | control: same spell cast normally | fizzles correctly — no damage, chain 0 |
| 3 | control: affordable immediate Mystery | pays 21, deals 4, chain 2 |
| 4 | peer-owned unaffordable immediate Mystery | **BUG** — identical, via `_certifiedPeerCastSettlement` |
| 5 | unaffordable delayed declaration | **BUG** — queues anyway |
| 6 | that declaration fires next turn | **BUG** — full damage, never paid for |
| 7 | control: affordable delayed declaration fires | same damage |
| 8 | control: affordable delayed declaration queues + pays | 21 charged |
| 9 | control: out-of-range Mystery | correctly suppressed |

Cases 3, 7, 8 are deliberately *indistinguishable* from 1, 6, 5 downstream of the
conversion. That is the finding restated as a test: today the engine cannot tell an
affordable Mystery cast from an unaffordable one.

---

## M4.21, part 2 — the fix: Mystery cannot resurrect a fizzled cast (2026-08-23)

Characterization commit `577828c`. This section is the repair.

### The rule, restated as the thing the code now enforces

> Once canonical Phase-5 settlement marks a committed cast `fizzledForMana`,
> the cast is **spent**: the mana is refunded, no effect resolves, the chain regresses,
> and nothing is placed on the battlefield. Neither Mystery conversion nor delayed
> declaration may resurrect it.

### Two repairs, because there were two defects

**A. `turn_loop.dart` — `_verifyMysteryAction` carries the flag.**

```dart
  return SpellCastAction(
    spell: action.spell,
    targetHex: action.immediateTarget!,
    isPotent: action.isPotent,
    isVelocity: action.isVelocity,
    recall: action.recall,
  )
    // Settled at Phase 5, before this line. Carried, not recomputed. M4.21.
    ..fizzledForMana = action.fizzledForMana;
```

One cascade. **Carried, never recomputed** — and that word is the design decision, not a
stylistic note. Re-pricing here would create a *second* affordability oracle reading a
different moment than the first, which is precisely the asymmetry M4.10b spent a
milestone abolishing. There is one canonical verdict, made at Phase 5 from settled
state, and everything downstream transports it.

**B. `deterministic_resolution.dart` — a fizzled declaration queues nothing.**

```dart
  if (action.fizzledForMana) {
    _regressChain(actor);
    break;
  }
```

Placed at the top of the non-immediate `MysterySpellCastAction` branch, before the
`certifiedDeclaration` derivation and the `PendingDelayedSpell` write.

Two things it deliberately does *not* do:

* **It does not re-price at fire time.** The affordability question is asked once, on
  the declaration turn, and this is where that answer has to bite. Checking again three
  turns later would ask a different question — "can they afford it *now*" — of a
  caster whose pool has nothing to do with the commitment they made. Two checks is how
  two devices come to disagree.
* **It does not queue a visibly fizzled placeholder.** A pending orb that can never
  fire is a tell about the caster's mana, and withholding exactly that is what Mystery
  is for. Nothing goes on the board.

The chain consequence is `_regressChain` — the same call the ordinary cast path's
`enhancements.fizzle` branch makes. No Mystery-specific chain rule was invented; the
branch simply reuses the general one it was previously skipping.

### Why B is not fixed by A

Worth stating plainly, because "preserve the flag" sounds like it should cover both.
It does not. A non-immediate Mystery action passes through `_verifyMysteryAction`
**untouched** — there is nothing to preserve, the flag was already intact. B's defect
was on the *reading* side: `resolveActions` destructured four fields and never looked at
the fifth. Two different defects, one invariant, two edits.

### The conversion audit, preserved

| field | classification |
|---|---|
| `spell`, `isPotent`, `isVelocity`, `recall` | explicitly copied |
| `targetHex` | deliberately reconstructed from `immediateTarget` |
| `mysteryCommitment`, `immediateTarget`, `immediateNonce` | consumed by the conversion |
| `delayedOriginHex`, `delayedRange` | correctly null — same-turn cast |
| `conveyorDirection`, `isEfficiency` | not representable on a Mystery action |
| `handIndex` | **dropped, and left dropped** — see below |
| `fizzledForMana` | **was the accidental loss** — now carried |

**`handIndex` was not "fixed".** Every consumer runs upstream of the conversion:
`appendSpellProofTail` at encode time, `_advanceDrawState` in Phase 5 — both of which
read `input.action` specifically because the converted action has lost the distinction,
with a comment in `runTurn` saying so. Copying a field nothing reads buys nothing and
costs something: it is how the *next* audit of this constructor gets a false negative,
because a fully-populated rebuild looks safe whether or not it is. If a consumer appears
downstream of the conversion, add it then. The audit is recorded here so that decision
is visible rather than merely absent.

### Version: engine 3 → 4

`kBattleEngineVersion` **3 → 4**. `kRulesetVersion` stays **3**;
`kBattleProtocolVersion` stays **5**.

The gate's test is not "did we fix a bug" but "can two builds compute a different
canonical `BattleState` from an identical transcript". They demonstrably can. The same
`0x03` action bytes, the same proofs, the same VK: a v3 build applies the spell's
damage, advances the caster's chain, and (for the delayed variant) writes a
`PendingDelayedSpell`; a v4 build suppresses all three. HP, `chainLengths` and
`pendingDelayedSpells` are all hashed by `BattleState.toCanonicalBytes`, so a mixed pair
desyncs mid-match on a state hash instead of being refused at the handshake.

Unlike v3, **the v3 behaviour here was well-defined** — both peers agreed, and agreed on
the wrong answer. That makes this a rules *correction* rather than a rules *supply*, and
it is why it needs an epoch rather than a patch note: an unpatched client is not merely
stale, it can cast for free.

Nothing in the proof path moved. The enhancement-backing check that certifies a Mystery
claim (`certifiedSupremeTags`, earth zone) is untouched, and so is the wire framing.

### Regressions

`mystery_fizzle_characterization_test.dart` keeps all nine fixtures; the five controls
are untouched and the four BUG cases have their expectations inverted:

| case | pre-fix | now |
|---|---|---|
| unaffordable immediate Mystery | 4 damage, chain 2, refunded | **no effect, chain 0, refunded** |
| ...peer-owned | 4 damage | **no effect** |
| unaffordable delayed declaration | queued a `PendingDelayedSpell` | **queues nothing** |
| ...and fired next turn | 4 damage, never paid for | **never fires** |
| control: same spell cast ordinarily | fizzles | unchanged |
| control: affordable immediate Mystery | 21 charged, 4 damage, chain 2 | unchanged |
| control: affordable delayed declaration | 21 charged, queues | unchanged |
| control: affordable delayed fire | 4 damage | unchanged |
| control: out-of-range Mystery | suppressed, still charged | unchanged |

Two tests are new. **`parity`** is the invariant in its shortest form: the same
unaffordable spell cast ordinarily and through Mystery, compared as whole outcomes
rather than field by field, so a consequence nobody thought to assert cannot diverge
unnoticed. Pre-fix these differed in HP, chain and pending spells.

The second guards repair B's `break`. It skips the rest of its `case`, and in Dart that
targets the switch rather than the `for (final (actor, action) in sorted)` around it —
but "the language says so" is a weaker guarantee than a fixture, and getting it wrong
would silently drop every action sorted *after* the fizzled one. So player_a's
declaration fizzles while player_b casts for real, and player_b's spell still lands.

### The replay: `mystery_fizzle_is_not_a_free_cast`

Added, because Mystery is natively expressible in the harness and the delayed half is
*only* visible across a turn boundary — this corpus's stated admission criterion. Four
turns, a 10-mana wizard, two 34-mana Mystery casts (one delayed, one immediate), and a
turn 2 that exists solely to be the turn the fire would have landed on. All four turns
golden to `pendingDelayedSpells: 0`, `resolvedSpells: 0`, both wizards at 24 HP and 10
mana.

The unit regressions assert the fields someone thought to name. The golden asserts the
**bytes** — the stronger claim for a bug whose whole signature was the absence of one.
The spell is `[fire, fire, fire, earth, earth, earth]`: two complete formulas (so
`spellFromElements`' whole-formula assertion holds), a fire triplet that would show as
HP loss if either repair regressed, and an earth triplet that backs the Mystery claim.

**No existing golden moved.** Nothing already in the corpus fizzles a Mystery cast, so
the fix is invisible to all nine prior transcripts — which is the evidence that it is
narrow.

### The fixture trap, repeated because it will catch the next person

A Mystery cast **is itself a cast-time enhancement claim**, and `PeerCastVerifier`
requires it to be backed by certified supreme dominance in the **earth** zone. A
synthetic proof with a pure-fire trajectory forfeits on `unbacked_enhancement_claim`
before anything under test is reachable — and it presents as a *hang*, not a failure,
because the forfeit kills one loop while the other waits on an exchange and
`Future.wait(...).timeout()` reports the timeout instead of the `StateError` underneath.
Any paired-session Mystery fixture needs an earth-dominant supreme generation.

### Audit: any remaining path where a fizzled cast can still act?

Grepping every read and write of `fizzledForMana` leaves four sites, and all four are
now closed:

* `_markFizzledForMana` — the only writer, reached only from the two settlement
  closures.
* `_verifyMysteryAction` — carries it (repair A).
* `resolveActions`' `SpellCastAction` case — reads it into `enhancements.fizzle`, which
  suppresses resolution and regresses the chain. This is the sole gate for every
  immediate cast, ordinary or Mystery-converted.
* `resolveActions`' `MysterySpellCastAction` case — reads it and declines to queue
  (repair B).

A delayed *fire* rebuilds a fresh `SpellCastAction` from its `PendingDelayedSpell` with
`fizzledForMana` defaulting to false, and that is correct: the affordability verdict was
consumed at declaration, and a record that fizzled never reaches the pending list to be
rebuilt from. Nothing else constructs a `SpellCastAction` from an action that could
carry the flag.

### Test results

* `mystery_fizzle_characterization_test.dart` — 11/11.
* Replay corpus — 3/3 (10 scripts; the nine prior goldens are byte-identical).
* Full `test/battle/` — 959/959.
* Full suite — 1770 pass, **2 pre-existing failures** in
  `test/ui/vocabulary_screen_test.dart` ("a too-short word is refused with a reason",
  "suggests a number of attunements per word, with no ceiling"). Verified pre-existing
  by stashing this change and re-running: they fail identically on the unmodified tree,
  in isolation, and touch no battle code. Not the rotating full-suite-load flake — these
  fail alone too.
* Analyzer — 39 issues, **identical to the pre-change baseline**, none in changed code.

### Still open

Unchanged by this slice and still outstanding: M4.19 (`isSummon` steering certified
chain affinity from a wire field), M4.20's contradictory-formula policy, and the
two-device hardware pass M4.10b left open — this work sits at integration-test level by
CLAUDE.md's verification hierarchy.

---

## M4.22 — A summon cast breaks lockstep the turn it is cast (characterized 2026-08-24)

**Status: characterized, NOT fixed.** Root cause proven and reproduced offline from the
exact shipped asset the hardware gate used. No `lib/` change made.

### The hardware evidence

`M4_engine_v4_two_device_gate_REPORT.md` (2026-08-23, commit 8ee51fc, engine v4,
Pixel 6 host + Linux desktop join): two Meditate turns held lockstep; an ordinary
Earthworks cast settled correctly on both devices; **casting Basic Windhound produced
"state hash mismatch on turn 3" every time** — with one summoner and with two, across
two independent matches. Proof verification succeeded before every divergence.

### Root cause: resolution reads a different element sequence on each device

`DeterministicResolution.resolveActions` looks up a cast's certified semantics as

```dart
final cert = delayedCertified[action] ?? certifiedPeerCasts[spell.commitmentHex];
```

`certifiedPeerCasts` is populated only by `TurnLoop._verifyPeerSpellCast`. **The
caster's own immediate cast is never in it.** So `certElementSequence` is null on the
caster's device and `applySpell` falls back to
`DeterministicResolution.elementSequence(spell)` — the authored `SpellAsset.formula`,
a wire field no proof attests — while the verifier resolves the same cast from
`TrajectoryParser.certifiedElementSequence` over the verified public outputs.

Between honest clients those two are supposed to be the same list. That assumption is
load-bearing and unenforced, and `assets/basic_spells/basic_windhound.json` violates it:

| | sequence |
|---|---|
| authored `SpellAsset.formula` (12) | air water earth air water fire air earth water fire air earth |
| certified trajectory (3) | fire water water |

**The certified side is correct.** `stepper.dart` — canonical per CLAUDE.md — replayed
over the asset's own `initialGrid` for its own `T=23` reproduces the proof's dominance
trajectory and supreme flags byte-for-byte and commits `[fire, water, water]`. The
commitment, `T`, `segmentCount` and `dotCount` all match the proof; only the authored
prose fields are wrong. No `T` in 1..48 on that grid produces the authored sequence, so
it came from a different grid or a pre-ink-substrate replay.

Origin of the bad content: `inscribeSpell` (lib/spells/inscribe.dart) takes `formula`,
`supremeTags` and `manaCost` as **caller-supplied arguments** and never checks them
against the proof it has just generated and self-verified. `main.dart` passes
`_formulaTracker.committed` from the live UI session. A stale tracker is persisted
verbatim, survives `scripts/export_basic_spells.dart` (which copies the field through by
design), and ships.

### The first canonical field to diverge is mana, not the minion

`wireBaseManaCost` counts effects from the authored formula (4 formulas → ×1.5³);
`PeerCastVerifier.certifiedBaseManaCost` counts them from the certified one (1 formula →
×1.5⁰). Base is `5×0 + 8 = 8`, grown by `1.05^23`:

* caster charges itself **83**
* verifier charges the caster **25**

`BattleState.toCanonicalBytes` writes `WizardAvatar.mana` in the avatar block, at **byte
offset 56** — `0x00000011` (17) against `0x0000004b` (75) from a 100-mana start. The
minion block is ~200 bytes further on. Everything after is downstream: chain affinity
(air vs water), the creature's stat block (3 HP air hound vs 0 HP water hound — the
latter reaped on spawn, so the verifier ends the turn with **zero** minions), and the
opponent's HP once the surviving hound attacks.

### Minion.id / RNG position is NOT the cause

Traced with temporary instrumentation on `HashRng` (since reverted). Single-summon turn,
both devices combined: 3 draws.

```
nextInt(2^30) -> 69911839   _castSummon <- applySpell          [caster]
nextInt(1)    -> 0          _nearestEnemyEntity <- _creatureTurn <- resolveSummonActions
nextInt(2^30) -> 69911839   _castSummon <- applySpell          [verifier]
```

Both devices draw the minion id at the **same RNG position and get the same value**;
the ids are identical. The extra `_nearestEnemyEntity` draw is the caster's surviving
hound taking its Phase-5b action — a *consequence* of the divergence, not a cause, but
it does mean the two RNG streams are at different positions from that point on, which
would desync subsequent turns independently.

Double-summon turn: 4 draws, 2 per device, pairwise identical. RNG stays in lockstep in
both cases.

### Why single and double summon both fail

The gate report's hypothesis — that a double summon cancels the local-vs-peer asymmetry
because each device runs one of each — was never valid. `toCanonicalBytes` encodes mana
**per player**, so the two devices **cross** rather than cancel:

| | device A | device B |
|---|---|---|
| player_a mana | 17 (local, authored) | 75 (peer, certified) |
| player_b mana | 75 (peer, certified) | 17 (local, authored) |

Mirrored, never equal — exactly the mirrored hashes the hardware showed. Canonical
resolution order (group → T → commitmentHex → playerId) is identical on both devices, so
both resolve the same cast first; each simply resolves its *own* cast from wire data and
the *peer's* from certified data.

### What the offline harness was missing

`certified_cast_fixture.dart`'s `spellFromElements` derives the wire `formula` **from**
the element list its synthetic proof attests, and computes `manaCost` from the same list.
Every fixture spell is honest by construction, so no `TurnSessionPair` script could ever
exercise the divergence. Nothing about real proofs, joint entropy, leyline seeds,
transport ordering or Pixel-vs-Linux runtime was involved — the harness models all of
those adequately. The one thing it could not model was a spell asset that lies about
itself.

Importing the real asset closed the gap: driving `assets/basic_spells/basic_windhound.json`
through the existing `TurnSessionPair` reproduces the hardware failure exactly, with no
fuzzing and no new harness machinery.

### Library audit

Scanned every asset in `~/Documents/spells` with proof bytes: **7 consistent, 2
mismatched** — "Basic Windhound" (shipped) and "Doggy". "Doggo", a tier-48 summon, is
consistent, so this is not "all summons". For "Doggy" the certified sequence is a strict
subsequence of the authored one (authored over-commits activations).

### Tests

* `test/battle/engine/peer_summon_replication_test.dart` (the M4.16 regression) —
  **strengthened**. It asserted only `minions.hasLength(1)` per device, which cannot see
  a creature that replicates with a divergent id/position/HP/affinity/stats/abilities/
  personality/size. It now also compares every canonically-hashed `Minion` field
  field-by-field and compares `toCanonicalBytes()` across the pair — the exact
  comparison `_exchangeStateHash` performs. **Still green**, as expected: its fixture
  spell is honest. Kept regardless; the hole must not silently reopen.
* `test/battle/engine/m422_summon_desync_characterization_test.dart` — NEW, 4/4 green.
  Pins the content defect, the stepper-vs-proof agreement, the single-summon desync
  (including the mana values and the verifier's empty minion list), and the crossed
  double-summon mana. **These assert the broken behaviour and must be inverted by the
  fix.**
* `test/battle/engine/simultaneous_summon_desync_repro_test.dart` — kept, header updated
  to record that both variants remain green and why, and that its "cancels out"
  hypothesis is wrong.
* Full `test/battle/` — **965/965**.
* No `lib/` file modified.

### Recommended repair (not implemented)

Two defects, two repairs, smallest first:

1. **Content (immediate, no version bump).** Regenerate `formula`, `supremeTags` and
   `manaCost` for `basic_windhound` from its own proof, and add a build-time assertion
   to `scripts/export_basic_spells.dart` that refuses to export any spell whose authored
   fields disagree with `PeerCastVerifier.semanticsOf` on its own proof bytes. This alone
   makes the hardware gate pass. It is a data change, not a rules change: no transcript
   currently accepted by engine v4 resolves differently, so **no `kBattleEngineVersion`
   bump**.

2. **Engine (the actual hole).** Have the caster resolve its own immediate cast from
   `certifiedFromProofBytes(spell)` — the seam already exists and the Mystery declaration
   path at `deterministic_resolution.dart:2769` already uses it — instead of falling back
   to the wire formula, and price it from the same source. That makes authored `formula`
   presentational everywhere and removes the whole class of defect, including the sibling
   `manaCost` field. It **does** change canonical resolution of transcripts v4 accepts
   (any spell whose authored fields drifted), so it requires **`kBattleEngineVersion`
   4 → 5**. No ruleset or protocol bump: the CA rules and the wire format are unchanged.

Repair 2 subsumes repair 1 semantically but not operationally — the shipped asset's
83-mana price and its air-hound artwork are player-visible, so the asset should be
regenerated either way.

Note this is adjacent to but distinct from **M4.19** (`isSummon` and `summonPersonality`
authored rather than certified). M4.19 was *not* a contributor here: both devices read
the same wire values for those two fields, so they agreed. Repair 2 would leave M4.19
exactly as it is.

---

## M4.22 — FIXED (2026-08-24). Engine v5: one proof, one meaning, both devices

**Status: fixed.** Two repairs — content and engine — landed together.
`kBattleEngineVersion` 4 → 5. `kRulesetVersion` stays 3,
`kBattleProtocolVersion` stays 5, no circuit or framing change.

### Repair 1 — content (no epoch)

`assets/basic_spells/basic_windhound.json` regenerated from its own proof:

| field | before | after |
|---|---|---|
| `formula` | air water earth air water fire air earth water fire air earth (12) | fire water water (3) |
| `supremeTags` | {air, earth} | {fire, water} |
| `manaCost` | 83 | 25 |

`initialGrid`, `t` (23), `commitmentHex`, `proofBytesBase64`, `spellHashHex`,
`id`, `segmentCount` (0), `dotCount` (8), `isSummon` and `summonPersonality`
are byte-identical. Regenerating input data cannot change how an identical
transcript is interpreted, so this half needs no version bump.

Two consequences worth knowing about, both of them the *correction* rather than
a side effect:

* **Windhound is now a Cantrip.** `kinKey` is derived (never persisted) from
  `formula` + `manaCost`, and a 3-element trajectory is under
  `kKinshipMinElements` (9). The peer's verifier already treated it as one —
  `certifyPeerCast`'s duplicate-grid exemption reads the CERTIFIED element
  count — so this only makes the local view agree with the remote one.
* **Its eligible enhancements changed** from Velocity/Mystery (air/earth) to
  Potency/Efficiency (fire/water). The old tags were unbacked: picking one
  would have been rejected by the peer as `unbacked_enhancement_claim`. The fix
  removes a live forfeit path.

The same audit over `~/Documents/spells` found **four** inconsistent assets, not
the two the characterization reported — the earlier pass compared only
`formula`. "Doggo" and "boom" have correct trajectories and stale prices (139 vs
93, 100 vs 67 — each exactly one extra ×1.5), which is the pre-2026-07-29
`(activations − 1) ~/ 3` effect-count bug still sitting in assets inscribed
before it was fixed. All four were repaired in place. None of them is a repo
asset, so no shipped regression can pin them.

### Repair 2 — the engine authority boundary (engine v5)

`DeterministicResolution.resolveActions` now branches on ownership, exactly as
the Mystery declaration path already did:

```dart
final cert = delayedCertified[action] ??
    (ctx.host.isLocalPlayer(actor.playerId)
        ? ctx.host.certifiedFromProofBytes(spell)          // own proof bytes
        : certifiedPeerCasts[spell.commitmentHex] ??       // real verification
            ctx.host.certifiedFromProofBytes(spell));      // unwired: parse
```

Ownership rather than map presence, because the map is keyed by commitmentHex
and the commitment is grid-only: a peer casting the same grid this turn would
otherwise hand the local caster the peer's certified entry.

**The trust roles stay distinct.** `certifiedFromProofBytes` parses WITHOUT
verifying, which is right for bytes this device authored and would be wrong for
a peer's. The peer branch still reads what `PeerCastVerifier` actually verified;
its parse fallback is only reached in the pre-existing `PeerCastUncertified`
case (solo, no verifier/VK wired) where it is no weaker than the wire formula it
replaces. No `certified: bool` API was introduced.

Pricing was threaded the same way. `CertifiedCast` gained `baseManaCost`, so the
price and the trajectory are two readings of one proof that cannot be sourced
separately; `spellCostBreakdown` / `applySpellManaCost` take an optional
`certified` and prefer it for the base, the chain affinity and the expected
recital; `TurnLoop._localCastSettlement` derives it once and hands the same
value to both the fizzle preview and the charge; `previewSpellCost` uses it too,
so the UI quote and the deduction still cannot disagree.

`wireBaseManaCost` survives as the proofless-only fallback and says so.

### Windhound, before and after

| | before (v4) | after (v5) |
|---|---|---|
| caster charges itself | 83 → mana 17 | 25 → mana 75 |
| verifier charges caster | 25 → mana 75 | 25 → mana 75 |
| caster's creature | 3 HP air hound | none (0 HP water hound, reaped on spawn) |
| verifier's creature | none | none |
| `toCanonicalBytes()` | differ at byte 56 | equal |
| turn outcome | "state hash mismatch on turn 3" | clean |

Double summon: was (a=17, b=75) against (a=75, b=17) — mirrored, never equal.
Now 75 across the board on both devices.

### Proofless behaviour

`kAllowProoflessSpells` is untouched and still `false`. `_isProoflessBypass` is
`allowProoflessSpells && spell.proofBytes.isEmpty`, so a proof-backed cast can
never take it. After this change the authored fallback in pricing and resolution
is reachable **only** when `certifiedFromProofBytes` returns null — empty or
malformed proof bytes — which both devices see identically. It is no longer
reachable for a normal proof-backed production cast, which was the point.

### M4.19 deliberately unchanged

`isSummon` and `summonPersonality` remain authored and unbound.
`summon_declaration_trust_test.dart` still passes unmodified. They were never a
contributor here — both devices read the same wire values for them, so they
agreed — and this repair concerns formula/element/base-cost semantics that were
already available from proof bytes.

### Content gate

* `lib/spells/spell_asset_integrity.dart` — the shared derivation. Deliberately
  Flutter-free, which forced a small split: `VerifiedSpellOutputs`, the
  exception and the pure ABI parser moved to
  `lib/battle/engine/proof_outputs.dart`, re-exported from `proof_intake.dart`
  so no importer changed. `proof_intake.dart` reaches `ProofVerifier` and
  `initSrsCached` and therefore `dart:ui`, which `dart run` cannot load.
* `scripts/export_basic_spells.dart` — validates all five selections BEFORE
  writing any of them, and exits 1 on a mismatch. Verified against the pre-fix
  Windhound: it refuses, prints the three offending fields, and leaves
  `assets/basic_spells` untouched.
* `scripts/audit_spell_assets.dart` — audits (`--fix` repairs) a directory or a
  file. Repairs only the three derivable fields, preserves the file's existing
  JSON style, and REFUSES an asset whose proof disagrees with its identity.

### Tests

* `m422_summon_desync_characterization_test.dart` — **inverted**, 5/5. The
  hardware-input offline reproduction is kept as a permanent regression: both
  devices charge 25, both resolve fire/water/water, minion fingerprints agree,
  `toCanonicalBytes()` agrees, and the double-summon table is 75 across.
* `authored_spell_field_trust_test.dart` — the ordinary-cast test **inverted**
  (it used to assert "the caster resolves its own authored wire formula" as the
  property under test) and extended into M4.22's **non-summon** adversarial
  regression: a proof certifying all-earth against an authored `water, water,
  fire` Clouds formula now stays in lockstep, creates no cloud on either device,
  and produces canonical state byte-identical to its honest twin. 27/27.
* `test/spells/spell_asset_integrity_test.dart` — NEW, 10/10. Positive corpus
  (every shipped basic clean, zero mismatches) paired with its negatives: the
  audit REPORTS the pre-fix Windhound's three fields, reports a Doggy-shaped
  strict-subsequence mismatch, flags an identity fault and refuses to repair it,
  audits a proofless spell clean, throws on unparseable bytes, and pins that
  `repairSpellJson` rewrites exactly three keys. Also pins that the audit, the
  verifier and the local mirror agree on the base price, and that the
  duplicated tier table matches `tierForSteps` across 1..48.
* `peer_summon_replication_test.dart` — M4.16's strengthened assertions kept
  as-is, still green.
* Replay corpus — **all 10 goldens byte-unchanged.** Every replay script builds
  its spells with `spellFromElements`, which derives the wire `formula` FROM the
  element list its synthetic proof attests, so they are honest by construction
  and the certified sequence the local path now reads equals the authored one it
  used to. That is also exactly why no `TurnSessionPair` script could ever have
  caught this bug — the one thing the harness could not model was a spell asset
  that lies about itself.
* `test/battle/` 967/967. Full suite 1789 passed, 2 failed —
  `test/ui/vocabulary_screen_test.dart` ("a too-short word is refused with a
  reason", "suggests a number of attunements per word, with no ceiling"),
  **pre-existing**: both fail identically with this work stashed, and neither
  touches anything in it. Not the known full-suite UI flake — these fail in
  isolation too.
* `flutter analyze` — 39 issues, down from a 43 baseline: the four
  `invalid_return_type_for_catch_error` warnings the characterization commit
  introduced are fixed by a shared `collectError` helper in
  `certified_cast_fixture.dart`. The one remaining warning
  (`spell_test_lab_screen.dart` unused parameter) predates this work.

### Still authored, and why that is acceptable

Three UI reads of `SpellAsset.formula`/`supremeTags` were left alone. None can
cause a silent divergence — the engine is authoritative and identical on both
devices — and the corrected content makes all three agree today:

* `battle_screen.dart:1425` — the enhancement picker gates on
  `spell.supremeTags`. An unbacked pick is rejected by the peer as
  `unbacked_enhancement_claim`, i.e. a clean forfeit, not a desync. Deriving it
  would mean adding supreme tags to `CertifiedCast`, which is a wider change
  than this slice.
* `battle_screen.dart:1286` — `_expectedElementCount` tells the player how many
  words the incantation wants. The engine now scores recall against the
  certified sequence on both devices, so a drifted asset would mislead the
  player without desyncing anyone.
* `battle_screen.dart:200` — `spellNeedsConveyorDirection` decides whether to
  prompt for a push direction. Both devices read the same transmitted
  direction, so a spurious or missing prompt is a UX artifact only.

Also still authored, by design and out of scope: the wire encoding of
`spell.formula` (`battle_wire_codec.dart`), trade/apprentice transfer metadata,
and every card-art / library / sound read.

---

## M4.22 — two-device hardware gate on engine v5 (2026-08-24) — PASS

Pixel 6 (`<device serial redacted>`, oriole, Android 17) host + Linux desktop join, both
from `cb996b1`, driven over `adb shell input` + `xdotool`. Ground truth read
from the UI and from `logcat`/stdout, not inferred.

### The three checks

| check | result |
|---|---|
| one Basic Windhound summon | **PASS** — both peers MP 25/75, no minion, turn advanced |
| both players summon Windhound | **PASS** — both peers MP 25/25 (symmetric, not crossed) |
| v4 ↔ v5 handshake negative control | **PASS** — refused at handshake |

Each was run twice: once with the Pixel still holding the **stale** asset and
Linux the repaired one (the harder case — divergent authored metadata,
byte-identical proofs), then again with both repaired. Identical results.

The negative control produced exactly the intended refusal, from
`duel_setup.dart:203`, before any turn ran:

```
Duel setup failed: Bad state: battle engine version mismatch (local=5, peer=4) — match aborted
```

### The decisive evidence for repair 2

Not the mana — the **chain affinity**. `_updateChainState` keys a summon's chain
on `CreatureSpec.fromElements(...).affinity`. The certified sequence
[fire, water, water] is **water**; the stale authored sequence opens on **air**.
On the run where the Pixel still held the stale asset, the Pixel's own status
line read **"Water ×1 (−10%)"** — the caster built a water chain from an asset
whose own file says air. That is the local device resolving its own cast from
its own proof bytes, observed on hardware.

Both peers also ended with **no minion**, exactly as the offline regression
predicts: the certified creature has 0 HP and is reaped on spawn. Under v4 the
caster would have kept a 3 HP air hound.

### NEW FINDING 1 — the content repair does not reach existing installs

`seedBasicSpells` matches by `spellHashHex` and never overwrites an existing
file. The repair deliberately preserved `spellHashHex` (Poseidon2(commitment,
T) — neither changed), so **the corrected asset is inert on any device that has
already seeded**. The Pixel still held the 83-mana Windhound from its
2026-08-23 seed.

Neither escape hatch works:

* bumping `kBasicSpellSetVersion` does **not** help — the per-`spellHashHex`
  existence check skips the file regardless of the marker;
* Library → "Restore basic spells" (`force: true`) does **not** help — same
  check.

Nothing in the test suite could see this: the suite and the audit both read the
**bundle**, not device state. Engine v5 makes it harmless for lockstep (both
devices resolve from proof bytes either way), so this is a content-freshness
bug, not a desync — but it is real and unfixed. A migration would need to
compare the on-disk asset against its own proof and rewrite the three derived
fields, which is exactly what `scripts/audit_spell_assets.dart --fix` does
off-device.

### NEW FINDING 2 — a stale asset offers enhancements its proof cannot back

With the stale asset the Pixel's cast-time enhancement picker offered
**Velocity** and **Mystery** (authored `supremeTags` {air, earth}) and greyed
out Potency/Efficiency. The proof certifies {fire, water}. Picking either
offered enhancement would have been rejected by the peer as
`unbacked_enhancement_claim` — a clean forfeit, not a desync, but a live
forfeit path reachable by an ordinary player on an un-migrated install.

After the asset was repaired on the Pixel the picker offered **Potency** and
**Efficiency** on both devices, matching the certified tags, and the
best-case price shown on the card changed from 25 to 17 (the Efficiency −1/3 it
had genuinely earned all along).

This is the `battle_screen.dart:1425` authored read flagged in the M4.22 report
as "cannot desync". That assessment holds — but it understated the cost:
combined with Finding 1 it is reachable in normal play.

### Presentation reads confirmed on hardware

The summon preview on the cast bar reads the **authored** formula. With the
stale asset the Pixel advertised "Air Creature · HP 3 · DMG 1 · Move 2 · Range 1"
while quoting the proof-derived "25 mana" and resolving a water 0 HP creature;
Linux's repaired copy correctly read "Water Creature · HP 0 · DMG 0 · Move 0 ·
Range 0". Both devices resolved identically regardless. After repair the two
UIs were identical.

### Incidental

* Linux still cannot advertise over mDNS ("Automatic discovery isn't available
  here") — the known nsd gap, out of scope for M4.22. The manual-address
  fallback carried every join.
* Test scaffolding left in place: a "Hound Only" chapter (one Windhound, no
  artifacts) on each device, used to make both hands deterministic at hand
  size 1. The Pixel's stale asset was backed up before repair.

---

## M4.22 follow-ups — DEFERRED, not engine-v5 gate blockers

Both were found by the 2026-08-24 two-device hardware gate. Neither blocks the
engine-v5 gate: v5 remains canonical and lockstep-safe, because both devices
resolve and price a proof-backed cast from proof bytes regardless of what the
authored caches say. Logged here so they are picked up as their own work.

### M4.22-F1 — installed basic spells are not refreshed when bundled derived metadata changes

`seedBasicSpells` (lib/spells/basic_spell_seed.dart) skips any spell whose
`spellHashHex` is already on disk and **never overwrites**. `spellHashHex` is
`Poseidon2(commitment, T)`, and a metadata-only repair changes neither — so a
corrected bundle is inert on every already-seeded install.

Neither existing lever helps: bumping `kBasicSpellSetVersion` only clears the
marker gate, and Library → "Restore basic spells" passes `force: true`, but both
still fall through the same per-`spellHashHex` existence check.

Invisible to the whole test suite, because the suite and
`scripts/audit_spell_assets.dart` read the **bundle**, never device state.

Shape of a fix: an on-device migration that audits each installed asset against
its own proof and rewrites `formula` / `supremeTags` / `manaCost` in place —
what `audit_spell_assets.dart --fix` already does off-device — keyed on a
migration version rather than on `spellHashHex`. Identity, grid, proof bytes and
the summon declaration must stay untouched.

### M4.22-F2 — UI enhancement eligibility and creature preview still read authored caches

Two proof-backed reads were left authored by M4.22 and are now confirmed
player-visible on hardware:

* `battle_screen.dart:1425` gates the cast-time enhancement picker on
  `SpellAsset.supremeTags`. On a stale asset it offered **Velocity/Mystery**
  ({air, earth}) for a spell certifying {fire, water}. Claiming either is
  rejected by the peer as `unbacked_enhancement_claim` — a clean forfeit rather
  than a desync, but reachable in ordinary play on an un-migrated install.
* the cast-bar summon preview reads the authored formula, so a stale asset
  advertised "Air Creature · HP 3 · DMG 1 · Move 2 · Range 1" while the engine
  resolved a water 0 HP creature and the price line correctly said 25.

Both are presentation/eligibility only — resolution is unaffected and identical
on both devices. Fixing F1 removes the practical exposure; fixing F2 properly
means deriving supreme tags and the creature summary from proof bytes, which
implies carrying certified supreme tags on `CertifiedCast`.
