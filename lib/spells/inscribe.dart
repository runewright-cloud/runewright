// SPDX-License-Identifier: GPL-3.0-or-later
//
// inscribe.dart — pure async orchestration for turning a played-out CA
// simulation into a persisted, owner-bound SpellAsset: pick the smallest
// circuit tier covering T, prove, self-verify, persist. Separated from the
// GameScreen widget the same way gate_runner.dart is separated from
// gate_screen.dart -- every call here is to an existing, already-tested
// entry point (the FFI prover, Identity, SpellAsset), and this stays
// testable without driving a real GUI.

import 'dart:io';
import 'dart:typed_data';

import '../engine/hex_grid.dart';
import '../ffi/prover.dart' as prover;
import '../ffi/srs_cache.dart';
import '../identity/identity.dart';
import 'spell_asset.dart';

class InscribeException implements Exception {
  InscribeException(this.message);
  final String message;
  @override
  String toString() => 'InscribeException: $message';
}

/// The three circuit tiers, smallest first -- CLAUDE.md hard invariant 6.
const List<int> kInscribeTiers = [12, 24, 48];
const int kMaxInscribableSteps = 48;

/// `RULESET_VERSION` -- CIRCUIT_IO.md CIRCUIT_IO 6, same fixed value used
/// throughout (gate_runner.dart's kGateRulesetVersionHex, spike_screen.dart).
const String kRulesetVersionHex = '0x1';

/// Smallest tier covering [t] generations, or null if [t] is outside the
/// circuit's supported range (`1 <= T <= 48`).
int? tierForSteps(int t) {
  if (t < 1) return null;
  for (final tier in kInscribeTiers) {
    if (t <= tier) return tier;
  }
  return null;
}

/// Loads a bundled circuit JSON asset as a string (e.g. `rootBundle.loadString`).
/// Injected so this file has no Flutter-asset-bundle dependency.
typedef CircuitJsonLoader = Future<String> Function(String assetPath);

/// Loads a bundled binary asset (e.g. a `.vk` file) as bytes.
typedef BinaryAssetLoader = Future<Uint8List> Function(String assetPath);

/// Reports a human-readable status string as inscription moves through its
/// stages, for a progress dialog. Best-effort UI feedback only -- never
/// awaited, never affects control flow.
typedef InscribeProgress = void Function(String message);

/// Proves that [initialGrid] simulated for [steps] generations produces the
/// trajectory the player saw, binds the proof to [identity]'s `owner_pubkey`,
/// self-verifies it, and persists the result as a [SpellAsset].
///
/// The SRS (structured reference string) needed to prove is cached on disk
/// at [srs_cache.dart]'s `srsCachePath()` -- the first inscription on a
/// fresh device downloads it over the network and writes the cache file;
/// every inscription after that on the same device reads from the cache
/// and needs no connection. [onProgress], if given, is told which of those
/// two cases this call is before attempting it, so the caller can warn the
/// player honestly ("first inscription needs a connection") rather than
/// presenting every inscription as equally network-dependent.
///
/// Throws [InscribeException] if [steps] is outside `1..48`, if the SRS
/// can't be obtained (no cache and no network, or a corrupt cache file --
/// see `ffi/src/api/prover.rs`'s `get_srs_cached`, which converts what
/// would otherwise be an unrecoverable panic into this catchable
/// exception), or if the freshly generated proof fails self-verification
/// (should never happen; treated as a hard stop rather than silently
/// persisting a bad proof).
Future<SpellAsset> inscribeSpell({
  required HexGrid initialGrid,
  required int steps,
  required Identity identity,
  required int manaCost,
  required CircuitJsonLoader loadCircuitJson,
  required BinaryAssetLoader loadVkBytes,
  InscribeProgress? onProgress,
}) async {
  final tier = tierForSteps(steps);
  if (tier == null) {
    throw InscribeException(
      'cannot inscribe: $steps generations is outside the supported 1-$kMaxInscribableSteps range',
    );
  }

  final gridState = initialGrid.packGridState();
  final ownerPubkeyHex = await identity.ownerPubkeyHex();

  final circuitJson = await loadCircuitJson('assets/circuits/ca_v2_4_tier$tier.json');
  final bytecode = await prover.extractBytecode(circuitJson);

  final cachePath = await srsCachePath();
  final cacheHit = await File(cachePath).exists();
  onProgress?.call(
    cacheHit ? 'Preparing the loom…' : 'Preparing the loom… (first inscription needs a connection)',
  );
  try {
    await prover.initSrsCached(bytecode, cachePath: cachePath);
  } catch (e) {
    throw InscribeException(
      cacheHit
          ? 'could not read the cached proving setup ($e) -- it may be corrupt; clearing app storage will let it re-download'
          : 'could not download the proving setup ($e) -- check your network connection and try again',
    );
  }

  final vkBytes = await loadVkBytes('assets/circuits/ca_v2_4_tier$tier.vk');

  onProgress?.call('Inscribing your spell…');
  final result = await prover.proveAndTime(
    bytecode,
    gridState,
    keyHiHex: identity.keyHiHex,
    keyLoHex: identity.keyLoHex,
    tHex: '0x${steps.toRadixString(16)}',
    ownerPubkeyHex: ownerPubkeyHex,
    rulesetVersionHex: kRulesetVersionHex,
    vkBytes: vkBytes,
  );

  onProgress?.call('Verifying…');
  final verified = await prover.verifyProof(vkBytes, result.proofBytes);
  if (!verified) {
    throw InscribeException('the freshly generated proof failed self-verification -- not persisting');
  }

  final asset = SpellAsset(
    id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
    createdAt: DateTime.now().toUtc(),
    tier: tier,
    t: steps,
    ownerPubkeyHex: ownerPubkeyHex,
    manaCost: manaCost,
    initialGrid: gridState,
    proofBytes: result.proofBytes,
  );
  await asset.save();
  return asset;
}
