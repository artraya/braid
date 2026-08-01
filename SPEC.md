# Braid
status: approved
owner: Alexandro
one-liner: A native macOS menu-bar app that records calls as two Tracks, has a cloud Provider transcribe and diarize them, summarises with Claude, and writes markdown Notes into an Obsidian Vault.

## Outcome
Problem: meeting knowledge evaporates after calls; manual note-taking during them is lossy and distracting.
User: the owner, on an 8GB M3 MacBook Air already strained by Teams.
Success measure (both must hold, both can fail; both are owner-verified, not agent-runnable):
1. A Note appears in the Vault within 15 minutes of Stop with zero manual steps, for ≥9 of the first 10 real calls.
2. After 2 weeks of use, the owner has stopped taking manual notes during calls.

## The Journey
1. One-time setup: choose the Vault folder, enter API keys (AssemblyAI + Anthropic), maintain the Key Terms list, review the four Presets.
2. Call starts → click the menu-bar icon → Start. The popover offers: Preset (default Meeting), optional Title (defaults to the Preset name), optional Participants. Recording begins: two Tracks, crash-safe on disk, continuously flushed.
3. During the call: the icon shows recording state; Pause/Resume any time; a pause stops both Tracks on the shared clock and is marked in the Transcript, never silently joined.
4. Call ends → Stop. A Job is created.
5. The Job submits the Recording to the Provider as two requests: the Remote Track with diarization on and no speaker constraint unless the user asserted a count at Start; the Mic Track without diarization (its single speaker is structural — the Adapter labels all of it "Me"). Both requests set English (`en_au`) explicitly and attach Key Terms plus the Session's Participants. No connectivity → the Job queues and retries.
6. The Adapter merges both results into one Transcript on the shared Recording clock (merge rule in Architecture).
7. The Summariser (Claude, `claude-opus-5`) produces the Note from the Transcript using the Preset; Participant names are used only where the Transcript makes them evident, and only for Remote speakers — the Mic speaker is always "Me". The one exception: a Session with exactly one Participant and exactly one heard voice has that voice relabelled to the Participant before summarising (amended R6a). The Note is written to the Vault, the Transcript to `<Vault>/transcripts/`; the Recording is deleted only after both the Note and the Transcript are confirmed on disk.
8. macOS notification: "Note ready." On any failure: the Recording is kept, the icon shows the error state. Transient failures (network unreachable, request timeout, provider HTTP 5xx or 429) retry automatically with backoff; all other failures (auth, invalid request, Vault write, malformed response) wait for user-initiated Retry from the menu.

## Non-goals
1. No live transcription or scrollback UI (v2 at the earliest).
2. No auto-detection of call start; Start/Stop is manual.
3. No calendar, EventKit, Graph, or Teams API integration.
4. No local ML — no on-device transcription or diarization ([ADR-0002](docs/adr/0002-cloud-diarization-over-local.md)).
5. No voiceprints or cross-Session voice memory, ever ([ADR-0003](docs/adr/0003-no-voiceprints-ever.md)).
6. No distribution: personal build, one Mac, no notarization, no App Store, no Windows.
7. No in-app transcript or note viewer/editor; Notes are read and fixed in Obsidian.
8. No RAG or chat over Notes.

## Language
The project's language lives in [CONTEXT.md](./CONTEXT.md); its terms are binding. To read this spec you need: **Session** (one Start→Stop span; produces one Recording, one Transcript, one Note), **Track** (Mic Track = "Me", Remote Track = everyone else), **Provider/Adapter** (cloud STT service / its translation layer), **Job** (the post-Stop pipeline: upload → transcribe → summarise → write → delete), **Preset** (a stored summary prompt template).

## Requirements
R1. Mic and system audio are captured as two separate Tracks via Core Audio process taps; the app never holds the Screen Recording permission. | Check: no ScreenCaptureKit reference in the codebase; a test Session produces two CAF files, each containing non-silent audio.
R2. A Recording survives a crash: `kill -9` mid-Session leaves both Track files playable, missing ≤5 seconds. | Check: kill the app during a test recording; both files play and their duration is within 5s of the kill time.
R3. Pause excludes audio and marks the gap: words spoken while paused never appear in the Transcript; the Transcript contains a marker line `[recording paused — <duration>]` at the pause point. | Check: speak a known phrase during Pause; assert it is absent and the marker line present with a plausible duration.
R4. In-call footprint is ≤5% CPU (as reported by `top` %CPU, where 100% = one core) and ≤100MB RAM while recording. | Check: sample with `top` during a 10-minute recording while a video call or video playback runs with the mic live.
R5. With connectivity, a Note and its Transcript appear in the Vault within 15 minutes of Stop with zero user action. | Check: scripted end-to-end run against a sample Recording.
R6 (amended 2026-08-01, cycles/2026-08-01-speaker-attribution.md). The Adapter submits the Remote Track with diarization enabled and, **by default, no speaker count of any kind**; the Mic Track without diarization and never with speaker fields; both with `language_code: en_au` and the Key Terms list with the Session's Participants appended (deduplicated case-insensitively). A speaker count is sent only when the user asserted one at Start: `count` always as `speaker_options.min_speakers_expected` (fixes under-splitting, cannot fold a late joiner), `max_speakers_expected` added only when the user also chose strict. A constraint is **never derived from Participants** — they are Key Terms, Summariser hints and naming suggestions only. When diarization's heard count disagrees with the asserted count (or, softly, the Participant count), the app warns after delivery and never blocks it. | Check: assert against `AssemblyAIAdapter.requestBody(...)` — the same function the live path calls — that the default carries no `speaker_options` or `speakers_expected`, that an asserted count sends the minimum and only strict adds the maximum, that the undiarized request never carries speaker fields, and that Participants appear in `keyterms_prompt`, never as a count. (The pipeline log carries these too, for reading in Console.app; `log show` is unavailable to the build environment, so it cannot be the automated check.)

R6a (amended 2026-08-01, cycles/2026-08-01-minimal-panel-zero-touch-naming.md). Remote speakers can be named after delivery. A Session whose Transcript contains Remote speakers keeps a NamingRecord; naming relabels the Transcript, re-runs the Summariser, and rewrites the Note and Transcript in place. One case is named *before* delivery: exactly one declared Participant and exactly one heard voice is unambiguous, so the pipeline relabels that voice pre-summary and the Note arrives named at no extra cost, with its record stored as already-named. Names are never assigned by guessing *among* voices. The Note is never rewritten if it has changed on disk since delivery — a new pair is written instead. | Check: `renamingAppliesNamesButNeverTouchesMe`, `transcriptStoreRoundTripsAndPurges`, `overwriteKeepsBothFilenamesAndRelinksTranscript`, `autoAssignNamesTheSingleVoiceBeforeSummarising`, `autoAssignNeverGuessesAmongVoices`.
R7. A Recording is deleted only after both its Note and its Transcript are confirmed on disk; any Job failure retains the Recording and surfaces the error state; non-transient failures (Journey step 8 taxonomy) are retried only on user-initiated Retry. | Check: make the Vault unwritable → Recording survives, error state shows, no automatic retry occurs; restore and Retry → Job succeeds and the Recording is deleted.
R8. A Job that fails transiently (Journey step 8 taxonomy) queues and retries automatically with backoff, then completes without interaction. | Check: point the Adapter at an unreachable endpoint, Stop a Session, restore the real endpoint; the Note appears without interaction.
R9. Note filename is `YYYY-MM-DD HHmm Title.md` — date and time are the Session's Start in local time; Title comes from the popover (default: the Preset name) with the characters `/ \ : # ^ [ ] |` replaced by `-`; on collision, append the lowest free integer suffix (" 2", " 3", …). | Check: force two collisions; three files exist with correct names.
R10. Note frontmatter carries date, start time, duration (recorded audio only, pauses excluded), preset, participants, provider, cost in USD, and a wikilink to its Transcript. | Check: parse a generated Note's frontmatter.
R11. The Summariser calls `claude-opus-5` with the chosen Preset; every Preset template embeds this canonical rule verbatim: "Only attribute a name to a speaker when the transcript itself provides evidence for it; otherwise keep the generic speaker label. Never relabel Me." | Check: assert all four shipped templates contain that exact sentence; behavioural conformance is reviewed at Done.
R12. Four editable Presets ship: Meeting, Lecture, Interview, Training, seeded from repo-defined defaults. | Check: settings lists all four; an edit persists across relaunch.
R13. API keys are stored only in the macOS Keychain. | Check: grep the app's files, defaults, and logs for key material; none found outside the Keychain.
R14. A running cost total is visible in the app and increments per completed Job by the amount computed from the rate table (Architecture). | Check: complete a Job; the total rises by hours × STT rate per submitted Track plus Claude token usage × token rates.
R15. The app is menu-bar only (no dock icon), launches at login, and shows distinct idle / recording / paused / processing / error states. | Check: `LSUIElement` is set; the login item is registered; each state can be driven and observed.
R16. A completed Session whose Remote Track peaks below −50 dBFS throughout triggers a "no system audio captured — check permission" warning (notification plus error badge until acknowledged); the Job still completes and produces the Note from what was captured. | Check: run a Job on a fixture Session whose Remote Track is all-zero samples; the warning appears and a Note is still written.

R17. Starting is always manual; stopping may be automatic. When a watched call app releases the microphone, the Session stops by itself after a 30-second countdown the user can cancel. The watcher arms only after a call app has held the mic during that Session, and requires the mic released continuously for 15 seconds. Cancelling disarms it until a new call begins. | Check: `CallWatcher` tests — never fires unarmed, fires once after the grace period, rides out a reconnect, and stays disarmed after Keep recording.

R18 (amended 2026-08-01, cycles/2026-08-01-minimal-panel-zero-touch-naming.md). Delivered Sessions are logged so the app can show its own history. History and the month's usage live one click deep within the one window — history as its own panel view listing recent Sessions, each opening its Note; the usage card (minutes against the user-set cap, spend) in Settings — so the first click shows only what needs attention. Reaching the cap warns by notification regardless of panel layout and never blocks recording. | Check: `sessionIndexKeepsNewestFirstAndTrimsTheTail`, `usageCountsThisMonthOnly`, `usageFlagsTheCapWithoutEverBlocking`, `daysLeftCountsTodayAndResetsOnTheFirst`.

R19. A Job can be cancelled before it finishes. A queued Job never reaches the Provider; one in flight has its request torn down. Cancelling keeps the Recording and is never reported as a failure — it does not auto-retry and does not park as `.failed`. A cancelled Job can be processed after all, or its Recording deleted on explicit confirmation. | Check: `cancellingAQueuedJobNeverCallsTheProvider`, `cancellingLeavesTheRecordingUntilDiscardIsAsked`, `cancellingIsNotAFailure`, `cancellationIsClassifiedAsCancellationNotFailure`.

## Design
Native, minimal, no web frontend of any kind. AppKit owns the status item and the one window; SwiftUI draws its content, with no `@State` anywhere (ADR-0004).

**One window.** The app never puts a second thing on screen. The Sessions panel hangs from the menu bar icon, pointing at it, and every part of the app is a view inside it: the usage card and Session history, the live recording block (elapsed time, waveform, Pause, Stop & save, Discard), naming speakers, settings, and confirmations for anything irreversible. Left click opens and closes it; right click gives a short menu of shortcuts into those same views plus Quit. macOS notifications cover "Note ready", failures, speakers to name, and a call ending — they are the only thing the app shows while the panel is closed.

The panel is dark regardless of system appearance: it appears over whatever you are doing, and a surface that flips to white mid-call is more distracting than one that always looks the same.

Concurrency: one Session at a time; Jobs run in the background, so Start is always available while earlier Jobs are queued, processing, or errored. Icon precedence when states coincide: recording/paused (the active Session) > error > processing > idle.

## Architecture
Swift, menu-bar-only (`LSUIElement`); SwiftUI `MenuBarExtra` is the expected shell, AppKit acceptable — no Electron/Tauri/web runtime (hard constraint: 8GB machine).

**Capture** ([ADR-0001](docs/adr/0001-process-tap-two-track-capture.md)): Core Audio process tap + physical mic combined in one aggregate device with drift compensation enabled (`kAudioSubTapDriftCompensationKey: true`). Each Track is written as its own mono CAF file, 16kHz 16-bit PCM, continuously flushed (crash-tolerant by format); encoding work runs at `.utility` QoS. The Job transcodes each Track to FLAC before upload to cut transfer size; the CAF originals remain the Recording of record until deletion.

**STT**: a pluggable Adapter interface with one v1 implementation, AssemblyAI Universal-3.5 Pro. ElevenLabs Scribe v2 is the named contingency if diarization disappoints on real calls — the interface is the insurance, justified by observed provider churn. Diarization is cloud-side only ([ADR-0002](docs/adr/0002-cloud-diarization-over-local.md)). AssemblyAI cannot do multichannel + diarization in one request, so the Adapter submits per Track as in Journey step 5.

**Merge rule** (Journey step 6): both Tracks share the Recording clock (same aggregate device, same start; pauses stop both). The Transcript is the utterance lists of both results interleaved by start timestamp; overlapping speech simply interleaves. Remote speakers are numbered by order of first appearance ("Speaker 1"…); every Mic utterance is labelled "Me". Pause markers are inserted at their clock position. No word-level cross-alignment between the two results is ever needed — this is a two-list sort, not diarization-to-transcript alignment.

**Summarisation**: a separate Anthropic API call — `claude-opus-5` with adaptive thinking (`thinking: {type: "adaptive"}`) — never the Provider's bundled summariser. Preset defaults live in the repo, are seeded at first launch, and are user-editable afterwards. Note bodies: **Meeting** — Summary, Key points, Decisions, Action items (owner and due date where stated), Open questions. **Lecture** — Summary, Topics covered, Key concepts and definitions, Examples given, Follow-up questions. **Interview** — Summary, Background, Questions and answers, Notable quotes, Follow-ups. **Training** — Summary, Skills and procedures taught, Steps to remember, Resources mentioned, Action items. All four embed the R11 canonical naming rule.

**Transcript format**: markdown. One line per utterance: `- **HH:MM:SS Speaker:** text`, timestamps in recorded-audio time (the clock pauses with the Recording); pause markers appear as their own line, `[recording paused — <duration>]`, carrying the wall-clock gap length.

**Cost** (R10/R14): computed from a rate table in one repo config file, USD — AssemblyAI $/audio-hour (per submitted Track, at current published pricing) and Claude $/MTok in and out from reported token usage. Rates are maintained by hand; the table is the single source.

**Vault delivery**: atomic file write (write temp file, rename into place). The Transcript is markdown at `<Vault>/transcripts/<Note name> (transcript).md`, so its basename never collides with the Note's; the Note's frontmatter links it as a wikilink.

**State**: Job state and pending Recordings in `~/Library/Application Support/Braid/`. Signing: the stable self-signed local identity "ms-notes Development" — named before the app was, and deliberately not renamed, because a new identity makes macOS forget the audio permissions already granted ([ADR-0004](docs/adr/0004-swiftpm-no-xcode-toolchain.md)), or macOS's privacy-permission system (TCC) re-prompts and misbehaves between builds.

**Toolchain** ([ADR-0004](docs/adr/0004-swiftpm-no-xcode-toolchain.md)): SwiftPM + Command Line Tools, no Xcode; a repo script assembles and signs the `.app`. Deployment target: macOS 27 only (this machine). Zero third-party dependencies. Swift Concurrency throughout (actors for the Job queue and capture state); Job state persisted as JSON files.

## Operation
No server component exists. Production = the signed `.app` in `/Applications` on the owner's MacBook, launched at login. Deploy = the repo's build script (`swift build` → assemble bundle → sign) → copy to `/Applications`; rollback = reinstall the previous version's kept zip; source in git, one tag per installed version. Logging = unified logging (`os_log`); the "pipeline" log category records each Job step including Provider/Summariser request parameters with credentials redacted, readable via `log show` — this is the log R6's check inspects. Every pipeline failure also surfaces in the menu-bar error state, never only in a log. Backups: Notes and Transcripts live in the Vault under the owner's existing vault backup; Recordings are transient by design and only a confirmed-success Job may delete one. Data protection: keys in Keychain (R13); AssemblyAI training opt-out enabled on the account; audio leaves the machine only to the Provider and is deleted locally after success; no voiceprints ([ADR-0003](docs/adr/0003-no-voiceprints-ever.md)). Consent posture: the owner verbally mentions recording; audio auto-deletion is the mitigation.

## Done
Owner-executed (the R-checks are agent-runnable; this gate is human). On the owner's Mac, in production: record one real call of ≥15 minutes with ≥2 remote speakers, using Pause once and entering Participants. Within 15 minutes of Stop, hands-off: a correctly named Note is in the Vault with the pause marked, names attributed only where evident, frontmatter complete, Transcript written and linked, Recording deleted, cost total incremented. Then the rolling criterion: ≥9 of the first 10 real calls deliver their Note hands-off within 15 minutes. Anything less fails the spec.
