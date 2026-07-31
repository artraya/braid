<img src="docs/icon.png" alt="" width="88">

# Braid

Record a meeting. Get notes in your Obsidian vault. That is the whole app.

| idle | recording |
|---|---|
| <img src="docs/screenshots/panel.png" width="340"> | <img src="docs/screenshots/panel-recording.png" width="340"> |

It lives in the menu bar. Click record when the call starts; it stops itself when
the call ends. A few minutes later a markdown note appears in your vault with the
summary, decisions and action items, alongside the full transcript.

No bot joins your call. No subscription.

## Who it is for

An 8 GB MacBook Air that is already working hard during a Teams call. Teams is
heavy Electron, rough on Apple Silicon, and using macOS screen sharing instead of
its own costs you Teams features like Take Control. A local transcription model
on top of that is the thing that would not fit.

And for low frequency use: a few meetings a week worth capturing properly, rather
than an archive of everything that nobody reads.

**Not for you if** your machine has headroom for on-device transcription. Local
models are good now and free per hour. Run one.

## How it works

```
menu bar  ──▶  two audio tracks  ──▶  AssemblyAI  ──▶  Claude  ──▶  your vault
              mic + system audio     transcript      summary      note + transcript
                                     + speakers
```

Mic and meeting audio are recorded as **separate tracks**. Because your voice is
on its own track you are always labelled correctly, and speaker separation only
has to sort out the far end.

**AssemblyAI** returns speaker labels already attached to the words, in one call.
Doing it locally means aligning an unlabelled transcript against separate speaker
segments, which goes wrong in ways that are hard to spot. Diarization adds about
two cents an hour. It sits behind a small protocol, so another provider is a new
adapter, not a rewrite. [ADR-0002](docs/adr/0002-cloud-diarization-over-local.md)

The summary is a plain HTTP call to Claude with no SDK, so pointing it at a
different model is a small change in one file.

Search is Obsidian's job. Braid writes markdown and stops.

## Where your audio goes

Not a privacy tool. Recordings go to **AssemblyAI**, transcripts to **Anthropic**,
both third parties under their own terms.

Locally: audio is deleted once the note is written, and no voiceprints are kept
between meetings. Behaviours, not claims.

Recording other people may need their consent where you live. Braid announces
itself to nobody.

## Costs

| | |
|---|---|
| Transcription with speaker separation | about $0.54 / hour |
| Claude summary | about $0.10 / hour |

Two tracks bill separately, which is what guaranteed labelling of your own voice
costs. At a few meetings a week that is a couple of dollars a month. The running
total and a monthly budget you set are in the app.

## Using it

Left click the icon for the panel. It is the whole app: recording, naming,
settings and confirmations all happen in it, never in a second window. Right
click for a short menu.

| name speakers | settings | cancel before it costs |
|---|---|---|
| <img src="docs/screenshots/panel-naming.png" width="240"> | <img src="docs/screenshots/panel-settings.png" width="240"> | <img src="docs/screenshots/panel-processing.png" width="240"> |

- **Auto-stop** when your call app releases the mic, after a thirty second
  countdown you can cancel. Starting is always manual.
- **Presets** — Meeting, Lecture, Interview, Training. Editable prompt templates.
- **Participant names** are hints, never limits, so someone joining late gets
  their own speaker. Afterwards Braid offers to name the voices it found, each
  with talk time and a line they said. Nothing is guessed for you.
- **Key terms** — proper nouns the transcriber would not guess. Keep the list
  tight; padding it hurts accuracy.
- **Pause** for the private parts. The note marks the gap.
- **Cancel** while processing and it stops before paying for anything it has not
  used. The audio is kept.

## Build it

No download. Braid is signed with a local certificate no other Mac trusts, and an
unnotarised build is one macOS refuses to open.

You need an Apple Silicon Mac on macOS 27, the Swift command line tools (not
Xcode), an [AssemblyAI](https://www.assemblyai.com) key and an
[Anthropic](https://console.anthropic.com) key.

```bash
git clone https://github.com/artraya/braid.git
cd braid

cp .env.example .env          # add your two API keys
./scripts/build-app.sh        # builds dist/Braid.app
cp -R dist/Braid.app /Applications/
./scripts/load-keys.sh        # moves the keys into the Keychain
```

Set your vault folder in Settings. The first recording asks for Microphone and
System Audio Recording.

The signing identity is `ms-notes Development`, named before the app was and kept
because renaming it makes macOS forget permissions already granted. Create one in
Keychain Access, or edit `scripts/build-app.sh`.

## Design decisions

- **System audio without the Screen Recording permission.** Core Audio process
  taps rather than ScreenCaptureKit: audio-only permission, no purple indicator,
  no monthly re-approval.
  [ADR-0001](docs/adr/0001-process-tap-two-track-capture.md)
- **No local machine learning**, for the reason above.
  [ADR-0002](docs/adr/0002-cloud-diarization-over-local.md)
- **Knowing the call ended without watching it.** Auto-stop reads Core Audio's
  per-process state and asks whether Teams is holding the mic. No Accessibility
  permission, nothing that breaks when Teams is redesigned.
- **No voiceprints.** Voices are grouped within a call, then forgotten.
  [ADR-0003](docs/adr/0003-no-voiceprints-ever.md)

## Layout

```
Sources/BraidCore/    capture engine, call watcher, provider adapters, pipeline
Sources/BraidApp/     menu bar app and headless test modes
Sources/BraidApp/UI/  the panel: every view the app has
Tests/                unit tests
scripts/              build, install, icon and key helpers
docs/adr/             why the difficult decisions went the way they did
```

```bash
./scripts/test.sh                              # unit tests
./.build/debug/BraidApp --ui-preview           # every panel view, on screen
./.build/debug/BraidApp --ui-preview --snapshot docs/screenshots
./.build/debug/BraidApp --ui-preview --check-geometry
```

## Status

Working, in daily use, unlikely to grow much. A personal tool published in case
the approach is useful to someone else. No support offered.

MIT licensed.
