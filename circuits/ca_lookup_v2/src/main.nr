mod constants;

use crate::constants::{N, IS_BORDER, NEIGHBORS, BORDER_ZONE};

global T: u32 = 20;

// Flat transition table: FLAT_TRANSITION[rule * 14 + state_bit * 7 + nb]
// state_bit = 1 if alive, 0 if dead.  nb in 0..6.
// Layout: 5 rules * 2 states * 7 neighbor counts = 70 entries.
//
// Rule 0 (neutral): survive {2}, born {2}
//   dead:  0 0 1 0 0 0 0
//   alive: 0 0 1 0 0 0 0
// Rule 1 (fire): survive {1}, born {1..6}
//   dead:  0 1 1 1 1 1 1
//   alive: 0 1 0 0 0 0 0
// Rule 2 (air/wind): survive {0,1,2}, born {2}
//   dead:  0 0 1 0 0 0 0
//   alive: 1 1 1 0 0 0 0
// Rule 3 (water): survive {2,3}, born {1}
//   dead:  0 1 0 0 0 0 0
//   alive: 0 0 1 1 0 0 0
// Rule 4 (earth): survive {2..6}, born {2..6}
//   dead:  0 0 1 1 1 1 1
//   alive: 0 0 1 1 1 1 1
global FLAT_TRANSITION: [Field; 70] = [
    // rule 0 - neutral
    0, 0, 1, 0, 0, 0, 0,   // dead
    0, 0, 1, 0, 0, 0, 0,   // alive
    // rule 1 - fire
    0, 1, 1, 1, 1, 1, 1,   // dead
    0, 1, 0, 0, 0, 0, 0,   // alive
    // rule 2 - air (wind)
    0, 0, 1, 0, 0, 0, 0,   // dead
    1, 1, 1, 0, 0, 0, 0,   // alive
    // rule 3 - water
    0, 1, 0, 0, 0, 0, 0,   // dead
    0, 0, 1, 1, 0, 0, 0,   // alive
    // rule 4 - earth
    0, 0, 1, 1, 1, 1, 1,   // dead
    0, 0, 1, 1, 1, 1, 1,   // alive
];

// -- Dominance helpers (identical to ca_natural_v2)

fn max4(a: [u32; 4]) -> u32 {
    let m01 = if a[0] > a[1] { a[0] } else { a[1] };
    let m23 = if a[2] > a[3] { a[2] } else { a[3] };
    if m01 > m23 { m01 } else { m23 }
}

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
        let mut leader: u32 = 0;
        for z in 0..4 {
            if pressures[z] == mp {
                leader = z + 1;
            }
        }
        if cnt == 1 { leader } else { current_rule }
    }
}

// -- Commitment hash (identical to ca_natural_v2)

fn commitment_hash(grid_state: [Field; N], t_val: Field) -> Field {
    let mut state: [Field; 4] = [0, 0, 0, 0];
    for block in 0..156 {
        state[0] = state[0] + grid_state[block * 3];
        state[1] = state[1] + grid_state[block * 3 + 1];
        state[2] = state[2] + grid_state[block * 3 + 2];
        state = std::hash::poseidon2_permutation(state);
    }
    state[0] = state[0] + grid_state[468];
    state[1] = state[1] + t_val;
    state[2] = state[2] + 1;
    state = std::hash::poseidon2_permutation(state);
    state[0]
}

// -- Main circuit

fn main(
    grid_state: [Field; N],
) -> pub (Field, [Field; 4], [Field; T], [Field; T]) {

    let mut grid = grid_state;
    let mut zone_pressure: [u32; 4] = [0, 0, 0, 0];
    let mut rule: u32 = 0;

    let mut total_border_acts: [Field; 4] = [0, 0, 0, 0];
    let mut dominance_trajectory: [Field; T] = [0; T];
    let mut supreme_flags: [Field; T] = [0; T];

    for t in 0..T {
        let mut next_grid: [Field; N] = [0; N];
        let mut step_acts: [u32; 4] = [0, 0, 0, 0];

        for i in 0..N {
            let nb: Field =
                (if NEIGHBORS[i][0] < N { grid[NEIGHBORS[i][0]] } else { 0 }) +
                (if NEIGHBORS[i][1] < N { grid[NEIGHBORS[i][1]] } else { 0 }) +
                (if NEIGHBORS[i][2] < N { grid[NEIGHBORS[i][2]] } else { 0 }) +
                (if NEIGHBORS[i][3] < N { grid[NEIGHBORS[i][3]] } else { 0 }) +
                (if NEIGHBORS[i][4] < N { grid[NEIGHBORS[i][4]] } else { 0 }) +
                (if NEIGHBORS[i][5] < N { grid[NEIGHBORS[i][5]] } else { 0 });
            let nb_u32 = nb as u8 as u32; // 0..6, safe

            let next_cell: Field = if IS_BORDER[i] {
                // Alive border cells die unconditionally.
                // Dead border cells use the "dead row" of the table (state_bit=0).
                let born = FLAT_TRANSITION[rule * 14 + nb_u32];
                let is_dead: Field = (grid[i] == 0) as Field;
                is_dead * born
            } else {
                let state_bit: u32 = (grid[i] == 1) as u32;
                FLAT_TRANSITION[rule * 14 + state_bit * 7 + nb_u32]
            };
            next_grid[i] = next_cell;

            if IS_BORDER[i] {
                let b = next_cell as u32;
                step_acts[0] += ((BORDER_ZONE[i] == 1) as u32) * b;
                step_acts[1] += ((BORDER_ZONE[i] == 2) as u32) * b;
                step_acts[2] += ((BORDER_ZONE[i] == 3) as u32) * b;
                step_acts[3] += ((BORDER_ZONE[i] == 4) as u32) * b;
            }
        }

        for z in 0..4 {
            zone_pressure[z] = zone_pressure[z] + step_acts[z];
            total_border_acts[z] = total_border_acts[z] + (step_acts[z] as Field);
        }

        let decay: u32 = (t + 1) / 2;
        for z in 0..4 {
            let is_active: u32 = (rule == (z + 1)) as u32;
            let new_p: u32 = if zone_pressure[z] > decay { zone_pressure[z] - decay } else { 0 };
            zone_pressure[z] = is_active * new_p + (1 - is_active) * zone_pressure[z];
        }

        rule = dominant_rule(zone_pressure, rule);
        dominance_trajectory[t] = rule as Field;

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
