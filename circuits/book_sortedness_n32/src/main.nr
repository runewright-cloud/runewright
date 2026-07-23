// SPDX-License-Identifier: GPL-3.0-or-later
//
// book_sortedness_n32/src/main.nr -- Sortedness-circuit spike, N=32.
// See docs/SORTEDNESS_CIRCUIT_SPIKE.md. Measurement-only: the deliverable is
// the `bb gates` count at this N, not an integration (spike doc SS5).
//
// Proves that a chapter of N=32 committed spells is strictly ascending by
// commitmentHex (sorted + distinct) and that the leaves reconstruct the
// public Merkle root R exactly as book_commitment.dart's computeRoot does:
// interior node = SHA-256(left ++ right) over 32-byte halves, odd levels
// right-padded with the 32-byte zero node.
//
// Noir 1.0.0-beta.20's stdlib dropped the byte-oriented `std::hash::sha256`
// in favor of the raw `sha256_compression` block primitive (spike doc SS9's
// "confirm the stdlib sha256 byte-variant" turned out to not exist at this
// version) -- there is no full-message sha256 to call. Every hash here is
// over a fixed 64-byte message (two 32-byte halves), so this hand-builds the
// two-block FIPS-180-4 padding for exactly that length instead of a generic
// variable-length routine.

global N: u32 = 32;

// Standard SHA-256 IV (FIPS 180-4 SS5.3.3).
global SHA256_IV: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
    0x1f83d9ab, 0x5be0cd19,
];

fn bytes_to_words16(bytes: [u8; 64]) -> [u32; 16] {
    let mut out: [u32; 16] = [0; 16];
    for i in 0..16 {
        out[i] = (bytes[4 * i] as u32) * 16777216
            + (bytes[4 * i + 1] as u32) * 65536
            + (bytes[4 * i + 2] as u32) * 256
            + (bytes[4 * i + 3] as u32);
    }
    out
}

fn words8_to_bytes(words: [u32; 8]) -> [u8; 32] {
    let mut out: [u8; 32] = [0; 32];
    for i in 0..8 {
        let w = words[i];
        out[4 * i] = (w >> 24) as u8;
        out[4 * i + 1] = (w >> 16) as u8;
        out[4 * i + 2] = (w >> 8) as u8;
        out[4 * i + 3] = w as u8;
    }
    out
}

// SHA-256(left ++ right) -- book_commitment.dart's `_hashPair`, bit-for-bit.
// Fixed 64-byte input -> exactly two compression blocks: the message block,
// then the FIPS-180-4 padding block (0x80, zeros, 64-bit bit-length = 512).
fn hash_pair(left: [u8; 32], right: [u8; 32]) -> [u8; 32] {
    let mut msg: [u8; 64] = [0; 64];
    for i in 0..32 {
        msg[i] = left[i];
        msg[32 + i] = right[i];
    }
    let block0 = bytes_to_words16(msg);

    let mut block1: [u32; 16] = [0; 16];
    block1[0] = 0x80000000;
    block1[15] = 512; // bit-length of a 64-byte message.

    let state1 = std::hash::sha256_compression(block0, SHA256_IV);
    let state2 = std::hash::sha256_compression(block1, state1);
    words8_to_bytes(state2)
}

// One Merkle level: M nodes -> ceil(M/2) nodes. Odd M pads the last pair's
// right side with the 32-byte zero node (book_commitment.dart's `_zeroNode`).
fn merkle_level<let M: u32>(level: [[u8; 32]; M]) -> [[u8; 32]; (M + 1) / 2] {
    let mut next: [[u8; 32]; (M + 1) / 2] = [[0; 32]; (M + 1) / 2];
    for i in 0..(M + 1) / 2 {
        let l = level[2 * i];
        let r = if 2 * i + 1 < M { level[2 * i + 1] } else { [0 as u8; 32] };
        next[i] = hash_pair(l, r);
    }
    next
}

// Unsigned 256-bit `<`, compared as (hi, lo) with hi = top 128 bits -- the
// same order as Dart's lexicographic string sort over uniform `0x`+64-hex
// leaves (spike doc SS4.D).
fn leaf_lt(hi_a: Field, lo_a: Field, hi_b: Field, lo_b: Field) -> bool {
    let hi_a_u = hi_a as u128;
    let lo_a_u = lo_a as u128;
    let hi_b_u = hi_b as u128;
    let lo_b_u = lo_b as u128;
    (hi_a_u < hi_b_u) | ((hi_a_u == hi_b_u) & (lo_a_u < lo_b_u))
}

fn main(
    leaves_hi: [Field; N],
    leaves_lo: [Field; N],
    root_hi: pub Field,
    root_lo: pub Field,
) {
    // Reconstruct each leaf's 32 raw bytes from its hi/lo split.
    // `to_be_bytes::<16>` range-checks hi/lo < 2^128 as a side effect of the
    // radix decomposition (CIRCUIT_IO.md-style range check, no separate assert
    // needed).
    let mut leaves: [[u8; 32]; N] = [[0; 32]; N];
    for i in 0..N {
        let hi_bytes: [u8; 16] = leaves_hi[i].to_be_bytes();
        let lo_bytes: [u8; 16] = leaves_lo[i].to_be_bytes();
        let mut leaf: [u8; 32] = [0; 32];
        for j in 0..16 {
            leaf[j] = hi_bytes[j];
            leaf[16 + j] = lo_bytes[j];
        }
        leaves[i] = leaf;
    }

    // Sorted + distinct: strict `<` between every adjacent pair.
    for i in 0..N - 1 {
        assert(leaf_lt(leaves_hi[i], leaves_lo[i], leaves_hi[i + 1], leaves_lo[i + 1]));
    }

    // Root reconstruction, level by level (32 -> 16 -> 8 -> 4 -> 2 -> 1),
    // matching book_commitment.dart's computeRoot exactly.
    let level1 = merkle_level(leaves);
    let level2 = merkle_level(level1);
    let level3 = merkle_level(level2);
    let level4 = merkle_level(level3);
    let level5 = merkle_level(level4);
    let root_bytes = level5[0];

    let mut computed_hi: Field = 0;
    let mut computed_lo: Field = 0;
    for j in 0..16 {
        computed_hi = computed_hi * 256 + (root_bytes[j] as Field);
        computed_lo = computed_lo * 256 + (root_bytes[16 + j] as Field);
    }
    assert(computed_hi == root_hi);
    assert(computed_lo == root_lo);
}
