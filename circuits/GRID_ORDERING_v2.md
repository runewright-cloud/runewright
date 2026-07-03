# Grid Ordering v2

Canonical flat array ordering for the `grid_state` input to `ca_natural_v2` and `ca_lookup_v2`.

## Grid parameters

- Coordinate system: axial (q, r), vertex-down orientation
- Radius: 12 (rings 0..12 inclusive)
- Total cells: **469** (`1 + 3 * 12 * 13`)

## Ordering rule

Cells are enumerated by iterating q from -12 to +12 (inclusive), and for each q, iterating r from `max(-12, -q-12)` to `min(12, -q+12)` (inclusive). This matches the insertion order of `HexGrid(12)` in the Dart implementation.

```
index = 0
for q in -12 .. 12:
    r_min = max(-12, -q - 12)
    r_max = min( 12, -q + 12)
    for r in r_min .. r_max:
        cells[index] = (q, r)
        index += 1
```

First cell: `(q=-12, r=0)` at index 0.  
Last cell: `(q=12, r=0)` at index 468.

## Index assignments — worked examples

| Index | Coord (q, r) | Ring (hex dist) | Region |
|---|---|---|---|
| 0 | (−12, 0) | 12 | border |
| 1 | (−12, 1) | 12 | border |
| 13 | (−11, −1) | 12 | border |
| 233 | (0, −1) | 1 | inscribable |
| 234 | (0, 0) | 0 | inscribable (centre) |
| 235 | (0, 1) | 1 | inscribable |
| 468 | (12, 0) | 12 | border |

The q=−12 column (13 cells, all border) occupies indices 0–12. The inscribable cells
are not a contiguous index range — they appear throughout the array, interleaved with
buffer and border cells from each q-column.

## Region boundaries

| Region | Definition | Cell count |
|---|---|---|
| Inscribable | ring ≤ 8 (i.e. `max(|q|,|r|,|q+r|) ≤ 8`) | 217 |
| Buffer | rings 9..11 | 180 |
| Border | ring 12 (i.e. `max(|q|,|r|,|q+r|) == 12`) | 72 |
| **Total** | | **469** |

**Important:** the region a cell belongs to is determined by its hex distance, not by
whether its index is ≥ 217. The q-major traversal interleaves all three regions: e.g.
the first 13 indices (the q=−12 column) are all border cells.

## Border zone assignment

The 72 border cells are partitioned by enumerating ring-12 cells **counter-clockwise** starting
from `(0, 12)` (the bottom vertex, index 36 in the clockwise ring), assigning four uniform
18-cell segments:

| Segment | Zone | Cells | First cell | Last cell |
|---|---|---|---|---|
| 1 | Water | 18 | (0, 12) | (12, -5) |
| 2 | Air | 18 | (12, -6) | (1, -12) |
| 3 | Fire | 18 | (0, -12) | (-12, 5) |
| 4 | Earth | 18 | (-12, 6) | (-1, 12) |

Algorithm: `ring[(3*RADIUS - i + n) % n]` for i = 0..71, grouped into the four 18-cell segments.
This matches `BorderZones._compute` in `lib/engine/border_zones.dart`.

Spatial interpretation: Water = right side and lower-right; Air = upper-right and top edge;
Fire = top vertex, left side; Earth = lower-left and bottom edge.

Note: an earlier draft used 7 segments of 9-9-9-18-9-9-9 clockwise from ring[1].
That was a pre-playtest design; the 4×18 CCW layout is the ratified design (confirmed 2026-06-14).

## Rule indices

| Index | Element | Dart `CARules` name |
|---|---|---|
| 0 | Neutral | `neutral` |
| 1 | Fire | `fire` |
| 2 | Air | `wind` |
| 3 | Water | `water` |
| 4 | Earth | `earth` |

Note: the Dart source names the air element "Wind" (`CARules.wind`); the circuit uses index 2 for
this element throughout.

## Neighbor slot convention

The circuit constant `NEIGHBORS: [[u32; 6]; 469]` stores the 6 neighbours of every cell
in a fixed direction order. The 6 directions, in slot order, are:

| Slot | Direction (Δq, Δr) | Antipodal slot |
|---|---|---|
| 0 | (+1, 0) | 3 |
| 1 | (+1, −1) | 4 |
| 2 | (0, −1) | 5 |
| 3 | (−1, 0) | 0 |
| 4 | (−1, +1) | 1 |
| 5 | (0, +1) | 2 |

Slot k and slot k+3 are always **antipodal** — their direction vectors sum to (0, 0). This
pairing is load-bearing for the ink rules (Rule A checks whether both endpoints of an axis
are active; the circuit encodes each axis as a (k, k+3) pair).

**Off-grid sentinel:** when a neighbour coordinate falls outside the radius-12 grid,
`NEIGHBORS[i][slot]` holds `469` (= N, the total cell count). Circuit code guards with
`if nb_idx < N` before reading `grid_state[nb_idx]`.

**Worked example — centre cell, index 234, coord (0, 0):**

| Slot | Neighbour coord | Neighbour index (from `NEIGHBORS[234]`) |
|---|---|---|
| 0 | (1, 0) | 259 |
| 1 | (1, −1) | 258 |
| 2 | (0, −1) | 233 |
| 3 | (−1, 0) | 209 |
| 4 | (−1, 1) | 210 |
| 5 | (0, 1) | 235 |

All 6 neighbours of the centre are in-grid (it is 12 steps from every border) so no
sentinel fires here. These values are read directly from `constants.nr`.

The same direction order is used in `HexGrid.directions` (Dart) and `InkStep.directions`
(Dart); the three sources are byte-identical for these 6 entries.

## Commitment construction

The circuit produces `commitment = poseidon2_hash2(packed0, packed1)` where the two field
elements are obtained by bit-packing the 469-cell grid state:

```
packed0 = sum(grid_state[i] * 2^i  for i in 0..252)   // cells 0–252, 253 bits
packed1 = sum(grid_state[253+i] * 2^i  for i in 0..215) // cells 253–468, 216 bits
```

Each `grid_state[i]` is 0 or 1, so the sum is a standard binary number where cell `i`
occupies bit position `i` within its packed field element. The split at index 253 keeps
both packed values below the BN254 scalar field modulus (verified: 2^253 − 1 < p and
2^216 − 1 < p), so no field-wrap aliasing occurs and the mapping is injective.

`poseidon2_hash2` is a fixed-length 2-input hash (not a sponge):

```
iv = 2 * 2^64   // domain-separation tag for 2 inputs
state = [packed0, packed1, 0, iv]
state = poseidon2_permutation(state)   // BN254 Poseidon2 from Noir stdlib
commitment = state[0]
```

**T is not included in the commitment** (CLAUDE.md hard invariant 2). `T`, `owner_pubkey`,
and `ruleset_version` are separate public inputs, emitted alongside `commitment` in the
proof's public-input list but never folded into the hash. This keeps the commitment
purely a function of the grid, allowing counter-charm mechanics to target any spell cast
from the same initial grid regardless of who cast it or with what T.

The Dart side reads `commitment` from the proof's public-input bytes and treats it as
opaque — it never recomputes it (CLAUDE.md hard invariant 1: never reimplement Poseidon2
in Dart).
