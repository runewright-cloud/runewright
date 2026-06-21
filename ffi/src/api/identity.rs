// SPDX-License-Identifier: GPL-3.0-or-later
//
// api/identity.rs — owner_pubkey recomputation for the M4 match protocol.
//
// CIRCUIT_IO.md CIRCUIT_IO 5 requires the verifying client to recompute
// `Poseidon2(split(presented_key))` and check it against the proof's
// `owner_pubkey` public input -- this is what binds a presented Ed25519
// identity to a specific proof at cast time. CLAUDE.md's hard invariant 1
// forbids reimplementing Poseidon2 in Dart, so this hash must be computed in
// Rust and crossed over FFI like every other Poseidon2 use in this project.
//
// This calls `bn254_blackbox_solver::poseidon2_permutation` directly --
// the literal ACVM/Noir-stdlib implementation (acvm-repo, part of the noir
// monorepo, pinned to the same v1.0.0-beta.20 tag noir_rs already resolves
// transitively), not a new or divergent implementation. It mirrors
// `circuits/ca_v2_4_tier12/src/main.nr`'s `poseidon2_hash2` helper exactly:
// state = [a, b, 0, iv], iv = 2 * 2^64, permute, take state[0].

use acir::{AcirField, FieldElement};
use flutter_rust_bridge::frb;

/// `poseidon2_hash2(a, b)` matching the circuit's helper of the same name
/// (`circuits/ca_v2_4_tier12/src/main.nr`) bit-for-bit -- same fixed IV,
/// same arity-2-padded-to-4 state, same permutation.
///
/// `a_hex`/`b_hex` and the return value are "0x"-prefixed hex Field strings,
/// the same convention used throughout `api::prover`.
#[frb]
pub fn poseidon2_hash2(a_hex: String, b_hex: String) -> Result<String, String> {
    let a = FieldElement::from_hex(&a_hex).ok_or_else(|| format!("invalid hex field: {a_hex}"))?;
    let b = FieldElement::from_hex(&b_hex).ok_or_else(|| format!("invalid hex field: {b_hex}"))?;

    // iv = 2 * 2^64, matching main.nr's poseidon2_hash2 exactly.
    let iv = FieldElement::from(2u128 * 18_446_744_073_709_551_616u128);
    let state = [a, b, FieldElement::zero(), iv];

    let out = bn254_blackbox_solver::poseidon2_permutation(&state)
        .map_err(|e| format!("poseidon2_permutation failed: {e}"))?;

    Ok(format!("0x{}", out[0].to_hex()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cross-check against the known-good `owner_pubkey = poseidon2_hash2(0, 0)`
    /// value already empirically verified against the real circuit in
    /// `src/bin/tamper_test.rs` / `src/bin/desktop_vk_test.rs` (proved + verified
    /// on tier-12). If this matches, this Rust-side implementation agrees with
    /// the circuit's `poseidon2_hash2` on a value already confirmed correct
    /// end-to-end through `nargo execute` / `prove_ultra_honk`.
    #[test]
    fn poseidon2_hash2_zero_zero_matches_known_circuit_value() {
        let got = poseidon2_hash2("0x0".to_string(), "0x0".to_string()).unwrap();
        assert_eq!(
            got,
            "0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1"
        );
    }

    /// Prints `poseidon2_hash2` for the M4 real-keypair golden vector (key_hi/
    /// key_lo from splitting bytes 0..31 first16/last16-LE, see
    /// `key_packing.dart` and the plan's amendment 2 cross-check). The
    /// printed value is pasted into `circuits/ca_v2_4_tier12/Prover.toml`
    /// and confirmed via `nargo execute` -- see `docs/M4_findings.md`.
    #[test]
    fn print_nonzero_owner_pubkey_vector() {
        let owner_pubkey = poseidon2_hash2(
            "0xf0e0d0c0b0a09080706050403020100".to_string(),
            "0x1f1e1d1c1b1a19181716151413121110".to_string(),
        )
        .unwrap();
        println!("owner_pubkey = {owner_pubkey}");
    }

    /// Third cross-oracle vector (plan: "exercises the full field width"),
    /// using a cryptographically random 32-byte key (not a sequential
    /// pattern like the second vector) split first16/last16-LE. Printed
    /// value confirmed via `nargo execute` -- see `docs/M4_findings.md`.
    #[test]
    fn print_high_entropy_owner_pubkey_vector() {
        let owner_pubkey = poseidon2_hash2(
            "0xc99502afe3f0288a3add28af7f7f1e1e".to_string(),
            "0xcb2712a65f5ad1234bf601a8d349c6ec".to_string(),
        )
        .unwrap();
        println!("owner_pubkey = {owner_pubkey}");
    }
}
