# Feedback round 1 — what changes

From the owner-side review. Grouped by area, in the order I intend to build them.

## A. Admission
1. **The admission form is built by the admin first.** Fields are defined, then
   that becomes the form used for every admission. A sensible demo form ships so
   nobody starts from blank.
2. **Monthly fee is per student and mandatory** at admission — not inherited
   silently from the batch.

## B. Students
3. **List students class-wise**, not one flat list.
4. **Add a class from the student tab**, without going to settings.
5. **Payment history per student** — already built; needs to be obvious.

## C. Batches
6. ~~Suggest a batch name, but let it be edited.~~ **Withdrawn** — the Batches
   screen already takes a freely-typed name; the owner had not seen it yet.

## D. Teachers and staff
7. **Separate tabs** — teachers and other staff are not the same list.
8. **Show every class a teacher takes**, and let that be edited by hand.
9. **Batch-wise subject assignment**, also hand-editable.
10. **A teacher can be paid per class *and* hourly** — not one or the other.
    Confirmed: routine classes pay per class, extra sittings pay by the hour,
    so a class session now records which kind it was.
11. **Teacher name is tappable** → phone, classes, payments to date, everything
    in one place.

17. **Teacher attendance counts** — how many classes taken and how many hours,
    both shown, per teacher for a period.

## E. Finance
12. **Expense head "Other" needs a free-text box** to say what it actually was.

## F. Questions
13. **Photograph a question and convert it to text** (OCR), attach photos, then
    correct the text by hand.

## G. Routine — rework
14. **Two views, batch-wise by default.** Revised in conversation: *"creating
    routine option will be batch wise"* and *"routine will be batch wise and it
    should be copyable and pastable to another batch"*. So **Build by batch**
    is the default — one batch's own week, which is the unit a period actually
    belongs to — and **Whole class** merges a class's batches onto one sheet
    for the notice board, each cell marked with its batch. Printing follows
    whichever view is open.
15. **Guided**: ask how many classes, subjects and teachers, and collect what it
    needs rather than expecting the data to already be there.
16. **Fill what it can automatically, leave the rest blank** for the owner —
    e.g. a teacher with a clash leaves an empty cell rather than failing.
18. **Copy a week from one batch to another.** Not a blind clone: subjects are
    matched by name across classes, and where the target batch has already
    named a teacher for a subject that teacher is used instead of the source's
    — the "internal connection". Anything that would clash is left blank, and
    the result says exactly what was left out and why.
19. **Subjects are per batch, added by hand.** Two batches of one class need not
    study the same list, so a subject can be added to a single batch (existing
    or newly typed) and removed from it without touching the others.

## H. Print centre
Owner will review later. No changes for now.

---

## Status — all items built

| # | Item | Where it lives |
|---|---|---|
| 1 | Admin-built admission form | `lib/data/students/admission_form_service.dart`, `features/students/admission_form_builder.dart` |
| 2 | Mandatory per-student monthly fee | `Students.monthlyFee`, admission form built-in field |
| 3 | Students class-wise | `features/students/students_screen.dart` |
| 4 | Add a class from the student tab | same, `_addClass()` |
| 5 | Payment history per student | `features/students/student_actions.dart` |
| 6 | *Withdrawn by the owner* | — |
| 7 | Teachers and staff on separate tabs | `features/staff/staff_screen.dart` |
| 8 | Every class a teacher takes, hand-editable | `StaffClasses`, `staff_repository.dart` |
| 9 | Batch-wise subjects, hand-editable | `SubjectPlanScreen` — add and remove per batch |
| 10 | Paid per class *and* hourly | `data/finance/payroll_service.dart` |
| 11 | Tappable teacher → phone, classes, pay | `features/staff/teacher_profile_screen.dart` |
| 12 | Expense head "Other" free-text | `Expenses.customHead` |
| 13 | Photograph a question → OCR → edit | `data/questions/ocr_service.dart` (ML Kit), `features/questions/scan_questions_screen.dart` |
| 14 | Routine: build by batch, view whole class | `features/routine/routine_screen.dart` |
| 15 | Guided routine setup | `features/routine/routine_setup_screen.dart` |
| 16 | Fills what it can, leaves the rest blank | `data/routine/routine_solver.dart` + the grid's blank cells |
| 17 | Teacher attendance, class-wise and hourly | `features/staff/staff_attendance_screen.dart` |
| 18 | Copy a batch's week to another batch | `data/routine/routine_copy.dart` |
| 19 | Subjects per batch | `SubjectPlanScreen` |

**Colour by section** — every screen now takes its colour from
`lib/core/sections.dart`: Students blue, Money green, Teachers purple,
Attendance orange, Routine teal, Questions indigo, Print brown, Inventory cyan,
Reports deep purple, Setup slate.

**OCR** uses Google's ML Kit (`google_mlkit_text_recognition`), not a
hand-rolled recogniser. ML Kit has no Bangla model, so the scanner detects
Bengali characters in the result and says plainly that the text will need
correcting rather than pretending otherwise.

### Known, not fixed
- **A5 receipts still print at A4.** The bridge asks for A5 but Android treats
  `PrintAttributes` as a suggestion the printer may override. Needs a real
  printer at the pilot centre to settle.
