// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_practice_settings_screen.dart — match settings for solo practice,
// no network required. Hands off a MatchConfig to the battle screen once
// the turn loop is implemented; for now routes to the match-starting stub.

import 'package:flutter/material.dart';

import '../battle/models/match_config.dart';
import '../battle/models/solo_battle_setup.dart';
import '../spells/chapter_asset.dart';
import 'battle_screen.dart';
import 'manuscript_theme.dart';

class SoloPracticeSettingsScreen extends StatefulWidget {
  const SoloPracticeSettingsScreen({super.key});

  @override
  State<SoloPracticeSettingsScreen> createState() =>
      _SoloPracticeSettingsScreenState();
}

class _SoloPracticeSettingsScreenState
    extends State<SoloPracticeSettingsScreen> {
  List<ChapterAsset> _chapters = [];
  ChapterAsset? _selectedChapter;
  bool _loadingChapters = true;

  int _hp = 24;
  int _gridRadius = 4;
  bool _sorcererMode = false;

  static const _hpMin = 8;
  static const _hpMax = 48;
  static const _hpStep = 4;
  static const _gridRadiusMin = 2;
  static const _gridRadiusMax = 6;

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  Future<void> _loadChapters() async {
    final chapters = await ChapterAsset.loadAll();
    final activeId = await ChapterAsset.loadActiveChapterId();
    if (!mounted) return;
    ChapterAsset? active;
    if (activeId != null) {
      final matches = chapters.where((c) => c.id == activeId);
      if (matches.isNotEmpty) active = matches.first;
    }
    active ??= chapters.length == 1 ? chapters[0] : null;
    setState(() {
      _chapters = chapters;
      _selectedChapter = active;
      _loadingChapters = false;
    });
  }

  MatchConfig get _config => MatchConfig(
        playerHp: _hp,
        gridRadius: _gridRadius,
        maxPlayers: 2,
        sorcererMode: _sorcererMode,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CHAPTER', style: manuscriptCaptionStyle()),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: kParchmentPanelColor,
            border: Border.all(
              color: _selectedChapter != null
                  ? kInkColor.withValues(alpha: 0.4)
                  : kInkMutedColor.withValues(alpha: 0.35),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: _loadingChapters
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    'Loading...',
                    style: TextStyle(fontFamily: 'serif', color: kInkMutedColor),
                  ),
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<ChapterAsset?>(
                    value: _selectedChapter,
                    isExpanded: true,
                    dropdownColor: kParchmentPanelColor,
                    style: const TextStyle(
                      fontFamily: 'serif',
                      fontSize: 16,
                      color: kInkColor,
                    ),
                    items: [
                      const DropdownMenuItem<ChapterAsset?>(
                        value: null,
                        child: Text(
                          'Select Chapter',
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 16,
                            color: kInkMutedColor,
                          ),
                        ),
                      ),
                      for (final c in _chapters)
                        DropdownMenuItem<ChapterAsset?>(
                          value: c,
                          child: Text(
                            c.name,
                            style: const TextStyle(
                              fontFamily: 'serif',
                              fontSize: 16,
                              color: kInkColor,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (c) => setState(() => _selectedChapter = c),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildHpStepper() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STARTING HP', style: manuscriptCaptionStyle()),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              icon: Icons.remove,
              onTap: _hp > _hpMin
                  ? () => setState(() => _hp -= _hpStep)
                  : null,
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: 48,
              child: Text(
                '$_hp',
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 24),
            _StepButton(
              icon: Icons.add,
              onTap: _hp < _hpMax
                  ? () => setState(() => _hp += _hpStep)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGridRadiusStepper() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('GRID SIZE', style: manuscriptCaptionStyle()),
        const SizedBox(height: 2),
        Text(
          'Radius of the battlefield in tiles',
          style: manuscriptCaptionStyle(color: kInkMutedColor.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              icon: Icons.remove,
              onTap: _gridRadius > _gridRadiusMin
                  ? () => setState(() => _gridRadius--)
                  : null,
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: 48,
              child: Text(
                '$_gridRadius',
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: kInkColor,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 24),
            _StepButton(
              icon: Icons.add,
              onTap: _gridRadius < _gridRadiusMax
                  ? () => setState(() => _gridRadius++)
                  : null,
            ),
          ],
        ),
      ],
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

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BattleScreen(
          state: setup.state,
          localPlayerId: localId,
          chapter: chapter,
        ),
      ),
    );
  }
}

// ── Shared small widgets ──────────────────────────────────────────────────────

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          border: Border.all(
            color: enabled
                ? kInkColor.withValues(alpha: 0.4)
                : kInkMutedColor.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? kInkColor : kInkMutedColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

