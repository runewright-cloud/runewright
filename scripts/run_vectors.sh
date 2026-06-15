#!/usr/bin/env bash
# run_vectors.sh — CI gate for the golden + negative vector corpus.
#
# Step 1: Dart stepper-regression runner (flutter test).
#         Catches stepper regressions; does not touch the circuit.
# Step 2: Noir circuit runner (nargo / bb).
#         Currently STUBBED — wired once M3 produces the v2.4 circuit.
#
# Exit codes:
#   0  — all checks passed (or corpus empty and no Noir runner yet)
#   1  — stepper regression, or corpus present with Noir runner stubbed (see below)
#   2  — corpus present but Noir runner still stubbed (configuration error)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO_ROOT}/test_vectors/corpus.json"
NOIR_RUNNER_READY=false  # flip to true in M3 when the circuit + runner exist

# ── Step 1: Dart stepper regression ─────────────────────────────────────────

echo "=== Step 1: Dart stepper regression (flutter test) ==="
cd "${REPO_ROOT}"
flutter test test/engine/ --reporter=expanded
echo "  Stepper tests passed."

# ── Step 2: Noir circuit runner ──────────────────────────────────────────────

echo ""
echo "=== Step 2: Noir circuit runner ==="

if [[ ! -f "${CORPUS}" ]]; then
  echo "  corpus.json not present — skipping Noir runner (empty corpus)."
  echo "  (Run scripts/gen_vectors.dart to generate the corpus from seeds.json.)"
  exit 0
fi

if ! $NOIR_RUNNER_READY; then
  echo "  ERROR: corpus.json exists but the Noir runner is not yet wired."
  echo "  Vectors are accumulating that nothing checks. This is a CI configuration"
  echo "  error. Either:"
  echo "    1. Remove corpus.json until M3 wires the circuit runner, or"
  echo "    2. Set NOIR_RUNNER_READY=true in this script and implement the runner."
  exit 2
fi

# ── Noir runner (fill in at M3) ───────────────────────────────────────────────
#
# For each tier in 12 24 48; do
#   for each vector in corpus.json:
#     build witness from input (applying raw_overrides and declared_overrides)
#     if kind == "positive":
#       nargo execute + bb prove + bb verify must SUCCEED
#       circuit-computed commitment must equal corpus expected.commitment
#     if kind == "negative":
#       prove/verify must FAIL (any failure counts)
#       a negative that verifies is a release-blocking bug — exit 1
# done
#
# [CONFIRM: nargo/bb CLI flags for UltraHonk at M3]

echo "Noir runner: all vectors passed."
exit 0
