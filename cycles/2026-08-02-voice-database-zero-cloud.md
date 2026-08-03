# Private voices, zero cloud
status: building
started: 2026-08-02
spec: [SPEC.md](../SPEC.md) R5, R6, R10–R14, R18, R20–R30

## Outcome

The owner's recurring colleagues stop arriving as "Speaker 1". A voice named once
is recognised on return and named before the note is read — and nothing Braid
hears, or derives from what it hears, has ever left the Mac.

## Why now

Two decisions that arrived together and only make sense together. Storing
voiceprints is defensible precisely because this is a private, single-owner app;
that premise is only honest if it is structural, and an app that uploads audio to
one service and transcript text to another is not that app. So the cloud goes
([ADR-0006](../docs/adr/0006-zero-cloud.md)) and the Voice Database arrives
([ADR-0007](../docs/adr/0007-the-voice-database.md), superseding ADR-0003).

## Slice

Everything on-device, plus identification end to end: match a Speaker against
known Persons, auto-name only when certain, offer a chip when not, cut a Voice
Clip to name it by ear, learn from the confirmation, and correct the diarizer
with what is known.

Excluded deliberately: true clusterer seeding (known voices fed *into* the
clustering rather than correcting its output) — it needs upstream support in
FluidAudio's VBx path, and forking a pinned pre-1.0 dependency is the cost
ADR-0005 was careful to avoid.

## Result

**Zero-cloud.** AssemblyAI and Claude are gone, with them both API keys, the cost
table, spend tracking, the monthly cap, the FLAC transcode, the network failure
branch and the Auto-fallback machinery. Setup is now one decision: where the
Vault is. `STTProvider`/`Adapter` left the vocabulary; the interchangeable local
implementations are Engines behind `TrackTranscribing`.

**The Summariser is Apple's on-device foundation model**, with guided generation
and map-reduce for transcripts beyond its context window.

**The Voice Database** is one ChaChaPoly-encrypted file whose key lives in the
Keychain marked this-device-only, holding Persons with a capped set of
Voiceprints. Naming is the only write path. The naming records got the same
encryption, since they hold transcript text and candidate voiceprints.

**Identification** matches per-voice centroids by cosine similarity against every
exemplar, auto-naming only when exactly one Person clears the bar. Re-attribution
uses FluidAudio's per-chunk embeddings to move speech the database says the
clustering misfiled. Voice Clips are cut from each unnamed Speaker's longest
overlap-free turn and deleted when Identification resolves.

**Delivery** is one Settings toggle. Held waits indefinitely and never waits when
it recognised everyone.

Measured end to end on the real 4-minute call fixture: two voices separated,
note and transcript written, frontmatter correct. 89 tests green.

### Found by running it

Four defects the tests and a real end-to-end run caught, all fixed:

1. **`@Generable` is unavailable under this toolchain.** Its compiler plugin
   ships with Xcode; ADR-0004 builds with Command Line Tools. Schemas are built
   by hand with `DynamicGenerationSchema` — the same guided generation, and a
   better fit anyway since user-editable Presets mean the Note's shape has to be
   built at runtime. Recorded as an amendment on ADR-0004, because the general
   lesson ("does its plugin ship with CLT?") will come up again.
2. **A Remote Track with no speech parked the whole Job**, losing the owner's own
   side of the call. FluidAudio raises `noSpeechDetected`; that is a fact about
   the recording, not a pipeline failure, and it is R16's territory. Now returns
   an empty diarization and the Note is written from what was captured.
3. **Clip extraction trapped** when a diarizer span ran past the end of the
   audio: an unchecked `AVAudioFrameCount` conversion on a negative value. Every
   bound is now clamped against the file.
4. **R24's correction path was unreachable.** The code to unlearn the Voiceprint
   behind a wrong auto-name existed, but the naming view listed only voices with
   generic labels, so an auto-named voice could never be corrected — and the
   record filed its candidate under the pre-rename label anyway, so the lookup
   would have missed. Both fixed: everything is keyed by the label the Transcript
   ends up with, and recognised voices appear in the naming view with their name
   filled in and a "recognised" tag. This is the one mistake the app can make
   confidently, so it needed somewhere to be undone.

### Found by the owner's first real session

5. **The on-device model refused an ordinary podcast conversation.** Apple's
   default guardrails treat the transcript as if Braid had prompted for it, and
   declined a whole session over a passing remark about a babysitter. Fixed by
   using `permissiveContentTransformations`, which Apple provides for apps that
   *transform* content the user already has — exactly this case. Verified: the
   same content now summarises. A refusal is also no longer fatal — it returns a
   Note that says plainly why it has no summary and links the transcript, and in
   a long meeting one refused slice no longer sinks the other fifty. Losing an
   entire recorded meeting to a safety filter is the wrong failure.
6. **The first person you ever name taught Braid nothing.** Voice data was only
   collected from the Remote Track when the database already had someone in it —
   an optimisation that made the feature unable to bootstrap, since the centroid
   is needed for *enrolling*, not just matching. The owner's first session named
   "Russell" and stored zero voiceprints. Now always collected; the cost is a
   megabyte or two per audio-hour, discarded with the Job.
7. **The Keychain prompted for a password on every rebuild.** The key's ACL named
   the binary that created it, so each new build was a stranger. The item is now
   written with a permissive ACL and existing keys are rewritten in place, same
   bytes, so nothing already encrypted is lost. Recorded on ADR-0007 with the
   reasoning: the prompt defended against a local process that could already read
   the Vault and the audio, while the property that actually matters — a copied
   file is useless — comes from the encryption, not the prompt. Verified by
   reading the store from the installed app, a different code identity, with no
   prompt. ADR-0007's original "restorable only onto this Mac" claim was an
   overstatement and has been corrected.

8. **The refusal was not a guardrail at all, and the first fix missed.** Finding
   5 assumed `guardrailViolation`; the owner kept seeing declines, and a
   diagnostic run showed `LanguageModelError.refusal` — the model's own training,
   not a configurable filter. A `--summary-check --probe` harness tried the same
   text five ways (preset instructions, neutral "you are a transcription tool"
   instructions, the content-tagging use case, the digest schema, and default
   guardrails): **all five refused**. Line by line, two passages were refused and
   four were accepted. So the fix is not a setting but a strategy — on a refusal,
   slice to roughly one speaking turn, keep every part the model will take, and
   say in the note how many parts are missing. The refused session now yields
   notes for two of its three parts instead of nothing. Recorded on ADR-0006 as
   the real, permanent cost of going on-device, with the honest conclusion: if
   this class of recording matters, the answer is a different summariser behind
   the same seam, not a setting.

Also corrected: the Presets still told the model to emit markdown and open with
an `# H1`, which contradicts a schema and which a 3B-class model handles badly.
They now name headings only. The first measured note repeated its summary twice
because both the schema and the Preset asked for one; the Preset's Summary
section is gone.

### The trade, stated plainly

AssemblyAI was the reference our 61–71% turn-purity numbers were measured
*against*. Removing it means accepting worse attribution today and betting that
the Voice Database plus Re-attribution close the gap as the app learns recurring
speakers. Opus-quality prose is likewise given up. The first real note was
genuinely good — specific, accurate, and it said "no specific dates or decisions
are mentioned" rather than inventing any — but that is one note.

## Checks

1. `./scripts/test.sh` — 89 tests, including the identification boundary rules
   (R23), enrollment and the cap (R24), Held delivery (R26), Re-attribution
   (R27), echo folding (R28), the user's controls (R29) and model-version
   staleness (R30). **Green.**
2. `--process-test` on the real call fixture delivers a Note with correct
   frontmatter; `--held` holds it and writes nothing. **Both pass.**
3. Wi-Fi off, one real Session end to end through the installed app. **Owner, not
   yet run.**

## Remaining

- ~~**Embed MLX as a second Summariser.**~~ Done 2026-08-02. Apple's is still the
  default; an open-weights model (Qwen3 4B, with Gemma 3 4B and Qwen2.5 3B
  selectable) runs beside it for the sessions Apple refuses. **Verified on the
  exact transcript Apple declined: summarised in full, accurately, with the
  Preset's headings.** Five things were learned building it:
  1. **Installing Xcode lowered the SDK.** Xcode 26.6 is the App Store's newest
     and ships the macOS 26.5 SDK, while Command Line Tools had 27.0 — so
     `LanguageModelError` vanished. Fixed by using `GenerationError`, which
     exists in both, and dropping the deployment target to macOS 26.0 (Braid
     uses nothing newer). On a macOS ahead of released Xcode, CLT is the more
     current toolchain.
  2. **`swift build` cannot compile Metal shaders**, which mlx-swift's README
     states plainly and which presents at runtime as "Failed to load the default
     metallib", not as a build error. `scripts/build-app.sh` now uses
     `xcodebuild` and copies the resource bundles into the `.app`. `swift test`
     still works untouched, because the test target does not depend on BraidMLX.
  3. **The MLX generation API had moved.** The single isolated function was the
     only thing that needed fixing, which is why it was isolated.
  4. **Structure has to be asked for, and asked for in the right place.** No
     constrained decoding here. Asking in the system turn was ignored three
     times running; moving the contract to the end of the user turn worked
     immediately, and repeating the Preset's headings beside it stopped the
     model inventing its own. Small models weight the most recent instruction
     far more heavily.
  5. **Its JSON is often malformed** — a `bullets` array closed with `}` on the
     first real run. `ModelReply` in BraidCore recovers it by pattern, and lives
     there rather than in BraidMLX precisely so `swift test` can cover it.
- **Calibrate the thresholds against real voices.** 0.72/0.55 are reasoned
  starting points, not measured ones. `--local-check` now reports what each voice
  would decide and how much room the auto threshold has above the worst
  different-voice similarity in the same recording; that number needs looking at
  on two or three real calls before the defaults are trusted.
- ~~**Measure `zeroVoteReembed`.**~~ Done 2026-08-02, and it produced a better
  result than the thing being measured. `zeroVoteReembed` itself was rejected:
  68.2% purity against 70.5%, and it invented a third voice where the reference
  has two. But sweeping the segmentation settings alongside it found that
  ADR-0005's earlier rejection of a finer floor was stale — it had been measured
  under Parakeet, and under Apple the same settings take purity from **70.5% to
  77.3% at no time cost**. Defaults changed to minTurn 0.4 / step 0.1, ADR-0005
  amended, harness defaults tracked to match so an unflagged run measures what
  ships. Attribution was the app's weakest measured dimension and this is the
  largest single gain it has had.
- **Summary quality on a long meeting.** The map-reduce path has not been run on
  anything near an hour; R11's check (a note referencing both the first and last
  ten minutes) is unwritten.
- **The mid-Job recording gap.** Deferral only stops Jobs from *starting*; a Job
  already running when you hit record keeps going, putting ~330MB and saturated
  CPU inside a call. Suspending between pipeline stages is the fix.
- Screenshots in the README are from the cloud build and show a cost line.
- The repo is still on GitHub; taking it private is the owner's action.
