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

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../battle/engine/trajectory_parser.dart' show ParsedFormula;
import '../battle/engine/wild_magic.dart';
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
/// support the derivation — a commitment that isn't a 32-byte Field (legacy
/// saves, hand-built test fixtures, a trade-offer preview stub that carries
/// display metadata only). A card that shows no wild magic is the correct
/// failure mode; an exception thrown from `build` is not.
List<WildMagicTrigger> wildMagicPreviewFor(SpellAsset spell, String communitySeed) {
  if (!_isFieldHex(spell.commitmentHex)) return const [];

  final key = '${spell.commitmentHex}|${spell.t}|$communitySeed|'
      '${spell.formula.join(",")}';
  final cached = _cache[key];
  if (cached != null) return cached;

  final triggers = WildMagic.triggersFromParts(
    commitmentHex: spell.commitmentHex,
    t: spell.t,
    formulas: completedFormulasFromNames(spell.formula),
    communitySeed: communitySeed,
  );

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

/// `SpellAsset.formula`'s flat zone-name sequence, regrouped into the complete
/// triplets [WildMagic.eligibleElements] wants.
///
/// `SpellAsset.formula` is `FormulaTracker.committed` mapped through
/// `BorderZone.name` (main.dart), i.e. the same flat committed sequence
/// `TrajectoryParser.certifiedElementSequence` recovers from a proof — so
/// chunking it by 3 and dropping the 0–2 element residual reproduces
/// `TrajectoryParser.parse`'s complete-triplets-only view. Unrecognised names
/// are dropped first, matching `_borderZoneSequence` in spell_card_painter.dart.
List<ParsedFormula> completedFormulasFromNames(List<String> formula) {
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
  return [
    for (var i = 0; i + 3 <= zones.length; i += 3)
      ParsedFormula(
        affinity: zones[i],
        effectType1: zones[i + 1],
        effectType2: zones[i + 2],
      ),
  ];
}

/// True iff [hex] is a 32-byte Field hex string (with or without `0x`), the
/// only shape [WildMagic.seedHexFromParts] will accept.
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
