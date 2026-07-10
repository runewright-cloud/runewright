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
  final _templateSource = SingleVoiceTemplateSource();
  final _generator = PracticeFormulaGenerator();
  final _player = AudioPlayer();

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PracticeFeedback>? _completeSub;
  StreamingPhonemeScorer? _scorer;

  PracticeFormula? _formula;
  PracticeFeedback? _feedback;
  bool _isCapturing = false;
  int _formulaCount = 1;
  ({int wordIndex, String phonemeLabel})? _target;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
    await _stopCapture();
    final formula = _generator.generate(formulaCount: _formulaCount);
    final scorer = StreamingPhonemeScorer(templateSource: _templateSource);
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
                'Listening for: word ${_target!.wordIndex + 1} — "${_target!.phonemeLabel}"',
                textAlign: TextAlign.center,
                style: const TextStyle(fontStyle: FontStyle.italic),
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
          Text('Held you up most: word ${stall.wordIndex + 1}, "${stall.phonemeLabel}" '
              '(${stall.dwellMs} ms)'),
        const SizedBox(height: 12),
        const Text('Per-checkpoint clarity:'),
        for (final c in feedback.checkpoints)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 80, child: Text('word ${c.wordIndex + 1}')),
                SizedBox(width: 48, child: Text('"${c.phonemeLabel}"')),
                Expanded(
                  child: LinearProgressIndicator(value: c.clarity01),
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
