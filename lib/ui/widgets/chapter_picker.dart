// SPDX-License-Identifier: GPL-3.0-or-later
//
// chapter_picker.dart — a labeled dropdown for choosing a ChapterAsset,
// auto-selecting the saved active chapter (or the only one, if there's just
// one). Extracted from solo_practice_settings_screen.dart so the LAN duel
// lobby flow can present the same picker without duplicating the
// load/auto-select logic (LAN_BATTLE_WIREUP_PLAN.md §3.3).
//
// Controlled widget: the owning screen holds the selected ChapterAsset in
// its own state and passes it back in via [selected]; this widget only
// fires [onChanged] with a new value (including the auto-selected one, once,
// after loading) and never sets internal selection state on its own.

import 'package:flutter/material.dart';

import '../../apprentice/apprenticeship.dart' show MasterLoanView;
import '../../spells/chapter_asset.dart';
import '../manuscript_theme.dart';

class ChapterPicker extends StatefulWidget {
  const ChapterPicker({super.key, required this.selected, required this.onChanged});

  final ChapterAsset? selected;
  final ValueChanged<ChapterAsset?> onChanged;

  @override
  State<ChapterPicker> createState() => _ChapterPickerState();
}

class _ChapterPickerState extends State<ChapterPicker> {
  List<ChapterAsset> _chapters = [];
  MasterLoanView _masterLoan = MasterLoanView.none;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final chapters = await ChapterAsset.loadAll();
    final activeId = await ChapterAsset.loadActiveChapterId();
    final masterLoan = await MasterLoanView.load();
    if (!mounted) return;
    ChapterAsset? active;
    if (activeId != null) {
      final matches = chapters.where((c) => c.id == activeId);
      if (matches.isNotEmpty) active = matches.first;
    }
    active ??= chapters.length == 1 ? chapters[0] : null;
    setState(() {
      _chapters = chapters;
      _masterLoan = masterLoan;
      _loading = false;
    });
    if (widget.selected == null && active != null) {
      widget.onChanged(active);
    }
  }

  @override
  Widget build(BuildContext context) {
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
              color: widget.selected != null
                  ? kInkColor.withValues(alpha: 0.4)
                  : kInkMutedColor.withValues(alpha: 0.35),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    'Loading...',
                    style: TextStyle(fontFamily: 'serif', color: kInkMutedColor),
                  ),
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<ChapterAsset?>(
                    value: widget.selected,
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
                    onChanged: widget.onChanged,
                  ),
                ),
        ),
        // A chapter lent by a master is playable but time-limited
        // (MASTER_APPRENTICE_PLAN.md §8) — and once it lapses its spells stop
        // passing localIdentityMayUse, so carrying it into a duel unwarned
        // would look like the game losing the player's spells mid-match.
        if (_masterLoan.isChapterFromMaster(widget.selected?.id)) ...[
          const SizedBox(height: 6),
          Text(
            _masterLoan.record!.isLapsed()
                ? "Lent by your master · lapsed — these spells will no longer cast"
                : 'Lent by your master · ${_masterLoan.remainingLabel()}',
            style: manuscriptCaptionStyle(
              color: _masterLoan.record!.isLapsed() ? kRubricRed : kIlluminationGold,
            ),
          ),
        ],
      ],
    );
  }
}
