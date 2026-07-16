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
import '../practice/practice_feedback.dart';
import '../practice/streaming_phoneme_scorer.dart';
import '../practice/vocal_enrollment.dart';
import '../practice/vocal_template_source.dart';
import '../sorcerer/mfcc.dart';
import '../sorcerer/vocal_score.dart';

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
  VocalWord? _enrollingWord;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PracticeFeedback>? _completeSub;
  StreamingPhonemeScorer? _scorer;

  PracticeFormula? _formula;
  PracticeFeedback? _feedback;
  bool _isCapturing = false;
  int _formulaCount = 1;
  ({int wordIndex, String label})? _target;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    unawaited(_initEnrollment());
  }

  Future<void> _initEnrollment() async {
    final enrollment = await VocalEnrollment.open();
    if (!mounted) return;
    setState(() {
      _enrollment = enrollment;
      _templateSource = PerUserEnrolledTemplateSource(enrollment: enrollment);
      _enrolledWords = enrollment.enrolledWords();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    unawaited(_stopCapture());
    _completeSub?.cancel();
    _scorer?.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _newFormula() async {
    final templateSource = _templateSource;
    if (templateSource == null) return; // enrollment dir still resolving
    await _stopCapture();
    final formula = _generator.generate(formulaCount: _formulaCount);
    final scorer = StreamingPhonemeScorer(templateSource: templateSource);
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

  /// Records ~2.5s of the player saying [word] and stores it as that
  /// word's scoring template (trimmed + validated by VocalEnrollment).
  /// The Piper clip is played first as the pronunciation model to imitate.
  Future<void> _enrollWord(VocalWord word) async {
    final enrollment = _enrollment;
    if (enrollment == null || _isCapturing || _enrollingWord != null) return;

    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        _showSnack('Microphone permission is needed to enroll your voice.');
        return;
      }

      // Pronunciation model first, then a beat before the mic opens.
      await _playWord(word);
      await Future<void>.delayed(const Duration(milliseconds: 900));

      setState(() => _enrollingWord = word);
      final pcm = BytesBuilder();
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      final sub = stream.listen(pcm.add);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await sub.cancel();
      await recorder.stop();

      final frameCount = await enrollment.saveFromRecording(word, pcm.toBytes());
      _templateSource?.invalidate();
      if (mounted) {
        setState(() => _enrolledWords = enrollment.enrolledWords());
      }
      _showSnack('Enrolled "${word.name}" ($frameCount frames). '
          'Takes effect on the next formula.');
    } on EnrollmentException catch (e) {
      _showSnack(e.message);
    } catch (e, st) {
      debugPrint('Practice Mode: enrollment failed: $e\n$st');
      _showSnack('Could not record enrollment: $e');
    } finally {
      recorder.dispose();
      if (mounted) setState(() => _enrollingWord = null);
    }
  }

  Future<void> _clearEnrollment() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await enrollment.clearAll();
    _templateSource?.invalidate();
    if (mounted) {
      setState(() => _enrolledWords = enrollment.enrolledWords());
    }
    _showSnack('Cleared all voice enrollments — scoring falls back to the '
        'default voice.');
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
          _buildGestureComingSoon(),
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

  /// Voice-enrollment status + per-word enroll buttons. Enrolled templates
  /// (your own voice) are what make right-vs-wrong-word discrimination
  /// work — the Piper fallback can only reliably detect "a real attempt."
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
                    'Voice enrollment: $enrolledCount / $total',
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
              enrolledCount == total
                  ? 'Scoring against your own voice.'
                  : 'Record each word once in your own voice — tap a word, '
                      'listen, then repeat it after the clip finishes. '
                      'Unenrolled words are scored against the default voice, '
                      'which is much weaker at telling words apart.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final word in VocalWord.values)
                  InputChip(
                    label: Text(word.name),
                    avatar: _enrollingWord == word
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _enrolledWords.contains(word)
                                ? Icons.check_circle
                                : Icons.mic_none,
                            size: 18,
                            color: _enrolledWords.contains(word)
                                ? Colors.green
                                : null,
                          ),
                    onPressed:
                        ready && _enrollingWord == null && !_isCapturing
                            ? () => _enrollWord(word)
                            : null,
                  ),
              ],
            ),
            if (_enrollingWord != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Recording "${_enrollingWord!.name}" — speak now…',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
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

  Widget _buildGestureComingSoon() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Gesture practice is coming soon.\n\n'
          'Somatic-gesture capture and a target-motion animation are not '
          'built yet — see the Phase 2 proposal.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
