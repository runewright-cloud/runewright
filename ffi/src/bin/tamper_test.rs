// M3.4 step 8: the single bb-verify tamper smoke test.
//
// Proves a real tier-12 v2.4 proof, flips one byte of the commitment within
// the proof's public-input section, and confirms verify_ultra_honk rejects
// the tampered proof. This is the SNARK public-input-binding property the
// four `declared_override` vectors deferred since M3.1 were standing in for
// (see docs/GOLDEN_VECTORS.md §3/§7) -- one test, not four.
//
// Also resolves GOLDEN_VECTORS.md §7's [CONFIRM: noir CLI] proof wire-format
// question empirically, by actually parsing a real proof rather than trusting
// the doc comments in noir_rs's source.
//
// Run from repo root: cd ffi && cargo run --release --bin tamper_test 2>&1

use noir_rs::barretenberg::{
    api::srs_init,
    prove::prove_ultra_honk,
    srs::get_srs,
    utils::{compute_subgroup_size, get_circuit_size},
    verify::verify_ultra_honk,
};
use noir_rs::witness::from_vec_str_to_witness_map;

const OWNER_PUBKEY_HEX: &str =
    "0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1";
const FIELD_SIZE: usize = 32;

fn main() {
    let circuit_path = format!(
        "{}/../circuits/ca_v2_4_tier12/target/ca_v2_4_tier12.json",
        env!("CARGO_MANIFEST_DIR"),
    );
    let vk_path = format!(
        "{}/../assets/circuits/ca_v2_4_tier12.vk",
        env!("CARGO_MANIFEST_DIR"),
    );

    let circuit_json = std::fs::read_to_string(&circuit_path).expect("read circuit");
    let v: serde_json::Value = serde_json::from_str(&circuit_json).expect("parse JSON");
    let bytecode = v["bytecode"].as_str().expect("bytecode field").to_owned();
    let vk = std::fs::read(&vk_path).expect("read bundled VK");

    // Same SRS sizing as the fixed init_srs (no multiplier -- M3.4 step 7 found
    // the *8 margin was unnecessary and wasteful for v2.4).
    let circuit_size = get_circuit_size(&bytecode, false);
    let subgroup_size = compute_subgroup_size(circuit_size);
    let srs = get_srs(subgroup_size, None);
    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data).expect("srs_init");

    // Known-good witness: all-zero grid, T=1, owner_pubkey=poseidon2_hash2(0,0),
    // key_hi=key_lo=0, ruleset_version=1.
    let mut witness_strs: Vec<String> = vec!["0x0".to_string(); 469];
    witness_strs.push("0x0".to_string());
    witness_strs.push("0x0".to_string());
    witness_strs.push("0x1".to_string());
    witness_strs.push(OWNER_PUBKEY_HEX.to_string());
    witness_strs.push("0x1".to_string());
    let witness_refs: Vec<&str> = witness_strs.iter().map(String::as_str).collect();
    let witness = from_vec_str_to_witness_map(witness_refs).expect("witness map");

    println!("Proving tier-12...");
    let proof = prove_ultra_honk(&bytecode, witness, vk.clone(), false, None).expect("prove");
    println!("Proof: {} bytes", proof.len());

    // ── Parse the wire format empirically ──────────────────────────────────
    let num_pub = u32::from_be_bytes(proof[0..4].try_into().unwrap()) as usize;
    println!("num_public_inputs (from 4-byte BE header) = {num_pub}");
    let pub_bytes_len = num_pub * FIELD_SIZE;
    println!(
        "public input section: bytes [4..{}], proof section: bytes [{}..{}]",
        4 + pub_bytes_len,
        4 + pub_bytes_len,
        proof.len()
    );

    // Print each public input field as hex, to find the commitment by eye
    // (it's the only one we independently know the expected value of, since
    // it equals poseidon2_hash2(packed all-zero grid) for this witness --
    // but simplest empirical confirmation: T=1, owner_pubkey, and
    // ruleset_version=1 are known plaintext, so whichever of the 32 fields
    // do NOT match a small/recognizable value are the return tuple, and the
    // first of those is the commitment per CIRCUIT_IO.md's declared return
    // order (commitment, border_activations[4], trajectory[12], flags[12])).
    for i in 0..num_pub {
        let start = 4 + i * FIELD_SIZE;
        let field = &proof[start..start + FIELD_SIZE];
        let hex: String = field.iter().map(|b| format!("{b:02x}")).collect();
        println!("  pub[{i:2}] @ byte {start:4}: 0x{hex}");
    }

    // ── Verify the real proof first (must succeed) ───────────────────────
    let valid = verify_ultra_honk(proof.clone(), vk.clone()).expect("verify call");
    println!("\nUntampered proof verify_ultra_honk result: {valid}");
    assert!(valid, "the real proof must verify");

    // ── Tamper one byte of the commitment and confirm rejection ──────────
    // Per CIRCUIT_IO.md CIRCUIT_IO 8, the return tuple is
    // (commitment, border_activations[4], dominance_trajectory[12], supreme_flags[12]),
    // and ABI pub *parameters* (T, owner_pubkey, ruleset_version) precede
    // return values in the public-input ordering -- so commitment is
    // public-input index 3 (0=T, 1=owner_pubkey, 2=ruleset_version, 3=commitment).
    let commitment_index = 3;
    let commitment_byte_offset = 4 + commitment_index * FIELD_SIZE;
    println!(
        "\nTampering 1 byte at offset {commitment_byte_offset} (public-input index {commitment_index}, the commitment)..."
    );
    let mut tampered = proof.clone();
    tampered[commitment_byte_offset] ^= 0xFF;

    let tampered_result = verify_ultra_honk(tampered, vk);
    match tampered_result {
        Ok(true) => {
            println!("FAIL: tampered proof verified successfully! This would be a release-blocking bug.");
            std::process::exit(1);
        }
        Ok(false) => {
            println!("PASS: tampered proof correctly rejected (verify returned false).");
        }
        Err(e) => {
            println!("PASS: tampered proof correctly rejected (verify errored: {e}).");
        }
    }
}
