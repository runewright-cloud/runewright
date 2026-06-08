mod constants;

use crate::constants::{N, IS_BORDER, NEIGHBORS, BORDER_ZONE};

// Number of simulation steps. Benchmark script changes this global and recompiles.
global T: u32 = 20;

// Rule indices: 0=neutral, 1=fire, 2=air(wind), 3=water, 4=earth
// Matches CARules in the Dart implementation.

// -- Rule application

// Returns 1 if the cell should be alive next step, else 0.
// state: 0 or 1 as Field.  nb: 0..6 neighbor count as u8.  rule: 0..4 as u32.
fn apply_rule(state: Field, nb: u8, rule: u32) -> Field {
    if rule == 0 {
        // neutral: survive {2}, born {2}
        (nb == 2) as Field
    } else if rule == 1 {
        // fire: survive {1}, born {1,2,3,4,5,6}
        let s: Field = (state == 1) as Field;
        let survives = s * ((nb == 1) as Field);
        let born = (1 - s) * ((nb >= 1) as Field);
        survives + born
    } else if rule == 2 {
        // air (wind in Dart): survive {0,1,2}, born {2}
        let s: Field = (state == 1) as Field;
        let survives = s * ((nb <= 2) as Field);
        let born = (1 - s) * ((nb == 2) as Field);
        survives + born
    } else if rule == 3 {
        // water: survive {3,4,5,6}, born {2,3,4,5,6}
        let s: Field = (state == 1) as Field;
        let survives = s * ((nb >= 3) as Field);
        let born = (1 - s) * ((nb >= 2) as Field);
        survives + born
    } else {
        // earth: survive {2,3,4,5,6}, born {2,3,4,5,6}
        ((nb >= 2) as Field)
    }
}

// Born-only check for dead border cells (alive border cells always die immediately).
fn check_born(nb: u8, rule: u32) -> Field {
    if rule == 0 {
        (nb == 2) as Field
    } else if rule == 1 {
        (nb >= 1) as Field
    } else if rule == 2 {
        (nb == 2) as Field
    } else if rule == 3 {
        (nb >= 2) as Field
    } else {
        (nb >= 2) as Field
    }
}

// -- Dominance helpers

fn max4(a: [u32; 4]) -> u32 {
    let m01 = if a[0] > a[1] { a[0] } else { a[1] };
    let m23 = if a[2] > a[3] { a[2] } else { a[3] };
    if m01 > m23 { m01 } else { m23 }
}

// Returns dominant rule index (0=neutral, 1..4=elements).
// Sticky on ties: multiple zones tie -> keep current_rule.
fn dominant_rule(pressures: [u32; 4], current_rule: u32) -> u32 {
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
        // After the loop, leader = last zone whose pressure equals mp.
        // Correct when cnt == 1 (single leader).
        let mut leader: u32 = 0;
        for z in 0..4 {
            if pressures[z] == mp {
                leader = z + 1;
            }
        }
        if cnt == 1 { leader } else { current_rule }
    }
}

// -- Commitment hash: Poseidon2 duplex sponge over (grid_state || T)
// State size 4, rate 3, capacity 1.
// 470 inputs = 156 full blocks of 3 + 2 remaining, then padding.

fn commitment_hash(grid_state: [Field; N], t_val: Field) -> Field {
    let mut state: [Field; 4] = [0, 0, 0, 0];

    // Build a flat 470-element array: grid_state[0..469] then t_val.
    // Rather than allocating it, absorb directly.

    // 156 full blocks of 3 from grid_state (indices 0..467 inclusive = 468 elements)
    for block in 0..156 {
        state[0] = state[0] + grid_state[block * 3];
        state[1] = state[1] + grid_state[block * 3 + 1];
        state[2] = state[2] + grid_state[block * 3 + 2];
        state = std::hash::poseidon2_permutation(state);
    }
    // Remaining: grid_state[468], then t_val, then padding marker.
    // 156*3 = 468, so grid_state[468] is one element, t_val is the second.
    state[0] = state[0] + grid_state[468];
    state[1] = state[1] + t_val;
    state[2] = state[2] + 1; // padding
    state = std::hash::poseidon2_permutation(state);
    state[0]
}

// -- Main circuit

fn main(
    grid_state: [Field; N],
) -> pub (Field, [Field; 4], [Field; T], [Field; T]) {

    let mut grid = grid_state;
    let mut zone_pressure: [u32; 4] = [0, 0, 0, 0]; // cumulative (fire,air,water,earth)
    let mut rule: u32 = 0;                            // current rule index

    let mut total_border_acts: [Field; 4] = [0, 0, 0, 0];
    let mut dominance_trajectory: [Field; T] = [0; T];
    let mut supreme_flags: [Field; T] = [0; T];

    for t in 0..T {
        let mut next_grid: [Field; N] = [0; N];
        let mut step_acts: [u32; 4] = [0, 0, 0, 0];

        for i in 0..N {
            // Neighbor sum. NEIGHBORS[i][j] is a compile-time constant (global array
            // accessed with compile-time loop index i). N-sentinel means no neighbor.
            let nb: Field =
                (if NEIGHBORS[i][0] < N { grid[NEIGHBORS[i][0]] } else { 0 }) +
                (if NEIGHBORS[i][1] < N { grid[NEIGHBORS[i][1]] } else { 0 }) +
                (if NEIGHBORS[i][2] < N { grid[NEIGHBORS[i][2]] } else { 0 }) +
                (if NEIGHBORS[i][3] < N { grid[NEIGHBORS[i][3]] } else { 0 }) +
                (if NEIGHBORS[i][4] < N { grid[NEIGHBORS[i][4]] } else { 0 }) +
                (if NEIGHBORS[i][5] < N { grid[NEIGHBORS[i][5]] } else { 0 });
            let nb_u8 = nb as u8;

            let next_cell: Field = if IS_BORDER[i] {
                if grid[i] == 1 { 0 } else { check_born(nb_u8, rule) }
            } else {
                apply_rule(grid[i], nb_u8, rule)
            };
            next_grid[i] = next_cell;

            // Border birth accounting. IS_BORDER[i] and BORDER_ZONE[i] are compile-time,
            // so this block is present only for the 72 border cells (dead code for others).
            if IS_BORDER[i] {
                let b = next_cell as u32;
                step_acts[0] += ((BORDER_ZONE[i] == 1) as u32) * b;
                step_acts[1] += ((BORDER_ZONE[i] == 2) as u32) * b;
                step_acts[2] += ((BORDER_ZONE[i] == 3) as u32) * b;
                step_acts[3] += ((BORDER_ZONE[i] == 4) as u32) * b;
            }
        }

        // Accumulate activations.
        for z in 0..4 {
            zone_pressure[z] = zone_pressure[z] + step_acts[z];
            total_border_acts[z] = total_border_acts[z] + (step_acts[z] as Field);
        }

        // Decay active zone by floor((t+1)/2). Matches _decayActiveZone in main.dart
        // which subtracts stepCount / 2 (integer division) from the active zone.
        let decay: u32 = (t + 1) / 2;
        for z in 0..4 {
            let is_active: u32 = (rule == (z + 1)) as u32;
            let new_p: u32 = if zone_pressure[z] > decay { zone_pressure[z] - decay } else { 0 };
            zone_pressure[z] = is_active * new_p + (1 - is_active) * zone_pressure[z];
        }

        // Compute new dominant rule.
        rule = dominant_rule(zone_pressure, rule);
        dominance_trajectory[t] = rule as Field;

        // Supreme: dominant zone pressure strictly exceeds sum of the other three.
        let p_dom: u32 =
            ((rule == 1) as u32) * zone_pressure[0] +
            ((rule == 2) as u32) * zone_pressure[1] +
            ((rule == 3) as u32) * zone_pressure[2] +
            ((rule == 4) as u32) * zone_pressure[3];
        let total_p: u32 =
            zone_pressure[0] + zone_pressure[1] + zone_pressure[2] + zone_pressure[3];
        supreme_flags[t] = ((rule != 0) & (p_dom > (total_p - p_dom))) as Field;

        grid = next_grid;
    }

    let commitment = commitment_hash(grid_state, T as Field);

    (commitment, total_border_acts, dominance_trajectory, supreme_flags)
}
