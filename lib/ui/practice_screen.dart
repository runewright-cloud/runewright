// SPDX-License-Identifier: GPL-3.0-or-later
//
// practice_screen.dart — PracticeScreen: drilling ONE library spell's
// incantation. Pure client scaffolding — consensus-invisible, never touches
// the circuit/ZK/lockstep/networking layers.
//
// Reachable only from a spell's card in the library ("Practice Incantation").
// There is deliberately no main-menu entry and no random-formula generator:
// you practise a spell you are trying to learn, not spelling in the abstract.
//
// ENROLLMENT of either kind does not live here — both halves live on Attune
// Spell Components (vocabulary_screen.dart): the Vocal tab, where choosing a
// word and recording it are one staged atomic act, and the Somatic tab, where
// gesture reps are captured. Attuning a component and drilling a spell are
// different acts, and the enrollment tools belong somewhere reachable before
// you own a spell worth drilling. The library gates on
// VocalEnrollment.isPracticeReady and diverts there when a player has too few
// takes to be scored fairly; see library_screen.dart's `_openPracticeForSpell`.

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide Element;
import 'package:record/record.dart';

import '../practice/formula_generator.dart';
import '../sorcerer/vocal_enrollment.dart';
import '../sorcerer/vocal_template_source.dart';
import '../sorcerer/mfcc.dart';
import '../spells/spell_asset.dart';
import 'widgets/hold_to_record_control.dart';
import '../sorcerer/incantation_recall.dart';
import '../sorcerer/incantation_recall_scorer.dart';
import '../sorcerer/vocal_slot.dart';
import '../sorcerer/vocabulary_profile.dart';
import 'safe_layout.dart';

class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key, required this.spell});

  /// The spell being drilled. The incantation is this spell's own (see
  /// PracticeFormula.fromSpellFormula) and the words start concealed — the
  /// drill is recalling them, not reading them.
  final SpellAsset spell;

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  // Created on first playback, not on screen open: constructing an
  // AudioPlayer spins up a native audio session and a per-player event
  // channel, which is wasted work for a player who only records, and is a
  // hard failure under `flutter test` (no audioplayers plugin) for screens
  // that never play a clip.
  AudioPlayer? _playerOrNull;
  AudioPlayer get _player => _playerOrNull ??= AudioPlayer();

  // Enrollment-backed template source (player's own voice per word, Piper
  // fallback until enrolled) — see vocal_enrollment.dart for why same-voice
  // templates are load-bearing for word discrimination. Null until the
  // documents directory resolves in initState. Read-only here: takes are
  // recorded on Attune Spell Components.
  PerUserEnrolledTemplateSource? _templateSource;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  BytesBuilder? _attemptPcm;

  /// The same scorer battle uses — that is the point of a drill. When these
  /// were two different code paths, practising well told you nothing about
  /// whether a cast would land.
  IncantationRecallScorer? _recallScorer;

  /// The last recited attempt, or null before one is made.
  IncantationRecall? _attempt;

  PracticeFormula? _formula;

  /// Whether the word chips are concealed. Starts true on every fresh attempt
  /// (see [_startFormula]) because recalling the sequence *is* the exercise —
  /// revealing is the "show me the answer" escape hatch, and the UI marks the
  /// attempt as revealed so a peeked run doesn't read as a clean one.
  bool _wordsHidden = false;

  /// Set when the player reveals a concealed formula, cleared on restart.
  bool _didReveal = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initEnrollment());
    unawaited(_initVocabulary());
  }

  /// The player's chosen words. Every place this screen shows a word must go
  /// through [_labelFor] rather than [VocalSlot.name] — the enum names slots,
  /// not words (VOCAL_RECALL_PLAN.md §8).
  VocabularyProfile _vocabulary = VocabularyProfile.defaults;

  Future<void> _initVocabulary() async {
    final vocabulary = await VocabularyProfile.load();
    if (!mounted) return;
    setState(() => _vocabulary = vocabulary);
  }

  /// The word this player speaks for [slot].
  String _labelFor(VocalSlot slot) => _vocabulary.labelFor(slot);

  Future<void> _initEnrollment() async {
    final enrollment = await VocalEnrollment.open();
    if (!mounted) return;
    setState(() {
      _templateSource = PerUserEnrolledTemplateSource(enrollment: enrollment);
    });
    // There is nothing to choose on this screen, so load the incantation as
    // soon as there's a template source to score it against — the player lands
    // on a ready drill rather than on a button they'd always press.
    await _newFormula();
  }

  @override
  void dispose() {
    unawaited(_stopCapture());
    _playerOrNull?.dispose(); // never touch the getter here — it would create one
    super.dispose();
  }

  /// The spell's own incantation, or null if it has no complete triplet (a
  /// spell whose trajectory produced fewer than 3 activations casts no
  /// formula, so there is nothing to recite). The library hides the Practice
  /// entry point for those, so in practice this is only null defensively.
  PracticeFormula? get _spellFormula =>
      PracticeFormula.fromSpellFormula(widget.spell.formula);

  Future<void> _newFormula() async {
    final formula = _spellFormula;
    if (formula == null) return;
    await _startFormula(formula);
  }

  /// Installs [formula] as the active drill: fresh scorer, fresh feedback, and
  /// words concealed again so a repeat attempt is still a recall test rather
  /// than a reading test.
  Future<void> _startFormula(PracticeFormula formula) async {
    final templateSource = _templateSource;
    if (templateSource == null) return; // enrollment dir still resolving
    await _stopCapture();
    final scorer = IncantationRecallScorer(templateSource: templateSource);
    await scorer.load();
    if (!mounted) return;
    setState(() {
      _formula = formula;
      _recallScorer = scorer;
      _attempt = null;
      _wordsHidden = true;
      _didReveal = false;
    });
  }

  Future<void> _playFormula() async {
    final formula = _formula;
    if (formula == null) return;
    for (final word in formula.words) {
      await _player.play(AssetSource('audio/practice/${word.name}.wav'));
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
  }

  Future<void> _startCapture() async {
    if (_recallScorer == null || _isCapturing) return;

    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is needed for vocal practice.'),
            ),
          );
        }
        return;
      }

      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      final pcm = BytesBuilder();
      _recorder = recorder;
      _attemptPcm = pcm;
      _micSub = stream.listen(pcm.add, onError: (_) {});
      setState(() => _isCapturing = true);
    } catch (e, st) {
      // Without this, a failure here (e.g. the platform audio backend
      // rejecting the requested format) previously died silently: the
      // button's press ripple would show but nothing else would happen,
      // with no indication anything had gone wrong.
      debugPrint('Practice Mode: mic capture failed to start: $e\n$st');
      recorder.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start microphone capture: $e')),
        );
      }
    }
  }

  /// Closes the capture window. [score] false abandons the attempt — a press
  /// dragged off the button was not a performed incantation.
  Future<void> _stopCapture({bool score = false}) async {
    await _micSub?.cancel();
    _micSub = null;
    final pcm = _attemptPcm;
    _attemptPcm = null;
    if (_recorder != null) {
      try {
        await _recorder!.stop();
      } catch (_) {
        // Already stopped; the buffered audio is still good.
      }
      _recorder!.dispose();
      _recorder = null;
    }
    if (!mounted) return;
    setState(() => _isCapturing = false);

    final formula = _formula;
    final scorer = _recallScorer;
    if (!score || pcm == null || formula == null || scorer == null) return;
    final attempt = scorer.score(
      pcm.toBytes(),
      expectedElements: formula.elements.length,
    );
    setState(() => _attempt = attempt);
  }

  /// The attempt scored against the formula — the same tally the engine
  /// charges mana on, so the number shown here is the number a duel uses.
  RecallTally? get _attemptTally {
    final attempt = _attempt;
    final formula = _formula;
    if (attempt == null || formula == null) return null;
    return attempt.tallyAgainst(
      expectedIsSummon: formula.opener == VocalSlot.openerSummon,
      expectedElements: formula.elements,
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.spell.name.isNotEmpty
        ? widget.spell.name
        : 'Unnamed Spell';
    // One view, not tabs: the gesture half of this screen moved to Attune
    // Spell Components (see the file header), leaving the drill itself.
    return Scaffold(
      appBar: AppBar(title: Text('Practice — $name')),
      body: SafeScreenBody(
        child: _buildDrill(),
      ),
    );
  }

  Widget _buildDrill() {
    final formula = _formula;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (formula != null) ...[
            if (_wordsHidden)
              _buildConcealedFormula(formula)
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < formula.words.length; i++)
                    _wordChip(formula.words[i], i),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Playing the formula aloud is giving away the answer, so it
                // is only offered once the words are already revealed.
                TextButton.icon(
                  onPressed: _wordsHidden ? null : _playFormula,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Play formula'),
                ),
              ],
            ),
            if (_didReveal)
              const Text(
                'Answer revealed — start over for a clean attempt.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            const SizedBox(height: 16),
            // Hold, chant the whole incantation, release — the exact shape a
            // real cast uses (VOCAL_RECALL_PLAN.md §9.4), on the same control.
            // A drill that segmented differently from battle would be
            // practising a skill the duel never tests.
            HoldToRecordButton(
              label: _isCapturing ? 'Reciting…' : 'Hold and recite',
              icon: Icons.mic,
              enabled: _recallScorer != null,
              onHoldStart: () => unawaited(_startCapture()),
              onHoldEnd: () => unawaited(_stopCapture(score: true)),
              onHoldCancel: () => unawaited(_stopCapture()),
            ),
            const SizedBox(height: 8),
            const Text(
              'Say the opener, then each element word in order, in one breath.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          if (_attempt != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            _buildAttemptResult(),
          ],
          const SizedBox(height: 24),
          // Re-conceals the words and clears the last verdict, so the next
          // recital is a clean recall test of the SAME spell. This is the only
          // formula control left: the screen drills one spell and nothing else.
          OutlinedButton(
            onPressed: _newFormula,
            child: const Text('Start Over'),
          ),
        ],
      ),
    );
  }

  /// The concealed form of a drill formula: one blank per word, so the player
  /// knows *how many* words to recite (a spell's length is visible on its
  /// library card anyway) without being shown *which*. The blank for the word
  /// currently being listened for is highlighted, mirroring [_wordChip]'s
  /// amber target so live progress still reads without leaking ahead.
  Widget _buildConcealedFormula(PracticeFormula formula) {
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < formula.words.length; i++)
              Chip(
                label: Text(
                  // Word count is not a secret; word identity is. Every word
                  // is concealed, the opener included — unlike the retired
                  // `finitus`, which was invariant, the opener is one of two
                  // and so carries real recall information (§8.5).
                  '? ? ?',
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() {
            _wordsHidden = false;
            _didReveal = true;
          }),
          icon: const Icon(Icons.visibility, size: 18),
          label: const Text('Reveal words'),
        ),
      ],
    );
  }

  /// One word of the revealed formula. Coloured by the last attempt once one
  /// exists, so a player sees WHICH word they missed rather than a score.
  Widget _wordChip(VocalSlot word, int index) {
    final attempt = _attempt;
    Color? background;
    if (attempt != null) {
      final spoken = index == 0
          ? attempt.opener
          : (index - 1 < attempt.elements.length
              ? attempt.elements[index - 1]
              : null);
      background =
          spoken == word ? Colors.green.shade100 : Colors.red.shade100;
    }
    return Chip(
      label: Text(_labelFor(word)),
      backgroundColor: background,
    );
  }

  /// What the last attempt scored, in the terms a duel uses.
  ///
  /// Shows the MANA MULTIPLIER rather than a quality percentage, because that
  /// is the only number that exists any more — recall does not produce a
  /// score, it produces a price (VOCAL_RECALL_PLAN.md §3).
  Widget _buildAttemptResult() {
    final tally = _attemptTally;
    final formula = _formula;
    if (tally == null || formula == null) return const SizedBox.shrink();

    // Priced against a round 100 so the figure reads as a percentage without
    // inventing a second formula: this is literally RecallTally.applyTo.
    final multiplier = tally.applyTo(100);
    final delta = multiplier - 100;
    final perfect = tally.isPerfect;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          perfect
              ? 'Perfect recall'
              : '${tally.correct} of ${tally.units} right',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          delta == 0
              ? 'No change to the mana cost.'
              : delta < 0
                  ? 'Casts for ${-delta}% less mana.'
                  : 'Costs $delta% more mana.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: delta <= 0 ? Colors.green.shade800 : Colors.red.shade800,
          ),
        ),
        const SizedBox(height: 8),
        if (!_wordsHidden)
          const Text(
            'Green words were heard correctly; red were not.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.grey),
          )
        else
          TextButton(
            onPressed: () => setState(() {
              _wordsHidden = false;
              _didReveal = true;
            }),
            child: const Text('Show me which ones'),
          ),
      ],
    );
  }
}
