// SPDX-License-Identifier: GPL-3.0-or-later
//
// practice_screen.dart — PracticeScreen: Vocal + Gesture practice sub-modes,
// reachable from the main menu. Pure client scaffolding — consensus-
// invisible, never touches the circuit/ZK/lockstep/networking layers.

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide Element;
import 'package:record/record.dart';

import '../practice/formula_generator.dart';
import '../practice/gesture_enrollment.dart';
import '../practice/gesture_template_source.dart';
import '../practice/vocal_diagnostics.dart';
import '../sorcerer/vocal_enrollment.dart';
import '../sorcerer/vocal_template_source.dart';
import '../sorcerer/gesture.dart';
import '../sorcerer/gesture_capture.dart';
import '../sorcerer/gesture_classifier.dart';
import '../sorcerer/mfcc.dart';
import '../spells/spell_asset.dart';
import 'widgets/hold_to_record_control.dart';
import '../sorcerer/incantation_recall.dart';
import '../sorcerer/incantation_recall_scorer.dart';
import '../sorcerer/vocal_slot.dart';
import '../sorcerer/vocabulary_profile.dart';

/// Which persistence path a hold-to-record capture feeds — see
/// [_PracticeScreenState._onHoldStart]/[_finishHold]. Enrollment takes and
/// calibration attempts are otherwise IDENTICAL captures (press, say the
/// word once, release; see hold_to_record_control.dart's header on why
/// segmentation must match everywhere it's used), so they share one mic
/// pipeline and differ only in where the result is saved.
enum _HoldTarget { enrollment, calibration }

class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key, this.spell});

  /// When non-null, the screen opens in **spell-drill mode**: the incantation
  /// is this spell's own (see PracticeFormula.fromSpellFormula) rather than a
  /// random one, the formula-count chips are hidden (a spell's length is a
  /// property of the spell, not a setting), and the words start concealed —
  /// the drill is recalling them, not reading them.
  ///
  /// Typed as SpellAsset via the library's Practice menu item
  /// (library_screen.dart). Null for the main-menu entry point, which keeps
  /// the original random-formula behaviour.
  final SpellAsset? spell;

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _generator = PracticeFormulaGenerator();
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
  // documents directory resolves in initState.
  VocalEnrollment? _enrollment;
  PerUserEnrolledTemplateSource? _templateSource;
  Set<VocalSlot> _enrolledWords = const {};

  /// Per-word exemplar take count (IncantationRecallScorer scores min-
  /// distance over this set — see vocal_enrollment.dart's 2026-07-22
  /// multi-take rework). Kept in sync with disk after every save/clear.
  Map<VocalSlot, int> _takeCounts = const {};

  // Calibration capture (dev tool, off by default): records single-word
  // attempt clips to <docs>/practice_diagnostics/ for offline threshold
  // tuning against the real voice — see vocal_diagnostics.dart and
  // test/practice/vocal_calibration.dart.
  VocalDiagnostics? _diagnostics;
  bool _calibrationMode = false;
  Map<VocalSlot, int> _attemptCounts = const {};

  // In-progress hold-to-record capture, shared by enrollment takes and
  // calibration attempts (see _HoldTarget and _onHoldStart/_finishHold) —
  // one clean utterance per hold, at the player's own pace.
  AudioRecorder? _holdRecorder;
  StreamSubscription<Uint8List>? _holdSub;
  BytesBuilder? _holdPcm;
  VocalSlot? _holdWord;
  _HoldTarget? _holdTarget;

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

  /// Spell-drill mode only: whether the word chips are concealed. Starts true
  /// on every fresh attempt (see [_startFormula]) because recalling the
  /// sequence *is* the exercise — revealing is the "show me the answer"
  /// escape hatch, and the UI marks the attempt as revealed so a peeked run
  /// doesn't read as a clean one.
  bool _wordsHidden = false;

  /// Set when the player reveals a concealed formula, cleared on restart.
  bool _didReveal = false;
  bool _isCapturing = false;
  int _formulaCount = 1;

  // Gesture (somatic) enrollment — SOMATIC_GESTURE_PLAN.md §3. All five
  // gestures ship together (not phased): the four enhancements plus melee.
  // Choreography for all five is Soren's own performed baseline, captured
  // via this tool — see SORCERER_REALTIME_PLAN.md §5.2/§10.2.
  static const _recognizedGestures = [
    Gesture.fire,
    Gesture.air,
    Gesture.water,
    Gesture.earth,
    Gesture.melee,
  ];

  GestureEnrollment? _gestureEnrollment;
  EnrolledGestureTemplateSource? _gestureTemplateSource;
  final _gestureCapture = SensorsGestureCapture();
  final _gestureClassifier = const GestureClassifier();
  Set<Gesture> _enrolledGestures = const {};
  Set<GestureConfusable> _enrolledConfusables = const {};
  Map<Gesture, int> _gestureRepCounts = const {};
  Map<GestureConfusable, int> _confusableRepCounts = const {};
  GestureMatch? _lastTestMatch;
  String? _gestureStatus;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    unawaited(_initEnrollment());
    unawaited(_initGestureEnrollment());
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
    final diagnostics = await VocalDiagnostics.open();
    if (!mounted) return;
    setState(() {
      _enrollment = enrollment;
      _templateSource = PerUserEnrolledTemplateSource(enrollment: enrollment);
      _enrolledWords = enrollment.enrolledWords();
      _takeCounts = {
        for (final w in VocalSlot.values) w: enrollment.takeCount(w),
      };
      _diagnostics = diagnostics;
      _attemptCounts = diagnostics.attemptCounts();
    });
    // Spell-drill mode has nothing to choose, so load the incantation as soon
    // as there's a template source to score it against — the player lands on
    // a ready drill rather than on a button they'd always press.
    if (_isSpellDrill) await _newFormula();
  }




  /// Minimum captured audio (bytes, PCM-16 @ 16 kHz ⇒ 0.25 s) for a
  /// calibration hold to count as a real attempt rather than an accidental
  /// tap. Enrollment doesn't need this pre-check — VocalEnrollment's own
  /// trim+minVoicedFrames guard already rejects too-short takes with a
  /// friendlier message.
  static const int _minCalibBytes = 8000;

  /// Hold-to-record, shared by enrollment takes and calibration attempts
  /// (see [_HoldTarget]'s header). One hold = one clean utterance at the
  /// player's own pace (no fixed window) — this is what fixed the pace
  /// mismatch between careful slow enrollment and brisk real casting (see
  /// docs/M4_findings.md 2026-07-22).
  Future<void> _onHoldStart(VocalSlot word, _HoldTarget target) async {
    if (_holdWord != null || _isCapturing) return;
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        _showSnack('Microphone permission is needed to record.');
        return;
      }
      final pcm = BytesBuilder();
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      final sub = stream.listen(pcm.add);
      if (!mounted) {
        await sub.cancel();
        await recorder.stop();
        recorder.dispose();
        return;
      }
      setState(() {
        _holdRecorder = recorder;
        _holdSub = sub;
        _holdPcm = pcm;
        _holdWord = word;
        _holdTarget = target;
      });
    } catch (e, st) {
      debugPrint('Practice Mode: hold capture failed to start: $e\n$st');
      recorder.dispose();
      _showSnack('Could not start recording: $e');
    }
  }

  /// Release/cancel edge of a hold. Saves the buffered utterance to
  /// whichever target started it when [save] (a normal release), discards
  /// on cancel.
  Future<void> _finishHold({required bool save}) async {
    final word = _holdWord;
    final target = _holdTarget;
    final recorder = _holdRecorder;
    final pcm = _holdPcm;
    await _holdSub?.cancel();
    await recorder?.stop();
    recorder?.dispose();
    if (mounted) {
      setState(() {
        _holdRecorder = null;
        _holdSub = null;
        _holdPcm = null;
        _holdWord = null;
        _holdTarget = null;
      });
    }
    if (!save || word == null || pcm == null || target == null) return;
    final bytes = pcm.toBytes();

    switch (target) {
      case _HoldTarget.enrollment:
        final enrollment = _enrollment;
        if (enrollment == null) return;
        try {
          final result = await enrollment.saveFromRecording(word, bytes);
          _templateSource?.invalidate();
          if (mounted) {
            setState(() {
              _enrolledWords = enrollment.enrolledWords();
              _takeCounts = {..._takeCounts, word: result.takeCount};
            });
          }
          _showSnack('Saved "${_labelFor(word)}" — '
              '${result.takeCount}/${VocalEnrollment.maxTakes} takes.');
        } on EnrollmentException catch (e) {
          _showSnack(e.message);
        } catch (e, st) {
          debugPrint('Practice Mode: enrollment failed: $e\n$st');
          _showSnack('Could not save enrollment: $e');
        }
      case _HoldTarget.calibration:
        if (bytes.length < _minCalibBytes) {
          _showSnack('Too short — hold, say the word once, then release.');
          return;
        }
        final diagnostics = _diagnostics;
        if (diagnostics == null) return;
        try {
          final file = await diagnostics.saveAttempt(word, bytes);
          if (mounted) {
            setState(() => _attemptCounts = diagnostics.attemptCounts());
          }
          _showSnack('Saved: ${file.uri.pathSegments.last}');
        } catch (e, st) {
          debugPrint('Practice Mode: saving attempt failed: $e\n$st');
          _showSnack('Could not save attempt: $e');
        }
    }
  }

  Future<void> _clearAttempts() async {
    final diagnostics = _diagnostics;
    if (diagnostics == null) return;
    await diagnostics.clearAll();
    if (mounted) {
      setState(() => _attemptCounts = diagnostics.attemptCounts());
    }
    _showSnack('Cleared all calibration attempt clips.');
  }

  @override
  void dispose() {
    _tabController.dispose();
    unawaited(_stopCapture());
    unawaited(_holdSub?.cancel());
    unawaited(_holdRecorder?.stop().then((_) => _holdRecorder?.dispose()));
    _playerOrNull?.dispose(); // never touch the getter here — it would create one
    _gestureCapture.dispose();
    super.dispose();
  }

  // ── Gesture enrollment ──────────────────────────────────────────────────

  Future<void> _initGestureEnrollment() async {
    final enrollment = await GestureEnrollment.open();
    if (!mounted) return;
    setState(() {
      _gestureEnrollment = enrollment;
      _gestureTemplateSource = EnrolledGestureTemplateSource(enrollment);
      _enrolledGestures = enrollment.enrolledGestures();
      _enrolledConfusables = enrollment.enrolledConfusables();
    });
    await _refreshGestureRepCounts();
  }

  Future<void> _refreshGestureRepCounts() async {
    final enrollment = _gestureEnrollment;
    if (enrollment == null) return;
    final gCounts = <Gesture, int>{};
    for (final g in _recognizedGestures) {
      gCounts[g] = await enrollment.repCountFor(g);
    }
    final cCounts = <GestureConfusable, int>{};
    for (final c in GestureConfusable.values) {
      cCounts[c] = await enrollment.confusableRepCountFor(c);
    }
    if (!mounted) return;
    setState(() {
      _gestureRepCounts = gCounts;
      _confusableRepCounts = cCounts;
    });
  }

  void _onGestureHoldStart() {
    setState(() => _gestureStatus = null);
    _gestureCapture.beginCapture();
  }

  void _onGestureHoldCancel() {
    _gestureCapture.endCapture(); // discard — press didn't complete
  }

  Future<void> _onGestureHoldEnd(Gesture gesture) async {
    final enrollment = _gestureEnrollment;
    if (enrollment == null) return;
    final samples = _gestureCapture.endCapture();
    try {
      final count = await enrollment.saveGestureRep(
        gesture,
        samples,
        stillnessFloor: _gestureClassifier.energyFloor,
      );
      _gestureTemplateSource?.invalidate();
      if (!mounted) return;
      setState(() {
        _enrolledGestures = enrollment.enrolledGestures();
        _gestureRepCounts = {..._gestureRepCounts, gesture: count};
        _gestureStatus = 'Saved rep #$count for ${gesture.name}.';
      });
    } on GestureEnrollmentException catch (e) {
      if (mounted) setState(() => _gestureStatus = e.message);
    }
  }

  Future<void> _onConfusableHoldEnd(GestureConfusable confusable) async {
    final enrollment = _gestureEnrollment;
    if (enrollment == null) return;
    final samples = _gestureCapture.endCapture();
    try {
      final count = await enrollment.saveConfusableRep(confusable, samples);
      if (!mounted) return;
      setState(() {
        _enrolledConfusables = enrollment.enrolledConfusables();
        _confusableRepCounts = {..._confusableRepCounts, confusable: count};
        _gestureStatus = 'Saved rep #$count for confusable "${confusable.name}".';
      });
    } on GestureEnrollmentException catch (e) {
      if (mounted) setState(() => _gestureStatus = e.message);
    }
  }

  /// Runs the just-captured hold through GestureClassifier against the
  /// current enrolled templates and shows the verdict — a live calibration
  /// readout while capturing, mirroring the vocal tab's quality display.
  /// This is NOT the confusion-matrix harness (test/sorcerer/) — it checks
  /// one attempt, not the corpus.
  Future<void> _onTestHoldEnd() async {
    final source = _gestureTemplateSource;
    if (source == null) return;
    final samples = _gestureCapture.endCapture();
    final templates = await loadGestureTemplates(source, _recognizedGestures);
    final match = _gestureClassifier.classify(samples, templates);
    if (mounted) setState(() => _lastTestMatch = match);
  }

  Future<void> _clearGestureEnrollment() async {
    final enrollment = _gestureEnrollment;
    if (enrollment == null) return;
    await enrollment.clearAll();
    _gestureTemplateSource?.invalidate();
    await _refreshGestureRepCounts();
    if (!mounted) return;
    setState(() {
      _enrolledGestures = enrollment.enrolledGestures();
      _enrolledConfusables = enrollment.enrolledConfusables();
      _lastTestMatch = null;
    });
    _showSnack('Cleared all gesture enrollments.');
  }

  /// True when this screen is drilling one specific library spell rather than
  /// generating random formulas — see [PracticeScreen.spell].
  bool get _isSpellDrill => widget.spell != null;

  /// The spell's own incantation, or null if it has no complete triplet (a
  /// spell whose trajectory produced fewer than 3 activations casts no
  /// formula, so there is nothing to recite). The library hides the Practice
  /// entry point for those, so in practice this is only null defensively.
  PracticeFormula? get _spellFormula {
    final spell = widget.spell;
    if (spell == null) return null;
    return PracticeFormula.fromSpellFormula(spell.formula);
  }

  Future<void> _newFormula() async {
    final formula = _isSpellDrill
        ? _spellFormula
        : _generator.generate(formulaCount: _formulaCount);
    if (formula == null) return;
    await _startFormula(formula);
  }

  /// Installs [formula] as the active drill: fresh scorer, fresh feedback,
  /// and (in spell-drill mode) words concealed again so a repeat attempt is
  /// still a recall test rather than a reading test.
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
      _wordsHidden = _isSpellDrill;
      _didReveal = false;
    });
  }

  Future<void> _clearEnrollment() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await enrollment.clearAll();
    _templateSource?.invalidate();
    if (mounted) {
      setState(() {
        _enrolledWords = enrollment.enrolledWords();
        _takeCounts = {for (final w in VocalSlot.values) w: 0};
      });
    }
    _showSnack('Cleared all voice enrollments — scoring falls back to the '
        'default voice.');
  }

  Future<void> _clearWordEnrollment(VocalSlot word) async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await enrollment.clearWord(word);
    _templateSource?.invalidate();
    if (mounted) {
      setState(() {
        _enrolledWords = enrollment.enrolledWords();
        _takeCounts = {..._takeCounts, word: 0};
      });
    }
    _showSnack('Cleared "${_labelFor(word)}" — record it again to re-enroll.');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSpellDrill
            ? 'Practice — ${widget.spell!.name.isNotEmpty ? widget.spell!.name : 'Unnamed Spell'}'
            : 'Practice'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Vocal'),
            Tab(text: 'Gesture'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildVocalTab(),
          _buildGestureTab(),
        ],
      ),
    );
  }

  Widget _buildVocalTab() {
    final formula = _formula;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildEnrollmentCard(),
          const SizedBox(height: 16),
          _buildCalibrationCard(),
          const SizedBox(height: 16),
          // Formula length is a property of the spell in drill mode, so the
          // count chips would be a setting that can't legally be changed.
          if (!_isSpellDrill) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Formulas: '),
                for (final k in [1, 2, 3])
                  ChoiceChip(
                    label: Text('$k'),
                    selected: _formulaCount == k,
                    onSelected: (_) => setState(() => _formulaCount = k),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          ElevatedButton(
            onPressed: _newFormula,
            child: Text(_isSpellDrill ? 'Start Over' : 'New Formula'),
          ),
          const SizedBox(height: 16),
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
                // counts as a reveal in drill mode — same escape hatch, same
                // marking.
                TextButton.icon(
                  onPressed: _wordsHidden ? null : _playFormula,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Play formula'),
                ),
              ],
            ),
            if (_isSpellDrill && _didReveal)
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
        ],
      ),
    );
  }


  /// Voice-enrollment status + per-word hold-to-record rows. Multiple takes
  /// per word (2026-07-22 multi-exemplar rework) are what make right-vs-
  /// wrong-word discrimination robust to natural voice variation — the
  /// scorer takes the best (min-distance) match among a word's takes. The
  /// Piper fallback for unenrolled words can only reliably detect "a real
  /// attempt," not which word.
  Widget _buildEnrollmentCard() {
    final ready = _templateSource != null;
    final enrolledCount = _enrolledWords.length;
    final total = VocalSlot.values.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Voice enrollment: $enrolledCount / $total words',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (enrolledCount > 0)
                  TextButton(
                    onPressed: _clearEnrollment,
                    child: const Text('Clear all'),
                  ),
              ],
            ),
            Text(
              'Tap ▶ to hear the model, then hold a word and say it in your '
              'own voice at your normal casting pace, and release. A few '
              'natural takes per word (up to ${VocalEnrollment.maxTakes}) '
              'beat one careful one — the scorer checks your best match '
              'among them. Unenrolled words fall back to the default voice, '
              'which is much weaker at telling words apart.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            for (final word in VocalSlot.values)
              _enrollmentRow(word, ready: ready),
          ],
        ),
      ),
    );
  }

  Widget _enrollmentRow(VocalSlot word, {required bool ready}) {
    final takes = _takeCounts[word] ?? 0;
    final canHold =
        ready && !_isCapturing && (_holdWord == null || _holdWord == word);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          HoldToRecordButton(
            label: _labelFor(word),
            icon: Icons.mic,
            enabled: canHold,
            onHoldStart: () => _onHoldStart(word, _HoldTarget.enrollment),
            onHoldEnd: () => _finishHold(save: true),
            onHoldCancel: () => _finishHold(save: false),
          ),
          const Spacer(),
          Text(
            '$takes/${VocalEnrollment.maxTakes}',
            style: TextStyle(
              fontSize: 12,
              color: takes > 0 ? Colors.green.shade700 : Colors.grey.shade500,
              fontWeight: takes > 0 ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          if (takes > 0)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Clear ${_labelFor(word)}\'s takes',
              onPressed: () => _clearWordEnrollment(word),
            ),
        ],
      ),
    );
  }

  /// Dev/calibration tool (off by default): record single-word attempt clips
  /// to `practice_diagnostics/` so the offline harness
  /// (test/practice/vocal_calibration.dart) can tune the scorer's operating
  /// point against the real voice. Captured the same way as enrollment
  /// (fixed 2.5 s window) so an attempt is comparable to its template.
  Widget _buildCalibrationCard() {
    final ready = _diagnostics != null;
    final totalClips =
        _attemptCounts.values.fold<int>(0, (s, c) => s + c);
    return Card(
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Calibration capture (dev)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                Switch(
                  value: _calibrationMode,
                  onChanged: (v) => setState(() => _calibrationMode = v),
                ),
              ],
            ),
            if (_calibrationMode) ...[
              Text(
                'Hold a word, say it ONCE at your normal casting pace, then '
                'release. Record ~3 per word. $totalClips clip(s) saved.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final word in VocalSlot.values)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HoldToRecordButton(
                          label: _labelFor(word),
                          icon: Icons.mic,
                          enabled: ready &&
                              !_isCapturing &&
                              (_holdWord == null || _holdWord == word),
                          onHoldStart: () =>
                              _onHoldStart(word, _HoldTarget.calibration),
                          onHoldEnd: () => _finishHold(save: true),
                          onHoldCancel: () => _finishHold(save: false),
                        ),
                        const SizedBox(height: 4),
                        Text('${_attemptCounts[word] ?? 0} clip(s)',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade600)),
                      ],
                    ),
                ],
              ),
              if (totalClips > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _clearAttempts,
                    child: const Text('Clear attempts'),
                  ),
                ),
            ],
          ],
        ),
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

  Widget _buildGestureTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildGestureEnrollmentCard(),
          const SizedBox(height: 16),
          _buildConfusableCard(),
          const SizedBox(height: 16),
          _buildGestureTestCard(),
          if (_gestureStatus != null) ...[
            const SizedBox(height: 12),
            Text(
              _gestureStatus!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGestureEnrollmentCard() {
    final ready = _gestureEnrollment != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Gestures: ${_enrolledGestures.length} / '
                    '${_recognizedGestures.length} have at least one rep',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (_enrolledGestures.isNotEmpty ||
                    _enrolledConfusables.isNotEmpty)
                  TextButton(
                    onPressed: _clearGestureEnrollment,
                    child: const Text('Clear all'),
                  ),
              ],
            ),
            Text(
              'Hold the button, perform the gesture clearly, release. '
              'Record at least 10 reps per gesture so the calibration '
              'harness can measure how much your own motion varies.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final gesture in _recognizedGestures)
                  _gestureCaptureRow(
                    label: gesture.name,
                    count: _gestureRepCounts[gesture] ?? 0,
                    enabled: ready,
                    onHoldEnd: () => _onGestureHoldEnd(gesture),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfusableCard() {
    final ready = _gestureEnrollment != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Confusables', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'Motions that should NOT trigger an enhancement: holding '
              'still, walking, and random flourish. These define the '
              'reject side of the boundary — without them the threshold '
              'can\'t be set.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final confusable in GestureConfusable.values)
                  _gestureCaptureRow(
                    label: confusable.name,
                    count: _confusableRepCounts[confusable] ?? 0,
                    enabled: ready,
                    onHoldEnd: () => _onConfusableHoldEnd(confusable),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gestureCaptureRow({
    required String label,
    required int count,
    required bool enabled,
    required VoidCallback onHoldEnd,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoldToRecordButton(
          label: label,
          enabled: enabled,
          onHoldStart: _onGestureHoldStart,
          onHoldEnd: onHoldEnd,
          onHoldCancel: _onGestureHoldCancel,
        ),
        const SizedBox(height: 4),
        Text('$count reps', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildGestureTestCard() {
    final ready = _gestureTemplateSource != null;
    final match = _lastTestMatch;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Test a capture', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'Perform any motion and see how the classifier reads it '
              'right now, against whatever is enrolled so far.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            HoldToRecordButton(
              label: 'Hold to test',
              enabled: ready,
              icon: Icons.science_outlined,
              onHoldStart: _onGestureHoldStart,
              onHoldEnd: _onTestHoldEnd,
              onHoldCancel: _onGestureHoldCancel,
            ),
            if (match != null) ...[
              const SizedBox(height: 12),
              Text(
                match.stillnessGated
                    ? 'Result: neutral (held still)'
                    : 'Result: ${match.gesture.name}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (!match.stillnessGated && match.distances.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    match.distances.entries
                        .map((e) => '${e.key.name}: ${e.value.toStringAsFixed(2)}')
                        .join('  ·  '),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
