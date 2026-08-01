# Braid

Braid is a personal macOS menu-bar app that records calls locally, has the cloud transcribe and diarize them, and writes summarised markdown notes into an Obsidian vault.

## Language

**Session**:
One Start→Stop recording span, pauses included. The core unit: one Session produces one Recording, one Transcript, one Note.
_Avoid_: Meeting, call (as the unit of work — a Session may be a lecture or interview)

**Recording**:
The two-Track audio artifact of a Session, stored crash-safe on disk and deleted only after its Note is confirmed written.
_Avoid_: Audio file, capture

**Track**:
One audio channel of a Recording. The **Mic Track** is always the user ("Me"); the **Remote Track** is everyone else via system audio.
_Avoid_: Channel, stream

**Transcript**:
The provider-independent, speaker-labelled, timestamped text merged from both Tracks. Persisted alongside the Note.
_Avoid_: Transcription (the act), STT output (provider-specific)

**Provider**:
A cloud speech-to-text service performing transcription and diarization on a Recording.
_Avoid_: Model, engine, API (alone)

**Adapter**:
The per-Provider code that submits a Recording and converts that Provider's output into a Transcript.
_Avoid_: Integration, connector

**Summariser**:
The separate Claude API call that turns a Transcript into a Note using a Preset.
_Avoid_: Summarizer (spelling), LLM step

**Preset**:
A stored summary prompt template. V1 ships four: Meeting, Lecture, Interview, Training.
_Avoid_: Prompt (alone), template

**Key Terms**:
The persistent user-maintained jargon list sent to the Provider to bias transcription.
_Avoid_: Custom vocabulary, word boost, keyterms (provider-specific names)

**Participants**:
Optional per-Session list of names entered at Start; used by the Summariser as naming hints only, never sent to the Provider as identities.
_Avoid_: Attendees, roster

**Note**:
The markdown file written into the Vault. The deliverable of a Session.
_Avoid_: Summary (the content, not the file), output

**Vault**:
The user-configured folder inside the Obsidian vault where Notes are written.
_Avoid_: Output folder, destination

**Job**:
The post-Stop pipeline run for one Session: upload → transcribe → summarise → write Transcript and Note → delete Recording. Queued, resumable, and retryable.
_Avoid_: Task, process
