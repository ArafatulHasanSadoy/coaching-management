import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Holds the values that must never live inside the database itself.
///
/// ## Why one passphrase rather than a device-random key
///
/// The obvious design — encrypt the database with a random key held in the
/// Android Keystore — protects a lost phone well but makes backups useless: an
/// export encrypted under a key that died with the handset cannot be restored
/// anywhere. Wrapping that key inside each backup would work, but it means two
/// secrets and a wrapping scheme to get right.
///
/// Instead the database is encrypted directly under an owner-chosen master
/// passphrase, cached here so day-to-day use never asks for it. That gives one
/// secret with one job: it protects the phone *and* it is what opens a backup on
/// a replacement device. The cost is that the owner must record it somewhere off
/// the phone — which setup is responsible for insisting on, because a forgotten
/// passphrase makes every backup unreadable.
///
/// The PIN is unrelated to encryption. It gates access to this cached
/// passphrase for quick unlocking; it is not what protects the data at rest.
class SecretsStore {
  SecretsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // resetOnError defaults to true, which discards the stored value
              // when the keystore throws. For the database passphrase that is
              // catastrophic — a transient Keystore fault would silently lock
              // the owner out of their own records. Fail loudly instead.
              aOptions: AndroidOptions(resetOnError: false),
            );

  final FlutterSecureStorage _storage;

  static const _passphraseName = 'master_passphrase_v1';
  static const _deviceIdName = 'device_id_v1';

  /// The cached master passphrase, or null before setup has run.
  Future<String?> masterPassphrase() => _storage.read(key: _passphraseName);

  Future<void> cacheMasterPassphrase(String passphrase) =>
      _storage.write(key: _passphraseName, value: passphrase);

  Future<bool> hasMasterPassphrase() async {
    final value = await _storage.read(key: _passphraseName);
    return value != null && value.isNotEmpty;
  }

  /// Forgets the cached passphrase. The database stays encrypted under it, so
  /// this locks the app rather than destroying anything.
  Future<void> forgetMasterPassphrase() =>
      _storage.delete(key: _passphraseName);

  /// Stable identifier for this installation, stamped onto every row it writes
  /// and onto every backup it produces. Audit and sync attribution only.
  Future<String> deviceId() async {
    final existing = await _storage.read(key: _deviceIdName);
    if (existing != null && existing.isNotEmpty) return existing;

    final fresh = const Uuid().v4();
    await _storage.write(key: _deviceIdName, value: fresh);
    return fresh;
  }
}
