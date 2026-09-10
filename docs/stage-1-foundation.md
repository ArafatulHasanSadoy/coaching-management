# Stage 1 — foundation

Database, encryption, audit trail, backup and restore, PIN lock.

## The key decision: one passphrase, not a device key

The obvious design encrypts the database with a random key in the Android
Keystore. It protects a lost phone well and makes backups worthless — an export
encrypted under a key that died with the handset cannot be restored anywhere.

Since the whole plan rests on a single master phone, a backup that cannot be
restored is not a backup. So the database is encrypted **directly under an
owner-chosen master passphrase**, cached in secure storage so daily use never
asks for it. One secret with one job: it protects the phone, and it is what opens
a backup on a replacement device.

The cost is real and setup states it bluntly: nobody can recover a forgotten
passphrase, and losing it makes every existing backup unreadable. The first-run
screen requires an explicit "I have written it down" before continuing.

**The PIN is unrelated to encryption.** It gates access to the cached passphrase
for quick unlocking. Calling it a security boundary would be a lie — the data at
rest is protected by the passphrase whether the app is locked or not. What the
lock actually defends against is the realistic threat: someone picking up a
shared counter phone while the owner is away.

## Conventions applied from schema version 1

Every domain table carries `id` (UUID), `createdAt`, `updatedAt`, `deletedAt`,
`deviceId` — via the `SyncableTable` mixin in `lib/data/db/tables.dart`. Nothing
in v1 reads them. They exist now because adding them later would be a migration
over live customer data rather than a change.

`AuditLog` and `ChangeLog` deliberately **do not** use the mixin. An audit trail
that can itself be soft-deleted is not an audit trail; both are append-only.
`AppDatabase.recordChange` writes the audit row and the oplog row in one
transaction, so one can never exist without the other.

## Failures are distinguished, not lumped together

Three startup outcomes have three different remedies, so they are three types
(`Bootstrap` in `lib/app/bootstrap.dart`) rather than a nullable database:

| State | Meaning | What the user is told |
|---|---|---|
| `NeedsFirstRun` | No passphrase set | Setup wizard |
| `BootstrapBlocked` (locked) | Stored passphrase no longer opens the database | Records are not lost — restore a backup |
| `BootstrapBlocked` (no cipher) | Build has no encryption support | App stops rather than write plaintext |

The last one is deliberately fatal. A build that silently lost cipher support
would write student names, guardian phone numbers and the centre's finances to
disk in the clear; failing loudly is the only acceptable behaviour.

Two supporting details make this work:

- `AppDatabase.open` unwraps drift's `DriftRemoteException`. Drift runs the
  database on a background isolate, so without unwrapping, "wrong passphrase"
  and "no cipher support" arrive indistinguishable from any other error.
- `flutter_secure_storage` is configured with `resetOnError: false`. The default
  is `true`, which **discards the stored value** when the keystore throws — for a
  database passphrase that would silently lock an owner out of their own records.

## Backup format

A zip holding `database.db` (encrypted under the master passphrase),
`manifest.json`, and `media/`. The snapshot uses `VACUUM INTO` rather than a file
copy, so it is transactionally consistent without closing the database or
interrupting the user.

Restore never runs on faith. `BackupService.inspect` unpacks to scratch space and
checks the manifest, the SHA-256 of the database, whether the passphrase opens
it, `PRAGMA integrity_check`, and schema agreement — collecting **all** problems
rather than throwing on the first, so the user hears everything wrong at once.
Only when that passes is live data touched, and the database being replaced is
renamed to `.pre-restore-<timestamp>` rather than deleted.

Stale `-wal` and `-shm` sidecars are removed during restore. A restored database
paired with the previous database's write-ahead log would be silently
inconsistent — the kind of corruption that surfaces weeks later.

## Verification

`test/backup_restore_test.dart` — six tests, all passing:

- the database is genuinely encrypted (the institution name does not appear in
  the raw file) and a wrong passphrase raises `DatabaseLockedException`
- **a full round trip onto a simulated second device**: back up, restore into a
  directory that has never seen the original, open with the passphrase alone,
  and find the records and student photos intact
- a wrong passphrase is refused with an explanation rather than a failure
- a corrupted archive fails inspection and **leaves existing data untouched**
- the replaced database is preserved
- audit and oplog rows are written together

## Verified on real hardware

Run on a Realme RMX3612, Android 14. Setup completed, PIN set, app unlocked,
backup taken — all on the device.

| Check | Result |
|---|---|
| Encryption active in the Android build | **Yes — `chacha20`** |
| Database created and readable | 52 KB, schema v1 |
| PIN unlock | Works |
| Idle auto-lock | Fired on its own during testing |
| Backup written on device | 52.4 KB archive |
| Self-verification on device | Checksum OK · opens with passphrase · integrity OK |
| **Archive restored on a different machine** | **Yes** |

That last row is the gate. `test/device_archive_test.dart` takes the archive the
phone wrote, pulls it to macOS, and restores it there — a different OS, CPU
architecture and SQLite build — using only the passphrase. The owner account came
back intact. Simulated second devices in the other tests are directories; this one
is genuinely a different machine.

Two things worth recording:

- **The cipher is ChaCha20-Poly1305, not AES.** SQLite3MultipleCiphers defaults
  to it rather than to SQLCipher's AES-256-CBC. It is a strong modern choice and
  nothing here depends on the difference, but the plan said "SQLCipher" and what
  actually ships is sqlite3mc's default — worth knowing before anyone writes AES
  in a security disclosure.
- **`sqlcipher_flutter_libs` is dead** ("no longer does anything" as of 0.7.0+eol)
  and was removed. Encryption now comes from drift ≥ 2.32 with sqlite3 3.x plus
  a `hooks: user_defines: sqlite3: source: sqlite3mc` block in `pubspec.yaml`.
  **If that block is ever lost, the app refuses to start rather than writing
  plaintext** — see `EncryptionUnavailableException`.

## Known gaps, carried into Stage 2

- The restore *UI* does not exist yet — `BlockedScreen` offers the button but the
  screen behind it is Stage 2 work. The service and its tests are complete.
- Backups are written to app storage only. Getting a copy off the phone (share
  sheet, then automatic Drive upload) is the first post-launch item, and until it
  exists a lost phone still loses everything.
- Archives are assembled in memory. Fine for the tens of megabytes a centre
  accumulates; switch to the streaming `ZipFileEncoder` if media grows.
- Idle timeout is a fixed 3 minutes and should become a setting.
- The debug APK is 185 MB — all ABIs, unstripped, with a debug engine. Release
  builds with split-per-ABI need measuring before any size claim is made.
- PBKDF2 at 120k iterations is visibly slow on a mid-range phone: the unlock
  button sits in its busy state long enough to notice. Worth timing properly and
  tuning against the "unlock takes seconds" goal.
