// SPDX-License-Identifier: GPL-3.0-or-later
//
// match_config.dart — MatchConfig data model.
//
// Both players independently build a MatchConfig and exchange it via
// BattleSession.exchangeMatchConfig(). Agreement is field-by-field:
// both sides must produce identical configs or the session is aborted.
// Conflict-resolution UI is stubbed (see battle_session.dart).
//
// Mana model fields (manaGemPoolPerGem, manaGemRegenPerGem, etc.) are
// present so the model is wire-stable; no balance logic lives here.
//
// See docs/BATTLE_PROTOCOL.md §2 (matchConfig message) and §9 (caps/tiers).

// ── Win condition ─────────────────────────────────────────────────────────────

enum WinCondition {
  /// All members of every opposing team eliminated — the implemented path.
  lastTeamStanding,

  /// Alternate win condition seam.
  // TODO(battle): define flag placement, capture rules, and scoring.
  captureTheFlag,
}

// ── Config ────────────────────────────────────────────────────────────────────

class MatchConfig {
  const MatchConfig({
    this.playerHp = 24,
    this.gridRadius = 4,
    this.baseRange = 3,
    this.rulesetVersion = 2,
    this.tier = 24,
    this.accoutrementLoadoutId,
    this.manaGemPoolPerGem = 100,
    this.manaGemRegenPerGem = 10,
    this.winCondition = WinCondition.lastTeamStanding,
    this.maxPlayers = 2,
    this.experimentalMultiplayer = false,
    this.sorcererMode = false,
  })  : assert(tier == 12 || tier == 24 || tier == 48, 'tier must be 12, 24, or 48'),
        assert(maxPlayers >= 1, 'maxPlayers must be ≥ 1'),
        assert(!experimentalMultiplayer || maxPlayers <= 6, 'LAN cap is 6');

  /// Starting HP per wizard. Default 24 (runewright_design_v2_4.md).
  final int playerHp;

  /// Battlefield radius in tiles. Default 4 → 61 tiles.
  final int gridRadius;

  /// Base attack range in tiles.
  final int baseRange;

  /// Negotiated ruleset epoch. Must match on both sides.
  /// See CIRCUIT_IO.md §6; currently 2.
  final int rulesetVersion;

  /// Circuit tier (12 / 24 / 48) — smallest covering the declared max T.
  /// Tier 48 requires ≥6 GB RAM; gated by DeviceCapabilities.ramTierCap.
  final int tier;

  /// Reference to the player's chosen ChapterAsset id.
  // TODO(battle): validate existence; for now just carried as a string.
  final String? accoutrementLoadoutId;

  // ── Mana model knobs (fields only; no balance logic) ──────────────────────

  /// Max mana pool contribution per Mana Gem. Default 100.
  final int manaGemPoolPerGem;

  /// Mana regeneration per turn per Mana Gem. Default 10.
  final int manaGemRegenPerGem;

  // TODO(battle): Fire-Air HP-per-mana conversion rate field — add once
  //   the Fire-Air effect row is specified (design doc §effects table).

  // ── Match shape ───────────────────────────────────────────────────────────

  final WinCondition winCondition;

  /// 1 = solo (no network), 2 = standard, 3–6 = experimentalMultiplayer only.
  final int maxPlayers;

  /// Gates 3–6 player sessions. Never set by default; requires explicit opt-in.
  final bool experimentalMultiplayer;

  /// When true, spell casts require a spoken incantation scored by [VocalScorer].
  /// Both sides must agree on this flag (enforced by [matches]).
  /// Wire format: adds a 3-byte sorcerer suffix to spell action payloads.
  final bool sorcererMode;

  // ── Agreement check ───────────────────────────────────────────────────────

  /// True when [other] has identical values on every negotiated field.
  bool matches(MatchConfig other) =>
      playerHp == other.playerHp &&
      gridRadius == other.gridRadius &&
      baseRange == other.baseRange &&
      rulesetVersion == other.rulesetVersion &&
      tier == other.tier &&
      manaGemPoolPerGem == other.manaGemPoolPerGem &&
      manaGemRegenPerGem == other.manaGemRegenPerGem &&
      winCondition == other.winCondition &&
      maxPlayers == other.maxPlayers &&
      experimentalMultiplayer == other.experimentalMultiplayer &&
      sorcererMode == other.sorcererMode;

  // ── Serialisation (wire + on-disk) ────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'playerHp': playerHp,
        'gridRadius': gridRadius,
        'baseRange': baseRange,
        'rulesetVersion': rulesetVersion,
        'tier': tier,
        if (accoutrementLoadoutId != null) 'accoutrementLoadoutId': accoutrementLoadoutId,
        'manaGemPoolPerGem': manaGemPoolPerGem,
        'manaGemRegenPerGem': manaGemRegenPerGem,
        'winCondition': winCondition.name,
        'maxPlayers': maxPlayers,
        'experimentalMultiplayer': experimentalMultiplayer,
        'sorcererMode': sorcererMode,
      };

  static MatchConfig fromJson(Map<String, dynamic> j) => MatchConfig(
        playerHp: j['playerHp'] as int? ?? 24,
        gridRadius: j['gridRadius'] as int? ?? 4,
        baseRange: j['baseRange'] as int? ?? 3,
        rulesetVersion: j['rulesetVersion'] as int? ?? 2,
        tier: j['tier'] as int? ?? 24,
        accoutrementLoadoutId: j['accoutrementLoadoutId'] as String?,
        manaGemPoolPerGem: j['manaGemPoolPerGem'] as int? ?? 100,
        manaGemRegenPerGem: j['manaGemRegenPerGem'] as int? ?? 10,
        winCondition: WinCondition.values.firstWhere(
          (w) => w.name == (j['winCondition'] as String? ?? 'lastTeamStanding'),
          orElse: () => WinCondition.lastTeamStanding,
        ),
        maxPlayers: j['maxPlayers'] as int? ?? 2,
        experimentalMultiplayer: j['experimentalMultiplayer'] as bool? ?? false,
        sorcererMode: j['sorcererMode'] as bool? ?? false,
      );
}
