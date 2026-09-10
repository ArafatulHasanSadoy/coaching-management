import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_gate.dart';
import '../core/strings.dart';
import 'lock_controller.dart';
import '../data/app_paths.dart';
import '../data/backup/backup_service.dart';
import '../data/db/database.dart';
import '../data/security/pin_hasher.dart';
import '../data/repositories/master_data_repository.dart';
import '../data/security/secrets_store.dart';
import '../data/students/csv_import.dart';
import '../data/attendance/attendance_service.dart';
import '../data/documents/document_engine.dart';
import '../data/finance/expense_service.dart';
import '../data/finance/fee_service.dart';
import '../data/finance/ledger_service.dart';
import '../data/inventory/inventory_service.dart';
import '../data/academic/session_service.dart';
import '../data/finance/payroll_service.dart';
import '../data/finance/period_lock_service.dart';
import '../data/printing/print_centre_service.dart';
import '../data/reports/reports_service.dart';
import '../data/routine/routine_repository.dart';
import '../data/staff/staff_repository.dart';
import '../data/students/admission_form_service.dart';
import '../data/students/enquiry_service.dart';
import '../data/students/students_repository.dart';
import '../../core/app_settings.dart';
import '../data/setup/setup_service.dart';

/// What startup found, and therefore which screen the user should see.
///
/// Modelled as distinct states rather than a nullable database plus an error
/// string, because the failure modes have genuinely different remedies and the
/// UI must not blur them: a first run needs setup, a bad passphrase needs a
/// restore, a build without encryption needs to stop entirely.
sealed class Bootstrap {
  const Bootstrap();
}

/// No passphrase has ever been set on this device.
class NeedsFirstRun extends Bootstrap {
  const NeedsFirstRun();
}

/// The database is open and usable.
class BootstrapReady extends Bootstrap {
  const BootstrapReady({
    required this.database,
    required this.deviceId,
    required this.paths,
    required this.setupComplete,
  });

  final AppDatabase database;
  final String deviceId;
  final AppPaths paths;

  /// False until the wizard has run. A database can be open and encrypted while
  /// still describing no centre at all — restoring a backup satisfies this
  /// without the wizard ever running.
  final bool setupComplete;
}

/// Startup cannot continue. [title] and [body] are user-facing and explain what
/// happened, why, and what to do next.
class BootstrapBlocked extends Bootstrap {
  const BootstrapBlocked({
    required this.title,
    required this.body,
    required this.canRestore,
  });

  final String title;
  final String body;

  /// Whether offering "restore a backup" is the right next step.
  final bool canRestore;
}

final secretsStoreProvider = Provider((ref) => SecretsStore());
final pinHasherProvider = Provider((ref) => const PinHasher());
final backupServiceProvider = Provider((ref) => const BackupService());
final featureGateProvider = Provider<FeatureGate>((ref) => const OpenFeatureGate());
final setupServiceProvider = Provider((ref) => const SetupService());

final appPathsProvider = FutureProvider((ref) => AppPaths.resolve());

/// Resolves startup state once per launch.
final bootstrapProvider = FutureProvider<Bootstrap>((ref) async {
  final secrets = ref.watch(secretsStoreProvider);
  final paths = await ref.watch(appPathsProvider.future);

  final passphrase = await secrets.masterPassphrase();
  if (passphrase == null || passphrase.isEmpty) {
    return const NeedsFirstRun();
  }

  final deviceId = await secrets.deviceId();

  try {
    final database = await AppDatabase.open(
      file: paths.databaseFile,
      encryptionKey: passphrase,
    );
    ref.onDispose(database.close);

    // Idempotent: creates fee heads, wallets and expense heads the first time,
    // and does nothing afterwards. Lives here rather than in the wizard so a
    // centre set up before these existed still gets them.
    await FeeService(db: database, deviceId: deviceId).ensureDefaults();

    // The auto-lock delay is a setting, so it has to be applied once the
    // database that holds it is open.
    final minutes = await AppSettings(db: database, deviceId: deviceId)
        .readInt(AppSettings.autoLockMinutes);
    ref.read(lockControllerProvider.notifier).setIdleMinutes(minutes);

    return BootstrapReady(
      database: database,
      deviceId: deviceId,
      paths: paths,
      setupComplete: await const SetupService().isComplete(database),
    );
  } on DatabaseLockedException {
    return const BootstrapBlocked(
      title: Strings.databaseLockedTitle,
      body: Strings.databaseLockedBody,
      canRestore: true,
    );
  } on EncryptionUnavailableException {
    // Deliberately fatal. Continuing would write student names, guardian phone
    // numbers and the centre's finances to disk in the clear.
    return const BootstrapBlocked(
      title: Strings.encryptionMissingTitle,
      body: Strings.encryptionMissingBody,
      canRestore: false,
    );
  }
});

/// The open database, once bootstrap has succeeded.
///
/// Throws if read before startup completes; every caller sits behind a screen
/// that only renders in the ready state.
final databaseProvider = Provider<AppDatabase>((ref) {
  final state = ref.watch(bootstrapProvider).value;
  if (state is! BootstrapReady) {
    throw StateError('databaseProvider read before startup finished');
  }
  return state.database;
});

final deviceIdProvider = Provider<String>((ref) {
  final state = ref.watch(bootstrapProvider).value;
  if (state is! BootstrapReady) {
    throw StateError('deviceIdProvider read before startup finished');
  }
  return state.deviceId;
});

/// Repository over the open database. Sits behind screens that only render once
/// startup has succeeded.
final masterDataProvider = Provider<MasterDataRepository>((ref) {
  final state = ref.watch(bootstrapProvider).value;
  if (state is! BootstrapReady) {
    throw StateError('masterDataProvider read before startup finished');
  }
  return MasterDataRepository(
    db: state.database,
    deviceId: state.deviceId,
  );
});

/// The session everything else hangs off. Null only in the window between a
/// restore and the app re-reading its data.
final activeSessionProvider = FutureProvider(
  (ref) => ref.watch(masterDataProvider).activeSession(),
);

final institutionProvider = FutureProvider(
  (ref) => ref.watch(masterDataProvider).institution(),
);

final studentsProvider = Provider<StudentsRepository>((ref) {
  final state = ref.watch(bootstrapProvider).value;
  if (state is! BootstrapReady) {
    throw StateError('studentsProvider read before startup finished');
  }
  return StudentsRepository(db: state.database, deviceId: state.deviceId);
});

final csvImportProvider = Provider((ref) => const CsvImportService());

/// Services over the open database. Each throws if read before startup, and
/// every screen that uses one renders only in the ready state.
T _withDb<T>(Ref ref, T Function(AppDatabase db, String deviceId) build) {
  final state = ref.watch(bootstrapProvider).value;
  if (state is! BootstrapReady) {
    throw StateError('service read before startup finished');
  }
  return build(state.database, state.deviceId);
}

final feeServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => FeeService(db: db, deviceId: id)));
final ledgerServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => LedgerService(db: db, deviceId: id)));
final expenseServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => ExpenseService(db: db, deviceId: id)));
final attendanceServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => AttendanceService(db: db, deviceId: id)));
final inventoryServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => InventoryService(db: db, deviceId: id)));

/// The document engine, carrying the centre's branding.
final documentEngineProvider = Provider((ref) {
  final institution = ref.watch(institutionProvider).value;
  return DocumentEngine(institution: institution);
});

final periodLockProvider = Provider(
    (ref) => _withDb(ref, (db, id) => PeriodLockService(db: db, deviceId: id)));
final payrollProvider = Provider(
    (ref) => _withDb(ref, (db, id) => PayrollService(db: db, deviceId: id)));
final sessionServiceProvider = Provider(
    (ref) => _withDb(ref, (db, id) => SessionService(db: db, deviceId: id)));
final reportsProvider = Provider(
    (ref) => _withDb(ref, (db, id) => ReportsService(db: db, deviceId: id)));
final routineProvider = Provider(
    (ref) => _withDb(ref, (db, id) => RoutineRepository(db: db, deviceId: id)));
final enquiryProvider = Provider(
    (ref) => _withDb(ref, (db, id) => EnquiryService(db: db, deviceId: id)));
final settingsProvider = Provider(
    (ref) => _withDb(ref, (db, id) => AppSettings(db: db, deviceId: id)));

final printCentreProvider = Provider(
    (ref) => _withDb(ref, (db, id) => PrintCentreService(db: db, deviceId: id)));

final admissionFormProvider = Provider((ref) =>
    _withDb(ref, (db, id) => AdmissionFormService(db: db, deviceId: id)));
final staffRepositoryProvider = Provider(
    (ref) => _withDb(ref, (db, id) => StaffRepository(db: db, deviceId: id)));
