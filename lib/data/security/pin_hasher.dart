import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Derives and verifies PIN hashes.
///
/// ## What the PIN is actually protecting
///
/// Not the data. The database is encrypted under the owner's master
/// passphrase, and an attacker holding the raw file needs *that*, not this. The
/// PIN gates access to an already-running app on a specific phone — someone
/// picking it up off the counter while the owner is away.
///
/// That changes the cost calculation. A very high iteration count would slow an
/// offline attack on the PIN hash, but reaching that hash already requires the
/// passphrase, so the expense buys little and is paid at every single unlock on
/// hardware that feels it. Measured at 120,000 iterations the check took ~400 ms
/// on a development machine, which is roughly 1–2 seconds on the mid-range phone
/// a centre actually owns — enough to be noticed at a busy counter.
///
/// The cost is therefore tuned down, and **the iteration count is stored with
/// the hash** so it can be changed again later without locking anyone out.
class PinHasher {
  const PinHasher();

  /// Used for newly created PINs. Existing hashes keep whatever count they were
  /// made with, read back from the stored value.
  static const iterations = 50000;

  /// Format: `pbkdf2$<iterations>$<base64 key>`.
  ///
  /// Self-describing on purpose — a bare base64 string would have made this
  /// number impossible to change without invalidating every PIN in the field.
  static const _scheme = 'pbkdf2';

  Future<({String hash, String salt})> hash(String pin) async {
    final salt = _randomSalt();
    final key = await _derive(pin, salt, iterations);
    return (hash: '$_scheme\$$iterations\$$key', salt: base64Encode(salt));
  }

  Future<bool> verify({
    required String pin,
    required String hash,
    required String salt,
  }) async {
    final (rounds, expected) = _parse(hash);
    final computed = await _derive(pin, base64Decode(salt), rounds);
    return _constantTimeEquals(computed, expected);
  }

  /// Reads a stored hash, tolerating the bare-base64 form written before the
  /// iteration count was recorded.
  static (int, String) _parse(String stored) {
    final parts = stored.split(r'$');
    if (parts.length == 3 && parts[0] == _scheme) {
      return (int.tryParse(parts[1]) ?? 120000, parts[2]);
    }
    // Legacy: everything written before this format used 120,000.
    return (120000, stored);
  }

  Future<String> _derive(String pin, List<int> salt, int rounds) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: rounds,
      bits: 256,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return base64Encode(await key.extractBytes());
  }

  static List<int> _randomSalt() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256));
  }

  /// Compares without leaking how many leading characters matched.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
