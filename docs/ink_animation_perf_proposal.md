# Proposal — Cutting the cost of the ink-spread animation (Rune Craft grid)

*Written 2026-07-17. Scope: `lib/ui/hex_grid_painter.dart` + its host in `lib/main.dart`.
This is a proposal / analysis document, not an applied change. Nothing here touches the
CA rules, the stepper, or the circuit — it's purely the on-screen rendering of a step.*

---

## TL;DR

Your instinct is correct, and then some. Right now, during the 500 ms growth animation
after every CA step, the painter:

1. redraws all **469** hex-cell backgrounds + grid lines **every frame** (~30 frames/step),
2. **recomputes the entire ink topology from scratch every frame** (which cells are alive,
   which pairs are connected, which triples form triangles) — for *both* the new grid and
   the previous grid, even though neither changes mid-animation, and
3. pushes **every** ink primitive — including the ones that didn't change at all — back
   through the expensive "goo" blur-and-recomposite layer every frame, and in fact
   **animates the unchanged ink too** (stable strokes collapse to a point at the start of
   each step and grow back), so the whole drawing re-flows on every step rather than only
   the cells that actually changed.

So "every single inkblot is redrawn whether or not it or its neighbors changed" is
essentially what's happening — on three separate axes at once. The good news: each axis
has a clean, independent fix, and the two biggest wins are low-risk. Idle (not stepping)
is already cheap — the cost is entirely during the post-step animation, which during
auto-run is ~half the wall-clock time.

---

## How the rendering works today (the diagnosis)

The grid is drawn by a single `HexGridPainter` (a `CustomPainter`). It's wired to repaint
off two `AnimationController`s:

```dart
super(repaint: Listenable.merge([flicker, growth]));
...
@override
bool shouldRepaint(HexGridPainter oldDelegate) => true;
```

While `growth` (or `flicker`) is running, Flutter calls `paint()` once per display frame —
~30 times over the 500 ms growth window. Each of those calls does the following, in full,
from scratch:

**A. Static background pass (per frame).** Lines 76–78 loop over all 469 cells and draw a
filled hex path + a stroked outline for each. None of this changes during an animation —
the board, the border tints, the grid lines are all fixed — yet it's re-issued every
frame.

**B. Topology recomputation (per frame).** `_liveEdges(grid)`, `_liveTriangles(grid)`, and
the alive-set are rebuilt by scanning every cell and its six neighbors (lines 89–162).
When `previousGrid` is set (i.e. during every step), it does this **twice** — once for
`grid`, once for `prev` — and unions the results. These sets are a pure function of the
two grids, and *neither grid changes during the 500 ms animation*. We're recomputing an
identical answer ~30 times per step.

**C. The goo / metaball layer (per frame).** Lines 171–190 open a `saveLayer` with a
color-matrix filter and draw every triangle, every edge stroke, and every connected dot
with an individual `MaskFilter.blur`, then re-threshold the whole layer. `saveLayer` +
per-primitive blur is the single most GPU-expensive thing on the screen, and it's redone
in full every frame — including for primitives that are fully static.

**D. Everything animates, not just the changes.** The interpolation factor is a single
global `t`. For an edge, line 117 reads:

```dart
final grown = t >= 1.0 ? 1.0 : currentEdges.contains(edge) ? t : 1.0 - t;
```

An edge that exists in *both* the previous and current grid (i.e. unchanged ink) is in
`currentEdges`, so it gets `grown = t` — meaning at the start of each step it collapses to
its midpoint and grows back over 500 ms. The same is true for dots and triangles. So the
whole drawing "breathes" on every step, not just the cells that were born or died. This is
worth a decision (see the note under Option 1): it may be an intended aesthetic, but it's
also the thing most directly responsible for the feeling that *everything* is redrawing.

---

## The fixes, ranked by value-for-effort

### Option 1 — Hold unchanged ink static (small change, big perceptual + real win)

Make stable primitives *stay drawn* instead of collapsing and regrowing each step. Only
the ink that was **born** this step grows in (`t`), and only the ink that **died** shrinks
out (`1 - t`); anything present in both grids is drawn at full size (`grown = 1.0`).

Concretely, for edges/dots/triangles, distinguish three cases instead of two:

```dart
final grown = t >= 1.0
    ? 1.0
    : (currentSet.contains(x) && prevSet.contains(x)) ? 1.0   // stable: hold
    : currentSet.contains(x)                          ? t     // born: grow in
    :                                                   1.0 - t; // died: shrink out
```

- **Why it helps performance:** on a typical step only a handful of cells change, so the
  vast majority of primitives become *static* — which is the precondition that makes
  Options 2 and 3 (caching) actually pay off. On its own it also removes a lot of
  sub-pixel geometry churn.
- **Why it helps the look:** the drawing stops re-flowing wholesale every step; the eye
  follows the ink that actually spread.
- **Decision (RESOLVED 2026-07-17):** the whole-drawing re-flow is a **bug**. Soren only
  wants the grow-in animation when ink spreads to *new* areas. So this is a correctness
  fix, not an aesthetic change — it's non-optional and moves to the top of the plan.
- **Effort:** ~10 lines. **Risk:** low.

### Option 2 — Compute the topology once per step, not once per frame (pure CPU win)

The alive-set, edge-set and triangle-set depend only on `grid` and `previousGrid`. Cache
them and rebuild only when those two references change (they change once per step, in
`setState`). Two shapes to do this:

- **In the painter:** memoize keyed on `identical(grid, …)` / `identical(previousGrid, …)`.
  Because `_stepOnce` assigns *new* grid objects each step (`CAStep.step` returns a fresh
  grid), an identity check is a reliable "did the input change?" signal.
- **Cleaner:** lift the sets into the host `State` and compute them in `_stepOnce`, passing
  them into the painter as already-built inputs. This also makes the painter a pure
  function of its inputs, which is generally healthier.

- **Why it helps:** turns ~30 full topology scans per step into **one**. This is the
  cheapest large CPU saving on the list and has no visual effect whatsoever.
- **Effort:** small–medium. **Risk:** low (behavior-identical).

### Option 3 — Cache the static layers so animation frames only redraw what moves

This is the structural win and the one that most directly answers "don't redraw the
inkblots whose state didn't change."

- **3a — Split the background into its own cached painter.** Move Pass 1 (the 469 hex
  backgrounds + grid lines, plus the border tints) into a separate `CustomPainter` whose
  `shouldRepaint` returns false unless the grid *structure* changes, and wrap it in a
  `RepaintBoundary`. Stack the animated ink painter on top. Result: the background is
  rasterized once and reused; animation frames never touch it.
- **3b — Cache the fully-grown ink as a `Picture`/`Image` and animate only the delta.**
  After a step settles (or precomputed at step time), record the *stable* ink — everything
  that isn't being born or dying this step — into a `ui.Picture` once, goo-blur and all.
  During the 500 ms animation, replay that cached picture and only run the live
  goo/`saveLayer` pass over the small set of born/dying primitives. This is what makes the
  expensive metaball blur (item C above) scale with *how much changed*, not with the whole
  board.

  This depends on Option 1 (you need a well-defined "stable" set to cache) and pairs
  naturally with Option 2.

- **Why it helps:** the per-frame GPU cost drops from "blur-composite the entire drawing"
  to "blur-composite the few cells that changed," plus a cheap picture blit.
- **Effort:** medium (3a) to medium-high (3b). **Risk:** medium — caching invalidation has
  to be exactly right (invalidate on grid change, resize, zone/rule change, theme). Worth
  doing *after* 1 and 2 are in and measured.

### Option 4 — Cheap knobs, if you want immediate relief before the structural work

- **Precise `shouldRepaint`.** Replace `=> true` with a real comparison of
  `grid`/`previousGrid`/`hexSize`/`activeZone`/`activatedBorderCells`. The animation
  listenable still drives repaints during growth, but this stops spurious full repaints on
  unrelated `setState`s (mode toggles, counters, banner changes) from rebuilding the whole
  ink drawing. Cheap hygiene; do it regardless.
- **`RepaintBoundary` around the `CustomPaint`.** Isolates the grid from the zone
  counters / dominance banner / mode bar so their rebuilds and the grid's repaints don't
  invalidate each other.
- **Trim the animation budget.** Fewer effective frames (e.g. cap the growth animation's
  effective step count) or a shorter `_growthDuration` reduces the number of expensive
  frames per step directly. Blunt, but a one-line safety valve if a low-end device still
  struggles after the above.
- **Reduce goo cost.** The blur sigma (`hexSize * 0.16`) and the per-primitive
  `MaskFilter.blur` are the GPU hot spot. A slightly smaller sigma, or blurring the layer
  once instead of per-primitive, buys headroom with minimal visual change. Measure before
  and after.

---

## Finalized implementation plan

Target device: **Pixel 6** (90 Hz display, so the 500 ms growth window is ~**45 frames**,
not 30 — per-frame cost matters more than the 60 Hz math above suggested). Both open
questions are now resolved: the re-flow is a bug to fix, and Pixel 6 is the bar. The plan
below is ordered, each phase is independently shippable and measurable, and Phases 1–3 are
committed work; Phase 4 is gated on measurement.

Implementation note that shapes all of this: during the growth animation the widget tree
does **not** rebuild — repaints are driven by the `repaint:` Listenable, which calls
`markNeedsPaint` without reconstructing the painter. So the **same `HexGridPainter`
instance's `paint()` is called ~45 times per step**. That means anything computed as a
`late final` field on the painter is computed **once per step** for free. Phases 1 and 2
exploit this directly.

### Phase 1 — Merge the topology-recompute fix and the stable-ink fix (Options 1 + 2)

These two are one edit in practice. Materialize the six topology sets as `late final`
fields on the painter instead of recomputing them inline every `paint()`:

```dart
late final Set<(HexCoord, HexCoord)> _currentEdges = _liveEdges(grid);
late final Set<(HexCoord, HexCoord)> _prevEdges =
    previousGrid == null ? const {} : _liveEdges(previousGrid!);
late final Set<(HexCoord, HexCoord, HexCoord)> _currentTriangles = _liveTriangles(grid);
late final Set<(HexCoord, HexCoord, HexCoord)> _prevTriangles =
    previousGrid == null ? const {} : _liveTriangles(previousGrid!);
late final Set<HexCoord> _currentAlive = /* alive coords of grid */;
late final Set<HexCoord> _prevAlive =
    previousGrid == null ? const {} : /* alive coords of previousGrid */;
```

Then in `paint()`:
- Replace the inline `_liveEdges(prev!)` / `_liveTriangles(prev!)` / alive-set unions with
  the cached fields. The render loops iterate `current ∪ prev` (built from the fields).
- Change the `grown` factor from two-case to **three-case** for edges, dots, and
  triangles:

  ```dart
  final grown = t >= 1.0
      ? 1.0
      : (currentSet.contains(x) && prevSet.contains(x)) ? 1.0   // stable → hold, don't animate
      : currentSet.contains(x)                          ? t     // born   → grow in
      :                                                   1.0 - t; // died  → shrink out
  ```

**Effect:** topology is computed once per step instead of ~45×, and only ink that spread
to new cells (or vanished) animates — matching the intended behavior. **Verify:** step a
grid with one obvious spread; confirm only the new edge/dot grows in while the rest holds
still. Run `test/engine/hex_grid_codec_test.dart` and any painter/golden tests.
**Risk:** low.

### Phase 2 — `shouldRepaint` + `RepaintBoundary` (Option 4, hygiene)

- Replace `shouldRepaint => true` with a real comparison: `!identical(grid, o.grid) ||
  !identical(previousGrid, o.previousGrid) || hexSize != o.hexSize || innerRadius !=
  o.innerRadius || activeZone != o.activeZone || !setEquals(activatedBorderCells,
  o.activatedBorderCells)`. Identity checks are valid because `_stepOnce` assigns fresh
  grid objects each step. (The animation listenable still drives the per-frame repaints
  during growth — `shouldRepaint` only governs rebuild-driven repaints.)
- Wrap the grid `CustomPaint` in [main.dart](../lib/main.dart) (~line 563) in a
  `RepaintBoundary`, isolating it from the zone counters / dominance banner / mode bar so
  their `setState`s don't invalidate the ink and vice-versa.

**Verify:** toggling a mode/counter mid-idle no longer repaints the grid (DevTools "repaint
rainbow"). **Risk:** low.

### Phase 3 — Cache the static background as its own layer (Option 3a)

Split Pass 1 (the 469 hex backgrounds + grid lines + border tints, lines 76–78 and
`_drawCellBackground`) out into a second `CustomPainter` (`HexGridBackgroundPainter`) whose
`shouldRepaint` returns false unless `grid.radius`, `hexSize`, `innerRadius`, or the zone
layout changes — the background does **not** depend on which cells are alive, so it's
effectively static across a whole session of stepping. Wrap it in its own `RepaintBoundary`
and stack the animated ink painter on top (a `Stack` of two `CustomPaint`s, or the
background as the `child` of the ink `CustomPaint`).

**Effect:** the 469-cell fill+stroke pass stops running on every animation frame — it
rasterizes once and is reused. **Verify:** DevTools raster timeline shows the background
draw calls gone from growth-window frames. **Risk:** low–medium (just get the invalidation
triggers right).

### Phase 4 — Measure on Pixel 6, then decide on the goo layer (Option 3b), GATED

After Phases 1–3, profile on the Pixel 6 (see verification below) on a **busy** grid. The
remaining per-frame GPU cost is the metaball "goo" `saveLayer` (lines 171–190), which still
redraws and re-blurs **every** ink primitive each frame — Phase 1 fixed the geometry churn
and the look, but not this, because the metaball merge needs all connected primitives in
one layer. If Pixel 6 frames are still over budget, pursue in this order and stop as soon
as it's smooth:

1. **Single whole-layer blur instead of per-primitive `MaskFilter.blur`.** Today each
   `drawPath`/`drawCircle` carries its own blur mask (N blur ops/frame). Draw the shapes
   *sharp* into an inner `saveLayer` that carries one `ImageFilter.blur`, nested inside the
   outer threshold-`colorFilter` layer — one blur pass over the group instead of N. Verify
   the visual result matches (blur order vs. threshold) on-device before committing; this
   is the highest-leverage GPU change if it holds up.
2. **Cache the fully-grown "stable" goo'd ink into a `ui.Picture` once per step** and, during
   the 500 ms animation, replay that picture and run the live goo pass only over the small
   born/dying set. This is what makes the blur cost scale with *how much changed*. It
   depends on Phase 1's clean stable/changing split. Invalidate on grid/size/zone/theme
   change. **Risk:** medium — caching invalidation must be exact. Do this last, only if #1
   isn't enough.
3. **Blunt safety valves** if still needed: slightly smaller blur sigma
   (`_gooBlurSigma`, currently `hexSize * 0.16`), or cap the growth animation's effective
   frame count / shorten `_growthDuration`.

## How to verify (per phase, and final)

- **Cheap loop:** `flutter run --profile -d linux` (Linux desktop build confirmed working)
  with the **performance overlay** — watch the UI (CPU) and raster (GPU) bars during
  auto-run. Phase 1 should visibly drop the UI bar; Phase 3 the raster bar.
- **DevTools → Performance** frame timeline: flag frames over the budget during the growth
  window; confirm background draw calls disappear after Phase 3 and `saveLayer`/blur op
  count drops after Phase 4.
- **The honest test is a busy grid** (many alive cells) — an empty grid hides all of this.
- **The gate is the Pixel 6**, in `--profile`, on a busy grid: the growth window should
  hold ~11 ms/frame (90 Hz). Per the handoff notes, anything device-facing needs at least
  one real-device pass before it's called done — this is that pass.

## What this plan deliberately does NOT touch

The CA rules, `stepper.dart`, the step cadence, the goo *aesthetic*, and anything
consensus-visible. `RULESET_VERSION` does not move — this is pure client-side rendering, no
circuit or golden-vector impact. Phase 1's only behavioral change is fixing the unintended
re-flow, which the code's own comments already describe as the intended behavior.
