// SPDX-License-Identifier: GPL-3.0-or-later
//
// trade_offer.dart — what one side of a Commune/Trade session is offering.
//
// Offer-eligibility (see [eligibleOfferSpells]): only natively-owned spells
// may be offered. A spell held via a loan grant or a transfer grant (foreign
// ownerPubkeyHex) is never offerable. This single filter is what enforces
// both halves of the design's asymmetry (docs/COMMUNE_TRADE_PLAN.md §2):
// a loaned spell cannot be re-loaned or re-transferred by the loanee, and a
// transferred spell cannot be re-offered until the recipient re-inscribes it
// under their own key (at which point it genuinely is native, and eligible).

import 'dart:typed_data';

import '../identity/identity.dart';
import '../spells/spell_asset.dart';

enum TradeMode { loan, transfer }

class TradeItem {
  const TradeItem({
    required this.spellId,
    required this.commitmentHex,
    required this.spellName,
    required this.mode,
    this.loanDays,
    this.manaCost = 0,
    this.formula = const [],
    this.t = 0,
    this.tier = 12,
    this.segmentCount = -1,
    this.dotCount = -1,
    this.supremeTags = const [],
    this.isSummon = false,
    this.summonPersonality = 'aggressive',
  }) : assert(
          (mode == TradeMode.loan) == (loanDays != null),
          'loanDays must be set iff mode is TradeMode.loan',
        );

  /// Local [SpellAsset.id] being offered.
  final String spellId;
  final String commitmentHex;
  final String spellName;
  final TradeMode mode;

  /// Required and >= 1 iff [mode] is [TradeMode.loan]; null for transfers
  /// (perpetual).
  final int? loanDays;

  // The fields below are the same "non-grid" metadata a loan grant already
  // reveals (SpellAsset.withGridWithheld only redacts initialGrid) --
  // carrying them in the advisory preview too, before either side confirms,
  // is not a new privacy exposure. They exist so [previewSpellAsset] can
  // render a real, commitment-derived card at review time: a same-name
  // reskin would still show a visibly different shield, since that art is
  // generated from [commitmentHex], not [spellName] (docs/COMMUNE_TRADE_PLAN.md).
  final int manaCost;
  final List<String> formula;
  final int t;
  final int tier;
  final int segmentCount;
  final int dotCount;
  final List<String> supremeTags;
  final bool isSummon;
  final String summonPersonality;

  /// Builds the [TradeItem] describing [spell] for an offer -- carries
  /// enough of [spell]'s metadata (see the field-group comment above) for
  /// the receiving side to render a real preview card via
  /// [previewSpellAsset], not just a name.
  factory TradeItem.fromSpell(SpellAsset spell, {required TradeMode mode, int? loanDays}) =>
      TradeItem(
        spellId: spell.id,
        commitmentHex: spell.commitmentHex,
        spellName: spell.name,
        mode: mode,
        loanDays: loanDays,
        manaCost: spell.manaCost,
        formula: spell.formula,
        t: spell.t,
        tier: spell.tier,
        segmentCount: spell.segmentCount,
        dotCount: spell.dotCount,
        supremeTags: spell.supremeTags,
        isSummon: spell.isSummon,
        summonPersonality: spell.summonPersonality,
      );

  Map<String, dynamic> toJson() => {
        'spellId': spellId,
        'commitmentHex': commitmentHex,
        'spellName': spellName,
        'mode': mode.name,
        if (loanDays != null) 'loanDays': loanDays,
        'manaCost': manaCost,
        'formula': formula,
        't': t,
        'tier': tier,
        'segmentCount': segmentCount,
        'dotCount': dotCount,
        'supremeTags': supremeTags,
        'isSummon': isSummon,
        'summonPersonality': summonPersonality,
      };

  static TradeItem fromJson(Map<String, dynamic> json) => TradeItem(
        spellId: json['spellId'] as String,
        commitmentHex: json['commitmentHex'] as String,
        spellName: json['spellName'] as String,
        mode: TradeMode.values.byName(json['mode'] as String),
        loanDays: json['loanDays'] as int?,
        manaCost: json['manaCost'] as int? ?? 0,
        formula: (json['formula'] as List<dynamic>? ?? []).cast<String>(),
        t: json['t'] as int? ?? 0,
        tier: json['tier'] as int? ?? 12,
        segmentCount: json['segmentCount'] as int? ?? -1,
        dotCount: json['dotCount'] as int? ?? -1,
        supremeTags: (json['supremeTags'] as List<dynamic>? ?? []).cast<String>(),
        isSummon: json['isSummon'] as bool? ?? false,
        summonPersonality: json['summonPersonality'] as String? ?? 'aggressive',
      );

  /// A synthetic, grid-withheld [SpellAsset] carrying only this item's
  /// preview metadata -- lets [showSpellCardFullscreen] render the real
  /// commitment-derived card (shield, element symbols, rules text) before
  /// either side confirms, rather than the player trusting [spellName]
  /// alone. Never carries [SpellAsset.initialGrid] or
  /// [SpellAsset.proofBytes] -- those don't exist locally until the real
  /// grant arrives post-confirm (`exchangeGrantsAndSave`), and this preview
  /// must never claim to have them (`gridWithheld: true`).
  SpellAsset previewSpellAsset() => SpellAsset(
        id: 'preview-$spellId',
        createdAt: DateTime.now(),
        tier: tier,
        t: t,
        ownerPubkeyHex: '',
        manaCost: manaCost,
        segmentCount: segmentCount,
        dotCount: dotCount,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: spellName,
        commitmentHex: commitmentHex,
        spellHashHex: '',
        formula: formula,
        supremeTags: supremeTags,
        isSummon: isSummon,
        summonPersonality: summonPersonality,
        gridWithheld: true,
      );
}

class TradeOffer {
  const TradeOffer({this.items = const []});

  final List<TradeItem> items;

  Map<String, dynamic> toJson() => {'items': items.map((i) => i.toJson()).toList()};

  static TradeOffer fromJson(Map<String, dynamic> json) => TradeOffer(
        items: (json['items'] as List<dynamic>? ?? [])
            .map((i) => TradeItem.fromJson(i as Map<String, dynamic>))
            .toList(),
      );
}

/// Spells [identity] may legally offer into a trade: natively-owned only.
/// A spell held via a loan or transfer grant (foreign ownerPubkeyHex) is
/// excluded -- see file header. Callers should filter the picker with this
/// AND re-check membership just before signing (state can change between
/// opening the picker and confirming, e.g. a loan expiring mid-session).
List<SpellAsset> eligibleOfferSpells(List<SpellAsset> allSpells, String myOwnerPubkeyHex) {
  BigInt parseHex(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  final mine = parseHex(myOwnerPubkeyHex);
  return allSpells.where((s) => parseHex(s.ownerPubkeyHex) == mine).toList();
}

/// Convenience overload taking an [Identity] instead of a pre-resolved hex
/// string.
Future<List<SpellAsset>> eligibleOfferSpellsFor(List<SpellAsset> allSpells, Identity identity) async {
  final myOwnerPubkeyHex = await identity.ownerPubkeyHex();
  return eligibleOfferSpells(allSpells, myOwnerPubkeyHex);
}
