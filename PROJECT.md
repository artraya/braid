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

The app works and is in daily use (see ADOPTION.md). The current theme is
**attribution quality**: the note must put the right words in the right person's
mouth. That covers speaker diarization controls and the naming flow (current
cycle), then speaker bleed when the user records without headphones — detection
and transcript-level dedup first, offline echo cancellation DSP only if
measurements demand it (researched in docs/echo-cancellation.md). Success looks
like: notes whose attributions can be trusted without opening the transcript,
whatever audio setup was used.

## Enduring constraints

- Zero third-party dependencies; plain URLSession for both providers (ADR-0004).
- Never link ScreenCaptureKit; audio-only permissions (ADR-0001).
- No voiceprints, ever (ADR-0003).
- Recordings are deleted once the note is confirmed written. Consequence: no
  post-hoc repair that needs audio; diarization settings must be right pre-call.
- One window; the panel contains every view. Notifications are the only UI while
  it is closed.
- Delivery is hands-off: a note lands without the user touching anything after
  Stop. Optional passes (naming) never block delivery.
- Names are never guessed: attribution beyond generic labels requires transcript
  evidence or explicit user action (SPEC R6a, R11).

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

## Current cycle

[Speaker attribution](./cycles/2026-08-01-speaker-attribution.md)

## Full lifecycle

Not promoted. Prior-methodology artifacts: SPEC.md (standing contract),
CONTEXT.md (language), IDEA.md (origin research), ADOPTION.md (baseline,
2026-08-01), docs/adr/ (durable decisions).
