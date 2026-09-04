// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_practice_settings_screen.dart — match settings for solo practice,
// no network required. Hands off a MatchConfig to the battle screen once
// the turn loop is implemented; for now routes to the match-starting stub.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../battle/engine/armor_certification.dart'
    show ArmorCertificationException, certifyEquippedChapterArmor;
import '../battle/models/certified_armor.dart' show ArmorLexicon, CertifiedArmor;
import '../battle/models/match_config.dart';
import '../battle/models/solo_battle_setup.dart';
import '../battle/models/leyline_config.dart'
    show LeylineConfig, kDefaultCommunitySeed;
import '../identity/identity.dart';
import '../battle/networking/solo_battle_session.dart';
import '../spells/chapter_asset.dart';
import '../spells/wild_magic_preview.dart' show resolveLocalCasterPubkeyHex;
import 'battle_screen.dart';
import 'manuscript_theme.dart';
import 'widgets/chapter_picker.dart';
import 'widgets/component_toggles.dart';
import 'widgets/int_stepper_row.dart';
import 'widgets/leyline_picker.dart';
import 'safe_layout.dart';

class SoloPracticeSettingsScreen extends StatefulWidget {
  const SoloPracticeSettingsScreen({super.key});

  @override
  State<SoloPracticeSettingsScreen> createState() =>
      _SoloPracticeSettingsScreenState();
}

class _SoloPracticeSettingsScreenState
    extends State<SoloPracticeSettingsScreen> {
  ChapterAsset? _selectedChapter;

  int _hp = 24;
  int _gridRadius = 4;

  // Spell components (docs/SPELL_COMPONENTS_PLAN.md §1). The duel lobby's
  // toggles, mirrored here so practice runs under the same rules a duel will.
  // Simultaneous casting is deliberately absent — see the widget below.
  bool _vocalComponents = false;
  bool _somaticComponents = false;

  /// Solo practice runs under the device's own leyline seed word, so wild
  /// magic behaves here exactly as it will in a duel this player hosts.
  String _communitySeed = kDefaultCommunitySeed;

  /// The leyline this practice match is fought under — ordinary by default,
  /// and the ONE place in the app a player can choose a Mutable one
  /// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E; see
  /// `LeylinePicker`'s header for why solo and not the duel host screen).
  ///
  /// Held whole rather than as a `mutable` bool plus a length: the config is
  /// canonical, and a screen that carried the pieces would be a second place
  /// they could be assembled inconsistently.
  LeylineConfig _leyline = LeylineConfig.ordinaryDefault;

  static const _hpMin = 8;
  static const _hpMax = 48;
  static const _hpStep = 4;
  static const _gridRadiusMin = 2;
  static const _gridRadiusMax = 6;

  @override
  void initState() {
    super.initState();
    // Guarded — see DuelHostSettingsScreen.initState for why.
    Identity.loadCommunitySeed().then((seed) {
      if (!mounted || seed == null) return;
      setState(() {
        _communitySeed = seed;
        // Re-seat the leyline on the loaded word, keeping whatever grammar is
        // already chosen. The word arrives asynchronously and the picker may
        // have been touched first, so rebuilding the config is the only way
        // the two cannot drift apart.
        _leyline = _leyline.formulaLength ==
                LeylineConfig.kOrdinaryFormulaLength
            ? LeylineConfig.ordinary(seed)
            : LeylineConfig.mutable(
                communitySeed: seed,
                formulaLength: _leyline.formulaLength,
                noiseDensityPermille: _leyline.noiseDensityPermille,
              );
      });
    }).catchError((_) {});
  }

  MatchConfig get _config => MatchConfig(
        playerHp: _hp,
        gridRadius: _gridRadius,
        maxPlayers: 2,
        vocalComponents: _vocalComponents,
        somaticComponents: _somaticComponents,
        // Whatever the player chose. Solo practice is where a Mutable
        // Leyline is learned: the engine has interpreted them since Slice D,
        // and this is the surface that can now ask for one.
        leyline: _leyline,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text(
          'SOLO PRACTICE',
          style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
        ),
      ),
      body: SafeScreenBody(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          // Same shape, same repair as duel_host_settings_screen.dart: these
          // settings are taller than a phone screen, and a Spacer cannot
          // absorb a negative remainder — BEGIN went off the bottom edge.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildChapterPicker(),
                      const SizedBox(height: 24),
                      Divider(color: kInkColor.withValues(alpha: 0.12)),
                      const SizedBox(height: 20),
                      _buildHpStepper(),
                      const SizedBox(height: 28),
                      _buildGridRadiusStepper(),
                      const SizedBox(height: 28),
                      _buildComponentToggles(),
                      const SizedBox(height: 28),
                      LeylinePicker(
                        communitySeed: _communitySeed,
                        value: _leyline,
                        onChanged: (c) => setState(() => _leyline = c),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildBeginButton(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChapterPicker() {
    return ChapterPicker(
      selected: _selectedChapter,
      onChanged: (c) => setState(() => _selectedChapter = c),
    );
  }

  Widget _buildHpStepper() {
    return IntStepperRow(
      label: 'STARTING HP',
      value: _hp,
      min: _hpMin,
      max: _hpMax,
      step: _hpStep,
      onChanged: (v) => setState(() => _hp = v),
    );
  }

  Widget _buildGridRadiusStepper() {
    return IntStepperRow(
      label: 'GRID SIZE',
      caption: 'Radius of the battlefield in tiles',
      value: _gridRadius,
      min: _gridRadiusMin,
      max: _gridRadiusMax,
      step: 1,
      onChanged: (v) => setState(() => _gridRadius = v),
    );
  }

  /// No simultaneous-casting switch: solo practice has exactly one caster, so
  /// there is nobody to be simultaneous with and nobody to take turns after.
  /// The config it builds leaves the flag at its default, which is harmless —
  /// SoloBattleSession completes the pacing signal immediately either way.
  Widget _buildComponentToggles() => ComponentToggles(
        vocalComponents: _vocalComponents,
        somaticComponents: _somaticComponents,
        simultaneousCasting: false,
        showSimultaneous: false,
        onVocalChanged: (v) => setState(() => _vocalComponents = v),
        onSomaticChanged: (v) => setState(() => _somaticComponents = v),
        onSimultaneousChanged: (_) {},
      );

  Widget _buildBeginButton(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: () => unawaited(_beginBattle()),
        style: OutlinedButton.styleFrom(
          foregroundColor: kIlluminationGold,
          side: const BorderSide(color: kIlluminationGold, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        child: const Text(
          'READY',
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 18,
            letterSpacing: 3,
            fontWeight: FontWeight.w600,
            color: kIlluminationGold,
          ),
        ),
      ),
    );
  }

  Future<void> _beginBattle() async {
    final chapter = _selectedChapter;
    if (chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Chapter Selected')),
      );
      return;
    }

    // Practice must be fought by the REAL local wizard: Wild Magic keys on the
    // caster, so a placeholder identity here would rehearse a spellbook the
    // player does not own (docs/WILD_MAGIC_PLAN_VNEXT.md §2). No key, no
    // practice — there is no honest substitute, and silently seating a stub
    // wizard is exactly the bug this replaced.
    final localOwnerPubkeyHex = await resolveLocalCasterPubkeyHex();
    if (!mounted) return;
    if (localOwnerPubkeyHex == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read your Runekey')),
      );
      return;
    }

    // The chapter's equipped Aetherial Armor, certified from its own proof
    // before any BattleState exists — the same local intake duel setup runs at
    // step 7b, through the same `certifyOwnArmor`. Practice must teach the
    // equipment the player actually has, so this is not optional and not
    // approximated.
    //
    // Fails CLOSED: an unreadable proof, an asset that is not an armor, an
    // over-budget loadout or a binding that no longer resolves all abort the
    // session. There is no peer and so no forfeit to send — the player just
    // does not get an armourless practice run they did not ask for.
    final CertifiedArmor? armor;
    try {
      armor = await certifyEquippedChapterArmor(
        chapter: chapter,
        wearerOwnerPubkeyHex: localOwnerPubkeyHex,
        lexicon: ArmorLexicon.of(_config.leyline),
      );
    } on ArmorCertificationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Armor could not be certified: ${e.reason}')),
      );
      return;
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Armor could not be equipped: ${e.message}')),
      );
      return;
    }
    if (!mounted) return;

    const localId = 'local';
    final setup = buildSoloBattleState(
      chapter,
      _config,
      localOwnerPubkeyHex: localOwnerPubkeyHex,
      armor: armor,
      localId: localId,
    );
    final dummyPos = setup.dummyPosition;
    // "Two squares south" — south is +r at constant q on this hex layout
    // (battlefield_painter's axialToPixel: dy increases with r at q=0), i.e.
    // toward the local player's side of the field. Same target-tile logic
    // as Spell Test Lab's dummy so both practice surfaces behave alike.
    final target = HexCoord(dummyPos.q, dummyPos.r + 2);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BattleScreen(
          state: setup.state,
          localPlayerId: localId,
          chapter: chapter,
          session: SoloBattleSession(
            state: setup.state,
            dummyAutoCast: true,
            dummyCastTarget: target,
          ),
        ),
      ),
    );
  }
}

