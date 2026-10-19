# P1 report: temporal understanding

**Status: completed at the software level; device check pending.** The software gate passes. It was tested with a
scripted (valid) Qwen extraction and with the model unavailable. Real Qwen output and phone behaviour were not
measured; they stay with P5.

Baseline: `c1d1ada` plus the accepted P0 working-tree changes. No commits, stashes, resets, installs or phone access
were made. The corpus is unchanged, and the held-out file was not read.

## Scope

- A new shared resolver, `lib/assistant/temporal.dart`.
- `rule_engine.dart`, `session.dart` and one line in `follow_through.dart` (`leadOverride`).
- Parser tests and end-to-end session regression tests.

`semantic.dart` and the prompts or grammar did not need to change. The model still copies the user's own time words
into `when`, and the app now resolves those words, and the whole message, through the same resolver. Because the
prompts are unchanged, `promptFingerprint` (`plan-v1:8fe00ad5e6c8`) is unchanged.

## What changed

**One resolver.** `Temporal.read(text, now)` returns a `TemporalReading`. It contains:
- a status: none, resolved, conflict or unsupported
- `at`
- a role: event start, alert, deadline, event end or recurrence
- the typed spans, each with its original words, relation (offset, within, before, by, lasting, every or calendar)
  and amount
- `rest`, the title text
- a disclosure `note`
- `lead` (for example "5 min before")
- `length` and `end` (for example "for half an hour")

The calendar parser moved out of `RuleEngine` into this module unchanged, with the same defaults and notes.
`RuleEngine._parse`, `parseWhen`, `resolveWhen`, `findWhen`, `parseDaily`, `parseDuration` and therefore
`leadOverride` and `eventDetails` all delegate to it. There is still only one date parser; `_inRe` and its
word-number table are gone.

**Durations.** The resolver now accepts:
- the relations in, within, after, "in the next", "from now", "later" and "'s time", plus fillers such as
  about/around
- units min, mins, m, h, hr, hrs and days
- word numbers, including twenty-five and "a couple of"
- half an hour, a quarter of an hour, "an hour and a half", "one and a half hours", 1.5 h, 1h30, and
  "1 hour (and) 30 minutes"

It refuses:
- compounds whose units don't shrink ("10 minutes, 5 minutes before" stays an offset plus a lead)
- vague amounts ("a few minutes")
- intervals ("every 2 hours", which are unsupported; nothing is saved)

The time is removed from the title wherever it appears, so word order does not matter. `_req` also moves leading
"after 10 min …" phrases.

**Roles.**
- "within N" is the event being that close. It is resolved to submission + N, and the reply discloses that
  reading: `I read "within 10 mins" as 10 minutes from now.`
- "within N" is a **deadline** when the text has a deadline cue (finish, submit, done …) or a window cue
  (sometime, anytime). There is no global within→in replacement.
- A deadline for something unnamed ("Finish this within 10 minutes") writes nothing and asks what it is.
- A named deadline task is due then and is never turned into an alarm. If the user asked for a reminder, the reply
  says the time is the deadline.
- "before 5pm" is a deadline. In a reminder request the app asks when to remind and keeps the title.
- "5 minutes before" is a lead time.
- "for half an hour" with a start is the event's end. It is saved with `setEventDetails`, so it does not trigger
  the optional question.
- "by 5pm" keeps its existing behaviour.

**Conflicts.** The cases are:
- two offsets
- an offset plus a clock time or another day
- a part of day versus a clock time
- two clock times

Each one is a conflict, never resolved by taking the first match. A day offset plus a clock is one time ("in 2 days
at 5pm"). For a request, the session keeps the title in the pending draft and asks:
`"in 10 minutes" and "at 9" disagree, so I saved nothing yet. When should I remind you about "meeting"?`
The original regression expectations still hold: the reply contains "disagree", and `maybeClarify` stays null. The
draft comes from the new `conflictDraft`.

**Model and fallback share the path.** `_create` reads the whole message with the same resolver.
- A conflict anywhere asks, whatever `when` the model copied.
- The app's own reading of the message wins over the model's `when` words.
- An unreadable model `when` no longer forces a question if the message itself resolves.

**Clock captured once per turn.** `handle()` stores `_turnNow`. The session's resolver, prompts and checks all use
it until the turn ends, including after asynchronous inference. Between turns the live clock applies.

**Concise questions.** `ClarifyDraft.prompt` no longer appends the full supported-date list. Clarify codes are
additive: `temporal_conflict`, `deadline_target`, `deadline_not_alert` and `tentative`.

**New request forms.**
- Trailing "…, remind me", which needs a time.
- "set an alarm/reminder/timer (for) …".
- Tentative wording (maybe, might, perhaps, if …) never writes.

## Evidence

| Check | Result |
|---|---|
| RED before implementation: `flutter test test/screenshot_within_test.dart` | Both tests fail. With the model unavailable, the app asks `When should I remind you about "meeting within 10 mins"? I understand today…`. With Qwen it says `I couldn't read "within 10 mins" as a time…`. (`P1-red.txt`) |
| GREEN: screenshot, `temporal_test.dart` and `temporal_session_test.dart` | **52/52 pass** (`P1-green.txt`) |
| New session tests against an exported `c1d1ada` copy (outside this checkout) | 25 of 42 fail (`P1-red-session-baseline.txt`). The 17 that pass there are safety cases the baseline already handled: negation, tentative, recurrence, plain "in ten minutes", 2 hrs and restart. They were written after the module, so this is the RED evidence for them. |
| `flutter analyze` | No issues (`P1-analyze.txt`) |
| Full `flutter test` | **329 pass, 2 fail** (`P1-tests-full.txt`). The 2 failures are exactly P0's baseline defects, which also reproduce on `c1d1ada`. In `proactive_session_test` "questions, negations…", the same 3 model prompts are made; P2 owns it. In `assistant_home_test`, the ambiguous `ListTile` finder fails; P4 owns it. P0's 4 failures are now 2: both screenshot tests are fixed. |
| `python3 -I eval/validate.py --summary` | OK; corpus unchanged |

The end-to-end tests run through `AssistantSession` over real SQLite repositories with preferences. Each one runs
twice, once with a valid scripted Qwen plan and once with the model unavailable. They assert stored reminders,
tasks and pending drafts, not just wording. Fixed time: Monday 19 Oct 2026, 07:41.

| Case | Result in both modes |
|---|---|
| The exact screenshot request | One reminder at 07:51 titled "meeting" (no within/10/min/i have/can u). The reply contains 7:51 AM and the disclosure, is under 240 characters, and has no help list and no "when should". The optional details question comes after the confirmation. |
| "in ten minutes", "after 10 min" (time first), "10 mins later", "in 2 hrs", "an hour and a half", "half an hour from now" (set an alarm) | Correct time, clean title |
| "Meeting in 10 minutes, remind me 5 minutes before" | Event at 07:51, alerts exactly {pre 07:46, reminder 07:51}. The saved lead policy is untouched. |
| "I have a meeting in 10 minutes for half an hour" | Start 07:51, end 08:21 |
| Dentist at 4 this afternoon, then "no idea yet" | Saved at 16:00 and never blocked by the optional details |
| "Finish this within 10 minutes" | No writes. With Qwen: "What needs to be done within 10 minutes?" |
| "I need to submit the report within 2 hours", with multiple alerts on | Task due 09:41 and no reminder rows |
| "remind me to submit the report before 5pm" | No write; asks and mentions the deadline. "at 4pm" then creates it at 16:00 with the title kept. |
| "Maybe I should meet him within an hour" | No writes |
| "Don't remind me about the meeting", with a reminder already saved | The reminder set is unchanged |
| "remind me about the meeting in 10 minutes at 9" | No write. The reply quotes both times and says "disagree"; clarify code `temporal_conflict`. "in 10 minutes" then gives one reminder at 07:51. |
| "Meeting in 10 minutes at 9" | No writes. With Qwen the app asks about the conflict. |
| "remind me every 2 hours to drink water" | No writes |
| Question then "cancel" | Draft cleared, no writes, no help list |
| Restart: the answer comes 2 minutes later in a new session | 07:53, based on the answer's own submission time |
| Slow model: the clock advances 3 minutes during inference | Reminder still at 07:51 (Qwen mode only) |
| `cancel()` during inference | Returns '', writes nothing, cancels the engine once. The next turn works. (Qwen mode only) |

## Deviations and decisions

- When the whole-message reading resolves, it takes precedence over the model's `when`. If the message has time
  words for something else ("…at 5pm about the 3pm meeting"), the app now asks rather than trusting the model's
  pick. This is safer, but it can ask more often; P5 should measure it.
- Deadlines are stored as task `due_at`. `Task.deadlineAt` only exists for daily schedules, and no schema change
  was made.
- `leadOverride` now keeps a trailing "remind me", so the rules recognise "X at T, remind me N before" as a
  reminder.
- `parseDuration` rejects durations under 1 minute; it previously accepted "0 minutes".

## Unresolved risks and items deferred to later stages

- **N-006 ("Don't remind me about the meeting" with two reminders).** P1 guarantees no write. Asking which
  reminder to cancel belongs to the **P2** unified cancel/validation routing.
- **A-005 "sometime within the next hour I need to call the courier".** It resolves as a deadline (08:41), but the
  rules capture pattern does not start with "sometime", so the rules path replies without writing. That is allowed
  by the case's expectations. Broader request recognition is **P2**.
- **Plain statements without a create cue ("Meeting in 10 minutes at 9") on the rules path** get the generic "not
  sure" reply, not a conflict question. They make no write. **P2/P4.**
- **S-025 and similar unsupported dates** still get the long `supportedWhen` reply from `RuleEngine.plan`. The
  clarification prompt no longer includes it. Reply policy is **P4**.
- The resolver works in local wall-clock `DateTime`. Device timezone and DST changes mid-turn are untested.
- None of this is real-model accuracy. The scripted plans show only that valid extractions are handled. **P5** must
  run actual 0.6B/1.7B output and the phone screenshot scenario.

## Contract handoff to P2

- Use `Temporal.read` / `RuleEngine.readWhen` for every time. Do not add a parser. Use the reading's `role`,
  `anchor.relation`, `lead`, `end` and `conflict` instead of re-deriving them.
- Pass the turn's submission time explicitly. The session's `_turnNow` is the TurnInput's captured time.
- Clarify codes are additive, and the existing `route` and `fallback` codes are unchanged.
- The two baseline failures remain the responsibility of P2 (proactive question/no-model-call) and P4 (sidebar
  finder).
- Device checks still pending: the screenshot request on the phone, real Qwen `when` extraction for the P1 forms,
  and the timing of alerts that are actually delivered.


---

# Attempt 2 (repair after the rejected attempt 1)

**Status: completed at the software level; device check pending.** This repair covers only the P1 temporal gate
failures listed in `P1-parent-review-attempt1.md`. The attempt 1 text above is kept for reference. Where attempt 2
differs, attempt 2 wins.

## Root causes and fixes

| Probe | Cause | Fix |
|---|---|---|
| model: "in 2 weeks at 5pm" saved at 17:00 today | Weeks are not a unit, so only "at 5pm" was read | `Temporal.read` returns **unsupported** for the whole message when it sees in/within/after/every N weeks, fortnights, months, years or seconds, or "N … from now/later/time" |
| model: "every 2 hours at 5pm" became a one-off | `_create` used the model's `when` because `whole.at` was null, and it ignored `whole.unsupported` | `_create` now checks for unsupported before the model's `when`. Repeats other than daily (every week/Monday/morning…, weekly, hourly…) are also unsupported. "daily"/"every day" still go to `parseDaily` |
| model: "in 10 minutes on 30 February" saved at +10 min | `dateIn` returned null for impossible dates, so the calendar found "nothing" and the offset won | The internal `_dateIn` now tells invalid dates apart from conflicting ones. An impossible or ambiguous date, or an impossible clock time (13pm, 25:00), makes the whole reading **unsupported**. The public `dateIn` contract (null) is unchanged for `parseDaily` |
| both paths: "in 1 hour and 2 hours" used the first amount (and the rules polluted the title) | When two same-rank pieces could not be combined, the resolver took the first piece and lost the rest | Every piece is read. When the compound has an in/within/after prefix or a from-now suffix, both pieces are offsets, so the result is a **conflict** that quotes both. Without that, each piece is classified in its own context |
| model: "tomorrow Friday at 5pm" chose tomorrow | Days that disagree came back as null, the same as "no date" | Disagreeing days are a calendar **conflict** naming both words |
| (source gap) "half an hour before" was ignored by execution | `leadOverride` used its own `_leadRe` regex | The duplicate `_leadRe` is gone. `leadOverride(text, now)` takes the lead span from `Temporal.read`, and the session passes the turn's captured `_now()`. The 1–1440 minute bounds and the "remind" cue are unchanged |
| Leftover unconsumed words after a partial read (for example "at 5pm next week") | No check on the resolved `rest` in the model path | `_create` asks `unsupported_date` when `RuleEngine.hasUnsupportedDate(whole.rest)` still matches. The rules path already did this through the title |

Files changed in attempt 2: `lib/assistant/temporal.dart`, `lib/assistant/session.dart`,
`lib/assistant/follow_through.dart`, `test/temporal_session_test.dart` and `test/temporal_test.dart`.
`test/temporal_parent_regression_test.dart` is unchanged.

## Evidence (attempt 2)

| Check | Result |
|---|---|
| RED before the fix: `flutter test test/temporal_session_test.dart test/temporal_parent_regression_test.dart` | **17 failures** (`P1-attempt2-red.txt`). All 6 parent regressions fail. The new "half an hour before" lead test fails in both modes. The new no-partial cases fail as follows: every week and weekly in both modes; "in 10 minutes and 20 minutes" in both modes; with the model only, "at 5pm next week" and "today Friday at 5pm". |
| GREEN after the fix: temporal_session, parent regression, temporal_test and screenshot_within | **79/79 pass** (`P1-attempt2-green.txt`) |
| New parser test "whole-message problems outrank any valid part" | Pass. It was written after the fix, so its RED is only the session-level RED above |
| `flutter analyze` | No issues (`P1-attempt2-analyze.txt`) |
| Full `flutter test` | **356 pass, 2 fail** (`P1-attempt2-tests-full.txt`). The 2 failures are the same baseline defects that reproduce on `c1d1ada`: `proactive_session_test` makes 3 model prompts, and `assistant_home_test` finds 2 `ListTile` widgets. Neither is a temporal failure, and neither is caused by this stage. |
| `python3 -I eval/validate.py --summary` | OK |

The new end-to-end cases run in both modes (scripted valid Qwen plan, and model unavailable). They assert SQLite
state directly:
- "remind me about the meeting in 2 hours half an hour before" gives one reminder at 09:41 titled "the meeting",
  with alerts exactly {pre 09:11, reminder 09:41}. The saved lead policy stays [30, 10].
- These 7 requests write nothing: in a week, in 30 seconds, every week at 5pm, weekly at 5pm, at 5pm next week,
  in 10 and 20 minutes, today Friday at 5pm.

All attempt 1 expectations are kept and pass: the screenshot request, word order, fillers, after 10 min, start versus
"5 minutes before", deadlines, tentative wording, negation, conflicts, cancel, restart, slow model and cancel during
inference.

## Remaining risks

- The whole-message unsupported check is deliberately conservative. A title that contains a unit phrase ("remind
  me about the in 2 weeks project at 5pm") is asked about, not saved. P5 should measure how often this happens.
- Leftover-word detection on the model path reuses `RuleEngine.hasUnsupportedDate`, which is broad. A title that
  contains a month or weekday name after a resolved time (for example "… at 5pm about the March budget") now gets a
  question. That is safe, but it may ask more often.
- Same limits as attempt 1: local wall-clock time only, with DST and timezone changes untested. There is no real
  Qwen accuracy evidence.

## Handoff

The P1 contract is unchanged except for these additions:
- `TemporalStatus.unsupported` also covers unsupported units, non-daily repeats, impossible dates and impossible
  clock times.
- Disagreeing named days are a `conflict`.
- `leadOverride(text, now)` is the only lead interpretation, and it uses the shared reading.

Device checks remain pending for P5: the screenshot request on the phone, real Qwen `when` extraction, and the
timing of delivered alerts.
