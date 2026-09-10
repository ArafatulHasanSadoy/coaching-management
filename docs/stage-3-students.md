# Stage 3 — students, admission, search and import

Gate: **300 students imported from a real register in under five minutes.**

## Where the five minutes actually goes

Not in the machine. Measured on the host, 300 rows parse in **7 ms** and commit
in **17 ms**, and a phone lookup across them returns in under a millisecond. The
whole budget is therefore available for the only part that needs a human:
checking that each column landed on the right field.

So the import screen spends its space on the mapping, not on progress bars.

**Auto-mapping does the first pass.** Each `ImportField` carries the header
spellings real registers use, in English and Bangla — `Mobile No`, `Father's
Name`, `মোবাইল`, `শিক্ষার্থীর নাম`, `জন্ম তারিখ`. Matching runs exact-first, then
substring, so a file with both `Phone` and `Guardian Phone` assigns each to the
right field rather than to whichever was checked first. Every guess is shown and
correctable in one tap.

**Nothing is written until the owner says so.** `preview()` parses, maps and
validates without touching the database; `commit()` writes.

## Decisions

**A bad phone number never loses a student.** Registers hold landlines, "ask
mother", and blanks. An unusable number produces a warning — imported as
written, with a note that search will not find it — rather than a rejection. The
only blocking condition is a missing name, because a student without one cannot
be a record.

**Duplicates are surfaced, not prevented.** Siblings legitimately share a
guardian's number, so a unique constraint would be wrong more often than right.
The importer flags "same guardian number as line 41 — siblings, or a repeated
row" and admission shows the matching students and asks. The desk decides.

**A centre's own IDs are kept.** If the register has an ID column, those values
are used. A number printed on an ID card or written in a ledger must not change
because the data moved into an app. Rows without one get the centre's configured
pattern (`AEC-{YY}-{#####}`).

**Codes are computed once per import, not per row.** Re-reading every existing
code to work out the next one is O(n²) and would turn the gate into a coffee
break. The starting sequence is read once and handed out in order, and the write
is two batched inserts inside one transaction.

**One audit row per import, not 300.** Three hundred near-identical entries would
bury everything else in the trail. The row records source file, count, batch and
the ID range.

**Phone numbers are stored twice** — as written, and normalised to digits.
`guardianPhoneNorm` is indexed, so a prefix search uses the index; normalising
inside the query could not. `Phone.normalize` handles `+88`, `0088`, dashes,
spaces, and the missing leading zero a spreadsheet leaves when it treats the
number as an integer.

**Day-first dates.** `03/04/2010` in a Bangladeshi register means 3 April far
more often than 4 March. Unambiguous values (`25/12`) are used to detect a
month-first file; unreadable ones warn and leave the field blank.

## Verified on device

Realme RMX3612, Android 14, upgrading the existing v2 database to v3.

A deliberately messy 120-row register was imported: Bangla headers, phone numbers
in five different shapes, two rows with no name, two landlines, two siblings
sharing a number, and one unreadable Bangla date.

| Check | Result |
|---|---|
| v2 → v3 migration on the live encrypted database | Clean |
| Bangla headers auto-mapped | নাম, পিতার নাম, মোবাইল, জন্ম তারিখ all correct |
| Summary | 120 rows found · 118 importable · 2 cannot · 4 worth a look |
| Blocked rows | Lines 18 and 64 — "No name — this row cannot become a student." |
| Landlines | Lines 26 and 89 — warned, imported as written |
| Siblings | Line 42 — "Same guardian number as line 41 — siblings, or a repeated row." |
| Unreadable date | Line 56 — "Could not read \"জানা নেই\" as a date of birth — left blank." |
| Import | 118 students, IDs 1 to 120, 2 skipped — the register's own SL numbering kept |
| Phone search, exact | `01700005754` → Tasnim Islam (row 42) |
| Phone search, shared number | `01712345678` → both siblings |
| Phone search, `+88` source | `01700001233` → found, though written `+8801700001233` |

Every planted problem was caught, each message naming the line number so the
owner can find it in their own spreadsheet.

The on-device import completed within a single screen transition. Its duration
was **not** isolated — the wall-clock measurement around it included several
multi-second `uiautomator` calls — so the 7 ms / 17 ms figures above are the
host measurements, not device ones.

## Verification

`test/csv_import_test.dart` (15 tests) and `test/phone_and_code_test.dart`
(7 tests). 35 tests across the project, all passing.

Notable cases: header aliases in both scripts, a UTF-8 BOM from Excel,
`Phone` vs `Guardian Phone` disambiguation, a bad phone not losing a student,
re-importing a register the app already holds, day-first date parsing, existing
IDs preserved, one audit row per import, and the 300-row timing gate.

## Carried into Stage 4

- **Students can be admitted and viewed but not edited.** No edit form, no batch
  transfer, no status change (drop-out, re-admission).
- **No student photos.** The schema holds `photoPath`; nothing writes it.
- **No enquiry register.** Lead → follow-up → admission is unbuilt; admission
  assumes the decision is already made.
- **No sibling linking.** Duplicate detection notices shared numbers but does not
  record the relationship, so a family discount cannot be expressed yet.
- **Import is CSV only.** A centre keeping `.xlsx` must export first. The
  `excel` package is not yet wired in.
- **Search has no filters.** Batch, class and status filters are not built, and
  the list shows active students only.
