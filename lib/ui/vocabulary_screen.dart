// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_screen.dart — "Attune Spell Components": the one place a player
// tunes the components they cast with. Two tabs, one per component type —
// **Vocal** (the six words, below) and **Somatic** (the five gestures, in
// widgets/gesture_training_panel.dart).
//
// The two tabs share a shape but not a mechanism, and deliberately so: words
// are chosen AND recorded (a rename invalidates its audio, so both are staged
// together), whereas a gesture has nothing to name — you only record it. So
// only the vocal side carries the staging/commit machinery described below.
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
//
// This is also the ONLY place voice takes are recorded. The practice drill
// used to carry its own enrollment card; it doesn't any more, because a word
// and the audio for it are one thing and splitting them across two screens let
// them drift. A player who tries to practise without enough takes is sent here
// first — see [VocabularyScreen.proceedToPracticeWith].

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
import '../spells/spell_asset.dart';
import 'practice_screen.dart';
import 'widgets/gesture_training_panel.dart';
import 'widgets/hold_to_record_control.dart';

class VocabularyScreen extends StatefulWidget {
  const VocabularyScreen({super.key, this.proceedToPracticeWith});

  /// Set when the player was diverted here on their way to practising a spell
  /// (library › Practice Incantation, with too few takes to score fairly —
  /// see VocalEnrollment.isPracticeReady). Two effects: every slot must reach
  /// [VocalEnrollment.minTakesForPractice] before the commit unlocks, and
  /// committing continues to the drill instead of just popping back.
  final SpellAsset? proceedToPracticeWith;

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

  /// Takes already on disk per slot, read at open and refreshed after every
  /// commit. Needed because a commit REPLACES a slot's takes with the staged
  /// ones rather than appending (adoptFrom) — so what a slot will end up with
  /// is the staged count where one exists and this otherwise, which is what
  /// [_effectiveTakes] returns and what the practice gate is measured against.
  Map<VocalSlot, int> _liveTakes = const {};

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
      _liveTakes = {
        for (final slot in VocalSlot.values) slot: enrollment.takeCount(slot),
      };
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

  /// What [slot] will hold once this edit commits — see [_liveTakes].
  int _effectiveTakes(VocalSlot slot) =>
      _stagedTakes[slot] ?? _liveTakes[slot] ?? 0;

  /// True when the player was sent here from the library's Practice entry
  /// point rather than choosing to re-key.
  bool get _isPracticeGate => widget.proceedToPracticeWith != null;

  /// Gate mode only: slots still short of [VocalEnrollment.minTakesForPractice].
  /// Practising against a vocabulary the scorer can't tell apart teaches the
  /// wrong lesson, so the drill stays behind this.
  Set<VocalSlot> get _underEnrolled => {
        for (final slot in VocalSlot.values)
          if (_effectiveTakes(slot) < VocalEnrollment.minTakesForPractice) slot,
      };

  /// Whether there is anything to write. Staged takes count on their own: a
  /// player topping up recordings for words they're keeping has made a real
  /// change even though no label moved.
  bool get _hasPendingWork => _changed.isNotEmpty || _stagedTakes.isNotEmpty;

  String? get _blockingReason {
    if (!_hasPendingWork && !_isPracticeGate) return null;
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
    if (_isPracticeGate) {
      final short = _underEnrolled;
      if (short.isNotEmpty) {
        return 'Practice needs ${VocalEnrollment.minTakesForPractice} '
            'recordings of each word so it can tell them apart. '
            '${short.length} ${short.length == 1 ? 'word is' : 'words are'} '
            'still short: ${short.map((s) => '"${_draft[s]}"').join(', ')}.';
      }
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
    // A satisfied gate with nothing staged is a pass-through, not a no-op:
    // the player already has the recordings the drill wanted, so asking them
    // to re-record words they own would be a dead end with a save button on
    // it. Only reachable defensively — the gate opens this screen precisely
    // because a slot was short — but a stuck screen is not worth the risk.
    if (!_hasPendingWork) {
      if (_isPracticeGate) _goToPractice();
      return;
    }
    setState(() => _busy = true);
    try {
      // Every slot with staged audio is adopted, not only the renamed ones —
      // topping up takes for a word you're keeping is a legitimate edit, and
      // it is the whole of what the practice gate asks for. Renamed slots
      // always have staged audio (the atomicity rule above), so this is a
      // superset of _changed.
      final adopted = {
        for (final slot in _stagedTakes.keys) slot: _draft[slot]!.trim(),
      };
      // Takes first, profile second. Each enrollment file records the word it
      // holds audio for, so if this is interrupted the affected slot reads as
      // stale and falls back to the bundled template rather than scoring the
      // player against a word they no longer say.
      await live.adoptFrom(staging, adopted);
      final profile = _live.withLabels({
        for (final slot in _changed) slot: _draft[slot]!.trim(),
      });
      await profile.save();
      await staging.clearAll();
      if (!mounted) return;
      setState(() {
        _live = profile;
        _liveTakes = {
          for (final slot in VocalSlot.values) slot: live.takeCount(slot),
        };
        _stagedTakes.clear();
        _busy = false;
      });
      if (_isPracticeGate) {
        _goToPractice();
        return;
      }
      _show('Vocabulary saved. Practise it before your next duel.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _show('Could not save the vocabulary: $e');
    }
  }

  /// Continues into the drill the player originally asked for. Replaces this
  /// route rather than stacking on it: they asked to practise, were diverted
  /// here, and have now paid the toll — Back from the drill should return to
  /// the library they started from, not to this page.
  void _goToPractice() {
    final spell = widget.proceedToPracticeWith;
    if (spell == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => PracticeScreen(spell: spell)),
    );
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
    // Always opens on Vocal: it is the tab a practice gate diverted the player
    // to, and the one with unsaved work to lose.
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Attune Spell Components'),
          actions: [
            if (_hasPendingWork)
              TextButton(
                onPressed: _busy ? null : _revert,
                child: const Text('Revert'),
              ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Vocal'),
              Tab(text: 'Somatic'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildVocalTab(context),
            const GestureTrainingPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildVocalTab(BuildContext context) {
    final blocking = _blockingReason;
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Why the player is here when they asked for a drill. Stated before
          // the words themselves, so it reads as an explanation rather than as
          // a refusal they discover at the bottom of the page.
          if (_isPracticeGate) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Before you can practise, record each of your words '
                  '${VocalEnrollment.minTakesForPractice} times in your own '
                  'voice. Practice scores you the way a duel does — against '
                  'your recordings — so without them it would mark you wrong '
                  'for words you said perfectly well.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'These are the words you speak to cast. Choose words you '
            'associate with each element — words you picked are far easier to '
            'recall mid-duel than ones you were handed.\n\n'
            'An opponent who learns your words can read your spells as you '
            'cast them. Changing your words costs nothing, so change them '
            'whenever someone has your measure.',
          ),
          const SizedBox(height: 12),
          Text(
            'Attune each word about '
            '${VocalEnrollment.suggestedTakes} times, and roughly the same '
            'number for every word — a word you have attuned far more than '
            'its neighbours starts winning ties it should lose. There is no '
            'upper limit: keep going as long as you like, and your oldest '
            'attunement quietly retires to make room, so what you are scored '
            'against is always how you speak now.',
            style: Theme.of(context).textTheme.bodySmall,
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
            // In gate mode the button is "get me to the drill", so an
            // unblocked gate enables it even with nothing to save.
            onPressed: (_busy ||
                    blocking != null ||
                    !(_hasPendingWork || _isPracticeGate))
                ? null
                : _commit,
            child: Text(
              _isPracticeGate
                  ? 'Save and proceed to practice'
                  : (_hasPendingWork ? 'Save vocabulary' : 'No changes'),
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ]);
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
    final needsTake = _awaitingTakes.contains(slot);
    final effective = _effectiveTakes(slot);
    // Every row states where it stands against the SUGGESTION, not just the
    // rows in flight: a count only guides a player if it's visible before they
    // have a reason to look. Under the suggestion it reads as progress
    // ("2 of 4"); at or above it, just the count — there is no ceiling to show
    // progress toward.
    final helper = needsTake
        ? 'Hold to attune'
        : effective < VocalEnrollment.suggestedTakes
            ? '$effective of ${VocalEnrollment.suggestedTakes} attunements'
            : '$effective attunements';
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
                helperText: helper,
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
            // "Again" only once THIS edit has staged a take — the button
            // labels what the next hold does to the staging set, not what the
            // slot holds on disk.
            label: (_stagedTakes[slot] ?? 0) > 0 ? 'Again' : 'Attune',
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
