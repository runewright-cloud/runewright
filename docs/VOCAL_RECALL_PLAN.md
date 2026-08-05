# Vocal Recall — redesign of the verbal component

*Ratified with Soren 2026-08-03. Supersedes the pronunciation-quality scoring model for
the vocal component. The practice entry point (below, §7) is built; the scoring rework
is not.*

*Amended 2026-08-04 — §8 makes the vocabulary player-chosen, replaces `finitus` with a
player-chosen opener pair, and amends §1, §3 and §5 accordingly. Where §8 and an earlier
section disagree, §8 wins.*

---

## 1. The change

The verbal component stops being **"how clearly did you say it"** and becomes
**"can you recall the trajectory your spell was built from"**.

Same five words (`ignis`/`ventus`/`aqua`/`terra` + `finitus`), same sequence — the
incantation already *is* the spell's trajectory read aloud. What changes is what's
measured: sequence correctness from memory, not articulation quality.

> **Amended by §8 (2026-08-04):** the vocabulary is now six *slots*, not five fixed
> words — four elements plus an opener pair — and the words filling them are chosen by
> the player. The Latin above is the suggested default, not the vocabulary. The sentence
> that still holds unchanged: the incantation is the spell's trajectory read aloud.

## 2. Why — the verifiability argument

`dominance_trajectory` is already a **public input to the proof** (`CIRCUIT_IO.md` §8,
`[Field; tier_max]`, dominant element per generation), and the formula derives from it
deterministically (`lib/engine/formula.dart` — activations grouped in 3s, remainder
dropped). The peer already holds it; that's what makes `_certifiedManaCost` possible.

So the correct incantation is a pure function of a ZK-bound value the opponent's device
already has. Recall correctness is therefore **checkable by the verifier**, where
pronunciation quality never can be. `vocal_score.dart` states the current limit outright:

> RECEIVING-SIDE CONSTRAINT: this constructor accepts only the bytes transmitted by the
> caster. It does not and cannot recalculate the score from audio.

That is a category change, not a degree change. The only remaining honour-system element
is *did you actually speak it* rather than tap it — and the opponent is standing there.

### Secondary benefits

- **Well-posed problem.** "Which of 5 words was that" is closed-vocabulary keyword
  spotting; "how well was that pronounced" is continuous regression with no ground truth.
  `streaming_phoneme_scorer.dart` (564 lines, the hardest code in the stack) retires.
  Enrollment *survives and matters more* — per-speaker templates are what make 5-way
  spotting robust across accents.
- **Cross-device determinism for free.** The u8 quantisation dance in `vocal_score.dart`
  exists so a continuous score lands on the same curve bracket on both devices. A
  correct-count agrees trivially.
- **Accessibility.** Accent-neutral and noise-tolerant, which matters because the design
  doc (§944) already flags that volume-scaling penalises players who can't project, in
  venues that are loud by design. It adds a *memory* axis, but that one has a graceful
  ramp (a sight-reading mode at a mana premium); pronunciation never had one.

### Accepted cost

Speaking the trajectory leaks a durable fact, not just a tactical one: hearing a 9-word
trajectory cast at tier-12 tells a rival that trajectory is achievable *cheaply*, and
finding a short grid for a desired trajectory is the expensive foundry work. Accepted —
it is much smaller than leaking the grid, which stays ZK-protected.

## 3. Cost formula `[ratified shape, step size open]`

Flat compounding, **order-independent**:

```
cost = base × (1 − step)^correct × (1 + step)^wrong
```

`finitus` is **excluded from scoring** — it is invariant and carries no recall
information.

> **Amended by §8.5:** `finitus` is gone, and the opener that replaces it is **scored, at
> asymmetric weight** (1× correct, 3× wrong). The exclusion above rested on the wrong
> criterion — `finitus` was safe to drop because it told an *opponent* nothing, not
> because it was invariant. The opener is pure telegraph, so leaving it unscored makes
> speaking it faithfully a cost with no upside. See §8.5.

Streak-escalating multipliers were considered and rejected: they made the discount scale
so aggressively with spell length that a perfect 9-word recital (−37%) out-discounted the
Water/Efficiency loadout (−33%), which is *gated* on supreme dominance while recall is
ungated. Constraint to preserve: **an ungated skill check must never beat a gated loadout
enhancement.**

Set the step by choosing the target, not the step. At −25% for a perfect 9-word recital,
`step = 1 − 0.75^(1/9) ≈ 0.03`:

| Spell | Perfect | 6 of 9 | Total blank |
|---|---|---|---|
| 3 words | −8.7% | — | +9.3% |
| 9 words | −24.0% | −9.0% | +30.5% |

`step = 0.01` was the first proposal; it was rejected as decorative — a total blank would
be only ~9% worse than a perfect recital, which does not beat the opportunity cost of
reciting Latin in a loud room.

## 4. Failure handling `[ratified]`

- **No fizzle from recall quality alone.** Getting words wrong costs mana.
- **Fizzle only on shortfall:** if the inflated cost exceeds the mana pool, the spell
  fizzles and **the mana is refunded** (the turn is still spent).
- This retires the reason `CastingEnhancements.maxManaCostMultiplier` exists — that
  constant is there purely so `previewSpellCost` can guarantee a bad incantation never
  turns an affordable spell into a forfeit. Preview can price at the honest base cost.
- **Known narrow edge:** refund-on-shortfall is a take-back. Deliberately blanking a cast
  you regret returns the mana at the cost of the turn. Only reachable when the spell costs
  >~91% of the pool at `step = 0.03`. Accepted.

## 5. Decisions taken and rejected

- **First utterance binds** — no paid self-correction. This keeps the telegraph honest
  (design v3_0 §934): a listening opponent can trust what they hear, which is what the
  information-curve counterplay rests on.
  > **Amended by §8:** the telegraph goes from *open* to *enciphered but enforced*. A
  > listener can still trust that what they hear is what was cast — first utterance still
  > binds, and §8.5 puts mana behind saying it faithfully — but they must learn that
  > opponent's vocabulary before the words mean anything. The counterplay is no longer
  > free; it is earned per opponent. See §8.2 for why that is the point rather than a
  > regression.
- **Affinity substitution — REJECTED.** Letting a wrong first word cast the spoken
  flavor instead was considered and dropped: the first word of each triplet is the
  affinity, so making it speakable-at-cast would stop affinity being an inscription-time
  commitment and gut hybrid affinity, chain casting and wild magic as deckbuilding axes
  (design v3_0 §211–217). The effect-table flavor columns differ enough in situational
  power that everyone would simply pick the best one.
- **Turn-based mode adopts this too**, with softer stakes: no channel and no dodge window
  there, so a recall miss should cost mana and the enhancement, not the whole cast.
- **Order-independence accepted.** `M M X M M X M M X` and `M M M M M M X X X` score
  identically. Streaks measured something more interesting but collided with the loadout
  balance above; accuracy-not-fluency is the deliberate trade.

## 6. Implementation notes for the scoring rework

- **Put the spoken words on the wire, not the score.** The peer holds
  `dominance_trajectory`, so transmit the spoken word indices (~3 bits each) and let the
  peer derive matches and the multiplier itself. Verifiable rather than self-reported, and
  it keeps a multi-step floating-point product off the trust boundary — which matters
  given the `_certifiedManaCost` / `_spellManaCost` operation-order coupling.
- Every multiplier is `(100 ± k)/100`, so the product can be computed exactly in integers
  and rounded once, in one place.
- Practice mode reframes from "train your pronunciation" to "drill your spellbook" —
  spaced repetition over spells you own. See §7.

## 7. Built so far (2026-08-03)

The practice entry point only — no scoring change yet.

- `PracticeFormula.fromSpellFormula()` (`lib/practice/formula_generator.dart`) builds a
  spell's own incantation from `SpellAsset.formula`. **Truncates to complete triplets**:
  `SpellAsset.formula` stores `FormulaTracker.committed`, which includes the 1–2 residual
  activations that never filled a group of three and resolve to no effect.
- `PracticeScreen({SpellAsset? spell})` — spell-drill mode. Loads that spell's
  incantation, hides the formula-count chips, and **starts with the words concealed**
  (`? ? ?` per word, count visible, `finitus` shown). Reveal is available and marks the
  attempt as revealed; Start Over re-conceals.
- Library `_SpellCard` gains **Practice Incantation**, shown only for spells with ≥3
  activations. Wired in both the Craftings and Tests tabs.
- `AudioPlayer` in `PracticeScreen` is now lazy — it was spinning up a native audio
  session and per-player event channel on screen open.

### Open

- The scoring rework itself (§3/§4/§6) — not started.
- Step-size ratification (§3 recommends ~0.03 against a −25% target). **§8.5 ratifies
  `step = 0.03`** with the opener at asymmetric weight; the resulting ceiling is −26.3%.
- Whether a sight-reading mode (words shown, mana premium) ships as the accessibility
  ramp, and at what premium.
- All of §8 — player-chosen vocabulary, the opener pair, enrollment separation warning,
  re-keying. Nothing in §8 is built.

---

# 8. Player-chosen incantations `[ratified 2026-08-04]`

## 8.1 The change

The vocabulary stops being five fixed Latin words and becomes **six slots the player
fills with words of their own choosing**:

| Slot | Count | Spoken |
|---|---|---|
| Elements — fire / air / water / earth | 4 | one per activation, in trajectory order |
| Opener — general | 1 | first word of a non-summon cast |
| Opener — summon | 1 | first word of a summon cast |

Cast shape becomes `OPENER + 3n element words`. `finitus` is **removed** — the terminator
is replaced by an opener, marking starts rather than ends.

The openers are **one slot with two possible values**, not two stacked words: a summon
cast is not one word longer than an incantation, and the distinction lands on the very
first syllable, which is where it is most audible.

Latin (`ignis`/`ventus`/`aqua`/`terra`) survives as the **suggested default**, shipped
with its Piper templates so a player can duel without enrolling. Choosing custom words
requires enrollment (§8.9).

## 8.2 Why — a lenticular telegraph

Player-chosen words turn the incantation from an open telegraph into one an opponent must
decipher, and the deciphering is a skill ramp with three legible rungs:

1. **Beginner** — say your own words right; enjoy the flavour of your opponent's
   muttering. You are not decoding anything yet.
2. **Intermediate** — realise it is worth the brain space to crack an opponent's
   element words, because the trajectory maps to the (public) effect table, so cracking
   the words cracks their recipes.
3. **Advanced, real-time** — map a cracked vocabulary back onto spell effects live, and
   read an opponent's intended move while it is still being spoken.

Two benefits that are not about obfuscation at all:

- **It lowers the floor as well as raising the ceiling.** The largest risk in this whole
  redesign is the memory burden it adds (§2, accessibility) — recalling a nine-token
  sequence in a language you do not speak, in a room that is loud by design. Four words
  *you* chose because you associate them with fire are dramatically easier to recall than
  four Latin ones. The same change that adds the advanced layer softens the beginner tax.
- **It partially retracts §2's accepted cost.** The durable leak §2 accepts — that
  overhearing a nine-word recital tells a rival the trajectory is achievable cheaply —
  becomes enciphered rather than plaintext.

**The cipher is deliberately weak.** Four symbols, and every cast is a labelled training
example because the resolving effect reveals the affinity. Cracked in a handful of casts
*on paper*. That is fine, and intended: what protects it in play is that decoding must
happen while you are also reading the tactical situation and recalling your own spells.
The protection is against the **live read** and the first encounter, not against a player
who thinks it through after the match — and free re-keying (§8.8) is the answer to that.

## 8.3 Why it is cheap to build

- `StreamingPhonemeScorer` has **no dependency on `latin_phonemes.dart`** — it is MFCC
  frames plus DTW min-distance over a template set keyed by the `VocalWord` enum. The
  recogniser is already word-agnostic.
- `VocalWord` stays an enum of **slots**. Custom words are a local
  `Map<VocalWord, String>` display layer plus the player's enrolled takes. Nothing about
  a word's identity crosses the wire.
- §6's wire format is unchanged in kind — slot indices, now covering six values, still
  inside 3 bits.
- `latin_phonemes.dart` is retained: it generates the Piper defaults and carries the G2P
  derivation trail.

## 8.4 Removing `finitus` is safe — the evidence

- Its "terminator (dismissal / chain break)" description exists in exactly one place, the
  comment at `lib/sorcerer/vocal_score.dart:23`. No chain-cast or dismissal code
  references it, and no design doc assigns it a role. It is decorative today.
- **Capture does not depend on it.** `battle_screen.dart`'s `_voiceCaptureWindow`
  (2500 ms) captures per-word against an expected word the device already knows from the
  selected card's trajectory. Nothing is terminator-delimited.
- **The opener subsumes its only real job, and does it better.** If chain casting ever
  needs a break marker, a listener needs *starts* marked, not ends — the next opener is
  the chain break.

## 8.5 The opener is scored, at asymmetric weight `[ratified]`

An unscored opener is a telegraph whose entire value accrues to the opponent: speaking it
faithfully would be a pure cost, and rational play degrades it — mumbled, clipped, or
filled with noise — until the telegraph is worthless. Scoring is the **only enforcement
mechanism available**, since nothing can verify that a player spoke rather than tapped.

Weight is **asymmetric: 1× on correct, 3× on wrong**, because the problem is deterrence,
not reward:

```
cost = base × (1 − step)^correct × (1 + step)^(wrong_elements + 3 × wrong_opener)
```

`step = 0.03` is **ratified**. At that step:

| Spell | Perfect | Opener missed, elements perfect | 6 of 9 elements, opener right | Total blank |
|---|---|---|---|---|
| 3 elements | −11.5% | **−0.3%** | — | +19.4% |
| 9 elements | −26.3% | **−16.9%** | −11.7% | +42.6% |

On a three-element spell, missing the opener erases essentially the whole discount — a
short, legible, strong deterrent exactly where the incantation is shortest and cheapest
to fake.

**Why asymmetric rather than symmetric double weight.** §3's binding constraint is that
an ungated skill check must never beat the gated Water/Efficiency loadout at −33%.
Symmetric 2× yields a −28.5% ceiling (4.5 points of headroom) and a 9.1-point deterrent;
asymmetric 1×/3× yields a **−26.3% ceiling (6.7 points of headroom) and a 9.3-point
deterrent** — a stronger deterrent *and* more headroom. Every multiplier is still
`(100 ± k)/100`, so §6's "compute in integers, round once" is unaffected.

The opener is scored; the constraint in §3 is preserved; the ratified −25% target moves
to −26.3%, which is within the spirit of the target and still well under the gate.

## 8.6 Ambiguity prices itself — no ambiguous state `[ratified]`

A player could try to defeat the telegraph not by suppressing the opener but by
**collapsing the pair** — re-keying so both openers sound alike, so one utterance always
matches and no opponent can tell a summon from an incantation.

**Rejected fix: an explicit "low confidence → penalty" wire state.** Ambiguity is measured
on the caster's device from audio the peer never hears, so an ambiguous flag is
self-reported — exactly the shape the B-1/B-8 audit closed. Worse, it would buy something
strictly better than what it prices: a caster keeps four clean, distinguishable words for
their own accuracy and merely *declares* ambiguity on the casts where hiding a summon
matters. Selective opacity, paid for only when used.

**Adopted: transmit the best guess.** Whichever opener won, however narrowly, goes on the
wire; the peer verifies it against `isSummon` and applies the multiplier itself.
`isSummon` is already consensus-visible — `turn_loop.dart:4170` uses it to compute chain
affinity on both devices, so they must already agree or chains would desync.

Ambiguity then prices itself at exactly the rate the confusion occurs:

- **Collapsed openers** ≈ a coin flip, so the wrong index is transmitted about half the
  time. Expected multiplier `0.5 × 0.97 + 0.5 × 1.03³ ≈ 1.031` against `0.97` for a clean
  vocabulary — **≈ +6.3% mana on every cast, permanently.**
- **Innocent near-collapse** at a ~20% confusion rate: `≈ 0.995` vs `0.97` — **≈ +2.5%**.
  Real, mild, survivable.

Nothing is self-reported, no threshold enters the protocol, and the "Mumbling Wizard" —
opacity bought with permanent mana — becomes a legitimate priced archetype rather than
either a banned strategy or a free one.

**This is uniform with the elements.** A near-tie between two element words already
resolves the same way: best guess transmitted, checked against `dominance_trajectory`,
wrong costs mana. The opener slot is not a special case; it is a slot with a two-way
candidate set instead of a four-way one.

## 8.7 Enrollment: a warning with a separation meter, not a ban

The mechanism in §8.6 prices the exploit, but it cannot tell an exploiter from a player
who innocently picked two similar words and now bleeds mana without understanding why.
That is a **disclosure** problem, and it is solved before the first duel:

- After recording, compute the cross-word DTW distance matrix against within-word
  variance (the contrastive machinery in `test/practice/vocal_calibration.dart` already
  does this, and the gesture corpus work established the LOO evaluation pattern).
- **Show the separation, and warn plainly** when two words will be confused: these will
  be mistaken for each other and it will cost you mana. Let the player proceed anyway.
- Enforce a **minimum duration / syllable count** — one-phoneme words discriminate badly
  under DTW.

**Opener-vs-opener is the most load-bearing distance in the vocabulary** and gets the
highest bar and the most prominent warning. It is the only pair a player is actively
motivated to collapse; every other pair only degrades by accident.

**Why a warning and not a hard reject.** A ban needs a threshold that is correct across
every accent and voice, and a wrong threshold locks a player out of words they say
perfectly well. A warning degrades gracefully when the threshold is off, and it turns the
exploit into an informed choice — which is what makes the Mumbling Wizard a character
rather than a trap.

## 8.8 Re-keying is free `[ratified]`

Changing your words costs nothing in game. Retraining your own brain onto a new vocabulary
is a real cost that must be worked for, and that is a sufficient limiter — no additional
price is needed. Re-keying is the counter-espionage move, and the answer to an opponent
who cracked you between matches.

**Re-keying must be atomic.** A partially re-enrolled vocabulary at cast time means mixed
old and new words and mana penalties the player did not earn. All words are re-recorded
before any of them swap in, and `PerUserEnrolledTemplateSource.invalidate()` fires on
commit. Cheap to get right now, nasty to debug later.

## 8.9 Enrollment becomes the on-ramp, not an upgrade

- **Retire the Piper trainer clip** — pronunciation is no longer scored, so a "here is how
  it sounds" demo has nothing left to teach.
- **Keep Piper as the template fallback for the default words.** It is the only path to
  casting without enrolling, and so the zero-config on-ramp: *default words = play now,
  custom words = enroll first.* A good gate — the players who want the obfuscation are
  exactly the ones who will pay three minutes for it.
- The marginal cost is near zero regardless: cross-voice discrimination was already 2/5
  (M4_findings 2026-07-16), and under recall scoring a mis-spot costs **mana**, not just a
  soft score. Enrollment was becoming mandatory in practice with or without §8.

## 8.10 Invariants this adds

1. **The wire carries slot indices only, never word text.** A player's vocabulary never
   leaves their device.
2. **The peer never renders the caster's chosen labels.** Displaying them would hand over
   the cipher for free. (Currently safe — the incantation tray shows spell art.)
3. **The peer never surfaces which opener it decoded.** It applies the multiplier
   silently; otherwise the device hands the opponent a telegraph their ears did not earn.
4. **Loaned spells recite in the borrower's vocabulary.** This falls out for free — words
   are local labels over slots — and it is required, not incidental: a borrowed spell in
   the lender's words would be near-uncastable. A master sharing their words with an
   apprentice stays a voluntary act of trust.

## 8.11 Open

- The default words themselves: Latin for the four elements is settled; the two openers
  need suggested defaults.
- The separation threshold at which §8.7 warns, and the minimum word duration.
- Whether six-player mesh needs anything special given five simultaneous ciphers
  (expected: no — a player prioritises one opponent).

---

# 9. Build log — 2026-08-04/05 `[implemented]`

*What was actually built, and the four decisions taken during the build. Where §9
and an earlier section disagree, §9 wins — it describes shipped code.*

## 9.1 Length-normalized step `[ratified 2026-08-04, supersedes §8.5's flat step]`

**§8.5's `step = 0.03` was calibrated against a 3–9 element vocabulary, and breaks
outside it.** `FormulaTracker.step` commits at most one activation per generation, so a
tier-48 spell can legitimately reach **48 element words**. At a flat step a perfect
recital passes §3's binding constraint — an ungated skill check must never beat the gated
Water/Efficiency loadout at −33% — at only ~13 element words, and reaches **−77%** at 48.

The step is therefore normalized to the recital length:

```
n    = 1 (opener) + elementCount
step = 1 − 0.737^(1/n)
```

A perfect recital now lands on the ratified **−26.3%** at every length. This
*generalizes* §8.5 rather than overturning it: at 9 element words the table gives
`30056 ppm` against the ratified `0.03`, and a total blank `+42.67%` against §8.5's
`+42.6%`. The §8.5 table is preserved as a regression fixture.

**Accepted consequence, flagged for playtest.** Per-word stakes now vary with length:
~7.3% per unit on a 3-element spell (all-or-nothing), ~0.62% on a 48-element one (a
grind). Same ceiling either way. It also makes the opener deterrent strongest on *short*
spells — a wrong opener swings 23.7% at 3 elements and 1.9% at 48 — which is where §8.5
wanted it, since a short incantation is the cheapest to fake.

## 9.2 Determinism: baked step table, exact integers

A normalized step is no longer a clean `(100±k)/100` rational, so §6's "compute in
integers" needed a mechanism rather than an assertion:

- The per-unit step is a **baked `ppm` table**, one entry per `n` in 1..49, committed as
  source. `pow`/`exp` with fractional exponents are **not** bit-reproducible across
  platforms and libm versions, and this value feeds the mana ledger — a one-ULP
  disagreement becomes a one-mana disagreement becomes a state-hash desync.
- The product is **exact BigInt**, rounded up **once**, matching the rest of TurnLoop's
  mana chain.
- `incantation_recall_test.dart` re-derives every table entry from the formula and
  re-checks the −33% gate at every length 3..48.

## 9.3 Opener defaults `[closes §8.11]`

**`reformare`** (general) / **`invoco`** (summon). Both are phonemized by the same
espeak-ng the templates are rendered with, and both needed checking:

- `reformare` → `/ɹᵻfˈoːɹmɛɹ/`, which is literally the English word **"reformer"** — the
  Latin `-are` collapses to `/ɛɹ/`. Fixed with a `kTtsTextOverride` of `"reformahray"`
  → `/ɹᵻfˈoːɹmɑːɹˌeɪ/`, the same mechanism `ignis`/`ignisse` already uses.
- `invoco` → `/ɪnvˈoʊkoʊ/`. No override needed.

They are deliberately far apart (different onset, syllable count, stress shape), because
§8.7 names opener-vs-opener as the load-bearing distance.

## 9.4 Capture is press-and-hold `[ratified 2026-08-04]`

The caster **holds the cast button**, chants `OPENER + trajectory` continuously, and
**release ends the window**. The same press bounds the somatic-gesture window.

This replaces the per-word 2500 ms window, which does not survive contact with the real
maximum: 49 words × 2.5 s is ~two minutes per cast. It also reuses
`HoldToRecordButton` (`lib/ui/widgets/hold_to_record_control.dart`), whose own header
already requires exactly this — *"do not build a second capture-window mechanism
elsewhere"* — because enrollment and live capture must segment identically or every DTW
distance is skewed.

## 9.5 Fizzle, refund, and the one weakened gate

`previewSpellCost` now quotes the **honest base price**. It used to quote a 1.5× worst
case for one reason: a cast the gate approved at 1.0× and the peer forfeited over at 1.5×
would read as a desync. Making a shortfall a legal, refunded fizzle removes that failure
mode, and with it `maxManaCostMultiplier`.

**The peer's `insufficient_mana_for_spell` forfeit is removed outright** — in BOTH
modes. `[ratified 2026-08-05, supersedes the mode-split first built]`

The forfeit was never really punishing a cheat: an unaffordable cast wins its caster
nothing. It was avoiding a **desync** — the caster's own deduction clamped at zero and
played on while the peer stopped the match, and those two devices disagreeing is the
actual failure. Fizzle-with-refund fixes that at the source, because both devices price
the cast from the same certified inputs and reach the same verdict. With the desync gone,
ending someone's match is a wildly disproportionate answer to a move that already
accomplishes nothing.

So a shortfall fizzles and refunds everywhere; the turn is still spent. Sorcerer mode
merely makes it *routine* rather than exceptional, since recall can inflate a cost after
the player has committed. The decision is never transmitted — each device derives it from
the same certified cost and the same avatar mana.

`canAffordSpell` and the UI gate stay: a cast that silently does nothing is still a
wasted turn, so the button should not offer it. The fizzle is the backstop behind the
gate, not a replacement for it.

## 9.6 Status

**Built:** the vocabulary slot model (`VocalSlot` + `VocabularyProfile`, `finitus`
removed, enrollment/templates moved to `lib/sorcerer/` with a legacy-filename read path);
the cost model (`IncantationRecall`); the wire format (variable-length, trailing length
byte, slot indices only); the engine wiring (both cost paths, fizzle-with-refund, the
forfeit split, honest preview); protocol bumped to **v4**; Piper assets and voice
fixtures regenerated for all six slots.

Also built: **the capture (§9.4)** — `IncantationRecallScorer` (whole-utterance
segmentation plus per-position argmin over the candidate set) and the hold-to-cast
wiring, on `HoldToRecordButton`. 1232 tests green.

Also built: **Practice Mode repointed** at the recall scorer, so the drill and battle
run one code path. `StreamingPhonemeScorer`, `PracticeFeedback`, the strictness dial
(`VocalTuning` + its Settings card) and the Piper trainer clips are all retired; the
real-voice fixture e2e is ported to `test/sorcerer/recall_real_voice_e2e_test.dart`.
1245 tests green.

**Not yet built:**

- **The vocabulary UI.** Nothing lets a player *choose* their words yet, so every
  vocabulary is the Latin default in practice. `VocabularyProfile` persists them and the
  whole stack reads through it — the screen is the missing piece, along with atomic
  re-keying (§8.8) and §8.7's separation meter.
- Repointing Practice Mode at the recall scorer, and retiring
  `StreamingPhonemeScorer`.
- A **two-loop parity test**: both devices deriving the same multiplier from the same
  certified trajectory. This is the exact shape of desync this change could introduce and
  is the most valuable remaining test.
- The **two-device LAN pass**, which no automated test substitutes for.
