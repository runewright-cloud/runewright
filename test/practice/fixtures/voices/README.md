# Practice Mode voice fixtures

Piper TTS renders of the 5 incantation words, used by
`test/practice/real_template_e2e_test.dart` to exercise the full
StreamingPhonemeScorer crossing logic against the real bundled templates
(`assets/practice_templates/*.json`, rendered from `en_US-lessac-medium`).

- `lessac2_*.wav` — the SAME voice as the templates but a different
  *utterance*: `en_US-lessac-medium` re-rendered with
  `--length_scale 1.12 --noise_scale 0.85 --noise_w 0.9`. Proxy for the
  enrolled-player case (reference and query share a voice but are not the
  same recording). 22050 Hz — the test resamples to 16 kHz.
- `amy_*.wav` — a different voice entirely (`en_US-amy-medium`). Proxy for
  the unenrolled-fallback case (player's voice vs the Piper reference).

Generated 2026-07-22 with Piper 2023.11.14-2 (`~/.piper/piper-bin/piper`);
both voice models from `rhasspy/piper-voices` (`en/en_US/lessac/medium`,
`en/en_US/amy/medium`). Committed rather than regenerated on every run
because Piper isn't part of the repo/CI toolchain (see docs/M4_findings.md,
Piper toolchain note) — but still regenerate the affected pair by hand (same
two commands, `--model` swapped) whenever the vocabulary or trainer voice
changes, as on 2026-07-22 when the trainer switched from Italian
(`it_IT-paola-medium`/`it_IT-riccardo-x_low`) to English (see
docs/M4_findings.md).
