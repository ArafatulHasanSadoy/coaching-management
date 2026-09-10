# Stage 2 — setup wizard and master data

Gate: **a stranger completes setup unaided.**

## How the gate is actually met

Not by writing a better empty-state. The wizard ships the Bangladeshi national
curriculum pre-filled — fifteen class/stream combinations, each with its
subjects and sensible weekly class counts — and asks the owner to tick what they
teach (`lib/data/defaults/curriculum_defaults.dart`).

Selecting "Class 9 — Science" creates eight subjects with Bangla or English
names and per-subject weekly class counts the routine engine will later treat as
hard requirements. The alternative — an empty table and forty rows to type — is
where a product like this loses people in the first ten minutes.

Four steps, each answerable without training, every default chosen so that
tapping straight through still produces a working centre:

1. **Centre** — name, address, phone. Only the name is required.
2. **Session** — pre-filled with the current year and 1 Jan – 31 Dec.
3. **What do you teach?** — tick classes, with a Bangla/English toggle for
   subject names.
4. **Finish** — review, plus optional example rooms and typical class times.

The script toggle exists because subject names are *data*, not interface: they
print on question papers and report cards, so a Bangla-medium centre needs
পদার্থবিজ্ঞান and an English-medium one needs Physics. Guessing wrong would mean
renaming every subject by hand.

## Two ways in, not one

First launch offers **Set up a new centre** or **Restore from a backup**. An
owner whose phone just died should not have to walk through creating a centre
before discovering they can restore one. This also closes the restore-UI gap
carried from Stage 1: `RestoreScreen` picks a file, inspects it, shows what the
archive contains and every problem found, and only then offers to restore.

## Decisions

**Money is whole Taka, not paisa.** Bangladeshi coaching fees are always whole
amounts and paisa has not circulated in decades, so minor units would add a ×100
conversion at every call site to represent something nobody uses. If that proves
wrong, the migration is a single multiply.

**Classes are free text, not a 6–12 enum.** Centres run "SSC 2027",
"HSC Science", "Admission — Engineering" alongside school grades. A product that
cannot express what is on their own whiteboard gets abandoned.

**Time slots are minutes from midnight, never hardcoded hours.** Every centre
sets its own, weekday and Friday differ, and the routine engine needs to compare
and detect overlap without parsing text.

**Every mutation goes through `MasterDataRepository`**, because each one must
also write an audit row. Scattering `db.into(...)` across screens is how audit
trails end up with holes.

**Archive, never delete.** A batch that vanished would take its history with it —
the students who sat in it, the fees they paid. `archiveBatch` soft-deletes and
records the reason; the confirmation dialog says so plainly.

## Schema v2

Adds `classes`, `subjects`, `rooms`, `time_slots`, `batches` — all carrying the
Stage 1 conventions — with a real `onUpgrade` migration, since the device already
held a v1 database. `PRAGMA foreign_keys = ON` is set in `beforeOpen`; SQLite
leaves them off by default, and without it a batch could reference a deleted
class and nothing would complain until a report tried to render it.

Two row classes needed explicit `@DataClassName`: drift's auto-singularisation
produced `Classe` and `Batche`, and `Batch` collides with drift's own type, so
they are `SchoolClass` and `StudentBatch`.

## Backup gets its off-device half

Stage 1 wrote verified backups to app storage and stopped there — which, on a
single-phone design, protects against almost nothing. `BackupScreen` now says so
in as many words and offers **Send a copy off this phone** via the system share
sheet, so a backup can reach Drive, Telegram or a computer. Every backup is
verified immediately after being written: a backup that was never checked is a
belief, not a backup.

## Verification

`test/setup_service_test.dart` — six tests:

- a wizard selection produces a usable centre, with subjects attached to the
  class they were created under rather than to whichever was written last
- subject names follow the chosen script
- optional defaults can be declined
- setup writes an audit row
- `isComplete` flips only once a centre exists
- **a failure part-way leaves nothing behind** — the whole apply is one
  transaction, because a setup that half-succeeded would leave classes with no
  session, or subjects pointing at a class that was never written: states no
  screen is built to handle and the owner could only escape by wiping data

## Verified on device

Realme RMX3612, Android 14, running against the **existing v1 database from
Stage 1** — so this also exercised the migration rather than a fresh install.

| Check | Result |
|---|---|
| v1 → v2 migration on a live encrypted database | Ran clean; app opened normally |
| Routed to the wizard, not the dashboard | `setupComplete` false with no institution row |
| Session step pre-filled | 2026, 01/01/2026 – 31/12/2026, no typing |
| Class selection with running total | 2 classes · 15 subjects (7 + 8) |
| Centre created | Home shows 2 classes, 2 rooms, 5 periods |
| Subjects in Bangla with weekly counts | বাংলা, ইংরেজি, গণিত, বিজ্ঞান, আইসিটি, সমাজবিজ্ঞান, ধর্ম |
| Short-name chips | বাং, ইং, গণিত, বিজ্ঞান, আইসিটি, সমাজ, ধর্ম |
| Batch creation | "Science A · Capacity 30 · ৳2500/month", list updated live |

Two details worth noting from the run: the Bengali subject names and the ৳
prefix render correctly throughout the interface (not only in printed output),
and the drift stream refreshed the batch list the instant the row was written,
with no manual reload.

## Carried into Stage 3

- **Subjects can be viewed but not yet edited or added** from the Classes tab.
  The wizard creates them; per-class editing is a screen that does not exist yet.
- **Rooms and periods can be added but not edited or archived.** Same shape of
  gap — `MasterDataRepository` has `archiveBatch` but no equivalent for the rest.
- **No session switching or year-end promotion.** One active session works;
  creating 2027 and promoting batches into it is the rollover wizard, still to
  come.
- **The wizard cannot be re-run or corrected** beyond editing individual rows
  afterwards. A "centre profile" settings screen is needed.
- Backup still has no automatic off-device copy — sharing is manual, one tap
  after each backup. Automatic Drive upload remains the first post-launch item.
