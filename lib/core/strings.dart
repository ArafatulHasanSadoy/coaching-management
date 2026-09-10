/// Every user-visible string in the app.
///
/// The UI is English and planned to stay that way, so this is not a
/// localisation layer and deliberately avoids the weight of one. It exists
/// because scattering literals through forty screens is the thing that makes
/// localisation impossible *later* — and because having the whole product's
/// voice in one file makes it reviewable as writing rather than as code.
abstract final class Strings {
  static const appName = 'Coaching Ops';

  // Lock screen ---------------------------------------------------------
  static const enterPin = 'Enter your PIN';
  static const wrongPin = 'That PIN is not right.';
  static const unlockWithBiometrics = 'Unlock with fingerprint';
  static const unlockReason = 'Unlock Coaching Ops';

  // Database failures ---------------------------------------------------
  /// Shown when the stored passphrase no longer opens the database. Says what
  /// happened, why, and what to do — rather than surfacing an error code.
  static const databaseLockedTitle = 'Your records could not be opened';
  static const databaseLockedBody =
      'The saved passphrase no longer unlocks the database on this phone. Your '
      'records are not lost — restore your most recent backup and enter the '
      'master passphrase you wrote down during setup.';

  static const encryptionMissingTitle = 'This build is not secure';
  static const encryptionMissingBody =
      'Encryption support is missing, so student and financial records would be '
      'stored unprotected. The app has stopped rather than write them. Reinstall '
      'from an official build.';

  // Backup --------------------------------------------------------------
  static const backupNow = 'Back up now';
  static const backupNeverRun = 'You have never backed up.';
  static const restoreBackup = 'Restore a backup';
  static const restoreWarning =
      'Restoring replaces everything currently in the app. The database being '
      'replaced is kept aside first, so this can be undone.';

  static String backupAgeWarning(int days) => days == 1
      ? 'Your last backup was yesterday.'
      : 'Your last backup was $days days ago.';
}
