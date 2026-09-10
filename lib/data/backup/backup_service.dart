import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../db/database.dart';

/// Describes what a backup archive contains, so a restore can be checked before
/// anything is overwritten.
class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.deviceId,
    required this.databaseBytes,
    required this.databaseSha256,
    required this.mediaFileCount,
  });

  factory BackupManifest.fromJson(Map<String, Object?> json) => BackupManifest(
        formatVersion: json['formatVersion']! as int,
        schemaVersion: json['schemaVersion']! as int,
        createdAt: DateTime.parse(json['createdAt']! as String),
        deviceId: json['deviceId']! as String,
        databaseBytes: json['databaseBytes']! as int,
        databaseSha256: json['databaseSha256']! as String,
        mediaFileCount: json['mediaFileCount']! as int,
      );

  /// Layout of the archive itself, independent of the database schema.
  static const currentFormatVersion = 1;

  final int formatVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final String deviceId;
  final int databaseBytes;
  final String databaseSha256;
  final int mediaFileCount;

  Map<String, Object?> toJson() => {
        'formatVersion': formatVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'deviceId': deviceId,
        'databaseBytes': databaseBytes,
        'databaseSha256': databaseSha256,
        'mediaFileCount': mediaFileCount,
      };
}

/// The result of a dry run against a backup archive.
///
/// Restoring is the one operation that can destroy a coaching center's records,
/// so it never happens on faith: every check here runs against a scratch copy
/// first, and [canRestore] must be true before live data is touched.
class BackupInspection {
  BackupInspection({
    required this.manifest,
    required this.checksumOk,
    required this.opensWithPassphrase,
    required this.integrityOk,
    required this.problems,
  });

  final BackupManifest? manifest;
  final bool checksumOk;
  final bool opensWithPassphrase;
  final bool integrityOk;
  final List<String> problems;

  bool get canRestore => problems.isEmpty;
}

/// Creates, verifies and restores backup archives.
///
/// A backup is a zip holding an encrypted copy of the database, the media
/// directory, and a manifest. The database copy is encrypted under the owner's
/// master passphrase — the same secret the app itself uses — so a restore on a
/// replacement phone needs only that passphrase and the file.
///
/// Archives are assembled in memory, which suits the tens of megabytes a
/// coaching center accumulates. If media ever grows past that, this is the place
/// to switch to the streaming `ZipFileEncoder`.
class BackupService {
  const BackupService();

  static const _dbEntryName = 'database.db';
  static const _manifestEntryName = 'manifest.json';
  static const _mediaPrefix = 'media/';

  /// Writes a backup of [db] into [destination] and returns the archive file.
  ///
  /// Uses `VACUUM INTO` rather than copying the file, so the snapshot is
  /// transactionally consistent without closing the database or stopping the
  /// user mid-task.
  Future<File> create({
    required AppDatabase db,
    required Directory destination,
    required String deviceId,
    Directory? mediaDir,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final scratch = await Directory.systemTemp.createTemp('coaching_backup');

    try {
      final snapshot = File('${scratch.path}/$_dbEntryName');
      await db.customStatement(
        "VACUUM INTO '${snapshot.path.replaceAll("'", "''")}'",
      );

      final dbBytes = await snapshot.readAsBytes();
      final entries = <ArchiveFile>[];

      var mediaCount = 0;
      if (mediaDir != null && mediaDir.existsSync()) {
        await for (final entity in mediaDir.list(recursive: true)) {
          if (entity is! File) continue;
          final relative = entity.path.substring(mediaDir.path.length + 1);
          entries.add(
            ArchiveFile.bytes('$_mediaPrefix$relative', await entity.readAsBytes()),
          );
          mediaCount++;
        }
      }

      final manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        schemaVersion: db.schemaVersion,
        createdAt: timestamp,
        deviceId: deviceId,
        databaseBytes: dbBytes.length,
        databaseSha256: await _sha256Hex(dbBytes),
        mediaFileCount: mediaCount,
      );

      final archive = Archive()
        ..add(ArchiveFile.bytes(_dbEntryName, dbBytes))
        ..add(
          ArchiveFile.string(
            _manifestEntryName,
            const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          ),
        );
      for (final entry in entries) {
        archive.add(entry);
      }

      await destination.create(recursive: true);
      final outFile = File('${destination.path}/${_fileNameFor(timestamp)}');
      await outFile.writeAsBytes(ZipEncoder().encodeBytes(archive));
      return outFile;
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  /// Checks an archive without modifying anything.
  ///
  /// Every failure is collected rather than thrown, so the user can be told
  /// everything that is wrong at once instead of one problem per attempt.
  Future<BackupInspection> inspect({
    required File archiveFile,
    required String passphrase,
  }) async {
    final problems = <String>[];
    BackupManifest? manifest;
    var checksumOk = false;
    var opensWithPassphrase = false;
    var integrityOk = false;

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
    } catch (e) {
      return BackupInspection(
        manifest: null,
        checksumOk: false,
        opensWithPassphrase: false,
        integrityOk: false,
        problems: ['The file is not a readable backup archive ($e).'],
      );
    }

    final manifestEntry = _findEntry(archive, _manifestEntryName);
    final dbEntry = _findEntry(archive, _dbEntryName);

    if (manifestEntry == null) problems.add('The archive has no manifest.');
    if (dbEntry == null) problems.add('The archive has no database.');

    if (manifestEntry != null) {
      try {
        manifest = BackupManifest.fromJson(
          jsonDecode(utf8.decode(manifestEntry.content as List<int>))
              as Map<String, Object?>,
        );
        if (manifest.formatVersion > BackupManifest.currentFormatVersion) {
          problems.add(
            'This backup was made by a newer version of the app '
            '(format ${manifest.formatVersion}). Update before restoring.',
          );
        }
      } catch (e) {
        problems.add('The manifest could not be read ($e).');
      }
    }

    if (dbEntry != null) {
      final dbBytes = dbEntry.content as List<int>;

      if (manifest != null) {
        checksumOk = await _sha256Hex(dbBytes) == manifest.databaseSha256;
        if (!checksumOk) {
          problems.add('The database is damaged — its checksum does not match.');
        }
      }

      final scratch = await Directory.systemTemp.createTemp('coaching_verify');
      try {
        final candidate = File('${scratch.path}/candidate.db');
        await candidate.writeAsBytes(dbBytes);

        final result = _probe(candidate, passphrase);
        opensWithPassphrase = result.opened;
        integrityOk = result.integrityOk;

        if (!opensWithPassphrase) {
          problems.add(
            'The passphrase does not open this backup. It must be the master '
            'passphrase from the device that created it.',
          );
        } else if (!integrityOk) {
          problems.add('The database failed its integrity check.');
        } else if (result.schemaVersion != null &&
            manifest != null &&
            result.schemaVersion != manifest.schemaVersion) {
          problems.add(
            'The database reports schema ${result.schemaVersion} but the '
            'manifest says ${manifest.schemaVersion}.',
          );
        }
      } finally {
        await scratch.delete(recursive: true);
      }
    }

    return BackupInspection(
      manifest: manifest,
      checksumOk: checksumOk,
      opensWithPassphrase: opensWithPassphrase,
      integrityOk: integrityOk,
      problems: problems,
    );
  }

  /// Replaces the live database and media with the contents of [archiveFile].
  ///
  /// The caller must have closed the database first. The previous database is
  /// moved aside rather than deleted, so a restore that turns out to be the
  /// wrong file is still recoverable.
  ///
  /// Returns the path the previous database was preserved at, or null if there
  /// was nothing to preserve.
  Future<String?> restore({
    required File archiveFile,
    required String passphrase,
    required File targetDbFile,
    Directory? targetMediaDir,
    DateTime? now,
  }) async {
    final inspection =
        await inspect(archiveFile: archiveFile, passphrase: passphrase);
    if (!inspection.canRestore) {
      throw BackupRestoreException(inspection.problems);
    }

    final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
    final dbEntry = _findEntry(archive, _dbEntryName)!;

    String? preservedPath;
    if (targetDbFile.existsSync()) {
      final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
      preservedPath = '${targetDbFile.path}.pre-restore-$stamp';
      await targetDbFile.rename(preservedPath);
    }

    await targetDbFile.parent.create(recursive: true);
    await targetDbFile.writeAsBytes(dbEntry.content as List<int>);

    // Drift may have left sidecars beside the old database; a restored file
    // paired with a stale WAL would be silently inconsistent.
    for (final suffix in const ['-wal', '-shm']) {
      final sidecar = File('${targetDbFile.path}$suffix');
      if (sidecar.existsSync()) await sidecar.delete();
    }

    if (targetMediaDir != null) {
      if (targetMediaDir.existsSync()) {
        await targetMediaDir.delete(recursive: true);
      }
      await targetMediaDir.create(recursive: true);
      for (final entry in archive) {
        if (!entry.isFile || !entry.name.startsWith(_mediaPrefix)) continue;
        final relative = entry.name.substring(_mediaPrefix.length);
        final outFile = File('${targetMediaDir.path}/$relative');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>);
      }
    }

    return preservedPath;
  }

  static String _fileNameFor(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'coaching-backup-${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}.zip';
  }

  static ArchiveFile? _findEntry(Archive archive, String name) {
    for (final entry in archive) {
      if (entry.name == name && entry.isFile) return entry;
    }
    return null;
  }

  static ({bool opened, bool integrityOk, int? schemaVersion}) _probe(
    File candidate,
    String passphrase,
  ) {
    sqlite3.Database? db;
    try {
      db = sqlite3.sqlite3.open(candidate.path);
      db.execute("PRAGMA key = '${passphrase.replaceAll("'", "''")}';");
      db.select('SELECT count(*) FROM sqlite_schema;');
    } catch (_) {
      db?.close();
      return (opened: false, integrityOk: false, schemaVersion: null);
    }

    try {
      final integrity = db.select('PRAGMA integrity_check;');
      final ok = integrity.isNotEmpty &&
          (integrity.first.values.first as String?)?.toLowerCase() == 'ok';
      final version = db.select('PRAGMA user_version;').first.values.first;
      return (
        opened: true,
        integrityOk: ok,
        schemaVersion: version is int ? version : null,
      );
    } catch (_) {
      return (opened: true, integrityOk: false, schemaVersion: null);
    } finally {
      db.close();
    }
  }

  static Future<String> _sha256Hex(List<int> bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Raised when a restore is attempted against an archive that failed inspection.
class BackupRestoreException implements Exception {
  const BackupRestoreException(this.problems);
  final List<String> problems;

  @override
  String toString() => 'BackupRestoreException: ${problems.join(' ')}';
}
