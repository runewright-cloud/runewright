// SPDX-License-Identifier: GPL-3.0-or-later
//
// statuesque_break.dart — what counts as "the wizard moved or acted" for
// Statuesque (wild magic, row 3 Earth).
//
// Design: *"All players return to full health and mana each turn; the effect is
// lost if they move or cast a spell."* Ratified in Slice 4 to the sharper rule:
//
//     Statuesque breaks the moment its holder takes ANY voluntary action other
//     than Pass. Nothing the engine does TO them breaks it.
//
// The point of the rule is stillness. A wizard who dashes, meditates, punches
// someone or burns an artifact has not stood still, and the previous reading —
// which broke only on a cast or a walked step — let a wizard meditate to full
// mana every round behind an unbreakable heal.
//
// ── Voluntary is a property of the CHANNEL, not of the outcome ────────────────
//
// A player's intent reaches the engine through five separate channels, and this
// file is the inventory of all five. That inventory is hand-maintained because
// each channel is a distinct commit-reveal with its own phase — there is no
// single "declaration" object to enumerate — but the one channel that can GROW
// silently, the [TurnAction] hierarchy, is checked exhaustively below and is a
// compile error to extend without deciding this question.
//
//   1. [TurnAction]           — the main-phase declaration. See
//                               [breaksStatuesque], the exhaustive switch.
//   2. Declared movement      — a walked path longer than its origin.
//                               (`resolveAvatarMovement`)
//   3. Free-move runs         — the Phase 5.5 / 6.5 barrier-burst windows.
//                               (`applyFreeMoveRun`)
//   4. Melee                  — a declared haymaker target. (`applyHaymaker`)
//   5. Artifact activation    — a declared Phase-0 activation.
//                               (`applyArtifactActivation`)
//   6. Move-phase Meditate    — `TurnInput.meditateInMove`, which is a separate
//                               declaration from [MeditateAction].
//
// Everything else is involuntary BY CONSTRUCTION and must never call the
// breaker: knockback, conveyor pushes, ice slides, Zephyr, terrain damage,
// forced free casts (Spontaneous Combustion, A8), Rippling Reflections'
// doubled application, wild magic firing on the wizard, their summons acting,
// counter charms self-triggering, and a delayed Mystery FIRING on a later
// round than the one it was declared on. A wizard is not moving just because
// the board moved them, and is not casting just because a promise they made
// three rounds ago came due.
//
// That last one is the only case where the type alone cannot tell you: a
// delayed fire re-enters resolution as a [SpellCastAction], identical in shape
// to a fresh cast. [SpellCastAction.isDelayedRealization] is the engine's own
// declaration/realization distinction, set at the single site that builds one,
// and it is what this file reads — never a turn-number comparison.

import 'turn_actions.dart';

/// Why a wizard's Statuesque ended. One value per voluntary channel in this
/// file's inventory, so the break sites are enumerable and a test can assert
/// that each one really does break the latch.
enum StatuesqueBreakCause {
  /// A main-phase [TurnAction] that [breaksStatuesque] classifies as voluntary.
  declaredAction,

  /// A declared movement path with at least one step actually taken.
  declaredMovement,

  /// A step taken in a Phase 5.5 / 6.5 free-move window.
  freeMoveRun,

  /// A declared melee target.
  melee,

  /// A declared Phase-0 artifact activation.
  artifactActivation,

  /// Move-phase Meditate (`TurnInput.meditateInMove`).
  moveePhaseMeditate,
}

/// Whether [action] is a voluntary declaration that ends Statuesque.
///
/// The rule is stated as its inverse — everything breaks it EXCEPT Pass — but
/// it is written as an exhaustive switch over the sealed [TurnAction]
/// hierarchy rather than as `action is! PassAction`, and that is deliberate:
///
///   * A wildcard default would silently swallow a future action type into
///     whichever answer the default happened to give. With no default clause,
///     adding a [TurnAction] subclass fails to compile until someone decides
///     this question for it. That is the whole safety property.
///   * Writing each case out also documents the answer per action, which
///     `is! PassAction` does not.
///
/// If you are adding an action type: the default answer is `true`. Only an
/// action that is genuinely the wizard doing NOTHING belongs with Pass.
bool breaksStatuesque(TurnAction action) => switch (action) {
      // Standing still is the whole point of the effect.
      PassAction() => false,

      // A cast breaks it even if it fizzles or is countered: the wizard still
      // chose to cast. But a DELAYED Mystery firing is the engine keeping an
      // earlier promise, not a fresh choice — the wizard's voluntary act was
      // the declaration, which broke the latch (or did not) on its own turn.
      // A spell declared before Statuesque armed must not break it on the way
      // out; see SpellCastAction.isDelayedRealization.
      SpellCastAction(:final isDelayedRealization) => !isDelayedRealization,

      // Declaring a Mystery — immediate or delayed — IS the fresh choice.
      MysterySpellCastAction() => true,

      // Dash is a declared movement multiplier — the wizard is running.
      DashAction() => true,

      // Meditate was the loophole that motivated the rule change: it is a
      // declared main-phase action, and a wizard channelling mana is not a
      // statue.
      MeditateAction() => true,
    };
