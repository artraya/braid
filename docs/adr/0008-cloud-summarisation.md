# Cloud summarisation: the Note is written by Gemini, everything else stays here

Supersedes the summarisation half of [ADR-0006](0006-zero-cloud.md). Transcription, diarization and identification remain entirely on-device; ADR-0006 stands for all of them.

ADR-0006 removed both cloud touchpoints and moved summarisation to Apple's on-device foundation model, with an MLX-hosted open model beside it for the sessions Apple refuses. Two months of daily use measured what that actually costs on the machine this project is shaped around — an M3 MacBook Air with 8GB — and the numbers are not marginal. On a real 86-minute call (68,778 characters of Transcript):

| | Wall clock | Effect on the machine | What the Note contained |
|---|---|---|---|
| MLX, Qwen3 4B | **49 minutes** | swap grew 5.1GB → 11.2GB; machine unusable | one paragraph, two bullets, one topic |
| Apple on-device | **23 minutes** | none (5–10MB resident) | the whole meeting, sloppy tail |
| Gemini 3.5 Flash-Lite | **5.4 seconds** | none | the whole meeting, clean |

The 49 minutes had three compounding causes, all now fixed or moot: the MLX path reloaded 2.1GB of weights on every generate call, its map-reduce digest passes never suppressed Qwen3's thinking so thousands of reasoning tokens were generated and then discarded, and an 8GB machine cannot hold a 4B model's weights plus a 20,000-token KV cache without paging. But the deeper problem was structural and applied to Apple's path too: **both local models have to cut the Transcript into pieces small enough to fit, and a summary-of-summaries loses the meeting.** That is a quality defect, not just a speed one, and no amount of tuning removes it while the context window is the binding constraint.

Flash-Lite carries a 1M-token context. An hour and a half of conversation is about 28,000 tokens. So the Transcript goes in one pass, whole, and the map-reduce machinery is not used at all. That is the actual argument for this decision: **one pass beats a summary of summaries**, and speed is the side effect.

## What leaves the machine, precisely

Transcript text, and nothing else. Specifically **not**: audio, ever; any speaker embedding, centroid or Voiceprint; any Voice Clip; the Voice Database in any form. [ADR-0003](0003-no-voiceprints-ever.md) and [ADR-0007](0007-the-voice-database.md) are untouched — identification happens before the network is reached, and the structures it works in never reach the request.

ADR-0006 argued that storing Voiceprints is defensible "precisely because this is a private, single-owner app where nothing derived from a voice ever leaves the machine, and that premise is only honest if it is structural." That sentence is now too strong, and pretending otherwise would be the dishonest move. The narrower claim that survives, and that this ADR commits to structurally, is: **nothing that identifies a voice leaves the machine.** A Transcript says what was said; it carries no biometric. The Voice Database remains the thing that never travels, and R21 still holds in full.

The consent posture changes with it and the SPEC now says so: "local-only processing" is no longer one of the two mitigations. What the owner tells people they are recording has to match what the app does.

## Held Delivery becomes the default, and that is what makes it one call

The pipeline already held a Session when Identification left anything unnamed, and delivered immediately when the Voice Database had recognised everyone. That behaviour existed but was not the default. It is now, because with a cloud summariser it is worth considerably more: a Held Session reaches Gemini with real names in the Transcript and gets prose written around them, instead of prose about "Speaker 1" that is patched afterwards.

Combined with naming-by-substitution (below), the guarantee is **exactly one cloud call per Session, ever** — including when a name is corrected weeks later.

## Consequences

- **`SummaryEngine` gains `.cloud`**, alongside Apple's and the open model. Both local Engines stay: they are the answer with no network, and Apple's remains the fallback for a machine with no key. The seam ADR-0006 insisted on is what made this an addition rather than a rewrite, exactly as intended.
- **No `ModelReply` salvage on this path.** Gemini enforces the output shape server-side with a response schema, so the reply is valid JSON by construction rather than something to be recovered from a code fence or a `<think>` block. `ModelReply` still renders it, so every Engine produces identical markdown.
- **Naming no longer re-summarises.** Correcting a speaker relabels the Transcript and substitutes the label in the existing Note body, which is instant and costs nothing. It also now reads the body from disk, so edits made in Obsidian since delivery survive the rename — something the re-summarising path could never do. `resummarise` remains only for a Note that has been moved away.
- **Voice Clips are cut for auto-named voices too, and outlive naming** (R25 amended). A name the user was asked about is one they chose; a name Braid applied on its own confidence is the only kind that reaches the Vault unchecked. Clips are a few hundred KB per Session and now age out with the naming record at 30 days, which is the window in which Re-naming can reach them.
- **Re-naming from History.** Any Session whose naming record is still alive can be reopened and its voices corrected, with the clip to listen back to. Correcting an auto-name still removes the Voiceprint that caused it (R24).
- **Cost metering returns (R14), honestly.** Tokens are counted exactly, from the API's own `usageMetadata`. Dollars are shown only once a rate is configured; the app ships with the rate unset and displays tokens rather than an invented figure.
- **The key is a sealed file, not a Keychain item.** Both Keychain routes are closed: the legacy file-based Keychain scopes an item to the exact binary that wrote it, so the first read after a rebuild blocks forever on a prompt that a CLI invocation cannot display; the data-protection Keychain needs a `keychain-access-groups` entitlement, which a self-signed app with no team identifier cannot have (`SecItemAdd` returns -34018). `SecretBox` already solved this for the Voice Database, so the key rides along with it.
- **Network posture.** The app now performs network I/O for one purpose beyond fetching model assets: summarising. Nothing else. The Done gate's Wi-Fi-off journey still passes with a local Engine selected, and that is how it should be run.
- **Reversal is a setting, not a revert.** Selecting Apple's or the open model turns the network off again with no code change. That is the point of keeping all three.

## What this does not settle

Attribution quality is still the open bet PROJECT.md describes. Auto-naming confidence is unproven — the Voice Database is young, `autoThreshold` is deliberately conservative at 0.72 with exactly-one-clears required, and 8 seconds of speech is the floor for learning anything. Re-naming from History exists because that bet has not been won yet, not because it has.
