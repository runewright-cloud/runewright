// SPDX-License-Identifier: GPL-3.0-or-later
//
// api/prover.rs — public proving API exposed to Dart via flutter_rust_bridge.
// All functions here are scanned by FRB codegen (--rust-input crate::api::prover).

use flutter_rust_bridge::frb;

use noir_rs::barretenberg::{
    api::srs_init,
    prove::prove_ultra_honk,
    srs::{get_srs, localsrs::LocalSrs, netsrs::NetSrs, Srs},
    utils::{compute_subgroup_size, get_circuit_size},
    verify::{get_ultra_honk_verification_key, verify_ultra_honk},
};
use noir_rs::witness::from_vec_str_to_witness_map;

use std::sync::Mutex;
use std::time::Instant;

// ── hardware_concurrency underflow fix (M3.4 finding) ───────────────────────
//
// Root cause of "Backend error: vector" (the real M3.3/M3.4 blocker, distinct
// from the SRS thread-isolation issue below): barretenberg's
// parallel_for_mutex_pool does `static thread_local ThreadPool pool(
// get_num_cpus() - 1)`. get_num_cpus() falls back to
// std::thread::hardware_concurrency(), which the C++ standard explicitly
// permits to return 0 when "not computable or well-defined" -- and it does,
// in some Android process contexts (confirmed via on-device lldb backtrace,
// docs/M3_findings.md). `0 - 1` on the unsigned `size_t` wraps to SIZE_MAX;
// `vector<thread>::reserve(SIZE_MAX)` throws exactly `length_error("vector")`,
// which is the opaque string seen at every layer above this.
//
// Fix: set the `HARDWARE_CONCURRENCY` env var, which barretenberg checks
// before falling back to hardware_concurrency(). Confirmed working on-device
// for both a trivial circuit and the real v2.4 bytecode.
//
// Hardening (this must survive FRB's threading, not just a single-threaded
// smoke test): the cache in barretenberg's get_num_cores_ref() is a
// `static thread_local` populated lazily on each thread's *first* read --
// so this must land before ANY thread (including FRB's worker pool threads)
// makes its first call into barretenberg, not merely before the init-call
// thread does. A #[ctor] runs at .so load time (DT_INIT_ARRAY), strictly
// before any Rust/FRB code runs and therefore before FRB can spawn its first
// worker thread -- this sidesteps the static-init-ordering question
// entirely, rather than relying on frb_init_app (which FRB calls from Dart,
// after the library is already loaded and threads may already exist).
#[ctor::ctor]
fn set_hardware_concurrency_workaround() {
    if std::env::var("HARDWARE_CONCURRENCY").is_err() {
        // Rust's own CPU-count query; conservative hardcoded fallback if even
        // this fails (mirrors barretenberg's own `std::min(32U, ...)` cap).
        let n = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        std::env::set_var("HARDWARE_CONCURRENCY", n.to_string());
        eprintln!("RUNEWRIGHT_DIAG HARDWARE_CONCURRENCY set to {n} (ctor, pre-FRB-init)");
    }
}

// ── Public types ──────────────────────────────────────────────────────────────

/// Result of a timed prove call.  Returned to Dart; Dart logs wall_ms and
/// peak_rss_kb to logcat so Soren can read them without needing the Profiler.
pub struct TimedProofResult {
    /// Proof bytes in the noir-rs wire format:
    ///   [4 bytes BE: num_public_inputs][public_input fields][proof fields]
    /// Each field is 32 bytes.
    pub proof_bytes: Vec<u8>,
    /// Wall-clock duration of the prove call, in milliseconds.
    pub wall_ms: u64,
    /// Peak resident set size at end of prove call, in KB (Linux /proc/self/status VmHWM).
    /// Returns 0 on platforms that don't expose /proc (iOS simulator, etc.).
    pub peak_rss_kb: u64,
}

// ── SRS thread-isolation fix ──────────────────────────────────────────────────
//
// Root cause of "Backend error: vector":
// flutter_rust_bridge dispatches every async Rust function as a separate
// tokio::task::spawn_blocking call.  Each call may land on a different OS
// thread.  Barretenberg's C++ stores the initialized SRS in thread-local (or
// thread-scoped) workspace: after srs_init_srs runs on thread T1, a
// circuit_compute_vk call on thread T2 sees an empty SRS vector and throws
// std::out_of_range("vector").
//
// Fix: cache the raw G1/G2 SRS bytes in Rust after downloading, then
// re-push to barretenberg at the top of every function that needs SRS access.
// The re-push is ~134 MB of buffer passing (~5-10 ms on a Pixel 6), which is
// negligible compared to the proof time (tens of seconds).

struct CachedSrs {
    g1_data: Vec<u8>,
    g2_data: Vec<u8>,
    num_points: u32,
}

// SAFETY: Vec<u8> and u32 are Send+Sync; Mutex wraps the whole thing.
static SRS_CACHE: Mutex<Option<CachedSrs>> = Mutex::new(None);

/// Re-push the cached SRS to barretenberg on the CURRENT thread.
///
/// Must be called at the top of any function that calls barretenberg operations
/// that need the SRS (VK computation, proving).  A prior call to
/// `init_srs_and_compute_vk` must have cached the SRS.
fn reinit_srs_on_thread() -> Result<(), String> {
    let guard = SRS_CACHE
        .lock()
        .map_err(|_| "SRS cache mutex poisoned".to_string())?;
    let srs = guard
        .as_ref()
        .ok_or_else(|| "SRS not cached — call init_srs_and_compute_vk first".to_string())?;
    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data)
}

// ── FRB init ──────────────────────────────────────────────────────────────────

/// Called once by the generated Flutter glue during library init.
#[frb(init)]
pub fn frb_init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// ── SRS + VK (combined, thread-safe) ─────────────────────────────────────────

/// Download (or read) the SRS and compute the UltraHonk VK in one blocking call.
///
/// This replaces the old `init_srs` + `compute_vk` two-step sequence.
/// Combining them in one function ensures both operations run on the same
/// OS thread, which is required for barretenberg's thread-scoped SRS state
/// to be visible during VK computation.
///
/// The downloaded SRS bytes are cached in `SRS_CACHE` for re-use by
/// `prove_and_time` (which re-pushes them to barretenberg on its thread
/// without re-downloading).
///
/// `srs_path = None`  → network download from crs.aztec.network (~128 MB for T=12).
/// `srs_path = Some(p)` → read from local .dat file at path `p`.
///
/// Returns `(num_srs_points, vk_bytes)`.
pub fn init_srs_and_compute_vk(
    circuit_bytecode: String,
    srs_path: Option<String>,
    low_memory: bool,
) -> Result<(u32, Vec<u8>), String> {
    // 1. Get dyadic gate count (no SRS needed, safe on any thread).
    let circuit_size = get_circuit_size(&circuit_bytecode, false);
    if circuit_size == 0 {
        return Err("circuit_stats returned 0 gates — bytecode may be invalid".into());
    }
    eprintln!("RUNEWRIGHT_DIAG circuit_size={circuit_size}");

    // 2. Download (or load) SRS data into Rust memory.
    // Multiplier 8 is the standard UltraHonk overhead; using 12 here to guard
    // against the circuit_compute_vk needing extra points on AArch64.
    let subgroup_size = compute_subgroup_size(circuit_size * 12);
    let srs = get_srs(subgroup_size, srs_path.as_deref());
    eprintln!("RUNEWRIGHT_DIAG num_points={} g1_bytes={} g2_bytes={}", srs.num_points, srs.g1_data.len(), srs.g2_data.len());

    // 3. Cache for re-use on other threads.
    {
        let mut guard = SRS_CACHE
            .lock()
            .map_err(|_| "SRS cache mutex poisoned".to_string())?;
        *guard = Some(CachedSrs {
            g1_data: srs.g1_data.clone(),
            g2_data: srs.g2_data.clone(),
            num_points: srs.num_points,
        });
    }

    // 4. Push SRS to barretenberg on THIS thread.
    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data)
        .map_err(|e| format!("srs_init: {e}"))?;

    // 5. Compute VK on the SAME thread (sees the SRS we just pushed).
    let vk = get_ultra_honk_verification_key(&circuit_bytecode, low_memory, None)
        .map_err(|e| format!(
            "compute_vk [circuit_size={circuit_size} num_pts={} g1_kb={}]: {e}",
            srs.num_points,
            srs.g1_data.len() / 1024,
        ))?;

    Ok((srs.num_points, vk))
}

// ── SRS init without VK (for bundled-VK flow) ────────────────────────────────

/// Download (or read) the SRS and cache it — without computing the VK.
///
/// Use this when the VK is loaded from a pre-bundled asset, bypassing the
/// AArch64-specific `circuit_compute_vk` bug in the current barretenberg binary.
/// Caches SRS bytes in `SRS_CACHE` so `prove_and_time` can re-push them on its
/// thread without re-downloading.
///
/// No oversizing multiplier here (unlike `init_srs_and_compute_vk`'s `* 12`):
/// that margin exists only to give on-device `circuit_compute_vk` extra room,
/// which this bundled-VK path skips entirely. Confirmed empirically (M3.4) —
/// `setup_srs_from_bytecode`'s raw (unmultiplied) sizing is sufficient for
/// `prove_ultra_honk` on the real v2.4 bytecode; applying the `* 8` margin
/// here was inflating peak on-device RSS by up to 8x for no benefit (it
/// pushed v2.4 into a dyadic SRS bucket several sizes above what `bb gates`
/// says the circuit actually needs — see docs/M3_findings.md).
///
/// Returns `num_srs_points`.
pub fn init_srs(circuit_bytecode: String, srs_path: Option<String>) -> Result<u32, String> {
    let circuit_size = get_circuit_size(&circuit_bytecode, false);
    if circuit_size == 0 {
        return Err("circuit_stats returned 0 gates — bytecode may be invalid".into());
    }
    let subgroup_size = compute_subgroup_size(circuit_size);
    let srs = get_srs(subgroup_size, srs_path.as_deref());

    {
        let mut guard = SRS_CACHE
            .lock()
            .map_err(|_| "SRS cache mutex poisoned".to_string())?;
        *guard = Some(CachedSrs {
            g1_data: srs.g1_data.clone(),
            g2_data: srs.g2_data.clone(),
            num_points: srs.num_points,
        });
    }

    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data)
        .map_err(|e| format!("srs_init: {e}"))?;

    Ok(srs.num_points)
}

// ── SRS init with a persistent on-disk cache (real player-facing path) ──────

/// Like `init_srs`, but with a persistent on-disk cache at `cache_path`: if
/// a valid cache file already exists there, read it (no network -- this is
/// what makes the second and subsequent inscription on a device work
/// offline); otherwise download from crs.aztec.network and write the cache
/// file for next time. `cache_path` should be a device-local, app-owned
/// file path (Dart side: `path_provider`'s `getApplicationSupportDirectory()`
/// joined with a fixed filename) -- not the bundled-VK asset path, and not
/// the bare directory.
///
/// Network/disk failures (no connection, corrupt cache file) are reported
/// as `Err(message)`, never as an unrecovered panic: noir_rs's
/// `NetSrs`/`LocalSrs` call `.unwrap()` internally on the HTTP response and
/// the file read, which would otherwise abort the whole process rather than
/// letting the caller (and ultimately the player, via a normal error
/// dialog) see what went wrong.
///
/// Uses the same unmultiplied sizing as `init_srs` (bundled-VK flow -- see
/// that function's doc comment for why no `* 12` margin here).
pub fn init_srs_cached(circuit_bytecode: String, cache_path: String) -> Result<u32, String> {
    let circuit_size = get_circuit_size(&circuit_bytecode, false);
    if circuit_size == 0 {
        return Err("circuit_stats returned 0 gates — bytecode may be invalid".into());
    }
    let subgroup_size = compute_subgroup_size(circuit_size);
    let srs = get_srs_cached(subgroup_size + 1, &cache_path)?;

    {
        let mut guard = SRS_CACHE
            .lock()
            .map_err(|_| "SRS cache mutex poisoned".to_string())?;
        *guard = Some(CachedSrs {
            g1_data: srs.g1_data.clone(),
            g2_data: srs.g2_data.clone(),
            num_points: srs.num_points,
        });
    }

    srs_init(&srs.g1_data, srs.num_points, &srs.g2_data)
        .map_err(|e| format!("srs_init: {e}"))?;

    Ok(srs.num_points)
}

/// Reads `cache_path` if it exists, else downloads and writes it there for
/// next time. Catches panics from noir_rs's local-file and network I/O
/// (both `.unwrap()` internally) and converts them into `Result::Err` so a
/// missing network connection on a fresh device surfaces as a normal,
/// Dart-catchable error rather than crashing the process. Safe to do:
/// `catch_unwind` here runs entirely before anything crosses back over the
/// FFI boundary, and this crate has no `panic = "abort"` profile override
/// (checked: ffi/Cargo.toml), so unwinding is actually available to catch.
fn get_srs_cached(num_points: u32, cache_path: &str) -> Result<Srs, String> {
    if std::path::Path::new(cache_path).exists() {
        std::panic::catch_unwind(|| LocalSrs::new(num_points, Some(cache_path)).to_srs()).map_err(|_| {
            format!("failed to read the cached SRS file at {cache_path} (corrupt?) — delete it and try again")
        })
    } else {
        let downloaded = std::panic::catch_unwind(|| NetSrs::new(num_points).to_srs())
            .map_err(|_| "SRS download failed — check your network connection and try again".to_string())?;
        let to_save = Srs {
            g1_data: downloaded.g1_data.clone(),
            g2_data: downloaded.g2_data.clone(),
            num_points: downloaded.num_points,
        };
        // Best-effort: a save failure (e.g. disk full) shouldn't fail this
        // inscription -- the player still gets their proof this once, just
        // without a cache for next time. Atomic (see save_srs_cache_atomic):
        // an interrupted write (flaky in-person network, app killed
        // mid-save) must never leave `cache_path` itself half-written --
        // that would make every future run see a "present but corrupt"
        // cache and need manual deletion (M4 plan, "interrupted download
        // must self-heal"). With an atomic publish, the worst case is a
        // missing cache (next run just re-downloads), never a poisoned one.
        let _ = save_srs_cache_atomic(&to_save, cache_path);
        Ok(downloaded)
    }
}

/// Writes `srs` to `cache_path` atomically: serialize to a uniquely-named
/// temp file in the same directory (so the final rename is on one
/// filesystem, which POSIX guarantees is atomic), fsync the temp file's
/// contents, then rename it into place. A crash/kill/panic at any point
/// before the rename leaves only the never-read temp file behind --
/// `cache_path` itself is either still absent or still holds its previous
/// contents, never a truncated/partial write. The temp file is best-effort
/// cleaned up on any failure path; a leftover temp file is harmless (never
/// read by `get_srs_cached`, which only looks at `cache_path`).
fn save_srs_cache_atomic(srs: &Srs, cache_path: &str) -> Result<(), String> {
    let final_path = std::path::Path::new(cache_path);
    let parent = final_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| std::path::Path::new("."));
    let file_name = final_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("srs.local");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let temp_path = parent.join(format!(".{file_name}.tmp-{}-{nanos}", std::process::id()));
    let temp_path_str = temp_path
        .to_str()
        .ok_or_else(|| "cache_path is not valid UTF-8".to_string())?;

    let to_save = Srs {
        num_points: srs.num_points,
        g1_data: srs.g1_data.clone(),
        g2_data: srs.g2_data.clone(),
    };
    let save_result = std::panic::catch_unwind(|| LocalSrs(to_save).save(Some(temp_path_str)));
    if save_result.is_err() {
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!("failed to write SRS cache temp file at {temp_path_str}"));
    }

    // fsync the temp file's contents before the rename -- LocalSrs::save
    // uses std::fs::write internally, which does not fsync, so without
    // this an interrupted-at-power-loss (not just process-kill) scenario
    // could still rename in data that never made it to disk.
    let fsync_result = std::fs::OpenOptions::new()
        .write(true)
        .open(&temp_path)
        .and_then(|f| f.sync_all());
    if let Err(e) = fsync_result {
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!("failed to fsync SRS cache temp file: {e}"));
    }

    std::fs::rename(&temp_path, final_path).map_err(|e| {
        let _ = std::fs::remove_file(&temp_path);
        format!("failed to publish SRS cache file: {e}")
    })
}

// ── VK computation ───────────────────────────────────────────────────────────

/// Compute the UltraHonk VK (poseidon2 oracle).
///
/// Re-pushes the cached SRS to barretenberg on the current thread first.
/// Requires a prior `init_srs_and_compute_vk` call to have populated the cache.
pub fn compute_vk(circuit_bytecode: String, low_memory: bool) -> Result<Vec<u8>, String> {
    reinit_srs_on_thread()?;
    get_ultra_honk_verification_key(&circuit_bytecode, low_memory, None)
}

/// Diagnostic: compute VK with Keccak oracle hash (not for production proving).
///
/// Used to test whether "Backend error: vector" is poseidon2-specific (lookup
/// table sizing bug) or a deeper VK computation issue.  If this succeeds while
/// `compute_vk` fails, the bug is in barretenberg's poseidon2 selector/lookup
/// table path on AArch64.
pub fn compute_vk_keccak(circuit_bytecode: String, low_memory: bool) -> Result<Vec<u8>, String> {
    reinit_srs_on_thread()?;
    noir_rs::barretenberg::verify::get_ultra_honk_keccak_verification_key(
        &circuit_bytecode,
        false,
        low_memory,
        None,
    )
}

// ── Prove ─────────────────────────────────────────────────────────────────────

/// Prove the v2.4 CA circuit and return timing data.
///
/// `circuit_bytecode`     — base64-encoded ACIR bytecode.
/// `grid_state`           — 469 cell values (0 or 1), flat q×r order.
/// `key_hi_hex`/`key_lo_hex` — hex-encoded Field, the Ed25519-key-half pair
///                          (interim zero keys until the identity module lands).
/// `t_hex`                — hex-encoded Field, `1 <= T <= tier_max`.
/// `owner_pubkey_hex`     — hex-encoded Field, `poseidon2_hash2(key_hi, key_lo)`
///                          (CIRCUIT_IO.md CIRCUIT_IO 5/6 — the VK-stable binding).
/// `ruleset_version_hex`  — hex-encoded Field, `RULESET_VERSION`.
/// `vk_bytes`             — from `init_srs_and_compute_vk` or a bundled asset.
/// `low_memory`           — enable file-backed polynomial storage (~2x RAM saving).
///
/// Witness order matches `main()`'s declared parameter order exactly: the 469
/// grid cells, then key_hi, key_lo, T, owner_pubkey, ruleset_version — hex
/// strings throughout (owner_pubkey is a full 254-bit field; u128 cannot
/// represent it, hence `from_vec_str_to_witness_map` rather than the
/// u128-based `from_vec_to_witness_map` the proxy-circuit version used).
///
/// Re-pushes the cached SRS to barretenberg on the current thread (fast, ~5-10 ms,
/// no network).  The cache must be populated by a prior `init_srs_and_compute_vk`.
pub fn prove_and_time(
    circuit_bytecode: String,
    grid_state: Vec<u8>,
    key_hi_hex: String,
    key_lo_hex: String,
    t_hex: String,
    owner_pubkey_hex: String,
    ruleset_version_hex: String,
    vk_bytes: Vec<u8>,
    low_memory: bool,
) -> Result<TimedProofResult, String> {
    reinit_srs_on_thread()?;

    if grid_state.len() != 469 {
        return Err(format!(
            "grid_state must be 469 cells, got {}",
            grid_state.len()
        ));
    }

    let grid_hex: Vec<String> = grid_state.iter().map(|&v| format!("0x{v:x}")).collect();
    let mut witness_strs: Vec<&str> = grid_hex.iter().map(String::as_str).collect();
    witness_strs.push(&key_hi_hex);
    witness_strs.push(&key_lo_hex);
    witness_strs.push(&t_hex);
    witness_strs.push(&owner_pubkey_hex);
    witness_strs.push(&ruleset_version_hex);

    let witness = from_vec_str_to_witness_map(witness_strs)?;

    // M3.4 step-6 gate: confirms the hardware_concurrency fix (set by the
    // #[ctor] above) is actually visible on *this* thread -- which may be an
    // FRB worker pool thread, not the thread frb_init_app ran on. Does not by
    // itself prove barretenberg's thread_local pool picked it up (no Rust
    // binding exposes that), but a missing/empty value here would mean the
    // env var never reached this thread at all, which is the failure mode to
    // rule out first if this call throws "Backend error: vector" again.
    eprintln!(
        "RUNEWRIGHT_DIAG HARDWARE_CONCURRENCY={:?} on prove_and_time's thread",
        std::env::var("HARDWARE_CONCURRENCY")
    );

    let t0 = Instant::now();
    let proof_bytes = prove_ultra_honk(&circuit_bytecode, witness, vk_bytes, low_memory, None)?;
    let wall_ms = t0.elapsed().as_millis() as u64;
    let peak_rss_kb = read_peak_rss_kb();

    Ok(TimedProofResult {
        proof_bytes,
        wall_ms,
        peak_rss_kb,
    })
}

// ── Verify ────────────────────────────────────────────────────────────────────

/// Verify a proof produced by `prove_and_time`.
pub fn verify_proof(vk_bytes: Vec<u8>, proof_bytes: Vec<u8>) -> Result<bool, String> {
    verify_ultra_honk(proof_bytes, vk_bytes)
}

// ── Utility ───────────────────────────────────────────────────────────────────

/// Extract the `bytecode` base64 string from a Noir circuit JSON artifact.
pub fn extract_bytecode(circuit_json: String) -> Result<String, String> {
    let v: serde_json::Value =
        serde_json::from_str(&circuit_json).map_err(|e| format!("JSON parse: {e}"))?;
    v["bytecode"]
        .as_str()
        .map(|s| s.to_owned())
        .ok_or_else(|| "No 'bytecode' field in circuit JSON".to_string())
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn read_peak_rss_kb() -> u64 {
    let Ok(status) = std::fs::read_to_string("/proc/self/status") else {
        return 0;
    };
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmHWM:") {
            if let Some(kb_str) = rest.split_whitespace().next() {
                return kb_str.parse().unwrap_or(0);
            }
        }
    }
    0
}

#[cfg(test)]
mod srs_cache_tests {
    use super::*;

    /// A cache hit must read exactly the bytes on disk and never touch the
    /// network. Proven deterministically (no real network involved either
    /// way) by writing a tiny synthetic SRS to the cache path -- if
    /// `get_srs_cached` had instead gone to `NetSrs`, the real downloaded
    /// data would not match this fabricated `num_points`/byte content.
    #[test]
    fn cache_hit_reads_local_file_verbatim() {
        let dir = std::env::temp_dir().join(format!(
            "runewright_srs_cache_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let cache_path = dir.join("srs.local");

        let fake = Srs {
            num_points: 3,
            g1_data: vec![7u8; 3 * 64],
            g2_data: vec![9u8; 128],
        };
        LocalSrs(Srs {
            num_points: fake.num_points,
            g1_data: fake.g1_data.clone(),
            g2_data: fake.g2_data.clone(),
        })
        .save(Some(cache_path.to_str().unwrap()));

        let got = get_srs_cached(3, cache_path.to_str().unwrap()).expect("cache hit should succeed");
        assert_eq!(got.num_points, fake.num_points);
        assert_eq!(got.g1_data, fake.g1_data);
        assert_eq!(got.g2_data, fake.g2_data);

        std::fs::remove_dir_all(&dir).ok();
    }

    /// A corrupt/unreadable cache file must surface as `Err`, never as an
    /// unrecovered panic -- this is the same `catch_unwind` path a "file
    /// exists but bincode-deserialize fails" real-world case would hit.
    #[test]
    fn corrupt_cache_file_returns_err_not_panic() {
        let dir = std::env::temp_dir().join(format!(
            "runewright_srs_cache_corrupt_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let cache_path = dir.join("srs.local");
        std::fs::write(&cache_path, b"not a valid bincode-serialized Srs").unwrap();

        let result = get_srs_cached(3, cache_path.to_str().unwrap());
        assert!(result.is_err(), "corrupt cache file should return Err, not panic or succeed");

        std::fs::remove_dir_all(&dir).ok();
    }

    /// The happy path for the atomic writer: produces a cache file that
    /// reads back correctly, and leaves no `.tmp-*` file behind once the
    /// rename has published it.
    #[test]
    fn atomic_save_round_trips_and_leaves_no_temp_file() {
        let dir = std::env::temp_dir().join(format!(
            "runewright_srs_cache_atomic_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let cache_path = dir.join("srs.local");

        let srs = Srs {
            num_points: 3,
            g1_data: vec![5u8; 3 * 64],
            g2_data: vec![6u8; 128],
        };
        save_srs_cache_atomic(&srs, cache_path.to_str().unwrap()).expect("atomic save should succeed");

        let got = get_srs_cached(3, cache_path.to_str().unwrap()).expect("should read back the just-saved cache");
        assert_eq!(got.num_points, srs.num_points);
        assert_eq!(got.g1_data, srs.g1_data);
        assert_eq!(got.g2_data, srs.g2_data);

        let leftover_temp_files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(
            leftover_temp_files.is_empty(),
            "atomic save left a temp file behind: {leftover_temp_files:?}"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    /// The property the M4 plan asked for: a failed/interrupted write must
    /// never leave a half-written file at `cache_path` itself -- the next
    /// run must see either nothing (re-download) or the last fully-written
    /// good state, never a "present but corrupt" file. Forced here by
    /// pointing `cache_path` at a location whose parent directory doesn't
    /// exist, which deterministically fails the write -- the real-world
    /// equivalent (process killed mid-`fs::write`) isn't reliably
    /// reproducible in a unit test, but both fail before the atomic rename
    /// publishes anything, which is the property under test.
    #[test]
    fn failed_save_does_not_create_a_partial_file_at_cache_path() {
        let dir = std::env::temp_dir().join(format!(
            "runewright_srs_cache_failure_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        // Deliberately not created -- forces the temp-file write inside
        // save_srs_cache_atomic to fail.
        let cache_path = dir.join("does-not-exist-subdir").join("srs.local");

        let srs = Srs {
            num_points: 3,
            g1_data: vec![9u8; 3 * 64],
            g2_data: vec![2u8; 128],
        };
        let result = save_srs_cache_atomic(&srs, cache_path.to_str().unwrap());

        assert!(result.is_err(), "save into a nonexistent directory should fail, not panic");
        assert!(
            !cache_path.exists(),
            "a failed save must not leave any file at cache_path, partial or otherwise"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    /// Requires a real network-denial environment to be meaningful, so it's
    /// `#[ignore]`d by default (a normal `cargo test` run has real network
    /// and would just download successfully, proving nothing about the
    /// failure path). Run it for real with:
    ///
    ///   unshare --user --net -- cargo test --offline missing_cache_with_no_network_returns_err_not_hang -- --ignored
    ///
    /// (--offline so cargo itself, which does need network for crate
    /// resolution on a clean checkout, doesn't also fail for the wrong
    /// reason -- run a normal `cargo build` first so everything is already
    /// fetched/compiled.) Confirms the player-facing contract: a fresh
    /// device with no connection gets a clear error, not a hang or crash.
    #[test]
    #[ignore]
    fn missing_cache_with_no_network_returns_err_not_hang() {
        let dir = std::env::temp_dir().join(format!(
            "runewright_srs_cache_offline_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let cache_path = dir.join("srs.local"); // deliberately does not exist

        let result = get_srs_cached(3, cache_path.to_str().unwrap());
        assert!(
            result.is_err(),
            "expected a graceful Err with no network and no cache, got Ok -- is this actually running offline?"
        );
        let message = result.unwrap_err();
        assert!(
            message.contains("network"),
            "error message should clearly point at the network, got: {message}"
        );

        std::fs::remove_dir_all(&dir).ok();
    }
}
