// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_practice_settings_screen.dart — match settings for solo practice,
// no network required. Hands off a MatchConfig to the battle screen once
// the turn loop is implemented; for now routes to the match-starting stub.

import 'package:flutter/material.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../battle/models/match_config.dart';
import '../battle/models/solo_battle_setup.dart';
import '../battle/models/wild_magic_effect.dart' show kDefaultCommunitySeed;
import '../identity/identity.dart';
import '../battle/networking/solo_battle_session.dart';
import '../spells/chapter_asset.dart';
import 'battle_screen.dart';
import 'manuscript_theme.dart';
import 'widgets/chapter_picker.dart';
import 'widgets/int_stepper_row.dart';

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
  bool _sorcererMode = false;

  /// Solo practice runs under the device's own leyline seed word, so wild
  /// magic behaves here exactly as it will in a duel this player hosts.
  String _communitySeed = kDefaultCommunitySeed;

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
      setState(() => _communitySeed = seed);
    }).catchError((_) {});
  }

  MatchConfig get _config => MatchConfig(
        playerHp: _hp,
        gridRadius: _gridRadius,
        maxPlayers: 2,
        sorcererMode: _sorcererMode,
        communitySeed: _communitySeed,
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
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
              _buildSorcererModeToggle(),
              const Spacer(),
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

  Widget _buildSorcererModeToggle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SORCERER MODE', style: manuscriptCaptionStyle()),
              const SizedBox(height: 2),
              Text(
                'Speak the incantation aloud to cast',
                style: manuscriptCaptionStyle(
                    color: kInkMutedColor.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
        Switch(
          value: _sorcererMode,
          activeThumbColor: kIlluminationGold,
          onChanged: (v) => setState(() => _sorcererMode = v),
        ),
      ],
    );
  }

  Widget _buildBeginButton(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: _beginBattle,
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

  void _beginBattle() {
    final chapter = _selectedChapter;
    if (chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Chapter Selected')),
      );
      return;
    }

    const localId = 'local';
    final setup = buildSoloBattleState(chapter, _config, localId: localId);
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

