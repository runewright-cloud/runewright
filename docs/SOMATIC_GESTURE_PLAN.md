# Somatic Gesture Capture & Calibration — Implementation Plan

*Proposed 2026-07-21 on `feature/practice-mode`. Companion to `SORCERER_REALTIME_PLAN.md`
§5.2 (somatic = enhancement selection) and the Practice-Mode vocal discipline. This is the
build spec for **SORC.5 (gesture classifier)** and the capture tool that must precede it.*

*Design lineage: this mirrors the vocal pipeline deliberately. Where a vocal decision was
paid for once and written down (`docs/M4_findings.md` 2026-07-16), the somatic twin inherits
it. Read that entry before touching scorer constants.*

---

## 0. Design stance (why strict is correct, not a limitation)

Casting gesticulation is *meant* to be difficult, nuanced, and hard to learn — that's the
genre flavor and it's mechanically load-bearing here. So the calibration posture is the same
as vocal: **never false-advance.** A sloppy or ambiguous gesture falls to **neutral** (cast
with no enhancement); it never grants an enhancement the player didn't clearly earn. Mastery
is visibly rewarded; imprecision costs a buff, never the match. Every error margin in §6 is
tuned to land on the *safe* side of that line.

There will always be residual error (§6.4) — no threshold makes the confusion matrix perfectly
diagonal. The goal is not zero error; it is (a) errors that land on the neutral/safe side and
(b) a measured operating point, not a discovered one.

---

## 1. Scope

**In scope (this plan):**
- A **hold-to-record capture window** control, shared by the enrollment tool *and* the live
  cast seam (identical segmentation on both paths — non-negotiable, see §7).
- Raw IMU capture + a committed **fixture corpus** (the SORC.4 discipline).
- A **per-user enrollment** flow (record each gesture; your motion becomes the template).
- A **GestureScorer**: stillness gate → open-set DTW match → contrastive margin → neutral.
- A **calibration harness** producing a confusion matrix (the golden-corpus analog).
- Wiring the certified **eligibility downgrade** (§5) into the existing cast flow.

**Out of scope (do not build here):**
- Melee *action* resolution and real-time movement mode — melee gestures are **captured** into
  the corpus now (forward-looking), but their in-game wiring belongs to the real-time-mode
  milestone, not this pass.
- Velocity (Air) and Mystery (Earth) gesture *choreography* — `[DECISION — needs Soren]` per
  SORCERER_REALTIME_PLAN §5.2. All five gestures ship together (§3) — not phased.
- Any change to the **vocal** capture window or its calibrated constants (§7 caution).
- Multiplayer/real-time tick integration (that's the sorcerer-realtime plan).

---

## 2. Prerequisite: sensor dependency

`pubspec.yaml` has no motion plugin today (only `record` for audio). Add:

```yaml
  sensors_plus: ^<latest 6.x>
```

`sensors_plus` gives `accelerometerEvents` (includes gravity), `userAccelerometerEvents`
(gravity removed), and `gyroscopeEvents`. We capture **userAccelerometer + gyroscope** (see
§4). **Gotcha:** `flutter pub add` can exit 255 under the snap environment — see M4_findings
toolchain notes for the workaround (edit `pubspec.yaml` by hand + `flutter pub get`, retry).

No DTW or FFT library is added. DTW is a small hand-rolled routine (§6.2); v1 is time-domain
only. `fftea` is a *possible* future dep if frequency features prove necessary — not now.

---

## 3. Vocabulary and the enum reconciliation (do first — SORC.0)

The classifier is **open-set**: it recognizes a small closed set, and everything else →
neutral. Recognized set — all five ship together, not phased
(`[RESOLVED — Soren, SORCERER_REALTIME_PLAN.md §10.2]`; an earlier draft of this table
phased fire+water+melee ahead of air+earth as pending-choreography, which was already
stale against Soren's answer there):

| Gesture | Selects | Notes |
|---------|---------|-------|
| `fire`  | Potency (enhancement)   | |
| `air`   | Velocity (enhancement)  | |
| `water` | Efficiency (enhancement)| |
| `earth` | Mystery (enhancement)   | |
| `melee` | nothing (action, not an enhancement) | wiring belongs to the real-time-movement milestone, not this pass (§1) |

Choreography for all five is Soren's own performed baseline — captured via the
enrollment tool (§8), not specified in writing here. The capture *is* the choreography
spec.

`neutral` is **not a learned template** — it is the reject class (stillness *or* no confident
match; §6). Do not enroll a "neutral gesture."

**Enum reconcile — DONE:** `lib/sorcerer/gesture.dart`'s `Gesture` enum is now
`{fire, air, water, earth, neutral, melee}`, still mapping to *elemental zones*.
Enhancements map through `enhancement_zone.dart` (fire=Potency, air=Velocity,
water=Efficiency, earth=Mystery) — the elemental names carry through cleanly, so the
enum was kept as-is rather than renamed. `melee.enhancementZone` returns `null` (not an
enhancement); `neutral` remains the reject/default sentinel.

---

## 4. Signal & features

- **Capture raw, derive features offline.** Log timestamped `userAccelerometer` (x,y,z) +
  `gyroscope` (x,y,z) at the highest steady rate the device gives (target ~50–100 Hz;
  record the actual rate in the fixture). **Never store only a derived summary** — raw logs
  are the corpus and let features be re-derived without recapture.
- **v1 feature frame** (per sample, after resampling to a fixed rate): `[ax, ay, az, gx, gy,
  gz]` low-pass smoothed, plus per-frame magnitude. Time-domain only.
- **Do NOT average raw traces.** Reps are not time-aligned; element-wise mean of misaligned
  time-series is mush (the somatic analog of the floor-only MFCC bug). Keep the N reps as a
  **template set** and match by DTW distance to the nearest rep. If a single representative is
  ever needed, use DTW-barycenter averaging (DBA), never arithmetic mean.

---

## 5. Trust boundary (the load-bearing part)

The gesture is a **self-attested sensor claim** — the protocol cannot verify you actually
moved, and that is fine (SORCERER_REALTIME_PLAN §8; shouting-distance social policing). It is
safe *because it only ever reduces to neutral* — it can never grant unearned power.

The **enhancement it selects is certified.** Supreme/torrential dominance is
`supreme_dominance_flags[]`, a **proof public input** (`lib/protocol/proof_wire.dart`). Two
layers, both required, and they compose — do not collapse them:

1. **Client-side downgrade (this plan adds):** before anything hits the wire, if the recognized
   gesture's zone is not in the spell's certified supreme-tags, resolve to **neutral** and send
   no enhancement claim. This is the "hasn't unlocked the flag → neutral" behavior.
   **Gate this on `spell.supremeTags`** — the same field the existing wizard-mode enhancement
   picker already gates on (`enhancement_zone.dart`'s own comment: "Eligibility itself is
   SpellAsset.supremeTags"; `battle_screen.dart`'s `_EnhancementPicker`). *Not* a re-verified
   `TrajectoryParser.certifiedSupremeTags(outputs)` — no `VerifiedSpellOutputs` object exists
   locally at cast time (that's the peer's-side artifact, built from parsing the *received*
   wire proof); re-deriving one here would mean re-verifying your own proof for no benefit.
   `spell.supremeTags` is provably equivalent: it's backfilled by `deriveSupremeTags()`
   replaying the exact same Dart stepper the proof attests over the exact same
   `initialGrid`/`t` that was proven, so it can't diverge from what the peer will certify. One
   source of truth, shared with the existing picker — not a second, parallel eligibility path.
2. **Peer-side forfeit (already exists, unchanged):** `turn_loop.dart:3242-3270` forfeits on an
   `unbacked_enhancement_claim`. Honest clients self-downgrade and never trip it; it is the
   backstop for modified clients that don't. **Do not weaken this to a silent downgrade** — a
   claim arriving over the wire without certified backing is still cheating.

Melee is an action, not an enhancement: no supreme-dominance gate; it is gated by whatever the
real-time melee rules impose (out of scope here).

---

## 6. The GestureScorer pipeline

Order matters — cheapest, most-reliable gate first. Neutral is the universal safe sink.

```
capture window (hold) → resample → feature frames
  ├─ (6.1) stillness floor:  windowed energy < FLOOR      → neutral   [skip DTW]
  ├─ (6.2) open-set match:   DTW to each gesture's rep set
  ├─ (6.3) accept rule:      best < CAP  AND  (2nd-best − best) > MARGIN
  │                          else                          → neutral
  ├─ (§5) eligibility:       zone ∉ certifiedSupremeTags   → neutral
  └─ apply enhancement
```

### 6.1 Stillness / energy floor (run first)
Scalar threshold on windowed variance of `userAccelerometer` (+ gyro magnitude). Below floor =
holding steady = neutral; skip DTW entirely. **FLOOR must sit above sensor noise + hand tremor
+ breathing micro-motion**, measured from the "hold steady" confusable (§8), with margin. This
is the direct twin of the vocal min-audio + energy gate.

### 6.2 DTW matching
Hand-rolled DTW (Sakoe-Chiba band to bound cost) between the query feature sequence and each
stored rep; per-gesture score = min distance over that gesture's rep set. Small N, small
frames — cheap.

### 6.3 Open-set accept rule (mirrors the vocal 4-condition crossing rule)
Accept the argmin gesture **only if** both:
- **absolute cap:** `best_distance < CAP` (rejects motion far from every template), and
- **contrastive margin:** `second_best − best > MARGIN` (rejects motion ambiguous between two).

Otherwise → neutral. This is what turns theatrical flourish and half-formed gestures into
safe no-ops.

### 6.4 On residual error (expected, by design)
`CAP`/`MARGIN` never eliminate error — they place it. Tune strict: accept more "real gesture →
neutral" (missed buff) to drive "wrong gesture → wrong buff" toward zero. Margins are also
**per-user and drift within a user** (fatigue, grip); enrollment removes cross-user error but
not intra-user drift — `MARGIN`/debounce absorb some, the neutral fallback makes the rest
tolerable. Quantify it in §9; don't chase zero.

### 6.5 Constants
`FLOOR`, `CAP`, `MARGIN`, DTW band width, resample rate, debounce — **all grid-searched through
the §9 harness, none invented.** Mirror the vocal `floor / margin / debounce` provenance.

---

## 7. The capture window (shared control — the key architectural rule)

Build **one** hold-to-record control (`onLongPressStart` → capture → `onLongPressEnd`) and use
it in **both** the enrollment tool and the live cast seam. Rationale: segmentation is part of
the sensor path. If enrollment is press-delimited but live uses a fixed timer, templates are
cut differently than live gestures and every DTW distance is skewed. Press-and-hold also
bounds a variable-duration gesture to exactly when the player performs it — a cleaner DTW
segment than a fixed window.

- Live seam: `lib/ui/battle_screen.dart:851-859` (the stubbed `kSomaticCaptureEnabled` block,
  built to sit parallel to the vocal `beginCapture → endCapture` at ~840). Gesture capture runs
  during the hold and folds its result into the same `CastingEnhancements` the vocalScore
  feeds, and into the one `castCompleted` frame (SORCERER_REALTIME_PLAN §5.1).
- **CAUTION — do not touch vocal timing.** Vocal uses a fixed `_voiceCaptureWindow` whose
  constants were grid-searched against it (M4_findings 2026-07-16). Do **not** retrofit vocal
  onto the hold-window in this plan. Cleanest safe path: the gesture press-and-hold defines the
  *gesture* window; vocal keeps its window; both align to the same cast, both land in one frame.

---

## 8. Capture / enrollment tool

Mirror `lib/practice/vocal_enrollment.dart` exactly:
- `GestureEnrollment(baseDir)` with injectable `baseDir`; `open()` anchors under
  `<app documents>/gesture_enrollment/`. Local-only, never leaves device, consensus-invisible.
- Per-gesture JSON files, schema e.g. `{"rate": 60, "reps": [[[6 doubles per frame], ...], ...]}`.
- `GestureEnrollmentException` (user-presentable) for too-short / too-still captures.
- Same-device, same-plugin, same-window as runtime (the "capture through the same path"
  invariant, extended to segmentation).
- A `GestureTemplateSource` abstraction (twin of `VocalTemplateSource`) so scorer code is
  source-agnostic; per-user enrolled templates are the reference.

**Capture protocol (what the tool records):**
- Each recognized gesture **≥ 10 reps** (enough to *measure* intra-gesture variance, which sets
  `CAP`/`MARGIN`), not just 3–5. This is the **calibration** figure —
  `GestureEnrollment.corpusRepsForCalibration` — i.e. how much Soren records to *set* the
  thresholds. It is NOT what a player is asked for; see §8.1.
- **Confusables, explicitly** — these define the reject side of the matrix: hold-steady/idle,
  walking, the melee wind-up, and free theatrical/garbage motion. Without these the threshold
  cannot be set (the vocal lesson: silence must be *measured* to be rejected).
- All raw logs land in a committed corpus dir (twin of `test/practice/fixtures/`), doubling as
  the SORC.4 IMU fixture vectors.

### 8.1 How many attunements to ask a PLAYER for (measured 2026-08-06)

The §8 figure above answers "how big a corpus sets the thresholds?". It kept getting
misread as "how many reps does a player need?", which is a different question with a
different answer — a player is matched *against* thresholds already set, not helping set
them. `tool/gesture_rep_count_sweep.dart` measures the second question directly: real
`GestureClassifier`, real Pixel 6 corpus, leave-one-out, 12 random subsets per
enrolled-set size N, shipped constants.

| N | genuine accepted | **wrong gesture** | confusable false accepts | DTW pairs/cast |
|---|---|---|---|---|
| 1 | 65.5% | **0.3%** | 0% | 5 |
| 2 | 81.3% | 0% | 0% | 10 |
| 3 | 85.0% | 0% | 0% | 15 |
| **4** | **87.0%** | **0%** | **0%** | **20** |
| 5 | 88.0% | 0% | 0% | 25 |
| 7 | 89.8% | 0% | 0% | 35 |
| 9 | 90.0% | 0% | 0% | 45 |

**Ratified: `GestureEnrollment.suggestedReps = 4`**, surfaced on the Somatic tab as
"attunements". Two reasons, in order of weight:

1. **N=1 is the only size that broke §0's never-false-advance bar** (0.3% wrong-gesture
   accepts). A lone rep carries no intra-gesture variance, so a stray query can sit
   closer to a *different* gesture than to the single stored copy of its own. Every
   N ≥ 2 held at zero. This makes the suggestion a safety floor, not a preference — and
   `gesture_confusion_e2e_test.dart` now pins it ("the suggested attunement count clears
   the gate on a player-sized set") so it cannot drift as the corpus or constants move.
2. **The knee is at 3–4.** 1→4 buys 21.5 points of accept rate; 4→9 buys 3. Asking for
   more than 4 would trade real player effort for very little.

**No maximum, on quality grounds.** Accuracy is monotone non-decreasing across the whole
measured range (89.8 → 89.8 → 90.0 at the top) — more attunements never made recognition
worse. `maxRepsStored = 20` is therefore reframed as a **rolling FIFO window, not a
ceiling**: recording past it is always allowed and evicts the oldest rep, so the stored
set tracks how the player moves *now*. The window exists only to bound the per-cast path,
which is min-distance DTW over every stored rep of all five candidates — `5 × reps` pairs,
capped at 100.

The one thing that does degrade with more attunements is **imbalance between them**:
min-distance argmin is biased toward whichever class holds more exemplars. Both tabs tell
players to keep the counts roughly even.

---

## 9. Calibration harness (the gate — golden-corpus analog)

`test/sorcerer/gesture_confusion_e2e_test.dart` (twin of `real_template_e2e_test.dart`):
- Loads the committed corpus, runs the full pipeline (§6), emits a **confusion matrix** over
  {recognized gestures} × {gestures + all confusables + neutral}.
- **Gate conditions:** every gesture's own reps accept as itself; every confusable
  (idle/walk/melee-vs-enhancement/garbage) resolves to neutral or its own class; **zero
  wrong-enhancement false-accepts** (the strict, never-false-advance bar).
- Constants (§6.5) are grid-searched through this harness. Re-run after ANY constant or template
  change. A wrong-enhancement false-accept is a release blocker, exactly as a wrong-word vocal
  advance is.

---

## 10. Integration seams (exact touch-points)

- `lib/sorcerer/gesture.dart` — **DONE**: `melee` added, `neutral` sentinel kept;
  `kSomaticCaptureEnabled` flips **only** once GestureClassifier + a real-device harness pass
  exist.
- `lib/ui/battle_screen.dart:851-859` — real capture in the stubbed block; fold `Gesture` into
  `CastingEnhancements` parallel to `vocalScore`. **Not yet wired** — comment updated to point
  at the now-existing infra, capture itself still gated behind `kSomaticCaptureEnabled`.
- `lib/battle/models/casting_enhancements.dart` / `vocal_score.dart` — the reserved somatic byte
  (`0xFF` sentinel) is the wire slot; populate from the resolved (post-downgrade) gesture.
- `lib/battle/engine/turn_loop.dart:3242-3270` — **unchanged**; verify the client-side downgrade
  (§5.1) means honest clients never reach it.
- `spell.supremeTags` — the single source for the §5.1 downgrade (see §5's correction — not a
  re-verified `VerifiedSpellOutputs`, which doesn't exist locally at cast time).

---

## 11. Build order

1. **SORC.0** — enum reconcile (§3); add `sensors_plus` (§2); hold-to-record control (§7). **DONE.**
2. **Capture tool** (§8) — enrollment + raw logging; capture Soren's five gestures + confusables.
   **DONE** (`lib/practice/gesture_enrollment.dart`, `practice_screen.dart`'s Gesture tab) — the
   tool exists; Soren's actual reps are not yet recorded (needs a real device).
3. **Corpus commit** (§8/§9) — raw fixtures under the test tree. **DONE** (2026-07-28):
   `test/sorcerer/fixtures/corpus_pixel6/`, 10 reps each of the five gestures plus the three
   confusables, captured on a Pixel 6 at ~55 Hz.
4. **GestureClassifier** (§6) — stillness gate → DTW → accept rule → eligibility downgrade.
   **DONE** for the classifier itself (`lib/sorcerer/gesture_classifier.dart`); the eligibility
   downgrade is documented (§5) but not yet wired into `battle_screen.dart` (see step 6).
5. **Harness** (§9) — confusion matrix; grid-search constants to the strict bar. **DONE**
   (2026-07-28): `test/sorcerer/gesture_confusion_e2e_test.dart` is the real gate, run over the
   committed corpus with the shipped constants — zero wrong-gesture false accepts, 90% genuine
   acceptance. Constants were grid-searched via `tool/gesture_corpus_analysis.dart`, which is
   also where handedness, generalization and streaming-feedback studies live. See
   `docs/M4_findings.md` 2026-07-28 for the full write-up, including what did NOT work.
6. **Wire the seam** (§10); flip `kSomaticCaptureEnabled`; **real-device pass** (the hardware
   gate — a fixture harness calibrates, a real IMU + real hand validates, exactly as vocal
   still awaits its real-mic pass). **Outstanding** — deliberately not done without real
   hardware to validate against.

---

## 12. Open decisions for Soren `[DECISION — needs Soren]`

- ~~Velocity (Air) + Mystery (Earth) gesture choreography~~ — **resolved**: all five gestures
  ship together (§3), choreography is Soren's own performed baseline via the capture tool.
- ~~**Resample target rate**~~ — **resolved (2026-07-28): no resampling.** The device reports a
  steady ~55 Hz (not the 100 Hz `SensorsGestureCapture` requests). Fixed-length resampling was
  measured against the real corpus and gave no gain over plain unit-RMS normalisation — DTW is
  already time-warp invariant, as §4 assumed. `normalizeForMatching` smooths and normalises but
  does not resample.

- **Universal bundled templates vs per-user enrollment** `[DECISION — needs Soren]` — the
  direction is universal gestures players are *taught*, with a haptic trainer, rather than
  per-user enrollment. Held-out probes are encouraging (100% across a real style shift) but
  cannot test grip orientation, the dominant cross-person variable; the vocal precedent
  (same-voice 5/5 vs cross-voice 2/5) is a warning. **Gate: capture 2–3 other people, 10 reps
  each (~10 min each).** Universality fails safe — a stranger's rendition falls to `neutral`,
  never to a wrong gesture — so this is a playability question, not a soundness one.

- **Haptic trainer** — agreed direction (2026-07-28): pulse-rate modulation via the built-in
  `HapticFeedback` API as the default, continuous amplitude via a vibration package as an opt-in
  setting. Streaming feedback is validated as viable (see M4_findings): the running prefix
  alignment cost separates own-class from other-class from ~25% into the gesture and widens
  monotonically. Build as `StreamingGestureScorer` mirroring `StreamingPhonemeScorer`, over
  `DtwMatcher.distanceWithSteps`.

- ~~**Re-record `fire`**~~ — **withdrawn (2026-07-28).** Fire's choreography is deliberately a
  *tremor* (phone mostly still, hand shaking). That is a stochastic texture, not a trajectory:
  shake cycles have arbitrary phase, so DTW has nothing repeatable to align and re-recording
  cannot make it crisper. Measured: fire is best matched **spectrally** (crispness 1.83 → 2.26
  under band energies) while the other four are best matched by trajectory DTW (2.1–2.5,
  collapsing to ~1.35 under spectral). No single representation wins both, and concatenating
  them is worse than either. **Decision: leave the cast-time classifier as-is** — fire at 1.83
  passes the gate — **but give the trainer a per-gesture matcher**, spectral for fire. Training
  is single-class, so mixed representations cost nothing there. See M4_findings 2026-07-28.

- **Fire vs the stillness gate** — "mostly still" fights `energyFloor = 8.0`; fire's weakest
  recorded rep is 13.75, the tightest margin of any gesture. A too-gentle shake gets gated and
  the player sees nothing happen. Prefer coaching intensity in the trainer; optionally make the
  gate spectral (low-energy *high-frequency* is a tremor; low-energy *low-frequency* is real
  stillness) — verify against `confusable_idle` before relying on it.
