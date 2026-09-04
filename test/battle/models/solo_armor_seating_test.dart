// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_armor_seating_test.dart — the chapter's equipped Aetherial Armor
// reaches a solo/practice wizard, and means the same thing there as in a duel
// (engine v16, docs/AETHERIAL_ARMOR.md §14).
//
// These began as characterization tests pinning the bug: `buildSoloBattleState`
// never received an armor, so the local `WizardAvatar` was built with the field
// at its default null and every armor term — all four ladders and both live
// keywords — was silently absent from practice. The melee arithmetic
// (`1 + (actor.armor?.meleeBonus ?? 0)`) was correct throughout; the operand
// was empty. Each `TODAY:` assertion is now inverted into the intended
// behaviour, and the tests that were already true (the ladder thresholds, the
// duel path) are kept unchanged as the controls that proved the original
// report was not a threshold misunderstanding.
//
// Every claim about a bonus is BEHAVIOURAL — damage actually dealt, HP actually
// opened at, a keyword's effect actually landing — not "a field is set", for
// the reason armor_numerical_effects_test.dart's header gives.
//
// The one thing deliberately NOT fixed and pinned here as a follow-up: solo
// hardcodes `baseSpellRange: 3` where the duel seat uses `config.baseRange`.
// Untouched by this change and recorded so the armor fix cannot silently ride
// along with it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rune_duel/battle/engine/armor_certification.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/duel_battle_setup.dart';
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/solo_battle_setup.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/armor_summary.dart' show localCertifiedArmor;
import 'package:rune_duel/spells/chapter_armor.dart' show resolveEquippedArmor;
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/spells/spell_asset.dart';

import 'certified_armor_fixture.dart';
import '../../spells/armor_fixture.dart';
import '../../spells/fake_path_provider.dart';

const MatchConfig _config = MatchConfig();

/// The device-forged fixture from docs/AETHERIAL_ARMOR.md §12: the Pixel's
/// `Charger Plate`, certified `T=12 F/A/W/E=4/2/0/0 melee=+1 kw=[charger]`.
/// Four fires reach the melee ladder's first rung while three CONSECUTIVE
/// fires leave Cleave absent, so the punch's second point cannot be confused
/// with a keyword.
const String _chargerPlateCodes = 'FFFAFA';
const List<BorderZone> _chargerPlateElements = [
  BorderZone.fire,
  BorderZone.fire,
  BorderZone.fire,
  BorderZone.air,
  BorderZone.fire,
  BorderZone.air,
];

/// `WEWE` — the minimal Muddy armor from the same gate: two earths put it on
/// the Earth ladder's first rung (+2 HP) and nothing else.
const String _muddyPlateCodes = 'WEWE';

const String _localHex =
    '0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a00000013';
const String _peerHex =
    '0x00000000000000000000000000000000000000000000000000000000000000ff';

/// The owner every `armorAsset` fixture proof is bound to. Certification
/// checks the certified `owner_pubkey` against the wearer, so a solo test must
/// wear its own armor.
final String _fixtureOwnerHex = '0x${'0' * 64}';

ChapterAsset _chapter({String? armorSpellId, List<ArtifactEntry> artifacts = const []}) =>
    ChapterAsset(
      id: 'ch_practice',
      name: 'Practice',
      createdAt: DateTime.utc(2026, 9, 4),
      armorSpellId: armorSpellId,
      artifacts: artifacts,
    );

/// Stands the two avatars of [state] next to each other at the middle of the
/// board so a punch is legal, without changing anything the setup functions
/// decided about equipment. Positions are the one thing these tests move.
void _standAdjacent(BattleState state, String actorId, String targetId) {
  final actor = state.avatars.firstWhere((a) => a.playerId == actorId);
  final target = state.avatars.firstWhere((a) => a.playerId == targetId);
  actor.position = const HexCoord(0, 0);
  target.position = const HexCoord(1, 0);
  state.battlefield.occupancy[actorId] = actor.position;
  state.battlefield.occupancy[targetId] = target.position;
}

/// One real Phase-4b melee round, as armor_numerical_effects_test drives it.
Future<void> _punch(BattleState state, String actorId, HexCoord target) async {
  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: actorId,
    meleeTargetPicker: (_) async => target,
  );
  await loop.runTurn(TurnInput(action: PassAction()));
}

WizardAvatar _local(SoloBattleSetup setup) =>
    setup.state.avatars.firstWhere((a) => a.playerId == 'local');

void main() {
  // ── 1. The ladder and its first rung ────────────────────────────────────
  //
  // Kept from the investigation: these ruled out "the playtest armor never
  // reached the first rung" BEFORE the seat was blamed, and they are what
  // makes the melee regression below a statement about seating rather than
  // about arithmetic. Neither formula nor threshold is touched by this change.

  group('the melee ladder and its first rung', () {
    test('four fires reach the first rung: +1 melee', () {
      final armor = armorOf('FFFF');
      expect(armor.fireCount, 4);
      expect(armor.meleeBonus, 1);
    });

    test('three fires do NOT — the rung is count: 4, not 3', () {
      final armor = armorOf('FFF');
      expect(armor.fireCount, 3);
      expect(armor.meleeBonus, 0,
          reason: 'a 3-fire armor legitimately punches for the base 1');
    });

    test('the §12 hardware fixture Charger Plate certifies +1 melee', () {
      final armor = armorOf(_chargerPlateCodes);
      expect(armor.fireCount, 4);
      expect(armor.airCount, 2);
      expect(armor.meleeBonus, 1);
    });

    test('the same reading comes off a persisted asset through the library '
        'preview path the player actually sees', () {
      final armor = localCertifiedArmor(armorAsset(
        id: 'armor_charger',
        name: 'Charger Plate',
        elements: _chargerPlateElements,
        t: 12,
      ));
      expect(armor, isNotNull);
      expect(armor!.meleeBonus, 1,
          reason: 'the library card promises +1 melee before the battle starts');
    });
  });

  // ── 2. The duel seat, unchanged ─────────────────────────────────────────
  //
  // The control. Nothing in this change touches buildDuelBattleState, the
  // armor envelope, peer verification or the pubkey-ordered seating; these
  // pass identically before and after, and are what solo is measured against.

  group('buildDuelBattleState seats armor (unchanged)', () {
    test('the certified armor lands on the local avatar', () {
      final setup = buildDuelBattleState(
        config: _config,
        localArtifacts: const [],
        peerArtifacts: const [],
        localOwnerHex: _localHex,
        peerOwnerHex: _peerHex,
        localArmor: armorOf(_chargerPlateCodes),
      );
      final local =
          setup.state.avatars.firstWhere((a) => a.playerId == _localHex);
      expect(local.armor, isNotNull);
      expect(local.armor!.meleeBonus, 1);
    });

    test('and the punch is 1 + 1 = 2', () async {
      final setup = buildDuelBattleState(
        config: _config,
        localArtifacts: const [],
        peerArtifacts: const [],
        localOwnerHex: _localHex,
        peerOwnerHex: _peerHex,
        localArmor: armorOf(_chargerPlateCodes),
      );
      _standAdjacent(setup.state, _localHex, _peerHex);
      final foe = setup.state.avatars.firstWhere((a) => a.playerId == _peerHex);
      final before = foe.hp;
      await _punch(setup.state, _localHex, foe.position);
      expect(before - foe.hp, 2, reason: '1 base + 1 Fire armor');
    });
  });

  // ── 3. The solo seat, fixed ─────────────────────────────────────────────

  group('buildSoloBattleState seats the equipped armor', () {
    test('the certified armor reaches the local practice wizard', () {
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_charger'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(_chargerPlateCodes),
      );
      final local = _local(setup);
      expect(local.armor, isNotNull);
      expect(local.armor!.meleeBonus, 1);
    });

    test('Fire: the punch is 1 base + 1 armor = 2, through the real TurnLoop',
        () async {
      // The reported symptom, inverted. The actor walks nowhere this turn, so
      // no Charger distance bonus qualifies and the 2 is unambiguously
      // 1 + meleeBonus.
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_charger'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(_chargerPlateCodes),
      );
      _standAdjacent(setup.state, 'local', 'dummy');
      final dummy =
          setup.state.avatars.firstWhere((a) => a.playerId == 'dummy');
      final before = dummy.hp;
      await _punch(setup.state, 'local', dummy.position);
      expect(before - dummy.hp, 2,
          reason: 'the bug was a flat 1 here — a certified +1 armor now lands');
    });

    test('Earth: opening HP is config.playerHp + armorHpBonus', () {
      final armor = armorOf(_muddyPlateCodes);
      expect(armor.armorHpBonus, 2, reason: 'two earths, first Earth rung');
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_muddy'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armor,
      );
      expect(_local(setup).hp, _config.playerHp + 2);
      expect(_local(setup).hp, 26, reason: 'the §12 hardware reading, 24 + 2');
    });

    test('Earth: the dummy is NOT given the bonus', () {
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_muddy'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(_muddyPlateCodes),
      );
      final dummy =
          setup.state.avatars.firstWhere((a) => a.playerId == 'dummy');
      expect(dummy.armor, isNull);
      expect(dummy.hp, _config.playerHp,
          reason: 'the practice dummy has no chapter to equip from');
    });

    test('Air: the live effectiveMoveSpeed getter now observes the armor', () {
      final bare = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex);
      final armored = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_air'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(kAirArmorCodes),
      );
      expect(_local(armored).effectiveMoveSpeed,
          _local(bare).effectiveMoveSpeed + 1);
    });

    test('Water: the live effectiveSpellRange getter now observes the armor',
        () {
      final bare = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex);
      final armored = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_water'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(kWaterArmorCodes),
      );
      expect(_local(armored).effectiveSpellRange,
          _local(bare).effectiveSpellRange + 1);
    });

    test('Keyword: Muddy can operate in solo at last — its punch slows',
        () async {
      // Muddy buys into the EXISTING Earth-haymaker slow. In solo it could
      // never fire at all, because the keyword is read off an armor that was
      // never seated. Asserted as the effect landing on the victim, not as a
      // flag being true.
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_muddy'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(_muddyPlateCodes),
      );
      final local = _local(setup);
      expect(local.hasHaymakerSlow, isTrue);

      _standAdjacent(setup.state, 'local', 'dummy');
      final dummy =
          setup.state.avatars.firstWhere((a) => a.playerId == 'dummy');
      final speedBefore = dummy.effectiveMoveSpeed;
      await _punch(setup.state, 'local', dummy.position);

      expect(
        dummy.activeStatusEffects
            .where((fx) => fx.effectTypeId == StatusEffectId.speedDown),
        hasLength(1),
        reason: 'exactly one slow, the Earth haymaker\'s own, not a second '
            'armor-specific status',
      );
      expect(dummy.effectiveMoveSpeed, speedBefore - 1);
    });

    test('Keyword: Charger can operate in solo — it buys the distance bonus',
        () {
      final setup = buildSoloBattleState(
        _chapter(armorSpellId: 'armor_charger'),
        _config,
        localOwnerPubkeyHex: _localHex,
        armor: armorOf(_chargerPlateCodes),
      );
      expect(_local(setup).hasHaymakerDistanceBonus, isTrue,
          reason: 'null armor could never grant this in solo');
    });
  });

  // ── 4. No armor: nothing moves ──────────────────────────────────────────

  group('a chapter with no armor is unchanged', () {
    test('the local wizard is armourless and opens on the bare config HP', () {
      final setup = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex);
      final local = _local(setup);
      expect(local.armor, isNull);
      expect(local.hp, _config.playerHp);
      expect(local.hasHaymakerSlow, isFalse);
      expect(local.hasHaymakerDistanceBonus, isFalse);
    });

    test('and its punch is still exactly the base 1', () async {
      final setup = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex);
      _standAdjacent(setup.state, 'local', 'dummy');
      final dummy =
          setup.state.avatars.firstWhere((a) => a.playerId == 'dummy');
      final before = dummy.hp;
      await _punch(setup.state, 'local', dummy.position);
      expect(before - dummy.hp, 1,
          reason: 'the bit-identical case across the v15 -> v16 bump');
    });

    test('the whole canonical state is byte-identical with and without the '
        'armor parameter omitted', () {
      final omitted = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex);
      final explicitNull = buildSoloBattleState(_chapter(), _config,
          localOwnerPubkeyHex: _localHex, armor: null);
      expect(omitted.state.toCanonicalBytes(),
          explicitNull.state.toCanonicalBytes());
    });
  });

  // ── 5. The derivation is the certified one ──────────────────────────────

  group('solo armor is derived exactly as duel setup derives it', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await installFakePathProvider();
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<SpellAsset> saveArmor({
      String id = 'armor_charger',
      List<BorderZone> elements = _chargerPlateElements,
      bool isArmor = true,
      int t = 12,
    }) async {
      final asset = armorAsset(
        id: id, name: 'Charger Plate', elements: elements, t: t,
        isArmor: isArmor,
      );
      await asset.save();
      return asset;
    }

    test('certifyEquippedChapterArmor agrees with certifyOwnArmor over the '
        'same resolved asset', () async {
      final asset = await saveArmor();
      final chapter = _chapter(armorSpellId: asset.id);

      final viaChapter = await certifyEquippedChapterArmor(
        chapter: chapter,
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
      final viaAsset = certifyOwnArmor(
        armor: await resolveEquippedArmor(chapter),
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        ordinaryArtifactCount: chapter.ordinaryArtifactCount,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
      expect(viaChapter, isNotNull);
      expect(viaChapter.toString(), viaAsset.toString(),
          reason: 'one derivation, not a solo-only reading');
      expect(viaChapter!.meleeBonus, 1);
      expect(viaChapter.keywords, contains(ArmorKeyword.charger));
    });

    test('it matches CertifiedArmor.fromOutputs over the same proof, not an '
        'authored preview', () async {
      // The fixture's authored `formula`/`supremeTags`/`manaCost` deliberately
      // CONTRADICT its proof (see armor_fixture.dart). A reading that agreed
      // with them would be reading metadata; this one reads the trajectory.
      final asset = await saveArmor();
      final certified = await certifyEquippedChapterArmor(
        chapter: _chapter(armorSpellId: asset.id),
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
      expect(certified.toString(), localCertifiedArmor(asset).toString());
      expect(asset.supremeTags, contains('earth'),
          reason: 'the authored metadata says Earth...');
      expect(certified!.earthCount, 0, reason: '...and the proof says none');
      expect(certified.fireCount, 4);
    });

    test('a chapter with no binding certifies to null and starts normally',
        () async {
      final armor = await certifyEquippedChapterArmor(
        chapter: _chapter(),
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
      expect(armor, isNull);
    });

    test('the leyline reaches the keyword derivation', () async {
      // The lexicon is the ONE thing a leyline moves (audit R-8): same proof,
      // same numbers, a different keyword set. Pinned so solo cannot quietly
      // fall back to the ordinary tradition.
      final asset = await saveArmor();
      final chapter = _chapter(armorSpellId: asset.id);
      final ordinary = await certifyEquippedChapterArmor(
        chapter: chapter,
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
      final mutable = await certifyEquippedChapterArmor(
        chapter: chapter,
        wearerOwnerPubkeyHex: _fixtureOwnerHex,
        lexicon: ArmorLexicon.of(LeylineConfig.mutable(
          communitySeed: 'a-different-tradition',
          formulaLength: 4,
        )),
      );
      expect(mutable!.meleeBonus, ordinary!.meleeBonus,
          reason: 'stat ladders are identical under every leyline');
      expect(mutable.fireCount, ordinary.fireCount);
    });

    // ── 6. Fail closed ───────────────────────────────────────────────────

    test('a dangling armor binding throws rather than starting armourless',
        () async {
      await expectLater(
        certifyEquippedChapterArmor(
          chapter: _chapter(armorSpellId: 'armor_that_was_deleted'),
          wearerOwnerPubkeyHex: _fixtureOwnerHex,
          lexicon: ArmorLexicon.of(_config.leyline),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('no longer in the library'))),
      );
    });

    test('an asset that is not marked as armor is refused', () async {
      final asset = await saveArmor(id: 'not_armor', isArmor: false);
      await expectLater(
        certifyEquippedChapterArmor(
          chapter: _chapter(armorSpellId: asset.id),
          wearerOwnerPubkeyHex: _fixtureOwnerHex,
          lexicon: ArmorLexicon.of(_config.leyline),
        ),
        throwsA(isA<ArmorCertificationException>()),
      );
    });

    test('an armor bound to another wizard\'s Runekey is refused', () async {
      final asset = await saveArmor();
      await expectLater(
        certifyEquippedChapterArmor(
          chapter: _chapter(armorSpellId: asset.id),
          wearerOwnerPubkeyHex: _localHex, // not the fixture's owner
          lexicon: ArmorLexicon.of(_config.leyline),
        ),
        throwsA(isA<ArmorCertificationException>().having(
            (e) => e.reason, 'reason', contains('another wizard'))),
      );
    });

    test('an over-budget loadout is refused on the CERTIFIED slot cost',
        () async {
      // T=48 -> 12 slots, which alone fills the budget; one ordinary artifact
      // tips it over. Recomputed from the proof, never from a stored cost.
      final asset = await saveArmor(id: 'armor_huge', t: 48);
      await expectLater(
        certifyEquippedChapterArmor(
          chapter: _chapter(
            armorSpellId: asset.id,
            artifacts: const [ArtifactEntry(kind: ArtifactKind.manaGem)],
          ),
          wearerOwnerPubkeyHex: _fixtureOwnerHex,
          lexicon: ArmorLexicon.of(_config.leyline),
        ),
        throwsA(isA<ArmorCertificationException>().having(
            (e) => e.reason, 'reason', contains('slot limit'))),
      );
    });
  });

  // ── 7. Both solo entry points ───────────────────────────────────────────
  //
  // Solo Practice and the Spell Test Lab are the only two callers of
  // buildSoloBattleState, and the bug is exactly what happens when one of them
  // does not resolve the equipment. A widget harness for each would be a heavy
  // way to say "it calls the shared function", so this reads the two sources
  // instead: narrow, but it makes an independent regression in either caller
  // fail loudly rather than silently reintroducing an armourless practice run.

  group('both solo entry points go through the shared certification', () {
    const paths = {
      'Solo Practice': 'lib/ui/solo_practice_settings_screen.dart',
      'Spell Test Lab': 'lib/ui/spell_test_lab_screen.dart',
    };

    for (final entry in paths.entries) {
      test('${entry.key} certifies and passes the armor', () {
        final src = File(entry.value).readAsStringSync();
        expect(src, contains('certifyEquippedChapterArmor'),
            reason: '${entry.key} must use the ONE shared resolve+certify path');
        expect(src, contains('ArmorLexicon.of('),
            reason: '${entry.key} must pass the match leyline, never default it');
        expect(src, contains('armor: armor'),
            reason: '${entry.key} must hand the result to buildSoloBattleState');
        expect(src, contains('ArmorCertificationException'),
            reason: '${entry.key} must fail closed on an uncertifiable armor');
        expect(src, isNot(contains('previewFromElementSequence')),
            reason: 'preview semantics must never reach a battle');
      });
    }

    test('duel setup and solo share the one binding resolver', () {
      final duel = File('lib/battle/networking/duel_setup.dart').readAsStringSync();
      expect(duel, contains('resolveEquippedArmor'));
      expect(duel, isNot(contains('_resolveEquippedArmor')),
          reason: 'the private copy was lifted into chapter_armor.dart');
    });
  });

  // ── 8. Recorded follow-up, deliberately not fixed ───────────────────────

  group('follow-up: solo baseSpellRange divergence (NOT fixed here)', () {
    test('solo still hardcodes 3 where the duel seat uses config.baseRange',
        () {
      const config = MatchConfig(baseRange: 5);
      final solo = buildSoloBattleState(_chapter(), config,
          localOwnerPubkeyHex: _localHex);
      expect(_local(solo).baseSpellRange, 3,
          reason: 'out of scope for the armor fix; recorded so it is not lost');

      final duel = buildDuelBattleState(
        config: config,
        localArtifacts: const [],
        peerArtifacts: const [],
        localOwnerHex: _localHex,
        peerOwnerHex: _peerHex,
      );
      expect(
          duel.state.avatars
              .firstWhere((a) => a.playerId == _localHex)
              .baseSpellRange,
          5);
    });
  });
}
