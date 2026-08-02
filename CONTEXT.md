# Braid

Braid is a personal macOS menu-bar app that records calls, transcribes and identifies who spoke, and writes summarised markdown notes into an Obsidian vault, entirely on this Mac. Nothing it hears or derives from what it hears ever leaves the machine.

## Language

**Session**:
One Start→Stop recording span, pauses included. The core unit: one Session produces one Recording, one Transcript, one Note.
_Avoid_: Meeting, call (as the unit of work — a Session may be a lecture or interview)

**Recording**:
The two-Track audio artifact of a Session, stored crash-safe on disk and deleted only after both its Note and its Transcript are confirmed written.
_Avoid_: Audio file, capture

**Track**:
One audio channel of a Recording. The **Mic Track** is always the user ("Me"); the **Remote Track** is everyone else via system audio.
_Avoid_: Channel, stream

**Transcript**:
The speaker-labelled, timestamped text merged from both Tracks. Persisted alongside the Note.
_Avoid_: Transcription (the act), STT output (engine-specific)

**Engine**:
One of the interchangeable on-device transcription implementations: Apple SpeechTranscriber or Parakeet.
_Avoid_: Provider, Adapter (retired cloud-era terms), model, API (alone)

**Summariser**:
The on-device summarisation step that turns a Transcript into a Note using a Preset.
_Avoid_: Summarizer (spelling), LLM step

**Preset**:
A stored summary prompt template. V1 ships four: Meeting, Lecture, Interview, Training.
_Avoid_: Prompt (alone), template

**Key Terms**:
The persistent user-maintained jargon list that biases an Engine's transcription.
_Avoid_: Custom vocabulary, word boost, contextual strings (engine-specific names)

**Participants**:
Optional per-Session list of names entered at Start; naming hints for the Summariser and suggestions during Identification, never identities.
_Avoid_: Attendees, roster

**Note**:
The markdown file written into the Vault. The deliverable of a Session.
_Avoid_: Summary (the content, not the file), output

**Vault**:
The user-configured folder inside the Obsidian vault where Notes are written.
_Avoid_: Output folder, destination

**Job**:
The post-Stop pipeline run for one Session: transcribe → identify → summarise → write Transcript and Note → delete Recording. Queued, resumable, and retryable.
_Avoid_: Task, process

**NamingRecord**:
The per-Session record kept after delivery — the structured Transcript, the facts the frontmatter was built from, and a hash of the Note as written — that lets Speakers be named or renamed after the Recording is gone. Purged 30 days after delivery.
_Avoid_: Naming state, pending sheet

**Speaker**:
One distinct voice heard in a Session's Remote Track, labelled by order of first appearance ("Speaker 1") until identified. Exists only within its Session.
_Avoid_: Voice (as the per-Session unit), cluster

**Person**:
A durable, named voice identity in the Voice Database, created the first time a Speaker is named.
_Avoid_: Contact, profile

**Voiceprint**:
One stored embedding exemplar of a Person's voice, recording when it was heard and for how long. A Person holds a small capped set of Voiceprints.
_Avoid_: Embedding (the raw in-Job vector, which never persists), template

**Voice Database**:
The encrypted local store of Persons and their Voiceprints.
_Avoid_: Speaker database (a FluidAudio result field), enrollment store

**Identification**:
Resolving a Speaker to a Person: automatic when a match is confident, otherwise done by the user in the naming flow.
_Avoid_: Recognition, matching (alone)

**Enrollment**:
The addition of a confirmed Voiceprint to a Person as a byproduct of Identification. Never a separate ceremony: naming is teaching.
_Avoid_: Training, registration

**Voice Clip**:
A short excerpt of a Speaker kept only until its Session's Identification resolves, so the user can hear who they are naming.
_Avoid_: Sample, snippet

**Re-attribution**:
The correction pass after diarization that moves a stretch of speech to the Person whose Voiceprint confidently contradicts the diarizer's assignment.
_Avoid_: Seeded clustering (the input-side technique this version does not do)

**Delivery**:
When a Session's Note is written. **Immediate**: as soon as processing completes, generic Speaker labels allowed. **Held**: only after Identification resolves. A single Settings toggle; Held Sessions with nothing to ask never wait.
_Avoid_: Auto/Accuracy (retired mode names)
