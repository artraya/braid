# Speaker attribution
status: verified
created: 2026-08-01
updated: 2026-08-01
release: production

## Outcome

The owner's notes name remote speakers correctly with near-zero effort: names
they typed before the call are transcribed correctly and applied with at most
one click, a known speaker count can be asserted to sharpen diarization, and
when the provider hears a different number of voices than expected the mismatch
is surfaced instead of silently mis-attributed.

## Prompt

Owner feedback (2026-08-01): pre-meeting Participants never show up in notes
(perceived bug; actually R6a/R11 no-guessing by design, but Participants also
never reach the provider as vocabulary, so the transcript evidence R11 needs is
routinely mis-spelled); diarization sometimes splits or merges speakers with no
recourse; wants a speaker-count control and an Auto default with real error
handling. Full design discussion in session of 2026-08-01.

## Evidence and assumptions

- Fact: Participants reach only the Summariser as hints (Summariser.swift:27);
  key terms sent to AssemblyAI are the global list only (JobQueue.swift:287).
- Fact: AssemblyAI supports `speakers_expected` (exact) and `speaker_options`
  {min_speakers_expected, max_speakers_expected}, documented as improving
  clustering when the count is known (docs, checked 2026-08-01).
- Fact: a previous implicit cap (Participants+1) mis-attributed a late joiner;
  R6 currently forbids any speaker count and a test asserts it.
- Fact: assigning the same name to two labels already merges them in the note
  (Transcript.renamingSpeakers maps labels independently); it is just invisible.
- Fact: recordings are deleted after delivery (R7), so under-splitting cannot be
  repaired after the fact; only prevented pre-call or disclosed.
- Assumption: min-only constraints capture most of the accuracy win with none of
  the late-joiner risk; strict max is rarely needed.
- Unknown: how much a min constraint improves real diarization on the owner's
  actual calls (observed over the next few real meetings, not testable locally).

## This cycle

One slice through form → provider → warning → naming:

1. Session Participants are appended to `keyterms_prompt` for both requests
   (deduplicated against global Key Terms), so names arrive spelled correctly.
2. The start form gains a Speakers control: **Auto** (default, sends nothing)
   or a count N, which sends `speaker_options.min_speakers_expected = N`; a
   strict toggle additionally sends `max_speakers_expected = N`, labelled with
   its cost ("late joiners will be merged"). SPEC R6 and its check are amended
   to match; the stale "speaker range" phrase in Journey step 5 is corrected.
3. After transcription, detected remote-speaker count is compared against N
   (hard signal) or Participant count (soft signal); a mismatch surfaces via
   the existing warning pattern (notification + naming sheet line, e.g. "heard
   3 voices, you expected 2"), never blocking delivery. Fewer-than-expected
   states plainly that the fix is setting the count before the next call.
4. Naming sheet: typing the same name for two speakers is surfaced as the merge
   affordance it already is (suggestion chips reused across labels, a one-line
   hint); when exactly one remote speaker was heard and exactly one Participant
   was listed, the "speakers to name" notification offers one-click Apply,
   running the existing SpeakerNamer pass. Nothing is ever applied unasked.

## Not this cycle

- Echo bleed work of any kind (detection, dedup, DSP) — next cycles, researched
  in docs/echo-cancellation.md.
- Voice-based speaker identification across meetings (forbidden, ADR-0003).
- Post-hoc re-transcription or re-diarization (impossible by design, R7).
- Deriving any provider constraint from Participants (burned before; R6 scar).
- Changes to the merge rule, Transcript model, or Provider seam.

## Approach

All changes sit on existing seams. `requestBody(...)` gains optional
speakerCount/strict and participant key-terms parameters (R6's check asserts
against this same function). Session carries the chosen constraint; the start
form adds one segmented control + conditional toggle. Mismatch detection is a
pure function of (Transcript, Session) evaluated in JobQueue after merge,
feeding Notifier and NamingRecord. The 1:1 Apply path calls SpeakerNamer.apply
with the single mapping. No new files of consequence, no dependencies, no
capture changes.

## Risks and routes

- Amending R6 weakens a guard that earlier pain paid for — mitigated: Auto
  remains the default and the amended check asserts Auto sends no speaker
  fields; the strict toggle's label owns the late-joiner cost.
- Provider parameter drift (the `speech_model` → `speech_models` incident) —
  mitigated: submission body remains logged (R6 log line); a rejected field
  surfaces as a permanent, visible job error, not silence.
- Re-running the Summariser on Apply can reword more than names — accepted,
  existing R6a behaviour; noted in the naming sheet copy.

## Checks

- [ ] `requestBody` assertions: Auto sends no speaker fields (amended R6
      regression); N sends min only; N+strict sends min and max; Participants
      appear in `keyterms_prompt` deduplicated, and never as a speaker count.
- [ ] Fixture job with 3 remote voices against an expectation of 2: the note
      still delivers hands-off, and the mismatch warning appears in both the
      notification path and the naming sheet.
- [ ] Naming: same name on two labels produces one merged speaker in note and
      transcript; the 1:1 case offers Apply and a confirmed Apply relabels
      "Speaker 1" to the participant everywhere; declining changes nothing.

## Result

Delivered 2026-08-01. All three checks pass; 56 tests green (46 pre-existing,
10 new), `swift build` clean, `--ui-preview` snapshots confirm the new form
control, mismatch line, and merge hint render.

**What changed**

- `Session` gained `SpeakerExpectation` (count + strict) and
  `SpeakerCountMismatch`, plus pure helpers `mergedKeyTerms(global:)` and
  `speakerMismatch(heardRemoteSpeakers:)`. Both new stored fields are optional,
  so Sessions and NamingRecords persisted before this cycle decode unchanged.
- `STTProvider.transcribe` and `AssemblyAIAdapter.requestBody` carry the
  expectation; N sends `speaker_options.min_speakers_expected`, strict adds
  `max_speakers_expected`, the undiarized Mic request never carries speaker
  fields, and the default sends nothing (amended-R6 regression test).
- `JobQueue` submits Participants inside the Key Terms (deduplicated,
  case-insensitive) for both requests; the cost table's keyterms flag follows
  the merged list, so accounting matches what was billed. Mismatch is computed
  after the Vault write — informative, never blocking — logged, attached to
  the `speakersDetected` event and persisted on the NamingRecord.
- Start form: "Voices on the far end" (Auto default / 1–6) with an "exactly"
  checkbox whose footer owns the late-joiner cost. Auto sends nothing.
- Naming sheet: mismatch line (amber), merge hint ("give both voices the same
  name"), and 1:1 prefill. Notification for the 1:1 case carries an Apply
  button (new `Notifier` delegate; clicking any speakers notification opens
  the naming view). Nothing is applied without explicit user action (R6a).
- `Summariser` sits behind a new `NoteSummarising` protocol so the pipeline
  fixture test runs a Job to completion offline; `SpeakerNamer` and
  `JobQueue.Environment` take the protocol.
- SPEC.md: R6 amended (dated, linked here); Journey step 5's stale "speaker
  range" corrected. UIPreview naming fixture now includes a mismatch.

**Checks**

1. `requestBody` assertions — `defaultRequestsNeverConstrainTheSpeakerCount`,
   `assertedCountSendsTheMinimumOnly`, `strictAddsTheMaximum`,
   `micRequestNeverCarriesSpeakerFields`, `participantsJoinTheKeyTermsDeduplicated`. Pass.
2. Fixture job, 3 voices vs asserted 2 — `mismatchWarnsAfterDeliveryWithoutBlockingIt`
   proves the Note lands, the Recording is deleted, the event and NamingRecord
   carry {heard 3, expected 2, asserted}, and the expectation reached only the
   diarized request with Participants in both key-term lists. Pass. Notification
   body and naming-sheet line verified via `--ui-preview` snapshot.
3. Naming — `sameNameOnTwoSpeakersMergesThem`,
   `oneToOneCandidateNeedsExactlyOneVoiceAndOneParticipant`; declining changes
   nothing (candidate is read-only until Apply). Pass.

**Review** (self, against contracts): no blocking or material findings. Advisory:
the notification Apply button itself (UNNotificationAction wiring) is exercised
manually, not by automated test, consistent with the project's UI test posture;
README screenshots predate the new form row.

**Limitations within contract**: heard-0 stays R16's territory; soft mismatch
can misfire if the user lists themselves in Participants (non-blocking, worded
gently); under-splitting remains unfixable post hoc by design (R7).

## Release

Verified locally. Production = build, sign, install to /Applications per SPEC
Operation; recorded below after authorization.

## Learning and next move

<!-- iterate -->
