# Cloud does both transcription and diarization; no local ML

status: historical — superseded by [ADR-0005](0005-local-transcription-as-a-provider.md) and [ADR-0006](0006-zero-cloud.md) (2026-08-02); the no-local-ML rule and the cloud pipeline it protected are both gone.

The Provider performs transcription and diarization in one call, returning speaker labels already attached to words. Local diarization (FluidAudio — pyannote Community-1 on the Neural Engine, ~21MB, native Swift) was seriously evaluated and parked, not rejected: it would require word-level alignment of an unlabelled transcript against independently produced diarization segments — a genuinely error-prone reconciliation, and distinct from the trivial two-list interleave the spec's split-file design needs (two already-labelled utterance lists sorted on a shared clock). It also adds a model dependency and measures worse (17% diarization error rate, DER) than the paid cloud pipelines. The hard constraint is an 8GB M3 MacBook Air already strained by Teams: v1 runs no local ML of any kind. Embedding pyannote.audio/PyTorch directly is rejected outright on that constraint.

## Consequences

- If a live transcript is ever built (v2+), FluidAudio's LS-EEND streaming model is the cheapest route back to local diarization — this ADR covers v1's batch path, not that future.
- Diarization quality is unverifiable in advance (no provider publishes independent DER); if AssemblyAI disappoints on real calls, the remedy is a second Adapter (ElevenLabs), not local ML.
