#!/usr/bin/env bash
# run_vectors.sh — single-command iteration loop for the golden + negative
# vector corpus (M3.1: recompile circuit -> run golden vectors).
#
# Step 1: Dart stepper-regression runner (flutter test).
#         Catches stepper regressions; does not touch the circuit.
# Step 2: Recompile the tier-12 v2.4 circuit (nargo compile).
# Step 3: scripts/gen_vectors.dart — for every seed in test_vectors/seeds.json,
#         runs nargo execute against the freshly compiled circuit and:
#           - positive vectors: cross-checks circuit CA outputs against the
#             Dart stepper oracle, and freezes the circuit-computed commitment.
#           - negative vectors with raw_overrides (malformed witness): asserts
#             nargo execute fails (the in-circuit constraint rejects it).
#           - negative vectors with declared_override (forged public output):
#             these test SNARK public-input binding (does bb verify reject a
#             tampered proof?), not a circuit constraint — border_activations/
#             trajectory/commitment are return values, so nargo execute
#             structurally cannot accept a declared lie. Each is discharged by
#             a named positive vector instead (see seeds.json); skipped here
#             and recorded as such in corpus.json, not silently passed.
#
# DEFERRED TO M3.4: a single end-to-end bb prove + public-input-byte-tamper +
# bb verify smoke test (one test, not four) resolves GOLDEN_VECTORS.md §7's
# [CONFIRM: noir CLI] question and is the only remaining piece of the four
# declared_override vectors' security property.
#
# Exit codes:
#   0 — stepper tests, circuit compile, and all witness-checkable vectors passed
#   1 — a stepper regression, compile failure, or vector mismatch/regression

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIER12_DIR="${REPO_ROOT}/circuits/ca_v2_4_tier12"
NARGO_BIN="${NARGO_BIN:-/tmp/nargo}"

# ── Step 1: Dart stepper regression ─────────────────────────────────────────

echo "=== Step 1: Dart stepper regression (flutter test) ==="
cd "${REPO_ROOT}"
flutter test test/engine/ --reporter=expanded
echo "  Stepper tests passed."

# ── Step 2: Recompile the tier-12 circuit ───────────────────────────────────

echo ""
echo "=== Step 2: Recompile circuits/ca_v2_4_tier12 ==="
(cd "${TIER12_DIR}" && "${NARGO_BIN}" compile --silence-warnings)
echo "  Compile succeeded."

# ── Step 3: Golden + negative vector corpus ─────────────────────────────────

echo ""
echo "=== Step 3: Golden vector corpus (scripts/gen_vectors.dart) ==="
NARGO_BIN="${NARGO_BIN}" dart run scripts/gen_vectors.dart

echo ""
echo "All witness-checkable vectors passed. See DEFERRED TO M3.4 above for what this does not cover."
