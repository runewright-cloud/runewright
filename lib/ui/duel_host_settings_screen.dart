// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_host_settings_screen.dart — the host's chapter + match-settings step
// for a LAN duel (LAN_BATTLE_WIREUP_PLAN.md §3.3, DECISION 3: host authors
// the MatchConfig, the guest adopts it verbatim). Shown before hosting
// begins; pops its result back to BattleLobbyScreen, which then starts
// advertising and — once a guest connects — runs `runDuelSetup` with this
// chapter/config.
//
// Mirrors solo_practice_settings_screen.dart's settings UI (same steppers,
// same chapter picker) via the shared widgets in ui/widgets/ — this is not a
// copy-paste of that screen, just the same controls repurposed for a
// pre-connection step rather than a start-battle-immediately button.

import 'package:flutter/material.dart';

import '../battle/models/match_config.dart';
import '../battle/models/leyline_config.dart'
    show LeylineConfig, kDefaultCommunitySeed, normalizeCommunitySeed;
import '../identity/identity.dart';
import '../spells/chapter_asset.dart';
import 'manuscript_theme.dart';
import 'widgets/chapter_picker.dart';
import 'widgets/component_toggles.dart';
import 'widgets/int_stepper_row.dart';
import 'safe_layout.dart';

/// What the host picked — chapter for its own artifact loadout, config for
/// the whole match (both sides' shared HP/grid/sorcerer settings).
typedef DuelHostSettings = ({ChapterAsset chapter, MatchConfig config});

class DuelHostSettingsScreen extends StatefulWidget {
  const DuelHostSettingsScreen({super.key});

  @override
  State<DuelHostSettingsScreen> createState() => _DuelHostSettingsScreenState();
}

class _DuelHostSettingsScreenState extends State<DuelHostSettingsScreen> {
  ChapterAsset? _selectedChapter;

  int _hp = 24;
  int _gridRadius = 4;

  // Spell components (docs/SPELL_COMPONENTS_PLAN.md §1). Three flags, not one
  // — the two components have different trust properties and different
  // hardware, so a player has real reason to want one without the other.
  bool _vocalComponents = false;
  bool _somaticComponents = false;
  bool _simultaneousCasting = false;

  /// The leyline seed word this duel runs under. Prefilled from the device's
  /// own saved word (Settings) but editable here, because the host is
  /// authoritative over the whole MatchConfig (DECISION 3) and two travelling
  /// players may want to duel under one agreed tradition for a single match
  /// without either of them permanently rotating their own.
  final _seedController = TextEditingController(text: kDefaultCommunitySeed);

  static const _hpMin = 8;
  static const _hpMax = 48;
  static const _hpStep = 4;
  static const _gridRadiusMin = 2;
  static const _gridRadiusMax = 6;

  @override
  void initState() {
    super.initState();
    // Guarded: secure storage has no platform channel under `flutter test`,
    // and an unhandled rejection here would fail unrelated widget tests. A
    // failure just leaves the default word in the field.
    Identity.loadCommunitySeed().then((seed) {
      if (!mounted || seed == null) return;
      setState(() => _seedController.text = seed);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  MatchConfig get _config => MatchConfig(
        playerHp: _hp,
        gridRadius: _gridRadius,
        maxPlayers: 2,
        vocalComponents: _vocalComponents,
        somaticComponents: _somaticComponents,
        simultaneousCasting: _simultaneousCasting,
        // Ordinary grammar. The host settings screen deliberately exposes
        // only the seed word for now; a mutable-leyline picker arrives with
        // the behaviour that backs it (LEYLINE_SEED_PLAN.md §16).
        leyline: LeylineConfig.ordinary(_seedController.text.trim()),
      );

  void _onReady() {
    final chapter = _selectedChapter;
    if (chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Chapter Selected')),
      );
      return;
    }
    Navigator.pop<DuelHostSettings>(context, (chapter: chapter, config: _config));
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
          'HOST SETTINGS',
          style: manuscriptHeaderStyle(fontSize: 20, color: kParchmentColor),
        ),
      ),
      body: SafeScreenBody(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          // The settings above HOST are taller than a phone screen, and a
          // Spacer cannot absorb a negative remainder: once they overflowed,
          // the HOST button was pushed off the bottom and the screen became a
          // dead end. Scrolling the settings and pinning the button keeps the
          // layout identical wherever it already fitted.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ChapterPicker(
                        selected: _selectedChapter,
                        onChanged: (c) => setState(() => _selectedChapter = c),
                      ),
                      const SizedBox(height: 24),
                      Divider(color: kInkColor.withValues(alpha: 0.12)),
                      const SizedBox(height: 20),
                      IntStepperRow(
                        label: 'STARTING HP',
                        value: _hp,
                        min: _hpMin,
                        max: _hpMax,
                        step: _hpStep,
                        onChanged: (v) => setState(() => _hp = v),
                      ),
                      const SizedBox(height: 28),
                      IntStepperRow(
                        label: 'GRID SIZE',
                        caption: 'Radius of the battlefield in tiles',
                        value: _gridRadius,
                        min: _gridRadiusMin,
                        max: _gridRadiusMax,
                        step: 1,
                        onChanged: (v) => setState(() => _gridRadius = v),
                      ),
                      const SizedBox(height: 28),
                      _buildComponentToggles(),
                      const SizedBox(height: 28),
                      _buildSeedWordField(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
                    'HOST',
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

  /// The leyline seed word for this duel. The guest adopts it verbatim with
  /// the rest of the host's config (DECISION 3), and is told which tradition
  /// they're dueling under if it differs from their own (BattleLobbyScreen).
  Widget _buildSeedWordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('LEYLINE SEED WORD', style: manuscriptCaptionStyle()),
        const SizedBox(height: 2),
        Text(
          'The tradition this duel is fought under — it decides '
          'every spell’s wild magic',
          style: manuscriptCaptionStyle(
            color: kInkMutedColor.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _seedController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4),
        // Echo the normalized form so "Rivendell!" → rivendell is never a
        // surprise at the point it starts mattering.
        Text(
          'Reads as: ${normalizeCommunitySeed(_seedController.text)}',
          style: manuscriptCaptionStyle(
            color: kInkMutedColor.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _buildComponentToggles() => ComponentToggles(
        vocalComponents: _vocalComponents,
        somaticComponents: _somaticComponents,
        simultaneousCasting: _simultaneousCasting,
        onVocalChanged: (v) => setState(() => _vocalComponents = v),
        onSomaticChanged: (v) => setState(() => _somaticComponents = v),
        onSimultaneousChanged: (v) =>
            setState(() => _simultaneousCasting = v),
      );
}
