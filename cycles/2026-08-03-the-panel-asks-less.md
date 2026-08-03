# The panel asks less

status: building
started: 2026-08-03
spec: [SPEC.md](../SPEC.md) R9, R9a, R12, Design

## Outcome

Starting a recording is one click on a panel that asks one question. The Note
names itself from what was actually said, rather than from what the owner
expected before the call.

## Why now

Auto voice detection has been working for a few real sessions, and that changed
what the Start form is for. It used to ask four things; three of them are now
either knowable without asking or better answered afterwards. The Preset is a
standing preference. The title is a guess made before the meeting, when the
summary makes a better one after it. Participants are mostly repeats, so the
right control is a list of voices Braid already knows rather than a free-text
field to spell them into.

## Slice

Take everything out of the Start form that Braid can work out for itself, put
the panel on a diet, and file Settings in drawers.

## Result

**The Note titles itself (R9a).** A Session starts as the time of day —
"2:15pm recording" — and both Summarisers now return a title alongside the body,
which becomes the Session's title and therefore both filenames. Apple's gets a
`title` field in its generation schema; MLX is asked for one in the JSON
contract and `ModelReply` reads it out, including out of JSON too broken to
decode. `Session.cleanTitle` vets what comes back, and rejects rather than
risks: too long, too short, empty, or a whole first sentence, and the
placeholder stands.

Two rules make this safe rather than merely convenient. A title is applied only
while a Session still carries the automatic one, so a Note already filed under a
name is never renamed by a later re-summarising pass — which matters because
naming a speaker re-runs the Summariser on a Note the owner may already have
linked from elsewhere. And the Summariser is no longer told the title at all:
it used to be, and every model given one echoed it straight back as the first
line of the summary.

**The panel is 228 points wide**, down from 380. Three layouts had to be rebuilt
to survive it rather than merely shrink: the recording controls stack (side by
side, "Stop & save" came out on three lines), pending rows put their actions
underneath (beside a title, "Process" rendered one letter per line), and the
participant chips wrap through a real `Layout` rather than a grid.

**The Start form is the panel.** No Record-then-Start reveal; opening the panel
shows who is on the call and one Start recording button.

**Participants are chips.** One per Person in the Voice Database, plus a field
for anyone new. A typed name that matches a known voice folds into its chip
instead of being added twice, and whatever is half-typed when Start is pressed
still counts.

**The Preset moved to Settings** (R12 amended). All four still ship and are still
editable; one is chosen once and shapes every Note.

**Settings is one visible setting and five drawers.** Vault stays in the open;
Notes, Voices, Models and Recording collapse. Every explanatory paragraph is
gone — one short line where a control genuinely trades something off, a tooltip
where the detail still matters, and nothing at all where the label says it. The
month's minutes moved to History.

## Checks

1. `./scripts/test.sh` — 100 tests, including the six new ones behind R9a.
   **Green.**
2. `--summary-check` on a pricing conversation: Apple's model returned
   "Q3 pricing discussion" and kept it out of the body. **Pass.**
3. `--ui-preview --snapshot` at 228 points across every route. **Pass**, after
   fixing the three layouts named above — all three were found this way rather
   than by reasoning about them.
4. The same text through MLX from the built bundle: "Q3 Pricing Discussion",
   read out of the JSON and kept out of the body. **Pass.** Both engines title
   a session, which was the open question — Apple's is constrained by a schema
   field, MLX only asked in words.
5. One real Session end to end through the installed app. **Owner, not yet run.**

## Remaining

- The README screenshots are regenerated and current again, at the new width and
  with no cost line. They come out of `--ui-preview --snapshot`, so keeping them
  honest costs one command.
- Carried from the last cycle, untouched by this one: threshold calibration
  against more real voices, summary quality on a long meeting, the mid-Job
  recording gap, and taking the repo private.
