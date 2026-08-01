# Braid lifecycle adoption
status: ready
updated: 2026-08-01
target-lane: fast
baseline: `github.com/artraya/braid`, branch `main`, commit `0d13e6a` (2026-07-31),
tag `v0.2.0-1-g0d13e6a`. Runtime: `/Applications/Braid.app` on the owner's M3
MacBook Air, macOS 27, in daily use. Working tree clean except one untracked
design note.

## Adoption purpose and scope

Braid predates these lifecycle skills. It was built under an earlier methodology
(IDEA → SPEC → CONTEXT → ADRs → six numbered phases) that produced real, good
artifacts but not the ones the fast lane expects: there is no `PROJECT.md` and no
`cycles/`. The app now works and is in daily use, and the next change is already
identified in a design note. Adoption exists to carry the existing contract into a
cycle without discarding it.

Scope is the whole repository — one Swift package, two targets, no server, no
second system.

## Evidence examined

| Source | Scope and version | What it establishes | Limit |
|---|---|---|---|
| `Sources/` | 9,004 lines, 2 targets, commit `0d13e6a` | Actual behaviour, boundaries, provider seam | Read, not executed line by line |
| `./scripts/test.sh` | Run 2026-08-01 | 46 tests pass, 0.36s, build green | Unit level only; no UI or live-network tests |
| `SPEC.md` (untracked, local) | 97 lines, mtime 2026-07-31, `status: approved` | Binding requirements R1–R19, journey, architecture | Not in git; version unverifiable |
| `CONTEXT.md` (untracked, local) | 58 lines | Domain language, 12 terms | Not in git |
| `IDEA.md`, `MORNING.md` (untracked, local) | 41 KB / 6.5 KB | Origin research; phase-6 handoff and R-check results | Not in git; MORNING is dated |
| `README.md` | Tracked, rewritten `0d13e6a` | The public-facing contract; costs, posture, build | — |
| `docs/adr/0001–0004` | Tracked | Four durable decisions with consequences | — |
| `docs/echo-cancellation.md` | Untracked, written 2026-08-01 | An unresolved correctness problem and its design | Explicitly "nothing decided or built" |
| `git log` | 25 commits, tags `v0.1.0`, `v0.2.0` | Phase history, the go-public commit, the Braid rename | History is squashed by phase, not fine-grained |
| `~/Library/Application Support/Braid` | Live, 48 KB | 4 jobs recorded, 3 transcripts, no pending audio | Contents not read (personal) |
| `.env`, `.gitignore` | Tracked ignore rules | Keys are gitignored and Keychain-resident | `.env` contents deliberately not read |

Not examined: the Obsidian vault output, Console.app pipeline logs, the AssemblyAI
and Anthropic account settings. None of these were needed to establish a baseline,
but they are where R5/R6/R14 evidence actually lives at runtime.

## Project identity

A personal macOS menu-bar app that records a call as two audio tracks, sends them
to AssemblyAI for transcription and speaker separation, summarises with Claude, and
writes a markdown note plus transcript into an Obsidian vault. One user: the owner.
One machine. No server, no accounts, no multi-user anything.

Maturity: working and shipped to itself. Tag `v0.2.0`, installed, in daily use,
README says "unlikely to grow much". The full R1–R16 verification pass is recorded
in MORNING.md; R17–R19 arrived afterwards with their own tests.

**Observed:** the project is publicly published on GitHub under MIT with a README
written for other people. **Owner-confirmed (2026-08-01):** this is now deliberate —
Braid is being developed for public use, superseding SPEC non-goal #6. What "public
use" means concretely is still build-it-yourself from source; a signed, notarized,
downloadable app has not been decided and would be a larger change (see the lane
recommendation).

## Current behaviour and journeys

Confirmed by code and tests:

- Capture is a Core Audio process tap plus the physical mic in one aggregate
  device, two mono 16 kHz CAF tracks, drift compensation on, with a silence
  keep-alive rendering to the output so the tap's clock never stalls
  (`CaptureEngine.swift`, `SilenceKeepAlive.swift`).
- Start is manual. Stop can be automatic: `CallWatcher` arms only after a call app
  has held the mic, then fires once after a 15s release plus a 30s cancellable
  countdown (four tests cover arm, fire, reconnect, and disarm).
- The job pipeline is a serial actor queue with JSON state per job beside the
  recording — transcode to FLAC, two AssemblyAI requests, merge on the shared
  clock, Claude summary, atomic vault write, then delete the recording only after
  both files are confirmed (`JobQueue.swift`, 376 lines).
- The remote request carries diarization with no speaker count of any kind, plus
  `en_au` and key terms; the mic request is undiarized and labelled "Me"
  unconditionally (`AssemblyAIAdapter.swift`, three tests).
- Speakers are named after the fact, never guessed. Renaming rewrites note and
  transcript in place unless the note changed on disk, in which case a new pair is
  written (`SpeakerNamer.swift`, three tests).
- Cancellation is modelled as its own outcome, not a failure — no auto-retry, no
  `.failed` parking, recording kept (four tests).
- One window: the panel hangs off the status item and contains every view the app
  has. Two geometry tests assert it stays on screen and its arrow tracks the icon.

Runtime state agrees: four jobs recorded, three transcripts retained, no pending
audio in Application Support — the success-gated deletion in R7 is behaving.

## Domain language

`CONTEXT.md` defines twelve terms and the code uses them consistently — types are
literally named `Session`, `Transcript`, `Preset`, `JobQueue`, `VaultWriter`,
`SpeakerNamer`, `CostTable`. This is unusually clean and needs no reconstruction.

| Term | Observed meaning | Source | Confidence | Conflict |
|---|---|---|---|---|
| Session, Recording, Track | As CONTEXT.md defines them | CONTEXT.md + type names | high | None |
| Provider / Adapter | AssemblyAI behind `STTProvider` | Code + ADR-0002 | high | None |
| Job, Preset, Key Terms, Participants | As defined | Code + tests | high | None |
| Note, Vault, Transcript | As defined | `VaultWriter.swift` | high | None |
| Call watcher | SPEC R17's check names `CallEndDetector`; the type is `CallWatcher` | SPEC vs code | high | Cosmetic naming drift |

## System map

```
StatusItemController ──▶ SessionsPanel (every view)     BraidApp   AppKit shell +
        │                                                          SwiftUI content
        ▼
   CaptureEngine ──▶ TrackWriter ×2 ──▶ mic.caf / remote.caf
        │            CallWatcher (auto-end), LevelMeter, SilenceKeepAlive
        ▼
   JobQueue (actor, serial) ──▶ Transcoder ──▶ AssemblyAIAdapter ──▶ Transcript
        │                                                              │
        └──▶ Summariser (Claude, plain URLSession) ──▶ VaultWriter ──▶ vault
                                                       TranscriptStore, SessionIndex
```

Two targets: `BraidCore` holds all logic and is headless-testable; `BraidApp` is the
shell plus CLI test modes (`--ui-preview`, `--import-keys`, `--check-keys`). Zero
third-party dependencies by policy (ADR-0004). Both external services sit behind
thin seams — the STT protocol, and a single-file HTTP call for Claude.

## Data and state

- **Authoritative:** the Obsidian vault. Notes and transcripts live there and are
  covered by the owner's existing vault backup. Braid writes and stops.
- **Transient:** recordings in `~/Library/Application Support/Braid/jobs/`, deleted
  only after both output files are confirmed on disk. Verified empty of audio now.
- **Retained locally:** `sessions.json` (history and usage) and per-session
  transcript JSON, for after-the-fact renaming.
- **Secrets:** macOS Keychain, items owned by the installed app. `.env` is the
  import staging file and is gitignored.
- No database, no migrations, no schema versioning. State is JSON files written by
  one serial actor.

Recovery: a lost note is regenerable only if its recording still exists, which by
design it usually does not. The transcript JSON survives, so a note can be
re-summarised; the audio cannot be recovered. This is deliberate (ADR-0003 posture,
audio auto-deletion as the consent mitigation), not a gap.

## Stack and environments

One environment. `swift build` via Command Line Tools, no Xcode; `scripts/build-app.sh`
assembles and signs `dist/Braid.app`; install is a copy into `/Applications`.
"Production" is that bundle on one Mac, launched at login. Rollback is reinstalling
a previous build. No CI, no preview, no hosting, no domain.

Two paid services, both metered per use: AssemblyAI (~$0.54/hr, two tracks billed
separately) and Anthropic (~$0.10/hr). README puts real use at a couple of dollars
a month; MORNING.md records $0.066 for a 4-minute test job. A monthly cap is set in
the app and warns without ever blocking.

Reproducibility caveat: the build depends on a self-signed identity,
`ms-notes Development`, that exists only in the owner's login keychain. Nobody else
can reproduce the signed artifact, and the README says so plainly.

## Security and operation

No authentication, no authorization, no network surface — Braid is a client that
makes two outbound HTTPS calls. Trust boundaries are the two providers.

- **Sensitive data:** other people's speech leaves the machine. This is disclosed in
  the README ("Not a privacy tool"), mitigated by local audio deletion and by
  ADR-0003's permanent no-voiceprints line, and the consent posture is verbal.
- **Secrets:** Keychain only (R13 verified). `.env` gitignored; `.env.example` ships
  empty. Repo scanned — no key material in tracked files.
- **Permissions:** Microphone and System Audio Recording. Deliberately *not* Screen
  Recording (ADR-0001). macOS exposes no way to query the audio grant, so R16
  detects a silent remote track and warns instead of assuming.
- **Public exposure:** source only. The published repo is readable by anyone; the
  built app is not distributable.
- **Operation:** `os_log` subsystem `no.braid.app`, category `pipeline`, read via
  Console.app. Every pipeline failure also surfaces in the UI, never only in a log.
  No alerting, no uptime concern — there is nothing running to be down.

## Quality and change safety

Strong for a project this size. 46 tests, all green, 0.36s, and they map to
requirements deliberately — SPEC R6a, R17, R18 and R19 name their tests by function
name, and those functions exist. All logic sits in `BraidCore` so it is testable
without a UI.

Weakly evidenced areas, in order of how much they would hurt:

1. **Speaker bleed without headphones.** Unhandled and untested. See below.
2. **UI behaviour.** Covered by two geometry tests and a `--ui-preview` snapshot
   mode, which is a genuinely good substitute, but no interaction is tested.
3. **The live network path.** No test exercises a real AssemblyAI or Anthropic call;
   provider drift would only surface at runtime. The project has already been bitten
   by this once (`speech_model` → `speech_models`).
4. **Permission loss.** If the System Audio grant is revoked, R16 catches it after
   the fact, never before.

## Documentation inventory

| Existing artifact | Classification | Useful evidence | Recommended destination |
|---|---|---|---|
| `SPEC.md` (untracked) | current, but unversioned | R1–R19, journey, architecture, done gate | Source for `PROJECT.md`; keep as the standing contract |
| `CONTEXT.md` (untracked) | current | Twelve binding domain terms | Keep as `CONTEXT.md`; already correct |
| `README.md` | current | Public posture, costs, build, usage | Stays; it is the outward contract |
| `docs/adr/0001–0004` | current | Four durable decisions with consequences | Stay; already the right shape |
| `docs/echo-cancellation.md` (untracked) | current, aspirational by its own admission | A designed but unbuilt correction | Input to the first cycle |
| `IDEA.md` (untracked) | historical | Origin research, provider comparison, cost modelling | Preserve as-is; do not fold into a cycle |
| `MORNING.md` (untracked) | historical, partially drifted | The R1–R16 verification record — genuinely valuable | Preserve as the v0.1.0 verification evidence, not as current truth |

MORNING.md's drift is worth naming precisely because the rest of it is accurate:
it refers to `/Applications/ms-notes.app`, subsystem `no.msnotes.app`, and states
"the app is AppKit, not SwiftUI". All three were true when written and none are now.
Its verification table is still the best record of how R1–R16 were proven.

## Evidence ledger

| Claim | Type | Source | Confidence | Conflict | Destination |
|---|---|---|---|---|---|
| R1–R16 verified on real hardware | documented | MORNING.md | medium | Predates the Braid rework; not re-run since | `PROJECT.md` history |
| R17–R19 implemented and tested | observed | Tests pass, named in SPEC | high | None | `PROJECT.md` |
| Recording deleted only after both files confirmed | observed | `JobQueue.swift` + live state | high | None | `PROJECT.md` |
| No local ML, no voiceprints | observed | Zero deps, no model files | high | None | ADRs 0002/0003, already recorded |
| Keys in Keychain only | observed | `KeychainStore.swift`, repo scan | high | None | `PROJECT.md` |
| "No distribution, one Mac" | owner-confirmed obsolete | SPEC non-goal #6 vs owner, 2026-08-01 | high | Resolved: public use is the intent | `shape` rewrites non-goal #6 |
| SPEC/CONTEXT are the binding contract | owner-confirmed | `status: approved` + owner, 2026-08-01 | high | Resolved: now tracked in git | Source for `PROJECT.md` |
| Version is 0.1.0 | observed | `Version.swift` | high | **Contradicted** by tag `v0.2.0` | Fix in a cycle (code) |
| Support dir is `ms-notes/` | observed | Runtime uses `Braid/` | high | Resolved: SPEC text corrected | Done |
| Headphones are assumed | inferred | `docs/echo-cancellation.md` | high | Nothing in app or README says so | First cycle |
| Bleed corrupts attribution | inferred | Reasoned in the design note | medium | Never measured on real audio | Needs evidence |

## Reconciliation ledger

Owner reconciliation held 2026-08-01. Three decisions taken.

| Finding | Current state | Owner-confirmed future | Disposition | Route |
|---|---|---|---|---|
| Distribution scope | SPEC non-goal #6 says one Mac, no distribution; repo is public MIT | "We're now developing this for public use" | **change** | `shape` rewrites non-goal #6 in `PROJECT.md`; see the new open decision below |
| Contract location | SPEC/CONTEXT/IDEA/MORNING gitignored | Move them into the repo | **change** — done in this pass | `.gitignore` updated; files now tracked |
| SPEC titled `ms-notes` | Stale after the Braid rename | Align | **change** — done | SPEC title corrected |
| SPEC state path `ms-notes/` | Runtime uses `Braid/` | Align to reality | **change** — done | SPEC Architecture corrected |
| SPEC R17 cites `CallEndDetector` | Type is `CallWatcher` | Align to reality | **change** — done | SPEC R17 check corrected |
| Signing identity `ms-notes Development` | Pre-rename name, deliberately kept | Keep; renaming loses TCC grants | **preserve** | SPEC now records why, matching the README |
| `MSNOTES_*` env prefix | Pre-rename leftover | Not yet decided | **needs-evidence** | A cycle, if it is worth the churn |
| `Version.swift` = 0.1.0 vs tag v0.2.0 | Drifted | Align | **change** | A cycle — this is code, not docs |
| Headphone assumption / speaker bleed | Undetected, undocumented, unbuilt | Not yet decided | **known-defect** | First or early cycle |
| ADRs 0001–0004 | Accurate | Unchanged | **preserve** | None |
| R1–R16 verification (MORNING.md) | Historical, pre-Braid | Keep as evidence, not current truth | **legacy-compatibility** | Preserved as-is |

Nothing in SPEC's requirements, journey, or outcome was altered. Only statements of
fact that the code had already overtaken were corrected. Product intent — non-goal #6
in particular — is left for `shape`, which owns it.

## Candidate durable decisions

For `architect-project` only if the full lane is ever entered. None of these need a
new ADR to proceed in the fast lane:

- **Publishing the source publicly** (commit `cc19d11`). Reverses SPEC non-goal #6.
  No ADR, no recorded rationale. This is the one decision with lost reasoning.
- **Rejecting VoiceProcessingIO for echo cancellation** (`docs/echo-cancellation.md`).
  Three reasons given, well argued, but nothing is built yet — it becomes a decision
  when the work starts, not before.
- **The gitignore of internal documents** (`cc19d11`). Deliberate, but the reasoning
  is only the commit subject: "Make the repo public-facing".

Existing ADRs 0001–0004 are accepted, still accurate, and need no revisiting.

## Drift, gaps, and contradictions

### Blocking

None. The build is green, the app runs, the contract is legible, and the next change
is already designed.

### Material

1. ~~**The binding contract is not in the repo.**~~ **Resolved 2026-08-01.** The
   gitignore entries for `SPEC.md`, `CONTEXT.md`, `IDEA.md` and `MORNING.md` were
   removed; all four are now tracked, as is `docs/echo-cancellation.md`. Before
   un-ignoring them they were scanned for identifying content — no emails, no company
   names, no absolute personal paths. The only personal reference is `owner: Alexandro`
   in the SPEC header, which matches what the git history already publishes. They are
   staged, not committed; the publish is yours to make.

2. **Speaker bleed misattributes the far end to "Me".** Braid assumes headphones;
   nothing says so and nothing detects otherwise. Without them the far end lands on
   both tracks, and the mic track is labelled "Me" unconditionally
   (`AssemblyAIAdapter.swift:8`), so their decisions and action items get handed to
   the user in the note. A wrong owner reads as correct, which is worse than a
   missing one. Designed in `docs/echo-cancellation.md`, nothing built, no test.
   This is the strongest candidate for the first cycle, and public use raises its
   severity: on your own Mac the headphone assumption is a habit you already have,
   but a stranger who runs Braid on speakers gets silently wrong notes with no
   warning anywhere in the app or the README.

3. **SPEC non-goal #6 is now known-false and still written down.** The owner has
   confirmed public use; the SPEC still says "No distribution: personal build, one
   Mac." I deliberately did not rewrite it — product intent belongs to `shape`, and
   this is the first thing it should settle. Until it does, the contract contains a
   statement its owner has disowned.

4. **Public use is confirmed but unscoped.** "Build it yourself from source" and
   "download a signed app" are very different commitments, and only the first is
   currently true. The second needs an Apple Developer account and notarization,
   which reverses part of ADR-0004, plus an update story and a support posture. This
   does not block adoption — it bounds it. See the lane recommendation.

### Advisory

Closed in this pass:

- ~~SPEC titled `ms-notes`~~ — corrected to Braid.
- ~~SPEC says state lives in `Application Support/ms-notes/`~~ — corrected to `Braid/`.
- ~~SPEC R17's check names `CallEndDetector`~~ — corrected to `CallWatcher`.
- ~~`docs/echo-cancellation.md` is untracked~~ — now tracked.
- CONTEXT.md needed no correction; it was already titled Braid and its twelve terms
  all match the code.

Still open:

5. `Version.swift` says `0.1.0`; the tag is `v0.2.0`. This is code, so it belongs to
   a cycle rather than a doc pass. It matters more now that other people may read it.
6. The `MSNOTES_*` env var prefix is a pre-rename leftover in `CLI.swift` and
   `.env.example`. Free to change, and more visible now that strangers follow the
   README's setup steps. Not worth a cycle of its own.
7. The `ms-notes Development` signing identity is also pre-rename but should **not**
   be renamed — a new identity makes macOS forget the audio permissions already
   granted. Both the README and now SPEC record why. Preserved deliberately.
8. `test-audio/` holds real personal recordings, correctly gitignored. Worth
   re-checking before any future change to the ignore rules.

## Existing strengths to preserve

- **Requirements name their own tests.** R6a, R17, R18, R19 cite test function names
  and those functions exist. This is the single best thing about the project and the
  cycle format should keep doing it.
- **All logic in `BraidCore`, headless-testable.** The reason 46 tests run in 0.36s.
- **`--ui-preview` with snapshot and geometry checks.** A real answer to "how do you
  test a menu-bar panel without Xcode".
- **Four ADRs that record consequences, not just decisions.** ADR-0001's note about
  a tap stalling the whole aggregate device is the kind of hard-won fact that is
  normally lost.
- **Zero dependencies, two thin provider seams.** Provider drift has already been
  survived once because of this.
- **Cancellation modelled as its own outcome.** Not overloaded onto failure.
- **The README is honest about cost, privacy, and who should not use it.**

## Lane recommendation

**Fast lane.** Your recommendation holds, and the evidence supports it more strongly
than "it's a small app" would:

- One purpose, one user, one machine, one process. No server, no auth, no
  multi-user data, no availability obligation.
- The consequential architecture is already decided and documented in four ADRs that
  still hold. Nothing pending requires an architecture gate.
- Changes are locally reversible: rollback is reinstalling the previous bundle, and
  the vault is the only durable artifact.
- Verification is genuinely cheap — 46 tests in under a second, plus a preview mode
  for the UI.
- `PROJECT.md` plus one cycle can safely carry a cold session, *provided* the
  contract is actually in the repo. See material finding 1.

I want to be explicit about what I checked before agreeing, because lane size does
not override risk: this project handles other people's voices, sends them to two
third parties, and is published publicly. Those are real, but none of them is an
*open* decision. The privacy posture is settled (ADR-0003, README disclosure, local
audio deletion), secrets are Keychain-only and verified, and the public exposure is
source-only with no distributable artifact. Settled risk does not need a full lane.

**The public-use decision does not change this, but it narrows the margin.** Braid
stays fast-lane while "public" means *the source is readable and buildable*: every
user brings their own machine, their own keys, and their own vault, so there is still
no server, no shared data, no account, and nothing that can be down. What each user
runs is their own copy.

Two things would move it to the full lane, and both are foreseeable rather than
hypothetical:

- **Shipping a signed, notarized, downloadable build.** That reverses part of
  ADR-0004, needs an Apple Developer account, and brings an update mechanism, a
  support surface, and a real privacy posture for people who never read the README.
  Route that to `architect-project` and `security`, not to a cycle.
- **Anything that stores voice data between sessions**, which ADR-0003 already
  forbids permanently, or a second user sharing state.

Neither is in play today, so `shape` is still the right next step. Naming the
boundary now means you will notice when you cross it.

## Translation map

| Adoption evidence | Destination | Required decision |
|---|---|---|
| SPEC outcome, journey, non-goals, R1–R19 | `PROJECT.md` via `shape` | Rewrite non-goal #6 for public use |
| `CONTEXT.md` | Stays as-is | None; it is already correct |
| ADRs 0001–0004 | Stay in `docs/adr/` | None |
| `docs/echo-cancellation.md` | First cycle scope | Which layers are in |
| MORNING.md verification table | `PROJECT.md` history | None |
| IDEA.md | Preserve as historical | None |
| Rename tail (advisory 4–8) | A cleanup cycle, or folded into the first | None |
| Build, signing, install | `STACK.md` only if it ever needs to grow | None now |

## Adoption route

1. **`shape`** — the one immediate next step, and the owner's stated intent. It reads
   this file, reconciles SPEC and CONTEXT into `PROJECT.md` (rewriting non-goal #6 for
   public use), and writes the first cycle under `cycles/`.
2. Then `deliver` for that cycle.
3. `security` is **not** required now. The posture is settled and disclosed. Revisit
   if a signed distributable build is ever on the table.
4. `prepare-dev-stack` is **not** required. One machine, one script, no services to
   provision. Revisit only if public use ever means CI or a release pipeline.

## Open owner decisions

1. **What does "public use" concretely include?** Confirmed as the direction, but the
   shape is unsettled: source-only as today, or eventually a signed downloadable app.
   `shape` needs this to write non-goal #6, and the answer decides whether Braid stays
   in the fast lane. Not blocking — today's answer is source-only, because that is
   what exists.

2. **What is the first cycle?** Deferred to `shape` at the owner's request. The
   evidence points at speaker bleed, and public use strengthens that: the note's own
   suggested order is Layer 0 detection plus Layer 3 transcript dedup, roughly half a
   day each, stopping wrong attribution without any DSP. The note's own last open
   question — "does the README need a headphones line now, before any of this is
   built?" — answers itself once strangers are running it.

3. **Commit and push?** The doc alignment is staged in the working tree, uncommitted.
   Publishing SPEC, IDEA and MORNING to a public repo is a one-way action, so it is
   left for the owner.

## Reassessment history

None. This is the first adoption baseline.
