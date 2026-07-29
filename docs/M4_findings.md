# M4 — Findings Log (live, updated per milestone)

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
