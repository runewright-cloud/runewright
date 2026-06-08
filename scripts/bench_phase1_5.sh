#!/usr/bin/env bash
# bench_phase1_5.sh -- Benchmark ca_natural_v2 and ca_lookup_v2 at T in {5,10,20,30}.
# Writes phase1_5_results.csv incrementally so a crash does not lose all data.
# Run from repo root:  bash scripts/bench_phase1_5.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSV="$REPO_ROOT/phase1_5_results.csv"
T_VALUES=(5 10 20 30)
VERSIONS=(ca_natural_v2 ca_lookup_v2)
RUNS=3

echo "version,T,acir_opcodes,bb_gates,witness_ms,prove_ms,peak_mem_mb,proof_bytes,compile_s" \
    > "$CSV"

median() {
    python3 -c "
import sys, statistics
vals = [float(x) for x in sys.argv[1:]]
print(round(statistics.median(vals), 1))
" "$@"
}

for VERSION in "${VERSIONS[@]}"; do
    DIR="$REPO_ROOT/circuits/$VERSION"
    MAIN_NR="$DIR/src/main.nr"
    BYTECODE="$DIR/target/${VERSION}.json"
    WITNESS="$DIR/target/${VERSION}.gz"
    VK_DIR="$DIR/target/vk"
    VK_FILE="$DIR/target/vk/vk"
    PROOF_DIR="$DIR/target/proof"
    PROOF_FILE="$DIR/target/proof/proof"

    for T in "${T_VALUES[@]}"; do
        echo "=== $VERSION  T=$T ==="

        sed -i "s/^global T: u32 = [0-9]*;/global T: u32 = $T;/" "$MAIN_NR"

        # Compile (3 runs, median)
        compile_times=()
        for i in $(seq 1 $RUNS); do
            t0=$(date +%s%3N)
            nargo compile --program-dir "$DIR" 2>/dev/null
            compile_times+=( $(( $(date +%s%3N) - t0 )) )
        done
        compile_ms=$(median "${compile_times[@]}")
        compile_s=$(python3 -c "print(round($compile_ms/1000.0, 2))")

        # ACIR opcode count
        acir_opcodes=$(nargo info --program-dir "$DIR" 2>/dev/null \
            | grep "^| $VERSION " \
            | awk -F'|' '{gsub(/ /,"",$4); print $4}')

        # Gate count
        bb_gates=$(bb gates -b "$BYTECODE" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['functions'][0]['circuit_size'])")

        # Generate VK
        bb write_vk -b "$BYTECODE" -o "$VK_DIR" 2>/dev/null

        # Witness generation (3 runs, median)
        witness_times=()
        for i in $(seq 1 $RUNS); do
            t0=$(date +%s%3N)
            nargo execute --program-dir "$DIR" 2>/dev/null
            witness_times+=( $(( $(date +%s%3N) - t0 )) )
        done
        witness_ms=$(median "${witness_times[@]}")

        # Proof generation (3 runs, median + peak memory on final run)
        prove_times=()
        for i in $(seq 1 $RUNS); do
            t0=$(date +%s%3N)
            if [ "$i" -eq "$RUNS" ]; then
                /usr/bin/time -v bb prove \
                    -b "$BYTECODE" -w "$WITNESS" \
                    -o "$PROOF_DIR" -k "$VK_FILE" \
                    2>/tmp/bb_mem.txt
                peak_mem_kb=$(grep "Maximum resident" /tmp/bb_mem.txt | awk '{print $NF}')
                peak_mem_mb=$(python3 -c "print(round($peak_mem_kb/1024.0,1))")
            else
                bb prove -b "$BYTECODE" -w "$WITNESS" \
                    -o "$PROOF_DIR" -k "$VK_FILE" 2>/dev/null
            fi
            prove_times+=( $(( $(date +%s%3N) - t0 )) )
        done
        prove_ms=$(median "${prove_times[@]}")

        proof_bytes=$(wc -c < "$PROOF_FILE" | tr -d ' ')

        row="$VERSION,$T,$acir_opcodes,$bb_gates,$witness_ms,$prove_ms,$peak_mem_mb,$proof_bytes,$compile_s"
        echo "$row" | tee -a "$CSV"
    done
done

echo ""
echo "Results written to $CSV"
