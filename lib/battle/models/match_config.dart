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

import 'package:rune_duel/battle/models/wild_magic_effect.dart'
    show kDefaultCommunitySeed, normalizeCommunitySeed;
import 'package:rune_duel/battle/engine/battle_engine_version.dart'
    show kBattleEngineVersion, kUndeclaredBattleEngineVersion;
import 'package:rune_duel/spells/inscribe.dart' show kRulesetVersion;

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
    this.rulesetVersion = kRulesetVersion,
    this.battleEngineVersion = kBattleEngineVersion,
    this.tier = 24,
    this.accoutrementLoadoutId,
    this.innateManaPool = 100,
    this.manaGemPoolPerGem = 100,
    this.manaGemRegenPerGem = 10,
    this.winCondition = WinCondition.lastTeamStanding,
    this.maxPlayers = 2,
    this.experimentalMultiplayer = false,
    this.vocalComponents = false,
    this.somaticComponents = false,
    this.simultaneousCasting = false,
    this.communitySeed = kDefaultCommunitySeed,
  })  : assert(tier == 12 || tier == 24 || tier == 48, 'tier must be 12, 24, or 48'),
        assert(maxPlayers >= 1, 'maxPlayers must be ≥ 1'),
        assert(!experimentalMultiplayer || maxPlayers <= 6, 'LAN cap is 6');

  /// Starting HP per wizard. Default 24 (runewright_design_v2_4.md).
  final int playerHp;

  /// Battlefield radius in tiles. Default 4 → 61 tiles.
  final int gridRadius;

  /// Base attack range in tiles.
  final int baseRange;

  /// Negotiated ruleset epoch. Must match on both sides, AND must match the
  /// `ruleset_version` every cast spell's proof attests — [TurnLoop]
  /// forfeits the match on a mismatch, so this is a real gate, not a label.
  ///
  /// Defaults to [kRulesetVersion] (inscribe.dart), the single canonical
  /// definition shared with the circuits. It used to default to a hardcoded 2
  /// while the circuits were on 3, which made the negotiated value meaningless.
  /// See CIRCUIT_IO.md §6.
  final int rulesetVersion;

  /// The deterministic battle-engine epoch this match is pinned to — which
  /// rules both devices run to compute the same canonical [BattleState] from
  /// the same inputs (ordering of simultaneous actions, RNG binding, effect
  /// resolution).
  ///
  /// Deliberately NOT [rulesetVersion]. That one is the proof/circuit epoch: a
  /// bump there invalidates every inscribed spell's VK. This one is battle-only
  /// — the circuit certifies nothing about, say, which of two simultaneous
  /// free-move runs walks first, so a proof-epoch check cannot see an engine
  /// disagreement at all. See battle_engine_version.dart.
  ///
  /// Defaults to [kBattleEngineVersion], the single canonical definition. A
  /// config decoded from a peer that predates this field reads as
  /// [kUndeclaredBattleEngineVersion] (0) rather than silently adopting our own
  /// value — `runDuelSetup` refuses the match on anything but an exact match.
  final int battleEngineVersion;

  /// Circuit tier (12 / 24 / 48) — smallest covering the declared max T.
  /// Tier 48 requires ≥6 GB RAM; gated by DeviceCapabilities.ramTierCap.
  final int tier;

  /// Reference to the player's chosen ChapterAsset id.
  // TODO(battle): validate existence; for now just carried as a string.
  final String? accoutrementLoadoutId;

  // ── Mana model knobs ──────────────────────────────────────────────────────

  /// Every wizard's innate max mana pool, before any Mana Gem. Default 100.
  ///
  /// This replaces the old "core gem" — a mandatory, indestructible first gem
  /// that every wizard was silently handed so they'd have a pool at all. The
  /// pool is now intrinsic to the wizard; gems are purely optional capacity on
  /// top, and every gem is destructible. A gemless wizard has no passive regen
  /// (see [manaGemRegenPerGem]) and refills by meditating.
  final int innateManaPool;

  /// Max mana pool contribution per Mana Gem, on top of [innateManaPool].
  /// Default 100.
  final int manaGemPoolPerGem;

  /// Mana regeneration per turn per Mana Gem. Default 10. There is
  /// deliberately no innate regen: a wizard carrying no gems regains mana by
  /// meditating (+25 per phase) rather than passively.
  final int manaGemRegenPerGem;

  // TODO(battle): Fire-Air HP-per-mana conversion rate field — add once
  //   the Fire-Air effect row is specified (design doc §effects table).

  // ── Match shape ───────────────────────────────────────────────────────────

  final WinCondition winCondition;

  /// 1 = solo (no network), 2 = standard, 3–6 = experimentalMultiplayer only.
  final int maxPlayers;

  /// Gates 3–6 player sessions. Never set by default; requires explicit opt-in.
  final bool experimentalMultiplayer;

  // ── Spell components (docs/SPELL_COMPONENTS_PLAN.md) ──────────────────────
  //
  // These three replace the single `sorcererMode` boolean. The split is not
  // cosmetic: vocal is peer-verifiable and moves the mana ledger, somatic is a
  // self-attested sensor claim that can only ever reduce the caster to no
  // enhancement (§1's trust table). A player has real reason to want one and
  // not the other, and the two need different hardware.
  //
  // All three are compared field-by-field in [matches] — both sides must agree
  // or the session aborts, exactly as with every other negotiated field.

  /// When true, casting requires reciting the incantation into the microphone
  /// while CAST is held; what was said is scored by [IncantationRecallScorer]
  /// and priced by [RecallTally] against the certified trajectory.
  /// Wire format: adds the recall suffix to spell action payloads.
  final bool vocalComponents;

  /// When true, casting requires gesticulating for the duration of the hold,
  /// and the gesture performed selects the enhancement (replacing the tap
  /// picker). Never transmits a score — see SPELL_COMPONENTS_PLAN.md §4.
  final bool somaticComponents;

  /// When true, every player performs their components at the same moment.
  /// Off by default: the sequential order is easier to concentrate under and
  /// far easier on the microphones (§5.1), and the turn-taking is itself a
  /// mechanic — a later caster hears the earlier one and may change their pick.
  final bool simultaneousCasting;

  /// True when either component is in play, i.e. when casting is a performance
  /// at all. Drives [GameMode.sorcerer] and the press-and-hold CAST control.
  bool get componentsEnabled => vocalComponents || somaticComponents;

  /// True when players must take turns performing components (§5.2).
  ///
  /// Gated on [componentsEnabled], not merely the negation of
  /// [simultaneousCasting]: with no components to perform there is nothing to
  /// take turns at, so ordering would be pure latency.
  bool get sequentialCasting => componentsEnabled && !simultaneousCasting;

  /// The leyline seed word (design doc: "Community Seed Word") folded into
  /// every spell's wild-magic hash — see WildMagic.seedHex. Stored RAW as the
  /// player typed it; normalized at hash time so the settings UI can echo back
  /// their own spelling.
  ///
  /// Both sides must agree or the session aborts, which is exactly right: two
  /// players from different traditions must explicitly settle on one word
  /// before dueling, and a pre-wild-magic client fails agreement at the
  /// handshake rather than silently desyncing mid-match.
  ///
  /// Rotating this word is the ratified anti-grinder lever
  /// (WILD_MAGIC_PLAN.md §2.6): it invalidates every previously ground trigger
  /// at zero cost and forces a grinder to start over after the new word is
  /// announced. Recipe (formula) effects are deliberately unaffected, so a
  /// travelling player's spellbook stays valid under any tradition.
  final String communitySeed;

  // ── Agreement check ───────────────────────────────────────────────────────

  /// True when [other] has identical values on every negotiated field.
  bool matches(MatchConfig other) =>
      playerHp == other.playerHp &&
      gridRadius == other.gridRadius &&
      baseRange == other.baseRange &&
      rulesetVersion == other.rulesetVersion &&
      battleEngineVersion == other.battleEngineVersion &&
      tier == other.tier &&
      innateManaPool == other.innateManaPool &&
      manaGemPoolPerGem == other.manaGemPoolPerGem &&
      manaGemRegenPerGem == other.manaGemRegenPerGem &&
      winCondition == other.winCondition &&
      maxPlayers == other.maxPlayers &&
      experimentalMultiplayer == other.experimentalMultiplayer &&
      vocalComponents == other.vocalComponents &&
      somaticComponents == other.somaticComponents &&
      simultaneousCasting == other.simultaneousCasting &&
      // Compared NORMALIZED, so two duelists who typed "Rivendell!" and
      // "rivendell" agree exactly when their spells would hash identically.
      // A genuine mismatch here means they follow different traditions — the
      // UI should say so rather than reporting a protocol error.
      normalizeCommunitySeed(communitySeed) ==
          normalizeCommunitySeed(other.communitySeed);

  // ── Serialisation (wire + on-disk) ────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'playerHp': playerHp,
        'gridRadius': gridRadius,
        'baseRange': baseRange,
        'rulesetVersion': rulesetVersion,
        'battleEngineVersion': battleEngineVersion,
        'tier': tier,
        if (accoutrementLoadoutId != null) 'accoutrementLoadoutId': accoutrementLoadoutId,
        'innateManaPool': innateManaPool,
        'manaGemPoolPerGem': manaGemPoolPerGem,
        'manaGemRegenPerGem': manaGemRegenPerGem,
        'winCondition': winCondition.name,
        'maxPlayers': maxPlayers,
        'experimentalMultiplayer': experimentalMultiplayer,
        'vocalComponents': vocalComponents,
        'somaticComponents': somaticComponents,
        'simultaneousCasting': simultaneousCasting,
        'communitySeed': communitySeed,
      };

  static MatchConfig fromJson(Map<String, dynamic> j) => MatchConfig(
        playerHp: j['playerHp'] as int? ?? 24,
        gridRadius: j['gridRadius'] as int? ?? 4,
        baseRange: j['baseRange'] as int? ?? 3,
        rulesetVersion: j['rulesetVersion'] as int? ?? kRulesetVersion,
        // NOT defaulted to our own constant, unlike every other field here: a
        // peer that omits this predates the engine-version gate, and reading
        // its silence as "agrees with us" is precisely the failure this field
        // exists to prevent.
        battleEngineVersion:
            j['battleEngineVersion'] as int? ?? kUndeclaredBattleEngineVersion,
        tier: j['tier'] as int? ?? 24,
        accoutrementLoadoutId: j['accoutrementLoadoutId'] as String?,
        innateManaPool: j['innateManaPool'] as int? ?? 100,
        manaGemPoolPerGem: j['manaGemPoolPerGem'] as int? ?? 100,
        manaGemRegenPerGem: j['manaGemRegenPerGem'] as int? ?? 10,
        winCondition: WinCondition.values.firstWhere(
          (w) => w.name == (j['winCondition'] as String? ?? 'lastTeamStanding'),
          orElse: () => WinCondition.lastTeamStanding,
        ),
        maxPlayers: j['maxPlayers'] as int? ?? 2,
        experimentalMultiplayer: j['experimentalMultiplayer'] as bool? ?? false,
        // `sorcererMode` is the pre-split key (docs/SPELL_COMPONENTS_PLAN.md
        // §1). It meant exactly what `vocalComponents` means now, so an older
        // stored config still loads with the right component enabled rather
        // than silently reading as "no components at all".
        vocalComponents:
            j['vocalComponents'] as bool? ?? j['sorcererMode'] as bool? ?? false,
        somaticComponents: j['somaticComponents'] as bool? ?? false,
        simultaneousCasting: j['simultaneousCasting'] as bool? ?? false,
        // A pre-wild-magic peer omits this field entirely and lands on
        // 'universal'. If they are actually running an unpatched client, the
        // rest of the handshake (toCanonicalBytes' new suffix) diverges anyway
        // — see WILD_MAGIC_PLAN.md §11.
        communitySeed: j['communitySeed'] as String? ?? kDefaultCommunitySeed,
      );
}
