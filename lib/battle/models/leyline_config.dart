// SPDX-License-Identifier: GPL-3.0-or-later
//
// leyline_config.dart — LeylineConfig: the canonical, structured representation
// of the magical environment a match is fought under
// (docs/LEYLINE_SEED_PLAN.md §2, §15).
//
// ## Why a struct and not a string
//
// A leyline is displayed as prose — "Rivendell", "Rivendell 5" — but it is
// never *parsed* from prose. §2 is explicit: gameplay configuration must not be
// inferred from a human-readable seed string, because a legitimate community
// name may contain digits ("Route 66", "Level 9 Caverns") and the day a seed
// word ends in a number is the day two clients silently disagree about what
// grammar they are playing. The number in "Rivendell 5" is
// [formulaLength] = 5; the seed is "rivendell" and nothing else.
//
// Ordinary play is represented EXPLICITLY as the standard grammar
// ([ordinary] / [ordinaryDefault]) rather than as the absence of a number.
//
// ## Consensus criticality
//
// [leylineConfigHash] is destined for the Wild Magic v2 preimage
// (docs/WILD_MAGIC_PLAN_VNEXT.md §5) and, later, for the derivation of every
// rekeyed incantation / summon / Armor dictionary
// (LEYLINE_SEED_PLAN.md §4, §8, §9). Player-discovered Wild Magic combinations
// are meant to become culturally significant, so accidental rerolling through
// serialization drift is unacceptable (WILD_MAGIC_PLAN_VNEXT.md §16). Every
// byte of [leylineConfigHash]'s preimage is therefore pinned by fixed vectors
// in `test/battle/models/leyline_config_test.dart`, and changing ANY of:
//
//   * the domain tag, its length prefix, or the encoding version in it;
//   * field order, widths, or endianness;
//   * seed normalization;
//   * the canonicality rules below;
//
// is a consensus change requiring a version bump, not a refactor.
//
// ## Canonicality — one hash per behaviour
//
// The validation in [_checkCanonical] exists for one reason: two configs that
// behave identically must never produce two different hashes. Under ordinary
// magic, [formulaLength] and [noiseDensityPermille] have no meaning, so a
// config claiming `mutableMagic: false, formulaLength: 4` would be a second
// spelling of ordinary play with a different hash — a silently forked magical
// tradition. Such combinations are REJECTED at construction, at decode, and
// again inside [leylineConfigHash] itself, so no build mode and no code path
// can mint one.
//
// ## Scope (Slice 1 + Slice A)
//
// This file introduces the representation and its hash. It does NOT implement
// mutable-leyline behaviour: no codebook derivation, no rekeyed formula
// chunking, no noise semantics. A [LeylineConfig.mutable] may be *represented*
// and *hashed*, but **nothing reads [formulaLength] for behaviour** — see
// LEYLINE_SEED_PLAN.md §4-§9 and
// docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md.
//
// Slice A consolidated every incantation-segmentation site behind
// `engine/formula_segmentation.dart` and made [kOrdinaryFormulaLength] an alias
// of its constant, so the seam that will one day read [formulaLength] is a
// single argument. Passing it there is a consensus change requiring an
// engine-version bump (audit Slice D), never a refactor.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'package:rune_duel/engine/formula_segmentation.dart'
    show kIncantationFormulaLength;

// ── Community seed ────────────────────────────────────────────────────────────

/// The leyline seed word used when a player has chosen none, and the fallback
/// for any raw seed that normalizes to the empty string (`"---"`, `"日本"`).
const String kDefaultCommunitySeed = 'universal';

/// Design: *"case-insensitive, stripped of whitespace and punctuation"*.
///
/// THE ONE normalization implementation in the codebase. Three things depend on
/// agreeing exactly: [LeylineConfig.leylineConfigHash], [LeylineConfig]'s
/// equality (and therefore `MatchConfig.matches`' handshake agreement check),
/// and `WildMagic.normalizeCommunitySeed`, which delegates here. A second copy
/// of this regex anywhere is a consensus bug waiting to happen — two duelists
/// who typed `"Rivendell!"` and `"rivendell"` must agree at the handshake
/// exactly when their spells would hash identically.
///
/// Lives here rather than in `wild_magic_effect.dart` (which re-exports it, so
/// every existing importer is unaffected) because normalization is a property
/// of the leyline, not of the wild-magic effect table.
///
/// The empty-result fallback matters: a seed of `"日本"` or `"---"` normalizes
/// to the empty string, and an empty seed must not silently become a
/// *different* magical tradition from [kDefaultCommunitySeed].
String normalizeCommunitySeed(String raw) {
  final s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return s.isEmpty ? kDefaultCommunitySeed : s;
}

// ── Errors ────────────────────────────────────────────────────────────────────

/// A [LeylineConfig] that is semantically invalid or non-canonical.
///
/// Thrown rather than returned because there is no safe fallback: guessing what
/// a malformed leyline meant is exactly how two devices end up under different
/// magical traditions while both believing they agreed. A config frame that
/// throws aborts setup, which is the correct outcome.
class LeylineConfigException implements Exception {
  LeylineConfigException(this.reason);
  final String reason;
  @override
  String toString() => 'LeylineConfigException: $reason';
}

// ── Config ────────────────────────────────────────────────────────────────────

class LeylineConfig {
  /// The unchecked constructor. Private on purpose: every public path
  /// ([ordinary], [mutable], [fromJson]) validates first, so an invalid config
  /// cannot be constructed from outside this file even in release mode, where
  /// `assert` is stripped.
  const LeylineConfig._({
    required this.communitySeed,
    required this.mutableMagic,
    required this.formulaLength,
    required this.noiseDensityPermille,
    required this.lexiconVersion,
  });

  /// The canonical ordinary configuration under the default tradition.
  ///
  /// A `const` so it can be a default parameter value — `MatchConfig`'s
  /// constructor must stay const-constructible (`const MatchConfig()` is used
  /// in the lobby and across the suite).
  static const LeylineConfig ordinaryDefault = LeylineConfig._(
    communitySeed: kDefaultCommunitySeed,
    mutableMagic: false,
    formulaLength: kOrdinaryFormulaLength,
    noiseDensityPermille: 0,
    lexiconVersion: kCurrentLexiconVersion,
  );

  /// An ordinary leyline under [communitySeed] — the standard three-element
  /// grammar, no noise (LEYLINE_SEED_PLAN.md §3).
  ///
  /// [communitySeed] is stored RAW, exactly as the player typed it, so the
  /// settings UI can echo back their own spelling. It is normalized at hash
  /// time and at comparison time.
  factory LeylineConfig.ordinary(String communitySeed) => LeylineConfig._(
        communitySeed: communitySeed,
        mutableMagic: false,
        formulaLength: kOrdinaryFormulaLength,
        noiseDensityPermille: 0,
        lexiconVersion: kCurrentLexiconVersion,
      );

  /// A numbered / mutable leyline (LEYLINE_SEED_PLAN.md §1, §16).
  ///
  /// **Representation only in Slice 1.** Nothing derives a codebook, chunks
  /// trajectories at [formulaLength], or applies noise yet; this exists so the
  /// hash is stable before the behaviour lands, and so the two cannot be
  /// designed against different field sets.
  factory LeylineConfig.mutable({
    required String communitySeed,
    required int formulaLength,
    int noiseDensityPermille = kDefaultNoiseDensityPermille,
    int lexiconVersion = kCurrentLexiconVersion,
  }) {
    final c = LeylineConfig._(
      communitySeed: communitySeed,
      mutableMagic: true,
      formulaLength: formulaLength,
      noiseDensityPermille: noiseDensityPermille,
      lexiconVersion: lexiconVersion,
    );
    c._checkCanonical();
    return c;
  }

  // ── Bounds (LEYLINE_SEED_PLAN.md §16) ─────────────────────────────────────

  /// The ordinary grammar's formula length: `Affinity | EffectKey1 | EffectKey2`
  /// (§3). 4² = 16 tails map perfectly onto the sixteen base effects, which is
  /// why ordinary play has no noise.
  ///
  /// An ALIAS of the engine's [kIncantationFormulaLength], never a second
  /// spelling of 3: the config layer's canonicality rule and the segmentation
  /// it describes must not be able to disagree about what the ordinary grammar
  /// is. Everything that already referenced this name is unaffected.
  static const int kOrdinaryFormulaLength = kIncantationFormulaLength;

  /// Mutable leylines initially support lengths 4-6 only (§16). Larger lengths
  /// sharply reduce how many complete formulas an ordinary trajectory yields
  /// and interact badly with T limits; expand only after workshop testing.
  static const int kMinMutableFormulaLength = 4;
  static const int kMaxMutableFormulaLength = 6;

  /// §5's initial playtest rule: ~50% meaningful / 50% noise.
  static const int kDefaultNoiseDensityPermille = 500;

  /// The only dictionary generation this build can derive. A peer declaring a
  /// different lexicon is refused rather than guessed at — we cannot construct
  /// their codebook, so we cannot agree with them about what any formula means.
  static const int kCurrentLexiconVersion = 1;

  // ── Fields ────────────────────────────────────────────────────────────────

  /// The community seed word, RAW as the player typed it. Never contains the
  /// leyline number: "Rivendell 5" is `communitySeed: 'rivendell'` plus
  /// `formulaLength: 5`.
  final String communitySeed;

  /// False = ordinary grammar (§1 "Ordinary Leyline"). True = the grammar is
  /// rekeyed and formulas are [formulaLength] elements long.
  final bool mutableMagic;

  /// Elements per formula. Exactly [kOrdinaryFormulaLength] when
  /// [mutableMagic] is false.
  final int formulaLength;

  /// Proportion of syntactically complete formula keys that decode to noise,
  /// in parts per thousand. Exactly 0 when [mutableMagic] is false — ordinary
  /// magic's sixteen tails all mean something (§3).
  final int noiseDensityPermille;

  /// The dictionary-derivation generation (§15). Separate from the encoding
  /// version baked into [_domain]: this versions the *codebook*, that versions
  /// these *bytes*.
  final int lexiconVersion;

  /// [communitySeed] under [normalizeCommunitySeed] — what is hashed and what
  /// is compared.
  String get normalizedSeed => normalizeCommunitySeed(communitySeed);

  // ── Canonicality ──────────────────────────────────────────────────────────

  /// Throws [LeylineConfigException] unless this is the one canonical
  /// representation of its own behaviour. See this file's header.
  void _checkCanonical() {
    if (lexiconVersion != kCurrentLexiconVersion) {
      throw LeylineConfigException(
        'lexiconVersion $lexiconVersion is not derivable by this build '
        '(expected $kCurrentLexiconVersion)',
      );
    }
    if (mutableMagic) {
      if (formulaLength < kMinMutableFormulaLength ||
          formulaLength > kMaxMutableFormulaLength) {
        throw LeylineConfigException(
          'mutable formulaLength $formulaLength outside the supported range '
          '$kMinMutableFormulaLength..$kMaxMutableFormulaLength',
        );
      }
      // 1000‰ would be all-noise: a leyline in which no formula means
      // anything, i.e. no magic at all. 0‰ is legal (a pure permutation with
      // no noise) even though §5's initial rule is 500.
      if (noiseDensityPermille < 0 || noiseDensityPermille > 999) {
        throw LeylineConfigException(
          'noiseDensityPermille $noiseDensityPermille outside 0..999',
        );
      }
    } else {
      // The canonicality rule that actually matters: under ordinary magic
      // these two fields have no behaviour, so allowing any value but the
      // canonical one would mint a second hash for identical play.
      if (formulaLength != kOrdinaryFormulaLength) {
        throw LeylineConfigException(
          'ordinary leyline must have formulaLength $kOrdinaryFormulaLength, '
          'got $formulaLength',
        );
      }
      if (noiseDensityPermille != 0) {
        throw LeylineConfigException(
          'ordinary leyline must have noiseDensityPermille 0, '
          'got $noiseDensityPermille',
        );
      }
    }
  }

  // ── The hash ──────────────────────────────────────────────────────────────

  /// The domain tag. `v1` versions THIS BYTE LAYOUT, not the codebook
  /// generation ([lexiconVersion]) — the two move independently, and conflating
  /// them would mean a new dictionary silently rewrote every old hash.
  static const String _domain = 'Runewright/Leyline/v1/Config';

  /// The canonical 64-char lowercase hex configuration hash (no `0x` prefix).
  ///
  /// ```
  /// preimage = uint8(len(domain)) ‖ ascii(domain)      // 1 + 28 bytes
  ///          ‖ uint8(lexiconVersion)                   // 1
  ///          ‖ uint8(mutableMagic ? 1 : 0)             // 1
  ///          ‖ uint8(formulaLength)                    // 1
  ///          ‖ uint16be(noiseDensityPermille)          // 2
  ///          ‖ uint16be(utf8ByteLength(normalizedSeed))// 2
  ///          ‖ utf8(normalizedSeed)                    // variable
  /// leylineConfigHash = lowercase hex of SHA-256(preimage)
  /// ```
  ///
  /// Four encoding decisions you must not quietly change:
  ///
  ///   1. **Every field is fixed-width or length-delimited**, including the
  ///      domain tag and the seed. The old wild-magic preimage relied on "the
  ///      seed goes last so it needs no prefix"; that trick does not survive a
  ///      struct with fields after it, and a length prefix is what stops
  ///      `("ab", 1)` and `("a", …)` from ever colliding.
  ///   2. **The seed is hashed NORMALIZED.** Two duelists who typed
  ///      `"Rivendell!"` and `"rivendell"` must produce one tradition, and
  ///      `MatchConfig.matches` compares the same normalized form.
  ///   3. **Seed length is the UTF-8 BYTE length**, not the Dart `String`
  ///      length (UTF-16 code units). They differ for any non-ASCII seed. In
  ///      practice normalization strips to `[a-z0-9]`, so the two always agree
  ///      today — the byte length is specified anyway so that relaxing
  ///      normalization later cannot silently reroll every hash.
  ///   4. **Ordinary and mutable configs sharing a seed hash differently**,
  ///      and so do two mutable configs differing only in formula length or
  ///      noise density. `rivendell`, `rivendell 4` and `rivendell 5` are three
  ///      distinct magical environments (LEYLINE_SEED_PLAN.md §10).
  ///
  /// Validates before hashing, so a non-canonical config can never be assigned
  /// a hash — not in release mode, not through any construction path.
  String get leylineConfigHash {
    _checkCanonical();

    final domain = utf8.encode(_domain);
    final seed = utf8.encode(normalizedSeed);
    assert(domain.length <= 0xFF, 'domain tag must fit a uint8 length prefix');
    if (seed.length > 0xFFFF) {
      throw LeylineConfigException('normalized seed exceeds 65535 bytes');
    }

    final out = BytesBuilder(copy: false)
      ..addByte(domain.length)
      ..add(domain)
      ..addByte(lexiconVersion)
      ..addByte(mutableMagic ? 1 : 0)
      ..addByte(formulaLength)
      ..addByte((noiseDensityPermille >> 8) & 0xFF)
      ..addByte(noiseDensityPermille & 0xFF)
      ..addByte((seed.length >> 8) & 0xFF)
      ..addByte(seed.length & 0xFF)
      ..add(seed);

    return _toHex(sha256.convert(out.takeBytes()).bytes);
  }

  /// The domain tag of the TRADITION hash. Versions that byte layout, exactly as
  /// [_domain] versions the configuration hash's; the two move independently.
  static const String _traditionDomain = 'Runewright/Leyline/v1/Tradition';

  /// The canonical 64-char lowercase hex hash of this leyline's **tradition** —
  /// who its magic belongs to, with the incantation grammar's own dials left
  /// out (audit R-8).
  ///
  /// ```
  /// preimage = uint8(len(domain)) ‖ ascii(domain)      // 1 + 31 bytes
  ///          ‖ uint8(lexiconVersion)                   // 1
  ///          ‖ uint8(mutableMagic ? 1 : 0)             // 1
  ///          ‖ uint16be(utf8ByteLength(normalizedSeed))// 2
  ///          ‖ utf8(normalizedSeed)                    // variable
  /// leylineTraditionHash = lowercase hex of SHA-256(preimage)
  /// ```
  ///
  /// [leylineConfigHash]'s layout, minus [formulaLength] and
  /// [noiseDensityPermille] — and the omission is the whole point, not an
  /// economy. Those two fields are the Incantation grammar's controls: how many
  /// elements make one spoken formula, and what share of formula tails a
  /// leyline leaves inert. The Summon and Armor pattern languages are four
  /// elements wide under every grammar (R-8 keeps them there), so keying their
  /// dictionaries on the full config would mean a host who moved from
  /// `rivendell 4` to `rivendell 6` silently rerolled what every creature and
  /// every armor in the match could do. `Rivendell 4`, `Rivendell 5` and
  /// `Rivendell 6` are three incantation grammars and ONE tradition of
  /// creatures and armor.
  ///
  /// [mutableMagic] is bound even though only mutable leylines derive a
  /// dictionary: an ordinary config has no business producing a score stream at
  /// all, and binding the flag means it could not share one with a mutable
  /// leyline of the same name even if some future caller tried.
  ///
  /// Validates before hashing, for the same reason [leylineConfigHash] does.
  String get leylineTraditionHash {
    _checkCanonical();

    final domain = utf8.encode(_traditionDomain);
    final seed = utf8.encode(normalizedSeed);
    assert(domain.length <= 0xFF, 'domain tag must fit a uint8 length prefix');
    if (seed.length > 0xFFFF) {
      throw LeylineConfigException('normalized seed exceeds 65535 bytes');
    }

    final out = BytesBuilder(copy: false)
      ..addByte(domain.length)
      ..add(domain)
      ..addByte(lexiconVersion)
      ..addByte(mutableMagic ? 1 : 0)
      ..addByte((seed.length >> 8) & 0xFF)
      ..addByte(seed.length & 0xFF)
      ..add(seed);

    return _toHex(sha256.convert(out.takeBytes()).bytes);
  }

  static String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  // ── Display ───────────────────────────────────────────────────────────────

  /// The player-facing name: `Rivendell`, or `Rivendell 5` for a mutable
  /// leyline. Presentation only — never parsed back (see this file's header).
  ///
  /// Built from the RAW seed so a player's own spelling survives to the screen.
  String get displayName {
    final base = communitySeed.trim().isEmpty ? kDefaultCommunitySeed : communitySeed.trim();
    return mutableMagic ? '$base $formulaLength' : base;
  }

  // ── Equality ──────────────────────────────────────────────────────────────

  /// Compares the NORMALIZED seed, so two spellings of one tradition are one
  /// config. `MatchConfig.matches` delegates here, which is what keeps the
  /// handshake's notion of agreement identical to the hash's.
  @override
  bool operator ==(Object other) =>
      other is LeylineConfig &&
      normalizedSeed == other.normalizedSeed &&
      mutableMagic == other.mutableMagic &&
      formulaLength == other.formulaLength &&
      noiseDensityPermille == other.noiseDensityPermille &&
      lexiconVersion == other.lexiconVersion;

  @override
  int get hashCode => Object.hash(normalizedSeed, mutableMagic, formulaLength,
      noiseDensityPermille, lexiconVersion);

  @override
  String toString() => 'LeylineConfig($displayName, '
      'seed: $normalizedSeed, mutable: $mutableMagic, '
      'formulaLength: $formulaLength, noise: $noiseDensityPermille‰, '
      'lexicon: $lexiconVersion)';

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'communitySeed': communitySeed,
        'mutableMagic': mutableMagic,
        'formulaLength': formulaLength,
        'noiseDensityPermille': noiseDensityPermille,
        'lexiconVersion': lexiconVersion,
      };

  /// Decodes a structured leyline object. Throws [LeylineConfigException] on
  /// anything non-canonical — see this file's header for why guessing is worse
  /// than aborting.
  factory LeylineConfig.fromJson(Map<String, dynamic> j) {
    final c = LeylineConfig._(
      communitySeed: j['communitySeed'] as String? ?? kDefaultCommunitySeed,
      mutableMagic: j['mutableMagic'] as bool? ?? false,
      // Defaulted to the ORDINARY values, not to the mutable ones: a truncated
      // object is read as ordinary play, which is the only reading that cannot
      // invent a grammar the sender never asked for.
      formulaLength: j['formulaLength'] as int? ?? kOrdinaryFormulaLength,
      noiseDensityPermille: j['noiseDensityPermille'] as int? ?? 0,
      lexiconVersion: j['lexiconVersion'] as int? ?? kCurrentLexiconVersion,
    );
    c._checkCanonical();
    return c;
  }

  /// Decodes the leyline from a `MatchConfig` JSON body, which may carry the
  /// structured `leyline` object, the legacy flat `communitySeed` string, or
  /// both.
  ///
  /// Both is the normal case: [MatchConfig.toJson] emits the flat key
  /// alongside the structured one so a build that predates this type still
  /// finds the seed where it expects it and still agrees at the handshake. That
  /// duplication is what makes this change protocol-compatible, and it is also
  /// a place two values can drift — so when both are present their NORMALIZED
  /// seeds must agree, and a disagreement is refused rather than resolved by
  /// preferring one. There is no honest way to pick: a peer whose two copies
  /// disagree is either buggy or probing.
  ///
  /// A body carrying neither key predates the leyline entirely and reads as
  /// [ordinaryDefault].
  factory LeylineConfig.fromMatchConfigJson(Map<String, dynamic> j) {
    final structured = j['leyline'];
    final legacy = j['communitySeed'] as String?;

    if (structured == null) {
      return legacy == null
          ? ordinaryDefault
          : LeylineConfig.ordinary(legacy);
    }
    if (structured is! Map) {
      throw LeylineConfigException(
        'leyline must be an object, got ${structured.runtimeType}',
      );
    }
    final config = LeylineConfig.fromJson(
      Map<String, dynamic>.from(structured),
    );
    if (legacy != null &&
        normalizeCommunitySeed(legacy) != config.normalizedSeed) {
      throw LeylineConfigException(
        'config declares communitySeed "$legacy" '
        '(normalized "${normalizeCommunitySeed(legacy)}") but its leyline '
        'object declares "${config.normalizedSeed}" — refusing to guess which '
        'tradition was meant',
      );
    }
    return config;
  }
}
