# Practice Mode voice fixtures

Piper TTS renders of the 5 incantation words, used by
`test/practice/real_template_e2e_test.dart` to exercise the full
StreamingPhonemeScorer crossing logic against the real bundled templates
(`assets/practice_templates/*.json`, rendered from `it_IT-paola-medium`).

- `paola2_*.wav` — the SAME voice as the templates but a different
  *utterance*: `it_IT-paola-medium` re-rendered with
  `--length_scale 1.12 --noise_scale 0.85 --noise_w 0.9`. Proxy for the
  enrolled-player case (reference and query share a voice but are not the
  same recording). 22050 Hz — the test resamples to 16 kHz.
- `riccardo_*.wav` — a different voice entirely (`it_IT-riccardo-x_low`,
  natively 16 kHz). Proxy for the unenrolled-fallback case (player's voice
  vs the Piper reference).

Generated 2026-07-16 with Piper 2023.11.14-2 (`~/.piper/piper-bin/piper`);
riccardo model from `rhasspy/piper-voices` `it/it_IT/riccardo/x_low`.
Committed rather than regenerated because Piper isn't part of the repo
toolchain (see docs/M4_findings.md, Piper toolchain note).
