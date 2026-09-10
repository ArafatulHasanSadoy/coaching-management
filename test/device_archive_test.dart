import 'dart:io';

import 'package:coaching_ops/data/backup/backup_service.dart';
import 'package:coaching_ops/data/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Restores a backup produced by the real Android app onto this machine.
///
/// The unit tests simulate a second device by using a second directory; this
/// closes the remaining gap by taking an archive written by the phone — a
/// different OS, a different CPU architecture, a different SQLite build — and
/// opening it here with nothing but the passphrase. That is the Stage 1 gate.
///
/// Skips itself when the archive is absent, so CI does not depend on a phone
/// being plugged in.
void main() {
  const archivePath =
      '/private/tmp/claude-501/-Users-farhantanvir-Dev-coaching-management/'
      '1c48568c-2d72-4c27-afe4-82c7e37e4f54/scratchpad/from-device.zip';
  const passphrase = 'CoachingOps2026Test';

  test('an archive written by the Android app restores on another machine',
      () async {
    final archive = File(archivePath);
    if (!archive.existsSync()) {
      markTestSkipped('no device archive at $archivePath');
      return;
    }

    final root = await Directory.systemTemp.createTemp('from_device');
    addTearDown(() => root.delete(recursive: true));

    final inspection = await const BackupService()
        .inspect(archiveFile: archive, passphrase: passphrase);

    expect(inspection.problems, isEmpty);
    expect(inspection.checksumOk, isTrue);
    expect(inspection.opensWithPassphrase, isTrue);
    expect(inspection.integrityOk, isTrue);
    expect(inspection.manifest!.schemaVersion, 1);

    final target = File('${root.path}/restored.db');
    await const BackupService().restore(
      archiveFile: archive,
      passphrase: passphrase,
      targetDbFile: target,
    );

    final db =
        await AppDatabase.open(file: target, encryptionKey: passphrase);
    final users = await db.select(db.appUsers).get();
    await db.close();

    expect(users, hasLength(1));
    expect(users.single.name, 'Owner');
    expect(users.single.role.name, 'owner');
    expect(users.single.pinHash, isNotEmpty);

    // ignore: avoid_print
    print('Restored from device archive: ${users.single.name} '
        '(${users.single.role.name}), device ${inspection.manifest!.deviceId}');
  });
}
