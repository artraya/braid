# Echo bleed: detect and dedup
status: ready
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

<!-- deliver -->

## Learning and next move

<!-- iterate -->
