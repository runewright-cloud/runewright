// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_preview.dart — the card-facing, DISPLAY-ONLY view of a spell's
// wild magic, and the app-wide "who is casting, under which leyline" context
// every such preview is taken against (docs/WILD_MAGIC_PLAN_VNEXT.md §2, §5).
//
// Wild Magic v2 is deterministic for
//
//     caster x certified spell behavior x leyline
//
// so a wild-magic preview is only meaningful once all three are known. All
// three live here: [activeWildMagicContext] carries the caster identity and the
// structured [LeylineConfig] in force, and [wildMagicPreviewFor] derives the
// triggers from a spell's own PROOF through the engine's derivation.
//
// ── What this is NOT ──────────────────────────────────────────────────────────
// This is not a second derivation path. It delegates to
// `PeerCastVerifier.certifyOwnProof` — the same call `TurnLoop
// .certifiedFromProofBytes` makes at cast time — so the card and the duel read
// one implementation (§10 invariant 2). The only difference is where the caster
// identity comes from: the engine takes it from the authenticated
// `WizardAvatar.ownerPubkeyHex` of the player casting, this takes it from the
// viewer's own identity in [activeWildMagicContext]. For the same proof, caster
// and leyline the two agree exactly, which is the whole point of printing wild
// magic on a card at all.
//
// Nothing here may reach battle state. If you find yourself wiring a value from
// this file into TurnLoop, stop: the answer is `certifiedFromProofBytes`.
//
// ── The caster is the CASTER, never the inscriber ─────────────────────────────
// Wild Magic follows whoever is casting (WILD_MAGIC_PLAN_VNEXT.md §2), so a
// borrowed, loaned or traded spell sitting in your library previews under YOUR
// identity — `SpellAsset.ownerPubkeyHex` names its inscriber and is deliberately
// not consulted. A surface with no viewer identity (a trade offer stub, a
// widget test with no secure storage) shows NO wild magic rather than inventing
// one: a zero key would give every unidentified viewer one shared magical
// identity, which is a consensus value conjured out of nothing.
//
// ── Which leyline a card previews under ───────────────────────────────────────
// There are two: the player's own (Identity.loadCommunitySeed, set in Settings)
// and the host-authoritative one a given duel is fought under
// (MatchConfig.leyline — the guest adopts the host's, see
// battle_lobby_screen.dart). A card must show whichever is actually in force,
// or it lies to the player at exactly the moment it matters. The library primes
// the context from the player's own setting; BattleScreen overrides it for the
// duration of a duel.

import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../battle/engine/peer_cast_verifier.dart' show PeerCastVerifier;
import '../battle/engine/trajectory_parser.dart' show ParsedFormula;
import '../battle/models/leyline_config.dart'
    show LeylineConfig, LeylineConfigException, kDefaultCommunitySeed;
import '../battle/models/wild_magic_effect.dart';
import '../engine/border_zone.dart';
import '../engine/formula_segmentation.dart';
import '../identity/identity.dart';
import '../battle/engine/incantation_lexicon.dart' show IncantationLexicon;
import 'spell_asset.dart';
import 'spell_identity.dart' show uniqueSpellId;

// ── The active preview context ────────────────────────────────────────────────

/// Who a spell card previews its wild magic *as*, and *where*.
///
/// Immutable and compared by value so a `ValueNotifier` holding it only
/// notifies on a real change — cards rebuild on every assignment otherwise, and
/// several of them repaint per frame during battle animations.
class WildMagicPreviewContext {
  const WildMagicPreviewContext({
    this.casterPubkeyHex,
    this.leyline = LeylineConfig.ordinaryDefault,
  });

  /// The viewer's canonical authenticated gameplay identity —
  /// `Poseidon2(key_hi, key_lo)`, the same value `WizardAvatar.ownerPubkeyHex`
  /// carries and the duel's fresh-nonce Ed25519 challenge authenticates.
  ///
  /// Null until the local identity has been read (and on a device that has none
  /// yet). Null means NO PREVIEW — see this file's header on why substituting a
  /// zero key would be worse than showing nothing.
  final String? casterPubkeyHex;

  /// The structured leyline in force. Held whole rather than as a seed word:
  /// `LeylineConfig.ordinary(seed)` cannot represent a numbered/mutable
  /// leyline, and reconstructing one at the call site would preview a mutable
  /// tradition as its ordinary namesake.
  final LeylineConfig leyline;

  WildMagicPreviewContext withCaster(String? casterPubkeyHex) =>
      WildMagicPreviewContext(
        casterPubkeyHex: casterPubkeyHex,
        leyline: leyline,
      );

  WildMagicPreviewContext withLeyline(LeylineConfig leyline) =>
      WildMagicPreviewContext(
        casterPubkeyHex: casterPubkeyHex,
        leyline: leyline,
      );

  @override
  bool operator ==(Object other) =>
      other is WildMagicPreviewContext &&
      other.casterPubkeyHex == casterPubkeyHex &&
      other.leyline == leyline;

  @override
  int get hashCode => Object.hash(casterPubkeyHex, leyline);

  @override
  String toString() => 'WildMagicPreviewContext(caster: '
      '${casterPubkeyHex ?? "<none>"}, leyline: ${leyline.displayName})';
}

/// THE active identity + leyline every wild-magic preview in the UI is taken
/// against.
///
/// A `ValueNotifier` rather than a plain global because rotating the leyline is
/// meant to visibly re-roll the whole library (WILD_MAGIC_PLAN.md §2.6 — it is
/// the ratified anti-grinder lever, and it only works if players can see it
/// working): cards listening to this repaint the moment it changes, instead of
/// waiting for a screen to be popped and re-pushed.
final ValueNotifier<WildMagicPreviewContext> activeWildMagicContext =
    ValueNotifier<WildMagicPreviewContext>(const WildMagicPreviewContext());

/// The one authoritative structured leyline. Read-only: assign through
/// [activeWildMagicContext] so the caster identity travels with it.
LeylineConfig get activeLeylineConfig => activeWildMagicContext.value.leyline;

/// The viewer identity previews are taken as, or null when none is known.
String? get activeCasterPubkeyHex =>
    activeWildMagicContext.value.casterPubkeyHex;

/// Reloads [activeWildMagicContext] from this device's own identity and stored
/// leyline setting. The app/session boundary primes it once (`AppRoot`), and
/// anything that changes either input assigns directly.
///
/// Never creates an identity: a device that has none yet is mid-onboarding, and
/// [Identity.loadOrCreate] would mint a Runekey behind the router's back.
///
/// Failure is deliberately swallowed and leaves the caster null: this reads
/// secure storage, which isn't available in every context the UI runs in
/// (widget tests with no platform-channel mocks, most obviously), and a card
/// that shows no wild magic is a far better outcome than a screen that throws.
Future<void> refreshActiveWildMagicContext() async {
  String? caster;
  var leyline = LeylineConfig.ordinaryDefault;
  try {
    leyline = LeylineConfig.ordinary(
      await Identity.loadCommunitySeed() ?? kDefaultCommunitySeed,
    );
  } catch (_) {
    // Keep the default tradition; see doc comment.
  }
  try {
    if (await Identity.exists()) {
      caster = await (await Identity.loadOrCreate()).ownerPubkeyHex();
    }
  } catch (_) {
    // Keep a null caster, i.e. no preview; see doc comment.
  }
  activeWildMagicContext.value =
      WildMagicPreviewContext(casterPubkeyHex: caster, leyline: leyline);
}

/// This device's canonical gameplay public key, priming
/// [activeWildMagicContext] on the way if it has not been read yet.
///
/// The one place outside the preview itself that resolves a local caster
/// identity for wild-magic purposes — solo and practice sessions seat the local
/// wizard with it, so the same wizard's spells fire the same wild magic in
/// practice, in the library and in a duel.
///
/// Returns null (never throws, never invents a key) when there is no identity
/// on the device or storage is unavailable.
Future<String?> resolveLocalCasterPubkeyHex() async {
  final known = activeWildMagicContext.value.casterPubkeyHex;
  if (known != null) return known;
  await refreshActiveWildMagicContext();
  return activeWildMagicContext.value.casterPubkeyHex;
}

/// Points every card at [context] for the duration of a duel and returns the
/// previous value, which the caller must restore when the duel ends.
///
/// The guest adopts the host's leyline (DECISION 3) and casts as themselves, so
/// during a match neither of the player's library defaults is necessarily what
/// their spells will hash under. Cards opened from the hand tray have to say
/// what will really happen.
WildMagicPreviewContext overrideWildMagicContext(
  WildMagicPreviewContext context,
) {
  final previous = activeWildMagicContext.value;
  activeWildMagicContext.value = context;
  return previous;
}

// ── The preview ───────────────────────────────────────────────────────────────

/// The wild-magic effects [spell] fires for [context]'s caster under
/// [context]'s leyline, or an empty list for the ~97% of spells that fire none.
///
/// Derived from the spell's own PROOF via `PeerCastVerifier.certifyOwnProof` —
/// the identical call the engine makes at cast time — so for one
/// `(proof, caster, leyline)` triple the card and the duel cannot disagree.
/// Nothing authored is consulted: not `SpellAsset.formula`, not
/// `segmentCount`/`dotCount`, not `ownerPubkeyHex`, not `commitmentHex`. Those
/// are the wire fields M4.22 established resolution must never read, and a
/// drifted asset would otherwise preview one thing and cast another.
///
/// Returns empty rather than throwing whenever an authoritative answer isn't
/// available — no viewer identity, no proof bytes (a legacy save, a trade-offer
/// preview stub that carries display metadata only), or a proof that will not
/// parse. A card that shows no wild magic is the correct failure mode; an
/// exception thrown from `build` is not.
List<WildMagicTrigger> wildMagicPreviewFor(
  SpellAsset spell,
  WildMagicPreviewContext context,
) {
  final caster = context.casterPubkeyHex;
  // Fail closed on both halves of the identity question: an absent viewer and
  // a stored key that is not a Field are the same answer — we do not know who
  // is casting, so we do not know what happens.
  if (caster == null || !_isFieldHex(caster)) return const [];
  if (spell.proofBytes.isEmpty) return const [];

  final String leylineHash;
  try {
    leylineHash = context.leyline.leylineConfigHash;
  } on LeylineConfigException {
    return const [];
  }

  final key = wildMagicPreviewCacheKey(spell, caster, leylineHash);
  final cached = _cache[key];
  if (cached != null) return cached;

  final List<WildMagicTrigger> triggers;
  try {
    // The preview must answer the same question the duel does, so it goes
    // through the same lexicon: under a mutable leyline a noise formula
    // contributes no wild-magic eligibility, and a preview that ignored that
    // would promise triggers the cast never fires. Derived here rather than
    // held on the context because [WildMagicPreviewContext] is const — and it
    // is affordable because it happens only on a cache MISS (the lookup above
    // is keyed on the leyline hash, so a leyline change invalidates it
    // wholesale).
    triggers = PeerCastVerifier.certifyOwnProof(
          spell,
          casterOwnerPubkeyHex: caster,
          lexicon: IncantationLexicon.of(context.leyline),
        )?.wildMagic ??
        const [];
  } on ArgumentError {
    // A caster key or trajectory element the canonical encoders refuse. A
    // blank card, not a crash.
    return const [];
  } on LeylineConfigException {
    return const [];
  }

  // Cards repaint per frame during battle animations, and this parses a proof
  // blob — the cache is what makes it affordable. Flat cap, cleared wholesale:
  // this is a paint cache, not a store, and the working set is one library's
  // worth of cards.
  if (_cache.length >= _kCacheLimit) _cache.clear();
  _cache[key] = triggers;
  return triggers;
}

const int _kCacheLimit = 512;
final Map<String, List<WildMagicTrigger>> _cache = {};

/// Clears the preview's paint cache. For tests that reuse one fixture across
/// contexts; production never needs it, because the cache is keyed on every
/// input the derivation reads.
void debugClearWildMagicPreviewCache() => _cache.clear();

/// The paint cache's key for one `(spell, caster, leyline)` triple.
///
/// Exposed for the aliasing test — a cache key is only correct if two distinct
/// proofs cannot produce the same one, and that is a property worth asserting
/// directly rather than inferring from a rendered card.
///
/// Every input the derivation reads is in here and nothing else is. `tier` and
/// `t` appear because `certifyOwnProof` picks the parse tier from them, so two
/// assets wrapping one proof at different tiers are genuinely different
/// derivations.
@visibleForTesting
String wildMagicPreviewCacheKey(
  SpellAsset spell,
  String casterPubkeyHex,
  String leylineConfigHash,
) =>
    '$casterPubkeyHex|$leylineConfigHash|${spell.tier}|${spell.t}|'
    '${proofIdentityForPreview(spell.proofBytes)}';

/// Memoized `SHA-256(proofBytes)` — the canonical [uniqueSpellId], computed at
/// most once per proof blob instance.
///
/// A digest, not a sample. An earlier version keyed the cache on length plus
/// the first and last eight bytes, which is a real aliasing hazard here rather
/// than a theoretical one: every proof of a given tier has the same length, the
/// same leading field-count bytes, and the same trailing `dotCount` field, so
/// two spells differing only in their trajectory collided exactly. One card
/// would then paint the other's Wild Magic.
///
/// The memo is what keeps that affordable. Hashing ~14 KB per card per frame is
/// the cost the cache exists to avoid, and [uniqueSpellId] rehashes on every
/// call — so the digest is computed lazily on first sight of a blob and hung
/// off the blob itself. An [Expando] rather than a map because it is keyed by
/// object identity and holds its keys weakly: entries disappear when the
/// `SpellAsset` does, so this needs no cap and cannot outlive a library.
///
/// SCOPE: this is a LOCAL PAINT-CACHE IDENTITY and nothing else. It is not a
/// gameplay spell identity, and its use here is not a precedent for moving any
/// commitment consumer — grid transmission, book Merkle leaves, duplicate-grid
/// guards, permissions and grants, trade identity, wire binding, hand ordering
/// — onto [uniqueSpellId]. That is the commitment-exposure audit's call, not
/// this cache's.
String proofIdentityForPreview(Uint8List proofBytes) =>
    _proofDigests[proofBytes] ??= uniqueSpellId(proofBytes);

final Expando<String> _proofDigests = Expando<String>('wildMagicProofDigest');

/// True iff [hex] is a 32-byte Field hex string (with or without `0x`), the
/// shape [WildMagic.canonicalPubkeyBytes] is happy to decode.
bool _isFieldHex(String hex) {
  final s = hex.startsWith('0x') ? hex.substring(2) : hex;
  if (s.length != 64) return false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39;
    final isLower = c >= 0x61 && c <= 0x66;
    final isUpper = c >= 0x41 && c <= 0x46;
    if (!isDigit && !isLower && !isUpper) return false;
  }
  return true;
}

// ── Authored-geometry helpers (NOT wild magic) ────────────────────────────────

/// `SpellAsset.formula`'s zone-name sequence as `BorderZone`s.
///
/// Display-only, and no longer part of any wild-magic derivation: the preview
/// reads the proof. Kept because the card painter renders the authored formula
/// as its elemental symbol ring, and that IS a fact about the stored asset.
List<BorderZone> borderZonesFromNames(List<String> formula) {
  final zones = <BorderZone>[];
  for (final name in formula) {
    final zone = switch (name.toLowerCase()) {
      'fire' => BorderZone.fire,
      'air' => BorderZone.air,
      'water' => BorderZone.water,
      'earth' => BorderZone.earth,
      _ => null,
    };
    if (zone != null) zones.add(zone);
  }
  return zones;
}

/// Chunks a flat zone sequence into formulas, dropping the incomplete trailing
/// residual — the complete-triplets-only view `TrajectoryParser.parse`
/// produces, through the same segmentation primitive that produces it.
List<ParsedFormula> completedFormulasFromZones(List<BorderZone> zones) => [
      for (final chunk in segmentFormulas(
        zones,
        formulaLength: kIncantationFormulaLength,
      ))
        ParsedFormula(
          affinity: chunk[0],
          effectType1: chunk[1],
          effectType2: chunk[2],
        ),
    ];

/// [completedFormulasFromZones] over raw names, kept for callers that have the
/// stored strings rather than zones.
List<ParsedFormula> completedFormulasFromNames(List<String> formula) =>
    completedFormulasFromZones(borderZonesFromNames(formula));
