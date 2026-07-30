# ms-notes

A macOS menu-bar app that records your meetings, has the cloud transcribe and
diarize them, summarises with Claude, and writes markdown notes straight into an
Obsidian vault. No bot joins your call, no subscription, no separate app to
check afterwards.

Built for a single user on a RAM-constrained MacBook Air, so the whole design
leans on being near-invisible while a call is running: measured **0.0% CPU and
about 6 MB of RAM** during recording.

## How it works

1. Click the menu-bar icon, pick a preset, hit Start.
2. The app records two separate tracks: your microphone, and the system audio
   (everyone else). Pause and resume whenever you like.
3. On Stop, a background job uploads both tracks to AssemblyAI, merges the
   results into one speaker-labelled transcript, and sends that to Claude for
   summarising.
4. A note and its full transcript land in your vault. The audio is deleted only
   after both files are confirmed on disk.

Roughly **$0.10 to $0.14 per hour** of meeting, all in.

## Design decisions worth knowing

**System audio without the Screen Recording permission.** Most apps in this
space use ScreenCaptureKit, which means granting Screen Recording, a purple
menu-bar indicator, and a re-approval nag every month. This uses Core Audio
process taps instead, which need only the audio-only "System Audio Recording"
permission. See [ADR-0001](docs/adr/0001-process-tap-two-track-capture.md).

**Two tracks, not one mix.** Recording your mic separately from the remote audio
doubles the transcription bill, and buys perfect "me vs them" separation for
free. Diarization then only has to separate the people on the far end.

**No local machine learning.** Transcription and diarization both happen in the
cloud. On an 8 GB machine already running Teams, that is the difference between
usable and not. See [ADR-0002](docs/adr/0002-cloud-diarization-over-local.md).

**No voiceprints, ever.** Speaker clustering happens within a single call and is
then discarded. Nothing that identifies a voice is stored or reused across
meetings. This is a permanent line, not a v1 shortcut.
See [ADR-0003](docs/adr/0003-no-voiceprints-ever.md).

**Swappable providers.** AssemblyAI is the only adapter shipped, behind an
`STTProvider` protocol. That seam exists because this space churns: the
`speech_model` parameter was rejected as deprecated on the very first API call
of the build.

## Requirements

- macOS 27 or later, Apple silicon
- Swift 6.4 command line tools (Xcode is not required)
- An AssemblyAI API key and an Anthropic API key
- Somewhere to put the notes, Obsidian vault or any folder

## Build and install

```bash
./scripts/build-app.sh              # produces dist/ms-notes.app
cp -R dist/ms-notes.app /Applications/
./scripts/test.sh                   # unit tests
```

The build script signs the app with a local code-signing identity called
`ms-notes Development`. You will need to create one, or edit the script to use
your own. A stable identity matters: without it macOS treats every rebuild as a
new app and forgets your audio permissions.

On first recording, macOS asks for Microphone and System Audio Recording. API
keys go in Settings and are stored only in the Keychain.

## Repository layout

| Path | What it is |
|---|---|
| `SPEC.md` | The binding specification, requirements and acceptance checks |
| `CONTEXT.md` | The project's vocabulary, terms used consistently in code and docs |
| `IDEA.md` | The research behind the idea, including alternatives rejected and why |
| `docs/adr/` | Architecture decision records |
| `MORNING.md` | Build log and verification results from the overnight build |
| `Sources/MsNotesCore/` | Capture engine, provider adapters, job pipeline |
| `Sources/MsNotesApp/` | Menu-bar shell and headless verification modes |

The documents came first and drove the build. `SPEC.md` is the contract,
`IDEA.md` records the reasoning that led to it.

## Status

Working and in daily use. Sixteen requirements, fourteen verified end to end,
the remaining two need a human clicking things. Personal project, no support
offered, but the ADRs should make it easy to fork in a different direction.

## Licence

MIT.
