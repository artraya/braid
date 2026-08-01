# Minimal panel, zero-touch naming
status: verified
created: 2026-08-01
updated: 2026-08-01
release: production

## Outcome

The owner's first click on the menu bar shows only what needs attention now —
record, anything processing or failed, anything to name — and a one-on-one
call with the participant named at Start delivers a fully named Note with zero
post-delivery action.

## Prompt

Owner feedback on v0.3.0, same day it shipped: the main panel is busy (usage
card + history list before the Record button); history and usage should live
one click deeper. A single named participant should not need the Apply step at
all — assign it during processing. And selecting a speaker count should mean
exactly that count by default, with Auto owning the late-joiner-tolerant case.

## Evidence and assumptions

- Fact: naming after delivery costs a second Claude call (SpeakerNamer);
  relabelling *before* the Summariser runs costs nothing extra.
- Fact: the 1:1 Apply notification shipped in v0.3.0 triggers only when one
  voice is heard and one Participant is listed — exactly the case auto-assign
  now handles earlier — so it becomes unreachable and is removed.
- Fact: R6a currently says "Nothing is auto-assigned from Participants";
  R18 says the panel lists recent Sessions and shows monthly usage. Both are
  amended, dated, by this cycle with the owner's explicit decision (2026-08-01).
- Assumption: one declared participant + one heard voice is reliable enough
  that a wrong auto-name (a stand-in taking the call) is rare and acceptable —
  fixable in Obsidian, and the risk was explicitly accepted by the owner.
- Unknown: whether hiding history/usage one click deep changes how often the
  owner actually checks spend (watch during use; cap warnings still notify).

## This cycle

1. Main panel first click: title bar, Record button, and only attention items
   (active recording block, processing/failed/cancelled jobs, speakers to
   name). Session history moves behind a History affordance (its own route in
   the same panel); the usage card moves into Settings.
2. Auto-assign: when a Session has exactly one Participant and diarization
   heard exactly one Remote voice, the pipeline relabels that voice to the
   Participant before summarising. The Note arrives already named, no
   notification action, no second Claude call. NamingRecord is stored with
   namesApplied set, so nothing prompts. Any other combination behaves as
   today (naming sheet, prefill). The v0.3.0 Apply notification button is
   removed; clicking a speakers notification still opens the naming view.
3. The "exactly" toggle defaults to on when a count is selected: picking N
   sends min=max=N unless unticked (then min only). Auto unchanged, still the
   default, still sends nothing.
4. SPEC: amend R6a (single-participant auto-assign, dated), R18 (history and
   usage one click deep within the one window), Journey step 7 wording.

## Not this cycle

- Echo bleed work (companion cycle, same date).
- Auto-assign for any case other than exactly 1:1 — never guess among voices.
- Removing the naming flow, merge affordance, or mismatch warnings (all stay).
- Any change to what history records (R18 data), only where it is shown.

## Approach

UI is route work in the existing panel: a `history` route case, list moved
there, usage card moved to the settings view, main view trimmed. Auto-assign
is a small pre-summary step in `JobQueue.execute` using the existing
`renamingSpeakers`, plus `namesApplied: true` on the stored record; the
mismatch computation already distinguishes the cases. Toggle default is one
model change plus footer copy. SPEC edits ride along, as in the last cycle.

## Risks and routes

- Auto-assigned wrong person (stand-in) — accepted by owner; bounded to the
  1:1 case; name also sits in frontmatter participants; fixable in Obsidian.
- Strict-by-default increases silent late-joiner merges — owner's explicit
  choice; the footer states the cost; Auto remains the default control state.
- Hiding usage could hide runaway spend — cap warning notifications (R18)
  still fire regardless of panel layout.

## Checks

- [ ] Fixture Jobs: 1 Participant + 1 voice heard → Note and transcript carry
      the name, no speakers-to-name prompt, exactly one summarise call;
      1 Participant + 3 voices heard → generic labels, naming flow as today.
- [ ] `requestBody`/model: count selected defaults to min+max=N; untick sends
      min only; Auto sends no speaker fields (amended-R6 regression stands).
- [ ] `--ui-preview` snapshots: main panel shows no usage card or history
      list and offers History; the history route lists sessions; settings
      shows the usage card.

## Result

Delivered 2026-08-01. All three checks pass; 57 tests green, build clean,
geometry check PANEL-GEOMETRY-OK across all five panel views including the new
history route.

**What changed**

- Main panel first click is header (Braid, history + settings icons), attention
  items only (recording block, processing/failed/cancelled, speakers to name,
  setup hint), and Record. `HistoryRoute` (new) lists delivered Sessions;
  `UsageCard` moved into Settings above the form. Right-click menu gained
  History.
- Auto-assign in `JobQueue.execute`: exactly one Participant + exactly one
  heard voice relabels pre-summary via the existing `renamingSpeakers`; the
  NamingRecord stores `namesApplied: true`; no `speakersDetected` event fires,
  so nothing prompts. Every other combination unchanged.
- Removed the superseded v0.3.0 1:1 machinery: notification Apply action and
  category, `onApplyName`, `applyOneToOneCandidate`, `oneToOneCandidate`,
  naming-sheet prefill. Clicking a speakers notification still opens naming.
- `selectSpeakerCount` on the panel model: picking a count sets strict; footer
  copy owns the late-joiner cost and points at untick/Auto.
- SPEC: R6a and R18 amended (dated, linked here); Journey step 7 updated.

**Checks**

1. `autoAssignNamesTheSingleVoiceBeforeSummarising` — one summarise call, its
   transcript already says "Priya", the delivered transcript file carries the
   name with no generic label, record stored named, no prompt event.
   `autoAssignNeverGuessesAmongVoices` — 1 Participant + 3 voices keeps
   generic labels, record unnamed, naming flow prompted. Both pass.
2. Amended-R6 requestBody tests unchanged and green (min/max mapping, Auto
   sends nothing); strict-by-default exercised through the real
   `selectSpeakerCount` path in the `panel-start-form-count` snapshot.
3. Snapshots: `panel` (minimal main), `panel-history`, `panel-settings` (usage
   card on top), all rendered and inspected; 13 snapshots written.

**Review** (self, against contracts): no blocking or material findings. The
mismatch warning still computes for auto-assigned Sessions and is logged and
stored, but with the prompt suppressed it surfaces only in the naming sheet if
opened later — acceptable within "nothing prompts", noted here. Advisory:
README screenshots now two cycles stale.

**Limitations within contract**: an auto-assigned wrong name (stand-in) is
fixable in Obsidian; the naming record remains for correction but no UI path
reopens it — Obsidian is the editor, per the one-window posture.

## Learning and next move

<!-- iterate -->
