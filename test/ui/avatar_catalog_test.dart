// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_catalog_test.dart — invariants on the generated avatar catalog
// (docs/AVATAR_PICKER_PLAN.md §6.1). These pin the shape of
// avatar_catalog.g.dart itself, as a regression guard against the build
// script (scripts/build_avatar_pack.py) being rerun with a reordered
// SOURCE_SUBDIRS or a changed portrait-detection rule — either of which
// would silently move ids to different atlas cells or produce bad rects.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/avatars/avatar_sprites.dart';

void main() {
  group('avatar catalog', () {
    test('has 53 entries across all three non-empty categories', () {
      expect(kAvatarCatalog, hasLength(53));
      for (final category in AvatarCategory.values) {
        expect(
          kAvatarCatalog.where((a) => a.category == category),
          isNotEmpty,
          reason: category.name,
        );
      }
    });

    test('pre-existing ids are stable', () {
      // Regression guard for "someone reordered SOURCE_SUBDIRS" — these ids
      // must keep existing, regardless of where Monsters landed.
      const stableIds = [
        'fighter_f_01',
        'mage_f_01',
        'npc_f_amanda',
        'townfolk_old_m_002',
      ];
      final ids = kAvatarCatalog.map((a) => a.id).toSet();
      for (final id in stableIds) {
        expect(ids, contains(id));
      }
    });

    test('portrait rects stay inside the portrait atlas', () {
      final bounds = Rect.fromLTWH(
        0,
        0,
        kAvatarPortraitAtlasWidth.toDouble(),
        kAvatarPortraitAtlasHeight.toDouble(),
      );
      for (final art in kAvatarCatalog) {
        final rect = art.portraitRect;
        expect(bounds.contains(rect.topLeft), isTrue, reason: art.id);
        expect(
          bounds.contains(rect.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: art.id,
        );
      }
    });

    test('portrait rects are unique per entry', () {
      final rects = kAvatarCatalog.map((a) => a.portraitRect).toSet();
      expect(rects, hasLength(kAvatarCatalog.length));
    });

    test('_defaultFor still only picks from Heroes, for a fixed player set', () {
      // Pinned so adding monsters/NPCs to the catalog can never silently
      // reshuffle an existing wizard's default sprite.
      const expected = {
        'alice': 'ranger_m_01',
        'bob': 'healer_f_01',
        'solo-dummy': 'healer_m_01',
        'wizard-1': 'mage_f_01',
        'wizard-2': 'fighter_m_02',
      };
      const assignment = AvatarAssignment();
      for (final entry in expected.entries) {
        final art = assignment.artFor(entry.key);
        expect(art.category, AvatarCategory.heroes, reason: entry.key);
        expect(art.id, entry.value, reason: entry.key);
      }
    });
  });
}
