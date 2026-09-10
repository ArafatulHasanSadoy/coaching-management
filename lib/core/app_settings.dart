import 'package:drift/drift.dart';

import '../data/db/database.dart';
import '../data/db/tables.dart';

/// Preferences that live in the database rather than in code.
///
/// Each one exists because the right value differs between centres: a phone on
/// a busy counter wants a short auto-lock, one in a locked office does not.
class AppSettings {
  const AppSettings({required this.db, required this.deviceId});

  final AppDatabase db;
  final String deviceId;

  static const autoLockMinutes = 'auto_lock_minutes';
  static const receiptPrefix = 'receipt_prefix';
  static const defaultDueDay = 'default_due_day';

  static const defaults = <String, String>{
    autoLockMinutes: '3',
    receiptPrefix: 'R',
    defaultDueDay: '10',
  };

  Future<String> read(String key) async {
    final row = await (db.select(db.settings)
          ..where((t) => t.key.equals(key) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row?.value ?? defaults[key] ?? '';
  }

  Future<int> readInt(String key) async =>
      int.tryParse(await read(key)) ?? int.tryParse(defaults[key] ?? '') ?? 0;

  Future<void> write(String key, String value) async {
    final existing = await (db.select(db.settings)
          ..where((t) => t.key.equals(key))
          ..limit(1))
        .getSingleOrNull();

    if (existing == null) {
      await db.into(db.settings).insert(
            SettingsCompanion.insert(
              key: key,
              deviceId: deviceId,
              value: Value(value),
            ),
          );
    } else {
      await (db.update(db.settings)..where((t) => t.id.equals(existing.id)))
          .write(
        SettingsCompanion(
          value: Value(value),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }

    await db.recordChange(
      entity: 'settings',
      entityId: key,
      op: ChangeOp.update,
      deviceId: deviceId,
      action: 'setting_changed',
      after: {'key': key, 'value': value},
    );
  }
}
