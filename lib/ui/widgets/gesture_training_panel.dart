// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_training_panel.dart — the somatic half of attunement: enrolling
// the five gestures a player performs, the confusables that define the
// reject side of the boundary, and a live "what would the classifier call
// this?" readout.
//
// Lifted out of practice_screen.dart's Gesture tab and given one home, for
// the same reason voice takes left the drill (vocabulary_screen.dart's
// header): attuning a component and drilling a spell are different acts, and
// when the enrollment tool lived behind a spell's Practice button it was
// reachable only if you owned a spell with a complete triplet — which is
// exactly backwards for a calibration corpus you record before you have any
// spells worth casting.
//
// Nothing here is consensus-visible: gesture reps are local files, never
// leave the device, and [kSomaticCaptureEnabled] still gates whether any of
// it reaches a cast (SOMATIC_GESTURE_PLAN.md §9/§11).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../practice/gesture_enrollment.dart';
import '../../practice/gesture_template_source.dart';
import '../../sorcerer/gesture.dart';
import '../../sorcerer/gesture_capture.dart';
import '../../sorcerer/gesture_classifier.dart';
import '../../spells/enhancement_zone.dart';
import 'hold_to_record_control.dart';

class GestureTrainingPanel extends StatefulWidget {
  const GestureTrainingPanel({super.key});

  @override
  State<GestureTrainingPanel> createState() => _GestureTrainingPanelState();
}

class _GestureTrainingPanelState extends State<GestureTrainingPanel> {
  // SOMATIC_GESTURE_PLAN.md §3. All five gestures ship together (not phased):
  // the four enhancements plus melee. Choreography for all five is Soren's own
  // performed baseline, captured via this tool — see SORCERER_REALTIME_PLAN.md
  // §5.2/§10.2.
  static const _enhancementGestures = [
    Gesture.fire,
    Gesture.air,
    Gesture.water,
    Gesture.earth,
  ];
  static const _recognizedGestures = [..._enhancementGestures, Gesture.melee];

  GestureEnrollment? _enrollment;
  EnrolledGestureTemplateSource? _templateSource;
  final _capture = SensorsGestureCapture();
  final _classifier = const GestureClassifier();
  Set<Gesture> _enrolledGestures = const {};
  Set<GestureConfusable> _enrolledConfusables = const {};
  Map<Gesture, int> _gestureRepCounts = const {};
  Map<GestureConfusable, int> _confusableRepCounts = const {};
  GestureMatch? _lastTestMatch;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final enrollment = await GestureEnrollment.open();
    if (!mounted) return;
    setState(() {
      _enrollment = enrollment;
      _templateSource = EnrolledGestureTemplateSource(enrollment);
      _enrolledGestures = enrollment.enrolledGestures();
      _enrolledConfusables = enrollment.enrolledConfusables();
    });
    await _refreshRepCounts();
  }

  Future<void> _refreshRepCounts() async {
    final enrollment = _enrollment;
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

  void _onHoldStart() {
    setState(() => _status = null);
    _capture.beginCapture();
  }

  void _onHoldCancel() {
    _capture.endCapture(); // discard — press didn't complete
  }

  Future<void> _onGestureHoldEnd(Gesture gesture) async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    final samples = _capture.endCapture();
    try {
      final count = await enrollment.saveGestureRep(
        gesture,
        samples,
        stillnessFloor: _classifier.energyFloor,
      );
      _templateSource?.invalidate();
      if (!mounted) return;
      setState(() {
        _enrolledGestures = enrollment.enrolledGestures();
        _gestureRepCounts = {..._gestureRepCounts, gesture: count};
        _status = 'Attunement #$count saved for ${_gestureTitle(gesture)}.';
      });
    } on GestureEnrollmentException catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _onConfusableHoldEnd(GestureConfusable confusable) async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    final samples = _capture.endCapture();
    try {
      final count = await enrollment.saveConfusableRep(confusable, samples);
      if (!mounted) return;
      setState(() {
        _enrolledConfusables = enrollment.enrolledConfusables();
        _confusableRepCounts = {..._confusableRepCounts, confusable: count};
        _status =
            'Attunement #$count saved for confusable "${confusable.name}".';
      });
    } on GestureEnrollmentException catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  /// Runs the just-captured hold through GestureClassifier against the
  /// current enrolled templates and shows the verdict — a live calibration
  /// readout while capturing, mirroring the vocal tab's separation card.
  /// This is NOT the confusion-matrix harness (test/sorcerer/) — it checks
  /// one attempt, not the corpus.
  Future<void> _onTestHoldEnd() async {
    final source = _templateSource;
    if (source == null) return;
    final samples = _capture.endCapture();
    final templates = await loadGestureTemplates(source, _recognizedGestures);
    final match = _classifier.classify(samples, templates);
    if (mounted) setState(() => _lastTestMatch = match);
  }

  Future<void> _clearEnrollment() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await enrollment.clearAll();
    _templateSource?.invalidate();
    await _refreshRepCounts();
    if (!mounted) return;
    setState(() {
      _enrolledGestures = enrollment.enrolledGestures();
      _enrolledConfusables = enrollment.enrolledConfusables();
      _lastTestMatch = null;
      _status = 'Cleared every gesture attunement.';
    });
  }

  /// Gestures still short of the suggested attunements. The somatic
  /// counterpart of the vocal tab's under-enrolled set — and the one place
  /// this matters for correctness rather than polish: a gesture with a single
  /// stored rep is the only enrolled-set size measured to produce a
  /// wrong-gesture accept (GestureEnrollment.suggestedReps).
  Set<Gesture> get _underAttuned => {
        for (final g in _recognizedGestures)
          if ((_gestureRepCounts[g] ?? 0) < GestureEnrollment.suggestedReps) g,
      };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'These are the motions you perform to enhance a cast. Hold the '
          'button, perform the gesture the same way you would mid-duel, and '
          'release — the hold marks the start and end of the motion, so a '
          'clean release matters as much as a clean gesture.\n\n'
          'Your phone learns your motion, not a canonical one. Perform each '
          'gesture the way that comes naturally to you and repeat it that '
          'way; consistency is what it measures.',
        ),
        const SizedBox(height: 12),
        Text(
          'Attune each gesture at least '
          '${GestureEnrollment.suggestedReps} times. A single attunement is '
          'the one case measured to misread one gesture as another — after '
          'that the reading is reliable, and past four it improves slowly. '
          'There is no upper limit: keep going as long as you like, and your '
          'oldest attunement quietly retires to make room, so what you are '
          'read against is always how you move now.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        _sectionHeader('Enhancements — one per element'),
        _gestureWrap(_enhancementGestures),
        const SizedBox(height: 16),
        _sectionHeader('Melee — the close-quarters strike'),
        _gestureWrap(const [Gesture.melee]),
        const SizedBox(height: 20),
        _confusableCard(),
        const SizedBox(height: 20),
        _testCard(),
        const SizedBox(height: 20),
        _readinessLine(context),
        if (_status != null) ...[
          const SizedBox(height: 12),
          Text(_status!, style: Theme.of(context).textTheme.bodySmall),
        ],
        if (_enrolledGestures.isNotEmpty || _enrolledConfusables.isNotEmpty) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _clearEnrollment,
            child: const Text('Clear all gestures'),
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  String _gestureTitle(Gesture gesture) => switch (gesture) {
        Gesture.fire => kEnhancementLabel['fire']!,
        Gesture.air => kEnhancementLabel['air']!,
        Gesture.water => kEnhancementLabel['water']!,
        Gesture.earth => kEnhancementLabel['earth']!,
        Gesture.melee => 'Melee',
        Gesture.neutral => 'Neutral',
      };

  Widget _gestureWrap(List<Gesture> gestures) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final gesture in gestures)
            _captureCell(
              label: _gestureTitle(gesture),
              count: _gestureRepCounts[gesture] ?? 0,
              target: GestureEnrollment.suggestedReps,
              enabled: _enrollment != null,
              onHoldEnd: () => unawaited(_onGestureHoldEnd(gesture)),
            ),
        ],
      );

  Widget _captureCell({
    required String label,
    required int count,
    required bool enabled,
    required VoidCallback onHoldEnd,
    int? target,
  }) {
    final short = target != null && count < target;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoldToRecordButton(
          label: label,
          enabled: enabled,
          onHoldStart: _onHoldStart,
          onHoldEnd: onHoldEnd,
          onHoldCancel: _onHoldCancel,
        ),
        const SizedBox(height: 4),
        Text(
          short ? '$count of $target attunements' : '$count attunements',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _confusableCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Confusables',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Motions that should NOT trigger an enhancement: holding '
              'still, walking, and random flourish. These define the reject '
              "side of the boundary — without them the threshold can't be "
              'set, and a still hand reads as a spell. These want more '
              'attunements than a gesture does '
              '(${GestureEnrollment.corpusRepsForCalibration}): they have to '
              'cover everything a duel might mistake for a cast, not one '
              'motion performed consistently.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final confusable in GestureConfusable.values)
                  _captureCell(
                    label: confusable.name,
                    count: _confusableRepCounts[confusable] ?? 0,
                    target: GestureEnrollment.corpusRepsForCalibration,
                    enabled: _enrollment != null,
                    onHoldEnd: () =>
                        unawaited(_onConfusableHoldEnd(confusable)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The somatic answer to the vocal tab's separation card: how clearly your
  /// motions differ, measured on one attempt instead of on the corpus.
  Widget _testCard() {
    final match = _lastTestMatch;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How clearly your gestures differ',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Perform any motion and see how the classifier reads it right '
              'now, against whatever is enrolled so far.',
            ),
            const SizedBox(height: 12),
            HoldToRecordButton(
              label: 'Hold to test',
              enabled: _templateSource != null,
              icon: Icons.science_outlined,
              onHoldStart: _onHoldStart,
              onHoldEnd: () => unawaited(_onTestHoldEnd()),
              onHoldCancel: _onHoldCancel,
            ),
            if (match != null) ...[
              const SizedBox(height: 12),
              Text(
                match.stillnessGated
                    ? 'Read as: nothing (you held still)'
                    : 'Read as: ${_gestureTitle(match.gesture)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (!match.stillnessGated && match.distances.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    match.distances.entries
                        .map((e) =>
                            '${e.key.name}: ${e.value.toStringAsFixed(2)}')
                        .join('  ·  '),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// States where the enrollment stands without ever refusing anything —
  /// same posture as the vocal separation card (§8.7): warn plainly, never
  /// block. Nothing on this page gates a duel today; [kSomaticCaptureEnabled]
  /// does.
  Widget _readinessLine(BuildContext context) {
    final short = _underAttuned;
    final text = short.isEmpty
        ? 'Every gesture has at least '
            '${GestureEnrollment.suggestedReps} attunements. More is welcome '
            'and never wasted.'
        : '${short.length} '
            '${short.length == 1 ? 'gesture is' : 'gestures are'} still '
            'short of ${GestureEnrollment.suggestedReps} attunements: '
            '${short.map(_gestureTitle).join(', ')}.';
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
  }
}
