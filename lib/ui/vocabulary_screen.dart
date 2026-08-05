// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_screen.dart — where a player chooses the six words they cast with.
//
// VOCAL_RECALL_PLAN.md §8. Editing is STAGED: nothing a player types or records
// here touches the live vocabulary until they commit, and committing is
// all-or-nothing.
//
// Why staged (§8.8): a vocabulary swap changes several enrollment files plus
// the profile. Applying them one at a time would leave a window where a duel
// uses half the old words and half the new ones, charging mana penalties for
// mistakes the player did not make. So takes are recorded into a separate
// staging enrollment and adopted only once EVERY changed slot has them.
//
// Re-keying itself is free (§8.8). Retraining your own brain onto new words is
// the real cost and a sufficient limiter; it is also the counter-espionage
// move, and the answer to an opponent who cracked you between matches.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../sorcerer/mfcc.dart';
import '../sorcerer/vocabulary_profile.dart';
import '../sorcerer/vocabulary_separation.dart';
import '../sorcerer/vocal_enrollment.dart';
import '../sorcerer/vocal_slot.dart';
import 'widgets/hold_to_record_control.dart';

class VocabularyScreen extends StatefulWidget {
  const VocabularyScreen({super.key});

  @override
  State<VocabularyScreen> createState() => _VocabularyScreenState();
}

class _VocabularyScreenState extends State<VocabularyScreen> {
  VocabularyProfile _live = VocabularyProfile.defaults;

  /// The words as edited on this screen, live until committed.
  final Map<VocalSlot, String> _draft = {};
  final Map<VocalSlot, TextEditingController> _controllers = {};

  VocalEnrollment? _liveEnrollment;
  VocalEnrollment? _staging;

  /// Takes recorded on this screen, per slot, not yet adopted.
  final Map<VocalSlot, int> _stagedTakes = {};

  VocabularySeparation? _separation;
  bool _busy = false;
  String? _status;

  // One hold-to-record capture.
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  BytesBuilder? _pcm;
  VocalSlot? _recording;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final live = await VocabularyProfile.load();
    final enrollment = await VocalEnrollment.open();
    final docs = await getApplicationDocumentsDirectory();
    final staging =
        VocalEnrollment(Directory('${docs.path}/vocabulary_staging'));
    // A staging directory left behind by an abandoned edit is not a
    // half-committed vocabulary — nothing there was ever live — so clearing it
    // is always safe and keeps a stale take from being adopted later.
    await staging.clearAll();
    if (!mounted) return;
    setState(() {
      _live = live;
      _liveEnrollment = enrollment;
      _staging = staging;
      for (final slot in VocalSlot.values) {
        _draft[slot] = live.labelFor(slot);
        _controllers[slot] = TextEditingController(text: live.labelFor(slot));
      }
    });
    await _refreshSeparation();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    unawaited(_sub?.cancel());
    _recorder?.dispose();
    super.dispose();
  }

  // ── Which slots need a recording before this can be committed ────────────

  /// Slots whose word changed. Only these need re-recording — an untouched
  /// slot keeps the takes it already has.
  Set<VocalSlot> get _changed => {
        for (final slot in VocalSlot.values)
          if ((_draft[slot] ?? '').trim() != _live.labelFor(slot)) slot,
      };

  /// Changed slots still waiting for a take. Commit stays disabled until this
  /// is empty — that is the whole of the atomicity guarantee.
  Set<VocalSlot> get _awaitingTakes =>
      {for (final slot in _changed) if ((_stagedTakes[slot] ?? 0) == 0) slot};

  String? get _blockingReason {
    if (_changed.isEmpty) return null;
    for (final slot in _changed) {
      final reason = VocabularyProfile.rejectReason(_draft[slot] ?? '');
      if (reason != null) return reason;
    }
    // Checked across the WHOLE vocabulary, not just the edited slots: renaming
    // fire to "aqua" collides with an untouched water slot just as badly, and
    // two identical words can never be told apart no matter which one moved.
    final all = [
      for (final slot in VocalSlot.values)
        (_draft[slot] ?? '').trim().toLowerCase(),
    ];
    if (all.toSet().length != all.length) {
      return 'Two slots have the same word — they would be impossible to tell '
          'apart.';
    }
    if (_awaitingTakes.isNotEmpty) {
      return 'Record ${_awaitingTakes.length} more '
          '${_awaitingTakes.length == 1 ? 'word' : 'words'} before saving.';
    }
    return null;
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording(VocalSlot slot) async {
    if (_recorder != null) return;
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        _show('Microphone permission is needed to record a word.');
        return;
      }
      final pcm = BytesBuilder();
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      if (!mounted) {
        await recorder.stop();
        recorder.dispose();
        return;
      }
      setState(() {
        _recorder = recorder;
        _pcm = pcm;
        _sub = stream.listen(pcm.add, onError: (_) {});
        _recording = slot;
      });
    } catch (_) {
      recorder.dispose();
    }
  }

  Future<void> _stopRecording({required bool save}) async {
    final recorder = _recorder;
    final pcm = _pcm;
    final slot = _recording;
    if (recorder == null) return;
    await _sub?.cancel();
    try {
      await recorder.stop();
    } catch (_) {
      // Already stopped; the buffer is still good.
    }
    recorder.dispose();
    if (!mounted) return;
    setState(() {
      _recorder = null;
      _sub = null;
      _pcm = null;
      _recording = null;
    });

    final staging = _staging;
    if (!save || pcm == null || slot == null || staging == null) return;
    try {
      final result = await staging.saveFromRecording(
        slot,
        pcm.toBytes(),
        label: _draft[slot]?.trim(),
      );
      if (!mounted) return;
      setState(() => _stagedTakes[slot] = result.takeCount);
      await _refreshSeparation();
    } on EnrollmentException catch (e) {
      _show(e.message);
    }
  }

  // ── Separation (§8.7) ─────────────────────────────────────────────────────

  /// Measures the vocabulary that would actually be used: staged takes where
  /// they exist, live ones otherwise.
  Future<void> _refreshSeparation() async {
    final staging = _staging;
    final live = _liveEnrollment;
    if (staging == null || live == null) return;
    final takes = <VocalSlot, List<List<List<double>>>>{};
    for (final slot in VocalSlot.values) {
      takes[slot] =
          await staging.loadTakes(slot) ?? await live.loadTakes(slot) ?? const [];
    }
    final separation = VocabularySeparation.measure(takes);
    if (!mounted) return;
    setState(() => _separation = separation);
  }

  // ── Commit ────────────────────────────────────────────────────────────────

  Future<void> _commit() async {
    final staging = _staging;
    final live = _liveEnrollment;
    if (staging == null || live == null || _blockingReason != null) return;
    setState(() => _busy = true);
    try {
      final labels = {
        for (final slot in _changed) slot: _draft[slot]!.trim(),
      };
      // Takes first, profile second. Each enrollment file records the word it
      // holds audio for, so if this is interrupted the affected slot reads as
      // stale and falls back to the bundled template rather than scoring the
      // player against a word they no longer say.
      await live.adoptFrom(staging, labels);
      final profile = _live.withLabels(labels);
      await profile.save();
      await staging.clearAll();
      if (!mounted) return;
      setState(() {
        _live = profile;
        _stagedTakes.clear();
        _busy = false;
      });
      _show('Vocabulary saved. Practise it before your next duel.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _show('Could not save the vocabulary: $e');
    }
  }

  Future<void> _revert() async {
    await _staging?.clearAll();
    if (!mounted) return;
    setState(() {
      _stagedTakes.clear();
      for (final slot in VocalSlot.values) {
        _draft[slot] = _live.labelFor(slot);
        _controllers[slot]!.text = _live.labelFor(slot);
      }
    });
    await _refreshSeparation();
  }

  void _show(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final blocking = _blockingReason;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Incantations'),
        actions: [
          if (_changed.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _revert,
              child: const Text('Revert'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'These are the words you speak to cast. Choose words you '
            'associate with each element — words you picked are far easier to '
            'recall mid-duel than ones you were handed.\n\n'
            'An opponent who learns your words can read your spells as you '
            'cast them. Changing your words costs nothing, so change them '
            'whenever someone has your measure.',
          ),
          const SizedBox(height: 20),
          _sectionHeader('Opener — spoken first, every cast'),
          for (final slot in VocalSlot.openers) _slotRow(slot),
          const SizedBox(height: 8),
          _sectionHeader('Elements — one per activation'),
          for (final slot in VocalSlot.elements) _slotRow(slot),
          const SizedBox(height: 20),
          _separationCard(),
          const SizedBox(height: 20),
          if (blocking != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                blocking,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton(
            onPressed:
                (_busy || _changed.isEmpty || blocking != null) ? null : _commit,
            child: Text(
              _changed.isEmpty ? 'No changes' : 'Save vocabulary',
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  String _slotTitle(VocalSlot slot) => switch (slot) {
        VocalSlot.fire => 'Fire',
        VocalSlot.air => 'Air',
        VocalSlot.water => 'Water',
        VocalSlot.earth => 'Earth',
        VocalSlot.openerGeneral => 'Cast',
        VocalSlot.openerSummon => 'Summon',
      };

  Widget _slotRow(VocalSlot slot) {
    final changed = _changed.contains(slot);
    final needsTake = _awaitingTakes.contains(slot);
    final takes = _stagedTakes[slot] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 76, child: Text(_slotTitle(slot))),
          Expanded(
            child: TextField(
              controller: _controllers[slot],
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: needsTake
                    ? 'Hold to record'
                    : (changed ? '$takes recorded' : null),
              ),
              onChanged: (value) => setState(() {
                _draft[slot] = value;
                // A changed word invalidates any take recorded for the old
                // one: those takes are audio of a different word.
                _stagedTakes.remove(slot);
                unawaited(_staging?.clearWord(slot));
              }),
            ),
          ),
          const SizedBox(width: 8),
          HoldToRecordButton(
            label: takes > 0 ? 'Again' : 'Record',
            icon: Icons.mic,
            enabled: !_busy &&
                (_recording == null || _recording == slot) &&
                VocabularyProfile.rejectReason(_draft[slot] ?? '') == null,
            onHoldStart: () => unawaited(_startRecording(slot)),
            onHoldEnd: () => unawaited(_stopRecording(save: true)),
            onHoldCancel: () => unawaited(_stopRecording(save: false)),
          ),
        ],
      ),
    );
  }

  /// §8.7: show the separation and warn plainly. Never refuse.
  Widget _separationCard() {
    final separation = _separation;
    if (separation == null) return const SizedBox.shrink();
    final warnings = separation.warnings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How clearly your words differ',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (separation.pairs.isEmpty)
              const Text('Record your words to see how well they separate.')
            else if (warnings.isEmpty)
              const Text('Your words are comfortably distinct.')
            else ...[
              for (final pair in warnings) ...[
                Text(
                  pair.isOpenerPair
                      ? '"${_draft[pair.a]}" and "${_draft[pair.b]}" sound '
                          'alike. These two decide whether your opponent can '
                          'hear a summon coming — and every time they are '
                          'confused, the cast costs you extra mana.'
                      : '"${_draft[pair.a]}" and "${_draft[pair.b]}" sound '
                          'alike. They will be mistaken for each other, and '
                          'each mistake costs mana.',
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: pair.meter),
                const SizedBox(height: 10),
              ],
              const Text(
                'You can keep them. Nothing here is forbidden — it will just '
                'cost you.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
