mod constants;

use crate::constants::{N, IS_BORDER, IS_BUFFER, NEIGHBORS, BORDER_ZONE, POW2_253, POW2_216};

global TIER_MAX: u32 = 12;
global RULESET_VERSION: Field = 1;

// Flat transition table: FLAT_TRANSITION[rule * 14 + state_bit * 7 + nb]
// state_bit = 1 if alive, 0 if dead.  nb in 0..6.
// Layout: 5 rules * 2 states * 7 neighbor counts = 70 entries.
// Rules match lib/engine/ca_rules.dart exactly (Dart is canonical, CLAUDE.md):
//   0 neutral: survive {2},          born {2}
//   1 fire:    survive {1},          born {1}
//   2 air:     survive {0,1,2},      born {2}
//   3 water:   survive {3,4,5,6},    born {1,2}
//   4 earth:   survive {1,2,3,4,5,6}, born {2}
global FLAT_TRANSITION: [Field; 70] = [
    // rule 0 - neutral
    0, 0, 1, 0, 0, 0, 0,   // dead
    0, 0, 1, 0, 0, 0, 0,   // alive
    // rule 1 - fire
    0, 1, 0, 0, 0, 0, 0,   // dead
    0, 1, 0, 0, 0, 0, 0,   // alive
    // rule 2 - air (wind)
    0, 0, 1, 0, 0, 0, 0,   // dead
    1, 1, 1, 0, 0, 0, 0,   // alive
    // rule 3 - water
    0, 1, 1, 0, 0, 0, 0,   // dead
    0, 0, 0, 1, 1, 1, 1,   // alive
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

// -- Dominance helpers (mirror ca_run.dart's _nextRule / _isSupreme)

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

            if IS_BORDER[i] {
                // Border cells always die next generation (stepper.dart:15-35) -
                // the Phase 1.5 proxy circuit got this wrong (CIRCUIT_IO.md CIRCUIT_IO 10
                // M3.0 correction). A dead border cell satisfying bornOn still
                // counts as an activation, but the cell itself stays 0.
                next_grid[i] = 0;

                let is_dead: Field = (grid[i] == 0) as Field;
                let born = FLAT_TRANSITION[rule * 14 + nb_u32];
                let activated = is_dead * born;
                let b = activated as u32;
                step_acts[0] += ((BORDER_ZONE[i] == 1) as u32) * b;
                step_acts[1] += ((BORDER_ZONE[i] == 2) as u32) * b;
                step_acts[2] += ((BORDER_ZONE[i] == 3) as u32) * b;
                step_acts[3] += ((BORDER_ZONE[i] == 4) as u32) * b;
            } else {
                let state_bit: u32 = (grid[i] == 1) as u32;
                next_grid[i] = FLAT_TRANSITION[rule * 14 + state_bit * 7 + nb_u32];
            }
        }

        for z in 0..4 {
            // Internal pressure accumulation is unmasked (mechanical CA state).
            zone_pressure[z] = zone_pressure[z] + step_acts[z];
            // The published running total is masked - CIRCUIT_IO 10.6 / neg_mask_abuse.
            total_border_acts[z] = total_border_acts[z] + gen_active * (step_acts[z] as Field);
        }

        let decay: u32 = (t + 1) / 2;
        for z in 0..4 {
            let is_active: u32 = (rule == (z + 1)) as u32;
            let new_p: u32 = if zone_pressure[z] > decay { zone_pressure[z] - decay } else { 0 };
            zone_pressure[z] = is_active * new_p + (1 - is_active) * zone_pressure[z];
        }

        rule = dominant_rule(zone_pressure, rule);

        // CIRCUIT_IO 10.7 - masked trajectory/flags: 0 for gen >= T, matching ca_run.dart's
        // zero-filled output exactly (not "real but unconsumed" - see CIRCUIT_IO.md
        // CIRCUIT_IO 7 M3.0 correction).
        dominance_trajectory[t] = gen_active * (rule as Field);

        let p_dom: u32 =
            ((rule == 1) as u32) * zone_pressure[0] +
            ((rule == 2) as u32) * zone_pressure[1] +
            ((rule == 3) as u32) * zone_pressure[2] +
            ((rule == 4) as u32) * zone_pressure[3];
        let total_p: u32 =
            zone_pressure[0] + zone_pressure[1] + zone_pressure[2] + zone_pressure[3];
        let supreme_this_gen: Field = ((rule != 0) & (p_dom > (total_p - p_dom))) as Field;
        supreme_flags[t] = gen_active * supreme_this_gen;

        grid = next_grid;
    }

    (commitment, total_border_acts, dominance_trajectory, supreme_flags)
}
