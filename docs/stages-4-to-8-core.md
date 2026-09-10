# Stages 4–8 — the commercial core

Staff and roles, fees and receipts, finance and ledger, attendance, inventory.
Built as one batch because they interlock: payments need accounts, salary needs
staff, attendance drives per-class pay.

Schema v4 adds nineteen tables in a single ordered migration.

---

## Stage 4 — roles

**Gate: a staff PIN cannot see profit.**

The distinction that matters is not "admin versus user". It is that the
receptionist collecting fees is trusted with the cash box and is *not* trusted
with the profit figures or with what each teacher earns. On a shared counter
phone that has to be enforced rather than assumed.

`Permissions.allows` in `lib/core/permissions.dart` is the single decision
point. Staff get `collectFees`, `manageStudents`, `takeAttendance`,
`manageInventory`. They are denied `viewFinanceSummary`, `viewStaffSalaries`,
`manageExpenses`, `manageStaff`, `manageMasterData`, `manageBackup`.

The home screen is **assembled** from granted capabilities rather than filtered
after the fact — a receptionist does not get a greyed-out Finance tile telling
them what they are missing.

Who unlocked is tracked, not just that someone did: `LockController.unlockAs`
records the user so the role is available everywhere, and locking clears it.

## Stage 5 — fees and receipts

**Gate: the full payment workflow, including restart and restore.**

Three rules hold throughout `FeeService`, because a fee system that cannot be
audited is worse than a paper receipt book:

- **Receipt numbers are gapless.** Allocated inside the same transaction as the
  payment, never reused. A cancelled receipt keeps its number and is marked
  cancelled — a *missing* number is the first thing an auditor asks about.
- **Payments are immutable.** Cancelling writes a compensating ledger entry and
  flags the row. Nothing is deleted or edited.
- **Invoice totals are recomputed from live payments**, never incremented, so a
  cancellation cannot leave a stale figure behind.

Monthly billing is idempotent per period — running it twice cannot double-charge
a centre's students.

**Collection is built for the moment it happens in**: a guardian is standing
there, often on the phone. Search is phone-first, the outstanding amount is
shown without asking, the amount field arrives pre-filled with what is owed, and
the wallet defaults to match the payment method.

### The Document Engine

This is where Stage 0 pays off. `DocumentEngine` is the single place that turns
content into a printable document — receipts now, question papers and routines
later. Every printed thing comes through it, which is what keeps branding,
margins and typography consistent and means the Bengali shaping problem was
solved once rather than five times.

Receipts show **previous due, paid now, and remaining due together**, because
guardians read that line first and a receipt that omits it starts an argument at
the counter. Amounts are grouped South Asian style (`1,25,000`, not `125,000`)
and spelled out in the lakh/crore system. A reprint carries a `DUPLICATE` stamp
so it cannot pass as the original.

## Stage 6 — finance

**Gate: balances reconcile after a void.**

The ledger is **append-only**. Nothing is edited or deleted; a mistake is
corrected by writing a compensating entry that points back at the original
through `reversesId`. That makes a balance the plain sum of its entries —
provable rather than believed — and keeps the fact that a correction happened
visible instead of erasing it.

Wallets are Cash / bKash / Nagad / Bank, matching how a Bangladeshi centre
actually holds money. Day closing stores the *difference* it found rather than
deriving it, so a later correction elsewhere cannot rewrite what was counted on
the night.

## Stage 7 — attendance

**Gate: forty students in under thirty seconds.**

Sessions open with **everyone already marked present**; the teacher touches only
the exceptions. One tap cycles present → absent → late → excused, which keeps
the row narrow enough for a name and puts the two states that matter one tap
apart. The whole class saves as a single batched write.

Re-saving replaces rather than merges: a class is thirty to fifty rows, and a
diff can leave a student silently unmarked. Late counts as attended for
percentage purposes. `consecutivelyAbsent` produces the call list — a student
drifting away is visible weeks before they formally drop out.

## Stage 8 — inventory

Every movement carries a reason, so the quantity on screen can always be
explained. `currentQuantity` is a cache; `quantityFromHistory` recomputes from
the movements and the tests assert the two agree. Issue and damage remove stock
whatever sign is passed, so a mistyped minus cannot add stock.

---

## Verification

`test/finance_test.dart` — 26 tests, all passing. Highlights:

- **Stage 4 gate**: staff can collect fees and take attendance; cannot see
  finance summary, salaries, expenses or backups.
- **Gapless receipts**: five payments produce `R-00001`–`R-00005`; cancelling
  the third means the next is `R-00006`, not a reused number.
- **Stage 6 gate**: two payments and an expense reconcile; cancelling one
  payment leaves the balance correct, adds a reversal beside the original rather
  than editing it, and the payment row survives with its amount unchanged.
- **Cancelling twice does not double-reverse.**
- **Stage 7 gate**: forty students saved in one batched write, well inside a
  second.
- **Inventory**: the running total matches the movements that produced it.
- **The full workflow end to end**: searchable → billed → paid → due updated →
  ledger updated → receipt allocated → appears in the day's report → **backed up
  → restored elsewhere with the money intact**.

Project total: 61 tests.

## Verified on device

Realme RMX3612, Android 14, upgrading the live v3 database to v4.

| Check | Result |
|---|---|
| v3 → v4 migration (19 tables) on the encrypted database | Clean |
| Role-aware home | Owner sees Finance, staff, inventory, backup |
| Monthly billing across the imported register | 118 invoices · **৳295,000 outstanding across 118 students** (118 × ৳2,500) |
| Dues list | Sorted, each showing months behind and the guardian's number |
| Collection | One tap from dues to the form; amount, method and wallet pre-filled |
| Receipt numbering | R-00001, then R-00002 — gapless |
| **Receipt printed through the Document Engine** | Letterhead, **মানি রসিদ** shaped correctly, ৳ symbol, previous/paid/remaining, amount in words |
| Class and batch on the receipt | "Class 9 — Science", "Science A" |

### Two defects found on device and fixed

**`setState` returning a Future.** `_reload()` in the dues screen used an arrow
body, so `setState` received the assigned `Future` rather than void and Flutter
threw a red screen. Tests could not catch it — it is a widget-lifecycle fault,
not a logic one. Fixed with a block body, and `initState` now assigns directly
instead of calling `setState` before the first build.

**No way to raise fees.** `generateMonthlyInvoices` existed with tests, and
nothing in the app called it — so dues could never appear. Added as an action on
the Dues screen, deliberately manual: a centre decides when its month starts, and
billing that fired on its own would be the app making a financial decision
nobody asked for.

### One defect found and not fully fixed

**Receipts still print on A4, not A5.** The bridge hardcoded `ISO_A4`; it now
accepts a paper size and the receipt asks for A5. The saved PDF is still A4,
because Android treats `PrintAttributes` as a *default* that the selected print
target may override, and the Save-as-PDF target kept its own A4 setting. The
content is correct and prints fine — it simply occupies the top half of an A4
sheet. **Confirm against the pilot centre's real printer** before deciding
whether more is needed; a thermal or A5-loaded printer may honour it directly.

## Known gaps

- **Per-class teacher pay is modelled but not computed.** `ClassSessions`
  records who taught, and `PayModel.perClass` exists, but nothing multiplies one
  by the other yet.
- **No payment history screen.** Payments are recorded and reversible in code;
  there is no UI listing a student's past receipts or cancelling one.
- **No month-end lock.** The plan calls for closing a period so past entries
  cannot be edited. Not built.
- **Invoices are generated on demand only** — there is no scheduler, so someone
  must trigger monthly billing.
- **Staff cannot be edited or deactivated** from the UI, and staff attendance
  has a table but no screen.
- **Expenses cannot be listed or cancelled** from the UI, though the service
  supports it.
- **No reports module.** The finance screen shows today and this month; there is
  no date-range report, no export.
