# Stage 12 — the print centre

The last piece of the original brief: *"there should be a thing where they can
upload those thing, the fixed thing as PDF. Whenever they need, they can
directly print from that"* — the diary page reprinted every fifteen days.

## Two kinds of printable thing

**Fixed files.** A PDF or image the centre already has and reprints unchanged:
the diary sheet, a blank attendance register, notice paper. Uploaded once,
tagged with when it is needed.

**Mail-merge layouts.** The app fills these from the database — student ID
cards, printed four to a page so a batch of forty does not cost forty sheets.

Both reach the printer through the same Document Engine, so they belong on one
screen.

## A WebView cannot render PDF

The print bridge built in Stage 0 renders HTML. An uploaded PDF has to take a
different route: `PdfFilePrintAdapter` in `MainActivity.kt` streams the existing
file straight to the print system without re-rendering it.

Worth noting for anyone reading that file: **subclassing** `PrintDocumentAdapter`
is fine. The restriction that bit during Stage 1 was on *constructing* its result
callbacks, which this only receives.

## Uploaded files are copied, not referenced

A template pointing at wherever the file picker found it breaks the moment the
owner tidies their downloads — and the backup would not contain it either. The
file is copied into the app's own media directory, which is inside the backup.

## When something is "due"

The scheduled day has arrived **and** it has not been printed since that day
began. So a reminder disappears once acted on, and printing early does not make
it nag again on the day.

The awkward cases are tested:

- **A day-30 schedule in February** falls back to the 28th rather than a date
  that does not exist.
- **Early in the month**, the last due date is looked for in the previous month
  rather than assumed to be this one.
- **Weeks start Saturday**, as a Bangladeshi week does.

## Verification

`test/print_centre_test.dart` — 11 tests, all passing. Covers the fortnightly
diary page from the brief (due on the 16th, quiet once printed, "was due 4 days
ago" when overdue), the February edge case, weekly cadence, on-demand templates
never nagging, files surviving the original being deleted, and ID card layout.
