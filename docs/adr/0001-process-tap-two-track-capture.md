# Capture via Core Audio process taps into a two-Track aggregate device

Most macOS apps (including Humla, the closest open-source relative) capture system audio with ScreenCaptureKit, which demands the Screen Recording permission, shows the purple indicator, forces an app restart on grant, and re-prompts monthly on macOS 15+. We instead use Core Audio process taps (macOS 14.4+) combined with the physical mic in a single aggregate device with drift compensation enabled (`kAudioSubTapDriftCompensationKey: true`), which needs only the audio-only "System Audio Recording" permission and shares one clock across an hour-long call. We record the mic and the tap as two separate Tracks rather than a mix: this doubles STT billing (providers charge per channel) but gives exact, free "Me vs. them" separation, so diarization only ever has to split the Remote Track — the single biggest accuracy win available to this pipeline.

## Consequences

- The app must never link ScreenCaptureKit; adding it would silently reintroduce the Screen Recording permission.
- STT cost is ~2 billed hours per real hour (~43 billed hrs/month at the user's volume) — deliberate, not a bug.
- macOS has no public API to query the System Audio Recording permission state; a denied grant records silence. The app must detect silent Remote Tracks and warn, rather than assume permission health.
