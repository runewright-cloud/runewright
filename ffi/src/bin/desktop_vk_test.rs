// Desktop VK precompute for the real v2.4 circuit (M3.4 step 3).
//
// Computes the UltraHonk VK on x86-64 for each tier and bundles it as a
// Flutter asset, bypassing the AArch64-specific circuit_compute_vk bug
// (M2 finding — distinct from, and still present alongside, the
// hardware_concurrency underflow fixed in api/prover.rs's #[ctor]; this
// desktop run never touches that bug since it's x86-64).
//
// Also proves once on x86-64 with the real v2.4 witness shape, as a sanity
// check that this binary's witness construction matches what prove_and_time
// will send on-device (CIRCUIT_IO.md CIRCUIT_IO 8 ABI order: grid_state,
// key_hi, key_lo, T, owner_pubkey, ruleset_version).
//
// Run from repo root:
//   cd ffi && cargo run --release --bin desktop_vk_test 2>&1

use noir_rs::barretenberg::{
    api::srs_init,
    prove::prove_ultra_honk,
    srs::get_srs,
    utils::{compute_subgroup_size, get_circuit_size},
    verify::get_ultra_honk_verification_key,
};
use noir_rs::witness::from_vec_str_to_witness_map;
use std::time::Instant;

// poseidon2_hash2(0, 0), pinned in CIRCUIT_IO.md CIRCUIT_IO 5 / test_vectors/seeds.json.
const OWNER_PUBKEY_HEX: &str =
    "0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1";

fn circuit_path(tier: u32) -> String {
    format!(
        "{}/../circuits/ca_v2_4_tier{tier}/target/ca_v2_4_tier{tier}.json",
        env!("CARGO_MANIFEST_DIR"),
    )
}

fn vk_asset_path(tier: u32) -> String {
    format!(
        "{}/../assets/circuits/ca_v2_4_tier{tier}.vk",
        env!("CARGO_MANIFEST_DIR"),
    )
}

fn known_good_witness(tier: u32) -> Vec<String> {
    let mut witness: Vec<String> = vec!["0x0".to_string(); 469]; // all-zero grid
    witness.push("0x0".to_string()); // key_hi
    witness.push("0x0".to_string()); // key_lo
    witness.push("0x1".to_string()); // T = 1 (valid for every tier, 1 <= T <= tier_max)
    witness.push(OWNER_PUBKEY_HEX.to_string()); // owner_pubkey = poseidon2_hash2(0,0)
    witness.push("0x1".to_string()); // ruleset_version = 1
    let _ = tier; // T=1 is tier-independent; kept as a parameter for clarity at call sites
    witness
}

fn compute_and_save_vk(tier: u32) -> Vec<u8> {
    println!("\n=== Tier {tier} ===");
    let path = circuit_path(tier);
    let circuit_json = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    let v: serde_json::Value = serde_json::from_str(&circuit_json).expect("parse JSON");
    let bytecode = v["bytecode"].as_str().expect("bytecode field").to_owned();

    let circuit_size = get_circuit_size(&bytecode, false);
    println!("  circuit_size={circuit_size}");
    let subgroup_size = compute_subgroup_size(circuit_size * 8);
    let srs = get_srs(subgroup_size, None);
    println!("  num_points={}", srs.num_points);
    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data).expect("srs_init");

    let vk = get_ultra_honk_verification_key(&bytecode, false, None).expect("circuit_compute_vk");
    println!("  VK: {} bytes", vk.len());
    let vk_path = vk_asset_path(tier);
    std::fs::write(&vk_path, &vk).expect("write VK");
    println!("  Saved: {vk_path}");

    // Sanity-prove once on x86-64 with the real witness shape and the VK we
    // just computed, mirroring exactly what prove_and_time will do on-device.
    let witness_strs = known_good_witness(tier);
    let witness_refs: Vec<&str> = witness_strs.iter().map(String::as_str).collect();
    let witness = from_vec_str_to_witness_map(witness_refs).expect("witness map");
    let t0 = Instant::now();
    let proof = prove_ultra_honk(&bytecode, witness, vk.clone(), false, None)
        .unwrap_or_else(|e| panic!("desktop sanity prove failed for tier {tier}: {e}"));
    println!(
        "  desktop sanity prove: {} bytes ({:.1}s)",
        proof.len(),
        t0.elapsed().as_secs_f32()
    );

    vk
}

fn main() {
    for tier in [12u32, 24, 48] {
        compute_and_save_vk(tier);
    }
    println!("\nDone.");
}
