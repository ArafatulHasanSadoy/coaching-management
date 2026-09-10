import 'dart:io';

import 'package:coaching_ops/data/backup/backup_service.dart';
import 'package:coaching_ops/data/db/database.dart';
import 'package:coaching_ops/data/db/tables.dart';
// Only Value is needed here; a bare drift import collides with matcher's
// isNotNull and friends.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// These tests stand in for the Stage 1 gate: "restore onto a second device
/// works". A second device is simulated by restoring into a directory that has
/// never seen the original database, then opening it with nothing but the
/// passphrase — which is all a replacement phone would have.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('coaching_test');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Directory sub(String name) =>
      Directory('${root.path}/$name')..createSync(recursive: true);

  Future<AppDatabase> openAt(String dir, String passphrase) =>
      AppDatabase.open(
        file: File('${sub(dir).path}/app.db'),
        encryptionKey: passphrase,
      );

  Future<void> seed(AppDatabase db) async {
    await db.into(db.institutions).insert(
          InstitutionsCompanion.insert(
            name: 'Advance Educare',
            deviceId: 'device-a',
            address: const Value('12/A, Mirpur Road, Dhaka'),
            phone: const Value('01712345678'),
          ),
        );
    await db.into(db.academicSessions).insert(
          AcademicSessionsCompanion.insert(
            name: '2026',
            startDate: DateTime(2026, 1, 1),
            endDate: DateTime(2026, 12, 31),
            deviceId: 'device-a',
            isActive: const Value(true),
          ),
        );
  }

  group('encryption', () {
    test('database is actually encrypted and rejects the wrong passphrase',
        () async {
      final db = await openAt('a', 'correct horse battery staple');
      await seed(db);
      await db.close();

      final bytes = await File('${root.path}/a/app.db').readAsBytes();
      expect(
        String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127)),
        isNot(contains('Advance Educare')),
        reason: 'institution name found in plaintext — encryption is not on',
      );

      await expectLater(
        AppDatabase.open(
          file: File('${root.path}/a/app.db'),
          encryptionKey: 'wrong passphrase',
        ),
        throwsA(isA<DatabaseLockedException>()),
        reason: 'a wrong passphrase must surface as a restore prompt, not as a '
            'generic isolate error',
      );
    });
  });

  group('backup and restore', () {
    test('round trip onto a fresh device preserves the data', () async {
      const passphrase = 'correct horse battery staple';
      final source = await openAt('device_a', passphrase);
      await seed(source);

      final media = sub('device_a/media');
      final photo = File('${media.path}/students/photo.jpg');
      await photo.create(recursive: true);
      await photo.writeAsBytes(List<int>.filled(64, 7));

      final archive = await const BackupService().create(
        db: source,
        destination: sub('exports'),
        deviceId: 'device-a',
        mediaDir: media,
      );
      await source.close();

      expect(archive.existsSync(), isTrue);

      // ---- a different device: empty directory, passphrase only ----
      final targetDb = File('${sub('device_b').path}/app.db');
      final targetMedia = Directory('${root.path}/device_b/media');

      final inspection = await const BackupService()
          .inspect(archiveFile: archive, passphrase: passphrase);
      expect(inspection.problems, isEmpty);
      expect(inspection.canRestore, isTrue);
      expect(inspection.checksumOk, isTrue);
      expect(inspection.integrityOk, isTrue);
      expect(inspection.manifest!.mediaFileCount, 1);

      await const BackupService().restore(
        archiveFile: archive,
        passphrase: passphrase,
        targetDbFile: targetDb,
        targetMediaDir: targetMedia,
      );

      final restored = await AppDatabase.open(
        file: targetDb,
        encryptionKey: passphrase,
      );
      final institutions = await restored.select(restored.institutions).get();
      final sessions = await restored.select(restored.academicSessions).get();
      await restored.close();

      expect(institutions, hasLength(1));
      expect(institutions.single.name, 'Advance Educare');
      expect(institutions.single.phone, '01712345678');
      expect(sessions.single.name, '2026');
      expect(sessions.single.isActive, isTrue);

      expect(
        File('${targetMedia.path}/students/photo.jpg').existsSync(),
        isTrue,
        reason: 'student photos must survive a restore',
      );
    });

    test('the wrong passphrase is refused with an explanation', () async {
      final source = await openAt('device_a', 'right passphrase');
      await seed(source);
      final archive = await const BackupService().create(
        db: source,
        destination: sub('exports'),
        deviceId: 'device-a',
      );
      await source.close();

      final inspection = await const BackupService()
          .inspect(archiveFile: archive, passphrase: 'not the passphrase');

      expect(inspection.canRestore, isFalse);
      expect(inspection.opensWithPassphrase, isFalse);
      expect(inspection.problems.single, contains('passphrase'));
    });

    test('a damaged archive fails inspection and never touches live data',
        () async {
      const passphrase = 'right passphrase';
      final source = await openAt('device_a', passphrase);
      await seed(source);
      final archive = await const BackupService().create(
        db: source,
        destination: sub('exports'),
        deviceId: 'device-a',
      );
      await source.close();

      final bytes = await archive.readAsBytes();
      bytes[bytes.length ~/ 2] ^= 0xFF;
      await archive.writeAsBytes(bytes);

      final live = File('${sub('device_b').path}/app.db');
      await live.writeAsString('existing records');

      await expectLater(
        const BackupService().restore(
          archiveFile: archive,
          passphrase: passphrase,
          targetDbFile: live,
        ),
        throwsA(isA<BackupRestoreException>()),
      );

      expect(
        await live.readAsString(),
        'existing records',
        reason: 'a failed restore must leave the existing database untouched',
      );
    });

    test('restoring preserves the database it replaced', () async {
      const passphrase = 'right passphrase';
      final source = await openAt('device_a', passphrase);
      await seed(source);
      final archive = await const BackupService().create(
        db: source,
        destination: sub('exports'),
        deviceId: 'device-a',
      );
      await source.close();

      final target = File('${sub('device_b').path}/app.db');
      await target.writeAsString('the database that was already here');

      final preserved = await const BackupService().restore(
        archiveFile: archive,
        passphrase: passphrase,
        targetDbFile: target,
      );

      expect(preserved, isNotNull);
      expect(
        await File(preserved!).readAsString(),
        'the database that was already here',
      );
    });
  });

  group('audit trail', () {
    test('records an audit row and an oplog row together', () async {
      final db = AppDatabase.memory();

      await db.recordChange(
        entity: 'students',
        entityId: 'student-1',
        op: ChangeOp.update,
        deviceId: 'device-a',
        before: {'phone': '0171'},
        after: {'phone': '0181'},
        userId: 'user-1',
      );

      final trail = await db.auditTrailFor('students', 'student-1');
      final oplog = await db.select(db.changeLog).get();
      await db.close();

      expect(trail, hasLength(1));
      expect(trail.single.action, 'update');
      expect(trail.single.beforeJson, contains('0171'));
      expect(trail.single.afterJson, contains('0181'));
      expect(oplog, hasLength(1));
      expect(oplog.single.entityId, 'student-1');
    });
  });
}
