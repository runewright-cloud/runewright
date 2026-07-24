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

  Map<String, dynamic> toJson() => {
        'spellId': spellId,
        'commitmentHex': commitmentHex,
        'spellName': spellName,
        'mode': mode.name,
        if (loanDays != null) 'loanDays': loanDays,
      };

  static TradeItem fromJson(Map<String, dynamic> json) => TradeItem(
        spellId: json['spellId'] as String,
        commitmentHex: json['commitmentHex'] as String,
        spellName: json['spellName'] as String,
        mode: TradeMode.values.byName(json['mode'] as String),
        loanDays: json['loanDays'] as int?,
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
