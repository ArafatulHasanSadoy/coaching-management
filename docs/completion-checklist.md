# Completion checklist

Everything carried forward from stages 1–8, plus stages 9–11. Ticked only when
built **and** covered by a test or verified on device.

## Stage 12 — print centre
- [x] Upload fixed forms (PDF/image) and print them unchanged
- [x] Recurring schedule with due detection (the 15-day diary page)
- [x] Print history
- [x] Student ID cards, mail-merged and laid out to a page

## Stages 9–11
- [x] 9. Routine schema, conflict engine, manual builder
- [x] 9. "What can go here?" slot query
- [x] 10. Smart generation with explained partial results
- [x] 11. Question bank
- [x] 11. Paper composer + marks validation
- [x] 11. Question paper PDF via the Document Engine

## Carried from Stage 1
- [x] Idle timeout becomes a setting
- [x] Release APK size measured (no claim made until then)
- [x] PBKDF2 unlock cost measured and tuned

## Carried from Stage 2
- [x] Subjects can be added and edited
- [x] Rooms and periods can be edited and archived
- [x] Session switching and year-end promotion
- [x] Centre profile settings screen

## Carried from Stage 3
- [x] Student edit, batch transfer, status change
- [x] Student photos
- [x] Enquiry register
- [x] Sibling linking
- [x] Search filters
- [x] `.xlsx` import

## Carried from Stages 4–8
- [x] Per-class teacher pay computed from the class-taken register
- [x] Payment history, reprint and cancellation from the UI
- [x] Month-end lock, and a readable message when a write hits one
- [x] Staff edit and deactivate; staff attendance screen
- [x] Expense list and void (Finance → Expenses this month) — added in
      Release 2; before that there was no expense list on any screen, only
      the Expenses report
- [x] Reports module

> **A note on this file.** Until Release 2 it claimed "payment history and
> cancellation from the UI" and "expense list and cancellation" while neither
> cancellation path had a call site anywhere in `lib/features/`. A checklist
> that overstates completion is how the next gap gets missed, so entries here
> now say what is reachable from a screen, not what exists in a service.

## Deliberately not doing now
- Automatic cloud backup — needs a backend; Phase 2 in the plan. Manual share
  exists and works.
- Streaming zip for backups — in-memory is fine at the scale a centre reaches.

---

## Status

**Everything above is built and covered by tests. 129 tests pass.**

Release APK, split per ABI: **arm64 22.9 MB**, armeabi-v7a 20.5 MB, x86_64
24.2 MB. (The earlier plan guessed 60–90 MB; that estimate was pessimistic.)

PBKDF2 unlock cost was measured at 413 ms per check on a development machine
with 120,000 iterations — roughly 1–2 seconds on a mid-range phone. It is now
50,000 (171 ms measured), and **the iteration count is stored inside the hash**
so it can be changed again without locking anyone out. A regression test proves
a PIN created under the old scheme still verifies.

### Not yet verified on device

Stages 9–11 are proven by tests but have **not** been exercised on the phone:
the handset's lockscreen would not dismiss through `adb`, and its screen timeout
is shorter than the verification round-trips. Everything through stage 8 was
verified on device in earlier sessions.

### Verified on device

Run against an **arm64 Android emulator (API 35)** using the *release* APK —
the same build the owner receives, not a debug one. That matters: R8
minification can break a release build where debug works. It does not here.

| Check | Result |
|---|---|
| Release build launches, no crash | Clean |
| First run → passphrase, PIN, four-step wizard | Completed |
| Auto-lock on background, PIN unlock | Works |
| Teachers, batches | Created |
| **Routine generation** | **"Fully scheduled — no clashes"**, Bangla subject names, rooms assigned |
| **Routine printed** | Full-week A4 grid with letterhead, Bangla in every cell |
| Print centre | Renders, ID cards offered, empty state teaches |
| Question bank | Renders with Bangla subject names |

### Two bugs found on device and fixed

Neither could have been caught by a test — both are widget-lifecycle faults.

**Setup appeared to do nothing.** `FirstRunScreen` is pushed as a route; on
success it invalidated the bootstrap provider, which changed what rendered
*underneath* it, but never popped itself. Setup worked perfectly and the user
was left staring at the form they had just completed. It now pops to the root.

**The question bank showed the wrong empty state.** `_subjectId ??= …` inside a
builder mutates state without scheduling a rebuild, so the surrounding widget
still saw null and said "add subjects to a class first" while a subject was
plainly selected in the dropdown above it. The subject list is now loaded into
state properly and the default is set in a post-frame callback.
