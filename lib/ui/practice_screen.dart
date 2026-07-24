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
import '../practice/practice_feedback.dart';
import '../practice/streaming_phoneme_scorer.dart';
import '../practice/vocal_diagnostics.dart';
import '../practice/vocal_enrollment.dart';
import '../practice/vocal_template_source.dart';
import '../practice/vocal_tuning.dart';
import '../sorcerer/gesture.dart';
import '../sorcerer/gesture_capture.dart';
import '../sorcerer/gesture_classifier.dart';
import '../sorcerer/mfcc.dart';
import '../sorcerer/vocal_score.dart';
import 'widgets/hold_to_record_control.dart';
import 'widgets/vocal_strictness_slider.dart';

/// Which persistence path a hold-to-record capture feeds — see
/// [_PracticeScreenState._onHoldStart]/[_finishHold]. Enrollment takes and
/// calibration attempts are otherwise IDENTICAL captures (press, say the
/// word once, release; see hold_to_record_control.dart's header on why
/// segmentation must match everywhere it's used), so they share one mic
/// pipeline and differ only in where the result is saved.
enum _HoldTarget { enrollment, calibration }

class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _generator = PracticeFormulaGenerator();
  final _player = AudioPlayer();

  // Enrollment-backed template source (player's own voice per word, Piper
  // fallback until enrolled) — see vocal_enrollment.dart for why same-voice
  // templates are load-bearing for word discrimination. Null until the
  // documents directory resolves in initState.
  VocalEnrollment? _enrollment;
  PerUserEnrolledTemplateSource? _templateSource;
  Set<VocalWord> _enrolledWords = const {};

  /// Per-word exemplar take count (StreamingPhonemeScorer scores min-
  /// distance over this set — see vocal_enrollment.dart's 2026-07-22
  /// multi-take rework). Kept in sync with disk after every save/clear.
  Map<VocalWord, int> _takeCounts = const {};

  // Calibration capture (dev tool, off by default): records single-word
  // attempt clips to <docs>/practice_diagnostics/ for offline threshold
  // tuning against the real voice — see vocal_diagnostics.dart and
  // test/practice/vocal_calibration.dart.
  VocalDiagnostics? _diagnostics;
  bool _calibrationMode = false;
  Map<VocalWord, int> _attemptCounts = const {};

  // In-progress hold-to-record capture, shared by enrollment takes and
  // calibration attempts (see _HoldTarget and _onHoldStart/_finishHold) —
  // one clean utterance per hold, at the player's own pace.
  AudioRecorder? _holdRecorder;
  StreamSubscription<Uint8List>? _holdSub;
  BytesBuilder? _holdPcm;
  VocalWord? _holdWord;
  _HoldTarget? _holdTarget;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PracticeFeedback>? _completeSub;
  StreamingPhonemeScorer? _scorer;

  // Player-adjustable recognition strictness (2026-07-22 playtest ask) — also
  // exposed in SettingsScreen; both read/write the same persisted VocalTuning.
  // Null until loaded, so _newFormula falls back to VocalTuning's shipped
  // default rather than blocking on the docs-directory read.
  VocalTuning? _vocalTuning;

  PracticeFormula? _formula;
  PracticeFeedback? _feedback;
  bool _isCapturing = false;
  int _formulaCount = 1;
  ({int wordIndex, String label})? _target;

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
    unawaited(_initVocalTuning());
  }

  Future<void> _initEnrollment() async {
    final enrollment = await VocalEnrollment.open();
    final diagnostics = await VocalDiagnostics.open();
    if (!mounted) return;
    setState(() {
      _enrollment = enrollment;
      _templateSource = PerUserEnrolledTemplateSource(enrollment: enrollment);
      _enrolledWords = enrollment.enrolledWords();
      _takeCounts = {
        for (final w in VocalWord.values) w: enrollment.takeCount(w),
      };
      _diagnostics = diagnostics;
      _attemptCounts = diagnostics.attemptCounts();
    });
  }

  Future<void> _initVocalTuning() async {
    final tuning = await VocalTuning.load();
    if (!mounted) return;
    setState(() => _vocalTuning = tuning);
  }

  void _onVocalTuningChanged(double strictness) {
    setState(() => _vocalTuning = VocalTuning(strictness));
  }

  void _onVocalTuningChangeEnd(double strictness) {
    unawaited(VocalTuning(strictness).save());
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
  Future<void> _onHoldStart(VocalWord word, _HoldTarget target) async {
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
          _showSnack('Saved "${word.name}" — '
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
    _completeSub?.cancel();
    _scorer?.dispose();
    _player.dispose();
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

  Future<void> _newFormula() async {
    final templateSource = _templateSource;
    if (templateSource == null) return; // enrollment dir still resolving
    await _stopCapture();
    final formula = _generator.generate(formulaCount: _formulaCount);
    final tuning = _vocalTuning ?? VocalTuning(VocalTuning.defaultStrictness);
    final scorer = StreamingPhonemeScorer(
      templateSource: templateSource,
      checkpointFloor: tuning.floor,
      debounceFrames: tuning.debounceFrames,
      contrastiveMargin: tuning.margin,
    );
    await scorer.beginFormula(formula);
    await _completeSub?.cancel();
    _completeSub = scorer.onComplete.listen(_onFormulaComplete);
    _scorer?.dispose();
    setState(() {
      _formula = formula;
      _scorer = scorer;
      _feedback = null;
      _target = scorer.currentTarget;
    });
  }

  Future<void> _playWord(VocalWord word) =>
      _player.play(AssetSource('audio/practice/${word.name}.wav'));

  Future<void> _clearEnrollment() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await enrollment.clearAll();
    _templateSource?.invalidate();
    if (mounted) {
      setState(() {
        _enrolledWords = enrollment.enrolledWords();
        _takeCounts = {for (final w in VocalWord.values) w: 0};
      });
    }
    _showSnack('Cleared all voice enrollments — scoring falls back to the '
        'default voice.');
  }

  Future<void> _clearWordEnrollment(VocalWord word) async {
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
    _showSnack('Cleared "${word.name}" — record it again to re-enroll.');
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
    final scorer = _scorer;
    if (scorer == null || _isCapturing) return;

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
      _recorder = recorder;
      _micSub = stream.listen((chunk) {
        scorer.acceptPcmChunk(chunk);
        if (mounted) setState(() => _target = scorer.currentTarget);
      });
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

  /// Manual bail-out only — there is deliberately no automatic timeout here.
  /// An unmet checkpoint floor stalls the pointer forever on its own; this
  /// button exists purely so a player can abandon a capture, not to enforce
  /// a listening window.
  Future<void> _stopCapture() async {
    await _micSub?.cancel();
    _micSub = null;
    await _recorder?.stop();
    _recorder?.dispose();
    _recorder = null;
    if (mounted) setState(() => _isCapturing = false);
  }

  void _onFormulaComplete(PracticeFeedback feedback) {
    unawaited(_stopCapture());
    if (mounted) setState(() => _feedback = feedback);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Practice'),
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
          _buildStrictnessCard(),
          const SizedBox(height: 16),
          _buildCalibrationCard(),
          const SizedBox(height: 16),
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
          ElevatedButton(
            onPressed: _newFormula,
            child: const Text('New Formula'),
          ),
          const SizedBox(height: 16),
          if (formula != null) ...[
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
                TextButton.icon(
                  onPressed: _playFormula,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Play formula'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isCapturing ? _stopCapture : _startCapture,
              icon: Icon(_isCapturing ? Icons.stop : Icons.mic),
              label: Text(_isCapturing ? 'Stop' : 'Start speaking'),
            ),
            if (_isCapturing && _target != null) ...[
              const SizedBox(height: 12),
              Text(
                'Listening for: word ${_target!.wordIndex + 1} — "${_target!.label}"',
                textAlign: TextAlign.center,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
              const Text(
                'If a word doesn\'t register, take a breath and say it '
                'again — a short pause is what starts a fresh attempt.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                _scorer?.currentNormalizedQuality != null
                    ? 'quality: ${_scorer!.currentNormalizedQuality!.toStringAsFixed(2)}'
                        ' / floor: ${_scorer!.floor.toStringAsFixed(2)} (lower is better)'
                    : 'quality: — (no audio evaluated yet)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              // Stall hint: after a couple of seconds without a crossing,
              // if another vocabulary word explains the audio better than
              // the target, say so gently. Informational only — the
              // pointer still only ever advances on the real conditions.
              if (_scorer != null &&
                  _scorer!.currentSegmentDwellMs > 2500 &&
                  _scorer!.currentBestGuess != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Hearing something closer to '
                  '"${_scorer!.currentBestGuess!.label}"…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: Colors.orange.shade800,
                  ),
                ),
              ],
            ],
          ],
          if (_feedback != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            _buildFeedback(_feedback!),
          ],
        ],
      ),
    );
  }

  /// Recognition strictness dial (2026-07-22 playtest ask) — same control
  /// and same persisted VocalTuning as SettingsScreen; new formulas pick up
  /// the current value (already-running captures are unaffected).
  Widget _buildStrictnessCard() {
    final tuning = _vocalTuning;
    if (tuning == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: VocalStrictnessSlider(
          strictness: tuning.strictness,
          onChanged: _onVocalTuningChanged,
          onChangeEnd: _onVocalTuningChangeEnd,
        ),
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
    final total = VocalWord.values.length;
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
            for (final word in VocalWord.values)
              _enrollmentRow(word, ready: ready),
          ],
        ),
      ),
    );
  }

  Widget _enrollmentRow(VocalWord word, {required bool ready}) {
    final takes = _takeCounts[word] ?? 0;
    final canHold =
        ready && !_isCapturing && (_holdWord == null || _holdWord == word);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.volume_up, size: 20),
            tooltip: 'Hear the model pronunciation',
            onPressed: () => _playWord(word),
          ),
          HoldToRecordButton(
            label: word.name,
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
              tooltip: 'Clear ${word.name}\'s takes',
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
                  for (final word in VocalWord.values)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        HoldToRecordButton(
                          label: word.name,
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

  Widget _wordChip(VocalWord word, int index) {
    final isCurrentTarget = _target?.wordIndex == index;
    return InputChip(
      label: Text(word.name),
      backgroundColor: isCurrentTarget ? Colors.amber.shade100 : null,
      onPressed: () => _playWord(word),
      avatar: const Icon(Icons.play_arrow, size: 18),
    );
  }

  Widget _buildFeedback(PracticeFeedback feedback) {
    final stall = feedback.stallPoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Feedback', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: 8),
        Text('Time to completion: ${feedback.timeToCompletionMs} ms (informational only)'),
        Text('Loudness: ${(feedback.averageLoudness * 100).round()}% (informational, non-gating)'),
        if (stall != null)
          Text('Held you up most: word ${stall.wordIndex + 1}, "${stall.label}" '
              '(${stall.dwellMs} ms)'),
        const SizedBox(height: 12),
        const Text('Per-checkpoint clarity:'),
        for (final c in feedback.checkpoints)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 80, child: Text('word ${c.wordIndex + 1}')),
                SizedBox(width: 48, child: Text('"${c.label}"')),
                Expanded(
                  child: LinearProgressIndicator(value: c.clarity01),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    // Raw normalizedQuality, not just the clarity bar --
                    // this is what actually cleared the floor (currently
                    // 7.0) at crossing time. Shown even though completion
                    // may have happened "too fast to read live," since this
                    // is the after-the-fact record of it.
                    c.normalizedQuality.toStringAsFixed(1),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Gesture (somatic) capture/enrollment tab — SOMATIC_GESTURE_PLAN.md §8.
  /// Not a game feature: this is the calibration tool. It records repeated
  /// examples of each v1 gesture plus the confusables that define the
  /// reject boundary (idle/walk/garbage), and lets you test a capture
  /// against what's enrolled so far. kSomaticCaptureEnabled stays false in
  /// battle until a real confusion-matrix pass (test/sorcerer/) clears —
  /// this tab is how that corpus gets built.
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
