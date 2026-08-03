# Braid
status: active
updated: 2026-08-02

## Purpose

Braid records a call as two audio tracks on macOS, transcribes and separates the
voices on-device, summarises on-device, and writes a markdown note plus
transcript into the owner's Obsidian vault. It exists so a low-spec machine in a
headphones-wearing office can get accurate, speaker-attributed meeting notes with
near-zero involvement: click record, get a note. Nothing it hears leaves the Mac.

## Current direction

The app works and is in daily use (see ADOPTION.md). Attribution quality shipped
(v0.3.0–v0.4.0); local transcription and diarization shipped behind a Provider
seam alongside the cloud.

The theme is now **a private app that learns the voices you meet**. Two decisions
made it one piece of work rather than two. Braid is going private and
single-owner, which makes storing voiceprints a reasonable thing to do
([ADR-0007](docs/adr/0007-the-voice-database.md)) — and that is only honest if
nothing derived from a voice can leave, so the cloud goes entirely
([ADR-0006](docs/adr/0006-zero-cloud.md)). Success looks like: the people you
meet every week stop arriving as "Speaker 1", the app costs nothing to run, and
no note or recording or voiceprint has ever been anywhere but this machine.

The measured cost of that trade is worse speaker attribution today than
AssemblyAI gave (61–71% turn purity against it), taken deliberately on the bet
that the Voice Database plus Re-attribution close the gap as the app learns
recurring speakers. That bet is what the current cycle has to prove.

## Enduring constraints

- **No calendar, EventKit, Graph or Teams integration. Ever.** Identity comes
  from voices and the owner's own naming, never an external roster.
- **No cloud services.** No STT API, no LLM API, no telemetry, no sync. The only
  network use is fetching Engine model assets (ADR-0006).
- Third-party dependencies are a deliberate, recorded decision, never routine
  (ADR-0004 as amended by ADR-0005 and ADR-0006). Two are accepted, both pinned
  exactly: FluidAudio for local ASR and diarization, and mlx-swift-examples for
  open-weights summarisation. Both sit behind a seam; neither is reachable from
  BraidCore's tests.
- Never link ScreenCaptureKit; audio-only permissions (ADR-0001).
- Recordings are deleted once the note is confirmed written. Consequence: no
  post-hoc repair that needs audio; a Held Session keeps its Recording until it
  delivers.
- One window; the panel contains every view. Notifications are the only UI while
  it is closed.
- Names are never guessed among voices: a name beyond a generic label requires
  transcript evidence, explicit user action, a confident Voiceprint match, or the
  single unambiguous case — exactly one declared Participant and exactly one
  heard voice.
- Voice data is the user's to delete, always, and deleting it never touches a
  note already written.

## Operating posture

Personal, private, single-owner: the signed bundle in /Applications on the
owner's M3 MacBook Air, macOS 27, launched at login. Source is private; there is
no distribution artifact and no support. No accounts, no API keys, nothing
metered — the app has no running cost. The only secret it holds is the Voice
Database key, in the Keychain, this-device-only. No CI; scripts/test.sh is the
gate.

## Lasting decisions

- SPEC.md remains the standing contract; cycles amend it explicitly rather than
  drifting from it. CONTEXT.md's terms are binding language.
- Diarization is split-file: Remote Track diarized, Mic Track labelled "Me"
  structurally (ADR-0001). The Mic Track is never split into several speakers.
- Speaker-count caps burned us once (a late joiner folded into another speaker).
  Any speaker constraint must be explicit, per-Session, user-asserted — never
  derived from Participants.
- Echo research (2026-08-01): VPIO rejected for cancellation; offline two-track
  approach chosen. Rationale in docs/echo-cancellation.md.
- Local models (2026-08-02, research in docs/local-models.md): inference runs
  post-Stop, never while recording, so the 8GB constraint that once forbade local
  ML does not apply. Apple SpeechTranscriber is the default Engine on measured
  attribution; Parakeet stays selectable for its lower word error rate.
- **Batch after the meeting, never chunked during it** (2026-08-02). Measured:
  memory is flat from 4 to 62 minutes (~330MB resident) because ASR streams and
  diarization windows, and an hour processes in ~3.4 minutes. Chunking would add
  model residency and ANE contention exactly when Teams has the machine pinned,
  and would wreck attribution — clustering needs the whole session to know the
  voice at minute 5 and minute 50 are one person.
- **Identification is precision-first.** A voice is auto-named only when exactly
  one Person clears the auto threshold; two plausible people is a suggestion, not
  a guess. One wrong auto-name is a defect, not a tuning matter.
- **Naming is teaching.** There is no enrollment ceremony: the only write path
  into the Voice Database is the user confirming who a voice was.
- **Two summarisers, because they fail differently** (2026-08-02, ADR-0006).
  Apple's on-device model refuses whole subjects — a recorded discussion of a
  news story about named people was declined outright, and permissive
  guardrails, the content-tagging use case and neutral instructions all made no
  difference, because it is `refusal` (the model's training) rather than
  `guardrailViolation` (a filter). So an open-weights model runs beside it
  through MLX. Consequence: ADR-0004 reversed, Xcode required, `xcodebuild` for
  the app build — but `swift test` still runs the unit tests in ~3 seconds
  because the test target never touches MLX.

## Current cycle

[Private voices, zero cloud](./cycles/2026-08-02-voice-database-zero-cloud.md).
Shipped: [Speaker attribution](./cycles/2026-08-01-speaker-attribution.md) (v0.3.0),
[Minimal panel, zero-touch naming](./cycles/2026-08-01-minimal-panel-zero-touch-naming.md) (v0.4.0),
[Echo bleed: detect and dedup](./cycles/2026-08-01-echo-bleed-detection-dedup.md),
[Local transcription and diarization](./cycles/2026-08-02-local-transcription-diarization.md).

## Full lifecycle

Not promoted. Prior-methodology artifacts: SPEC.md (standing contract),
CONTEXT.md (language), IDEA.md (origin research), ADOPTION.md (baseline,
2026-08-01), docs/adr/ (durable decisions).
