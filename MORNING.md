# Good morning — ms-notes is built and installed

The app is in `/Applications/ms-notes.app`, signed, running, and its vault path
is already pointed at your Meetings folder. Everything below is either a result
or something that genuinely needs you.

---

## Do these two things first (5 minutes)

**1. Grant the two audio permissions.** They can only be granted by a real
person clicking a dialog. The app is running now; open the menu-bar icon
(a waveform circle, right side of the menu bar) → **Start Recording…** → give
it a title → Start. macOS will ask twice:

- **Microphone** — allow.
- **System Audio Recording** — allow. This is *not* Screen Recording; there is
  no purple indicator and no monthly re-approval ([ADR-0001](docs/adr/0001-process-tap-two-track-capture.md)).

Talk for ten seconds, hit Stop, and a note should land in your vault within a
couple of minutes.

**2. Re-enter your API keys in Settings.** Menu → Settings… → paste both keys →
Save. They are already in your Keychain, but they were written by the *build*
binary; the installed app is a different code identity, so macOS will otherwise
prompt for consent on first read. Re-saving from the installed app fixes it
permanently. (`api-keys.conf` is gitignored and never committed.)

**Optional:** add your jargon to **Key Terms** (one per line) — "Pangaea",
"QuickSlope", "Geomoss", site names, colleague names. This is the single
highest-leverage accuracy lever in the whole pipeline.

---

## What was built

Six phases, all complete, committed at each step (`git log --oneline`).

| | |
|---|---|
| **Capture** | Core Audio process tap + mic in one aggregate device, drift compensation on. Two mono CAF tracks, 16 kHz. Pause/resume on a shared clock. |
| **Pipeline** | FLAC transcode → AssemblyAI (split submission) → merge → Claude Opus 5 → Note + Transcript into the vault → Recording deleted. |
| **Shell** | AppKit menu-bar app, five states, Start popover, Settings, notifications, launch at login. |
| **Tests** | 17 unit tests + 6 live end-to-end verifications. |

**Your test recording ran the whole pipeline for real.** It produced a note with
Summary / Key points / Decisions / Open questions covering the site-report
discussion — branding, letterhead, photo manager, screenshot section, internal
sign-off. Cost: **$0.066** for 4 minutes. At 2–5 hrs/week that lands around
**$10–14/month**, matching the estimate in IDEA.md.

---

## Verification results

| Check | Result |
|---|---|
| R1 capture, no Screen Recording | **PASS** — two non-silent tracks; zero ScreenCaptureKit references |
| R2 crash resilience | **PASS** — `kill -9` mid-recording left both CAFs playable, 0.6 s lost |
| R3 pause excludes audio | **PASS (decisive)** — "alpha" before and "charlie" after transcribed; "bravo" spoken *during* the pause is absent |
| R4 footprint | **PASS** — 0.0 % CPU, 5.9 MB RAM while recording (limits 5 % / 100 MB) |
| R5 end-to-end delivery | **PASS** — note + transcript in vault, hands-off |
| R6 request parameters | **PASS** — `en_au`, keyterms, mic undiarized, remote range 1…n+1 |
| R7 success-gated deletion | **PASS** — *after fixing a real defect, see below* |
| R8 offline retry | **PASS** — unreachable provider → transient → re-queued, recording intact |
| R9/R10 filename + frontmatter | **PASS** — collisions number correctly; all frontmatter keys present |
| R11/R12 presets | **PASS** — four presets, naming rule embedded verbatim; held on real audio (no name evidence → generic labels) |
| R13 Keychain only | **PASS** — no key material outside the Keychain |
| R14 cost | **PASS** — total incremented by $0.0661 on a real job |
| R15 menu-bar only | **PASS** — `LSUIElement`, no dock icon, five states, login item registered |
| R16 silent remote warning | **PASS** — warns and still delivers the note |

**The defect R7 caught:** on success the pipeline deleted the Recording
directory — then immediately wrote `job.json` back into it, recreating the
directory it had just removed. Job state now lives *beside* the recording as
`<id>.json`. This is exactly the class of bug that safeguard exists to catch,
and it only surfaced because the test asserted on the directory rather than
trusting the happy path.

---

## Three things you should know

**1. A global audio tap has no clock when nothing is playing.** Undocumented,
and it stalls the *entire* aggregate device — zero callbacks on the mic too, so
a silent room recorded nothing at all. The engine now renders continuous silence
to the output device for the duration of a Session, which keeps the tap ticking
at no measurable cost. Recorded in [ADR-0001](docs/adr/0001-process-tap-two-track-capture.md).

**2. The app is AppKit, not SwiftUI.** The Command Line Tools ship no
`SwiftUIMacros` plugin, so `@State` cannot compile without Xcode. The spec
explicitly allowed AppKit; it is also lighter. If you install Xcode later and
want SwiftUI, nothing blocks it.

**3. AssemblyAI's `speech_model` parameter is dead.** It now rejects the
request and demands `speech_models: ["universal-3-5-pro"]` — drift caught on the
very first API call, which is precisely why the provider layer is pluggable.

---

## Not done, and why

- **The Done gate needs you.** It requires a real call ≥15 min with ≥2 remote
  speakers, using Pause once. Only you can run that.
- **Menu interaction is unverified.** I confirmed the app launches, stays alive,
  and shows its status item; clicking through the menus needs a human.
- **`log show` is unavailable** in the build environment, so R6's check targets
  the request-building functions directly instead of the log. The logs are still
  written — read them in Console.app, subsystem `no.msnotes.app`.
- **ElevenLabs adapter not built** — you chose AssemblyAI-only for v1. The
  `STTProvider` protocol is the seam if AssemblyAI disappoints on real calls.

---

## Handy commands

```bash
./scripts/test.sh                  # 17 unit tests
./scripts/build-app.sh             # rebuild dist/ms-notes.app
cp -R dist/ms-notes.app /Applications/    # reinstall
git log --oneline                  # the build, phase by phase
```

Recordings awaiting processing: `~/Library/Application Support/ms-notes/jobs/`.
Nothing is deleted there until a note is confirmed written.
