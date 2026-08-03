<img src="docs/icon.png" alt="" width="88">

# Braid

Record a meeting. Get notes in your Obsidian vault. Nothing leaves the Mac.

| idle | recording |
|---|---|
| <img src="docs/screenshots/panel.png" width="340"> | <img src="docs/screenshots/panel-recording.png" width="340"> |

It lives in the menu bar. Click record when the call starts; it stops itself when
the call ends. A few minutes later a markdown note appears in your vault with the
summary, decisions and action items, alongside the full transcript.

No bot joins your call. No account, no API key, no subscription, no running cost.

## Where your audio goes

Nowhere.

Transcription, speaker separation and the summary all run on this Mac. The app
makes no network requests except to fetch the speech models themselves. Audio is
deleted once the note is written. The voices it remembers are encrypted with a
key that never leaves this machine's Keychain.

Recording other people may need their consent where you live. Braid announces
itself to nobody.

## It learns the voices you meet

The first time you name a voice, Braid remembers it. The next call with the same
person, they are named before you see the note.

Naming is the only way it learns — there is no enrollment step and no setup. When
it does not recognise someone you get a row with a play button, a few seconds of
that person talking, and a name field. One tap on a suggestion, or a few
keystrokes.

It will not guess. If two people it knows both sound like the voice, it offers
both and asks. A wrong name in a filed note is worse than "Speaker 1", so the bar
to write one without asking is deliberately high.

**Wait for names, or don't.** By default the note is written straight away with
generic labels and rewritten when you name the voices. Turn on *Wait for speaker
names* and nothing is written until you have.

Everything it knows is in Settings: every person, how many samples it has, and a
way to forget any of them or all of them. Forgetting never touches notes you
already have.

## Who it is for

An 8 GB MacBook Air that is already working hard during a Teams call. The trick
is timing: nothing is transcribed while you are recording. Capture is about 6 MB
and no measurable CPU; all the model work happens after you hit stop, when Teams
has let go of the machine.

An hour-long meeting takes about three and a half minutes to process, and peaks
around 330 MB — the same as a four-minute one, because the models stream.

## How it works

```
menu bar  ──▶  two audio tracks  ──▶  Apple Speech  ──▶  pyannote  ──▶  Apple's
              mic + system audio     transcript        who spoke     on-device model
                                                        when              │
                                                                          ▼
                                                            your vault: note + transcript
```

Mic and meeting audio are recorded as **separate tracks**. Because your voice is
on its own track you are always labelled correctly, and speaker separation only
has to sort out the far end.

Braid assumes headphones: on speakers it warns you while recording, cleans the
far end's echo out of your track afterwards, and folds anything of yours that
bounced back into "Me" rather than inventing a phantom participant.

**Transcription** is Apple's on-device speech by default — nothing to download,
and it takes your key terms. Parakeet is selectable if you would rather have its
slightly lower word error rate and don't mind a 443 MB model.

**The summary** is written by one of two on-device models, your choice in
Settings. Apple's built-in one is the default: nothing to download, no memory
cost. It has one real flaw — it refuses some subjects outright, politics and
anything touching crime or allegations about named people, and no setting
changes that. When it does, Braid summarises the parts it will accept and says
in the note what is missing.

The alternative is an open model (Qwen3 4B by default) running on this Mac
through MLX. No such refusals, and it reads a whole meeting in one pass rather
than in chunks, so long sessions summarise better. Costs a 2.3GB download and
about that much memory while it writes.

Search is Obsidian's job. Braid writes markdown and stops.

## Using it

Left click the icon for the panel. It is the whole app: recording, naming,
settings and confirmations all happen in it, never in a second window. Right
click for a short menu.

| name voices | settings | processing |
|---|---|---|
| <img src="docs/screenshots/panel-naming.png" width="240"> | <img src="docs/screenshots/panel-settings.png" width="240"> | <img src="docs/screenshots/panel-processing.png" width="240"> |

- **One click to start.** The panel asks who is on the call and nothing else.
- **Notes name themselves.** The summariser reads the conversation and titles the
  file from it, so you never type a title before a meeting you haven't had.
- **Auto-stop** when your call app releases the mic, after a thirty second
  countdown you can cancel. Starting is always manual.
- **Participants** are chips for voices Braid already knows, plus a field for
  anyone new. They are hints, never limits, so someone joining late still gets
  their own voice.
- **Presets** — Meeting, Lecture, Interview, Training. Editable prompt templates.
  Pick one in Settings and it shapes every note.
- **Key terms** — proper nouns the transcriber would not guess. Keep the list
  tight; padding it hurts accuracy.
- **Pause** for the private parts. The note marks the gap.
- **Cancel** while processing and it stops. The audio is kept.

## Build it

You need an Apple Silicon Mac on macOS 26 or later with Apple Intelligence
switched on, and Xcode. Xcode is needed because MLX compiles Metal shaders and
SwiftPM on the command line cannot; if you only ever want Apple's summariser,
Command Line Tools alone still runs the tests.

```bash
git clone <this repo>
cd braid

./scripts/build-app.sh        # builds dist/Braid.app
cp -R dist/Braid.app /Applications/
```

Set your vault folder in Settings. The first recording asks for Microphone and
System Audio Recording. That is the entire setup.

The signing identity is `ms-notes Development`, named before the app was and kept
because renaming it makes macOS forget permissions already granted. Create one in
Keychain Access, or edit `scripts/build-app.sh`.

## Design decisions

- **System audio without the Screen Recording permission.** Core Audio process
  taps rather than ScreenCaptureKit: audio-only permission, no purple indicator,
  no monthly re-approval.
  [ADR-0001](docs/adr/0001-process-tap-two-track-capture.md)
- **No cloud at all.** Both services removed, and why that costs accuracy today.
  [ADR-0006](docs/adr/0006-zero-cloud.md)
- **Voiceprints, deliberately.** What changed, and the three rules that keep it
  honest. [ADR-0007](docs/adr/0007-the-voice-database.md)
- **Knowing the call ended without watching it.** Auto-stop reads Core Audio's
  per-process state and asks whether Teams is holding the mic. No Accessibility
  permission, nothing that breaks when Teams is redesigned.

## Layout

```
Sources/BraidCore/       capture engine, call watcher, pipeline
Sources/BraidCore/Local/ engines, diarizer, aligner
Sources/BraidCore/Voice/ the voice database, identification, clips
Sources/BraidMLX/        the open-weights summariser (needs Xcode's Metal)
Sources/BraidApp/        menu bar app and headless test modes
Sources/BraidApp/UI/     the panel: every view the app has
Tests/                   unit tests
scripts/                 build, install and icon helpers
docs/adr/                why the difficult decisions went the way they did
```

```bash
./scripts/test.sh                              # unit tests (plain SwiftPM, ~3s)
./.build/debug/BraidApp --summary-check <file> [--mlx] [--probe]
./.build/debug/BraidApp --voices               # who Braid can recognise
./.build/debug/BraidApp --local-check <audio> [--reference <json>]
./.build/debug/BraidApp --ui-preview           # every panel view, on screen
```

## Status

Working, in daily use, private. A personal tool, no support offered.
