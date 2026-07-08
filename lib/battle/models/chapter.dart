// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter.dart — Chapter model and battle-selection seam.
//
// A Chapter is the player-selected subset of their spell library carried into
// one match. It has exactly [bookmarkCount] initial hand slots (SpellDraw
// fills the hand from the shuffled Chapter on match start).
//
// Library source is a stub: [fromChapterAsset] loads a ChapterAsset by id and
// resolves its entries against persisted SpellAssets. The resolution step
// (SpellAsset.loadAll + filter) is real; the UI for selecting a chapter before
// battle is out of scope this pass.
//
// See docs/BATTLE_PROTOCOL.md §5 (BookCommitment derives from Chapter spell
// commitmentHexes in sorted order).

import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';

class Chapter {
  const Chapter({required this.spells, required this.bookmarkCount});

  /// Spells in this chapter, in **canonical order** (sorted by spellId
  /// lexicographically). Both clients must agree on this order before the
  /// SpellDraw shuffle (BATTLE_PROTOCOL.md §4).
  final List<SpellAsset> spells;

  /// Hand size for this match (from MatchConfig.bookmarkCount).
  final int bookmarkCount;

  /// Commitment hex values in canonical order — the leaf set for the
  /// BookCommitment Merkle tree (BATTLE_PROTOCOL.md §5).
  List<String> get commitmentHexes => spells.map((s) => s.commitmentHex).toList();

  /// Load a Chapter from a persisted [ChapterAsset], resolving each entry
  /// against the device's persisted spell library.
  ///
  /// Spells not found on disk are silently dropped (e.g. deleted after the
  /// chapter was created). Returned list is sorted by spellId.
  ///
  /// [bookmarkCount] is taken from [MatchConfig.bookmarkCount] at call site.
  static Future<Chapter> fromChapterAsset(
    ChapterAsset asset,
    int bookmarkCount,
  ) async {
    final all = await SpellAsset.loadAll();
    final byId = {for (final s in all) s.id: s};

    final resolved = asset.entries
        .map((e) => byId[e.spellId])
        .whereType<SpellAsset>()
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return Chapter(spells: resolved, bookmarkCount: bookmarkCount);
  }

  /// Fixture chapter for tests and solo mode — populated with a caller-
  /// supplied spell list, already in canonical order.
  // TODO(battle): replace fixture usage with real library integration once
  //   the library UI and chapter-selection screen land.
  static Chapter fixture(List<SpellAsset> spells, int bookmarkCount) {
    final sorted = List<SpellAsset>.from(spells)
      ..sort((a, b) => a.id.compareTo(b.id));
    return Chapter(spells: sorted, bookmarkCount: bookmarkCount);
  }
}
