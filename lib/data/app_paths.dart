import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the app keeps its files on disk.
///
/// Centralised because backup and restore both need to agree with the database
/// about these locations, and a mismatch would mean silently backing up nothing.
class AppPaths {
  const AppPaths(this.documents);

  static Future<AppPaths> resolve() async =>
      AppPaths(await getApplicationDocumentsDirectory());

  final Directory documents;

  /// The encrypted database.
  File get databaseFile => File('${documents.path}/coaching/app.db');

  /// Student photos, logos, question images — everything the database refers to
  /// by path rather than storing inline.
  Directory get mediaDir => Directory('${documents.path}/coaching/media');

  /// Local backup archives. Backups the owner keeps only here are one dropped
  /// phone away from being useless, which is why the UI pushes them to share a
  /// copy off the device.
  Directory get backupDir => Directory('${documents.path}/coaching/backups');
}
