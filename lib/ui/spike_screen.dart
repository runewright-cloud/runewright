// M3.4 on-device gate + measurement harness for the real v2.4 circuit.
// Supersedes the M2 proxy-circuit spike (ca_spike_t*) that used to live here.
// Also the harness for the ink-substrate tier-12 cold/warm proving-time
// measurement (RULESET_VERSION 2): tap "Prove Tier 12" once on a fresh
// install for cold (SRS cache miss, network download), then 3-5 more times
// for warm (cache hit) -- read srs_ms/wall_ms off each RUNEWRIGHT_PROVE
// logcat line, see below.
//
// Calls:  lib/ffi/prover.dart → noir_rs barretenberg FFI
// Assets: assets/circuits/ca_v2_4_tier{12,24,48}.json + matching .vk

import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ffi/prover.dart';
import '../ffi/srs_cache.dart';

// poseidon2_hash2(0, 0) — the interim dummy owner_pubkey used throughout
// test_vectors/seeds.json and scripts/gen_vectors.dart until the identity
// module lands. CIRCUIT_IO.md CIRCUIT_IO 5/6 — the VK-stable binding.
const _ownerPubkeyHex =
    '0x0b63a53787021a4a962a452c2921b3663aff1ffd8d5510540f8e659e782956f1';

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  bool _busy = false;
  final List<String> _log = ['Ready. Press a button to start proving.'];

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _append(String msg) {
    setState(() => _log.add(msg));
    debugPrint('[spike] $msg');
  }

  // ── Core measurement flow ─────────────────────────────────────────────────

  Future<void> _runSpike(int tier) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _log.clear();
      _log.add('─── Tier $tier (v2.4) ───');
    });

    try {
      // 1. Load circuit from bundled asset
      _append('Loading circuit asset…');
      final assetPath = 'assets/circuits/ca_v2_4_tier$tier.json';
      final circuitJson = await rootBundle.loadString(assetPath);

      // 2. Extract base64 bytecode from the JSON artifact
      _append('Extracting bytecode…');
      final bytecode = await extractBytecode(circuitJson);

      // 3. Init SRS via the PERSISTENT on-disk cache (lib/ffi/srs_cache.dart),
      //    not the network-only `initSrs` this screen used through M3.4 --
      //    that always re-downloaded over the network on every tap, which
      //    can't distinguish a cold (cache miss, network fetch) run from a
      //    warm (cache hit, disk read only) one. Timed separately from the
      //    prove call below so SRS-load cost and proving cost are visible
      //    as distinct numbers, not folded together.
      //    We skip circuit_compute_vk because it crashes on AArch64 Android with
      //    "Backend error: vector" (std::out_of_range in barretenberg-rs 4.2.0 arm64,
      //    a real but separate AArch64 bug from the hardware_concurrency one below).
      //    VKs were pre-computed on x86-64 and bundled as assets instead.
      _append('Initialising SRS… (may download ${_srsHint(tier)} on first run, cached after)');
      final srsStopwatch = Stopwatch()..start();
      // Each tier needs a different SRS size (t12≈128MB, t24≈256MB, t48≈512MB).
      // Use per-tier cache files so a t24 warm-up can't pollute the t48 run.
      final baseCache = await srsCachePath();
      final cachePath = baseCache.replaceFirst(kSrsCacheFileName, 'runewright_srs_t$tier.local');
      await initSrsCached(bytecode, cachePath: cachePath);
      srsStopwatch.stop();
      _append('SRS ready in ${srsStopwatch.elapsedMilliseconds} ms (cache: $cachePath)');

      // 4. Load pre-computed VK from bundled asset (bypasses broken circuit_compute_vk).
      _append('Loading bundled VK…');
      final vkData = await rootBundle.load('assets/circuits/ca_v2_4_tier$tier.vk');
      final vk = vkData.buffer.asUint8List();
      _append('VK: ${vk.length} bytes (pre-computed, bundled)');

      // 5. Prove with the known-good witness: all-zero grid, T=1, the pinned
      //    owner_pubkey, zero key halves, ruleset_version=3 (must match the
      //    circuit's hardcoded RULESET_VERSION -- CIRCUIT_IO.md CIRCUIT_IO 6,
      //    same value as spells/inscribe.dart's kRulesetVersionHex). This is the
      //    M3.4 step-6 gate: the first real exercise of public-input
      //    (T/owner_pubkey/ruleset_version) marshalling across FRB, and of
      //    the hardware_concurrency fix (ffi/src/api/prover.rs's #[ctor])
      //    surviving FRB's worker-thread dispatch rather than just the
      //    bare-metal smoke test's single thread.
      _append('Proving tier $tier… (UI stays responsive — watch logcat for result)');
      final grid = List<int>.filled(469, 0);
      final result = await proveAndTime(
        bytecode,
        grid,
        keyHiHex: '0x0',
        keyLoHex: '0x0',
        tHex: '0x1',
        ownerPubkeyHex: _ownerPubkeyHex,
        rulesetVersionHex: '0x3',
        vkBytes: vk,
      );

      // 6. Verify
      _append('Verifying…');
      final verified = await verifyProof(vk, result.proofBytes);

      // 7. Emit the acceptance-gate log line (grep for this in adb logcat)
      final logLine = 'RUNEWRIGHT_PROVE tier=$tier '
          'srs_ms=${srsStopwatch.elapsedMilliseconds} '
          'wall_ms=${result.wallMs} '
          'peak_rss_kb=${result.peakRssKb} '
          'verified=$verified';
      developer.log(logLine, name: 'runewright.spike', level: 800);

      _append('Done ✓  srs=${srsStopwatch.elapsedMilliseconds} ms  '
          'prove=${result.wallMs} ms  '
          'rss=${result.peakRssKb} kB  '
          'verified=$verified');
      _append('→ See logcat:  adb logcat -s flutter | grep RUNEWRIGHT_PROVE');
    } catch (e) {
      _append('ERROR: $e');
      _append('If this is an UnimplementedError, re-run:');
      _append('  flutter_rust_bridge_codegen generate');
    } finally {
      setState(() => _busy = false);
    }
  }

  String _srsHint(int tier) {
    if (tier <= 12) return '~128 MB';
    if (tier <= 24) return '~256 MB';
    return '~512 MB';
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('M3.4 — v2.4 Proving Harness'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // ── Buttons ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [12, 24, 48].map((tier) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ElevatedButton(
                      onPressed: _busy ? null : () => _runSpike(tier),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo[800],
                        disabledBackgroundColor: Colors.grey[900],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white38,
                              ),
                            )
                          : Text(
                              'Prove\nTier $tier',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 13),
                            ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          // ── Status log ───────────────────────────────────────────────────
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[950] ?? Colors.grey[900],
                border: Border.all(color: Colors.grey[800]!),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _LogView(entries: _log),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Scrolling log widget ────────────────────────────────────────────────────

class _LogView extends StatefulWidget {
  final List<String> entries;
  const _LogView({required this.entries});

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_LogView old) {
    super.didUpdateWidget(old);
    // Auto-scroll to bottom when new entries arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemCount: widget.entries.length,
      itemBuilder: (_, i) {
        final entry = widget.entries[i];
        final isError = entry.startsWith('ERROR') || entry.startsWith('If this');
        final isDone  = entry.startsWith('Done ✓') || entry.startsWith('→');
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            entry,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isError
                  ? Colors.red[400]
                  : isDone
                      ? Colors.green[400]
                      : Colors.grey[400],
            ),
          ),
        );
      },
    );
  }
}
