// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_events.dart — UI-only playback records emitted by resolution.
//
// These classes used to live in `turn_loop.dart`. They moved here when the
// Summons-phase AI moved behind the deterministic seam: the AI *emits* them,
// so `deterministic_resolution.dart` needs the types, and having the
// deterministic core import the orchestrator would point the seam's dependency
// the wrong way round. `turn_loop.dart` re-exports this file, so every existing
// `import '.../turn_loop.dart'` that names these types keeps working unchanged.
//
// Everything here is playback bookkeeping: the state transition has already
// happened by the time an event is emitted, and nothing reads them back.

import 'package:rune_duel/engine/hex_grid.dart';

import '../models/effect_descriptor.dart' show SpellAffinity;

/// One summon's movement this turn — the [AvatarMoveEvent] of the Summons
/// phase, and UI-only in exactly the same way: a creature that crossed three
/// tiles should be seen crossing them, not blink to its destination. Carries
/// no gameplay effect; [TurnLoop] never reads these back. See
/// [TurnLoop.lastMinionMoveEvents].
class MinionMoveEvent {
  const MinionMoveEvent({
    required this.minionId,
    required this.path,
    this.lungeTile,
  });

  final String minionId;

  /// Every tile actually visited, in order, starting with the pre-move tile —
  /// including free displacement picked up along the way (conveyor pushes), so
  /// the token follows the real route. Length 1 means "did not move", which is
  /// still worth emitting when [lungeTile] is set.
  final List<HexCoord> path;

  /// The enemy tile a melee (range 0) creature stepped onto to land its blow.
  /// It cannot stay there — bodies are exclusive — so the UI reaches the token
  /// onto that tile and shoves it back to [path]'s last tile, which is the
  /// whole visible form the attack takes. Null for a creature with reach, and
  /// for one that had no movement left to strike with.
  final HexCoord? lungeTile;
}

/// One ordinary attack that landed this turn — a wizard's haymaker or a
/// creature's strike — so the UI can show the blow itself rather than only its
/// consequences. UI-only bookkeeping, exactly like [MinionMoveEvent]: the
/// damage has already been applied by the time this is emitted and [TurnLoop]
/// never reads these back.
///
/// [range] is the attacker's *effective* attack range at the moment it struck
/// (a wizard haymaker is always 1), which is what decides the form the attack
/// takes on screen: reach 0/1 is a blow at arm's length, reach 2+ is something
/// thrown across the intervening tiles. [affinity] is the attacker's element,
/// null for a wizard — wizards punch, they don't have an elemental flavour.
class AttackEvent {
  const AttackEvent({
    required this.from,
    required this.to,
    required this.range,
    this.affinity,
  });

  /// The attacker's tile at the moment of the blow (post-movement).
  final HexCoord from;

  /// The tile struck. For a melee creature this is the tile it lunges onto —
  /// the same tile as [MinionMoveEvent.lungeTile] — so the two animations line
  /// up on the same target.
  final HexCoord to;

  final int range;

  final SpellAffinity? affinity;

  /// Whether this blow was struck within arm's reach. Reach 1 counts: the
  /// attacker is standing next to its target either way, and only a creature
  /// that can strike from 2+ tiles away has anything to throw.
  bool get isMelee => range <= 1;
}
