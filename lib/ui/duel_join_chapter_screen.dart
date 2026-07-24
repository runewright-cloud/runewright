// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_join_chapter_screen.dart — the guest's chapter-only step for a LAN
// duel (LAN_BATTLE_WIREUP_PLAN.md §3.3, DECISION 3). Unlike the host, the
// guest has no match settings to author — it adopts whatever MatchConfig
// the host sends during runDuelSetup — so this screen is just a chapter
// picker, shown before scanning for duels begins.

import 'package:flutter/material.dart';

import '../spells/chapter_asset.dart';
import 'manuscript_theme.dart';
import 'widgets/chapter_picker.dart';

class DuelJoinChapterScreen extends StatefulWidget {
  const DuelJoinChapterScreen({super.key});

  @override
  State<DuelJoinChapterScreen> createState() => _DuelJoinChapterScreenState();
}

class _DuelJoinChapterScreenState extends State<DuelJoinChapterScreen> {
  ChapterAsset? _selectedChapter;

  void _onReady() {
    final chapter = _selectedChapter;
    if (chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Chapter Selected')),
      );
      return;
    }
    Navigator.pop<ChapterAsset>(context, chapter);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kParchmentColor,
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        title: Text(
          'CHOOSE CHAPTER',
          style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ChapterPicker(
                selected: _selectedChapter,
                onChanged: (c) => setState(() => _selectedChapter = c),
              ),
              const Spacer(),
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _onReady,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kIlluminationGold,
                    side: const BorderSide(color: kIlluminationGold, width: 2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text(
                    'SCAN FOR DUELS',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 18,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                      color: kIlluminationGold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
