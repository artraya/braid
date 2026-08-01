# Echo bleed: detect and dedup
status: verified
created: 2026-08-01
updated: 2026-08-01
release: production

## Outcome

Recording without headphones stops silently corrupting attribution: the owner
is warned in the panel while there is still time to plug in, and a Session
recorded on speakers anyway delivers a Note that does not attribute the far
end's words to "Me".

## Prompt

The researched design note (docs/echo-cancellation.md, 2026-08-01): Braid
assumes headphones and nothing detects otherwise. Speaker playback re-enters
the mic, both Tracks carry the far end's speech, and the merge attributes the
duplicate to "Me". This cycle is layers 0 and 3 of that note — detection and
transcript dedup; the DSP layers (1 and 2) only if these prove insufficient.

## Evidence and assumptions

- Fact: the Remote Track is a digital tap, byte-identical with or without
  headphones; damage is attribution, not audio (research note, 2026-08-01).
- Fact: both Tracks share one clock with drift compensation (ADR-0001), so
  echo appears at a single constant small positive lag — cross-correlation is
  definitive, and time-overlap for dedup needs no alignment search.
- Fact: `kAudioDevicePropertyTransportType` / `DataSource` identify built-in
  speakers directly; Bluetooth is ambiguous (AirPods vs HomePod), so the
  device check is a prior and the correlation is the proof.
- Assumption: transcript-level dedup (time overlap + text similarity) removes
  enough echo damage that the DSP layers can wait for evidence.
- Unknown: correlation threshold and window on this MacBook's actual speakers
  and room — tuned against a real speaker Session before trusting the warning.
- Unknown: the text-similarity metric that kills echoes without killing
  genuine "same words" interjections ("yeah, exactly") — start conservative.

## This cycle

1. Detection: at Start, read the default output device's transport type and
   data source; built-in speaker raises the prior. A few seconds into
   recording, cross-correlate decimated mic and remote streams; a clear peak
   at a small positive lag confirms bleed. Watch for output device changes
   mid-Session (AirPods dying). While recording, the panel's recording block
   shows the warning — the only moment the user can still plug in. The
   Session records that bleed was detected.
2. Dedup: for flagged Sessions only, after merge, drop "Me" utterances that
   time-overlap a Remote utterance with high text similarity — echo lags well
   under a second, so overlap is near-total. Genuine interruptions (different
   words) survive. The count of dropped utterances is logged, and the
   delivered Note is otherwise untouched; delivery stays hands-off.
3. A completed flagged Session also warns after the fact via the existing
   warning path, so a headphones-forgotten meeting is understood, not
   mysterious.

## Not this cycle

- DSP cancellation of any kind (layers 1–2; needs the fixture set first).
- VPIO (rejected in the research note).
- Dedup for unflagged Sessions — no bleed, no reason to risk dropping real
  speech.
- README headphones note rewrite beyond one plain sentence.

## Approach

A small `EchoBleedDetector` in BraidCore fed decimated mono frames from the
existing IOProc (both scratch buffers already exist there), correlating off
the real-time thread at a slow cadence; vDSP, zero dependencies. Device
transport/data-source query and a property listener beside the existing
device helpers in CaptureEngine. `Session` gains an optional bleed flag
(Codable-safe like expectedSpeakers). Dedup is a pure `Transcript` function
(overlap window + token-similarity), applied in `JobQueue.execute` when the
flag is set, before summarising. Panel warning rides the existing recording
block; post-hoc warning reuses the R16 pattern.

## Risks and routes

- False-positive bleed warning (correlated by coincidence) — conservative
  threshold plus repeated-window confirmation before flagging; warning wording
  stays calm ("speakers detected").
- Dedup drops a genuine "Me" line — gated on the flag, overlap AND similarity
  both required, dropped lines logged; transcript remains reviewable.
- RT-thread cost of feeding the detector — decimation in the IOProc is a copy
  and stride; correlation itself runs on a utility queue. R4's CPU budget
  (≤5%) is the check.

## Checks

- [ ] Detector unit tests: synthetic mic = remote delayed 10–30 ms plus noise
      → flags and reports the lag; independent signals → never flags.
- [ ] Dedup fixtures: echoed far-end lines on the Mic Track removed; a
      genuine overlapping interruption with different words kept; unflagged
      Session passes through byte-identical (regression).
- [ ] End-to-end fixture Job with the flag set delivers hands-off with the
      deduped transcript, and `--ui-preview` shows the recording-block
      warning; CPU during a 10-minute flagged recording stays within R4.

## Result

Delivered 2026-08-01. All three checks pass; 63 tests green (6 new), build
clean, geometry PANEL-GEOMETRY-OK, 14 snapshots.

**What changed**

- `EchoBleedDetector` (new, BraidCore/Capture): decimates both mono streams to
  ~4 kHz in the IO path, correlates mic against remote over 0–100 ms lags in
  1 s windows on a utility queue, mean-removed (a shared DC offset would
  otherwise correlate at every lag — caught by the fixture during delivery and
  hardened in the detector, not just the test). Confirmation needs two windows
  agreeing on the lag within 5 ms and is sticky for the Session.
- CaptureEngine: output-route prior (`kAudioDevicePropertyTransportType` +
  `DataSource`; built-in speaker = likely, headphone jack clears it, Bluetooth
  stays ambiguous by design) with a default-output listener for mid-Session
  device changes; feeds the detector matched frames; `Result.bleedDetected`.
- `Session.bleedDetected` (optional, decode-safe); set at Stop.
- `Transcript.dedupingEchoes`: drops "Me" utterances that time-overlap a
  Remote utterance (±0.5 s tolerance) with ≥60% token containment and ≥3
  tokens; interruptions and short agreements survive. Applied in
  `JobQueue.execute` only when the flag is set, before auto-assign.
- Recording block shows the warning live (proof outranks prior); enqueue
  emits `echoBleedWarning` → notification, mirroring the R16 pattern; CLI
  prints it. README gained its one headphones sentence.

**Checks**

1. `detectorConfirmsADelayedCopyAndReportsTheLag` (15 ms echo at −16 dB →
   confirmed, lag within 5 ms), `detectorNeverConfirmsIndependentSignals`.
   Both deterministic (seeded noise). Pass.
2. `dedupDropsTheEchoedLineAndKeepsTheInterruption`,
   `dedupSparesShortLinesAndCleanTranscripts` (clean transcript returns
   equal). Pass.
3. `bleedFlagGatesDedupThroughTheWholePipeline` — flagged Session delivers
   hands-off minus the echo with the warning event; identical unflagged
   Session keeps its Mic Track intact. `panel-recording-bleed` snapshot shows
   the in-recording warning. `detectorProcessesTenMinutesCheaply` is the R4
   proxy (10 min of audio analysed in ≪5 s CPU); the in-call `top`
   measurement remains owner-run, as R4 itself always has been.

**Review** (self, against contracts): one real defect found and fixed during
delivery — the original correlation was DC-sensitive; a positive-mean fixture
confirmed spuriously at an arbitrary lag. Mean removal fixed it and the test
fixture was centered to keep testing the correlation rather than the offset.
No blocking findings remain.

**Limitations within contract**: the 0.25 correlation threshold and the
two-window rule are validated on synthetic fixtures; the cycle's stated
unknown — behaviour on this MacBook's real speakers and room — needs one real
speaker Session, which is exactly what iterate should look at. Bluetooth
outputs never raise the device prior; the correlation alone carries those.

## Learning and next move

<!-- iterate -->
