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
import '../ffi/identity.dart' as ffi_identity;
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
/// Bumped to 3 for deterministic geometry outputs (segment_count, dot_count).
const String kRulesetVersionHex = '0x3';

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

/// Extracts the commitment field element from the noir-rs proof wire format.
///
/// Wire format: [4 bytes BE: num_public_inputs][public_input fields][proof fields]
/// Each field is 32 bytes (big-endian BN254).
/// Public input order (CIRCUIT_IO.md CIRCUIT_IO 8):
///   index 0: T, index 1: owner_pubkey, index 2: ruleset_version,
///   index 3: commitment  ← this function's target
String _commitmentHexFromProof(Uint8List proofBytes) {
  const offset = 4 + 3 * 32;
  final bytes = proofBytes.sublist(offset, offset + 32);
  return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Proves that [initialGrid] simulated for [steps] generations produces the
/// trajectory the player saw, binds the proof to [identity]'s `owner_pubkey`,
/// self-verifies it, and persists the result as a [SpellAsset].
///
/// [name] is the player-assigned spell name; must be non-empty (the caller
/// is responsible for prompting before calling this function).
///
/// Throws [InscribeException] with message `'Spell already known.'` if a
/// spell with the same `Poseidon2(commitment, T)` hash is already in the
/// player's library (same grid AND same T -- Kin spells that share the same
/// grid but differ in T are saved normally, they are not duplicates).
///
/// Also throws [InscribeException] if [steps] is outside `1..48`, if the SRS
/// can't be obtained, or if the freshly generated proof fails self-verification.
Future<SpellAsset> inscribeSpell({
  required HexGrid initialGrid,
  required int steps,
  required Identity identity,
  required int manaCost,
  required int segmentCount,
  required int dotCount,
  required String name,
  required CircuitJsonLoader loadCircuitJson,
  required BinaryAssetLoader loadVkBytes,
  InscribeProgress? onProgress,
  List<String> formula = const [],
  List<String> supremeTags = const [],
  bool isSummon = false,
  String summonPersonality = 'aggressive',
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
  final tHex = '0x${steps.toRadixString(16)}';
  final result = await prover.proveAndTime(
    bytecode,
    gridState,
    keyHiHex: identity.keyHiHex,
    keyLoHex: identity.keyLoHex,
    tHex: tHex,
    ownerPubkeyHex: ownerPubkeyHex,
    rulesetVersionHex: kRulesetVersionHex,
    vkBytes: vkBytes,
  );

  onProgress?.call('Verifying…');
  final verified = await prover.verifyProof(vkBytes, result.proofBytes);
  if (!verified) {
    throw InscribeException('the freshly generated proof failed self-verification -- not persisting');
  }

  // Extract the in-circuit commitment from the verified proof's public inputs,
  // then compute the off-circuit spell_hash = Poseidon2(commitment, T).
  // Both calls use the same Poseidon2 implementation (bn254_blackbox_solver via
  // FFI -- CLAUDE.md hard invariant 1: never reimplement Poseidon2 in Dart).
  final commitmentHex = _commitmentHexFromProof(result.proofBytes);
  final spellHashHex = await ffi_identity.poseidon2Hash2(commitmentHex, tHex);

  // Duplicate detection: a spell the player has already inscribed themselves
  // (same grid AND same T) is identified by an identical spellHashHex.
  // Spells that were encountered from opponents (saved via a different path,
  // not yet implemented) are not checked here.
  final existing = await SpellAsset.loadAll();
  if (existing.any((s) => s.spellHashHex == spellHashHex)) {
    throw InscribeException('Spell already known.');
  }

  final asset = SpellAsset(
    id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
    createdAt: DateTime.now().toUtc(),
    tier: tier,
    t: steps,
    ownerPubkeyHex: ownerPubkeyHex,
    manaCost: manaCost,
    segmentCount: segmentCount,
    dotCount: dotCount,
    initialGrid: gridState,
    proofBytes: result.proofBytes,
    name: name,
    commitmentHex: commitmentHex,
    spellHashHex: spellHashHex,
    formula: formula,
    supremeTags: supremeTags,
    isSummon: isSummon,
    summonPersonality: summonPersonality,
  );
  await asset.save();
  return asset;
}
