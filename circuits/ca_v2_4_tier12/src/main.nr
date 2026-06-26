mod constants;

use crate::constants::{N, IS_BORDER, IS_BUFFER, NEIGHBORS, BORDER_ZONE, POW2_253, POW2_216};

global TIER_MAX: u32 = 12;
global RULESET_VERSION: Field = 2;

// Pulse cadence for the neutral ink ruleset's Rule E (serif flare) -- matches
// InkRules' production default (lib/engine/ink_step.dart). pulse(g) =
// ((g+1) % CADENCE == 0): the circuit's loop is 0-indexed `g`, with the same
// stepCount = g+1 convention the decay formula below already uses, so the
// pulse fires at g in {3, 7, 11} for TIER_MAX=12 -- see CIRCUIT_IO.md CIRCUIT_IO 10.5
// "Generation indexing / the pulse off-by-one".
global CADENCE: u32 = 4;

// Flat transition table for the FOUR ELEMENTAL rules only -- neutral is no
// longer count-based (see the ink branch in `main`), so the old rule-0
// Conway-2/2 row is gone and this table shrinks from 70 to 56 entries.
// FLAT_TRANSITION[(rule-1)*14 + state_bit*7 + nb], rule in 1..4 (never 0 --
// callers always clamp via `safe_rule` before indexing, see `main`).
// state_bit = 1 if alive, 0 if dead. nb in 0..6.
// Layout: 4 rules * 2 states * 7 neighbor counts = 56 entries.
// Rules match lib/engine/ca_rules.dart exactly (Dart is canonical, CLAUDE.md):
//   1 fire:    survive {1},          born {1}
//   2 air:     survive {0,1,2},      born {2}
//   3 water:   survive {2,3},          born {1}
//   4 earth:   survive {1,2,3,4,5,6}, born {2}
global FLAT_TRANSITION: [Field; 56] = [
    // rule 1 - fire
    0, 1, 0, 0, 0, 0, 0,   // dead
    0, 1, 0, 0, 0, 0, 0,   // alive
    // rule 2 - air (wind)
    0, 0, 1, 0, 0, 0, 0,   // dead
    1, 1, 1, 0, 0, 0, 0,   // alive
    // rule 3 - water
    0, 1, 0, 0, 0, 0, 0,   // dead
    0, 0, 1, 1, 0, 0, 0,   // alive
    // rule 4 - earth
    0, 0, 1, 0, 0, 0, 0,   // dead
    0, 1, 1, 1, 1, 1, 1,   // alive
];

// -- Poseidon2 fixed-length-2 hash, hand-rolled because Poseidon2::hash is
// pub(crate) in the beta.20 stdlib and not callable from this circuit.
// Bit-for-bit identical to Poseidon2::hash([a, b], 2) - see CIRCUIT_IO.md CIRCUIT_IO 4.
fn poseidon2_hash2(a: Field, b: Field) -> Field {
    let iv: Field = 2 * 18446744073709551616; // 2 * 2^64
    let mut state: [Field; 4] = [a, b, 0, iv];
    state = std::hash::poseidon2_permutation(state);
    state[0]
}

// -- Dominance helpers (mirror ca_run.dart's advanceDominance / _nextRule /
// _decayAtMaxPressure -- RULESET_VERSION 2: decay splits ceil(D/k) across
// every zone tied at the max pressure, not just one dispatched zone; a tie
// reports dominant=0 with no sticky-previous-rule fallback; dispatch gates
// the elemental rule behind supreme dominance. See CIRCUIT_IO.md CIRCUIT_IO 10.5.)

fn max4(a: [u32; 4]) -> u32 {
    let m01 = if a[0] > a[1] { a[0] } else { a[1] };
    let m23 = if a[2] > a[3] { a[2] } else { a[3] };
    if m01 > m23 { m01 } else { m23 }
}

// Decays every zone at the max pressure by ceil(d / k), k = how many zones
// are tied at that max. A unique leader (k=1) decays by the full `d` --
// identical to the old single-zone decay in the no-tie case. Pure function
// of the pressure table: unlike the old `_decayActiveZone`, this no longer
// takes a "current rule" -- nothing here depends on which rule is/was
// dispatched.
fn decay_at_max_pressure(pressures: [u32; 4], d: u32) -> [u32; 4] {
    let mp = max4(pressures);
    if mp == 0 {
        pressures
    } else {
        let k: u32 =
            ((pressures[0] == mp) as u32) +
            ((pressures[1] == mp) as u32) +
            ((pressures[2] == mp) as u32) +
            ((pressures[3] == mp) as u32);
        let dec: u32 = (d + k - 1) / k; // ceil(d / k)
        let mut out: [u32; 4] = pressures;
        for z in 0..4 {
            if pressures[z] == mp {
                out[z] = if mp > dec { mp - dec } else { 0 };
            }
        }
        out
    }
}

// Dominant element (1..4) from decayed pressures, or 0 on a tie / all-zero.
// No "current rule" input: a tie no longer sticks to the previous leader
// (CIRCUIT_IO.md CIRCUIT_IO 10.5 decay/ties subsection) -- this makes
// `dominant_element` a pure function of `pressures` alone.
fn dominant_element(pressures: [u32; 4]) -> u32 {
    let all_zero =
        (pressures[0] == 0) &
        (pressures[1] == 0) &
        (pressures[2] == 0) &
        (pressures[3] == 0);
    if all_zero {
        0
    } else {
        let mp = max4(pressures);
        let cnt: u32 =
            ((pressures[0] == mp) as u32) +
            ((pressures[1] == mp) as u32) +
            ((pressures[2] == mp) as u32) +
            ((pressures[3] == mp) as u32);
        let mut leader: u32 = 0;
        for z in 0..4 {
            if pressures[z] == mp {
                leader = z + 1;
            }
        }
        if cnt == 1 { leader } else { 0 }
    }
}

// -- Main circuit
//
// Public input ABI order (Noir lists pub params, then return values):
//   T, owner_pubkey, ruleset_version, commitment, border_activations[4],
//   dominance_trajectory[TIER_MAX], supreme_dominance_flags[TIER_MAX]
// See CIRCUIT_IO.md CIRCUIT_IO 8.
fn main(
    grid_state: [Field; N],
    key_hi: Field,
    key_lo: Field,
    T: pub Field,
    owner_pubkey: pub Field,
    ruleset_version: pub Field,
) -> pub (Field, [Field; 4], [Field; TIER_MAX], [Field; TIER_MAX]) {

    // CIRCUIT_IO 10.9 - owner_pubkey / ruleset_version bound into the VK (locked construction,
    // see CIRCUIT_IO.md CIRCUIT_IO 5/CIRCUIT_IO 6 - never add inputs to this hash or this assertion).
    assert(ruleset_version == RULESET_VERSION);
    assert(owner_pubkey == poseidon2_hash2(key_hi, key_lo));

    // CIRCUIT_IO 10.8 - T range, for this tier.
    let t_u32: u32 = T as u32;
    assert(t_u32 >= 1);
    assert(t_u32 <= TIER_MAX);

    // CIRCUIT_IO 10.1 - every cell boolean.
    for i in 0..N {
        assert(grid_state[i] * (grid_state[i] - 1) == 0);
    }

    // CIRCUIT_IO 10.2 - buffer + border cells must be 0 at T=0 (region check, not index range -
    // CLAUDE.md's "index >= 217" framing is wrong; CIRCUIT_IO.md CIRCUIT_IO 2 confirms regions
    // are scattered by hex distance, not contiguous index blocks).
    for i in 0..N {
        if IS_BORDER[i] | IS_BUFFER[i] {
            assert(grid_state[i] == 0);
        }
    }

    // CIRCUIT_IO 3 - bit-packing for the commitment.
    let mut packed0: Field = 0;
    for i in 0..253 {
        packed0 += grid_state[i] * POW2_253[i];
    }
    let mut packed1: Field = 0;
    for i in 0..216 {
        packed1 += grid_state[253 + i] * POW2_216[i];
    }

    // CIRCUIT_IO 4 - commitment is grid-only. Never fold T/owner_pubkey/ruleset_version in here.
    let commitment = poseidon2_hash2(packed0, packed1);

    // CIRCUIT_IO 10.5 - CA evolution. The circuit's loop bound is fixed at TIER_MAX regardless
    // of T (a circuit can't have a variable-length loop); T only masks which outputs
    // are externally visible (CIRCUIT_IO 7, CIRCUIT_IO 10.6, CIRCUIT_IO 10.7 - see CIRCUIT_IO.md M3.0 correction).
    let mut grid = grid_state;
    let mut zone_pressure: [u32; 4] = [0, 0, 0, 0];
    let mut rule: u32 = 0;

    let mut total_border_acts: [Field; 4] = [0, 0, 0, 0];
    let mut dominance_trajectory: [Field; TIER_MAX] = [0; TIER_MAX];
    let mut supreme_flags: [Field; TIER_MAX] = [0; TIER_MAX];

    for t in 0..TIER_MAX {
        // gen_active = 1 for t < T, 0 otherwise - masks every public output below,
        // but never the internal grid/pressure/rule state (that keeps evolving for
        // all TIER_MAX generations regardless of T).
        let gen_active: Field = (t < t_u32) as Field;

        // `rule` is this generation's dispatched rule (0 = neutral, set at the end
        // of the PREVIOUS iteration -- or 0 initially). `safe_rule` avoids a u32
        // underflow on (rule-1) when rule==0; the elemental branch's result is
        // discarded by the `is_neutral` select below regardless of what
        // `safe_rule` computes, so its value when neutral is irrelevant.
        let is_neutral: bool = rule == 0;
        let safe_rule: u32 = if is_neutral { 1 } else { rule };

        // Rule E pulse gate for this generation -- see the CADENCE comment above.
        let pulse: bool = ((t + 1) % CADENCE) == 0;

        // ---- Pass 1 (CIRCUIT_IO.md CIRCUIT_IO 10.5 "Rule B as two distance-1
        // passes"): per-cell ink intermediates derived from `grid` (the prior
        // generation's state) only. Computed for ALL cells unconditionally --
        // both the ink and elemental branches are evaluated every generation
        // regardless of which is dispatched (a witness-dependent rule mux pays
        // for both branches; see the Part 1 pre-check), so there is nothing to
        // gain by trying to skip this when rule != 0.
        let mut b_ext: [Field; N] = [0; N];
        let mut born_a: [bool; N] = [false; N];
        let mut born_serif_raw: [bool; N] = [false; N];
        let mut nb_count_arr: [u32; N] = [0; N];

        for i in 0..N {
            let g0: Field = if NEIGHBORS[i][0] < N { grid[NEIGHBORS[i][0]] } else { 0 };
            let g1: Field = if NEIGHBORS[i][1] < N { grid[NEIGHBORS[i][1]] } else { 0 };
            let g2: Field = if NEIGHBORS[i][2] < N { grid[NEIGHBORS[i][2]] } else { 0 };
            let g3: Field = if NEIGHBORS[i][3] < N { grid[NEIGHBORS[i][3]] } else { 0 };
            let g4: Field = if NEIGHBORS[i][4] < N { grid[NEIGHBORS[i][4]] } else { 0 };
            let g5: Field = if NEIGHBORS[i][5] < N { grid[NEIGHBORS[i][5]] } else { 0 };
            let n0: bool = g0 == 1;
            let n1: bool = g1 == 1;
            let n2: bool = g2 == 1;
            let n3: bool = g3 == 1;
            let n4: bool = g4 == 1;
            let n5: bool = g5 == 1;

            let cnt: u32 = (n0 as u32) + (n1 as u32) + (n2 as u32) + (n3 as u32) + (n4 as u32) + (n5 as u32);
            nb_count_arr[i] = cnt;

            // Rule A: complete antipodal axis -- slot k / slot (k+3)%6 are
            // antipodal (CIRCUIT_IO.md CIRCUIT_IO 2 NEIGHBORS slot-order note).
            let axis_complete: bool = (n0 & n3) | (n1 & n4) | (n2 & n5);
            let is_dead: bool = grid[i] == 0;
            born_a[i] = is_dead & axis_complete;
            // Rule E source condition (pulse-gating applied in Pass 2).
            born_serif_raw[i] = is_dead & (cnt == 1);

            // Rule B Pass 1: b_ext[i] is a DERIVED value -- a direct function of
            // `grid`/the neighbor bits computed above, never a free witness, so
            // there is no opportunity for a prover to supply an arbitrary
            // intermediate (CIRCUIT_IO.md CIRCUIT_IO 10.11 / CIRCUIT_IO 11.9).
            let is_source: bool = (grid[i] == 1) & (cnt == 1);
            let s: u32 = 0 * (n0 as u32) + 1 * (n1 as u32) + 2 * (n2 as u32) + 3 * (n3 as u32) + 4 * (n4 as u32) + 5 * (n5 as u32);
            let d_ext: u32 = (s + 3) % 6;
            let computed_b_ext: Field = (is_source as Field) * ((d_ext + 1) as Field);
            b_ext[i] = computed_b_ext;
            // CIRCUIT_IO 10.11, explicit defense-in-depth: restated as an
            // assert (not just the assignment above) so a future refactor that
            // changes b_ext into a separately-witnessed value can't silently
            // drop this constraint without a compile/proving failure here.
            assert(b_ext[i] == computed_b_ext);
        }

        // ---- Pass 2: gather Rule B's bornB from Pass 1's b_ext, assemble
        // next_grid for both branches, select on `is_neutral`, and accumulate
        // border activations. ----
        let mut next_grid: [Field; N] = [0; N];
        let mut step_acts: [u32; 4] = [0, 0, 0, 0];

        for i in 0..N {
            // Rule B Pass 2 (gather): X = NEIGHBORS[i][e] extends into `i`
            // exactly when X's extension direction equals (e+3)%6 -- if X is at
            // slot e from i, i is at slot (e+3)%6 from X.
            let x0 = NEIGHBORS[i][0];
            let x1 = NEIGHBORS[i][1];
            let x2 = NEIGHBORS[i][2];
            let x3 = NEIGHBORS[i][3];
            let x4 = NEIGHBORS[i][4];
            let x5 = NEIGHBORS[i][5];
            let bx0: Field = if x0 < N { b_ext[x0] } else { 0 };
            let bx1: Field = if x1 < N { b_ext[x1] } else { 0 };
            let bx2: Field = if x2 < N { b_ext[x2] } else { 0 };
            let bx3: Field = if x3 < N { b_ext[x3] } else { 0 };
            let bx4: Field = if x4 < N { b_ext[x4] } else { 0 };
            let bx5: Field = if x5 < N { b_ext[x5] } else { 0 };
            let born_b: bool =
                (bx0 == (((0 + 3) % 6) + 1) as Field) |
                (bx1 == (((1 + 3) % 6) + 1) as Field) |
                (bx2 == (((2 + 3) % 6) + 1) as Field) |
                (bx3 == (((3 + 3) % 6) + 1) as Field) |
                (bx4 == (((4 + 3) % 6) + 1) as Field) |
                (bx5 == (((5 + 3) % 6) + 1) as Field);

            let born_serif: bool = pulse & born_serif_raw[i];
            let ink_birth: bool = born_a[i] | born_b | born_serif;
            let prev_active: bool = grid[i] == 1;
            // Rule D, realized structurally as a monotone union -- never a
            // separate death rule (CIRCUIT_IO.md CIRCUIT_IO 10.5).
            let ink_next_active: bool = prev_active | ink_birth;

            let nb_u32 = nb_count_arr[i];
            let state_bit: u32 = (grid[i] == 1) as u32;
            let elem_idx: u32 = (safe_rule - 1) * 14 + state_bit * 7 + nb_u32;
            let elemental_next: Field = FLAT_TRANSITION[elem_idx];

            if IS_BORDER[i] {
                // Border cells always die the following step (stepper.dart:15-35),
                // unchanged by the ink substrate -- only WHICH birth conditions
                // trigger the counted activation changes (ink birth conditions
                // here, the old count rule before RULESET_VERSION 2).
                next_grid[i] = 0;

                let is_dead_b: bool = grid[i] == 0;
                let elem_dead_idx: u32 = (safe_rule - 1) * 14 + 0 * 7 + nb_u32;
                let activated_elem: bool = is_dead_b & (FLAT_TRANSITION[elem_dead_idx] == 1);
                let activated_ink: bool = is_dead_b & ink_birth;
                let activated: bool = if is_neutral { activated_ink } else { activated_elem };

                let b = activated as u32;
                step_acts[0] += ((BORDER_ZONE[i] == 1) as u32) * b;
                step_acts[1] += ((BORDER_ZONE[i] == 2) as u32) * b;
                step_acts[2] += ((BORDER_ZONE[i] == 3) as u32) * b;
                step_acts[3] += ((BORDER_ZONE[i] == 4) as u32) * b;
            } else {
                // CIRCUIT_IO 10.10, neutral generations only: explicit
                // monotonicity assert -- defense-in-depth even though
                // ink_next_active is already constructed as a union of `prev`
                // and birth conditions above, so this is implied by
                // construction today. Kept as an explicit, auditable
                // constraint so a future refactor of how next_grid is computed
                // can't silently lose the no-deaths guarantee. Elemental rules
                // are NOT covered -- they can and do kill cells (e.g. fire
                // dies outside its surviveOn set), so this only applies when
                // is_neutral.
                if is_neutral {
                    assert(grid[i] * (1 - (ink_next_active as Field)) == 0);
                }
                next_grid[i] = if is_neutral { ink_next_active as Field } else { elemental_next };
            }
        }

        for z in 0..4 {
            // Internal pressure accumulation is unmasked (mechanical CA state).
            zone_pressure[z] = zone_pressure[z] + step_acts[z];
            // The published running total is masked - CIRCUIT_IO 10.6 / neg_mask_abuse.
            total_border_acts[z] = total_border_acts[z] + gen_active * (step_acts[z] as Field);
        }

        // CIRCUIT_IO 10.5 decay/ties subsection: ceil(D/k) over the
        // max-pressure set, pure function of the pressure table.
        let d: u32 = (t + 1) / 2;
        zone_pressure = decay_at_max_pressure(zone_pressure, d);

        // CIRCUIT_IO 10.5 decay/ties subsection: tie -> dominant 0, no sticky
        // fallback.
        let dominant: u32 = dominant_element(zone_pressure);

        // dominance_trajectory reports the DOMINANT element (the spell's
        // elemental signature), not the gated dispatch rule -- a generation
        // may report e.g. fire here while the grid evolves under neutral ink
        // because fire wasn't supreme this generation. See CIRCUIT_IO.md
        // CIRCUIT_IO 10.5 "Rule dispatch" subsection.
        dominance_trajectory[t] = gen_active * (dominant as Field);

        let p_dom: u32 =
            ((dominant == 1) as u32) * zone_pressure[0] +
            ((dominant == 2) as u32) * zone_pressure[1] +
            ((dominant == 3) as u32) * zone_pressure[2] +
            ((dominant == 4) as u32) * zone_pressure[3];
        let total_p: u32 =
            zone_pressure[0] + zone_pressure[1] + zone_pressure[2] + zone_pressure[3];
        // Computed ONCE, used for both the emitted flag below AND next
        // iteration's dispatch gate (`rule = ...` below) -- CIRCUIT_IO.md
        // CIRCUIT_IO 10.5 requires the dispatch signal and the emitted flag to
        // be the literal same computation.
        let supreme_this_gen: bool = (dominant != 0) & (p_dom > (total_p - p_dom));
        supreme_flags[t] = gen_active * (supreme_this_gen as Field);

        // CIRCUIT_IO 10.5 "Rule dispatch" subsection: gate the elemental rule
        // behind supreme dominance, mirroring ca_run.dart's advanceDominance.
        // This becomes `rule` for the NEXT generation's Pass 1/Pass 2 above.
        rule = if supreme_this_gen { dominant } else { 0 };

        grid = next_grid;
    }

    (commitment, total_border_acts, dominance_trajectory, supreme_flags)
}
