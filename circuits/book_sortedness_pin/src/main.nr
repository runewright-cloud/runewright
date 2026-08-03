// SPDX-License-Identifier: GPL-3.0-or-later
//
// book_sortedness_pin/src/main.nr -- SHA-256 bit-parity pin, N=2.
// docs/SORTEDNESS_CIRCUIT_SPIKE.md #9: "confirm the stdlib sha256 byte-variant
// is bit-identical to the `crypto` package's output on the same input before
// trusting any root match... pin it with the smallest possible vector (one
// interior node: SHA-256(leafA || leafB)) first."
//
// This crate is the pin: exactly one `hash_pair` call, no zero-padding (N=2 is
// even), Prover.toml generated from BookCommitment.computeRoot itself
// (scripts/gen_book_sortedness_vectors.dart) -- the Dart oracle, not hand
// computed. If this crate's witness doesn't satisfy its constraints, the
// hand-rolled two-block SHA-256 in book_sortedness_n{32,48,64} is wrong and
// those crates' root checks are meaningless regardless of their gate counts.

global N: u32 = 2;

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

fn hash_pair(left: [u8; 32], right: [u8; 32]) -> [u8; 32] {
    let mut msg: [u8; 64] = [0; 64];
    for i in 0..32 {
        msg[i] = left[i];
        msg[32 + i] = right[i];
    }
    let block0 = bytes_to_words16(msg);

    let mut block1: [u32; 16] = [0; 16];
    block1[0] = 0x80000000;
    block1[15] = 512;

    let state1 = std::hash::sha256_compression(block0, SHA256_IV);
    let state2 = std::hash::sha256_compression(block1, state1);
    words8_to_bytes(state2)
}

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

    for i in 0..N - 1 {
        assert(leaf_lt(leaves_hi[i], leaves_lo[i], leaves_hi[i + 1], leaves_lo[i + 1]));
    }

    let root_bytes = hash_pair(leaves[0], leaves[1]);

    let mut computed_hi: Field = 0;
    let mut computed_lo: Field = 0;
    for j in 0..16 {
        computed_hi = computed_hi * 256 + (root_bytes[j] as Field);
        computed_lo = computed_lo * 256 + (root_bytes[16 + j] as Field);
    }
    assert(computed_hi == root_hi);
    assert(computed_lo == root_lo);
}
