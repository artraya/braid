# ms-notes

Record a meeting. Get notes in your Obsidian vault. That is the whole app.

It lives in the macOS menu bar. You click record when a call starts and stop
when it ends. A few minutes later a markdown note appears in your vault with a
summary, the decisions and the action items, alongside the full transcript. The
audio is deleted once the note is safely written.

No bot joins your call. No subscription. Nothing to check afterwards.

![the app icon](docs/icon.png)

## Why this exists

Every tool in this space is a monthly subscription with its own silo to log into.
This one is about 2000 lines of Swift that you own, calling two APIs you pay for
directly. Roughly **10 to 14 dollars a month** at two to five hours of calls a
week, and you can read every line that touches your audio.

It was also built for a machine under pressure, an 8 GB MacBook Air already
running Teams. Measured while recording: **0.0% CPU and about 6 MB of RAM**.

## How it works

```
menu bar  ──▶  two audio tracks  ──▶  AssemblyAI  ──▶  Claude  ──▶  your vault
              mic + system audio     transcript      summary      note + transcript
                                     + speakers
```

Your microphone and the meeting audio are recorded as **separate tracks**. That
sounds like a detail and is actually the core design choice: because your voice
is on its own track, you are always labelled correctly, and the speaker
separation only has to work out who is who on the far end.

Everything else is deliberately boring. Recording is crash safe, so pulling the
power costs you a few seconds rather than the meeting. If the network is down
when you stop, the job waits and retries. Nothing is deleted until the note
exists on disk.

## Setup

You need macOS 27, the Swift command line tools (not Xcode), an
[AssemblyAI](https://www.assemblyai.com) key and an
[Anthropic](https://console.anthropic.com) key.

```bash
git clone https://github.com/artraya/ms-notes.git
cd ms-notes

cp .env.example .env          # add your two API keys
./scripts/build-app.sh        # builds dist/ms-notes.app
cp -R dist/ms-notes.app /Applications/
./scripts/load-keys.sh        # moves the keys into the Keychain
```

Open the app, click the menu bar icon, and set your vault folder in Settings.
On your first recording macOS asks for Microphone and System Audio Recording.

The build signs the app with a local identity called `ms-notes Development`.
Create one in Keychain Access, or edit `scripts/build-app.sh` to use your own.
A stable identity matters, because without it macOS treats every rebuild as a
brand new app and forgets your permissions.

## Using it

Pick a **preset** when you start recording: Meeting, Lecture, Interview or
Training. Each one is a prompt template that shapes the note, and all four are
editable in Settings.

You can type **participant names** at the start. They are only hints. A name is
used in the note when the transcript actually supports it, otherwise you get
Speaker 1 and Speaker 2.

**Key terms** are the highest value setting in the app. Add proper nouns the
transcriber would not guess, such as product names, sites and colleagues'
surnames, one per line. The transcript then uses your exact spelling. Keep the
list tight and specific, since padding it with common words makes accuracy worse
rather than better.

**Pause** during the private parts of a call. Nothing said while paused is
recorded, and the note marks the gap so the summary does not read two unrelated
halves as one conversation.

## Design decisions

**System audio without the Screen Recording permission.** Most apps here use
ScreenCaptureKit, which means granting Screen Recording, a purple indicator in
your menu bar, and a re-approval prompt every month. This uses Core Audio
process taps, which need only the audio-only permission.
[ADR-0001](docs/adr/0001-process-tap-two-track-capture.md)

**No local machine learning.** Transcription and speaker separation both happen
in the cloud. On a RAM-constrained laptop already running a video call, that is
the difference between usable and not.
[ADR-0002](docs/adr/0002-cloud-diarization-over-local.md)

**No voiceprints, ever.** Voices are grouped within a single call and then
forgotten. Nothing that could identify a voice is stored or reused across
meetings. This is a permanent line, not a shortcut taken to ship.
[ADR-0003](docs/adr/0003-no-voiceprints-ever.md)

**Swappable transcription providers.** AssemblyAI is the only adapter shipped,
sitting behind a small protocol. That seam exists because this corner of the
industry churns constantly. During the build, the first API call was rejected
for using a parameter that had been deprecated.

## Costs

Per hour of meeting, at current prices:

| | |
|---|---|
| Transcription with speaker separation | about $0.54 |
| Claude summary | about $0.10 |

Both audio tracks are billed separately, which is what the two track design
costs you. Providers bill per channel, so mixing them into one file before
upload would halve the transcription line and give up the guaranteed labelling
of your own voice. The running total is shown in the app.

## Project layout

```
Sources/MsNotesCore/   capture engine, provider adapters, job pipeline
Sources/MsNotesApp/    menu bar app and headless test modes
Tests/                 unit tests
scripts/               build, install, icon and key helpers
docs/adr/              why the difficult decisions went the way they did
```

```bash
./scripts/test.sh    # run the tests
```

## Status

Working, in daily use, and unlikely to grow much. A personal tool published in
case the approach is useful to someone else. No support offered, but the
decision records should make it easy to take in a different direction.

MIT licensed.
