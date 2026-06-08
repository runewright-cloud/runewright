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

## Region boundaries

| Region | Definition | Cell count |
|---|---|---|
| Inscribable | ring `<= 8` (i.e. `max(|q|,|r|,|q+r|) <= 8`) | 217 |
| Buffer | rings 9..11 | 180 |
| Border | ring 12 (i.e. `max(|q|,|r|,|q+r|) == 12`) | 72 |
| **Total** | | **469** |

## Border zone assignment

The 72 border cells are partitioned into elemental zones by enumerating ring-12 cells clockwise
starting from `(0, -12)`, rotating one cell clockwise (i.e. starting from the second cell in
clockwise order), then assigning zones in the following segments:

| Segment | Zone | Cells |
|---|---|---|
| 1 | Fire | 9 |
| 2 | Air | 9 |
| 3 | Water | 9 |
| 4 | Earth | 18 |
| 5 | Water | 9 |
| 6 | Air | 9 |
| 7 | Fire | 9 |

Total: 72 cells.  Fire = 18, Air = 18, Water = 18, Earth = 18.

The starting corner is the cell at `(1, -12)` (one step clockwise from the topmost cell `(0, -12)`),
and proceeds clockwise around the ring. This matches `BorderZones._compute` in the Dart source.

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

## Poseidon2 commitment construction

`commitment = Poseidon2_sponge(grid_state[0..468] || T)`

Sponge parameters (BN254 Poseidon2, Noir stdlib):
- State size: 4 fields
- Rate: 3 (fields 0, 1, 2 absorb data; field 3 is capacity)
- Capacity: 1
- Padding: after the final partial block, the capacity lane receives `+1`

Absorption sequence:
1. 156 full blocks of 3 fields each (`grid_state[0..467]`), each followed by a permutation
2. Final partial block: `grid_state[468]`, `T as Field`, padding `1`; then one permutation
3. Output: `state[0]` after the final permutation

Dart-side commitment verification will need to implement the same sponge sequence to
reproduce the circuit's commitment output.
