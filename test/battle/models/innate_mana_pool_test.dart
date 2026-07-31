// SPDX-License-Identifier: GPL-3.0-or-later
//
// innate_mana_pool_test.dart — 2026-07-30: the "core gem" is gone. A wizard's
// mana pool is innate (MatchConfig.innateManaPool, default 100); Mana Gems are
// purely optional capacity on top, and EVERY gem is destructible.
//
// The three behaviours this pins, each of which was the opposite before:
//   1. A gemless loadout is legal and gets no silently-inserted core gem —
//      the wizard still has a full innate pool.
//   2. There is no innate regen. A gemless wizard passively regains nothing
//      (they meditate instead); gems are the only passive source.
//   3. Burn effects can destroy a wizard's last gem, and maxMana shrinks with
//      it — maxMana is stored state hashed into toCanonicalBytes(), so a
//      stale pool after a burn would desync the two clients.

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/models/accoutrement_loadout.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/solo_battle_setup.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/chapter_asset.dart'
    show ArtifactEntry, ArtifactKind, ChapterAsset;

// ── Helpers ───────────────────────────────────────────────────────────────────

const _config = MatchConfig();

WizardAvatar _avatar(List<AccoutrementKind> kinds) {
  var i = 0;
  final accoutrements = [
    for (final k in kinds) Accoutrement(id: 'a${i++}', kind: k),
  ];
  final av = WizardAvatar(
    playerId: 'w',
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 0,
    maxMana: 0,
    position: const HexCoord(0, 0),
    teamId: 'w',
    baseSpellRange: 3,
    accoutrements: accoutrements,
  );
  av.maxMana = av.maxManaFor(_config);
  av.mana = av.maxMana;
  return av;
}

BattleState _state(WizardAvatar av) {
  final battlefield = Battlefield(radius: 4);
  battlefield.occupancy[av.playerId] = av.position;
  return BattleState(
    config: _config,
    avatars: [av],
    teams: const [],
    battlefield: battlefield,
    tileEffects: const {},
  );
}

ApplyContext _ctx(BattleState state, WizardAvatar av, SpellEffect effect) => ApplyContext(
      descriptor: EffectDescriptor(
        affinity: SpellAffinity.water,
        effectKind: EffectKind.artifactsInteraction,
        spellEffect: effect,
      ),
      targetTile: av.position,
      caster: av,
      state: state,
      rng: Random(7),
    );

void main() {
  group('innate mana pool', () {
    test('a gemless wizard still has the full innate pool', () {
      final av = _avatar(const []);
      expect(av.manaGemsEquipped, 0);
      expect(av.maxManaFor(_config), _config.innateManaPool);
    });

    test('each gem stacks on top of the innate pool', () {
      expect(_avatar(const [AccoutrementKind.manaGem]).maxManaFor(_config),
          _config.innateManaPool + _config.manaGemPoolPerGem);
      expect(
          _avatar(const [AccoutrementKind.manaGem, AccoutrementKind.manaGem])
              .maxManaFor(_config),
          _config.innateManaPool + 2 * _config.manaGemPoolPerGem);
    });

    test('regen comes from gems only — a gemless wizard regenerates nothing', () {
      expect(_avatar(const []).manaRegenFor(_config), 0);
      expect(_avatar(const [AccoutrementKind.manaGem]).manaRegenFor(_config),
          _config.manaGemRegenPerGem);
      expect(
          _avatar(const [AccoutrementKind.manaGem, AccoutrementKind.manaGem])
              .manaRegenFor(_config),
          2 * _config.manaGemRegenPerGem);
    });
  });

  group('loadout conversion inserts nothing', () {
    test('a gem-free artifact list produces a gem-free accoutrement list', () {
      final accoutrements = accoutrementsFromArtifacts(
        const [
          ArtifactEntry(kind: ArtifactKind.bookmark),
          ArtifactEntry(kind: ArtifactKind.rodOfSpreading),
        ],
        idPrefix: 'acc',
      );
      expect(accoutrements, hasLength(2));
      expect(accoutrements.any((a) => a.kind == AccoutrementKind.manaGem), isFalse);
      // Ids stay index-aligned with the declared artifacts — both devices
      // must generate identical ids (they are hashed into the state).
      expect(accoutrements.map((a) => a.id), ['acc_0', 'acc_1']);
    });

    test('solo setup gives a gemless chapter the innate pool and no gem', () {
      final chapter = ChapterAsset(
        id: 'ch_gemless',
        name: 'Gemless',
        createdAt: DateTime.utc(2026, 7, 30),
        artifacts: const [ArtifactEntry(kind: ArtifactKind.bookmark)],
      );
      final setup = buildSoloBattleState(chapter, _config);
      final local = setup.state.avatars.firstWhere((a) => a.playerId == 'local');
      expect(local.manaGemsEquipped, 0);
      expect(local.maxMana, _config.innateManaPool);
    });
  });

  group('burn reaches every gem', () {
    test('a wizard\'s last gem can be burned and the pool shrinks with it', () {
      final av = _avatar(const [AccoutrementKind.manaGem]);
      final state = _state(av);
      expect(av.maxMana, _config.innateManaPool + _config.manaGemPoolPerGem);
      expect(av.mana, av.maxMana);

      EffectApplicator.apply(_ctx(
        state,
        av,
        const ArtifactsInteractionEffect(affinity: SpellAffinity.fire, count: 1),
      ));

      expect(av.manaGemsEquipped, 0, reason: 'no gem is indestructible any more');
      expect(av.maxMana, _config.innateManaPool);
      expect(av.mana, av.maxMana, reason: 'current mana is clamped into the smaller pool');
    });

    test('burning a non-gem artifact leaves the pool alone', () {
      final av = _avatar(const [AccoutrementKind.bookmark]);
      final state = _state(av);
      final maxBefore = av.maxMana;

      EffectApplicator.apply(_ctx(
        state,
        av,
        const ArtifactsInteractionEffect(affinity: SpellAffinity.fire, count: 1),
      ));

      expect(av.accoutrements, isEmpty);
      expect(av.maxMana, maxBefore);
    });
  });
}
