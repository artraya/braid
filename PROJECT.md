# Braid
status: active
updated: 2026-08-01

## Purpose

Braid records a call as two audio tracks on macOS, has AssemblyAI transcribe and
diarize them, summarises with Claude, and writes a markdown note plus transcript
into the owner's Obsidian vault. It exists so a low-spec machine in a
headphones-wearing office can get accurate, speaker-attributed meeting notes with
near-zero involvement: click record, get a note.

## Current direction

The app works and is in daily use (see ADOPTION.md). The attribution-quality
theme is delivered: diarization controls, the naming flow, and speaker-bleed
detection with transcript dedup all shipped (v0.3.0–v0.4.0).

The theme is now **running on your own machine**. Braid transcribes and
diarizes locally by default, with the cloud as an automatic, disclosed
fallback, so a Session can cost nothing and leave no machine. This follows
directly from the public-use decision: the README's "run a local model
instead" carve-out turned away exactly the users public source invites.
Researched in docs/local-models.md. Success looks like: notes as trustworthy
as the cloud path produces, with no key, no cost, and no audio leaving the
Mac.

## Enduring constraints

- Third-party dependencies are a deliberate, recorded decision, never routine
  (ADR-0004 as amended by ADR-0005). Exactly one is accepted: FluidAudio,
  pinned exactly, for local ASR and diarization. Both Providers remain plain
  URLSession.
- Never link ScreenCaptureKit; audio-only permissions (ADR-0001).
- No voiceprints, ever (ADR-0003).
- Recordings are deleted once the note is confirmed written. Consequence: no
  post-hoc repair that needs audio; diarization settings must be right pre-call.
- One window; the panel contains every view. Notifications are the only UI while
  it is closed.
- Delivery is hands-off: a note lands without the user touching anything after
  Stop. Optional passes (naming) never block delivery.
- Names are never guessed among voices: attribution beyond generic labels
  requires transcript evidence, explicit user action, or the single unambiguous
  case — exactly one declared Participant and exactly one heard voice, which
  auto-assigns (owner decision 2026-08-01, amending R6a; SPEC R11).

## Operating posture

Personal production: the signed bundle in /Applications on the owner's M3
MacBook Air, macOS 27, launched at login. Public source on GitHub (MIT),
build-it-yourself; no distribution artifact. Two metered paid services
(AssemblyAI, Anthropic) behind Keychain-held keys, monthly cost cap warns and
never blocks. No CI; scripts/test.sh is the gate.

## Lasting decisions

- SPEC.md remains the standing contract (R1–R19); cycles amend it explicitly
  rather than drifting from it. CONTEXT.md's twelve terms are binding language.
- Diarization is split-file: Remote Track diarized, Mic Track labelled "Me"
  structurally (ADR-0001, ADR-0002).
- The Provider seam is STTProvider; provider quirks live in the Adapter only.
- Speaker-count caps burned us once (late joiner folded into another speaker,
  see AssemblyAIAdapter.requestBody comment). Any speaker constraint must be
  explicit, per-Session, user-asserted — never derived from Participants.
- Echo research (2026-08-01): VPIO rejected for cancellation; offline two-track
  approach chosen. Rationale and sources in docs/echo-cancellation.md.
- Local models (owner decisions 2026-08-02, research in docs/local-models.md):
  ADR-0002's "no local ML" is superseded — inference runs post-Stop, never
  while recording, so the 8GB constraint that justified it does not apply.
  FluidAudio is accepted pinned, despite its vendored binary framework and
  pre-1.0 version, because it carries both Parakeet and the community-standard
  pyannote diarizer. Auto prefers local from the start; Parakeet is the default
  engine, with Apple SpeechTranscriber selectable. Consequence: Key Terms no
  longer bias transcription under Parakeet (no keyword-biasing API), which is a
  known regression to the app's highest-leverage accuracy lever.
- Provenance is disclosed, never silent: the Note's `provider` frontmatter and
  the delivery notification name whichever Provider actually ran, and Local
  mode never reaches the network under any failure.

## Current cycle

[Local transcription and diarization](./cycles/2026-08-02-local-transcription-diarization.md).
Shipped: [Speaker attribution](./cycles/2026-08-01-speaker-attribution.md) (v0.3.0),
[Minimal panel, zero-touch naming](./cycles/2026-08-01-minimal-panel-zero-touch-naming.md) (v0.4.0),
[Echo bleed: detect and dedup](./cycles/2026-08-01-echo-bleed-detection-dedup.md).

## Full lifecycle

Not promoted. Prior-methodology artifacts: SPEC.md (standing contract),
CONTEXT.md (language), IDEA.md (origin research), ADOPTION.md (baseline,
2026-08-01), docs/adr/ (durable decisions).
