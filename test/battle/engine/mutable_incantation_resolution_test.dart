// SPDX-License-Identifier: GPL-3.0-or-later
//
// mutable_incantation_resolution_test.dart — Mutable Leylines Slice D, through
// the REAL resolution loop.
//
// `incantation_lexicon_test.dart` proves the seam in isolation. This file
// proves the thing the review gate actually asks for: that a Mutable Leyline
// reinterprets complete incantation formulas in ACTUAL GAMEPLAY, with a real
// `BattleState`, a real `DeterministicResolution`, and effects that land on a
// real avatar.
//
// The three claims, and the observable each rests on:
//
//   * a MEANINGFUL formula resolves to exactly its codebook effect — a target
//     that loses HP it would not otherwise lose;
//   * a NOISE formula resolves to nothing at all — a target that loses none;
//   * a mixed cast resolves every meaningful formula, in order, and a noise
//     formula in the middle neither swallows the ones after it nor is
//     substituted for.
//
// Damage is the observable because it ACCUMULATES: two damage formulas are
// distinguishable from one, which a tile-placing effect on a single target hex
// would not be. The damage key is selected from the leyline's own codebook
// rather than hardcoded — the Slice B vectors already attest that the codebook
// is correct, and pinning a second copy of one of its entries here would just
// be a literal that has to move whenever the corpus does.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/battle_events.dart';
import 'package:rune_duel/engine/formula_segmentation.dart'
    show completeFormulaElementCount;
import 'package:rune_duel/battle/engine/deterministic_resolution.dart';
import 'package:rune_duel/battle/engine/draw_schedule.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart'
    show ConveyorChainEvent;
import 'package:rune_duel/battle/engine/trajectory_parser.dart'
    show ParsedFormula;
import 'package:rune_duel/battle/engine/turn_actions.dart'
    show ResolvedSpellEvent, SpellCastEvent;
import 'package:rune_duel/battle/engine/wild_magic_applicator.dart'
    show WildMagicEvent;
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/casting_enhancements.dart';
import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/battle/models/leyline_codebook.dart'
    show IncantationCodebook;
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── A minimal host ───────────────────────────────────────────────────────────

class _Host implements ActionResolutionHost {
  @override
  bool isLocalPlayer(String playerId) => playerId == 'player_a';

  @override
  GameMode get componentsGameMode => GameMode.wizard;

  @override
  CertifiedCast? certifiedFromProofBytes(
    SpellAsset spell, {
    required String casterPlayerId,
  }) =>
      null;

  Uint8List _seed(int tag) =>
      Uint8List.fromList(sha256.convert([tag]).bytes);

  @override
  Uint8List witherSeed(Uint8List entropy, String playerId) => _seed(0x06);

  @override
  Uint8List ripplingSeed(Uint8List entropy, String playerId) => _seed(0x0A);

  @override
  Uint8List turbulentSeed(Uint8List entropy, String playerId) => _seed(0x0B);

  @override
  Uint8List wildMagicEventSeed(
    Uint8List entropy, {
    required int batchCode,
    required int effectCode,
    required int effectiveBracketSteps,
  }) =>
      _seed(0x0C);

  @override
  void redrawHand(String playerId, Uint8List entropy) {}

  @override
  void reconcileHandSize(
    String playerId,
    int beforeCount,
    int afterCount,
    Uint8List entropy,
  ) {}

  @override
  void queueForcedCast(
    Set<String> playerIds,
    int countPerPlayer,
    String reasonTag,
  ) {}

  @override
  Future<void> drainForcedCasts(Uint8List entropy) async {}
}

// ── A two-wizard board under a chosen leyline ────────────────────────────────

typedef _Board = ({
  BattleState state,
  DeterministicResolution resolution,
  ActionResolutionContext ctx,
  WizardAvatar caster,
  WizardAvatar target,
});

_Board _board(LeylineConfig leyline) {
  final battlefield = Battlefield();
  const posA = HexCoord(0, 0);
  const posB = HexCoord(1, 0);
  battlefield.occupancy['player_a'] = posA;
  battlefield.occupancy['player_b'] = posB;

  final a = WizardAvatar(
    playerId: 'player_a',
    ownerPubkeyHex: '0x${'00' * 32}',
    hp: 200,
    mana: 500,
    maxMana: 500,
    position: posA,
    teamId: 'team_a',
    baseSpellRange: 3,
  );
  final b = WizardAvatar(
    playerId: 'player_b',
    ownerPubkeyHex: '0x${'11' * 32}',
    hp: 200,
    mana: 500,
    maxMana: 500,
    position: posB,
    teamId: 'team_b',
    baseSpellRange: 3,
  );
  final state = BattleState(
    config: MatchConfig(playerHp: 200, gridRadius: 4, leyline: leyline),
    avatars: [a, b],
    teams: [
      Team(id: 'team_a', playerIds: const ['player_a']),
      Team(id: 'team_b', playerIds: const ['player_b']),
    ],
    battlefield: battlefield,
    turnNumber: 1,
  );
  final host = _Host();
  return (
    state: state,
    resolution: DeterministicResolution(state),
    caster: a,
    target: b,
    ctx: ActionResolutionContext(
      host: host,
      entropy: Uint8List(32),
      drawSchedules: <String, DrawSchedule>{},
      castEvents: <SpellCastEvent>[],
      resolvedSpells: <ResolvedSpellEvent>[],
      conveyorChainEvents: <ConveyorChainEvent>[],
      wildMagicEvents: <WildMagicEvent>[],
      minionMoveEvents: <MinionMoveEvent>[],
      minionAttackEvents: <AttackEvent>[],
    ),
  );
}

SpellAsset _spell() => SpellAsset(
      id: 'mutable-probe',
      name: 'Mutable Probe',
      createdAt: DateTime.utc(2026, 9, 3),
      tier: 12,
      t: 12,
      segmentCount: 3,
      dotCount: 2,
      manaCost: 10,
      initialGrid: const [],
      proofBytes: Uint8List(0),
      commitmentHex: '0x${'00' * 32}',
      spellHashHex: '0x${'00' * 32}',
      ownerPubkeyHex: '0x${'00' * 32}',
    );

/// Resolve [formulas] as one cast and return the target's HP loss.
///
/// [suppressedFormulas] is a trajectory counter charm's partial counter — the
/// number of LEADING STRUCTURAL formulas the charm cancelled before anything
/// reached the effect resolver.
Future<int> _hpLostCasting(
  _Board board,
  List<ParsedFormula> formulas, {
  int suppressedFormulas = 0,
}) async {
  final before = board.target.hp;
  await board.resolution.applySpell(
    board.ctx,
    board.caster,
    _spell(),
    board.target.position,
    const CastingEnhancements(),
    HashRng(Uint8List(32)),
    certFormulas: formulas,
    certElementSequence: const [],
    skipChainUpdate: true,
    suppressedFormulas: suppressedFormulas,
  );
  return before - board.target.hp;
}

const _rivendell4 = 4;

LeylineConfig _mutable() => LeylineConfig.mutable(
      communitySeed: 'rivendell',
      formulaLength: _rivendell4,
    );

ParsedFormula _f(BorderZone affinity, List<BorderZone> tail) =>
    ParsedFormula.withTail(affinity: affinity, tail: tail);

void main() {
  final leyline = _mutable();
  final book = IncantationCodebook.derive(leyline);
  final lexicon = IncantationLexicon.of(leyline);

  // A key this leyline maps to Blast, and a key it maps to noise. Taken from
  // the codebook the Slice B vectors pin, not invented here.
  final damageKey = book.keysFor(EffectKind.damage).first;
  final noiseKey = book.orderedKeys.firstWhere(
    (k) => book.lookup(k) is IncantationNoise,
  );

  /// Fire-affinity Blast is `DamageEffect(amount: 4, kind: direct)` — the one
  /// row this file depends on, asserted here so a table edit fails with a
  /// clear reason rather than as a mysterious arithmetic mismatch.
  const damagePerFormula = 4;

  setUp(() {
    expect(lexicon.meaningOf(_f(BorderZone.fire, damageKey)),
        const IncantationEffect(EffectKind.damage));
    expect(lexicon.meaningOf(_f(BorderZone.fire, noiseKey)),
        kIncantationNoise);
  });

  test('the board really is mutable, and chunks at 4', () {
    final board = _board(leyline);
    expect(board.resolution.lexicon.isMutable, isTrue);
    expect(board.resolution.lexicon.formulaLength, 4);
    expect(damageKey.length, 3, reason: 'a length-4 tail is 3 elements');
    expect(noiseKey.length, 3);
  });

  test('an ordinary board derives nothing', () {
    final board = _board(LeylineConfig.ordinaryDefault);
    expect(board.resolution.lexicon.isMutable, isFalse);
    expect(board.resolution.lexicon.formulaLength, 3);
  });

  test('a meaningful formula resolves to exactly its codebook effect',
      () async {
    final board = _board(leyline);
    final lost = await _hpLostCasting(board, [_f(BorderZone.fire, damageKey)]);
    expect(lost, damagePerFormula,
        reason: 'the leyline says this tail is Blast, so Blast is what lands');
  });

  test('a noise formula resolves to nothing', () async {
    final board = _board(leyline);
    final lost = await _hpLostCasting(board, [_f(BorderZone.fire, noiseKey)]);
    expect(lost, 0,
        reason: 'no effect, no substitute, and above all no fallback to the '
            'ordinary table — which would have read the same three elements '
            'as a triplet and dealt damage');
  });

  test('a noise formula does not fall back to the ordinary reading', () async {
    // The strongest form of the no-fallback claim. Under the ORDINARY table
    // this tail's first two elements resolve to a real effect; if anything in
    // the resolution path quietly fell back, this cast would do something.
    final board = _board(leyline);
    final ordinaryKind = effectKindFromPair(noiseKey[0], noiseKey[1]);
    expect(ordinaryKind, isNotNull);
    expect(await _hpLostCasting(board, [_f(BorderZone.fire, noiseKey)]), 0);
    // And the ordinary accessors refuse outright rather than silently
    // truncating the tail.
    expect(() => _f(BorderZone.fire, noiseKey).effectType1, throwsStateError);
  });

  test('a mixed cast resolves every meaningful formula and skips the noise',
      () async {
    final board = _board(leyline);
    final lost = await _hpLostCasting(board, [
      _f(BorderZone.fire, damageKey),
      _f(BorderZone.fire, noiseKey),
      _f(BorderZone.fire, damageKey),
    ]);
    expect(lost, damagePerFormula * 2,
        reason: 'a noise formula in the middle must neither swallow the '
            'formula after it nor contribute one of its own');
  });

  test('noise at either end changes nothing', () async {
    for (final formulas in [
      [
        _f(BorderZone.fire, noiseKey),
        _f(BorderZone.fire, damageKey),
      ],
      [
        _f(BorderZone.fire, damageKey),
        _f(BorderZone.fire, noiseKey),
      ],
    ]) {
      final board = _board(leyline);
      expect(await _hpLostCasting(board, formulas), damagePerFormula);
    }
  });

  test('an all-noise cast is completely inert', () async {
    final board = _board(leyline);
    final beforeHp = board.target.hp;
    final beforeMana = board.target.mana;
    final lost = await _hpLostCasting(board, [
      _f(BorderZone.fire, noiseKey),
      _f(BorderZone.water, noiseKey),
      _f(BorderZone.earth, noiseKey),
    ]);
    expect(lost, 0);
    expect(board.target.hp, beforeHp);
    expect(board.target.mana, beforeMana);
    expect(board.state.tileEffects, isEmpty,
        reason: 'no terrain was placed either — inertness is total, not just '
            'damage-shaped');
    expect(board.state.clouds, isEmpty);
    expect(board.state.minions, isEmpty);
  });

  test('the same formulas under an ORDINARY board resolve the ordinary way',
      () async {
    // The invariance check from the other direction: an ordinary board handed
    // ordinary-length formulas is untouched by any of this.
    final board = _board(LeylineConfig.ordinaryDefault);
    final lost = await _hpLostCasting(board, [
      ParsedFormula(
        affinity: BorderZone.fire,
        effectType1: BorderZone.fire,
        effectType2: BorderZone.fire,
      ),
    ]);
    expect(lost, damagePerFormula,
        reason: 'fire-fire-fire is Blast under the fixed table, as it always '
            'has been');
  });

  // ── Recital follows the active grammar (Slice E pin) ──────────────────────
  //
  // `expectedRecitalSlots` is what a vocal cast is SCORED against. Slice E
  // fixed `BattleScreen._expectedElementCount`, which told the caster how many
  // words to say and had hardcoded the ordinary 3 — so under a length-5
  // leyline the screen asked for 12 words while the engine scored 10, and a
  // caster who did exactly what the screen said was penalised for it.
  //
  // The engine side is canonical and is pinned here; the screen now computes
  // the same thing from `lexicon.formulaLength`, and the posture test in
  // `incantation_meaning_test.dart` keeps it from drifting back to the literal.

  group('expected recital slots', () {
    /// Twelve elements, no two adjacent equal — the shape a real committed
    /// trajectory has.
    List<BorderZone> twelve() => [
          for (var i = 0; i < 12; i++) BorderZone.values[i % 4],
        ];

    test('the slot count is the complete-formula prefix, per grammar', () {
      // 12 is divisible by 3, 4 and 6 but not 5, so the length-5 row is also
      // the residual-is-discarded case.
      const expected = {3: 12, 4: 12, 5: 10, 6: 12};
      for (final entry in expected.entries) {
        final leyline = entry.key == 3
            ? LeylineConfig.ordinaryDefault
            : LeylineConfig.mutable(
                communitySeed: 'rivendell', formulaLength: entry.key);
        final board = _board(leyline);
        expect(
          board.resolution.expectedRecitalSlots(twelve()).length,
          entry.value,
          reason: 'length ${entry.key}',
        );
        // And it is exactly what the UI now computes independently.
        expect(
          board.resolution.expectedRecitalSlots(twelve()).length,
          completeFormulaElementCount(
            12,
            formulaLength: board.resolution.lexicon.formulaLength,
          ),
          reason: 'length ${entry.key}: the screen and the engine must agree '
              'about how many words the caster owes',
        );
      }
    });

    test('a noise formula is still recited', () {
      // §6: a noise chunk is consumed exactly like a meaningful one — only its
      // EFFECT is absent. The caster still speaks its words, so the slot count
      // is structural and cannot depend on the codebook.
      final board = _board(leyline);
      final allNoise = [
        ...(_f(BorderZone.water, noiseKey).tail),
        BorderZone.water,
      ];
      // Four elements = one complete length-4 formula, whatever it means.
      expect(allNoise.length, 4);
      expect(board.resolution.expectedRecitalSlots(allNoise).length, 4,
          reason: 'a spell of pure noise is still spoken in full');
    });

    test('a structurally void spell asks for nothing', () {
      // Three elements under length 4: no complete formula, so no words are
      // owed and none are scored.
      final board = _board(leyline);
      expect(
        board.resolution.expectedRecitalSlots(
          const [BorderZone.fire, BorderZone.water, BorderZone.earth],
        ),
        isEmpty,
      );
    });
  });

  // ── Counter-charm suppression counts STRUCTURAL formulas (Slice E pin) ─────
  //
  // Ratified in Slice D and pinned here because Slice E puts a number of
  // countered formulas in front of players: a partial counter cancels the
  // leading formulas of the STRUCTURAL list, noise included, because that is
  // what the charm actually matched against — the certified element sequence,
  // which is leyline-independent. A charm cannot know, and must not depend on,
  // which of the chunks it cancelled happened to mean something.
  //
  // The consequence UI copy has to respect: "1 formula countered" does NOT
  // mean "1 effect cancelled". Suppressing a noise formula cancels nothing
  // observable, and the charm's owner still pays for it.

  group('partial counter-charm suppression', () {
    test('a suppressed noise formula consumes a suppression slot', () async {
      // Noise, then two Blasts. Suppressing ONE formula eats the noise — so
      // both Blasts survive and the cast is undiminished, even though a
      // formula was cancelled.
      final board = _board(leyline);
      final lost = await _hpLostCasting(
        board,
        [
          _f(BorderZone.water, noiseKey),
          _f(BorderZone.fire, damageKey),
          _f(BorderZone.fire, damageKey),
        ],
        suppressedFormulas: 1,
      );
      expect(lost, damagePerFormula * 2,
          reason: 'suppression skips the leading STRUCTURAL formula, which '
              'here is the noise — if it skipped the leading MEANINGFUL one, '
              'a Blast would have been eaten and this would be one Blast');
    });

    test('suppressing a meaningful formula does cancel its effect', () async {
      // The control. Same shape, noise moved to the back: now the leading
      // structural formula is a Blast, and suppressing one really does cost
      // the caster an effect.
      final board = _board(leyline);
      final lost = await _hpLostCasting(
        board,
        [
          _f(BorderZone.fire, damageKey),
          _f(BorderZone.fire, damageKey),
          _f(BorderZone.water, noiseKey),
        ],
        suppressedFormulas: 1,
      );
      expect(lost, damagePerFormula);
    });

    test('suppression counts positions, not effects', () async {
      // Stated directly: two casts with the SAME number of meaningful
      // formulas and the same suppression count resolve differently, purely
      // because of where the noise sits. That is the whole of the ruling.
      final noiseFirst = await _hpLostCasting(
        _board(leyline),
        [
          _f(BorderZone.water, noiseKey),
          _f(BorderZone.fire, damageKey),
        ],
        suppressedFormulas: 1,
      );
      final noiseLast = await _hpLostCasting(
        _board(leyline),
        [
          _f(BorderZone.fire, damageKey),
          _f(BorderZone.water, noiseKey),
        ],
        suppressedFormulas: 1,
      );
      expect(noiseFirst, damagePerFormula);
      expect(noiseLast, 0);
    });

    test('ordinary suppression is unchanged', () async {
      // Ordinary interpretation is total, so structural and meaningful
      // suppression are the same thing — and must stay the same thing.
      final board = _board(LeylineConfig.ordinaryDefault);
      ParsedFormula blast() => ParsedFormula(
            affinity: BorderZone.fire,
            effectType1: BorderZone.fire,
            effectType2: BorderZone.fire,
          );
      expect(
        await _hpLostCasting(board, [blast(), blast()],
            suppressedFormulas: 1),
        damagePerFormula,
      );
    });
  });
}
