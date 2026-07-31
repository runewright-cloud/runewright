// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_sprites.dart — the seam between a wizard on the battlefield and the
// artwork that represents them.
//
// PURELY COSMETIC. Nothing here is consensus-visible: no engine code reads an
// avatar id, none of it is hashed into state, and a device with a missing or
// corrupt atlas still plays a byte-identical match — BattlefieldPainter simply
// falls back to the placeholder disc token it drew before this file existed.
//
// ── What this is for ─────────────────────────────────────────────────────────
//
// Three things arrive in sequence, and this file is shaped so the later two
// cost no rework:
//
//   1. (now) Every wizard gets *some* character sprite instead of a coloured
//      circle, assigned deterministically from their playerId.
//   2. (later) The player picks their avatar from the catalog. That is a
//      picker UI over [kAvatarCatalog] plus persistence of the chosen id, and
//      it enters through [AvatarAssignment.explicit] — see its doc comment for
//      the one thing that work must not forget.
//   3. (later still) Real walk/idle animation. The atlas already carries all
//      12 poses per character (4 facings x 3 frames), and the movement
//      animation already knows which way a wizard is walking, so this is a
//      matter of advancing [AvatarPose] on a timer rather than re-cutting art.
//
// ── Art ──────────────────────────────────────────────────────────────────────
//
// Sprites are RPG Maker 2000 charsets by Svetlana Kushnariova, CC BY 3.0 —
// attribution is REQUIRED, see assets/art_pack/avatars/ATTRIBUTION.md. The
// atlas and the generated catalog both come from scripts/build_avatar_pack.py.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;

part 'avatar_catalog.g.dart';

// ── Frame geometry ───────────────────────────────────────────────────────────

/// One pose is 24x32 px; one character's block is 3 poses across by 4 facings
/// down. Measured from the source sheets — see the build script's docstring.
const int kAvatarFrameWidth = 24;
const int kAvatarFrameHeight = 32;
const int kAvatarFrameCols = 3;
const int kAvatarFrameRows = 4;
const int kAvatarBlockWidth = kAvatarFrameWidth * kAvatarFrameCols; // 72
const int kAvatarBlockHeight = kAvatarFrameHeight * kAvatarFrameRows; // 128

/// Which way a sprite is facing. The index is the atlas row, in RPG Maker 2000
/// order (**not** RPG Maker XP's) — verified against the art when the pack was
/// built, not assumed.
enum AvatarFacing {
  up(0),
  right(1),
  down(2),
  left(3);

  const AvatarFacing(this.row);
  final int row;
}

/// Which walk frame. Column 1 is the standing pose; 0 and 2 are the two steps
/// of the walk cycle. Nothing animates them yet (see the header, item 3) — the
/// battlefield draws [stand] — but the frames are in the atlas ready for it.
enum AvatarPose {
  stepA(0),
  stand(1),
  stepB(2);

  const AvatarPose(this.col);
  final int col;
}

/// Which source directory a character came from. Only a grouping hint for the
/// future picker UI; the battlefield does not care.
enum AvatarCategory { heroes, npc }

/// One character in the shipped pack. Generated into [kAvatarCatalog] —
/// see avatar_catalog.g.dart.
class AvatarArt {
  const AvatarArt({
    required this.id,
    required this.name,
    required this.category,
    required this.atlasCol,
    required this.atlasRow,
  });

  /// Stable identifier, and the value a player's avatar choice is persisted
  /// (and, eventually, transmitted) as. Regenerating the pack must never
  /// change one — see avatar_catalog.g.dart.
  final String id;

  /// Human-readable label for the picker. Derived from the source filename, so
  /// it is serviceable rather than evocative; renaming these for flavour is a
  /// safe change, since only the [id] is load-bearing.
  final String name;

  final AvatarCategory category;

  /// Position of this character's 72x128 block within the atlas.
  final int atlasCol;
  final int atlasRow;

  /// The atlas rect for one pose of this character.
  Rect frameRect(AvatarFacing facing, AvatarPose pose) => Rect.fromLTWH(
    (atlasCol * kAvatarBlockWidth + pose.col * kAvatarFrameWidth).toDouble(),
    (atlasRow * kAvatarBlockHeight + facing.row * kAvatarFrameHeight).toDouble(),
    kAvatarFrameWidth.toDouble(),
    kAvatarFrameHeight.toDouble(),
  );
}

/// Catalog lookup by [AvatarArt.id]. Null for an unknown id — callers treat
/// that as "fall back to the default", never as an error, so a save file that
/// names an avatar a later pack dropped still opens.
AvatarArt? avatarArtById(String id) {
  for (final art in kAvatarCatalog) {
    if (art.id == id) return art;
  }
  return null;
}

/// The catalog entries a player may pick from. Everything shipped, currently —
/// this exists so the picker has one place to narrow if some sprites are ever
/// reserved for NPCs.
List<AvatarArt> get selectableAvatars => List.unmodifiable(kAvatarCatalog);

// ── Assignment ───────────────────────────────────────────────────────────────

/// Resolves "which sprite does this wizard wear".
///
/// Today every wizard falls through to [_defaultFor], a pure function of their
/// playerId — which matters more than it looks: both devices in a LAN duel run
/// it over the same ids and independently arrive at the same sprites, with no
/// wire format and no agreement protocol.
///
/// **When avatar choice is implemented, that property is what has to be kept.**
/// A locally-stored choice is invisible to the peer, so a chosen avatar has to
/// travel in the handshake (alongside the identity/spellbook exchange) and be
/// installed here via [explicit] on BOTH devices. A choice applied only to the
/// local map is not a bug that fails loudly — each player just sees a different
/// board than the other, which is exactly the class of seam bug CLAUDE.md's
/// handoff notes warn about.
class AvatarAssignment {
  const AvatarAssignment({this.explicit = const {}});

  /// playerId → chosen [AvatarArt.id]. Empty today; the future picker fills it
  /// (and the future handshake fills the peer's entries). Ids not in the
  /// catalog fall back to the default, so a stale choice degrades quietly.
  final Map<String, String> explicit;

  AvatarArt artFor(String playerId) {
    final chosen = explicit[playerId];
    if (chosen != null) {
      final art = avatarArtById(chosen);
      if (art != null) return art;
    }
    return _defaultFor(playerId);
  }

  /// Deterministic per-id pick from the Heroes, so two wizards in a duel are
  /// very unlikely to wear the same face and both devices agree on who wears
  /// what. FNV-1a rather than [Object.hashCode]: Dart string hashes are not
  /// guaranteed stable across runs or platforms, and "my wizard looked
  /// different last session" is a bug report nobody would enjoy chasing.
  static AvatarArt _defaultFor(String playerId) {
    final pool = kAvatarCatalog
        .where((a) => a.category == AvatarCategory.heroes)
        .toList();
    final candidates = pool.isEmpty ? kAvatarCatalog : pool;
    var hash = 0x811c9dc5;
    for (final unit in playerId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return candidates[hash % candidates.length];
  }
}

// ── Atlas loading ────────────────────────────────────────────────────────────

/// Loads and caches the shipped avatar atlas. One decode per process; every
/// sprite is a source rect into it, so a whole board of wizards is one texture
/// bind. Same shape as [SceneryAtlas] in lib/ui/scenery/scenery_painter.dart.
class AvatarAtlas {
  AvatarAtlas._();

  static const String assetPath = 'assets/art_pack/avatars/avatar_atlas.png';

  static ui.Image? _image;
  static Future<ui.Image>? _pending;

  /// The decoded atlas, or null if [load] has not completed (or failed).
  /// Painters treat null as "draw the placeholder token instead".
  static ui.Image? get imageOrNull => _image;

  static Future<ui.Image> load() {
    final cached = _image;
    if (cached != null) return Future.value(cached);
    return _pending ??= _decode();
  }

  static Future<ui.Image> _decode() async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    _image = frame.image;
    _pending = null;
    return frame.image;
  }

  /// Test hook — drops the cached decode so a fake atlas can be installed.
  @visibleForTesting
  static void resetForTest() {
    _image = null;
    _pending = null;
  }
}

// ── Facing ───────────────────────────────────────────────────────────────────

/// The facing that best matches an on-screen movement vector.
///
/// Taken from *pixel* delta rather than axial delta on purpose: the hex grid
/// has six directions and the sprite sheet has four, so the mapping depends on
/// how the grid is laid out on screen. Reading it off the rendered offsets
/// keeps this correct if the grid geometry ever changes, and keeps this file
/// from having to know about flat-top axial coordinates at all.
///
/// The 0.8 weight biases ties toward left/right: on a flat-top grid the four
/// diagonal steps have |dx| ≈ 1.5·hexSize and |dy| ≈ 0.87·hexSize, and a
/// diagonal step reads far better as a side-step than as walking up or down.
/// A zero vector (no movement) keeps [fallback].
AvatarFacing facingForDelta(Offset delta, {AvatarFacing fallback = AvatarFacing.down}) {
  if (delta.dx == 0 && delta.dy == 0) return fallback;
  if (delta.dx.abs() * 0.8 >= delta.dy.abs()) {
    return delta.dx >= 0 ? AvatarFacing.right : AvatarFacing.left;
  }
  return delta.dy >= 0 ? AvatarFacing.down : AvatarFacing.up;
}
