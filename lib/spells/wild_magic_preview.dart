// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_preview.dart — the card-facing, DISPLAY-ONLY view of a spell's
// wild magic (docs/WILD_MAGIC_PLAN.md §4, §7.5).
//
// Wild magic is a fixed property of the rune: a spell either always fires its
// effect or never does, because the hash has no per-cast entropy in it. That
// makes it a *card fact* — as printable on the spell card as its mana cost —
// and this file is what lets the card print it.
//
// ── What this is NOT ──────────────────────────────────────────────────────────
// This is not a second derivation path. Everything here delegates to
// `WildMagic` (§10 invariant 2); the only difference is where the inputs come
// from. The engine derives triggers from CERTIFIED proof outputs at cast time
// (`WildMagic.triggersFor`, §4.6 / §10 invariant 6) and that is the only
// derivation allowed to touch battle state. This one reads a stored
// `SpellAsset` — trusted enough to paint a label with, never enough to resolve
// an effect with. If you ever find yourself wiring a value from this file into
// TurnLoop, stop: the answer is `WildMagic.triggersFor`.
//
// ── Which seed word a card previews under ─────────────────────────────────────
// Wild magic is only defined relative to a leyline seed word, and there are two
// of them: the player's own (Identity.loadCommunitySeed, set in Settings) and
// the host-authoritative one a given duel is fought under (MatchConfig
// .communitySeed — the guest adopts the host's, see battle_lobby_screen.dart).
// A card must show whichever one is actually in force, or it lies to the player
// at exactly the moment it matters. Hence [activeLeylineSeed]: the library
// primes it from the player's own setting, and BattleScreen overrides it for
// the duration of a duel.

import 'dart:math' show pow;

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../battle/engine/trajectory_parser.dart' show ParsedFormula;
import '../battle/engine/wild_magic.dart';
import '../battle/models/leyline_config.dart' show LeylineConfig;
import '../battle/models/wild_magic_effect.dart';
import '../engine/border_zone.dart';
import '../identity/identity.dart';
import 'spell_asset.dart';

// ── The seed word currently in force ──────────────────────────────────────────

/// The leyline seed word every spell card in the UI previews its wild magic
/// under. Defaults to [kDefaultCommunitySeed] so a card is never blank while
/// the real value loads.
///
/// A `ValueNotifier` rather than a plain global because rotating the seed
/// word is meant to visibly re-roll the whole library (WILD_MAGIC_PLAN.md
/// §2.6 — it is the ratified anti-grinder lever, and it only works if players
/// can see it working): cards listening to this repaint the moment the seed
/// changes, instead of waiting for a screen to be popped and re-pushed.
final ValueNotifier<String> activeLeylineSeed =
    ValueNotifier<String>(kDefaultCommunitySeed);

/// Reloads [activeLeylineSeed] from the player's stored setting.
///
/// Failure is deliberately swallowed: this reads secure storage, which isn't
/// available in every context the UI runs in (widget tests with no
/// platform-channel mocks, most obviously), and a card that previews under the
/// default tradition is a far better outcome than a screen that throws.
Future<void> refreshActiveLeylineSeed() async {
  try {
    activeLeylineSeed.value =
        await Identity.loadCommunitySeed() ?? kDefaultCommunitySeed;
  } catch (_) {
    // Keep whatever we had; see doc comment.
  }
}

/// Points every card at [seed] for the duration of a duel and returns the
/// previous value, which the caller must restore when the duel ends.
///
/// The guest adopts the host's seed word (DECISION 3), so during a match the
/// player's own setting is simply not what their spells will hash under. Cards
/// opened from the hand tray have to say what will really happen.
String overrideLeylineSeed(String seed) {
  final previous = activeLeylineSeed.value;
  activeLeylineSeed.value = seed;
  return previous;
}

// ── The preview ───────────────────────────────────────────────────────────────

/// The wild-magic effects [spell] fires under [communitySeed], or an empty
/// list for the ~97% of spells that fire none.
///
/// Returns empty rather than throwing for any spell whose stored data can't
/// support the derivation — an owner pubkey that isn't a Field, a legacy save
/// with no certified geometry, a trade-offer preview stub that carries display
/// metadata only. A card that shows no wild magic is the correct failure mode;
/// an exception thrown from `build` is not.
///
/// ## KNOWN INCONSISTENT under Wild Magic v2 — see the header, and §5
///
/// v2 keys on `caster x certified spell behavior x leyline`, and this function
/// has none of those three to hand at paint time:
///
///   * **Caster.** It uses `spell.ownerPubkeyHex` — the INSCRIBER — because the
///     viewer's own identity is behind an async secure-storage read this
///     synchronous painter cannot make. For your own spell those coincide; for
///     a loaned or traded one the card will preview the LENDER's wild magic
///     while the engine fires the borrower's.
///   * **Certified behaviour.** It uses the authored `SpellAsset.formula` and
///     `segmentCount`/`dotCount`, not the proof. Those are the wire fields
///     M4.22 established resolution must never read; a drifted asset previews
///     one thing and casts another.
///   * **Leyline.** It builds an ORDINARY config from the active seed word, so
///     a numbered/mutable leyline previews as its ordinary namesake.
///
/// Fixing all three is the preview/identity slice (Slice 3): the card needs the
/// viewer's identity plumbed in and its inputs re-sourced from the spell's own
/// proof via `PeerCastVerifier.certifyOwnProof`. Until then this is a label,
/// and — as the header already says — nothing here may reach battle state.
List<WildMagicTrigger> wildMagicPreviewFor(SpellAsset spell, String communitySeed) {
  if (!_isFieldHex(spell.ownerPubkeyHex)) return const [];
  if (spell.segmentCount < 0 || spell.dotCount < 0) return const [];

  final key = '${spell.ownerPubkeyHex}|${spell.t}|$communitySeed|'
      '${spell.segmentCount}|${spell.dotCount}|${spell.formula.join(",")}';
  final cached = _cache[key];
  if (cached != null) return cached;

  final zones = borderZonesFromNames(spell.formula);
  final formulas = completedFormulasFromZones(zones);
  final List<WildMagicTrigger> triggers;
  try {
    triggers = WildMagic.triggersFor(
      casterPubkeyHex: spell.ownerPubkeyHex,
      certifiedTrajectory: zones,
      certifiedBaseManaCost: _authoredBaseManaCost(spell, formulas.length),
      leylineConfigHash:
          LeylineConfig.ordinary(communitySeed).leylineConfigHash,
      formulas: formulas,
    );
  } on ArgumentError {
    // Malformed stored data (a pubkey that parses as a Field but isn't, a
    // trajectory element with no pinned byte). A blank card, not a crash.
    return const [];
  }

  // Cards repaint per frame during battle animations and a SHA-256 per card
  // per frame is wasteful, if not actually expensive. Flat cap, cleared
  // wholesale: this is a paint cache, not a store, and the working set is one
  // library's worth of cards.
  if (_cache.length >= _kCacheLimit) _cache.clear();
  _cache[key] = triggers;
  return triggers;
}

const int _kCacheLimit = 512;
final Map<String, List<WildMagicTrigger>> _cache = {};

/// `SpellAsset.formula`'s zone-name sequence as `BorderZone`s.
///
/// `SpellAsset.formula` is `FormulaTracker.committed` mapped through
/// `BorderZone.name` (main.dart), i.e. the authored analogue of the flat
/// committed sequence `TrajectoryParser.certifiedElementSequence` recovers from
/// a proof. Unrecognised names are dropped, matching `_borderZoneSequence` in
/// spell_card_painter.dart.
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

/// Chunks a flat zone sequence by 3, dropping the 0–2 element residual — the
/// complete-triplets-only view `TrajectoryParser.parse` produces and
/// [WildMagic.eligibleElements] wants.
List<ParsedFormula> completedFormulasFromZones(List<BorderZone> zones) => [
      for (var i = 0; i + 3 <= zones.length; i += 3)
        ParsedFormula(
          affinity: zones[i],
          effectType1: zones[i + 1],
          effectType2: zones[i + 2],
        ),
    ];

/// [completedFormulasFromZones] over raw names, kept for callers that have the
/// stored strings rather than zones.
List<ParsedFormula> completedFormulasFromNames(List<String> formula) =>
    completedFormulasFromZones(borderZonesFromNames(formula));

/// `PeerCastVerifier.certifiedBaseManaCost`'s formula, over the spell's
/// AUTHORED geometry rather than its proof — the preview's stand-in for the
/// certified base cost. Same arithmetic and the same rounding, so a spell whose
/// authored fields match its proof previews the real hash.
int _authoredBaseManaCost(SpellAsset spell, int completedFormulaCount) {
  final base = 5 * spell.segmentCount + spell.dotCount;
  final effectCount = completedFormulaCount - 1 < 0 ? 0 : completedFormulaCount - 1;
  return (base * pow(1.05, spell.t) * pow(1.5, effectCount)).round();
}

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
