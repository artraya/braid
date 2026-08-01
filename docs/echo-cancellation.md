# Speaker bleed into the Mic Track

Status: **researched design note, nothing built.** First written 2026-08-01;
rewritten the same day after a full research sweep (sources at the bottom).
Intended input to a `/shape` cycle.

## The problem

Braid assumes headphones. Nothing in the app says so and nothing detects otherwise.

Without headphones the far end comes out of the speakers and back into the mic, so
their speech lands on **both** Tracks. There is no feedback loop and no howl: the
Remote Track is a digital tap on the output stream (`CaptureEngine.swift:137`), not
a recording of the room, so it is byte-identical whether headphones are worn or
not. Braid never plays the Mic Track out, so there is no loop gain.

The damage is **attribution, not intelligibility**. Both Tracks are transcribed
independently and the Mic Track is labelled "Me" unconditionally
(`AssemblyAIAdapter.swift`). So the far end's words appear a second time,
time-overlapping their real utterance, attributed to the user. The Summariser then
hands their decisions and action items to the user. A wrong owner reads as correct
and is worse than a missing one. Secondary: during double talk the user's own
lines degrade because their voice is mixed with the echo.

Typical echo is 20 to 30 dB below the direct voice and lags 10 to 30 ms. Quiet to
a human, comfortably loud to a Provider.

Nothing upstream saves us. Teams' echo canceller cleans what Teams *sends*, not
what the input device hands to Braid, which pulls the raw default input with no
voice processing.

## What the research established

### The industry does exactly what we sketched

Recall.ai, which sells the capture infrastructure this category is built on, is
explicit: the standard approach is "an acoustic echo cancellation (AEC) library,
which takes both system audio and microphone input to remove overlapping sounds",
plus "logic to detect the output device type and accordingly enable or disable
AEC", and they name the hard parts as keeping speaker volume intact, minimising
delay, and keeping the two streams synchronized. Braid already has the two
streams, sample-aligned on one clock. The detection layer and the AEC pass are
the missing pieces, and they are the same two pieces the industry names.

Granola does **not** robustly solve this. Its own troubleshooting docs list
speaker echo as a known accuracy problem and point users at a headset. Doing this
well is ahead of the category, not parity.

### Apple's VPIO: better than we first thought, still wrong for us

Correction to the first draft of this note, which treated "does VPIO cancel other
apps' output?" as open. Empirical evidence says it does: Scripta, a local
transcription app with our exact capture shape, enables
`inputNode.setVoiceProcessingEnabled(true)` and gets working cancellation of
meeting audio it never rendered, and the standalone `AECAudioStream` library does
the same. The system canceller references the device output mix, not just the
app's own bus. macOS 14 added `AUVoiceIOOtherAudioDuckingConfiguration`
(WWDC23 session 10235) precisely because voice processing interacts with other
apps' output; Scripta has to set `enableAdvancedDucking: false, duckingLevel: .min`
to stop macOS turning the meeting down.

So VPIO is *capable* here. It is still the wrong choice for Braid:

1. **Multi-app voice processing is unresolved.** An open Apple forum thread
   (751100, no Apple reply) reports that when a recorder app and Zoom/Teams both
   enable voice processing, one cuts off the other's input stream. Teams and Zoom
   do use voice processing. Betting the recording on an undocumented interaction
   that has open cut-out reports is not acceptable for an app whose one job is to
   not lose the meeting.
2. **It breaks the single-clock design.** VPIO wants to own the input device;
   the Mic Track would leave the aggregate whose shared clock every Transcript
   timestamp depends on (ADR-0001). That trades a headphones-only problem for an
   always problem.
3. **Documented side effects, undocumented behaviour.** Enabling it silently
   changes the mic format to 9 channels (Scripta hit converter crashes), applies
   AGC and noise suppression that are not meaningfully optional, and ducks other
   apps' audio unless configured not to on macOS 14+. Apple's documentation of
   all this is thin to nonexistent.
4. **Real time buys us nothing.** The pipeline is batch. We can do better than a
   real-time canceller precisely because we are not one.

Keep the one-hour spike (play audio from another app, capture through VPIO,
observe) only if live in-meeting features ever appear on the roadmap.

### Why Braid's position is unusually strong

Every good real-time canceller (FaceTime, Teams, AEC3 in Chrome) fights three
things we do not have:

- **No lookahead, 10 to 20 ms budget.** We run after the Session ends; seconds of
  CPU are free and we can read the whole file twice.
- **Reference acquisition.** A discuss-webrtc thread confirms Chrome's AEC cannot
  cancel other processes' audio because it cannot get a reference for it. Our
  Remote Track *is* the reference: the undistorted digital original of exactly
  what the speakers played, already on disk next to the mic file.
- **Clock drift between playback and capture devices**, the main source of AEC
  complexity. Our two Tracks come from one aggregate device with drift
  compensation (ADR-0001), so the echo delay is one constant for the whole
  Session. Both Tracks pass through the same ExtAudioFile conversion to 16 kHz
  from the same IOProc, so alignment survives the file format.

Offline cancellation with a perfect reference and a fixed delay is a much easier
problem than the one the famous implementations solve.

### The state of the art, honestly assessed

| Option | What it is | Licence / size | Fit |
|---|---|---|---|
| **WebRTC AEC3** via `pulseaudio/webrtc-audio-processing` v2.0 (M131) | Best open-source classical AEC; partitioned-block frequency-domain adaptive filter + residual suppression | BSD; large C++ vendoring job, meson build | Highest classical quality; works file-wise offline at 16 kHz; heaviest clash with ADR-0004 (zero dependencies) |
| **speexdsp** echo canceller (AUMDF) | Small classical AEC, a handful of C files | Permissive; trivial SwiftPM C target | Weaker than AEC3, but our fixed delay and gating remove most of what makes it weak |
| **DTLN-aec** | Neural AEC, MIT, pretrained (1.8M/3.9M/10.4M params), top-tier in Microsoft's AEC Challenge among open models | MIT, but needs TFLite or a Core ML conversion | Best raw quality of anything open; a runtime dependency ADR-0004 exists to forbid; built for MOS, overkill for WER |
| **ByteAudio-18** (ICASSP 2023 challenge winner) | Hybrid DSP + two-stage neural | Not open source | Establishes that hybrid classical-then-neural is the state of the art; not obtainable |
| **Custom gate + spectral suppressor** in vDSP/Accelerate | ~200 lines, no adaptive filter, exploits fixed alignment | Ours; zero dependencies | Cannot reach FaceTime transparency; does not need to. Cannot diverge, no double-talk detector needed |

The judged metric in Microsoft's AEC Challenge is opinion score **and word
accuracy**. Our target is only the second one. That asymmetry is the whole
opportunity: an approach far below state of the art on MOS can be at parity on
WER when the echo-only frames are simply removed.

## The design

Four layers. Each is independently shippable and independently valuable.

### Layer 0: detect and warn, during the Session

- Query the default output device at Session start:
  `kAudioDevicePropertyTransportType` (built-in / USB / Bluetooth / HDMI), and on
  built-in output `kAudioDevicePropertyDataSource` to separate internal speaker
  from headphone jack. Built-in speaker is near-proof of bleed. Bluetooth is
  ambiguous (AirPods vs HomePod), so this is a prior, not proof.
- Confirm acoustically: cross-correlate the two live streams over short windows a
  few seconds in (vDSP). A clear peak at a small positive lag is definitive, and
  its position measures the exact echo delay for Layer 2.
- Surface in the panel **while recording**, the only moment the user can still
  plug in. Listen for output-device changes mid-Session; the realistic failure is
  AirPods dying forty minutes in. Reuse the R16 warning path for after the fact.

### Layer 1: gate before cancelling

Classify every ~20 ms frame using both Tracks: silence / user only / far end
only / both. In far-end-only frames, which are most of the echo, **zero the Mic
Track**. Perfect suppression, no residual, nothing for the Provider to
mis-transcribe. Offline lookahead (~200 ms) means the start of the user's reply
is never clipped, which is the artefact that makes real-time gating sound bad.
Only genuine double-talk frames, a small fraction of a Session, then need real
cancellation.

### Layer 2: cancellation for the double-talk frames

First version: **spectral suppression only**, custom, in Accelerate. Align the
Remote Track by the measured fixed delay; where the reference has energy at a
time-frequency bin and the mic energy is proportional, duck the bin. No adaptive
filter, nothing to diverge, no dependencies.

Escalation path if fixture WER demands it, in order: speexdsp as a vendored C
target (small, permissive, fine with a known delay); `webrtc-audio-processing`
AEC3 (accept the vendoring cost knowingly, as an ADR); DTLN-aec via Core ML
(accept a model runtime, as an ADR). Each step is an explicit decision against
ADR-0004, taken only on evidence.

Placement: a new Pipeline stage between capture and `Transcoder.toFLAC`, reading
`mic.caf` and `remote.caf`, writing a cleaned Mic Track. Runs only when Layer 0
flagged the Session. Capture is untouched; ADR-0001 stands.

### Layer 3: Transcript backstop

Drop "Me" utterances that time-overlap a Remote utterance with high text
similarity; the Provider's word confidence assists (echo-derived words score
low). Catches whatever survives the audio layers, and works even for Sessions
recorded before any of this ships.

## Measurement, decided before any DSP

**Fixtures.** Take a real Session recorded on headphones (clean Mic Track). Play
its Remote Track through the MacBook speakers in a quiet room and record the mic:
that is the true echo signal for our actual hardware, room and speaker
distortion included. Mix into the clean Mic Track at several levels for matched
pairs with known ground truth.

**Metrics.** Word error rate of the final Transcript against the headphones
Transcript, and the count of utterances attributed to the wrong speaker. Not
decibels of suppression; that optimises the wrong thing.

## Recommended order

1. **Layer 0** detection and in-panel warning (~half a day). Removes most
   real-world harm immediately; also produces the delay measurement Layer 2 needs.
2. **Layer 3** Transcript dedup (~half a day). Protects the Note when the warning
   is ignored; retroactively useful.
3. **Fixtures + Layer 1 + Layer 2 first version** (two to three days). This is
   where the quality lives.
4. Escalate Layer 2 along the path above only if the fixtures say so.

Steps 1 and 2 reach category parity. Step 3 exceeds it.

## Rejected

- **VPIO as the canceller** — reasons above. Revisit only for live features.
- **Neural AEC as the first move** — best open quality (DTLN-aec) but wrong cost:
  a model runtime dependency against ADR-0004, targeting a metric (MOS) we do not
  need, for a problem instance (fixed delay, perfect reference, batch) that the
  cheap approach is unusually suited to.
- **"Turn your volume down to 30 to 40%"** — the category's actual answer today.
  Not an engineering position.

## Sources

- Recall.ai, [How to get access to system audio](https://www.recall.ai/blog/how-to-get-access-to-system-audio) — industry-standard approach: AEC library over both streams, output-device detection, sync named as the hard part
- Granola, [transcription troubleshooting](https://docs.granola.ai/help-center/troubleshooting/transcription-issues) — speaker echo acknowledged, headset recommended
- Scripta, [dev.to build log](https://dev.to/thehwang/building-a-100-local-meeting-transcription-app-for-macos-with-whispercpp-and-screencapturekit-33m7) — VPIO works against other apps' output; 9-channel surprise; ducking workaround
- Apple, [WWDC23 What's new in voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/) — other-audio ducking API, muted talker detection
- Apple Developer Forums, [thread 751100](https://developer.apple.com/forums/thread/751100) — two apps with voice processing conflict, unanswered
- Apple Developer Forums, [thread 733733](https://developer.apple.com/forums/thread/733733) — VPIO gain change expected, AGC toggle
- discuss-webrtc, [Chromium AEC on out-of-process system audio](https://groups.google.com/g/discuss-webrtc/c/v592nFc4cO4) — AEC3 cannot reference other processes' audio; pointer to standalone webrtc-audio-processing
- PulseAudio, [webrtc-audio-processing v2.0](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/releases/v2.0) — standalone AEC3 (WebRTC M131), BSD, meson
- [Switchboard: How WebRTC AEC3 works](https://switchboard.audio/hub/how-webrtc-aec3-works/) — PBFDAF architecture summary
- [DTLN-aec](https://github.com/breizhn/DTLN-aec) — MIT pretrained neural AEC, AEC Challenge entrant
- Microsoft, [ICASSP 2023 AEC Challenge](https://arxiv.org/abs/2309.12553) — judged on MOS and word accuracy; ByteAudio-18 hybrid winner
- [AECAudioStream](https://github.com/kasimok/AECAudioStream) — VPIO-based AEC library, corroborates system-wide reference
- [Speex manual, echo canceller](https://www.speex.org/docs/manual/speex-manual/node7.html) — AUMDF implementation
