# Local models: research and orchestration plan

Status: **direction decided by the owner 2026-08-02; engine choice pending the
spike below. Nothing built.** This note is the research record and the plan for
the iteration. It supersedes nothing until the spike reports and shape amends
the contracts.

## What is changing, and why now

[ADR-0002](adr/0002-cloud-diarization-over-local.md) parked local ML, it did not
reject it. Its own text names the conditions for coming back, and they have
arrived:

1. **Public use.** The README currently sends capable machines away: "Not for
   you if your machine has headroom for on-device transcription. Run one."
   Since the adoption decision (2026-08-01) Braid is developed for public use,
   so that carve-out now excludes exactly the users we invited in. Local STT
   also removes one of the two API keys from setup, which serves the philosophy
   directly: less interaction, more automation.
2. **The tooling matured into precisely the shape ADR-0002 evaluated.**
   FluidAudio, the same project the ADR named, now ships batch pyannote
   Community-1 diarization at 10.6% DER on AMI SDM running 323x realtime, plus
   Parakeet TDT v3 ASR, all CoreML on the Neural Engine, Apache 2.0, actively
   maintained through July 2026. Apple shipped a new on-device ASR
   (SpeechAnalyzer / SpeechTranscriber, macOS 26+) that benchmarks above every
   Whisper variant on clean speech, costs zero download and zero dependencies.
3. **The timing insight ADR-0002 did not weigh.** The 8GB constraint governs
   *during the call*, when Teams is strangling the machine. Braid's pipeline is
   batch: inference runs after Stop, when the call app has released everything.
   R4 (≤5% CPU, ≤100MB while recording) is untouched by local inference that
   runs later. The constraint that justified "no local ML" applies to a window
   in which no ML would run.

What does not change:

- Capture (ADR-0001). The tap, the aggregate device, two CAF tracks.
- **No voiceprints (ADR-0003). A hard boundary, restated below, because local
  diarization is exactly where it could erode silently.**
- The Summariser stays Claude. A local summary via Apple Foundation Models is
  noted at the end as a future direction, not part of this iteration.
- Hands-off delivery, one window, notifications-only while closed.

## The candidates, with evidence

### ASR engines

| | Apple SpeechTranscriber | FluidAudio Parakeet TDT v3 | WhisperKit / whisper.cpp |
|---|---|---|---|
| Accuracy evidence | Best on clean scripted speech in a 13,000-recording comparison (4.0% WER Italian, best overall result in that benchmark); beats every Whisper model on another independent test | 2.15 to 2.5% WER LibriSpeech class; **wins on disfluent natural speech in 3 of 5 languages**, which is what meetings are | WhisperKit best-in-class proper-noun biasing; otherwise slower and heavier than both |
| Speed | ~3x faster than Whisper Small | ~120 to 190x realtime on M-series; an hour of audio in about 20 to 30 seconds | ~146x (large-v3) at best |
| Weight | **Zero download** (OS-managed model assets), zero dependencies | Model download on the order of half a gigabyte (verify at spike), one SPM dependency | Hundreds of MB plus C++ vendoring against ADR-0004's grain |
| Key Terms | **`contextualStrings` via AnalysisContext**: direct parity with today's Key Terms lever | No keyword biasing; raw jargon WER ~20% in testing, the one confirmed weakness | Prompt-biasing (WhisperKit) |
| Timestamps | Per-run `audioTimeRange` attribute; granularity at word level unconfirmed | Token-level durations, native to the TDT architecture | Word-level |
| License / OS | OS framework, macOS 26+ | Apache 2.0, models MIT/Apache | MIT / MIT |

No engine wins everything. The two that matter for Braid pull in opposite
directions: Apple keeps the Key Terms lever (the single highest-leverage
accuracy input per the phase-6 verification record) and adds zero weight;
Parakeet is stronger on exactly the audio a meeting produces (disfluent,
interrupted, compressed far-end) and has honest word timing. This is why the
plan starts with a spike on our own fixtures rather than a choice made from
other people's benchmarks.

### Diarization

One serious Swift-native option: **FluidAudio's pyannote Community-1 offline
pipeline**. 10.6% DER on AMI SDM (a meeting corpus, the right genre) at 323x
realtime, VBx clustering, CoreML. Its streaming siblings (LS-EEND, Sortformer)
are markedly worse (31 to 55% DER) and exist for live use; ADR-0002 already
named LS-EEND as the route to a future live transcript, and that stays true and
stays future. Diarization is needed **only on the Remote Track**; whichever ASR
engine wins, the diarizer is FluidAudio.

### What the community ships (the pattern is established practice)

- **swift-scribe** (FluidInference's own example): SpeechAnalyzer ASR +
  FluidAudio diarization + Foundation Models summaries, fully local, macOS 26.
  This is structurally Braid's pipeline minus the two-track capture advantage.
- **meetily**: Parakeet/Whisper + diarization + Ollama summaries, Rust, fully
  local meeting notes.
- **anarlog / Hyprnote**: whisper-family local transcription, local LLM
  summaries, same no-bot capture posture as Braid.

Nobody in that list has Braid's split-track design, which is our edge: they
diarize a mixed signal; we only ever diarize the far end.

## Why Braid's design makes this easier than the general problem

ADR-0002's core objection was the "genuinely error-prone reconciliation" of an
unlabelled transcript against independent diarization segments. Three things
shrink that risk to a measurable engineering task:

1. **The Mic Track needs no diarization at all.** It is "Me" structurally.
   Half the pipeline is plain ASR.
2. **Only the Remote Track is aligned**, and it contains only the far end:
   fewer voices, no self-voice confusion, and speaker turns are cleaner because
   the user's interjections are on the other file. Words map to speaker
   segments by time overlap; the merge that follows is the same two-list
   interleave on the shared clock that R6 already defines. The alignment is
   scoped, not open-ended, and it is the standard pattern the tools above ship
   every day.
3. **Batch removes every real-time constraint.** Stages run sequentially,
   models load and unload one at a time, and seconds of CPU are free. The same
   properties the echo-cancellation note exploits.

And the measurement problem is already solved in principle: `test-audio/` holds
real call fixtures with an AssemblyAI reference response. The spike compares
local output against the pipeline we already trust, on the machine we actually
run, not against leaderboard corpora.

## Proposed architecture

**A LocalAdapter behind the existing STTProvider seam.** The cloud Adapter is
untouched; the seam was built as insurance and this is the claim.

```
Recording (two CAF)
  ├─ Mic Track ────▶ ASR ──────────────────────────▶ utterances, all "Me"
  └─ Remote Track ─▶ ASR ─▶ diarize ─▶ align words ─▶ utterances, Speaker 1…n
                                        to segments
            └──────────── same merge rule, same Transcript ────────────┘
```

- **Engine seam, spike-lifetime only.** Inside the LocalAdapter, a minimal
  internal `TranscriberEngine` protocol with Apple and Parakeet
  implementations exists for the spike; the loser is deleted, the protocol
  stays as the one-file insurance policy, mirroring the
  AssemblyAI/ElevenLabs precedent.
- **No FLAC for local.** The Transcoder becomes a cloud-path step; local reads
  the CAF originals directly. Less code runs, not more.
- **Model manager.** Download once on first enable, size shown before
  confirming, checksummed, cached under Application Support. FluidAudio
  supports offline staging and custom registries, so an air-gapped install is
  possible. After the one confirmation, everything is automatic forever.
- **Provider modes: Cloud | Local | Auto.**
  - *Auto* (default once local is installed): local first; falls back to cloud
    only on local failure and only when keys exist; the fallback is always
    disclosed, in the notification and in the Note's existing `provider`
    frontmatter field (R10 already carries provenance, so this costs nothing).
  - *Local*: audio never leaves the machine, full stop. Failures park for
    user-initiated Retry under the existing R7/R8 taxonomy. No silent change
    of privacy posture, ever.
- **Deferral rule.** Local inference never runs while a Session is recording.
  The JobQueue is already serial; this adds one condition. It protects R4 and
  bounds peak memory on 8GB machines, since capture and inference never
  coexist.
- **ADR-0003 enforcement, stated as a requirement.** Diarization produces
  speaker embeddings in memory; they die with the Job. Nothing audio-derived
  about a speaker survives to disk or to another Session. FluidAudio's speaker
  enrollment APIs are off-limits. A test asserts the Application Support tree
  contains no embedding artifacts after a Job completes.

## Contract changes (shape owns these; this note only proposes)

- **ADR-0005 (new):** local STT and diarization as a Provider. Supersedes
  ADR-0002's v1 prohibition while preserving its record; documents the engine
  choice with the spike's numbers as evidence.
- **ADR-0004 (revise):** either one pinned SPM dependency (FluidAudio,
  Apache 2.0, exact version) or vendored CoreML models with minimal pipeline
  code; decided at spike once the transitive dependency surface is known. Exit
  strategy recorded: the models are standard CoreML artifacts.
- **SPEC:** rewrite non-goal 4 (local ML allowed, post-Stop only, never during
  recording); new **R20** (provider modes, disclosed fallback, deferral rule,
  local Job completes within 5 minutes per audio-hour); new **R21** (no
  audio-derived speaker data persists beyond its Job); scope R6's
  AssemblyAI-specific fields to the cloud Adapter; amend R13 (AssemblyAI key
  optional when local is installed); amend R14 (zero-cost STT rows, cost
  display shows Claude only).

## Measurement before commitment

The echo note's rule applies: decide the metric before writing the code.

- **Harness:** a script runs a fixture Recording through each engine plus the
  diarizer and produces a Transcript via the existing merge. All outputs stay
  untracked; the fixtures are real personal calls.
- **Metrics, on the M3 Air itself:**
  - WER against the AssemblyAI reference transcript, with a human spot-check
    (the reference is trusted, not ground truth).
  - Attribution error at speaker turns against AssemblyAI's labels: the number
    that actually decides whether a Note can be trusted.
  - Key Terms hit rate: the fixtures contain known jargon; count recoveries
    per engine, Apple with `contextualStrings` versus Parakeet raw.
  - Wall time and peak RSS per stage.
  - en_AU locale asset availability for SpeechTranscriber.
- **Decision gate:** if the best local WER is materially worse than cloud on
  real call audio (worse than ~1.5x relative) or turn attribution visibly
  fails, local ships as explicit opt-in labelled experimental, Auto keeps
  preferring cloud, and the numbers go in ADR-0005 either way. No launder.

## The cycles

1. **Spike and measurement** (~1 to 2 days). The harness, both engines, the
   diarizer, the metrics above, run on the owner's machine. Output: the engine
   decision and a drafted ADR-0005. Gates everything after it.
2. **Contracts, then the local pipeline behind a dev flag** (~2 to 4 days).
   shape lands ADR-0005, the ADR-0004 revision, and the SPEC amendments; then
   the model manager, LocalAdapter end-to-end, the deferral rule, the
   no-persistence test, and fixture regression against the cloud reference.
   Invisible to users.
3. **Product surface** (~1 to 2 days). Settings provider modes, first-enable
   download flow, Auto fallback policy with disclosure, cost display, README
   rewrite: the "Not for you if" carve-out inverts into "bring your own
   machine headroom or use the cloud path", and setup drops to one API key.
4. **Iterate gate.** The SPEC's own rolling standard, applied to the local
   path: 9 of the first 10 real calls deliver a trustworthy Note hands-off
   before Auto prefers local by default. Evidence, not enthusiasm.

## Explicitly out of scope, recorded for later

- **Local summarisation via Apple Foundation Models** (the swift-scribe
  pattern). Would make Braid zero-key and fully offline. Deferred because
  Opus-class summary quality is the product; measure the gap another day.
- **Live transcript** via LS-EEND streaming diarization, per ADR-0002's
  original note. Batch remains the design.
- **Echo cancellation interplay:** the bleed work
  ([echo-cancellation.md](echo-cancellation.md)) is provider-independent and
  composes with local unchanged; Layer 3 dedup runs on the merged Transcript
  regardless of which Adapter produced it.

## Risks

- **Real-call accuracy is unproven until the spike.** Every public benchmark
  is clean speech or meeting corpora, not compressed Teams far-end audio. This
  is the whole reason the spike exists.
- **Apple timestamp granularity.** If `audioTimeRange` runs prove too coarse
  for turn-boundary attribution, Parakeet wins by default and the Key Terms
  regression must be mitigated (post-pass fuzzy correction against the Key
  Terms list; measure before building).
- **Parakeet jargon weakness.** ~20% WER on technical terms without biasing,
  and Key Terms is our top accuracy lever today. The spike's hit-rate metric
  decides how much this costs on real audio.
- **Dependency surface.** FluidAudio pinned exactly; transitive dependencies
  audited at spike; ADR-0004 revision records the exit.
- **8GB peak memory.** Measured at spike; the deferral rule bounds the worst
  case by construction.
- **Fixture privacy.** All spike inputs and outputs remain untracked;
  `test-audio/` stays gitignored.

## Sources

- [FluidAudio](https://github.com/FluidInference/FluidAudio) and its
  [benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md),
  [ASR getting started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md)
- [swift-scribe: SpeechAnalyzer + FluidAudio + Foundation Models](https://github.com/FluidInference/swift-scribe)
- [Dictato: four engines on 13,000 recordings](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/)
- [Inscribe: Apple Speech API vs Whisper benchmark](https://get-inscribe.com/blog/apple-speech-api-benchmark.html)
- [Whisper Notes: Parakeet v3 vs Whisper](https://whispernotes.app/blog/parakeet-v3-default-mac-model),
  [Spokenly: Parakeet vs Whisper](https://spokenly.app/blog/parakeet-vs-whisper)
- [Argmax on Apple SpeechAnalyzer and WhisperKit](https://www.argmaxinc.com/blog/apple-and-argmax)
- [meetily](https://github.com/Zackriya-Solutions/meetily),
  [anarlog (Hyprnote)](https://github.com/fastrepl/anarlog),
  [Hyprnote open source](https://hyprnote.com/opensource)
- [Apple Developer Forums: SpeechAnalyzer on macOS 26](https://developer.apple.com/forums/thread/819555)
