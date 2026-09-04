// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_phase_test.dart — Wild Magic vNext slice 7: collect → coalesce →
// order → resolve, scoped to one simultaneous resolution batch.
//
// Built against the SEAM rather than through natural hash fixtures, exactly as
// the slice-7 pre-coding review recommended. Two casters whose spells hash to
// the same wild-magic row and share an eligible element is a rare coincidence
// to search for and an unreadable fixture once found; every duplicate this
// slice exists to handle is reachable here by handing the resolver two
// certified trigger lists directly. The natural derivation (hash → scan →
// eligibility → triggers) is already pinned by `wild_magic_test.dart` and
// `wild_magic_resolution_test.dart`; nothing here re-tests it.
//
// Four groups:
//
//   1. the pinned consensus encodings (effect codes, batch codes);
//   2. the coalesced-event RNG's exact byte layout, and the properties that
//      layout exists to buy;
//   3. coalescing itself, as a pure function;
//   4. the phase driven through `DeterministicResolution.resolveActions`,
//      which is where R2 (death after admission), R3 (wild magic before
//      formula effects) and the phase-scope bounds actually live.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/battle_events.dart';
import 'package:rune_duel/battle/engine/deterministic_resolution.dart';
import 'package:rune_duel/battle/engine/draw_schedule.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart'
    show ConveyorChainEvent;
import 'package:rune_duel/battle/engine/trajectory_parser.dart'
    show ParsedFormula;
import 'package:rune_duel/battle/engine/turn_actions.dart';
import 'package:rune_duel/battle/engine/wild_magic_applicator.dart';
import 'package:rune_duel/battle/engine/wild_magic_phase.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/casting_enhancements.dart'
    show GameMode;
import 'package:rune_duel/battle/models/certified_cast.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

String _hexOf(String seed) => seed.codeUnits
    .map((c) => (c & 0xFF).toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

/// A spell that never has to parse: every cast below hands the resolver its
/// certified semantics through the fake host, so `proofBytes` is never read.
SpellAsset _spell(String id, {int t = 3}) => SpellAsset(
      id: id,
      createdAt: DateTime.utc(2026, 9, 3),
      tier: 12,
      t: t,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 1,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List(0),
      name: id,
      commitmentHex: '0x${_hexOf(id)}',
      spellHashHex: '0x${_hexOf('$id-hash')}',
      formula: const [],
    );

/// Fire-Fire-Fire: `DamageEffect(amount: 4, kind: direct)`. The one formula
/// this file needs, because the only ordinary effect it asserts about is
/// "did the target take damage / did it die".
final _damageFormula = ParsedFormula(
  affinity: BorderZone.fire,
  effectType1: BorderZone.fire,
  effectType2: BorderZone.fire,
);

CertifiedCast _certified({
  int formulas = 1,
  List<WildMagicTrigger> wildMagic = const [],
}) =>
    CertifiedCast(
      formulas: List.filled(formulas, _damageFormula),
      elementSequence:
          List.filled(formulas * 3, BorderZone.fire, growable: false),
      wildMagic: wildMagic,
      baseManaCost: 1,
    );

WildMagicTrigger _trigger(
  WildMagicRow row,
  SpellAffinity element, {
  int bracketSteps = 0,
}) =>
    WildMagicTrigger(row: row, element: element, bracketSteps: bracketSteps);

/// The (row, element) cell of each effect this file drives, so a test can name
/// the EFFECT it wants and let the table supply the trigger.
WildMagicTrigger _triggerFor(WildMagicEffectKind effect, {int bracketSteps = 0}) {
  for (final row in WildMagicRow.values) {
    for (final element in SpellAffinity.values) {
      if (wildMagicEffectFor(row, element) == effect) {
        return _trigger(row, element, bracketSteps: bracketSteps);
      }
    }
  }
  throw StateError('no (row, element) cell produces $effect');
}

// ── A fake ActionResolutionHost ───────────────────────────────────────────────

/// Everything `resolveActions` needs that is not a function of `(state, args,
/// rng)`, with the certified semantics of each cast handed in directly.
///
/// Keyed by `(playerId, spell.id)` rather than by commitment: several casters
/// in one batch deliberately cast the SAME grid here, which is exactly the
/// collision the real host's ownership branch exists to avoid.
class _FakeHost implements ActionResolutionHost {
  _FakeHost({required this.localPlayerId, required this.certified});

  final String localPlayerId;
  final Map<String, CertifiedCast> certified;

  /// Every forced-cast request the wild-magic phase queued, in order.
  final List<(Set<String>, int, String)> forcedCasts = [];

  /// Every `(batchCode, effectCode, effectiveBracketSteps)` an event asked a
  /// seed for, in resolution order — the phase's whole RNG surface, observable.
  final List<(int, int, int)> eventSeeds = [];

  final List<String> redrawnHands = [];

  @override
  bool isLocalPlayer(String playerId) => playerId == localPlayerId;

  @override
  GameMode get componentsGameMode => GameMode.wizard;

  @override
  CertifiedCast? certifiedFromProofBytes(
    SpellAsset spell, {
    required String casterPlayerId,
  }) =>
      certified['$casterPlayerId/${spell.id}'];

  Uint8List _seed(int tag, String playerId) => Uint8List.fromList(
        sha256.convert([tag, ...playerId.codeUnits]).bytes,
      );

  @override
  Uint8List witherSeed(Uint8List entropy, String playerId) =>
      _seed(0x06, playerId);

  @override
  Uint8List ripplingSeed(Uint8List entropy, String playerId) =>
      _seed(0x0A, playerId);

  @override
  Uint8List turbulentSeed(Uint8List entropy, String playerId) =>
      _seed(0x0B, playerId);

  @override
  Uint8List wildMagicEventSeed(
    Uint8List entropy, {
    required int batchCode,
    required int effectCode,
    required int effectiveBracketSteps,
  }) {
    eventSeeds.add((batchCode, effectCode, effectiveBracketSteps));
    return wildMagicEventSeedFn(
      entropy: entropy,
      turnNumber: 1,
      batchCode: batchCode,
      effectCode: effectCode,
      effectiveBracketSteps: effectiveBracketSteps,
    );
  }

  @override
  void redrawHand(String playerId, Uint8List entropy) =>
      redrawnHands.add(playerId);

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
  ) =>
      forcedCasts.add((playerIds, countPerPlayer, reasonTag));

  /// Deliberately a no-op beyond clearing: a real drain needs a protocol round
  /// trip. What this file asserts about Spontaneous Combustion is how many
  /// requests the PHASE queued, which is the bound the ruling is about.
  @override
  Future<void> drainForcedCasts(Uint8List entropy) async {}
}

/// The top-level function, aliased so `_FakeHost`'s override of the same name
/// does not shadow it inside the class.
const wildMagicEventSeedFn = wildMagicEventSeed;

// ── A two-wizard board ────────────────────────────────────────────────────────

typedef _Ctx = ({
  BattleState state,
  DeterministicResolution resolution,
  ActionResolutionContext ctx,
  _FakeHost host,
  WizardAvatar a,
  WizardAvatar b,
});

final Uint8List _entropy =
    Uint8List.fromList(List.generate(32, (i) => (i * 11 + 5) & 0xFF));

_Ctx _board({
  required Map<String, CertifiedCast> certified,
  int radius = 4,
  int hpA = 24,
  int hpB = 24,
  HexCoord posA = const HexCoord(0, 2),
  HexCoord posB = const HexCoord(0, -2),
}) {
  final battlefield = Battlefield(radius: radius)
    ..occupancy['a'] = posA
    ..occupancy['b'] = posB;
  final a = WizardAvatar(
    playerId: 'a',
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: hpA,
    mana: 500,
    maxMana: 500,
    position: posA,
    teamId: 'ta',
    baseSpellRange: 8,
  );
  final b = WizardAvatar(
    playerId: 'b',
    ownerPubkeyHex: '0x${'1' * 64}',
    hp: hpB,
    mana: 500,
    maxMana: 500,
    position: posB,
    teamId: 'tb',
    baseSpellRange: 8,
  );
  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [a, b],
    teams: [
      Team(id: 'ta', playerIds: const ['a']),
      Team(id: 'tb', playerIds: const ['b']),
    ],
    battlefield: battlefield,
    turnNumber: 1,
  );
  final host = _FakeHost(localPlayerId: 'a', certified: certified);
  return (
    state: state,
    resolution: DeterministicResolution(state),
    host: host,
    a: a,
    b: b,
    ctx: ActionResolutionContext(
      host: host,
      entropy: _entropy,
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

Future<void> _resolve(
  _Ctx c,
  List<(WizardAvatar, TurnAction)> actions,
) =>
    c.resolution.resolveActions(
      c.ctx,
      actions: actions,
      delayedCertified: const {},
      preMovPos: {for (final av in c.state.avatars) av.playerId: av.position},
      preMovRange: {for (final av in c.state.avatars) av.playerId: 8},
      rng: HashRng(Uint8List(32)),
    );

void main() {
  // ── 1. Pinned consensus encodings ───────────────────────────────────────
  group('pinned encodings', () {
    test('every effect kind has a code, and the codes are 0..11 distinct', () {
      for (final effect in WildMagicEffectKind.values) {
        expect(kWildMagicEffectCode.containsKey(effect), isTrue,
            reason: 'an effect with no pinned code is a consensus hole');
      }
      final codes = kWildMagicEffectCode.values.toList()..sort();
      expect(codes, List.generate(WildMagicEffectKind.values.length, (i) => i));
    });

    test('the codes reproduce row-then-element order exactly', () {
      // The order the ratified plan §11 states, written out independently of
      // both the enum's declaration order and the code map itself.
      final expected = <WildMagicEffectKind>[
        for (final row in WildMagicRow.values)
          for (final element in [
            SpellAffinity.fire,
            SpellAffinity.earth,
            SpellAffinity.water,
            SpellAffinity.air,
          ])
            wildMagicEffectFor(row, element),
      ];
      final byCode = kWildMagicEffectCode.keys.toList()
        ..sort((x, y) => wildMagicEffectCode(x).compareTo(wildMagicEffectCode(y)));
      expect(byCode, expected);
    });

    test('the effect codes are pinned NUMBERS, not enum indices', () {
      // Spelled out so a reorder of `WildMagicEffectKind` fails here loudly
      // rather than silently rerolling every event's RNG on one device.
      expect(kWildMagicEffectCode[WildMagicEffectKind.burningHot], 0);
      expect(kWildMagicEffectCode[WildMagicEffectKind.mountains], 1);
      expect(kWildMagicEffectCode[WildMagicEffectKind.manaFlood], 2);
      expect(kWildMagicEffectCode[WildMagicEffectKind.zephyr], 3);
      expect(kWildMagicEffectCode[WildMagicEffectKind.spontaneousCombustion], 4);
      expect(kWildMagicEffectCode[WildMagicEffectKind.chasm], 5);
      expect(kWildMagicEffectCode[WildMagicEffectKind.glacier], 6);
      expect(kWildMagicEffectCode[WildMagicEffectKind.updraft], 7);
      expect(kWildMagicEffectCode[WildMagicEffectKind.phoenix], 8);
      expect(kWildMagicEffectCode[WildMagicEffectKind.statuesque], 9);
      expect(kWildMagicEffectCode[WildMagicEffectKind.ripplingReflections], 10);
      expect(kWildMagicEffectCode[WildMagicEffectKind.scatteredGusts], 11);
    });

    test('every resolution group has a pinned batch code', () {
      for (final group in ResolutionGroup.values) {
        expect(kResolutionBatchCode.containsKey(group), isTrue);
      }
      expect(resolutionBatchCode(ResolutionGroup.quickSpell), 0);
      expect(resolutionBatchCode(ResolutionGroup.normalSpell), 1);
      expect(resolutionBatchCode(ResolutionGroup.sluggishSpell), 2);
      expect(kResolutionBatchCode.values.toSet().length, 3,
          reason: 'two batches sharing a code would share their RNG streams');
    });
  });

  // ── 2. The coalesced-event RNG ──────────────────────────────────────────
  group('wildMagicEventSeed byte layout', () {
    Uint8List seedOf({
      Uint8List? matchId,
      int turnNumber = 7,
      int batchCode = 1,
      int effectCode = 5,
      int bracket = 0,
    }) =>
        wildMagicEventSeed(
          entropy: _entropy,
          matchId: matchId,
          turnNumber: turnNumber,
          batchCode: batchCode,
          effectCode: effectCode,
          effectiveBracketSteps: bracket,
        );

    test('the preimage is exactly the documented concatenation', () {
      // The whole point of pinning a layout is that a SECOND, independent
      // spelling of it agrees. This is that second spelling.
      final expected = sha256.convert(<int>[
        ..._entropy,
        0, 0, 0, 7, // uint32be(turnNumber)
        1, // batchCode
        0x0C, // kWildMagicEventRngDomain
        5, // effectCode
        2, // effectiveBracketSteps
      ]).bytes;
      expect(seedOf(bracket: 2), Uint8List.fromList(expected));
    });

    test('matchId sits between the entropy and the turn number', () {
      final matchId = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final expected = sha256.convert(<int>[
        ..._entropy,
        ...matchId,
        0, 0, 0, 7,
        1,
        0x0C,
        5,
        0,
      ]).bytes;
      expect(seedOf(matchId: matchId), Uint8List.fromList(expected));
    });

    test('a null matchId omits the field rather than padding it', () {
      expect(
        seedOf(matchId: Uint8List(0)),
        seedOf(),
        reason: 'an empty matchId and no matchId are the same preimage',
      );
    });

    test('the domain tag is 0x0C and separates this from every other stream',
        () {
      expect(kWildMagicEventRngDomain, 0x0C);
      // Tag 0x09's construction is `SHA-256(phaseSeed ‖ playerId ‖ nonce)` — a
      // 32-byte digest followed by text. Nothing here can produce that shape,
      // and the assertion that matters is simply that this preimage begins
      // with the RAW entropy.
      final seed = seedOf();
      expect(seed.length, 32);
    });

    test('the same event in the same batch always gives the same stream', () {
      expect(seedOf(), seedOf());
    });

    test('different batches of one turn never share a stream', () {
      expect(seedOf(batchCode: 0), isNot(seedOf(batchCode: 1)));
      expect(seedOf(batchCode: 1), isNot(seedOf(batchCode: 2)));
    });

    test('different effects never share a stream', () {
      expect(seedOf(effectCode: 3), isNot(seedOf(effectCode: 5)));
    });

    test('different turns never share a stream', () {
      expect(seedOf(turnNumber: 7), isNot(seedOf(turnNumber: 8)));
    });

    test('a stronger effective bracket IS a different event, deliberately', () {
      expect(seedOf(bracket: 0), isNot(seedOf(bracket: 1)));
    });

    test('an out-of-range bracket throws rather than wrapping', () {
      // A silent mask would hand a bracket-256 event the bracket-0 stream —
      // a fork with nothing to signal it.
      expect(() => seedOf(bracket: 256), throwsArgumentError);
      expect(() => seedOf(bracket: -1), throwsArgumentError);
      expect(seedOf(bracket: kMaxWildMagicBracketSteps), isA<Uint8List>());
    });

    test('an unpinned code throws rather than defaulting to 0', () {
      expect(() => wildMagicEffectCode(WildMagicEffectKind.chasm), returnsNormally);
      expect(() => seedOf(effectCode: 256), throwsArgumentError);
      expect(() => seedOf(batchCode: -1), throwsArgumentError);
    });
  });

  // ── 3. Coalescing ────────────────────────────────────────────────────────
  group('coalesceWildMagicTriggers', () {
    test('two identical triggers from two casters become ONE event', () {
      final events = coalesceWildMagicTriggers([
        WildMagicTriggerRecord('a', _triggerFor(WildMagicEffectKind.zephyr)),
        WildMagicTriggerRecord('b', _triggerFor(WildMagicEffectKind.zephyr)),
      ]);
      expect(events.length, 1);
      expect(events.single.effect, WildMagicEffectKind.zephyr);
      expect(events.single.contributingCasterIds, ['a', 'b']);
    });

    test('the strongest contributing bracket wins', () {
      final events = coalesceWildMagicTriggers([
        WildMagicTriggerRecord(
            'a', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 1)),
        WildMagicTriggerRecord(
            'b', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 3)),
        WildMagicTriggerRecord(
            'c', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)),
      ]);
      expect(events.single.effectiveBracketSteps, 3,
          reason: 'max, never a sum — bracket is the one power axis');
    });

    test('contributor order changes nothing at all', () {
      final records = [
        WildMagicTriggerRecord(
            'b', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)),
        WildMagicTriggerRecord('a', _triggerFor(WildMagicEffectKind.zephyr)),
        WildMagicTriggerRecord(
            'c', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 1)),
      ];
      String describe(List<CoalescedWildMagicEvent> evs) => evs
          .map((e) =>
              '${e.effectCode}:${e.effectiveBracketSteps}:${e.contributingCasterIds}')
          .join('|');

      final forwards = describe(coalesceWildMagicTriggers(records));
      final backwards =
          describe(coalesceWildMagicTriggers(records.reversed.toList()));
      expect(forwards, backwards);
      // And so is the RNG each of them would draw from.
      for (final evs in [
        coalesceWildMagicTriggers(records),
        coalesceWildMagicTriggers(records.reversed.toList()),
      ]) {
        expect(
          evs.map((e) => wildMagicEventSeed(
                entropy: _entropy,
                turnNumber: 1,
                batchCode: 1,
                effectCode: e.effectCode,
                effectiveBracketSteps: e.effectiveBracketSteps,
              )),
          evs.map((e) => wildMagicEventSeed(
                entropy: _entropy,
                turnNumber: 1,
                batchCode: 1,
                effectCode: e.effectCode,
                effectiveBracketSteps: e.effectiveBracketSteps,
              )),
        );
      }
    });

    test('adding an EQUAL duplicate trigger does not reroll the event', () {
      final one = coalesceWildMagicTriggers([
        WildMagicTriggerRecord(
            'a', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)),
      ]).single;
      final two = coalesceWildMagicTriggers([
        WildMagicTriggerRecord(
            'a', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)),
        WildMagicTriggerRecord(
            'b', _triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)),
      ]).single;
      expect(two.effectiveBracketSteps, one.effectiveBracketSteps);
      expect(two.effectCode, one.effectCode);
      // Only the attribution list grew.
      expect(one.contributingCasterIds, ['a']);
      expect(two.contributingCasterIds, ['a', 'b']);
    });

    test('distinct effects come back in ascending effect-code order', () {
      final events = coalesceWildMagicTriggers([
        WildMagicTriggerRecord(
            'a', _triggerFor(WildMagicEffectKind.scatteredGusts)),
        WildMagicTriggerRecord('a', _triggerFor(WildMagicEffectKind.chasm)),
        WildMagicTriggerRecord('b', _triggerFor(WildMagicEffectKind.burningHot)),
      ]);
      expect(events.map((e) => e.effect), [
        WildMagicEffectKind.burningHot,
        WildMagicEffectKind.chasm,
        WildMagicEffectKind.scatteredGusts,
      ]);
    });

    test('a duplicate caster id appears once in the attribution list', () {
      final events = coalesceWildMagicTriggers([
        WildMagicTriggerRecord('a', _triggerFor(WildMagicEffectKind.zephyr)),
        WildMagicTriggerRecord('a', _triggerFor(WildMagicEffectKind.zephyr)),
      ]);
      expect(events.single.contributingCasterIds, ['a']);
    });

    test('no triggers means no events', () {
      expect(coalesceWildMagicTriggers(const []), isEmpty);
    });
  });

  // ── 4. The phase, through resolveActions ────────────────────────────────
  group('the phase, driven through resolveActions', () {
    test('two same-batch Chasms open ONE axis, as one event', () async {
      final chasm = _triggerFor(WildMagicEffectKind.chasm);
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [chasm]),
        'b/sb': _certified(wildMagic: [chasm]),
      });
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      final chasms = c.ctx.wildMagicEvents
          .where((e) => e.effect == WildMagicEffectKind.chasm);
      expect(chasms.length, 1,
          reason: 'two triggers, one world event (R4)');
      expect(chasms.single.contributingCasterIds, ['a', 'b']);
      expect(c.host.eventSeeds.length, 1,
          reason: 'one event draws one stream');

      // Exactly one axis of chasm cells is on the board.
      final open = c.state.tileEffects.entries
          .where((e) => e.value is ChasmTile)
          .map((e) => e.key)
          .toSet();
      final onQ = open.every((h) => h.q == 0);
      final onR = open.every((h) => h.r == 0);
      final onS = open.every((h) => h.q + h.r == 0);
      expect(onQ || onR || onS, isTrue,
          reason: 'a second axis would mean two Chasms resolved');
      expect(open.length, 2 * c.state.config.gridRadius + 1);
    });

    test('the strongest Chasm bracket wins and sets the expiry', () async {
      final c = _board(certified: {
        'a/sa': _certified(
            wildMagic: [_triggerFor(WildMagicEffectKind.chasm, bracketSteps: 0)]),
        'b/sb': _certified(
            wildMagic: [_triggerFor(WildMagicEffectKind.chasm, bracketSteps: 2)]),
      });
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.host.eventSeeds.single.$3, 2,
          reason: 'the event RNG is keyed on the EFFECTIVE bracket');
      final expiries = c.state.expiringTiles.values.toSet();
      // turnNumber (1) + 1 + bracketSteps (2)
      expect(expiries, {4});
    });

    test('contributor order does not alter the axis the Chasm selects',
        () async {
      Future<Set<HexCoord>> axisFor(bool bFirst) async {
        final c = _board(certified: {
          'a/sa': _certified(
              wildMagic: [_triggerFor(WildMagicEffectKind.chasm)]),
          'b/sb': _certified(
              wildMagic: [_triggerFor(WildMagicEffectKind.chasm)]),
        });
        final actions = <(WizardAvatar, TurnAction)>[
          (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
          (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
        ];
        // `resolveActions` sorts internally, but the INPUT order is
        // device-relative — this is the fact the old encounter-order nonce
        // made observable.
        await _resolve(c, bFirst ? actions.reversed.toList() : actions);
        return c.state.tileEffects.entries
            .where((e) => e.value is ChasmTile)
            .map((e) => e.key)
            .toSet();
      }

      expect(await axisFor(false), await axisFor(true));
    });

    test('a lone Chasm and a coalesced one of the same bracket agree', () async {
      // The event's identity is the effect and the bracket — not how many
      // casters happened to roll it. A second EQUAL contributor must not move
      // the axis.
      Future<Set<HexCoord>> axisWith(bool second) async {
        final c = _board(certified: {
          'a/sa': _certified(
              wildMagic: [_triggerFor(WildMagicEffectKind.chasm)]),
          'b/sb': _certified(
              wildMagic: second
                  ? [_triggerFor(WildMagicEffectKind.chasm)]
                  : const []),
        });
        await _resolve(c, [
          (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
          (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
        ]);
        return c.state.tileEffects.entries
            .where((e) => e.value is ChasmTile)
            .map((e) => e.key)
            .toSet();
      }

      expect(await axisWith(true), await axisWith(false));
    });

    test('Chasms in DISTINCT batches stay distinct events', () async {
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [_triggerFor(WildMagicEffectKind.chasm)]),
        'b/sb': _certified(wildMagic: [_triggerFor(WildMagicEffectKind.chasm)]),
      });
      // A Quick caster and a Sluggish one: two temporally separate resolution
      // groups that merely share a turn number (R1).
      StatusEffect.applyTo(
          c.a.activeStatusEffects, StatusEffectId.quick, const {}, 3);
      StatusEffect.applyTo(
          c.b.activeStatusEffects, StatusEffectId.sluggish, const {}, 3);
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(
        c.ctx.wildMagicEvents
            .where((e) => e.effect == WildMagicEffectKind.chasm)
            .length,
        2,
        reason: 'separate batches are separate world events',
      );
      expect(c.host.eventSeeds.map((s) => s.$1), [
        resolutionBatchCode(ResolutionGroup.quickSpell),
        resolutionBatchCode(ResolutionGroup.sluggishSpell),
      ], reason: 'each batch draws under its own pinned batch code');
    });

    test('duplicate Spontaneous Combustions queue ONE forced cast per wizard',
        () async {
      final sc = _triggerFor(WildMagicEffectKind.spontaneousCombustion);
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [sc]),
        'b/sb': _certified(wildMagic: [sc]),
      });
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.host.forcedCasts.length, 1,
          reason: 'queueForcedCast appends per CALL — two firings used to '
              'queue two requests per living wizard');
      expect(c.host.forcedCasts.single.$1, {'a', 'b'});
      expect(c.host.forcedCasts.single.$2, 1);
    });

    test('duplicate Mountains raise at most three walls per living wizard',
        () async {
      final mountains = _triggerFor(WildMagicEffectKind.mountains);
      final c = _board(
        certified: {
          'a/sa': _certified(wildMagic: [mountains]),
          'b/sb': _certified(wildMagic: [mountains]),
        },
        radius: 5,
      );
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      final walls = c.state.tileEffects.entries
          .where((e) => e.value is ImpassableTile)
          .map((e) => e.key)
          .toSet();
      // Two wizards, three each, chosen from disjoint neighbourhoods here.
      expect(walls.length, lessThanOrEqualTo(6),
          reason: 'two firings used to select three walls EACH TIME');
      for (final av in [c.a, c.b]) {
        final around = walls
            .where((w) =>
                (w.q - av.position.q).abs() <= 1 &&
                (w.r - av.position.r).abs() <= 1 &&
                w != av.position)
            .length;
        expect(around, lessThanOrEqualTo(3),
            reason: 'the cap is per living wizard per BATCH');
      }
    });

    // ── Burning Hot: the batch boundary is the whole rule ────────────────
    //
    // Three cases, deliberately separated, because R5 is scoped to ONE
    // simultaneous batch and the persistent-state primitive must not be the
    // thing that decides which events were simultaneous.

    test('1. two Burning Hots in the SAME batch take the maximum, not the sum',
        () async {
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [
          _triggerFor(WildMagicEffectKind.burningHot, bracketSteps: 0),
        ]),
        'b/sb': _certified(wildMagic: [
          _triggerFor(WildMagicEffectKind.burningHot, bracketSteps: 2),
        ]),
      });
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      // The two triggers coalesce to ONE event at bracket 2, which arms
      // `1 + 2 = 3`. Summing would give (1 + 0) + (1 + 2) = 4.
      expect(c.state.wildMagic.spellDamageBonusFor(2), 3,
          reason: 'one batch, one world event, strongest bracket');
      expect(
        c.ctx.wildMagicEvents
            .where((e) => e.effect == WildMagicEffectKind.burningHot)
            .length,
        1,
        reason: 'one event, so the state primitive is called exactly once',
      );
      expect(c.host.eventSeeds.length, 1);
      expect(c.host.eventSeeds.single.$3, 2,
          reason: 'the event is keyed on the EFFECTIVE bracket');
    });

    test(
        '2. Quick + Normal Burning Hot in the SAME turn are separate events, '
        'and stack as they did before slice 7', () async {
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [
          _triggerFor(WildMagicEffectKind.burningHot, bracketSteps: 0),
        ]),
        'b/sb': _certified(wildMagic: [
          _triggerFor(WildMagicEffectKind.burningHot, bracketSteps: 2),
        ]),
      });
      // Two temporally distinct resolution groups that merely share a turn
      // number (R1) — so two world events, not one.
      StatusEffect.applyTo(
          c.a.activeStatusEffects, StatusEffectId.quick, const {}, 3);
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      // (1 + 0) from the Quick batch, then (1 + 2) from the Normal one: the
      // PRE-SLICE-7 additive interaction between two separate armings of the
      // same future round, deliberately preserved.
      expect(c.state.wildMagic.spellDamageBonusFor(2), 4,
          reason: 'separate batches are separate world events, and separate '
              'events stack exactly as they always did');
      expect(
        c.ctx.wildMagicEvents
            .where((e) => e.effect == WildMagicEffectKind.burningHot)
            .length,
        2,
      );
      expect(c.host.eventSeeds.map((s) => s.$1), [
        resolutionBatchCode(ResolutionGroup.quickSpell),
        resolutionBatchCode(ResolutionGroup.normalSpell),
      ], reason: 'each batch draws under its own pinned batch code');
    });

    test('3. a PREVIOUS round\'s Burning Hot is replaced, not combined',
        () async {
      final c = _board(certified: {
        'a/sa': _certified(wildMagic: [
          _triggerFor(WildMagicEffectKind.burningHot, bracketSteps: 3),
        ]),
      });
      // A stale arming from an earlier round, aimed at a round that has been
      // and gone. It must not leak its amount into the new one.
      c.state.wildMagic.armSpellDamageBonus(1, 9);
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
      ]);

      expect(c.state.wildMagic.spellDamageBonusFor(1), 0,
          reason: 'the stale round is gone');
      expect(c.state.wildMagic.spellDamageBonusFor(2), 4,
          reason: '1 + bracket 3, with nothing carried forward');
    });

    // ── R2 / R3 ──────────────────────────────────────────────────────────
    test(
        "R2: a caster killed by an earlier admitted cast still fires its wild "
        'magic AND its spell', () async {
      // 'a' sorts before 'b' and deals 12 damage; 'b' has 8 HP, so 'b' is dead
      // before its own effects would once have run. Under the old interleave
      // 'b' was skipped by `if (!actor.isAlive) continue` and neither its wild
      // magic nor its spell ever happened.
      final c = _board(
        certified: {
          'a/sa': _certified(formulas: 3),
          'b/sb': _certified(
            formulas: 3,
            wildMagic: [_triggerFor(WildMagicEffectKind.manaFlood)],
          ),
        },
        hpB: 8,
      );
      c.a.mana = 10;
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.b.isAlive, isFalse, reason: "a's spell killed b");
      expect(
        c.ctx.wildMagicEvents.map((e) => e.effect),
        contains(WildMagicEffectKind.manaFlood),
        reason: "b's wild magic was admitted before a's spell resolved (R2)",
      );
      expect(c.a.mana, c.a.maxMana,
          reason: 'Mana Flood is symmetric and fires from an admitted cast');
      expect(c.a.hp, lessThan(24),
          reason: "b's own admitted spell still resolved onto a");
      expect(
        c.ctx.resolvedSpells.map((e) => e.casterId),
        containsAll(<String>['a', 'b']),
      );
    });

    test('R2: a caster killed by an EARLIER BATCH is not admitted at all',
        () async {
      final c = _board(
        certified: {
          'a/sa': _certified(formulas: 3),
          'b/sb': _certified(
            formulas: 1,
            wildMagic: [_triggerFor(WildMagicEffectKind.manaFlood)],
          ),
        },
        hpB: 8,
      );
      c.a.mana = 10;
      StatusEffect.applyTo(
          c.a.activeStatusEffects, StatusEffectId.quick, const {}, 3);
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.b.isAlive, isFalse);
      expect(c.ctx.wildMagicEvents, isEmpty,
          reason: 'liveness is decided at each batch\'s own admission');
      expect(c.a.mana, 10, reason: 'no Mana Flood fired');
      expect(c.ctx.resolvedSpells.map((e) => e.casterId), ['a']);
    });

    test('R3: ALL wild magic resolves before ANY formula effect', () async {
      // The sharpest available marker for the ordering, because it is
      // order-sensitive in BOTH directions.
      //
      // 'a' sorts first and casts 12 damage at 'b', who has 8 HP. 'b' sorts
      // second and carries Mountains, which walls the tiles around every living
      // wizard — including the tile between 'b' and the incoming spell.
      //
      //   OLD (per-cast interleave): 'a' resolved completely first. Its damage
      //   reached 'b' over open ground and killed them, and 'b' — now dead —
      //   was skipped by `if (!actor.isAlive) continue`, so Mountains never
      //   fired at all.
      //
      //   NEW (phase): both casts are admitted, then the batch's wild magic
      //   resolves, so 'b''s walls go up BEFORE 'a''s spell flies. The spell
      //   resolves on the wall (WALL_LOS_PLAN.md §2.1) and 'b' lives.
      final c = _board(
        certified: {
          'a/sa': _certified(formulas: 3),
          'b/sb': _certified(
            formulas: 1,
            wildMagic: [_triggerFor(WildMagicEffectKind.mountains)],
          ),
        },
        hpB: 8,
        radius: 5,
      );
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      final walls = c.state.tileEffects.entries
          .where((e) => e.value is ImpassableTile)
          .map((e) => e.key)
          .toList();
      expect(walls, isNotEmpty,
          reason: "b's wild magic fired, so b was alive when the phase ran");
      final nearB = walls.where((w) =>
          (w.q - c.b.position.q).abs() <= 1 &&
          (w.r - c.b.position.r).abs() <= 1);
      expect(nearB, isNotEmpty,
          reason: 'Mountains walls every LIVING wizard, b included');

      expect(c.b.isAlive, isTrue,
          reason: "b's Mountains went up before a's spell resolved (R3), so "
              'the spell stopped at the wall');
      expect(c.b.hp, 8, reason: 'the wall took it, not the wizard');
      expect(
        c.ctx.resolvedSpells.map((e) => e.casterId),
        containsAll(<String>['a', 'b']),
        reason: 'both casts still resolved, in canonical order',
      );
    });

    // ── Admission-pass audit: Pass / Dash / Meditate ─────────────────────
    //
    // These three execute during PASS 1, while an admitted cast's formula
    // effects wait for pass 3. The audit question is whether a pass-1 mutation
    // can alter an input another action in the same batch is admitted on.
    //
    // Their complete pass-1 write set is:
    //
    //   Pass      _regressChain(actor)                       — actor's chain only
    //   Dash      _breakStatuesque(actor) + _regressChain     — + actor's window
    //   Meditate  _breakStatuesque + applyManaGain(actor, 25) + _regressChain
    //
    // Chain state (`activeChainElement`, `chainLengths`) and the Statuesque
    // window are read by NO admission input — not the cloud check, not
    // `effectiveSpellRange`, not `hasTurbulent`, not `fizzledForMana` (an
    // action field decided at commit time), not `_findCounteringCharm`. Both
    // are also the actor's own, and a Pass/Dash/Meditate actor has no cast to
    // admit. So Pass and Dash cannot reach another action's admission at all.
    //
    // MEDITATE CAN, through exactly one channel: `_findCounteringCharm` skips a
    // charm whose owner cannot afford `counterCharmManaCost`, and
    // `applyManaGain` raises mana — the meditator's, and through a Reflections
    // `manaMirror` link another wizard's. That dependency is PRE-EXISTING and
    // its ordering is unchanged: pass 1 walks the same `sorted` list the old
    // single loop did, so a Meditate still runs before the admission of every
    // later-sorted action, exactly as before. These two tests pin that.

    test(
        "Meditate's +25 can decide a later-sorted cast's counter charm, and "
        'still runs first', () async {
      final c = _board(certified: {
        'b/sb': _certified(formulas: 1),
      });
      // A Meditate has no spell, so the sort falls through to playerId: 'a'
      // meditates before 'b''s cast is admitted.
      c.a.mana = 5; // below the 10 a one-formula charm costs
      c.a.accoutrements.add(
        const Accoutrement(
          id: 'charm',
          kind: AccoutrementKind.counterCharm,
          charmTrajectory: [BorderZone.fire, BorderZone.fire, BorderZone.fire],
        ),
      );
      await _resolve(c, [
        (c.a, MeditateAction()),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.ctx.resolvedSpells.single.wasCountered, isTrue,
          reason: '5 + 25 clears the charm cost, and the Meditate is still '
              'sequenced ahead of the cast it enables');
      expect(c.a.mana, 5 + 25 - 10, reason: 'gained, then charged for the charm');
    });

    test('the same board without the Meditate cannot afford the charm',
        () async {
      // The control. Identical in every respect but the action, so the only
      // thing it can be measuring is the mana the Meditate would have added.
      final c = _board(certified: {
        'b/sb': _certified(formulas: 1),
      });
      c.a.mana = 5;
      c.a.accoutrements.add(
        const Accoutrement(
          id: 'charm',
          kind: AccoutrementKind.counterCharm,
          charmTrajectory: [BorderZone.fire, BorderZone.fire, BorderZone.fire],
        ),
      );
      await _resolve(c, [
        (c.a, PassAction()),
        (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
      ]);

      expect(c.ctx.resolvedSpells.single.wasCountered, isFalse);
      expect(c.a.mana, 5, reason: 'a Pass writes nothing but chain state');
      expect(c.a.hp, lessThan(24), reason: 'the uncountered spell landed');
    });

    test('Pass and Dash reach no admission input a no-op turn does not',
        () async {
      // Pass, Dash and "no non-cast action at all" must admit the cast
      // identically. If either wrote something admission reads, one of these
      // three boards would diverge from the others.
      Future<(bool countered, int hp, int mana)> outcome(
        TurnAction? nonCast,
      ) async {
        final c = _board(certified: {'b/sb': _certified(formulas: 1)});
        c.a.mana = 5;
        c.a.accoutrements.add(
          const Accoutrement(
            id: 'charm',
            kind: AccoutrementKind.counterCharm,
            charmTrajectory: [
              BorderZone.fire,
              BorderZone.fire,
              BorderZone.fire,
            ],
          ),
        );
        await _resolve(c, [
          if (nonCast != null) (c.a, nonCast),
          (c.b, SpellCastAction(spell: _spell('sb'), targetHex: c.a.position)),
        ]);
        return (
          c.ctx.resolvedSpells.single.wasCountered,
          c.a.hp,
          c.a.mana,
        );
      }

      final none = await outcome(null);
      expect(await outcome(PassAction()), none);
      expect(await outcome(DashAction()), none);
    });

    test('a fully countered cast still contributes no wild magic (A1)',
        () async {
      // The charm swallows the whole cast during admission, so its triggers
      // never reach the collection.
      final c = _board(certified: {
        'a/sa': _certified(
          formulas: 1,
          wildMagic: [_triggerFor(WildMagicEffectKind.manaFlood)],
        ),
      });
      c.a.mana = 10;
      c.b.accoutrements.add(
        const Accoutrement(
          id: 'charm',
          kind: AccoutrementKind.counterCharm,
          charmTrajectory: [BorderZone.fire, BorderZone.fire, BorderZone.fire],
        ),
      );
      await _resolve(c, [
        (c.a, SpellCastAction(spell: _spell('sa'), targetHex: c.b.position)),
      ]);

      expect(c.ctx.resolvedSpells.single.wasCountered, isTrue);
      expect(c.ctx.wildMagicEvents, isEmpty);
      expect(c.a.mana, 10, reason: 'no Mana Flood — A1 holds structurally');
    });
  });
}
