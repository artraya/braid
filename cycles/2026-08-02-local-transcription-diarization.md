# Local transcription and diarization

status: building
created: 2026-08-02
updated: 2026-08-02
release: production

## Outcome

A Session is transcribed and speaker-separated entirely on the owner's Mac,
with no audio leaving it and no per-hour cost, and Braid picks that path by
itself. Cloud remains available and takes over automatically when local cannot
deliver, saying so in the Note rather than switching silently.

## Prompt

Adoption (2026-08-01) put Braid on a public-use footing, and the README
currently turns away the exact people that invites: "Not for you if your
machine has headroom for on-device transcription. Run one." Researched in
docs/local-models.md (2026-08-02): the tooling ADR-0002 evaluated and parked
has matured into the shape it was waiting for, and the 8GB constraint that
justified the prohibition governs the *recording* window, where no inference
would run. Owner decisions 2026-08-02: accept FluidAudio pinned, Auto prefers
local immediately, Parakeet is the default engine.

## Evidence and assumptions

- Fact: FluidAudio v0.15.5 (Apache-2.0, 2.6k stars, active 2026-08-01) ships
  Parakeet TDT v3 ASR and offline pyannote community-1 diarization at 10.6%
  DER on AMI SDM, 323x realtime. No SPM package dependencies, but a vendored
  binary xcframework and two C/C++ targets.
- Fact: `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)` transcribes a file
  in batch, so Apple's engine fits a post-Stop pipeline; `contextualStrings`
  carries Key Terms. macOS 26+, and Braid targets 27.
- Fact: the merge rule already relabels Remote speakers by first appearance and
  labels the Mic Track "Me" (`mergeTranscripts`), so an Adapter only has to
  return per-Track utterances. The `STTProvider` seam was built for this.
- Fact: only the Remote Track needs diarization; the Mic Track is one speaker
  structurally (ADR-0001). Half the local pipeline is plain ASR.
- Assumption: word-to-speaker alignment by time overlap on a single track is
  accurate enough for trustworthy attribution — the risk ADR-0002 named, now
  scoped to one track with no self-voice in it.
- Unknown: local accuracy on real compressed Teams far-end audio. Every
  published benchmark is clean speech or meeting corpora.
- Unknown: peak memory of ASR plus diarization on an 8GB machine. Bounded by
  construction (local never runs while recording) but unmeasured.
- Unknown: whether FluidAudio's C++ targets and binary xcframework build under
  Command Line Tools without Xcode (ADR-0004). Being tested first; a failure
  routes this cycle back to shaping.

## This cycle

A `LocalAdapter` behind the existing `STTProvider` seam that transcribes both
Tracks on-device, diarizes the Remote Track, and aligns words to speakers on
the shared clock, with two interchangeable engines (Parakeet by default, Apple
SpeechTranscriber selectable) and a shared model manager that downloads once on
first enable. Provider mode becomes Cloud | Local | Auto in Settings; Auto
prefers local and falls back to cloud only when local fails, recording which
Provider actually ran in the Note's existing frontmatter field and in the
notification. Local Jobs are deferred while a Session is recording, cost zero
for STT, and leave nothing audio-derived about a speaker on disk.

## Not this cycle

- Local summarisation. The Summariser stays Claude; the Anthropic key is still
  required.
- Live transcript or streaming diarization (LS-EEND, Sortformer).
- Key Terms recovery for Parakeet, which has no keyword biasing. Apple's engine
  keeps Key Terms via `contextualStrings`; under Parakeet the list still
  reaches the Summariser and Participants still spell correctly, but it no
  longer biases transcription. Measure the real cost before building a fuzzy
  post-correction that could corrupt correct text.
- Removing the AssemblyAI key requirement from setup, or the README rewrite
  that inverts the "Not for you if" carve-out. Both follow once local is proven
  on real calls.
- DSP echo cancellation (layers 1–2), unchanged from the echo cycle.

## Approach

`BraidCore/Local/`: a `TranscriberEngine` protocol with `ParakeetEngine`
(FluidAudio `AsrManager`) and `AppleSpeechEngine` (`SpeechAnalyzer` +
`SpeechTranscriber`, Key Terms as `contextualStrings`); `LocalDiarizer` wrapping
FluidAudio's offline pyannote pipeline; `SpeakerAligner`, a pure function
mapping timed words onto speaker segments by overlap and grouping them into
`Utterance`s; `ModelManager` for download state and staging under Application
Support. `LocalAdapter: STTProvider` composes them — `diarize: false` returns
one unlabelled stream, `diarize: true` returns aligned speakers. `STTProvider`
gains `prefersCompressedUpload` (local reads the CAF originals, skipping the
FLAC transcode) and `isLocal` (zero STT cost). `JobQueue.Environment` gains an
optional `fallback` provider; `execute` tries the primary for both Tracks and,
on non-cancellation failure, retries the pair with the fallback and records
which one delivered. AppState composes primary and fallback from the mode, so
routing policy stays in the app and the queue stays mechanical.

## Risks and routes

- FluidAudio fails to build under CLT (C++17 targets, binary xcframework) —
  tested before any code is written; failure means Apple engine only for this
  cycle and re-shaping the diarization half, not a partial ship.
- Local attribution is materially worse than cloud on real audio — the fixture
  check compares against the AssemblyAI reference before this is trusted; if it
  fails, Auto is flipped to prefer cloud in Settings and the cycle still ships
  local as a working opt-in, with the numbers recorded in ADR-0005.
- Peak memory on 8GB — models load one at a time and never during a recording;
  the deferral rule is asserted by test, the real figure measured at delivery.
- ADR-0003 erosion: diarization produces speaker embeddings, and this is
  exactly where they could start persisting — a test asserts nothing
  audio-derived about a speaker survives a completed Job, and FluidAudio's
  speaker-enrollment APIs are not linked.
- Reverses ADR-0002 and dents ADR-0004's zero-dependency policy — delivery
  writes ADR-0005 recording both, with the exit route (models are standard
  CoreML artifacts).

## Checks

- [ ] Fixture Session runs end-to-end through `LocalAdapter` with no network:
      a Note and Transcript land hands-off, the Mic Track is entirely "Me",
      the Remote Track carries more than one speaker where the reference has
      more than one, and `provider` frontmatter names the local engine.
      Attribution is compared against the AssemblyAI reference in
      `test-audio/`, and the deviation recorded in the cycle Result.
- [ ] Fallback and disclosure: a primary that always throws delivers the Note
      via the fallback with the fallback's name in the frontmatter; Local mode
      with a broken engine parks as `.failed` and never silently reaches the
      cloud; STT cost is zero when local delivered and unchanged when cloud
      did.
- [ ] Regression and safety: the existing 63 tests stay green with the cloud
      path byte-identical (same FLAC transcode, same request bodies, R6 intact);
      no speaker embedding or voiceprint artifact exists anywhere under
      Application Support after a completed local Job (ADR-0003).

## Result

Built and measured 2026-08-02. 78 tests green (15 new), build clean,
`PANEL-GEOMETRY-OK`, 14 snapshots, `dist/Braid.app` assembles and signs.
**Run for real against `test-audio/fixture-remote.flac` (246s of a genuine
call) with both engines and the real models** — numbers below.

**Measurement, against the AssemblyAI reference for the same audio**

Identical diarizer settings for both, so the difference is engine word timings
alone (the diarizer produced the same 48 turns / 17 speaker changes each time).

| | Parakeet TDT v2 | Apple SpeechTranscriber |
|---|---|---|
| WER vs reference | **9.6%** | 10.3% |
| Turn purity | 61.4% | **70.5%** |
| Coverage | 100% | 100% |
| Utterances (ref 44) | 23 | 27 |
| Speed | **64x realtime** | 43x realtime |
| Peak RSS | **281 MB** | 312 MB |
| Model download | 443 MB | **none** |
| Key Terms | not wired | **supported** |

Word accuracy is genuinely good on real call audio: ~10% deviation from a
Provider costing $0.54/hour, with 100% coverage — no speech is dropped.

**Attribution is the weak point, and it is the current product theme.** Both
engines under-segment: 23–27 utterances where the reference has 44, and only
61–71% of reference turns map to a single local speaker. Root cause is the
diarizer, not the aligner — it finds 17 speaker changes where the reference
alternates roughly 40 times, so short backchannels ("yeah", "sure") get
absorbed into the surrounding speaker and attributed to the wrong person.
`SpeakerAligner` is faithful to the spans it is given (48 diarizer turns, 17
changes → 18 runs → 23 utterances is arithmetic, not error).

Tuning was tried and rejected on evidence: dropping the embedding floor from
1.0s to 0.4s and halving the segmentation step gave 62 turns but still 18
speaker changes, identical 61.4% purity, and 20% more time. The extra turns
were the same speaker split finer, not the missing alternations. Defaults kept,
parameters left exposed so the next fixture can re-test cheaply.

Model loading: 213s the first time (CoreML ANE compilation), 1.0s warm.

**The cycle's stated blocking unknown is resolved.** FluidAudio builds under
Command Line Tools with no Xcode, C++17 targets and binary xcframework
included, links statically, and needs no change to bundle assembly or signing.
The bundle grew from ~3MB to 11MB.

**What changed**

- `BraidCore/Local/` (new): `LocalTypes` (`LocalEngine`, `ProviderMode`,
  `SpeakerSpan`, `TimedWord`); `TranscriberEngine` protocol with
  `ParakeetEngine` (FluidAudio `AsrManager`, words rebuilt from SentencePiece
  token timings) and `AppleSpeechEngine` (`SpeechAnalyzer` +
  `SpeechTranscriber`, Key Terms as `contextualStrings`, word timings from
  `audioTimeRange` attributed runs); `LocalDiarizer` (offline pyannote via
  `OfflineDiarizerManager`) behind a `SpeakerDiarizing` seam; `SpeakerAligner`;
  `LocalAdapter: STTProvider`.
- `STTProvider` gained `prefersCompressedUpload` and `isLocal`, both defaulted
  in an extension so the cloud Adapter and every existing test double compile
  untouched.
- `JobQueue`: `Environment.fallback`, a whole-Job `attempt(_:)` that transcodes
  only for Providers that want an upload, one fallback retry that re-runs both
  Tracks, `providerFellBack` event, `updateProviders` for settings changes, and
  provenance plus cost now taken from the Provider that actually delivered.
- Settings: a Transcription section (Cloud / On this Mac / Automatic, plus the
  engine picker and any model error); `AppState` composes primary and fallback
  from the mode and only requires the AssemblyAI key in Cloud mode.
- ADR-0005 written; SPEC non-goal 4 rewritten, R13/R14 amended, R20–R22 added,
  Architecture STT section rewritten.

**Deviations from the shaped cycle**

1. **Key Terms under Parakeet.** The cycle said Parakeet has "no keyword
   biasing". That was wrong: FluidAudio ships a custom-vocabulary rescorer
   (`CustomVocabularyContext`, CTC keyword spotting, BK-tree matching). It is
   still not wired — biasing that fires too eagerly rewrites correct words, so
   it needs measurement first — but the exclusion is now "not wired yet"
   rather than "impossible". Recorded in ADR-0005.
2. **Diarizer models load per Job instead of being cached.**
   `OfflineDiarizerManager` is non-Sendable, so holding one on an actor and
   awaiting its work is not expressible in Swift 6. Building it per call keeps
   it in one isolation domain and releases several hundred MB when a Job ends,
   which on 8GB is the better trade anyway.
3. **`SpeakerDiarizing` protocol added** beyond the shaped approach, so the
   alignment path is testable without loading CoreML. The cycle's confidence
   rests on those tests; they could not exist otherwise.

**Checks**

1. *Local end-to-end.* Partially met. `localAdapterLabelsTheMicTrackMeAndNeverDiarizesIt`,
   `localAdapterSeparatesRemoteVoicesAndPassesTheAssertedCountThrough`,
   `localAdapterFallsBackToOneBlockWithoutTimings`, and four `SpeakerAligner`
   tests prove the pipeline shape and the attribution rule exactly, without a
   model. `noVoiceprintSurvivesACompletedLocalJob` runs a full Job through the
   queue with a local Provider and lands a Note hands-off. **The comparison
   against the AssemblyAI reference in `test-audio/` has not been run** — it
   needs the real models downloaded and a real Session, which is owner-run
   work, exactly as the R-checks have always been.
2. *Fallback and disclosure.* Pass.
   `autoFallsBackToTheCloudAndTheNoteNamesTheProviderThatRan` (both Tracks
   re-run on the fallback, `provider: assemblyai` in frontmatter, event
   emitted), `localModeNeverReachesTheCloudWhenItFails` (cloud Provider never
   called, Job parks `.failed`, Recording kept per R7),
   `localDeliveryAddsNoTranscriptionCost` (an hour-long local Session bills the
   summary only).
3. *Regression and safety.* Pass. All 63 pre-existing tests green with the
   cloud path unchanged — same FLAC transcode, same request bodies, R6 intact
   (`localAdapterReadsOriginalsAndCostsNothingToRun` asserts the cloud
   Adapter's `prefersCompressedUpload`/`isLocal` explicitly).
   `noVoiceprintSurvivesACompletedLocalJob` scans everything the Job persisted
   for embedding or speaker-database data and finds none, with a structural
   size assertion on `SpeakerSpan` as the canary if a field is ever added.

**Review** (self, against contracts): one weak test found and fixed during
delivery — `parakeetTokensRebuildIntoWords` originally re-implemented the
grouping rule in the test file, so it asserted a copy rather than the shipped
code. `TokenTiming` has a public initializer, so it now calls the real
`ParakeetEngine.words(from:)`. No blocking findings remain.

**Two defects found by running it, both fixed**

1. **The deferral rule was never implemented.** The cycle specified that local
   inference must not run while a Session is recording, and ADR-0005's whole
   argument that the 8GB constraint does not apply rests on it — but nothing
   enforced it. Measured peak is ~300MB against R4's 100MB in-call budget, so
   a Job running during a call would have blown the budget threefold. Now
   `JobQueue.setRecordingActive`, held from Start and released at Stop or
   Discard, with cloud Jobs deliberately unaffected. Two tests.
2. **`AppleSpeechEngine` crashed with SIGTRAP on every run.** It paired
   `SpeechAnalyzer(inputAudioFile:finishAfterFile: true)`, which consumes the
   file itself, with an explicit `analyzeSequence` and finalize — finishing the
   analyzer twice. Now the plain `modules:` initializer with `setContext` for
   Key Terms. This is exactly what writing against an API from documentation
   rather than running it produces, and only a real run caught it.

**Remaining before this cycle can be called verified**

- **Owner decision on the default engine.** Parakeet was chosen before there
  were numbers. On this fixture Apple is materially better at the thing
  PROJECT.md's current theme is about (70.5% vs 61.4% purity), needs no
  download, and is the only engine that takes Key Terms — at the cost of 0.7pp
  WER and being 1.5x slower. One fixture is not a mandate, but it is the only
  evidence there is.
- **Attribution quality against the cloud.** 61–71% turn purity is a real
  regression from the cloud path on a project whose theme is attribution.
  Auto prefers local by owner decision; that decision should be revisited
  against these numbers.
- A second and third fixture before either of the above is treated as settled.
- No Job has yet run the local path end-to-end to a Note in the real Vault
  through the installed app; the pipeline is proven by `--local-check` and by
  queue tests with stubs.
- The README still says "Not for you if your machine has headroom for
  on-device transcription. Run one." Deliberately excluded from this cycle,
  but it is now false in a way a reader would notice.

## Learning and next move

<!-- iterate -->
